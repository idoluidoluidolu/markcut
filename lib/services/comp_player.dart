import 'dart:io';

import 'package:flutter/services.dart';

import '../models/timeline.dart';
import 'diagnostics.dart';
import 'media_prep.dart';

/// Metal 預覽引擎（滑動/暫停接管；見 AppDelegate 的
/// MetalPreviewEngine）。組不了或平台不支援一律回 false，
/// 呼叫端照舊走合成播放器路
class MetalPreview {
  /// 引擎目前有沒有在畫（Dart 端的顯示開關跟它走）
  static bool active = false;

  static Future<bool> build(Map<String, dynamic> payload) async {
    try {
      return await CompPlayer._ch.invokeMethod<bool>('mbuild', payload) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> show(bool on) async {
    try {
      await CompPlayer._ch.invokeMethod<void>('mshow', on);
    } catch (_) {}
  }

  static Future<void> seek(double t) async {
    try {
      await CompPlayer._ch.invokeMethod<void>('mseek', t);
    } catch (_) {}
  }

  /// 播放接管：引擎自己的時鐘＋每軌 pump 起播。回 false＝佈局
  /// 沒建成，呼叫端照舊讓合成播放器出畫面
  static Future<bool> play(double t) async {
    try {
      return await CompPlayer._ch.invokeMethod<bool>('mplay', t) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 停播（畫面停在停點那格；讓位時機由呼叫端決定）。
  /// 回傳引擎的精確停點（秒）：讓位 exact seek 必須用它——
  /// 音訊時鐘的位置差幾十 ms，讓位瞬間畫面會跳半格（136「暫停抖」）
  static Future<double?> stopPlay() async {
    try {
      final t = await CompPlayer._ch.invokeMethod<double>('mstop');
      return t;
    } catch (_) {
      return null;
    }
  }

  /// 影片圖層重新綁定到現役播放器（見原生 PlayerHosts.reassert）
  static Future<void> reattach() async {
    try {
      await CompPlayer._ch.invokeMethod<void>('reattach');
    } catch (_) {}
  }

  /// 引擎實測統計（tick/掉格/渲染耗時/供格 miss）——診斷用
  static Future<Map<dynamic, dynamic>?> stats() async {
    try {
      return await CompPlayer._ch.invokeMethod<Map<dynamic, dynamic>>('mstats');
    } catch (_) {
      return null;
    }
  }

  /// 泊車：播放起跑前把引擎的 pump（每軌一台 AVPlayer＋解碼器）
  /// 全放掉，別跟合成播放器搶硬體。暫停後懶建自動重建
  static Future<void> park() async {
    try {
      await CompPlayer._ch.invokeMethod<void>('mpark');
    } catch (_) {}
  }

  /// [t] 這一刻引擎畫面就緒了嗎（所有覆蓋層都有紋理）。
  /// 接管前先問，沒好就等下一個事件——不讓黑畫布上台
  static Future<bool> ready(double t) async {
    try {
      return await CompPlayer._ch.invokeMethod<bool>('mready', t) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 數值法庭：離屏渲染 [t] 的影片層、回讀中線 5 點線性值
  ///（驗色用，跟顯示器無關）
  static Future<List<double>?> grab(double t) async {
    try {
      final r = await CompPlayer._ch.invokeMethod<List<dynamic>>('mgrab', t);
      return r?.map((e) => (e as num).toDouble()).toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> disposeEngine() async {
    active = false;
    try {
      await CompPlayer._ch.invokeMethod<void>('mdispose');
    } catch (_) {}
  }
}

/// 合成播放器：整條時間軸交給系統的一顆播放器。
///
/// 原本是「一個片段一顆播放器」，由 App 自己的時鐘驅動、交界前預先開播
/// 下一顆再換手。實機量下來 Flutter 這條線完全乾淨（五千格只超時兩格）、
/// 散熱正常、對時成本 0.01ms，但影格就是會不定時落後——剩下唯一沒排除的
/// 變因是「同時養三顆 AVPlayer」，每顆都佔一組解碼與影格輸出資源。
///
/// AVComposition 正是為這件事存在的：一條時間軸、一顆播放器、一組解碼
/// 資源，片段交界由系統自己接（不會黑閃、不用預熱、不用對時校正）。
///
/// 目前只有 iOS 有原生實作；拿不到就回 null，呼叫端退回原本的多播放器路徑
class CompPlayer {
  CompPlayer._(
    this.textureId,
    this.duration,
    this.width,
    this.height,
    this.ciOn,
    this.hdrIn,
    this.wmLive,
  );

  static const _ch = MethodChannel('markcut/comp');

  /// 原生端回報「新合成的畫面真的上檔了」（第一格就緒翻面／保底）。
  /// HDR 預覽的 Flutter 版浮水印要等這一刻才藏——早藏的話舊畫面
  /// 還在前面撐著，浮水印會憑空消失一下（實測回報：讀取時浮水印
  /// 消失、讀取完才出來）
  static void Function()? onCompVisible;

  static bool _handlerSet = false;
  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'compVisible') onCompVisible?.call();
      return null;
    });
  }

  final int textureId;
  final double duration;
  final double width;
  final double height;

  /// 這一次組建有沒有掛 CI 合成器／HDR 判定結果（寫進「就緒」的
  /// 診斷歷史用——組建內視鏡只留最後一次，進場那次會被蓋掉）
  final bool ciOn;
  final bool hdrIn;

  /// HDR 預覽的疊加物走「即時清單」：浮水印/文字/貼圖烘進合成、
  /// 用 EDR 顯示（白色才是白色，提亮跟匯出同一段程式碼）。
  /// 之後改樣式/拖曳用 [setOverlays] 換清單，不必整組重建。
  /// false＝疊加物照舊由 Flutter 圖層畫（SDR 預覽本來就準）
  final bool wmLive;

  double get aspect => (width <= 0 || height <= 0) ? 16 / 9 : width / height;

  static bool? _available;

  static Future<bool> get available async {
    if (_available != null) return _available!;
    try {
      _available = await _ch.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  /// 這條時間軸能不能交給合成播放器。
  ///
  /// 剩兩件做不到：
  /// - 倒轉：播放器沒辦法倒著播（那條路是先把片段做成「已經倒好的檔」）
  /// - 調色：畫面走系統的影片圖層，Flutter 的濾鏡疊不上去。舊路徑的
  ///   影格是畫在 Flutter 材質上的，濾鏡吃得到——所以有調色就退回去，
  ///   不然預覽看不到效果、匯出卻有，那比慢更糟
  ///
  /// 子母畫面本來也被擋掉，一上多軌就整組退回舊的「一片段一顆播放器」
  /// ——那正是「多軌之後變超 LAG」。AVFoundation 原生就支援多軌疊合，
  /// 一條時間軸軌道對一條合成軌，逐段的 layer instruction 決定每一刻
  /// 誰在上面。變速、淡入淡出、縮放位移也一樣烘進合成裡。
  ///
  /// 工作檔沒好也照組——用原檔組一樣播得動，而且是一顆播放器一組解碼
  /// 資源，比舊路徑輕得多
  static String? whyNot(TimelineModel tl, {Set<int> hiddenTracks = const {}}) {
    // 隱藏軌整條不進合成：判定也用同一份視角，不然「隱藏了唯一
    // 會擋路的片段」還是被判組不起來
    final vids = [
      for (final c in tl.clips)
        if (tl.sourceOf(c).isVideo && !hiddenTracks.contains(c.track)) c,
    ];
    if (vids.isEmpty) return '沒有影片片段';
    for (final c in vids) {
      if (c.reverse) return '有倒轉的片段';
      if (c.color.hasColor) return '有調色的片段';
    }
    // 馬賽克不再是阻擋條件：改成烘進合成本身——原生端掛上跟匯出
    // 同一顆 CI 合成器，逐格在 GPU 上打碼。Flutter 的 BackdropFilter
    // 版馬賽克在合成模式下會關掉（不然是打兩次碼）
    // 圖片素材不再是阻擋條件：
    // - 壓在所有影片之上的：由 Flutter 圖層畫在合成畫面上面
    //  （跟非合成模式同一套），可以即時拖曳
    // - 墊在影片下層的：烘進合成本身（still/GIF 層，跟匯出同一顆
    //   CI 合成器、同一套定位數學），見 [bakedImageIds]。
    //   以前這種疊法整個放棄合成、退回一片段一顆播放器——
    //   「加一張 GIF 之後開頭又開始卡」就是這樣來的
    // 影片全部播完之後時間軸還有別的東西（圖片、文字拖得比影片長）：
    // 合成的總長只到影片結尾，播放時鐘走到那裡就卡住原地跳針，
    // 位置甚至會跑到比總長還大。
    // 馬賽克不算：它只是糊底下的畫面，影片播完沒東西可糊，而且
    // 預設 3 秒常常比短片還長——因為它放棄合成，等於馬賽克永遠
    // 用不到單一播放器（實測就是這樣壞的）
    var vidEnd = 0.0;
    for (final c in vids) {
      if (c.end > vidEnd) vidEnd = c.end;
    }
    var lastEnd = 0.0;
    for (final c in tl.clips) {
      if (tl.sourceOf(c).kind == ClipKind.mosaic) continue;
      if (hiddenTracks.contains(c.track)) continue;
      if (c.end > lastEnd) lastEnd = c.end;
    }
    if (lastEnd - vidEnd > 0.05) return '影片結束後還有其他素材';
    return null;
  }

  /// 要烘進合成的圖片素材（片段 id）：墊在「最高的影片軌」之下的
  /// 那些。壓在所有影片之上的不烘——Flutter 畫在上面，拖曳即時。
  /// build 的 payload 跟編輯器「合成新鮮時別重畫」都用這一個，
  /// 兩邊的判定不可能走鐘
  ///
  /// [wmStart]~[wmEnd]＝浮水印烘在合成裡的那段時間（終點不大於起點
  /// ＝沒有，見 [build] 的同名參數）。跟它重疊的圖片/GIF 也要烘：
  /// 不烘的話 Flutter 會把那張畫在整顆播放器材質「上面」，而浮水印
  /// 在材質「裡面」＝被蓋掉（實測回報：最上層的浮水印被 GIF 蓋過）；
  /// 匯出的合成器是疊加物最後畫、永遠在最上面，預覽就跟成品不一致。
  /// 一起烘之後兩邊都照同一條 z 序（層照軌道排、疊加物最後），
  /// 代價跟墊底圖片一樣：拖它要等重烘，不能即時
  static Set<int> bakedImageIds(
    TimelineModel tl, {
    double wmStart = 0,
    double wmEnd = 0,
  }) {
    var top = -1;
    // 合成只到影片結尾：整塊落在影片之後的圖片烘不進去（build 會
    // 跳過），這裡也要用同一條件排除——不排除的話編輯器把它當
    // 「已烘」不畫，預覽看不見、匯出卻有
    var vidEnd = 0.0;
    for (final c in tl.clips) {
      if (!tl.sourceOf(c).isVideo) continue;
      if (c.track > top) top = c.track;
      if (c.end > vidEnd) vidEnd = c.end;
    }
    // 馬賽克壓在圖片/GIF 上面（軌道更高、時間重疊）：那張圖也要烘
    // 進合成——Flutter 畫的圖層在合成畫面「上方」，原生端的馬賽克
    // 永遠打不到它（實測回報：馬賽克無法覆蓋 GIF，儘管圖層在上；
    // 匯出端本來就是 z 交錯、蓋得住，預覽不烘就跟成品不一致）。
    // 代價跟墊底圖片一樣：拖曳它要等重烘，不能即時
    final mosaics = [
      for (final c in tl.clips)
        if (tl.sourceOf(c).kind == ClipKind.mosaic) c,
    ];
    bool mosaicAbove(TimelineClip img) => mosaics.any(
      (m) => m.track > img.track && m.offset < img.end && m.end > img.offset,
    );
    // 浮水印看得見的那段時間（見上）
    bool underWm(TimelineClip img) =>
        wmEnd > wmStart && img.offset < wmEnd && img.end > wmStart;
    return {
      for (final c in tl.clips)
        if (tl.sourceOf(c).kind == ClipKind.image &&
            (c.track <= top || mosaicAbove(c) || underWm(c)) &&
            c.offset < vidEnd)
          c.id,
    };
  }

  /// 用時間軸組一份合成。組不起來（平台不支援、素材有問題）回 null
  /// [texture] 畫面要不要另外送一份到 Flutter 材質。用系統影片圖層
  /// 顯示時給 false：那份材質沒有人看，卻是每一格複製一張 4K 畫面
  /// 上一次組不起來的原因（原生端回報的）。呼叫端拿去寫進診斷
  static String? lastError;

  /// 這個檔是不是 HDR（probeLite 的 sdr709 判定）。
  /// 快取鍵含檔案大小與修改時間：相簿的暫存路徑會重複使用
  ///（work_files 自己就寫明了），只記路徑的話同一路徑換了
  /// 另一支影片會沿用舊判定——SDR 被當 HDR 播原檔，或 HDR
  /// 被當 SDR 整段發白
  static final Map<String, bool> _hdrCache = {};
  static Future<bool> _isHdrPath(String path) async {
    var key = path;
    try {
      final st = await File(path).stat();
      key = '$path#${st.size}#${st.modified.millisecondsSinceEpoch}';
    } catch (_) {}
    final hit = _hdrCache[key];
    if (hit != null) return hit;
    // 讀不到（探測失敗/沒實作）就當 HDR：CI 的 toneMap 對 SDR 輸入
    // 是無害的空操作，多掛只是原檔期間多一點 GPU；漏掛就是整段白白。
    // 失敗的結果不進快取——之後重試還有機會拿到正確判定
    final m = await MediaPrep.probeLite(path);
    if (m == null || m['error'] != null) return true;
    return _hdrCache[key] = m['sdr709'] != true;
  }

  /// [mutedTracks] 整軌靜音的軌號：音量在組合成時就烘進去，
  /// 所以切靜音要重組（呼叫端的指紋有把它算進去）
  /// [hdrOut]：匯出選「保留 HDR」時預覽也走 HDR——HDR 素材播原檔
  ///（工作檔是 SDR，播它永遠比成品淡）、合成不做 toneMap。
  /// SDR 輸出時照舊（工作檔＋toneMap，已與成品同曲線）
  /// 最後一次組建餵給原生的來源路徑（取樣全零時查檔用）
  static List<String> lastPaths = [];

  static Future<String> sampleOut(String path) async {
    try {
      return await _ch.invokeMethod<String>('sampleOut', {'path': path}) ?? '?';
    } catch (_) {
      return '?';
    }
  }

  static Future<String> finfo(String path) async {
    try {
      return await _ch.invokeMethod<String>('finfo', path) ?? '?';
    } catch (_) {
      return '?';
    }
  }

  /// [wmStart]~[wmEnd]：浮水印在合成裡看得見的那段時間（終點不大於
  /// 起點＝沒有浮水印）。只拿來決定哪些圖片/GIF 必須烘進合成，
  /// 見 [bakedImageIds]——呼叫端四個地方要送同一個值，不然「編輯器
  /// 以為烘了不畫／合成其實沒烘」就是素材整個不見
  static Future<CompPlayer?> build(
    TimelineModel tl, {
    bool texture = true,
    Set<int> mutedTracks = const {},
    Set<int> hiddenTracks = const {},
    bool hdrOut = false,
    List<Map<String, dynamic>> overlays = const [],
    double wmStart = 0,
    double wmEnd = 0,
  }) async {
    if (!await available) return null;
    _ensureHandler();
    // 裁切/旋轉/透明度不再是阻擋條件：原生端會為它們掛 CI 合成器，
    // 直接烘進合成畫面（跟匯出同一套數學）。
    // 隱藏軌整條排除（畫面與聲音都不進，跟匯出一致）
    final vids =
        [
          for (final c in tl.clips)
            if (tl.sourceOf(c).isVideo && !hiddenTracks.contains(c.track)) c,
        ]..sort((a, b) {
          final t = a.offset.compareTo(b.offset);
          return t != 0 ? t : a.track.compareTo(b.track);
        });
    if (vids.isEmpty) return null;
    // 每支來源是不是 HDR（工作檔一定是 SDR，不用問）。
    // 在 Dart 端用 probeLite 算好傳過去：Swift 端自己同步讀軌道
    // 的判定在實機上有拿不到資料的情況（實測：進場的合成沒掛
    // CI、HDR 原檔整段白白的），probeLite 那條路已被證明可靠
    final hdrOf = <int, bool>{};
    for (final c in vids) {
      final i = c.sourceIndex;
      if (hdrOf.containsKey(i)) continue;
      final s = tl.sourceOf(c);
      // HDR 輸出模式：一律探測原檔（工作檔捷徑會把 HDR 判成 SDR，
      // 那正是要繞開的東西）。有 HDR 代理＝一定是 HDR，免探
      if (hdrOut && s.workHdrPath != null) {
        hdrOf[i] = true;
        continue;
      }
      if (!hdrOut && s.workPath != null) {
        hdrOf[i] = false;
        continue;
      }
      hdrOf[i] = await _isHdrPath(s.path);
    }
    final clips = [
      for (final c in vids)
        {
          // 一律用工作檔（轉正過、SDR、H.264）；HDR 輸出模式的
          // HDR 素材播「HLG 代理」（密關鍵幀、HLG 直通不動色彩）
          // ——原檔關鍵幀疏是 seek 慢的地板，播放 LAG 家族的根之一。
          // 當初為驗 Dolby Vision 顯示管理直接播原檔（+109 實驗），
          // 實驗結束收回；Diag.hdrProxyPreview 留退路：實機若出現
          // 過飽和（DV 中繼資料被剝）關掉就回原檔。代理還沒轉好前
          // 照舊播原檔，轉好那刻換手（指紋含 workHdrPath）
          'path': hdrOut && (hdrOf[c.sourceIndex] ?? false)
              ? ((Diag.hdrProxyPreview.value
                        ? tl.sourceOf(c).workHdrPath
                        : null) ??
                    tl.sourceOf(c).path)
              : tl.sourceOf(c).previewPath,
          // HDR 原檔要在原生端掛 CI 做 toneMap（見上）
          'hdr': hdrOf[c.sourceIndex] ?? false,
          'start': c.trimStart,
          'end': c.trimEnd,
          // 絕對時間＋軌道編號：原生端一條軌道開一條合成軌，
          // 疊起來的順序就是使用者看到的上下層
          'offset': c.offset,
          'track': c.track,
          'volume': mutedTracks.contains(c.track)
              ? 0.0
              : c.volume.clamp(0.0, 1.0),
          'speed': c.speed,
          'fadeIn': c.fadeIn,
          'fadeOut': c.fadeOut,
          'scale': c.scale,
          'px': c.px,
          'py': c.py,
          'mirror': c.mirror,
          if (c.cropped) 'crop': [c.cropL, c.cropT, c.cropW, c.cropH],
          'rotation': c.rotation,
          'opacity': c.opacity,
        },
    ];
    // 馬賽克：跟原生匯出同一套欄位（見 native_export 的 mosaics），
    // 原生端拿它組 CIMosaicSpec。時間是時間軸秒數——合成的時間基準
    // 就是時間軸，整體變速由播放速率處理，不用在這裡除
    // 馬賽克的尾巴夾到影片結尾：合成只到影片結尾，超過的部分
    // 沒有畫面可糊（也是 whyNot 對馬賽克放行的前提）
    var compEnd = 0.0;
    for (final c in vids) {
      if (c.end > compEnd) compEnd = c.end;
    }
    final mosaics = <Map<String, dynamic>>[];
    for (final c in tl.clips) {
      final src = tl.sourceOf(c);
      if (src.kind != ClipKind.mosaic) continue;
      if (hiddenTracks.contains(c.track)) continue; // 隱藏軌不打碼
      if (c.offset >= compEnd) continue; // 整塊都在影片之後：沒東西可糊
      final ms = src.mosaicStyle ?? MosaicStyle();
      mosaics.add({
        'start': c.offset,
        'end': c.end > compEnd ? compEnd : c.end,
        'track': c.track,
        'px': c.px,
        'py': c.py,
        'scale': c.scale,
        'type': ms.type,
        'strength': ms.strength,
        'color': ms.color,
        'feather': ms.feather,
        // 筆刷筆畫（0~1 畫布座標）：Swift 端組成遮罩，
        // 塗到哪碼到哪（跟匯出同一套欄位）
        if (src.mosaicStroke != null) 'stroke': src.mosaicStroke,
        if (src.mosaicStroke != null) 'brush': src.mosaicBrush,
      });
    }
    mosaics.sort((a, b) => (a['track'] as int).compareTo(b['track'] as int));
    // 墊在影片下層的圖片/GIF：烘進合成（跟原生匯出同一套欄位，
    // Swift 端組 CILayerSpec/CIGifSpec）。時間是時間軸秒數
    final baked = bakedImageIds(tl, wmStart: wmStart, wmEnd: wmEnd);
    final stills = <Map<String, dynamic>>[];
    for (final c in tl.clips) {
      if (!baked.contains(c.id)) continue;
      if (hiddenTracks.contains(c.track)) continue; // 隱藏軌不烘
      if (c.offset >= compEnd) continue;
      final src = tl.sourceOf(c);
      stills.add({
        'path': src.path,
        if (src.isGif) 'gif': true,
        'start': c.offset,
        'end': c.end > compEnd ? compEnd : c.end,
        'track': c.track,
        'px': c.px,
        'py': c.py,
        'scale': c.scale,
        'mirror': c.mirror,
        'fadeIn': c.fadeIn,
        'fadeOut': c.fadeOut,
        'color': c.color.hasColor ? c.color.matrix : null,
        if (c.cropped) 'crop': [c.cropL, c.cropT, c.cropW, c.cropH],
        'rotation': c.rotation,
        'opacity': c.opacity,
      });
    }
    lastPaths = [for (final c in clips) (c['path'] as String?) ?? ''];
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('build', {
        'clips': clips,
        'texture': texture,
        'mosaics': mosaics,
        'stills': stills,
        'hdrOut': hdrOut,
        // HDR 預覽的疊加物（浮水印/文字/貼圖的整版 PNG，跟匯出
        // 同一套欄位；rect 描述使用者畫布落在合成畫框的哪裡）
        'overlays': overlays,
      });
      if (m == null) return null;
      // 原生端組不起來時會回原因，不要讓它只變成一句「組不起來」
      final err = m['error'];
      if (err is String) {
        lastError = err;
        return null;
      }
      lastError = null;
      return CompPlayer._(
        (m['textureId'] as num).toInt(),
        (m['duration'] as num).toDouble(),
        (m['width'] as num?)?.toDouble() ?? 0,
        (m['height'] as num?)?.toDouble() ?? 0,
        m['ci'] == true,
        m['hdr'] == true,
        m['wmLive'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// 捏合/拖曳中的即時變形（不重建合成）：原生端只重產
  /// videoComposition 換上，同一個播放器、不閃。放手後照舊由
  /// 指紋觸發重組烘定——數學同一段，不會跳位。
  /// [z]＋[start] 一起定位「哪一段」（同一軌可以有很多片段）
  static Future<bool> setXform({
    required int z,
    required double start,
    required double scale,
    required double px,
    required double py,
    required double rotation,
  }) async {
    try {
      return await _ch.invokeMethod<bool>('setXform', {
            'z': z,
            'start': start,
            'scale': scale,
            'px': px,
            'py': py,
            'rotation': rotation,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 浮水印部件的即時幾何（拖曳/縮放/旋轉；絕對值，原生跟烘進
  /// PNG 的基準算差量）。一次送「所有偏離基準的部件」整包——
  /// 位置九宮格是文字＋圖片一起跳，漏送誰誰就不動。
  /// PNG 不重畫、合成不重建——跟手的關鍵
  static Future<bool> setOvXforms(
    List<Map<String, dynamic>> items, {
    bool noNudge = false,
  }) async {
    try {
      return await _ch.invokeMethod<bool>('setOvXform', {
            'items': items,
            'noNudge': noNudge,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 取消即時變形覆寫（重組完成、烘定值已含最終位置時呼叫；
  /// 值相同所以畫面不動，只是把覆寫收掉，免得之後改了縮放
  /// 又被舊覆寫算錯差量）
  static Future<void> clearXform() async {
    try {
      await _ch.invokeMethod<bool>('setXform', {'clear': true});
    } catch (_) {}
  }

  /// 換 HDR 預覽的即時疊加物清單（不重建合成）。
  /// 只有 [wmLive] 的合成收得下；成功回 true。暫停中呼叫端要補一個
  /// 精準 seek，逼合成器用新清單重畫當下這一格
  static Future<bool> setOverlays(
    List<Map<String, dynamic>> overlays, {
    List<Map<String, dynamic>>? live,
    bool noNudge = false,
  }) async {
    try {
      return await _ch.invokeMethod<bool>('setOverlays', {
            'overlays': overlays,
            'live': ?live,
            'noNudge': noNudge,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 回「按下那一刻播放器在忙什麼」（診斷用；原生端拿不到就 null）
  Future<String?> play() async {
    try {
      return await _ch.invokeMethod<String>('play');
    } catch (_) {
      return null;
    }
  }

  /// 抽「現在畫面上這一格」（合成後的輸出，JPEG）。
  /// 給編輯器的重烘空窗鋪面用；抽不到（剛換 item、web）回 null
  Future<Uint8List?> grab({int maxH = 1080}) async {
    try {
      return await _ch.invokeMethod<Uint8List>('grab', {'maxH': maxH});
    } catch (_) {
      return null;
    }
  }

  Future<void> pause() => _quiet('pause');
  Future<void> setRate(double r) => _quiet('rate', r);

  /// 預覽靜音（原生端走播放器的 isMuted，不重組合成）
  Future<void> setMuted(bool m) => _quiet('muted', m);

  /// 專業 AV 分離：引擎接管播放時視訊軌硬體級停用（解碼器全讓
  /// 給引擎），這顆只出聲音＋當時鐘。即時切換、不重建
  Future<void> setVideoTracks(bool on) => _quiet('vtracks', on);

  /// 播放接管（音訊分身版）：聲音與時鐘交給純音訊分身，
  /// 主播放器原地凍結——管線永不拆裝、暫停畫面隨叫隨到
  Future<void> setTakeover(bool on) => _quiet('takeover', on);

  /// [exact] 只有「停手要對準那一格」時才給 true。拖曳中與按下播放前
  /// 一律寬容——精準 seek 跑完之前播放器的 rate 會被壓在 0
  Future<void> seek(double seconds, {bool exact = false}) =>
      _quiet('seek', {'sec': seconds, 'exact': exact});
  Future<void> dispose() => _quiet('dispose');

  /// 目前位置（秒）。合成播放器是唯一的時鐘來源——App 不再自己算時間，
  /// 也就不會有「時鐘跟畫面對不上」這回事
  Future<double> position() async {
    try {
      final ms = await _ch.invokeMethod<int>('position');
      return (ms ?? 0) / 1000.0;
    } catch (_) {
      return 0;
    }
  }

  /// 材質實際更新的間隔統計。30fps 的素材理想是每 33ms 換一張；
  /// 出現 60、80、100 就是 judder——每一格都準時畫，但畫的是同一張。
  /// Flutter 端的所有指標都看不到這件事，眼睛卻很敏感
  Future<String> gaps() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('gaps');
      final n = (m?['count'] as num?)?.toInt() ?? 0;
      if (n == 0) return '沒有取樣到';
      final avg = (m!['avgMs'] as num).toDouble();
      final max = (m['maxMs'] as num).toInt();
      final over = (m['over2x'] as num).toInt();
      return '換圖 $n 次／平均 ${avg.toStringAsFixed(1)}ms'
          '／最久 ${max}ms／超過兩格 $over 次';
    } catch (_) {
      return '讀不到';
    }
  }

  /// 拖曳偵探用的計數（原生端便宜的整數：seek 落地幾發／合併幾發／
  /// 合成器交了幾格）。手勢頭尾各讀一次相減＝這一手滑出幾張畫面。
  /// 走 'gaps' 這條（不做抽格檢查，拖曳中叫得起；health 會抽格）
  Future<({int seeks, int coalesced, int frames})> scrubCounters() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('gaps');
      return (
        seeks: (m?['seeks'] as num?)?.toInt() ?? 0,
        coalesced: (m?['coalesced'] as num?)?.toInt() ?? 0,
        frames: (m?['frames'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return (seeks: 0, coalesced: 0, frames: 0);
    }
  }

  /// 播放器自己回報的狀況：seek 成本、掉格、卡頓、在等什麼。
  /// 這幾個數字 Flutter 端一個都量不到
  Future<String> health() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('health');
      if (m == null || m.isEmpty) return '讀不到';
      final b = StringBuffer();
      // 有沒有掛合成器＝這條時間軸是「硬體解碼直送螢幕」還是
      // 「每一格都進合成管線重畫一張」。原檔一匯入順不順就看這裡
      b.write(
        m['usesVC'] == true
            ? '合成器 開（每格重畫 ${m['renderW']}x${m['renderH']}）'
            : '合成器 關（硬體直送，跟相簿同一條路）',
      );
      // 軌數、指令數、以及「這一刻抽得到畫面嗎」。畫面黑掉時這一行
      // 直接分得出是合成壞了還是圖層沒畫
      if (m['vTracks'] != null) {
        b.write(
          '／${m['vTracks']} 條畫面軌、${m['aTracks']} 條聲音軌'
          '、${m['instructions']} 段指令'
          '、長 ${(m['compDur'] as num?)?.toStringAsFixed(1)}s',
        );
      }
      final luma = m['lumaProbe'] as String?;
      if (luma?.isNotEmpty == true) {
        b.write('\n  交格亮度：$luma（全 0＝合成器真的交黑格）');
      }
      if (m['layerBound'] == false) {
        b.write('\n  ⚠ 影片圖層綁在舊播放器（畫面會全黑）');
      }
      if (m['frameProbe'] != null) {
        b.write('\n  抽格檢查：${m['frameProbe']}');
      }
      // 時鐘偵探：接管/讓位後 1.5 秒的三時鐘軌跡（音訊率/音訊時間/
      // 引擎時鐘）——「暫停再播跳動」直接看曲線，不用重現
      final ct = m['clockTrace'] as String?;
      if (ct != null && ct.isNotEmpty) {
        b.write('\n  時鐘軌跡（率=音訊分身速率）：\n    ');
        b.write(ct.replaceAll('\n', '\n    '));
      }
      // CI 合成器的逐格計時：接縫頓的話，慢格清單會直接寫著
      // 「幾秒的那一格花了幾 ms、幾層、有沒有缺格」——不用再猜
      final fast = m['fastFrames'] as String?;
      if (fast != null) b.write('\n  合成路徑：$fast（快路=Metal直拷）');
      final skips = m['fastSkip'] as String?;
      if (skips?.isNotEmpty == true) {
        b.write('\n  快路未命中原因：$skips');
      }
      final ciFrames = (m['ciFrames'] as num?)?.toInt() ?? 0;
      if (ciFrames > 0) {
        b.write(
          '\n  CI 逐格：$ciFrames 格'
          '／最慢 ${(m['ciWorstMs'] as num?)?.toStringAsFixed(0)}ms',
        );
        final slow = m['ciSlow'];
        if (slow is List && slow.isNotEmpty) {
          b.write('／慢格(>20ms)：${slow.join('；')}');
        } else {
          b.write('／沒有超過 20ms 的格');
        }
        // 供格節奏：合成快不等於畫面順——系統若在接縫供不出下一格，
        // 這裡會直接寫出「幾秒處等了幾 ms」。卡頓的最終裁判
        b.write(
          '\n  供格節奏：最多多等 '
          '${(m['ciSupplyWorst'] as num?)?.toStringAsFixed(0) ?? '?'}ms',
        );
        final gaps = m['ciSupplyGaps'];
        if (gaps is List && gaps.isNotEmpty) {
          b.write('／卡住的點：${gaps.join('；')}');
        } else {
          b.write('／沒有等超過 80ms 的格');
        }
        final burst = m['ciBurst'];
        if (burst is String && burst.isNotEmpty) {
          b.write('\n  起播前40格到格間隔(ms)：$burst');
        }
        // 缺格與保底：哪一軌在什麼時候給不出影格、保底出動了幾次
        final miss = (m['ciMiss'] as num?)?.toInt() ?? 0;
        final holdM = (m['ciHoldMiss'] as num?)?.toInt() ?? 0;
        final holdG = (m['ciHoldGap'] as num?)?.toInt() ?? 0;
        if (miss > 0 || holdM > 0 || holdG > 0) {
          b.write('\n  缺格：$miss 次');
          final notes = m['ciMissNotes'];
          if (notes is List && notes.isNotEmpty) {
            b.write('（${notes.join('；')}）');
          }
          b.write('／保底重播：缺格 $holdM 次、短縫或片尾 $holdG 次');
        } else {
          b.write('\n  缺格：0／保底沒出動');
        }
      }
      // 組建內視鏡：Swift 實際收到的軌值、組出的軌數與每段指令的層 z。
      // 「程式碼看起來對、裝置行為不對」時只有這個拆得開
      final bi = m['buildInfo'];
      if (bi is Map && bi.isNotEmpty) {
        b.write(
          '\n  組建：收到 ${bi['收到'] ?? '?'}'
          '／馬賽克 ${bi['馬賽克'] ?? '無'}'
          '／合成軌 ${bi['合成軌']}／CI ${bi['CI']}／HDR ${bi['HDR']}'
          '\n  指令：${bi['指令'] ?? '?'}',
        );
        // 軌道實況：媒＝正常媒體、填＝拉長的填充、空＝空範圍。
        // CI 路線出現「空」＝鋪滿失敗，病灶直接定罪
        if (bi['軌道段'] != null) {
          b.write('\n  軌道段：${bi['軌道段']}');
        }
        if (m['trackGeo'] != null) {
          b.write(
            '\n  軌道幾何：${m['trackGeo']}'
            '／合成畫布 ${m['canvasWH'] ?? '?'}',
          );
        }
      }
      b.write('／狀態 ${m['timeControl'] ?? '?'}');
      if (m['waiting'] != null) b.write('（在等：${m['waiting']}）');
      if (m['bufferEmpty'] == true) b.write('／緩衝空的');
      if (m['likelyToKeepUp'] == false) b.write('／可能跟不上');
      final dropped = (m['dropped'] as num?)?.toInt();
      if (dropped != null) b.write('／系統記的掉格 $dropped');
      final stalls = (m['stalls'] as num?)?.toInt();
      if (stalls != null) b.write('／卡頓 $stalls 次');
      // 原生圖層建立次數：播放中變多＝圖層被拆掉重掛（黑閃）。
      // 修好之後整段編輯應該只有 1 次
      final vcr = (m['viewCreates'] as num?)?.toInt();
      if (vcr != null) {
        b.write('／原生圖層建立 $vcr 次');
        final at = m['viewCreateAt'];
        if (at is List && at.isNotEmpty) b.write('（${at.join('、')}）');
      }
      // 系統主動喊的「播放卡住」通知（跟供格節奏對照用）
      final sn = (m['stallNotify'] as num?)?.toInt() ?? 0;
      if (sn > 0) {
        b.write(
          '／系統喊卡住 $sn 次'
          '（${(m['stallNotifyAt'] as List?)?.join('、') ?? '?'}）',
        );
      }
      final n = (m['seekCount'] as num?)?.toInt();
      // 按下播放那兩百毫秒的內部拆解：播放器什麼時候真的開始跑、
      // 什麼時候畫面才動、中間在等什麼。三個時間點分開之後，
      // 「播放器沒開始」跟「開始了但畫面沒更新」一眼就分得出來
      final bd = m['playBreakdown'];
      if (bd is Map) {
        b.write(
          '\n  按下播放：${[if (bd['rateMs'] != null) 'rate 起來 ${bd['rateMs']}ms', if (bd['playingMs'] != null) '系統說在播 ${bd['playingMs']}ms', if (bd['movedMs'] != null) '時間真的前進 ${bd['movedMs']}ms' else '時間一直沒前進', if (bd['waiting'] != null) '等待理由 ${bd['waiting']}'].join('／')}',
        );
      }
      if (n != null) {
        b.write(
          '\n  催重畫：${m['nudgeInfo'] ?? '—'}'
          '\n  拖曳 seek：$n 發／平均 ${m['seekAvgMs']}ms'
          '／一半在 ${m['seekP50Ms']}ms 內／九成在 ${m['seekP90Ms']}ms 內'
          '／最久 ${m['seekMaxMs']}ms／被合併掉 ${m['seekCoalesced']} 發',
        );
      }
      return b.toString();
    } catch (_) {
      return '讀不到';
    }
  }

  Future<void> _quiet(String method, [Object? arg]) async {
    try {
      await _ch.invokeMethod(method, arg);
    } catch (_) {}
  }
}
