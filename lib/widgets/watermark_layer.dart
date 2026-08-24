import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../models/watermark_settings.dart';
import '../services/text_mark_painter.dart';
import '../theme.dart';

/// 疊在預覽畫面上的浮水印圖層：單指拖曳調位置、雙指捏合調大小。
/// 大小以「佔畫面寬度比例」計算，跟輸出時的算法一致，所見即所得。
/// 元素會自動夾在畫面內：太長的文字靠邊也不會超出去（匯出同一套規則）。
/// 浮水印的兩個獨立部件
enum WmPart { none, text, logo }

class WatermarkLayer extends StatefulWidget {
  final WatermarkSettings settings;
  final VoidCallback onChanged;

  /// 開始拖曳（父層拿來拍「上一步」快照）
  final VoidCallback? onDragStart;

  /// 選取到哪一個部件：被選的那個外圍畫白框，縮放也只動它。
  /// 文字和圖片是兩個獨立的東西，一起縮放會把調好的搭配弄壞
  final WmPart selectedPart;

  /// 點到哪個部件（父層拿來記選取）
  final ValueChanged<WmPart>? onSelectPart;

  /// 點浮水印元素（父層拿來設定選取）
  final VoidCallback? onTap;

  /// 點浮水印「文字」時另外觸發（父層拿來直接開文字輸入）；
  /// 沒給就退回 onTap
  final VoidCallback? onTapText;

  /// 回報這一刻文字／圖片畫在哪（父層拿去判斷點擊落在誰身上）。
  /// [textBoxes] 跟 settings.texts、[logoBoxes] 跟 settings.logos
  /// 一一對應，沒畫出來的是 null。
  /// 在 build 裡呼叫，父層只能存起來，不可以 setState
  final void Function(List<Rect?> textBoxes, List<Rect?> logoBoxes)? onHitBox;

  /// 給了這個就不在圖層內畫選取框，改成把「被選部件的框」回報出去，
  /// 由外層的 [WmFrameOverlay] 在「不裁切的圖層」畫。
  ///
  /// 為什麼要繞這一圈：部件可以拖出畫面（超出的內容被裁掉是對的），
  /// 但琥珀框要照畫在真實位置，人才知道它跑到哪去了——框畫在圖層內
  /// 會跟內容一起被裁掉，整個看不見
  final ValueNotifier<WmFrameInfo?>? frameNotifier;

  /// 目前播放時間（秒）；動畫預覽用，靜態畫面給 null
  final double? time;

  /// 回傳 true 時暫停單指拖曳。
  /// 兩指捏合縮放時，其中一指滑過別的元素會把它拖走——
  /// 捏合期間要把拖曳整個鎖住
  final bool Function()? panLocked;

  /// 回傳 false 時該部件完全不註冊拖曳（只留點選）。
  /// 父層在「別的素材被選取」時用這個把拖曳讓給選中的素材
  final bool Function(WmPart part)? panAllowed;

  const WatermarkLayer({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onDragStart,
    this.selectedPart = WmPart.none,
    this.onSelectPart,
    this.onTap,
    this.onTapText,
    this.onHitBox,
    this.frameNotifier,
    this.time,
    this.panLocked,
    this.panAllowed,
  });

  @override
  State<WatermarkLayer> createState() => _WatermarkLayerState();
}

class _WatermarkLayerState extends State<WatermarkLayer> {
  // 捏合縮放的起點值

  /// 選取框（只畫在被選的那個部件上）。圖片有很多張時，
  /// 只有「操作中」的那張要畫框——每張都畫等於沒有選取這回事。
  ///
  /// 一定要用 foregroundDecoration 掛：Container 的 decoration 會把
  /// 邊框寬度算進內距，選取／取消選取的瞬間內容就位移 1.4px——
  /// 那正是「移好位置後點別的東西，浮水印會稍微跳一下」
  BoxDecoration? _deco(WmPart part, {int logoIndex = -1, int textIndex = -1}) {
    // 外層接手畫框（見 frameNotifier）就不在圖層內畫
    if (widget.frameNotifier != null) return null;
    if (widget.selectedPart != part) return null;
    if (part == WmPart.logo &&
        logoIndex >= 0 &&
        logoIndex != widget.settings.activeLogo) {
      return null;
    }
    if (part == WmPart.text &&
        textIndex >= 0 &&
        textIndex != widget.settings.activeText) {
      return null;
    }
    // 琥珀而不是白：這個框疊的是使用者的照片／影片，白框落在白色縮圖
    // 或亮背景上會整個看不見
    return BoxDecoration(border: Border.all(color: kSelect, width: 1.4));
  }

  /// 這個部件現在能不能拖：
  /// 有部件被選取時只有被選的能拖；父層說不行（別的素材選取中）就不行。
  /// 回 false 時連手勢都不註冊，拖曳會落到下層的「選取路由」去
  bool _canDrag(WmPart part) {
    if (widget.selectedPart != WmPart.none && widget.selectedPart != part) {
      return false;
    }
    return widget.panAllowed?.call(part) ?? true;
  }

  /// 正在拖哪個部件（畫置中輔助線用）
  WmPart _panning = WmPart.none;

  // 置中輔助線的共用元件在檔尾：CenterGuides

  /// 上一刻有沒有吸在中線上（吸上去的瞬間震一下）
  bool _centerSnapped = false;

  /// 拖曳期間「未吸附」的原始座標。吸附只作用在顯示值上——
  /// 若直接把吸完的值當下一刻的起點，單次手指位移永遠小於吸附半徑,
  /// 吸上中線後就再也拖不出來（會一直被吸回去）
  double _rawX = 0, _rawY = 0;

  /// 拖曳時把座標吸到置中線（0.5）附近；回傳吸完的值
  double _snapCenter(double v) {
    if ((v - 0.5).abs() < 0.015) return 0.5;
    return v;
  }

  void _feedbackCenter(double x, double y) {
    final on = x == 0.5 || y == 0.5;
    if (on != _centerSnapped) {
      _centerSnapped = on;
      if (on) HapticFeedback.selectionClick();
    }
  }

  /// 文字尺寸量測快取：拖曳中每一次指尖移動都會重建這一層，
  /// 文字沒變就不要每幀重新排版一次（長文字一次要 1~3ms，會吃掉幀）
  Size _probeSize = Size.zero;
  List<Object?>? _probeKey;

  Size _measureText(TextMark t, double fontSize) {
    final key = [t.text, t.fontFamily, fontSize, t.spacing];
    if (_probeKey != null && listEquals(_probeKey!, key)) return _probeSize;
    final tp = TextPainter(
      text: TextSpan(
        text: t.text,
        style: TextStyle(
          fontFamily: t.fontFamily,
          fontSize: fontSize,
          letterSpacing: fontSize * t.spacing,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _probeKey = key;
    _probeSize = Size(tp.width, tp.height);
    return _probeSize;
  }

  /// 圖片的長寬比（寬/高），一張一格。匯出是用實際高度來置中與算圓角，
  /// 預覽若拿寬度當高度用，非正方形的圖位置就會跟成品差一截。
  /// 以 bytes 為 key：同一張圖被幾個地方共用時只量一次
  final Map<Uint8List, double> _aspects = {};

  double _logoAspectOf(Uint8List bytes) {
    final known = _aspects[bytes];
    if (known != null) return known;
    // 還沒量到先當正方形，量好了再重畫
    _aspects[bytes] = 1;
    ui
        .instantiateImageCodec(bytes)
        .then((c) => c.getNextFrame())
        .then((f) {
          final a = f.image.width / f.image.height;
          f.image.dispose();
          if (!mounted) return;
          if ((a - (_aspects[bytes] ?? 1)).abs() > 0.001) {
            setState(() => _aspects[bytes] = a);
          }
        })
        .catchError((_) {});
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final onChanged = widget.onChanged;
    final onDragStart = widget.onDragStart;
    final onTap = widget.onTap;
    final onTapText = widget.onTapText;
    final time = widget.time;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        // 動畫（只在有時間軸的畫面生效）
        final anim = time == null
            ? (dx: 0.0, dy: 0.0, alpha: 1.0)
            : settings.animAt(time);
        final children = <Widget>[];
        // 這一輪畫出來的位置，最後回報給父層
        final hitTexts = List<Rect?>.filled(settings.texts.length, null);
        final hitLogos = List<Rect?>.filled(settings.logos.length, null);

        // 圖片可以放很多張：照清單順序畫，後加的疊在前面的上面。
        // 碰到哪一張就把它設成「操作中」（settings.activeLogo），
        // 面板、捏合縮放、選取框全部跟著它走
        for (var li = 0; li < settings.logos.length; li++) {
          final logo = settings.logos[li];
          final logoBytes = logo.bytes;
          if (!logo.enabled || logoBytes == null) continue;
          // 滿版平鋪：整面重複，不能拖曳（位置無意義）
          if (logo.tiled) {
            children.add(
              Positioned.fill(
                child: IgnorePointer(child: _TiledLogo(logo: logo)),
              ),
            );
            continue;
          }
          // 大小以「短邊」為基準：同一個範本套到 16:9 或 9:16，
          // 看起來的比例才會一樣（用寬的話直式/橫式差超多）
          final logoW = logo.sizeFrac * math.min(w, h);
          // 高度要用實際長寬比算，跟匯出同一套；
          // 拿寬度當高度的話非正方形 Logo 會上下偏掉
          final logoH = logoW / _logoAspectOf(logoBytes);
          // 不夾限：可以一路拖出畫面。超出的部分由預覽的裁切自然切掉
          //（匯出同一套規則），還留在畫面內的那一角連同琥珀選取框
          // 會看得到，知道它跑到哪去了
          final left = logo.x * w - logoW / 2;
          final top = logo.y * h - logoH / 2;
          hitLogos[li] = Rect.fromLTWH(left, top, logoW, logoH);
          void makeActive() => settings.activeLogo = li;
          children.add(
            Positioned(
              left: left,
              top: top,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  makeActive();
                  widget.onSelectPart?.call(WmPart.logo);
                  onTap?.call();
                },
                // 雙擊＝回正中央、恢復預設大小。
                // 允許拖到畫面外，拖丟了本來只能去面板拉滑桿救
                onDoubleTap: () {
                  makeActive();
                  onDragStart?.call(); // 先拍快照
                  logo.x = 0.5;
                  logo.y = 0.5;
                  logo.sizeFrac = 0.18;
                  onChanged();
                },
                // 單指拖＝移動（雙指縮放由預覽層的 Listener 處理：
                // 元素本身範圍太小，兩指張開時第二指會落在範圍外）
                onPanStart: !_canDrag(WmPart.logo)
                    ? null
                    : (_) {
                        if (widget.panLocked?.call() ?? false) return;
                        makeActive();
                        _rawX = logo.x;
                        _rawY = logo.y;
                        setState(() => _panning = WmPart.logo);
                        onDragStart?.call();
                      },
                onPanUpdate: !_canDrag(WmPart.logo)
                    ? null
                    : (d) {
                        if (widget.panLocked?.call() ?? false) return;
                        // 手指位置累積在原始座標上；顯示值才吸中線,
                        // 拖離吸附半徑就自然脫離
                        _rawX = (_rawX + d.delta.dx / w).clamp(0.0, 1.0);
                        _rawY = (_rawY + d.delta.dy / h).clamp(0.0, 1.0);
                        logo.x = _snapCenter(_rawX);
                        logo.y = _snapCenter(_rawY);
                        _feedbackCenter(logo.x, logo.y);
                        onChanged();
                      },
                onPanEnd: !_canDrag(WmPart.logo)
                    ? null
                    : (_) => setState(() => _panning = WmPart.none),
                onPanCancel: !_canDrag(WmPart.logo)
                    ? null
                    : () => setState(() => _panning = WmPart.none),
                // 選取框放在旋轉「裡面」：框才會跟著 Logo 轉
                //（文字那邊本來就是這樣，兩邊要一致）
                child: Opacity(
                  opacity: logo.opacity,
                  child: Transform.rotate(
                    angle: logo.rotation * math.pi / 180,
                    child: Container(
                      foregroundDecoration: _deco(WmPart.logo, logoIndex: li),
                      child: ClipRRect(
                        // 圓角基準跟匯出一致：短邊
                        borderRadius: BorderRadius.circular(
                          logo.corner * math.min(logoW, logoH) / 2,
                        ),
                        child: Image.memory(
                          logoBytes,
                          width: logoW,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        // 文字可以放很多個（跟圖片同一套）：照清單順序畫，
        // 碰到哪一個就把它設成「操作中」（settings.activeText）
        for (var ti = 0; ti < settings.texts.length; ti++) {
          final t = settings.texts[ti];
          // 滿版平鋪（棋盤格）：整面重複，不能拖曳（位置無意義）
          if (t.enabled && t.text.trim().isNotEmpty && t.tiled) {
            children.add(
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _TiledTextPainter(t, math.min(w, h)),
                  ),
                ),
              ),
            );
          } else if (t.enabled && t.text.trim().isNotEmpty) {
            // 不自動換行、也不自動縮小：使用者調多大就多大，
            // 超出畫面是允許的（跟匯出同一套規則）
            final fontSize = t.sizeFrac * math.min(w, h); // 短邊基準

            final probe = _measureText(t, fontSize);

            // 開底色時外框會往外長一圈 padding，Positioned 的原點是
            // 「含底色的框」；不先扣掉的話文字會被推到右下，
            // 跟匯出（底色往外擴、文字不動）差一個 padding
            final padH = t.bg ? fontSize * 0.35 * t.bgPad : 0.0;
            final padV = t.bg ? fontSize * 0.18 * t.bgPad : 0.0;
            // 不夾限（理由同 Logo）
            final boxW = probe.width + padH * 2;
            final boxH = probe.height + padV * 2;
            final left = t.x * w - probe.width / 2 - padH;
            final top = t.y * h - probe.height / 2 - padV;
            // 框比量到的字再放寬一點點。
            //
            // TextPainter 回的是「行高」，而不少字型的墨水會超出行高
            //（粉圓這種圓體最明顯，筆畫的圓頭往上下多凸一截）——照行高
            // 畫框，字就會壓在框線上、甚至凸出去。放寬只動框與點擊範圍，
            // 文字本身的位置一個像素都沒變，跟匯出還是對得上
            final inkH = fontSize * 0.07;
            final inkW = fontSize * 0.04;
            hitTexts[ti] = Rect.fromLTWH(
              left - inkW,
              top - inkH,
              boxW + inkW * 2,
              boxH + inkH * 2,
            );
            void makeActive() => settings.activeText = ti;

            children.add(
              Positioned(
                left: left,
                top: top,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    makeActive();
                    widget.onSelectPart?.call(WmPart.text);
                    (onTapText ?? onTap)?.call();
                  },
                  // 雙擊＝回正中央、恢復預設大小（同 Logo）
                  onDoubleTap: () {
                    makeActive();
                    onDragStart?.call();
                    t.x = 0.5;
                    t.y = 0.5;
                    t.sizeFrac = 0.12;
                    onChanged();
                  },
                  // 單指拖＝移動（雙指縮放由預覽層的 Listener 處理）
                  onPanStart: !_canDrag(WmPart.text)
                      ? null
                      : (_) {
                          if (widget.panLocked?.call() ?? false) return;
                          makeActive();
                          _rawX = t.x;
                          _rawY = t.y;
                          setState(() => _panning = WmPart.text);
                          onDragStart?.call();
                        },
                  onPanUpdate: !_canDrag(WmPart.text)
                      ? null
                      : (d) {
                          if (widget.panLocked?.call() ?? false) return;
                          // 手指位置累積在原始座標上；顯示值才吸中線,
                          // 拖離吸附半徑就自然脫離
                          _rawX = (_rawX + d.delta.dx / w).clamp(0.0, 1.0);
                          _rawY = (_rawY + d.delta.dy / h).clamp(0.0, 1.0);
                          t.x = _snapCenter(_rawX);
                          t.y = _snapCenter(_rawY);
                          _feedbackCenter(t.x, t.y);
                          onChanged();
                        },
                  onPanEnd: !_canDrag(WmPart.text)
                      ? null
                      : (_) => setState(() => _panning = WmPart.none),
                  onPanCancel: !_canDrag(WmPart.text)
                      ? null
                      : () => setState(() => _panning = WmPart.none),
                  child: Transform.rotate(
                    angle: t.rotation * math.pi / 180,
                    child: Container(
                      foregroundDecoration: _deco(WmPart.text, textIndex: ti),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: padH,
                          vertical: padV,
                        ),
                        decoration: t.bg
                            ? BoxDecoration(
                                color: t.bgColor.withValues(alpha: t.bgOpacity),
                                borderRadius: BorderRadius.circular(
                                  fontSize * t.bgCorner,
                                ),
                              )
                            : null,
                        // 內容＝共用畫家 paintMarkGlyphs：跟匯出執行
                        // 同一段程式碼，預覽即成品；同步繪製，
                        // 滑桿/拖曳即時零延遲
                        child: CustomPaint(
                          size: Size(probe.width, probe.height),
                          painter: MarkGlyphPainter(t, fontSize),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
        }

        // 置中輔助線：拖曳中吸在中線上時，畫出垂直／水平線
        if (_panning != WmPart.none) {
          final p = _panning == WmPart.text ? settings.text : null;
          final lgP = _panning == WmPart.logo ? settings.logo : null;
          final px = p?.x ?? lgP?.x;
          final py = p?.y ?? lgP?.y;
          if (px == 0.5) {
            children.add(
              Positioned(
                left: w / 2 - 0.5,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    width: 1,
                    color: kSelect.withValues(alpha: 0.9),
                  ),
                ),
              ),
            );
          }
          if (py == 0.5) {
            children.add(
              Positioned(
                top: h / 2 - 0.5,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 1,
                    color: kSelect.withValues(alpha: 0.9),
                  ),
                ),
              ),
            );
          }
        }

        // 動畫會整組位移，回報的框也要跟著移，不然點擊判定跟看到的錯開
        final shift = Offset(anim.dx * w, anim.dy * h);
        widget.onHitBox?.call(
          [for (final r in hitTexts) r?.shift(shift)],
          [for (final r in hitLogos) r?.shift(shift)],
        );

        // 被選部件的框回報給外層畫（見 frameNotifier 的說明）
        final fn = widget.frameNotifier;
        if (fn != null) {
          WmFrameInfo? info;
          if (widget.selectedPart == WmPart.text) {
            final ai = settings.activeText;
            final r = (ai >= 0 && ai < hitTexts.length) ? hitTexts[ai] : null;
            if (r != null) {
              info = WmFrameInfo(r.shift(shift), settings.texts[ai].rotation);
            }
          } else if (widget.selectedPart == WmPart.logo) {
            final ai = settings.activeLogo;
            final r = (ai >= 0 && ai < hitLogos.length) ? hitLogos[ai] : null;
            if (r != null) {
              info = WmFrameInfo(r.shift(shift), settings.logos[ai].rotation);
            }
          }
          // build 中不能動 notifier（會連鎖 setState），排到這一格畫完
          if (fn.value != info) {
            final want = info;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (fn.value != want) fn.value = want;
            });
          }
        }

        // 動畫：整組浮水印一起位移＋淡出（閃爍＝alpha 0/1）
        if (anim.dx != 0 || anim.dy != 0 || anim.alpha != 1) {
          return Opacity(
            opacity: anim.alpha.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(anim.dx * w, anim.dy * h),
              child: Stack(children: children),
            ),
          );
        }
        return Stack(children: children);
      },
    );
  }
}

/// Logo 滿版平鋪：解碼一次，之後用 CustomPaint 重複畫
class _TiledLogo extends StatefulWidget {
  final LogoMark logo;

  const _TiledLogo({required this.logo});

  @override
  State<_TiledLogo> createState() => _TiledLogoState();
}

class _TiledLogoState extends State<_TiledLogo> {
  ui.Image? _img;
  Uint8List? _decodedFrom;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(_TiledLogo old) {
    super.didUpdateWidget(old);
    if (widget.logo.bytes != _decodedFrom) _decode();
  }

  void _decode() {
    final b = widget.logo.bytes;
    if (b == null) return;
    _decodedFrom = b;
    ui.decodeImageFromList(b, (img) {
      if (mounted) setState(() => _img = img);
    });
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _TiledLogoPainter(widget.logo, _img));
  }
}

/// Logo 平鋪的排列（跟匯出 WatermarkRenderer 同一套邏輯）
class _TiledLogoPainter extends CustomPainter {
  final LogoMark logo;
  final ui.Image? img;

  /// 面板是「原地改同一個物件」，比 reference 永遠相等，
  /// shouldRepaint 就永遠回 false → 拉滑桿預覽完全不動。
  /// 把影響畫面的值抄一份出來比
  final List<Object?> _sig;

  _TiledLogoPainter(this.logo, this.img)
    : _sig = [logo.sizeFrac, logo.opacity, logo.rotation, logo.corner];

  @override
  void paint(Canvas canvas, Size size) {
    final im = img;
    if (im == null) return;
    final w = size.width;
    final h = size.height;
    final targetW = logo.sizeFrac * math.min(w, h); // 短邊基準
    final targetH = targetW * im.height / im.width;
    final stepX = targetW * 1.8;
    final stepY = targetH * 1.9;
    final src = Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble());
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Colors.white.withValues(alpha: logo.opacity);

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (logo.rotation.abs() > 0.01) {
      canvas.translate(w / 2, h / 2);
      canvas.rotate(logo.rotation * math.pi / 180);
      canvas.translate(-w / 2, -h / 2);
    }
    var row = 0;
    for (var y = -h; y < h * 2; y += stepY, row++) {
      final shift = row.isOdd ? stepX / 2 : 0.0;
      for (var x = -w - shift; x < w * 2; x += stepX) {
        final rect = Rect.fromLTWH(x, y, targetW, targetH);
        if (logo.corner > 0.01) {
          final r = logo.corner * math.min(targetW, targetH) / 2;
          canvas.save();
          canvas.clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
          canvas.drawImageRect(im, src, rect, paint);
          canvas.restore();
        } else {
          canvas.drawImageRect(im, src, rect, paint);
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TiledLogoPainter old) =>
      old.img != img || !listEquals(old._sig, _sig);
}

/// 滿版平鋪浮水印：跟匯出（WatermarkRenderer）同一套排列邏輯
class _TiledTextPainter extends CustomPainter {
  final TextMark t;
  final double canvasW; // 字級基準：呼叫端傳畫面短邊 min(w,h)，跟匯出一致

  /// 同 _TiledLogoPainter：物件是原地改的，要比值不能比 reference
  final List<Object?> _sig;

  _TiledTextPainter(this.t, this.canvasW)
    : _sig = [
        t.text,
        t.fontFamily,
        t.sizeFrac,
        t.spacing,
        t.colorValue,
        t.opacity,
        t.rotation,
        t.shadow,
        t.shadowOpacity,
        t.shadowBlur,
        t.outline,
        t.outlineWidth,
        t.outlineColorValue,
        t.bg,
        t.bgPad,
        t.bgCorner,
        t.bgColorValue,
        t.bgOpacity,
      ];

  @override
  void paint(Canvas canvas, Size size) {
    final fontSize = t.sizeFrac * canvasW;
    // 字形交給共用畫家 paintMarkGlyphs（跟匯出同一段程式碼）；
    // 這裡只管平鋪的步進、底色與旋轉
    final m = measureMark(t, fontSize);
    final w = size.width;
    final h = size.height;
    final stepX = m.width + fontSize * 2.2;
    final stepY = m.height + fontSize * 2.6;
    final padH = fontSize * 0.35 * t.bgPad;
    final padV = fontSize * 0.18 * t.bgPad;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (t.rotation.abs() > 0.01) {
      canvas.translate(w / 2, h / 2);
      canvas.rotate(t.rotation * math.pi / 180);
      canvas.translate(-w / 2, -h / 2);
    }
    var row = 0;
    for (var y = -h; y < h * 2; y += stepY, row++) {
      final shift = row.isOdd ? stepX / 2 : 0.0;
      for (var x = -w - shift; x < w * 2; x += stepX) {
        if (t.bg) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                x - padH,
                y - padV,
                m.width + padH * 2,
                m.height + padV * 2,
              ),
              Radius.circular(fontSize * t.bgCorner),
            ),
            Paint()..color = t.bgColor.withValues(alpha: t.bgOpacity),
          );
        }
        paintMarkGlyphs(canvas, t, fontSize, Offset(x, y));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TiledTextPainter old) =>
      old.canvasW != canvasW || !listEquals(old._sig, _sig);
}

/// 置中輔助線（琥珀色細線）：各編輯器在拖曳吸到中線時疊在預覽上。
/// WatermarkLayer 自己的拖曳有內建，這個給「選取路由」等外部拖曳共用
class CenterGuides extends StatelessWidget {
  final bool vertical; // 吸在垂直中線（x == 0.5）
  final bool horizontal; // 吸在水平中線（y == 0.5）

  const CenterGuides({
    super.key,
    required this.vertical,
    required this.horizontal,
  });

  @override
  Widget build(BuildContext context) {
    const line = kSelect;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (vertical)
            Center(
              child: Container(width: 1, color: line.withValues(alpha: 0.9)),
            ),
          if (horizontal)
            Center(
              child: Container(height: 1, color: line.withValues(alpha: 0.9)),
            ),
        ],
      ),
    );
  }
}

/// 透明底的棋盤格。做浮水印時底色如果是純黑或純白，跟浮水印同色的
/// 邊緣會整個看不見——棋盤格才分得出「這張圖的邊到哪裡」
class CheckerPainter extends CustomPainter {
  const CheckerPainter({this.cell = 12});

  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    final a = Paint()..color = const Color(0xFF2A2A30);
    final b = Paint()..color = const Color(0xFF1B1B20);
    canvas.drawRect(Offset.zero & size, a);
    // 格數取整、格子大小跟著微調：固定 12px 一路鋪過去的話，
    // 畫布邊長不是 12 的倍數時最後一排會剩半截格子，邊緣看起來缺一角
    final nx = math.max(1, (size.width / cell).round());
    final ny = math.max(1, (size.height / cell).round());
    final cw = size.width / nx;
    final ch = size.height / ny;
    for (var iy = 0; iy < ny; iy++) {
      for (var ix = 0; ix < nx; ix++) {
        if ((ix + iy).isEven) continue;
        canvas.drawRect(Rect.fromLTWH(ix * cw, iy * ch, cw, ch), b);
      }
    }
  }

  @override
  bool shouldRepaint(CheckerPainter old) => old.cell != cell;
}

/// 被選取的浮水印部件在畫面上的框（圖層座標）＋旋轉角度
class WmFrameInfo {
  const WmFrameInfo(this.rect, this.rotation);

  final Rect rect;
  final double rotation;

  @override
  bool operator ==(Object other) =>
      other is WmFrameInfo && other.rect == rect && other.rotation == rotation;

  @override
  int get hashCode => Object.hash(rect, rotation);
}

/// 把 [WmFrameInfo] 畫成琥珀選取框的外層圖層。
///
/// 掛在「不會被裁切」的地方（畫布 Stack 要 clipBehavior: Clip.none）：
/// 部件拖出畫面時內容照樣被圖層自己的 Stack 裁掉，但這個框畫在真實
/// 位置——超出畫面的部分也看得到，人才知道東西跑到哪去了
class WmFrameOverlay extends StatelessWidget {
  const WmFrameOverlay(this.info, {super.key});

  final ValueNotifier<WmFrameInfo?> info;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<WmFrameInfo?>(
        valueListenable: info,
        builder: (context, f, _) {
          if (f == null) return const SizedBox.shrink();
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fromRect(
                rect: f.rect,
                child: Transform.rotate(
                  angle: f.rotation * math.pi / 180,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: kSelect, width: 1.4),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 旋轉吸附的輔助線：吸在整數角度時，畫一條穿過中心的斜線與角度標。
/// 只有「正在吸住」時才畫（[deg] 為 null 就整個不出現）
class RotGuidePainter extends CustomPainter {
  final double? deg;

  const RotGuidePainter(this.deg);

  @override
  void paint(Canvas canvas, Size size) {
    final d = deg;
    if (d == null) return;
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.sqrt(size.width * size.width + size.height * size.height);
    final a = d * math.pi / 180;
    final v = Offset(math.cos(a), math.sin(a));
    canvas.drawLine(
      c - v * r,
      c + v * r,
      Paint()
        ..color = kSelect.withValues(alpha: 0.9)
        ..strokeWidth = 1,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: '${d.round()}°',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: kSelect,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c + const Offset(8, -18));
  }

  @override
  bool shouldRepaint(RotGuidePainter old) => old.deg != deg;
}
