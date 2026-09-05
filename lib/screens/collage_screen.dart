import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crop_screen.dart';
import '../models/watermark_settings.dart';
import '../services/collage_compose.dart';
import '../services/file_reader.dart';
import '../services/photo_export.dart';
import '../theme.dart';
import '../widgets/watermark_layer.dart';
import '../widgets/watermark_panel.dart';

/// 照片拼圖：一個畫面、三個分頁（拼圖／浮水印／匯出），跟影片編輯器的
/// 剪輯／浮水印／匯出同一套。拼圖分頁排照片（2/4/6/9 宮格或自由排版）、
/// 浮水印分頁在同一個預覽上疊浮水印（共用的 WatermarkPanel＋
/// WatermarkLayer，接法照批次浮水印那一頁）、匯出分頁把「拼圖＋浮水印」
/// 一次合成存相簿。不再交給照片編輯器、沒有「完成」鈕（使用者指定：
/// 乾淨拼圖就好）。
/// 畫布比例可選（1:1/4:5/3:4/16:9/9:16）、格子等分、照片置中裁滿（cover）；
/// 拖曳格子互換位置、點一下鎖定後可調構圖（右上角鈕換照片），
/// 也能開純格線（調線寬、選顏色）。空格子隨時允許，合成時留透明。
/// 拼圖的草稿鍵（個人頁「未完成的拼圖」讀這裡）
const kCollageDraftKey = 'collage_draft_v1';

class CollageScreen extends StatefulWidget {
  /// 進場時就帶進來的照片。可以是空的——空手進來先排宮格、
  /// 再用底下的「批次匯入照片」或每一格的「＋」放照片
  final List<XFile> photos;

  /// 從草稿續作：照片路徑＋排法＋設定（見 kCollageDraftKey）
  final Map<String, dynamic>? restore;

  const CollageScreen({super.key, this.photos = const [], this.restore});

  @override
  State<CollageScreen> createState() => _CollageScreenState();
}

/// 單邊上限：再多的話手機上每格會小於觸控目標（約 48dp），
/// 點選、拖曳互換、雙指縮放都會變得很難按
const _kMaxSide = 6;

/// 總格數上限：輸出畫布放大到 2400 時每格仍有 400px
const _kMaxCells = 30;

/// 解碼後的長邊上限。不縮的話一張 4000x3000 的照片解開就是 48MB，
/// 放滿 30 格會直接被系統殺掉；縮到這裡每張約 7.7MB，
/// 而輸出畫布最多 2400、單格最多幾百 px，畫質綽綽有餘
const _kDecodeLongSide = 1600;

class _CollageScreenState extends State<CollageScreen>
    with SingleTickerProviderStateMixin {
  /// 已解碼的照片。換掉之後不再被任何格子用到的會被釋放並留 null，
  /// 索引保持穩定（_order 存的是這裡的索引）
  final List<ui.Image?> _images = [];

  /// 每張照片的來源路徑（跟 _images 同索引；存草稿用）。
  /// 換單張時換上的是裁切版，路徑仍記原圖——續作時裁切會回到原圖
  final List<String?> _srcPaths = [];

  /// 一開始選進來的那批數量：換版型時還會用到，不能釋放
  int _poolSize = 0;

  /// 宮格的欄與列（0 = 還在載入）
  int _cols = 0;
  int _rows = 0;

  int get _cellCount => _cols * _rows;

  /// 每個格子放哪張照片（照片 index，照選取順序）
  List<int> _order = [];

  /// 選取中的格子（-1 = 沒有）：選中後可拖曳移動、雙指縮放調整構圖
  int _selCell = -1;

  /// 每格的取景（縮放倍率＋來源像素平移；數學在 collage_compose.dart，
  /// 預覽跟匯出同一段）
  List<CollageCellFit> _fits = [];

  // 雙指縮放
  final Map<int, Offset> _pts = {};
  double? _baseDist;
  double _baseZoom = 1;

  // 拖曳互換：從哪格拖起、目前指尖（宮格座標）、懸在哪格上
  int _dragFrom = -1;
  Offset? _dragPos;
  int _dragOver = -1;

  /// 按住多久才算「拿起來」。跟排序清單同一個手感（200ms）：
  /// 內建的 500ms 按起來像沒反應，再短就會跟一般的點選打架
  static const _kHoldDelay = Duration(milliseconds: 200);

  /// 按住計時器與按下的位置（宮格座標）。時間到才進入拖曳，
  /// 途中手指移開太多就取消——一按就拖的話，只是想點一下鎖定
  /// 都會不小心把照片搬走
  Timer? _holdTimer;
  Offset? _holdPos;

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  // 這一幀宮格的幾何（拖曳換算目標格用）
  double _gG = 0, _gCw = 1, _gCh = 1;

  /// 格線：開了之後在格子交界疊上細線（純線條，不填背景）
  bool _lines = false;

  /// 線寬（畫布邊長的比例），格線開啟時才作用
  double _gapN = 0.008;

  /// 格線顏色（ARGB）
  int _lineColor = 0xFFFFFFFF;

  // ===== 自由模式 =====
  //
  // 照片不排格子，是畫布上一塊塊可以自由拖曳、四角拉伸的方塊。
  // 想要「一張大的配兩張小的」這種排法，宮格等分做不到

  /// 自由模式開關（版型列的「宮格／自由」切換）
  bool _free = false;

  /// 自由模式的照片方塊（畫的順序＝疊的順序，後面的在上面）
  final List<CollageFreeItem> _items = [];

  /// 自由模式選取中的方塊（-1 = 沒有）
  int _selItem = -1;

  /// 進行中的手勢（移動或拉某一角），null = 沒有
  _FreeDrag? _fDrag;

  /// 畫布比例（寬/高），宮格與自由共用。方塊座標是 0~1 的比例，
  /// 換比例時排版跟著畫布伸縮，不會弄丟
  double _canvasAspect = 1;

  /// 畫布比例的選項（標籤＋寬/高）
  static const _kAspects = [
    ('1:1', 1.0),
    ('4:5', 0.8),
    ('3:4', 0.75),
    ('16:9', 16 / 9),
    ('9:16', 9 / 16),
  ];

  // ===== 分頁：拼圖／浮水印／匯出（跟影片編輯器的剪輯／浮水印／匯出同一套）=====

  static const _kTabCollage = 0;
  static const _kTabWatermark = 1;
  static const _kTabExport = 2;

  late final TabController _tabs = TabController(length: 3, vsync: this);

  int get _tab => _tabs.index;

  /// 換分頁：拼圖分頁上的選取、按住、拖曳全部收掉。浮水印／匯出分頁上
  /// 拼圖本身不吃手勢，殘留的亮框會讓人以為還能動。
  /// 三個分頁永遠都能切（照片還沒放也能先調浮水印，跟影片編輯器一樣）
  void _onTabChanged() {
    if (!mounted) return;
    _cancelHold();
    // 剛切進浮水印分頁就先把浮水印選起來（使用者指定：點浮水印時要
    // 自動選取）——不然進來還得再點一下才有框、才拖得動。只在「換到」
    // 這一頁的那一下做：在頁內自己取消選取的話不會被硬選回去
    final entering =
        _tabs.index == _kTabWatermark && _lastTab != _kTabWatermark;
    _lastTab = _tabs.index;
    setState(() {
      _selCell = -1;
      _selItem = -1;
      _fDrag = null;
      _dragFrom = -1;
      _dragPos = null;
      _dragOver = -1;
      if (entering && _wmPartAlive == WmPart.none) _wmPart = _defaultWmPart;
    });
  }

  /// 上一次看到的分頁索引（判斷「剛切進來」用）
  int _lastTab = _kTabCollage;

  /// 進浮水印分頁時預設選哪個部件：有字的文字優先，不然就 Logo；
  /// 平鋪的不能選（位置無意義）
  WmPart get _defaultWmPart {
    final t = _wm.text;
    if (t.enabled && !t.tiled && t.text.trim().isNotEmpty) return WmPart.text;
    final lg = _wm.logo;
    if (lg.enabled && !lg.tiled) return WmPart.logo;
    return WmPart.none;
  }

  // ===== 浮水印：整張拼圖一組（預覽與面板的接法照批次浮水印那一頁）=====

  final _wm = WatermarkSettings();

  /// 被選浮水印部件的框（畫在裁切外，拖出畫面也看得到位置）
  final _wmFrameInfo = ValueNotifier<WmFrameInfo?>(null);

  /// 點預覽上的浮水印時，叫下面的面板捲到對應的設定區塊
  final _wmPanelCtrl = WatermarkPanelController();

  /// 選取中的部件：選了圖片就鎖定圖片，拖曳／縮放都只動它
  WmPart _wmPart = WmPart.none;

  /// 被選部件還活著嗎（存在、非平鋪）；不活一律當沒選
  WmPart get _wmPartAlive {
    final t = _wm.text;
    final lg = _wm.logo;
    return switch (_wmPart) {
      WmPart.text when t.enabled && !t.tiled && t.text.trim().isNotEmpty =>
        WmPart.text,
      WmPart.logo when lg.enabled && !lg.tiled => WmPart.logo,
      _ => WmPart.none,
    };
  }

  void _clearWmSel() {
    if (_wmPart != WmPart.none) setState(() => _wmPart = WmPart.none);
  }

  // ===== 匯出 =====

  bool _exporting = false;

  /// 成功匯出過。跟影片、批次同一條規矩（batch_watermark_screen 的
  /// _exportedOk）：匯出成功過就不再問「要不要保留草稿」，
  /// 靜靜留一份走人；沒匯出過才問
  bool _exportedOk = false;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTabChanged);
    _load();
  }

  @override
  void dispose() {
    _cancelHold();
    _tabs.dispose();
    _wmFrameInfo.dispose();
    _wmPanelCtrl.dispose();
    for (final img in _images) {
      img?.dispose();
    }
    super.dispose();
  }

  /// 解碼並把長邊縮到 [_kDecodeLongSide]。
  /// 先用 ImageDescriptor 讀出原圖尺寸（不解碼像素），才知道該縮哪一邊——
  /// 只指定 targetWidth 的話，直式照片反而會被放大
  Future<ui.Image> _decode(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final desc = await ui.ImageDescriptor.encoded(buffer);
      final long = math.max(desc.width, desc.height);
      ui.Codec codec;
      if (long > _kDecodeLongSide) {
        final k = _kDecodeLongSide / long;
        codec = await desc.instantiateCodec(
          targetWidth: math.max(1, (desc.width * k).round()),
          targetHeight: math.max(1, (desc.height * k).round()),
        );
      } else {
        codec = await desc.instantiateCodec(); // 本來就小，不放大
      }
      final frame = await codec.getNextFrame();
      codec.dispose();
      desc.dispose();
      return frame.image;
    } catch (_) {
      // ImageDescriptor 這條快路不是每個平台都在（web 的部分算圖
      // 引擎沒有它），走不通就退回一般解碼——少了「先縮再解」的
      // 省記憶體，但至少解得開
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    }
  }

  /// 讀不出來時給個有用的說法：iPhone 的 HEIC 瀏覽器解不動是最常見的
  /// 原因，講清楚比一句「讀不出來」省使用者一輪瞎猜
  static String _decodeFailMsg(Iterable<String> names) {
    final heic = names.any((n) {
      final l = n.toLowerCase();
      return l.endsWith('.heic') || l.endsWith('.heif');
    });
    return heic ? '瀏覽器解不了 HEIC 格式，請先轉成 JPG（或改用手機版）' : '照片讀不出來';
  }

  // ===== 草稿（離開保護；跟批次同一套 prefs 存法）=====

  bool get _hasContent => _images.any((i) => i != null);

  String _draftJson() => jsonEncode({
    'photos': [for (final p in _srcPaths) p ?? ''],
    'order': _order,
    'cols': _cols,
    'rows': _rows,
    'free': _free,
    'aspect': _canvasAspect,
    'lines': _lines,
    'gapN': _gapN,
    'lineColor': _lineColor,
    'fits': [
      for (final f in _fits) {'z': f.zoom, 'x': f.panX, 'y': f.panY},
    ],
    'freeItems': [
      for (final t in _items)
        {
          'img': t.img,
          'l': t.rect.left,
          't': t.rect.top,
          'w': t.rect.width,
          'h': t.rect.height,
        },
    ],
    // 整張拼圖那一組浮水印一起存：續作時浮水印要跟著回來
    'wm': _wm.toJson(),
    'savedAt': DateTime.now().toIso8601String(),
  });

  Future<void> _saveDraft() async {
    try {
      // 先在同步這一段把內容組好：匯出成功後關頁那條路是 unawaited
      // 呼叫的，await 之後才讀 state 欄位太晚（跟批次同一個寫法）
      final text = _draftJson();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kCollageDraftKey, text);
    } catch (_) {}
  }

  /// 從草稿把照片與排法還原。照片不在了就略過並講清楚；
  /// 一張都讀不回來回 false，退回一般載入（空盤）
  Future<bool> _restoreDraft(Map<String, dynamic> r) async {
    // 浮水印先還原：照片就算都不在了，調好的浮水印也不該跟著蒸發。
    // 不換掉 _wm 物件（面板與預覽綁的是同一個參照），整組搬進去
    final wm = r['wm'];
    if (wm is Map) {
      try {
        _wm.copyMarksFrom(
          WatermarkSettings.fromJson(Map<String, dynamic>.from(wm)),
        );
      } catch (_) {}
    }
    try {
      final paths = (r['photos'] as List? ?? []);
      final map = <int, int>{}; // 草稿裡的索引 → 現在的索引
      var gone = 0;
      for (var i = 0; i < paths.length; i++) {
        final p0 = paths[i];
        if (p0 is! String || p0.isEmpty) continue;
        if (!await fileExists(p0)) {
          gone++;
          continue;
        }
        try {
          final img = await _decode(await XFile(p0).readAsBytes());
          if (!mounted) {
            img.dispose();
            return true;
          }
          map[i] = _images.length;
          _images.add(img);
          _srcPaths.add(p0);
        } catch (_) {
          gone++;
        }
      }
      if (_images.isEmpty) {
        if (mounted && paths.isNotEmpty) {
          showHint(context, '這份拼圖的照片都已經不在了，從空白開始', error: true);
        }
        return false;
      }
      _poolSize = _images.length;
      _free = r['free'] == true;
      _canvasAspect = ((r['aspect'] as num?)?.toDouble() ?? 1.0).clamp(
        0.3,
        3.5,
      );
      _lines = r['lines'] == true;
      _gapN = ((r['gapN'] as num?)?.toDouble() ?? 0.008).clamp(0.0, 0.05);
      final lc = (r['lineColor'] as num?)?.toInt();
      if (lc != null) _lineColor = lc;
      _cols = ((r['cols'] as num?)?.toInt() ?? 2).clamp(1, _kMaxSide);
      _rows = ((r['rows'] as num?)?.toInt() ?? 2).clamp(1, _kMaxSide);
      final ord = (r['order'] as List? ?? []).cast<num>();
      _order = List.generate(
        _cellCount,
        (n) => n < ord.length ? (map[ord[n].toInt()] ?? -1) : -1,
      );
      final fs = (r['fits'] as List? ?? []);
      _fits = List.generate(_cellCount, (n) {
        final f = CollageCellFit();
        if (n < fs.length && fs[n] is Map) {
          final m = fs[n] as Map;
          f.zoom = ((m['z'] as num?)?.toDouble() ?? 1.0).clamp(1.0, 8.0);
          f.panX = (m['x'] as num?)?.toDouble() ?? 0;
          f.panY = (m['y'] as num?)?.toDouble() ?? 0;
        }
        return f;
      });
      _items.clear();
      for (final e in (r['freeItems'] as List? ?? [])) {
        if (e is! Map) continue;
        final ni = map[(e['img'] as num?)?.toInt() ?? -1];
        if (ni == null) continue;
        _items.add(
          CollageFreeItem(
            img: ni,
            rect: ui.Rect.fromLTWH(
              ((e['l'] as num?)?.toDouble() ?? 0.1).clamp(-0.5, 1.5),
              ((e['t'] as num?)?.toDouble() ?? 0.1).clamp(-0.5, 1.5),
              ((e['w'] as num?)?.toDouble() ?? 0.4).clamp(0.05, 2.0),
              ((e['h'] as num?)?.toDouble() ?? 0.4).clamp(0.05, 2.0),
            ),
          ),
        );
      }
      if (gone > 0 && mounted) showHint(context, '有 $gone 張照片已不在，已略過');
      if (mounted) setState(() {});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 返回鍵／返回手勢：匯出成功過就靜靜留草稿走人（跟影片、批次的
  /// _handleBack 同一條規矩）；其餘走離開保護
  void _handleBack() {
    if (_exportedOk) {
      // 匯出成功過的不再問：草稿留著，之後想改再從個人頁續作
      unawaited(_saveDraft());
      Navigator.of(context).pop();
      return;
    }
    unawaited(_confirmLeave());
  }

  /// 離開保護：畫布上有照片就問一下（跟其他編輯畫面同一套）
  Future<void> _confirmLeave() async {
    if (!_hasContent) {
      Navigator.of(context).pop();
      return;
    }
    final act = await showLeaveChoice(
      context,
      title: '這份拼圖還沒完成',
      // 全 App 統一的說法（使用者指定）
      message: '可以在個人頁面的「草稿」繼續未完成的編輯',
      keepLabel: '保留草稿',
    );
    if (!mounted) return;
    if (act == 'keep') {
      await _saveDraft();
      if (mounted) Navigator.of(context).pop();
    } else if (act == 'discard') {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(kCollageDraftKey);
      } catch (_) {}
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _load() async {
    if (widget.restore != null && await _restoreDraft(widget.restore!)) return;
    for (final f in widget.photos) {
      try {
        final img = await _decode(await f.readAsBytes());
        // 讀取途中使用者可能已經離開，這時 dispose 過了，
        // 再往清單裡塞就沒人會釋放它
        if (!mounted) {
          img.dispose();
          return;
        }
        _images.add(img);
        _srcPaths.add(f.path);
      } catch (_) {}
      if (_images.length >= _kMaxCells) break;
    }
    if (!mounted) return;
    _poolSize = _images.length;
    // 空手進場（從首頁直接點拼圖）：給一個 2×2 的空盤，
    // 使用者先挑宮格數再匯入照片。以前這裡會直接把人踢回上一頁
    if (_images.isEmpty) {
      setState(() {
        _cols = 2;
        _rows = 2;
        _resize();
      });
      return;
    }
    if (_images.length < 2) {
      showHint(context, '再加一張才拼得起來');
    }
    // 預設挑一個「剛好放得下」而且接近正方形的排法
    final n = math.max(2, _images.length);
    var cols = math.sqrt(n).ceil().clamp(1, _kMaxSide);
    var rows = (n / cols).ceil().clamp(1, _kMaxSide);
    if (cols * rows > _kMaxCells) rows = _kMaxCells ~/ cols;
    setState(() {
      _cols = cols;
      _rows = rows;
      _resize();
    });
  }

  /// 目前放了幾張照片
  int get _filled => _order.where((k) => k >= 0).length;

  /// 依目前欄列重建格子：照片夠就填，不夠的留空（畫面上顯示「＋」）
  void _resize() {
    final alive = [
      for (var k = 0; k < _images.length; k++)
        if (_images[k] != null) k,
    ];
    final keep = _order.take(_cellCount).toList();
    _order = List.generate(_cellCount, (n) {
      if (n < keep.length) return keep[n]; // 原本就有的格子維持不動
      final used = keep.toSet();
      final free = alive.where((x) => !used.contains(x)).toList();
      final extra = n - keep.length;
      return extra < free.length ? free[extra] : -1;
    });
    _fits = List.generate(
      _cellCount,
      (n) => n < _fits.length ? _fits[n] : CollageCellFit(),
    );
  }

  void _setGrid({int? cols, int? rows}) {
    final c = (cols ?? _cols).clamp(1, _kMaxSide);
    final r = (rows ?? _rows).clamp(1, _kMaxSide);
    if (c * r > _kMaxCells) {
      showHint(context, '最多 $_kMaxCells 格', error: true);
      return;
    }
    if (c == _cols && r == _rows) return;
    setState(() {
      _cols = c;
      _rows = r;
      _selCell = -1;
      // 換排法時把拖曳狀態歸零，避免殘留的格子編號超出範圍
      _dragFrom = -1;
      _dragPos = null;
      _dragOver = -1;
      _resize();
    });
  }

  /// 點空格子的「＋」：挑照片補進來（多選會依序補其他空格）
  Future<void> _fillCell(int cell) async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty || !mounted) return;
    var filled = 0;
    final failedNames = <String>[];
    for (final f in files) {
      try {
        final img = await _decode(await f.readAsBytes());
        // 解碼要好幾秒，這中間使用者可能換了排法／離開，
        // 用當初算好的索引會直接越界
        if (!mounted) {
          img.dispose();
          return;
        }
        final slot = _emptySlot(prefer: filled == 0 ? cell : -1);
        if (slot == -1) {
          img.dispose();
          break; // 沒有空格了
        }
        _images.add(img);
        _srcPaths.add(f.path);
        _order[slot] = _images.length - 1;
        _fits[slot] = CollageCellFit();
        filled++;
      } catch (_) {
        failedNames.add(f.name);
      }
    }
    if (!mounted) return;
    if (failedNames.isNotEmpty) {
      showHint(context, _decodeFailMsg(failedNames), error: true);
    }
    setState(() {});
  }

  /// 這一格現在顯示的照片（空格或已釋放都回 null）
  ui.Image? _imgAt(int cell) {
    if (cell < 0 || cell >= _order.length) return null;
    final idx = _order[cell];
    if (idx < 0 || idx >= _images.length) return null;
    return _images[idx];
  }

  /// 現在還空著的格子；prefer 若仍是空的就優先用它
  int _emptySlot({int prefer = -1}) {
    if (prefer >= 0 && prefer < _order.length && _order[prefer] == -1) {
      return prefer;
    }
    for (var i = 0; i < _order.length; i++) {
      if (_order[i] == -1) return i;
    }
    return -1;
  }

  /// 點格子＝選取（可調整）；再點同一格取消
  void _tapCell(int cell) {
    setState(() => _selCell = _selCell == cell ? -1 : cell);
  }

  /// 換一張照片（重新從相簿挑）：鎖定格子後點右上角按鈕
  Future<void> _replaceCell(int cell) async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (f == null || !mounted) return;
    try {
      // 換單張時給裁切：宮格是「貼齊格子」的排版，想強調照片裡的
      // 哪一塊只能先裁
      final raw = await f.readAsBytes();
      if (!mounted) return;
      final cut = await cropImage(context, raw);
      if (cut == null || !mounted) return;
      final img = await _decode(cut);
      // 選照片＋解碼期間排法可能被換掉，格子編號會失效
      if (!mounted || cell >= _order.length) {
        img.dispose();
        return;
      }
      setState(() {
        final old = _order[cell];
        _images.add(img);
        _srcPaths.add(f.path);
        _order[cell] = _images.length - 1;
        _fits[cell] = CollageCellFit();
        _selCell = cell;
        // 被換掉的那張若沒有別的格子在用就釋放，
        // 不然連換幾張就是好幾十 MB 掛在那裡等到離開才放
        _releaseIfUnused(old);
      });
    } catch (_) {
      if (mounted) {
        showHint(context, _decodeFailMsg([f.name]), error: true);
      }
    }
  }

  /// 釋放沒有任何格子在用的照片（一開始選進來的那批留著，
  /// 換版型時還要靠它們把格子填回去）
  void _releaseIfUnused(int idx) {
    if (idx < _poolSize || idx < 0 || idx >= _images.length) return;
    if (_order.contains(idx)) return;
    if (_items.any((t) => t.img == idx)) return; // 自由模式還在用
    _images[idx]?.dispose();
    _images[idx] = null;
    if (idx < _srcPaths.length) _srcPaths[idx] = null;
  }

  // ===== 自由模式：狀態操作 =====

  /// 切換宮格／自由。第一次切到自由時，用當下的宮格排列當起始位置
  /// ——使用者多半是先排個大概再想微調，從空白畫布重排一次太折騰。
  /// 之後來回切都各自保留（自由排好的不會因為看了一眼宮格就毀掉）
  void _setFree(bool v) {
    if (v == _free) return;
    setState(() {
      _free = v;
      _selCell = -1;
      _selItem = -1;
      _fDrag = null;
      _cancelHold();
      _dragFrom = -1;
      _dragPos = null;
      _dragOver = -1;
      if (v && _items.isEmpty) {
        for (var i = 0; i < _cellCount; i++) {
          if (_imgAt(i) == null) continue;
          _items.add(
            CollageFreeItem(
              img: _order[i],
              rect: ui.Rect.fromLTWH(
                (i % _cols) / _cols,
                (i ~/ _cols) / _rows,
                1 / _cols,
                1 / _rows,
              ),
            ),
          );
        }
      }
    });
  }

  /// 自由模式加照片：新的方塊疊在畫布中間，一張比一張錯開一點，
  /// 看得出來是好幾張（完全重疊的話會以為只進來一張）
  Future<void> _addFreePhotos() async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty || !mounted) return;
    final failedNames = <String>[];
    var added = 0;
    for (final f in files) {
      try {
        final img = await _decode(await f.readAsBytes());
        if (!mounted) {
          img.dispose();
          return;
        }
        _images.add(img);
        _srcPaths.add(f.path);
        // 方塊照照片比例開（寬 45% 畫布），太長太扁的夾一下。
        // 高度的比例座標要把畫布比例算進去，方塊才真的是照片的形狀
        final a = img.width / img.height;
        const w = 0.45;
        final h = (w * _canvasAspect / a).clamp(0.15, 0.8);
        final off = 0.04 * (_items.length % 5);
        _items.add(
          CollageFreeItem(
            img: _images.length - 1,
            rect: ui.Rect.fromLTWH(
              (0.5 - w / 2 + off).clamp(0.0, 1.0 - w),
              (0.5 - h / 2 + off).clamp(0.0, 1.0 - h),
              w,
              h,
            ),
          ),
        );
        added++;
      } catch (_) {
        failedNames.add(f.name);
      }
    }
    if (!mounted) return;
    if (failedNames.isNotEmpty) {
      showHint(context, _decodeFailMsg(failedNames), error: true);
    }
    if (added > 0) setState(() => _selItem = _items.length - 1);
  }

  /// 移除選取中的方塊（照片沒別人用就釋放）
  void _removeFreeItem() {
    if (_selItem < 0 || _selItem >= _items.length) return;
    setState(() {
      final idx = _items.removeAt(_selItem).img;
      _selItem = -1;
      _releaseIfUnused(idx);
    });
  }

  /// 拿到最上面（畫的順序＝疊的順序）。回傳搬完之後的索引
  int _bringToFront(int i) {
    if (i < 0 || i >= _items.length - 1) return i;
    final t = _items.removeAt(i);
    _items.add(t);
    return _items.length - 1;
  }

  /// 指尖落在哪個方塊上（從最上層找起）。
  /// 座標是比例值，寬高要各用各的邊換算（畫布不一定是正方形）
  int _freeHit(Offset p, Size s) {
    for (var i = _items.length - 1; i >= 0; i--) {
      final r = _items[i].rect;
      if (ui.Rect.fromLTWH(
        r.left * s.width,
        r.top * s.height,
        r.width * s.width,
        r.height * s.height,
      ).contains(p)) {
        return i;
      }
    }
    return -1;
  }

  /// 點擊用的命中：重疊處「再點一下」輪到下一層。
  /// 已選中的正好是最上層的命中時，回傳它下面那一張——疊在一起的
  /// 照片才選得到（使用者指定：加入後再點一下，選底下一層的照片）
  int _freeHitCycle(Offset p, Size s) {
    final hits = <int>[];
    for (var i = _items.length - 1; i >= 0; i--) {
      final r = _items[i].rect;
      if (ui.Rect.fromLTWH(
        r.left * s.width,
        r.top * s.height,
        r.width * s.width,
        r.height * s.height,
      ).contains(p)) {
        hits.add(i);
      }
    }
    if (hits.isEmpty) return -1;
    if (hits.length > 1 && hits.first == _selItem) return hits[1];
    return hits.first;
  }

  /// 指尖有沒有壓在選取框的某一角（回 0~3＝左上/右上/左下/右下）
  int _freeCorner(Offset p, Size s) {
    if (_selItem < 0 || _selItem >= _items.length) return -1;
    final r = _items[_selItem].rect;
    final cs = [
      Offset(r.left * s.width, r.top * s.height),
      Offset(r.right * s.width, r.top * s.height),
      Offset(r.left * s.width, r.bottom * s.height),
      Offset(r.right * s.width, r.bottom * s.height),
    ];
    for (var k = 0; k < 4; k++) {
      // 24px 的觸控範圍：角點本身只有 10px，照畫的大小抓根本按不到
      if ((p - cs[k]).distance <= 24) return k;
    }
    return -1;
  }

  /// 拖曳互換：由宮格座標算出落在哪一格（-1 = 界外）
  int _cellAt(Offset p) {
    final c = (p.dx / (_gCw + _gG)).floor();
    final r = (p.dy / (_gCh + _gG)).floor();
    if (c < 0 || c >= _cols || r < 0 || r >= _rows) return -1;
    final i = r * _cols + c;
    return i < _cellCount ? i : -1;
  }

  /// 放開＝落在別格就互換（照片跟取景一起換；拖到空格＝移過去）
  void _endDrag() {
    final from = _dragFrom;
    final to = _dragPos == null ? -1 : _cellAt(_dragPos!);
    setState(() {
      if (from >= 0 && from < _order.length && to != -1 && to != from) {
        final t = _order[from];
        _order[from] = _order[to];
        _order[to] = t;
        final f = _fits[from];
        _fits[from] = _fits[to];
        _fits[to] = f;
      }
      _dragFrom = -1;
      _dragPos = null;
      _dragOver = -1;
    });
  }

  /// 合成用的排法快照（清單直接引用畫面上的那幾份，不複製）
  CollageLayout _layout() => CollageLayout(
    free: _free,
    cols: _cols,
    rows: _rows,
    order: _order,
    fits: _fits,
    items: _items,
    canvasAspect: _canvasAspect,
    lines: _lines,
    gapN: _gapN,
    lineColor: _lineColor,
  );

  /// 畫布上有沒有照片（宮格：有格子放了照片；自由：有方塊）。
  /// 空格子隨時允許，只有「一張都沒有」才擋匯出
  bool get _hasPhotos => _free ? _items.isNotEmpty : _filled > 0;

  /// 匯出：先問格式（JPEG／PNG，跟照片、批次同一個視窗，只問這一個），
  /// 點了格式就直接匯出（選擇即確認，不再多一層）
  Future<void> _confirmExport() async {
    if (_exporting) return;
    if (!_hasPhotos) {
      showHint(context, '先加幾張照片再匯出', error: true);
      return;
    }
    final fmt = await askPhotoFormat(context);
    if (fmt == null || !mounted) return;
    await _export(jpeg: fmt == 'jpg');
  }

  /// 拼圖＋浮水印一次合成（PNG 透明處保持透明；JPEG 沒有透明，空格子
  /// 鋪黑底，見 collage_compose.dart），走照片共用的編碼＋存相簿那條路
  ///（photo_export.dart），完成後跟照片／批次一樣問下一步
  Future<void> _export({required bool jpeg}) async {
    if (_exporting || !_hasPhotos) return;
    setState(() => _exporting = true);
    // PopScope：不擋的話返回鍵會把進度框關掉，
    // 匯出完成後那個 pop 就會把「拼圖頁本身」關掉，排好的全沒了
    var dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('匯出中…'),
          content: SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    ).then((_) => dialogOpen = false);
    // 讓進度框先畫出來再開始重活（PNG 編碼在 web 會卡主執行緒）
    await Future<void>.delayed(const Duration(milliseconds: 40));
    if (!mounted) return;

    String message;
    String? note;
    var ok = true;
    try {
      final image = await composeCollage(
        _layout(),
        _images,
        watermark: _wm,
        // JPEG 沒有透明，空格子鋪黑；PNG 留透明（跟預覽的棋盤格說法一致）
        background: jpeg ? const ui.Color(0xFF000000) : null,
      );
      // 編碼＋存檔跟照片、批次同一條路（原生 ImageIO 直出 → BMP 快路 →
      // Skia PNG，見 photo_export.dart）；PNG 保留透明
      final String ext;
      try {
        (message, ext) = await savePhotoImage(
          image,
          jpeg: jpeg,
          quality: 92,
          name: 'watermarker_${DateTime.now().millisecondsSinceEpoch}',
        );
      } finally {
        image.dispose();
      }
      // 這句是次要說明，不要接在主訊息後面變成一長串括號
      if (jpeg && ext == 'png') note = '這個裝置不支援 JPEG，已改存 PNG';
    } catch (e) {
      message = '匯出失敗：$e';
      ok = false;
    }
    if (ok) {
      // 匯出成功＝靜靜留一份草稿、之後離開不再問（跟批次同一條規矩）。
      // 這裡就存：回主畫面那條路（popUntil）不會經過 _handleBack
      _exportedOk = true;
      unawaited(_saveDraft());
    }

    if (!mounted) return;
    // 只有進度框還開著才 pop，不然會把拼圖頁本身關掉。
    // rootNavigator：showDialog 開在 root，pop 也要對同一個 navigator
    if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
    setState(() => _exporting = false);
    if (!ok) {
      showHint(context, message, error: true);
      return;
    }
    // 成功：問要回主畫面還是留下來繼續改
    final act = await askAfterExport(context, message, note: note);
    if (act == 'home' && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  /// 設定卡（版本 B）：左標籤右內容，「版型」「格線」兩列一張卡
  Widget _settingsCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(
                width: kSliderLabelW,
                child: Text(
                  '模式',
                  style: TextStyle(fontSize: 12, color: kTextDim),
                ),
              ),
              _modeChip('宮格', !_free, () => _setFree(false)),
              const SizedBox(width: 8),
              _modeChip('自由', _free, () => _setFree(true)),
              const Spacer(),
              if (_free) ...[
                if (_selItem >= 0 && _selItem < _items.length)
                  _freeAction(Icons.delete_outline, '移除', _removeFreeItem),
                const SizedBox(width: 8),
                _freeAction(
                  Icons.add_photo_alternate_outlined,
                  '加照片',
                  _addFreePhotos,
                ),
              ],
            ],
          ),
          // 畫布比例兩種模式都能選：宮格就是把選的比例等分
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 8),
            color: kBorder,
          ),
          Row(
            children: [
              const SizedBox(
                width: kSliderLabelW,
                child: Text(
                  '畫布',
                  style: TextStyle(fontSize: 12, color: kTextDim),
                ),
              ),
              // 五顆膠囊排不下窄螢幕，讓它自己捲
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (label, a) in _kAspects) ...[
                        _modeChip(
                          label,
                          (_canvasAspect - a).abs() < 0.01,
                          () => setState(() => _canvasAspect = a),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (!_free) ...[
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(vertical: 8),
              color: kBorder,
            ),
            Row(
              children: [
                const SizedBox(
                  width: kSliderLabelW,
                  child: Text(
                    '版型',
                    style: TextStyle(fontSize: 12, color: kTextDim),
                  ),
                ),
                _stepper('欄', _cols, (v) => _setGrid(cols: v)),
                const SizedBox(width: 10),
                _stepper('列', _rows, (v) => _setGrid(rows: v)),
                // 「N 格」不顯示（使用者指定）：欄×列本身就講完了
              ],
            ),
          ],
          if (!_free)
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(vertical: 8),
              color: kBorder,
            ),
          if (!_free)
            Row(
              children: [
                const SizedBox(
                  width: kSliderLabelW,
                  child: Text(
                    '格線',
                    style: TextStyle(fontSize: 12, color: kTextDim),
                  ),
                ),
                SizedBox(
                  width: 42,
                  height: 26,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: Switch(
                      value: _lines,
                      onChanged: (v) => setState(() => _lines = v),
                    ),
                  ),
                ),
                if (_lines) ...[
                  const SizedBox(width: 8),
                  for (final c in const [
                    0xFFFFFFFF,
                    0xFF000000,
                    0xFF9E9EA6,
                    0xFFFFC24B,
                  ])
                    _lineSwatch(c),
                  // 調色盤：想要什麼顏色都能挑
                  Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _pickLineColor,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const SweepGradient(
                            colors: [
                              Color(0xFFE57373),
                              Color(0xFFFFC24B),
                              Color(0xFF81C784),
                              Color(0xFF64B5F6),
                              Color(0xFFBA68C8),
                              Color(0xFFE57373),
                            ],
                          ),
                          border: Border.all(color: kBorder),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SizedBox(
                      height: 30,
                      child: Slider(
                        value: _gapN,
                        min: 0.001,
                        max: 0.05,
                        onChanged: (v) => setState(() => _gapN = v),
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
              ],
            ),
        ],
      ),
    );
  }

  /// 宮格／自由的切換膠囊
  Widget _modeChip(String label, bool on, VoidCallback onTap) => InkWell(
    borderRadius: BorderRadius.circular(999),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: on ? kSelect.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: on ? kSelect : kClipBorder),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: on ? FontWeight.w700 : FontWeight.w400,
          color: on ? kSelect : kTextDim,
        ),
      ),
    ),
  );

  /// 自由模式的小動作鈕（加照片、移除）
  Widget _freeAction(IconData icon, String label, VoidCallback onTap) =>
      InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: kText),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(fontSize: 11.5, color: kText)),
            ],
          ),
        ),
      );

  /// 欄／列的加減。到達上限時該側按鈕變灰，不是消失——
  /// 按鈕位置跳動比按不下去更難用
  Widget _stepper(String label, int value, ValueChanged<int> onChange) {
    Widget btn(IconData icon, int delta, bool enabled) => InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: enabled ? () => onChange(value + delta) : null,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 17, color: enabled ? kText : kBorder),
      ),
    );
    final other = label == '欄' ? _rows : _cols;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kClipBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 3, right: 5),
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: kTextDim),
            ),
          ),
          btn(Icons.remove, -1, value > 1),
          SizedBox(
            width: 18,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: kText,
              ),
            ),
          ),
          btn(
            Icons.add,
            1,
            value < _kMaxSide && (value + 1) * other <= _kMaxCells,
          ),
        ],
      ),
    );
  }

  /// 調色盤挑格線顏色（跟浮水印文字的顏色挑選同一套）
  Future<void> _pickLineColor() async {
    final picked = await pickColor(context, Color(_lineColor), title: '格線顏色');
    final ok = picked != null;
    final color = Color(picked ?? 0);
    if (ok == true && mounted) {
      setState(() => _lineColor = color.toARGB32());
    }
  }

  Widget _lineSwatch(int c) {
    final on = _lineColor == c;
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => setState(() => _lineColor = c),
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: Color(c),
            shape: BoxShape.circle,
            border: Border.all(
              color: on ? kSelect : kBorder,
              width: on ? 2 : 1,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 鍵盤打開時（浮水印分頁打字）把預覽收起來：不收的話面板被擠成
    // 一條縫，文字輸入框整個藏在鍵盤後面（批次那頁實測回報過）
    final kbOpen = MediaQuery.of(context).viewInsets.bottom > 60;
    final tab = _tab;
    // 不包 SwipeBack：拖曳格子互換會誤觸右滑返回、被踢回首頁。
    // 離開保護：匯出成功過靜靜留草稿；否則畫布上有照片就先問
    //（保留草稿／捨棄，見 _handleBack）
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) _handleBack();
      },
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(backgroundColor: kBg),
        body: _cols == 0
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: [
                    // 三個分頁共用同一個預覽（跟影片編輯器一樣，預覽永遠
                    // 在上面）。浮水印分頁上 4 下 5：面板是主要工作區
                    //（跟批次同一個比例）；另外兩頁底下只有一張卡，
                    // 預覽拿剩下的全部
                    if (!kbOpen)
                      Expanded(
                        flex: tab == _kTabWatermark ? 4 : 1,
                        child: _buildPreview(tab),
                      ),
                    if (tab == _kTabCollage) ..._collageTabBody(),
                    if (tab == _kTabWatermark) _buildWatermarkTab(),
                    if (tab == _kTabExport) _buildExportTab(),
                  ],
                ),
              ),
        bottomNavigationBar: _cols == 0 ? null : _bottomNav(),
      ),
    );
  }

  /// 底部分頁列：跟影片編輯器的剪輯／浮水印／匯出同一款（同樣式、
  /// 同高度、同字級；選中轉琥珀）
  Widget _bottomNav() => Container(
    color: kBg,
    child: SafeArea(
      top: false,
      child: TabBar(
        controller: _tabs,
        // 已經在匯出分頁再按一次「匯出」＝直接開始匯出（跟影片編輯器
        // 同一個手感）。indexIsChanging＝從別的分頁切過來的那一下，
        // 那不算第二次
        onTap: (i) {
          if (i == _kTabExport && !_tabs.indexIsChanging && !_exporting) {
            _confirmExport();
          }
        },
        indicatorColor: Colors.transparent,
        dividerHeight: 0,
        // 選中分頁跟浮水印面板同一套語言：字＋圖示直接轉琥珀
        labelColor: kSelect,
        unselectedLabelColor: kTextDim,
        labelStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          fontFamily: 'NotoSansTC',
        ),
        unselectedLabelStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.3,
          fontFamily: 'NotoSansTC',
        ),
        tabs: const [
          Tab(
            icon: Icon(Icons.grid_view, size: 20),
            text: '拼圖',
            height: 54,
            iconMargin: EdgeInsets.only(bottom: 2),
          ),
          Tab(
            icon: Icon(Icons.branding_watermark, size: 20),
            text: '浮水印',
            height: 54,
            iconMargin: EdgeInsets.only(bottom: 2),
          ),
          Tab(
            icon: Icon(Icons.ios_share, size: 20),
            text: '匯出',
            height: 54,
            iconMargin: EdgeInsets.only(bottom: 2),
          ),
        ],
      ),
    ),
  );

  /// 預覽：拼圖畫布＋浮水印圖層，三個分頁同一個。
  /// 拼圖分頁：拼圖吃手勢（拖曳互換、鎖定調構圖），浮水印只是看得到；
  /// 浮水印分頁反過來——拼圖不吃手勢，浮水印圖層可拖／捏合／點選
  ///（選取框、置中輔助線、選取路由全照批次那一頁的接法）；匯出分頁純看
  Widget _buildPreview(int tab) {
    final wmTab = tab == _kTabWatermark;
    final canvas = AspectRatio(
      // 畫布比例兩種模式共用（宮格＝把它等分）
      aspectRatio: _canvasAspect,
      child: Stack(
        fit: StackFit.expand,
        // 不裁切：浮水印選取框要能畫到畫面外
        clipBehavior: Clip.none,
        children: [
          IgnorePointer(
            ignoring: tab != _kTabCollage,
            child: _free ? _buildFree() : _buildGrid(),
          ),
          // 浮水印圖層：拼圖分頁「點得到、拖不動」——點到浮水印框內就
          // 選起來並切到浮水印分頁（使用者指定）；拖曳鎖住，不然會跟
          // 格子的拖曳打架。匯出分頁純看。圖層的觸控區只有部件本身那塊
          //（opaque），框外的觸控照樣落到底下的格子
          IgnorePointer(
            ignoring: tab == _kTabExport,
            child: WatermarkLayer(
              settings: _wm,
              // 選取框畫在裁切外（見 _wmFrameInfo）
              frameNotifier: _wmFrameInfo,
              onChanged: () => setState(() {}),
              selectedPart: wmTab ? _wmPartAlive : WmPart.none,
              onSelectPart: (p) {
                setState(() => _wmPart = p);
                if (!wmTab) {
                  // 從拼圖分頁點到浮水印：帶著選取一起過去
                  _tabs.animateTo(_kTabWatermark);
                  return;
                }
                _wmPanelCtrl.scrollTo(p);
              },
              panLocked: () => !wmTab || _pvPts.length >= 2,
            ),
          ),
          if (wmTab) ...[
            // 置中輔助線。在浮水印分頁裡永遠插著、不要用 if 增減：線一
            // 出現會把後面手勢層的索引推掉，拖曳被中斷後又從已吸附的
            // 中線重新開始，就再也拖不出來了（其他編輯畫面同一種寫法）
            Positioned.fill(
              child: CenterGuides(vertical: _btGuideV, horizontal: _btGuideH),
            ),
            // 浮水印選取框：畫在真實位置（拖出畫面也看得到）
            Positioned.fill(child: WmFrameOverlay(_wmFrameInfo)),
            // 選取路由：有部件被選取時，整個預覽的拖曳都只動被選的那個
            // ——手指滑過另一個部件才不會把它一起拖走
            if (_wmPartAlive != WmPart.none)
              Positioned.fill(child: _wmSelectionRouter()),
          ],
        ],
      ),
    );
    final body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 點畫布外的黑邊＝取消選取。窄長畫布（9:16）兩側一大片留白，
      // 點那裡沒反應會以為選取卡住了。浮水印分頁取消的是部件選取
      //（不取消的話另一個部件會永遠拖不動）
      onTap: () {
        if (wmTab) {
          _clearWmSel();
          return;
        }
        setState(() {
          _selItem = -1;
          _selCell = -1;
        });
      },
      child: Center(
        child: Padding(padding: const EdgeInsets.all(16), child: canvas),
      ),
    );
    if (!wmTab) return body;
    // 雙指縮放浮水印（跟照片、批次同一套，用 Listener 不搶單指拖曳）
    return Listener(
      onPointerDown: _pinchDown,
      onPointerMove: _pinchMove,
      onPointerUp: (e) => _pinchUp(e.pointer),
      onPointerCancel: (e) => _pinchUp(e.pointer),
      child: body,
    );
  }

  /// 選取路由（照批次那頁）：有部件被選取時，整個預覽的拖曳都只動被選
  /// 的那個。點空白＝取消選取
  Widget _wmSelectionRouter() => LayoutBuilder(
    builder: (context, box) => GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 點空白＝取消選取；點在被選部件的框裡＝維持選取。這層在圖層之上
      // 且 translucent，點到部件時它的 tap 會贏過圖層自己的 tap——
      // 不看座標的話「點一下浮水印」反而變成取消選取
      onTapUp: (d) {
        final r = _wmFrameInfo.value?.rect;
        if (r != null && r.contains(d.localPosition)) return;
        _clearWmSel();
      },
      onPanStart: (_) {
        if (_pvPts.length >= 2) return;
        _btRawX = null;
        _btRawY = null;
      },
      onPanUpdate: (d) {
        if (_pvPts.length >= 2) return;
        final part = _wmPartAlive;
        if (part != WmPart.text && part != WmPart.logo) return;
        final mark = part == WmPart.text
            ? (x: _wm.text.x, y: _wm.text.y)
            : (x: _wm.logo.x, y: _wm.logo.y);
        // 累加在「未吸附」的原始座標上，顯示值才吸中線
        _btRawX ??= mark.x;
        _btRawY ??= mark.y;
        _btRawX = (_btRawX! + d.delta.dx / box.maxWidth).clamp(0.0, 1.0);
        _btRawY = (_btRawY! + d.delta.dy / box.maxHeight).clamp(0.0, 1.0);
        final sx = _snapC(_btRawX!);
        final sy = _snapC(_btRawY!);
        setState(() {
          if (part == WmPart.text) {
            _wm.text.x = sx;
            _wm.text.y = sy;
          } else {
            _wm.logo.x = sx;
            _wm.logo.y = sy;
          }
        });
        _btSetGuides(sx, sy);
      },
      onPanEnd: (_) => _btClearGuides(),
      onPanCancel: _btClearGuides,
      child: const SizedBox.expand(),
    ),
  );

  /// 拼圖分頁：設定卡＋一行提示。原本底下那顆「完成」／「匯入照片」
  /// 大鈕拿掉了——上浮水印是隔壁分頁、匯出再隔壁，
  /// 補照片點格子的「＋」（自由模式用卡上的「加照片」）
  List<Widget> _collageTabBody() => [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: _settingsCard(),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Text(
        _free ? '最後選取的照片會在最上層' : '按住可拖曳交換照片位置；點一下鎖定 可調照片顯示位置',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, color: kTextDim),
      ),
    ),
  ];

  /// 浮水印分頁：共用的設定面板（跟批次同一套接法）；
  /// 底部疊一段漸層淡出，內容是淡出去、不是被底欄硬切
  Widget _buildWatermarkTab() => Expanded(
    flex: 5,
    child: Column(
      children: [
        Container(height: 1, color: kBorder),
        Expanded(
          child: Stack(
            children: [
              WatermarkPanel(
                controller: _wmPanelCtrl,
                settings: _wm,
                // 九宮格「貼邊」要知道畫布比例才夾得準
                canvasAspect: _canvasAspect,
                // 剛加的圖片直接選起來，可以馬上拖／縮放
                onLogoAdded: () => setState(() => _wmPart = WmPart.logo),
                // 面板裡點縮圖／文字＝畫面上也選它。沒有這一段，面板亮框
                // 的圖片在預覽上拖不動：文字圖層畫在圖片之上且 opaque，
                // 重疊處的手指全被文字吃掉，而「選取路由」又只在有選取
                // 時才掛上來
                onSelectPart: (p) => setState(() => _wmPart = p),
                onChanged: () => setState(() {}),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 32,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [kBg.withValues(alpha: 0), kBg],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  /// 匯出分頁：跟影片編輯器的匯出分頁同一種列（標籤左、值右）＋
  /// 同一顆匯出鈕。格式（JPEG／PNG）按下去才問，只問那一個
  Widget _buildExportTab() {
    final l = _layout();
    final (w, h) = collageCanvasSize(l, collageLongSide(l));
    final aspect = _kAspects
        .firstWhere(
          (a) => (a.$2 - _canvasAspect).abs() < 0.01,
          orElse: () => ('自訂', _canvasAspect),
        )
        .$1;
    final photos = _free ? _items.length : _filled;
    Widget row(String label, String value, {bool divider = true}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 15),
      decoration: divider
          ? const BoxDecoration(
              border: Border(bottom: BorderSide(color: kBorder)),
            )
          : null,
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: kText,
            ),
          ),
          const SizedBox(width: 12),
          // 值比標籤小一階也更淡：標籤是「這一列在講什麼」，值是內容
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: kTextDim,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row('畫布', '$aspect·$w×$h'),
          row('照片', photos == 0 ? '還沒放照片' : '$photos 張', divider: false),
          const SizedBox(height: 14),
          primaryAction(
            label: '匯出',
            onPressed: _exporting ? null : _confirmExport,
          ),
        ],
      ),
    );
  }

  // ===== 預覽區雙指縮放浮水印（跟照片、批次同一套）=====
  final Map<int, Offset> _pvPts = {};
  double? _pvBaseDist;
  double _pvBaseText = 0;
  double _pvBaseLogo = 0;

  void _pinchDown(PointerDownEvent e) {
    _pvPts[e.pointer] = e.position;
    if (_pvPts.length != 2) return;
    final p = _pvPts.values.toList();
    final d = (p[0] - p[1]).distance;
    if (d <= 20) return;
    _pvBaseDist = d;
    _pvBaseText = _wm.text.sizeFrac;
    _pvBaseLogo = _wm.logo.sizeFrac;
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pvPts.containsKey(e.pointer)) return;
    _pvPts[e.pointer] = e.position;
    if (_pvBaseDist == null || _pvPts.length < 2) return;
    final p = _pvPts.values.toList();
    final f = (p[0] - p[1]).distance / _pvBaseDist!;
    setState(() {
      final t = _wm.text;
      final hasText = t.enabled && t.text.trim().isNotEmpty;
      final hasLogo = _wm.logo.enabled;
      // 有選取就只縮被選的那個（跟其他編輯畫面一致）；
      // 都沒選而且兩個都在才一起縮
      final part = _wmPartAlive;
      final doText = hasText && (part != WmPart.logo || !hasLogo);
      final doLogo = hasLogo && (part != WmPart.text || !hasText);
      if (doText) t.sizeFrac = (_pvBaseText * f).clamp(0.015, 2.0);
      if (doLogo) _wm.logo.sizeFrac = (_pvBaseLogo * f).clamp(0.03, 2.0);
    });
  }

  void _pinchUp(int pointer) {
    _pvPts.remove(pointer);
    if (_pvBaseDist != null && _pvPts.length < 2) _pvBaseDist = null;
  }

  // ===== 置中吸附與輔助線（跟影片／照片／批次同一套手感）=====
  //
  // 拖曳時記「未吸附」的原始座標：直接把吸完的值當下一刻的起點，
  // 單次手指位移永遠小於吸附半徑，就再也拖不出中線了
  double? _btRawX, _btRawY;
  bool _btGuideV = false, _btGuideH = false;
  bool _btSnapped = false;

  double _snapC(double v) => (v - 0.5).abs() < 0.015 ? 0.5 : v;

  void _btSetGuides(double x, double y) {
    final v = x == 0.5, hh = y == 0.5;
    if (v != _btGuideV || hh != _btGuideH) {
      setState(() {
        _btGuideV = v;
        _btGuideH = hh;
      });
    }
    final on = v || hh;
    if (on != _btSnapped) {
      _btSnapped = on;
      if (on) HapticFeedback.selectionClick(); // 吸上去震一下
    }
  }

  void _btClearGuides() {
    _btRawX = null;
    _btRawY = null;
    _btSnapped = false;
    if (_btGuideV || _btGuideH) {
      setState(() {
        _btGuideV = false;
        _btGuideH = false;
      });
    }
  }

  Widget _buildGrid() {
    final (count, cols, rows) = (_cellCount, _cols, _rows);
    return LayoutBuilder(
      builder: (context, box) {
        // 畫布比例由外層的 AspectRatio 決定（不再鎖 1:1），
        // 這裡拿到多寬多高就等分多寬多高。
        // 純格線：格子貼齊排滿，線條疊在照片上面畫，
        // 不用背景填色（背景填色會從空格、邊緣露出來）
        final cw = box.maxWidth / cols;
        final ch = box.maxHeight / rows;
        _gG = 0;
        _gCw = cw;
        _gCh = ch;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < count; i++)
              Positioned(
                left: (i % cols) * cw,
                top: (i ~/ cols) * ch,
                width: cw,
                height: ch,
                child: _cell(i, cw, ch),
              ),
            if (_lines)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _GridLinePainter(
                      cols: cols,
                      rows: rows,
                      t: _gapN * box.maxWidth,
                      color: Color(_lineColor),
                    ),
                  ),
                ),
              ),
            // 拖曳互換中：浮起的縮圖跟著指尖走
            if (_dragFrom >= 0 && _imgAt(_dragFrom) != null && _dragPos != null)
              Positioned(
                left: _dragPos!.dx - cw * 0.3,
                top: _dragPos!.dy - ch * 0.3,
                width: cw * 0.6,
                height: ch * 0.6,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.85,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: kSelect, width: 2),
                      ),
                      child: ClipRect(
                        child: CustomPaint(
                          painter: _CellPainter(
                            img: _imgAt(_dragFrom)!,
                            src: collageSrcRect(
                              _imgAt(_dragFrom)!,
                              _fits[_dragFrom],
                              cw / ch,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // ===== 自由模式：手勢與畫布 =====

  void _freePanStart(Offset p, Size s) {
    // 先看角：角落的觸控範圍常常同時落在方塊裡，
    // 先判斷方塊的話就永遠拉不到角
    final corner = _freeCorner(p, s);
    if (corner != -1) {
      _fDrag = _FreeDrag(corner: corner, start: _items[_selItem].rect, from: p);
      return;
    }
    final hit = _freeHit(p, s);
    if (hit == -1) {
      _fDrag = null;
      return;
    }
    setState(() => _selItem = _bringToFront(hit));
    _fDrag = _FreeDrag(corner: -1, start: _items[_selItem].rect, from: p);
  }

  /// 吸附中的輔助線位置（比例座標；null＝這一軸沒吸到）
  double? _guideX, _guideY;

  /// 吸附的候選線：畫布的邊與中線＋其他方塊的邊。
  /// 照片跟照片要能貼齊，靠的就是別人的邊也在候選裡
  (List<double>, List<double>) _snapCands() {
    final xs = [0.0, 0.5, 1.0];
    final ys = [0.0, 0.5, 1.0];
    for (var i = 0; i < _items.length; i++) {
      if (i == _selItem) continue;
      final o = _items[i].rect;
      xs
        ..add(o.left)
        ..add(o.right);
      ys
        ..add(o.top)
        ..add(o.bottom);
    }
    return (xs, ys);
  }

  /// 這一軸最近的吸附修正量：edges 是方塊上會動的邊，吸到候選線
  /// 就回（要補的位移, 吸到哪條線）；都太遠回（0, null）
  (double, double?) _snapAxis(
    List<double> edges,
    List<double> cands,
    double th,
  ) {
    var best = 0.0;
    double? line;
    var bestD = th;
    for (final e in edges) {
      for (final c in cands) {
        final dd = (c - e).abs();
        if (dd < bestD) {
          bestD = dd;
          best = c - e;
          line = c;
        }
      }
    }
    return (best, line);
  }

  void _freePanUpdate(Offset p, Size s) {
    final d = _fDrag;
    if (d == null || _selItem < 0 || _selItem >= _items.length) return;
    final dx = (p.dx - d.from.dx) / s.width;
    final dy = (p.dy - d.from.dy) / s.height;
    final r = d.start;
    // 吸附門檻：螢幕 8px。用比例座標比會隨畫布大小忽鬆忽緊
    final thx = 8 / s.width;
    final thy = 8 / s.height;
    final (xCands, yCands) = _snapCands();
    ui.Rect nr;
    double? gx, gy;
    if (d.corner == -1) {
      // 移動：中心不准出畫布，方塊才不會被丟到找不回來
      nr = r.shift(Offset(dx, dy));
      nr = ui.Rect.fromCenter(
        center: Offset(
          nr.center.dx.clamp(0.0, 1.0),
          nr.center.dy.clamp(0.0, 1.0),
        ),
        width: nr.width,
        height: nr.height,
      );
      // 磁鐵：左右邊與中線去吸候選線，吸到就整塊平移過去
      final (sx, lx) = _snapAxis(
        [nr.left, nr.right, nr.center.dx],
        xCands,
        thx,
      );
      final (sy, ly) = _snapAxis(
        [nr.top, nr.bottom, nr.center.dy],
        yCands,
        thy,
      );
      nr = nr.shift(Offset(sx, sy));
      gx = lx;
      gy = ly;
    } else {
      // 拉某一角：對角不動。可以拉出畫布一些（出血構圖），
      // 但不能小到抓不到（0.08 ≈ 手指的大小）
      const mn = 0.08;
      var l = r.left, t = r.top, rr = r.right, b = r.bottom;
      if (d.corner == 0 || d.corner == 2) {
        l = (r.left + dx).clamp(-0.5, rr - mn);
        final (sx, lx) = _snapAxis([l], xCands, thx);
        if ((l + sx) < rr - mn) l += sx;
        gx = lx;
      } else {
        rr = (r.right + dx).clamp(l + mn, 1.5);
        final (sx, lx) = _snapAxis([rr], xCands, thx);
        if ((rr + sx) > l + mn) rr += sx;
        gx = lx;
      }
      if (d.corner == 0 || d.corner == 1) {
        t = (r.top + dy).clamp(-0.5, b - mn);
        final (sy, ly) = _snapAxis([t], yCands, thy);
        if ((t + sy) < b - mn) t += sy;
        gy = ly;
      } else {
        b = (r.bottom + dy).clamp(t + mn, 1.5);
        final (sy, ly) = _snapAxis([b], yCands, thy);
        if ((b + sy) > t + mn) b += sy;
        gy = ly;
      }
      nr = ui.Rect.fromLTRB(l, t, rr, b);
    }
    // 剛吸上去的那一刻輕震一下（跟時間軸磁鐵同一個手感；web 是無感）
    if ((gx != null && gx != _guideX) || (gy != null && gy != _guideY)) {
      HapticFeedback.selectionClick();
    }
    setState(() {
      _items[_selItem].rect = nr;
      _guideX = gx;
      _guideY = gy;
    });
  }

  /// 手勢結束：收掉進行中的拖曳與吸附輔助線
  void _endFreeDrag() {
    _fDrag = null;
    if (_guideX != null || _guideY != null) {
      setState(() {
        _guideX = null;
        _guideY = null;
      });
    }
  }

  Widget _buildFree() {
    return LayoutBuilder(
      builder: (context, box) {
        final s = Size(box.maxWidth, box.maxHeight);
        final sel = (_selItem >= 0 && _selItem < _items.length)
            ? _items[_selItem]
            : null;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (e) => setState(() {
            // 重疊處再點一下＝輪到下一層（選到誰誰就被帶到最上層，
            // 跟「最後選取的照片會在最上層」一致）
            final hit = _freeHitCycle(e.localPosition, s);
            _selItem = hit == -1 ? -1 : _bringToFront(hit);
          }),
          onPanStart: (e) => _freePanStart(e.localPosition, s),
          onPanUpdate: (e) => _freePanUpdate(e.localPosition, s),
          onPanEnd: (_) => _endFreeDrag(),
          onPanCancel: _endFreeDrag,
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: kBorder)),
            clipBehavior: Clip.antiAlias,
            // 底改棋盤格＝把「這塊是透明的」講清楚：匯出 PNG 就是透明（JPEG 空格鋪黑）
            //（以前預覽用面板色、匯出卻烙白底，兩邊說法不一致）
            child: CustomPaint(
              painter: const CheckerPainter(),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _FreePainter(items: _items, images: _images),
                    ),
                  ),
                  if (_items.isEmpty)
                    const Center(
                      child: Text(
                        '點「加照片」開始自由組圖',
                        style: TextStyle(fontSize: 12, color: kTextDim),
                      ),
                    ),
                  if (sel != null) ..._freeSelection(sel, s),
                  // 吸附輔助線：吸到哪條線就把那條畫出來，
                  // 不然使用者只覺得「怎麼卡了一下」
                  if (_guideX != null)
                    Positioned(
                      left: _guideX! * s.width - 0.5,
                      top: 0,
                      bottom: 0,
                      width: 1,
                      child: const IgnorePointer(
                        child: ColoredBox(color: kSelect),
                      ),
                    ),
                  if (_guideY != null)
                    Positioned(
                      top: _guideY! * s.height - 0.5,
                      left: 0,
                      right: 0,
                      height: 1,
                      child: const IgnorePointer(
                        child: ColoredBox(color: kSelect),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 選取框＋四個角點（都不吃事件：拖曳判斷在畫布那層做，
  /// 這裡吃掉的話拉角會變成拉不動）
  List<Widget> _freeSelection(CollageFreeItem it, Size s) {
    final r = Rect.fromLTWH(
      it.rect.left * s.width,
      it.rect.top * s.height,
      it.rect.width * s.width,
      it.rect.height * s.height,
    );
    Widget dot(double x, double y) => Positioned(
      left: x - 5,
      top: y - 5,
      child: IgnorePointer(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: kSelect, width: 2),
          ),
        ),
      ),
    );
    return [
      Positioned(
        left: r.left,
        top: r.top,
        width: r.width,
        height: r.height,
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: kSelect, width: 2),
            ),
          ),
        ),
      ),
      dot(r.left, r.top),
      dot(r.right, r.top),
      dot(r.left, r.bottom),
      dot(r.right, r.bottom),
    ];
  }

  Widget _cell(int i, double cellW, double cellH) {
    final img = _imgAt(i);
    // 空格子：一個「＋」，點了挑照片補進來（拖照片過來也行）
    if (img == null) {
      final over = _dragFrom != -1 && _dragOver == i;
      return GestureDetector(
        onTap: () => _fillCell(i),
        child: Container(
          decoration: BoxDecoration(
            color: kPanel,
            border: over
                ? Border.all(color: kSelect, width: 2.5)
                : Border.all(color: kBorder),
          ),
          child: const Center(
            child: Icon(Icons.add, size: 30, color: kTextDim),
          ),
        ),
      );
    }
    final selected = _selCell == i;
    final fit = _fits[i];
    // 這格在宮格座標裡的左上角（拖曳換算指尖位置用）
    final origin = Offset(
      (i % _cols) * (_gCw + _gG),
      (i ~/ _cols) * (_gCh + _gG),
    );
    // 螢幕位移 → 來源像素位移的換算比
    double dispScale() => cellW / collageSrcRect(img, fit, cellW / cellH).width;
    return Listener(
      // 雙指縮放：判斷用「有沒有格子被選」而不是「這一格被選」——
      // 撐開時第二指多半落在隔壁格，用後者的話常常整個沒反應
      onPointerDown: (e) {
        _pts[e.pointer] = e.position;
        if (_selCell != -1 && _pts.length == 2) {
          final p = _pts.values.toList();
          _baseDist = (p[0] - p[1]).distance;
          _baseZoom = _fits[_selCell].zoom;
        }
      },
      onPointerMove: (e) {
        if (!_pts.containsKey(e.pointer)) return;
        _pts[e.pointer] = e.position;
        if (_selCell != -1 && _baseDist != null && _pts.length >= 2) {
          final p = _pts.values.toList();
          final f = (p[0] - p[1]).distance / _baseDist!;
          final sf = _fits[_selCell];
          setState(() {
            sf.zoom = (_baseZoom * f).clamp(1.0, 4.0);
            final si = _imgAt(_selCell);
            if (si != null) collageClampFit(si, sf, cellW / cellH);
          });
        }
      },
      onPointerUp: (e) {
        _pts.remove(e.pointer);
        if (_pts.length < 2) _baseDist = null;
      },
      onPointerCancel: (e) {
        _pts.remove(e.pointer);
        if (_pts.length < 2) _baseDist = null;
      },
      // 桌面：滾輪縮放選取中的格子
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent || !selected) return;
        setState(() {
          fit.zoom = (fit.zoom * (e.scrollDelta.dy > 0 ? 1 / 1.07 : 1.07))
              .clamp(1.0, 4.0);
        });
      },
      child: GestureDetector(
        onTap: () => _tapCell(i),
        // 沒選取的格子：按住 200ms 才拿得起來（成立時震一下＋亮框），
        // 之後拖到哪一格就跟哪一格互換。選取中的格子單指拖曳是移動構圖，
        // 不進這條路
        onPanDown: selected
            ? null
            : (d) {
                _holdPos = origin + d.localPosition;
                _cancelHold();
                _holdTimer = Timer(_kHoldDelay, () {
                  if (!mounted) return;
                  // 兩指在畫面上＝在縮放別格的構圖，不是要搬照片。
                  // 第二指常常落在隔壁格，不擋的話那一格會被拿起來
                  if (_pts.length >= 2) return;
                  // 成立的那一刻給回饋：不震一下、不亮框的話，
                  // 使用者不知道已經按夠久、可以開始移動了
                  HapticFeedback.mediumImpact();
                  setState(() {
                    _dragFrom = i;
                    _dragPos = _holdPos;
                    _dragOver = i;
                  });
                });
              },
        // 還沒按滿就開始滑＝不是要搬照片，把計時器收掉
        onPanStart: selected ? null : (_) => _cancelHold(),
        onPanUpdate: (d) {
          if (_pts.length >= 2) return;
          if (selected) {
            final k = dispScale();
            setState(() {
              fit.panX -= d.delta.dx / k;
              fit.panY -= d.delta.dy / k;
              // 夾回可移動範圍：不夾的話拖到底之後還會一直累積，
              // 往回拖時要先抵銷那幾百 px，畫面看起來像卡住
              collageClampFit(img, fit, cellW / cellH);
            });
          } else if (_dragFrom == i) {
            setState(() {
              _dragPos = origin + d.localPosition;
              _dragOver = _cellAt(_dragPos!);
            });
          }
        },
        onPanEnd: selected
            ? null
            : (_) {
                _cancelHold();
                _endDrag();
              },
        onPanCancel: selected
            ? null
            : () {
                _cancelHold();
                setState(() {
                  _dragFrom = -1;
                  _dragPos = null;
                  _dragOver = -1;
                });
              },
        child: Container(
          foregroundDecoration: selected
              ? BoxDecoration(border: Border.all(color: kSelect, width: 2))
              // 被拿起來的那一格：亮框留在原位，看得出正在搬的是誰
              : _dragFrom == i
              ? BoxDecoration(border: Border.all(color: kSelect, width: 2.5))
              : (_dragFrom != -1 && _dragOver == i && _dragFrom != i)
              ? BoxDecoration(
                  border: Border.all(color: kSelect, width: 2.5),
                  color: kSelect.withValues(alpha: 0.15),
                )
              : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRect(
                child: CustomPaint(
                  size: Size(cellW, cellH),
                  painter: _CellPainter(
                    img: img,
                    src: collageSrcRect(img, fit, cellW / cellH),
                  ),
                ),
              ),
              // 鎖定中：右上角「換照片」鈕
              // （長按跟拖曳在手機上會互相搶，改用按鈕最不會誤觸）
              if (selected)
                Positioned(
                  right: 6,
                  top: 6,
                  child: GestureDetector(
                    onTap: () => _replaceCell(i),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.cached,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 純格線：畫在照片上面的細線（直的 cols-1 條、橫的 rows-1 條）
class _GridLinePainter extends CustomPainter {
  final int cols;
  final int rows;
  final double t;
  final Color color;

  const _GridLinePainter({
    required this.cols,
    required this.rows,
    required this.t,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    final cw = size.width / cols;
    final ch = size.height / rows;
    for (var c = 1; c < cols; c++) {
      canvas.drawRect(Rect.fromLTWH(c * cw - t / 2, 0, t, size.height), p);
    }
    for (var r = 1; r < rows; r++) {
      canvas.drawRect(Rect.fromLTWH(0, r * ch - t / 2, size.width, t), p);
    }
  }

  @override
  bool shouldRepaint(_GridLinePainter old) =>
      old.cols != cols || old.rows != rows || old.t != t || old.color != color;
}

/// 自由模式進行中的手勢：corner -1＝整塊移動，0~3＝拉哪一角。
/// 起手時記下方塊位置，之後只看指尖總位移（見 GIF 把手的教訓：
/// 拿上一幀畫出來的值當基準會自己餵自己，抖）
class _FreeDrag {
  final int corner;
  final ui.Rect start;
  final Offset from;

  _FreeDrag({required this.corner, required this.start, required this.from});
}

/// 自由模式的畫布：照清單順序畫（後面的疊上面）。
/// 取景（置中 cover）跟匯出同一個算法：collageCoverSrc
class _FreePainter extends CustomPainter {
  final List<CollageFreeItem> items;
  final List<ui.Image?> images;

  const _FreePainter({required this.items, required this.images});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..filterQuality = FilterQuality.medium;
    for (final it in items) {
      final img = (it.img >= 0 && it.img < images.length)
          ? images[it.img]
          : null;
      if (img == null) continue;
      final dst = Rect.fromLTWH(
        it.rect.left * size.width,
        it.rect.top * size.height,
        it.rect.width * size.width,
        it.rect.height * size.height,
      );
      canvas.drawImageRect(
        img,
        collageCoverSrc(img, dst.width / dst.height),
        dst,
        p,
      );
    }
  }

  // rect 是直接改在 CollageFreeItem 上的，新舊 painter 比不出差異——
  // 這頁只有拖曳時會 setState，每次都重畫是對的
  @override
  bool shouldRepaint(_FreePainter old) => true;
}

/// 依取景窗畫出這一格的照片
class _CellPainter extends CustomPainter {
  final ui.Image img;
  final ui.Rect src;

  const _CellPainter({required this.img, required this.src});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      img,
      src,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CellPainter old) => old.img != img || old.src != src;
}
