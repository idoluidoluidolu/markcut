import 'dart:math' as math;
import 'dart:typed_data';

import '../models/timeline.dart';
import '../models/watermark_settings.dart';

/// 匯出解析度選項。
/// 用「畫質等級」而不是 4K／1080P 這種絕對名稱：素材本身沒那麼大時
/// 不會放大（放大不會更清晰，只會讓檔案變大、匯出變慢），
/// 所以掛絕對數字的選項常常算出跟原始一模一樣的尺寸，選了也沒反應。
/// 等級講的是「相對原片縮多少」，永遠三個選項而且永遠有意義
enum ExportResolution { original, fhd1080, hd720 }

extension ExportResolutionLabel on ExportResolution {
  /// 用「尺寸」而不是「畫質」講：下面還有一個獨立的「畫質」設定
  /// （標準／極高／最高），兩邊都叫畫質的話同一頁會出現兩個「最高」
  String get label => switch (this) {
    ExportResolution.original => '原尺寸',
    ExportResolution.fhd1080 => '縮小',
    ExportResolution.hd720 => '最小',
  };

  /// 選單裡的一句說明（尺寸另外由呼叫端算）
  String get hint => switch (this) {
    ExportResolution.original => '跟原片一樣',
    ExportResolution.fhd1080 => '檔案小一半左右',
    ExportResolution.hd720 => '匯出速度最快',
  };
}

/// 輸出畫面比例（原始 = 跟第一個影片一樣）。
/// 4:5 補在最後而不是插在中間——草稿存的是 enum 索引，
/// 插在中間會讓舊專案的比例整個跑掉；顯示順序由 [ratioOrder] 決定
enum CanvasRatio { original, r16_9, r9_16, r1_1, r4_3, r3_4, r4_5 }

/// 比例視窗的顯示順序：原始最前，其餘照首位數字由小到大
///（使用者指定；全 App 的比例視窗都用這一份，照片編輯也對齊它）
const ratioOrder = [
  CanvasRatio.original,
  CanvasRatio.r1_1,
  CanvasRatio.r3_4,
  CanvasRatio.r4_3,
  CanvasRatio.r4_5,
  CanvasRatio.r9_16,
  CanvasRatio.r16_9,
];

extension CanvasRatioInfo on CanvasRatio {
  String get label => switch (this) {
    CanvasRatio.original => '原始',
    CanvasRatio.r16_9 => '16:9',
    CanvasRatio.r9_16 => '9:16',
    CanvasRatio.r1_1 => '1:1',
    CanvasRatio.r4_3 => '4:3',
    CanvasRatio.r3_4 => '3:4',
    CanvasRatio.r4_5 => '4:5',
  };

  /// 寬/高；null = 依素材
  double? get value => switch (this) {
    CanvasRatio.original => null,
    CanvasRatio.r16_9 => 16 / 9,
    CanvasRatio.r9_16 => 9 / 16,
    CanvasRatio.r1_1 => 1,
    CanvasRatio.r4_3 => 4 / 3,
    CanvasRatio.r3_4 => 3 / 4,
    CanvasRatio.r4_5 => 4 / 5,
  };
}

/// 匯出畫質（CRF 越低畫質越高、檔案越大）
/// 匯出畫質。low 補在最後而不是插在最前面——
/// 草稿存的是 enum 索引，插在中間會讓舊專案的畫質整個跑掉；
/// 顯示順序另外由 [qualityOrder] 決定
enum ExportQuality { standard, ultra, lossless, low }

/// 選單顯示順序：由低到高
const qualityOrder = [
  ExportQuality.low,
  ExportQuality.standard,
  ExportQuality.ultra,
  ExportQuality.lossless,
];

extension ExportQualityInfo on ExportQuality {
  /// 「極高／最高」在中文裡分不出大小，選單上只好一個一個試。
  /// 改成講尺度：省空間←→最高畫質。真正的差別由選單右邊的檔案大小講，
  /// 那是唯一每個人都懂、而且會隨專案變動的東西
  String get label => switch (this) {
    ExportQuality.low => '省空間',
    ExportQuality.standard => '標準',
    ExportQuality.ultra => '高畫質',
    ExportQuality.lossless => '最高畫質',
  };

  /// 一句話講「什麼時候選這檔」。講用途不講技術——位元率、壓縮率
  /// 那些字眼幫不了不懂的人，懂的人看右邊的檔案大小就夠了
  String get note => switch (this) {
    ExportQuality.low => '輸出最快速',
    ExportQuality.standard => '手機上不放大看不太出差別',
    ExportQuality.ultra => '幾乎原畫質',
    ExportQuality.lossless => '多數情況下和高畫質幾乎沒有分別',
  };

  /// 每像素每幀的位元數。手機走硬體編碼器，吃的是位元率不是 CRF，
  /// 所以這張表才是各檔位實際的差別（見 [kbpsFor]）
  double get bpp => switch (this) {
    ExportQuality.low => 0.07,
    ExportQuality.standard => 0.15,
    ExportQuality.ultra => 0.28,
    ExportQuality.lossless => 0.60,
  };

  /// 這一檔在指定輸出尺寸與影格率下的位元率（kbps）。
  /// 下限擋住極小畫面算出來的荒謬低值，上限是保護（4K 最高會撞到）。
  ///
  /// 影格率用開根號進位：60fps 不用兩倍位元率——相鄰影格更像、
  /// 可壓縮的冗餘更多，經驗值大約多四成，跟 sqrt(2)≈1.41 剛好對上。
  /// 不算的話 60fps 每格只分到一半預算，同一檔畫質實際上掉一階
  int kbpsFor(int w, int h, {double fps = 30}) {
    final f = fps <= 0 ? 1.0 : math.pow(fps / 30, 0.5).toDouble();
    return (w * h * 30 * bpp * f / 1000).round().clamp(1500, 120000);
  }

  int get crf => switch (this) {
    ExportQuality.low => 26,
    ExportQuality.standard => 17,
    ExportQuality.ultra => 12,
    ExportQuality.lossless => 0,
  };
}

/// 輸出影格率：跟著素材走（取專案中最高者），只處理兩種例外。
///
/// probe 讀到垃圾值（0 或大於 480）退回 30。合法的高影格素材夾到
/// 120 而不是丟回 30——原本的防呆寫成 fps>120 就整個退回 30，
/// 等於 240fps 的慢動作素材一匯出就掉七成的影格。
///
/// 1440p 以上夾 60：多數手機的硬體編碼器 4K 只支援到 60，硬塞
/// 120 會編碼失敗、掉進 mpeg4 軟編退路，畫質反而全毀
double outputFps(double srcFps, int outW, int outH, {int want = 0}) {
  var fps = srcFps;
  if (fps <= 0 || fps > 480) fps = 30;
  if (fps > 120) fps = 120;
  if (outW * outH > 2560 * 1440 && fps > 60) fps = 60;
  // 使用者指定了張數就照他的，但不超過素材本身有的——把 30fps 的
  // 素材寫成 60fps 只是把每一格存兩次，檔案變兩倍、畫面一樣頓
  if (want > 0) return math.min(want.toDouble(), fps);
  return fps;
}

/// 匯出頁「張數」可以選的幾檔。0＝跟著素材
const kFpsChoices = <int>[0, 24, 30, 60];

/// 張數選項的說明
String fpsNote(int fps, double srcFps) => switch (fps) {
  0 => '跟原素材一樣',
  24 => '電影感',
  30 => '一般影片',
  _ => '滑順',
};

/// 匯出規格裡存的是 CRF 數字，換回檔位
ExportQuality qualityFromCrf(int crf) => switch (crf) {
  <= 0 => ExportQuality.lossless,
  <= 12 => ExportQuality.ultra,
  <= 17 => ExportQuality.standard,
  _ => ExportQuality.low,
};

/// 依素材本身的位元率，挑一個「看不出被重壓過」的檔位（視覺無損）。
///
/// 只看檔案大小 ÷ 長度換算出來的位元率，不去 probe 編碼格式——
/// probe 要另外跑一次 FFmpeg，開匯出頁就會卡一下。
///
/// [headroom] 是重壓一次的餘裕。同樣的畫質，HEVC 素材換成 H.264
/// 要多吃三到五成位元率，H.264 素材則幾乎不用加；不知道是哪一種，
/// 取中間值。
///
/// [cap] 是自動挑的上限，預設不會自己選到「最高」。最高是標準的
/// 四倍檔案，那種代價該由使用者自己按下去決定，不該是他沒動過設定
/// 就默默拿到的結果；而且極高在任何解析度都已經是很難挑毛病的畫質。
/// 素材真的超過極高（高位元率相機檔）時就停在極高——這是刻意的取捨，
/// 使用者要更高隨時可以自己往上選
ExportQuality recommendQuality({
  required double srcKbps,
  required int outW,
  required int outH,
  double fps = 30,
  double headroom = 1.25,
  ExportQuality cap = ExportQuality.ultra,
}) {
  if (srcKbps <= 0) return ExportQuality.standard;
  final need = srcKbps * headroom;
  final limit = qualityOrder.indexOf(cap);
  for (final (i, q) in qualityOrder.indexed) {
    if (i >= limit) break;
    if (q.kbpsFor(outW, outH, fps: fps) >= need) return q;
  }
  return cap;
}

class ExportSpec {
  final List<MediaSource> sources;
  final List<TimelineClip> clips; // 依軌道由下而上、時間先後排好
  final double timelineDuration; // 原速總長
  final double speed; // 1.0 = 原速（套用整條時間軸）
  final Uint8List? watermarkPng;
  final double wmStart; // 浮水印顯示範圍（時間軸秒）
  final double wmEnd;
  final WmAnimation wmAnimation; // 浮水印動畫
  final double wmSpeed; // 動畫速度倍率
  final double wmRange; // 動畫幅度倍率

  /// 文字／浮水印素材渲染好的整版 PNG（clip id → 圖），匯出時 overlay 用
  final Map<int, Uint8List> overlayPngs;
  final int outW;
  final int outH;
  final int crf; // 匯出畫質（x264 CRF）

  /// 順暢度（每秒幾張）。0＝跟著素材（見 outputFps）
  final int fps;

  /// 輸出成 GIF：先照舊做出影片，最後再轉一趟 GIF（兩段式調色盤）。
  /// 管線一行都不用改，GIF 只是多一道後製
  final bool gif;

  /// GIF 的影格率與長邊上限（只在 gif=true 時有意義）
  final int gifFps;
  final int gifMaxSide;

  /// 保留 HDR：輸出 HEVC 10-bit HLG（只在 iOS 原生匯出、來源是 HDR
  /// 時有效果）。SDR 轉出來在 HDR 螢幕上永遠跟原片有落差，
  /// 要「跟看到的一樣」只有讓輸出檔本身就是 HDR
  final bool hdr;

  ExportSpec({
    required this.sources,
    required this.clips,
    required this.timelineDuration,
    required this.speed,
    required this.watermarkPng,
    required this.outW,
    required this.outH,
    this.wmStart = 0,
    this.wmEnd = 1e9,
    this.wmAnimation = WmAnimation.none,
    this.wmSpeed = 1.0,
    this.wmRange = 1.0,
    this.overlayPngs = const {},
    this.crf = 17,
    this.fps = 0,
    this.gif = false,
    this.gifFps = 12,
    this.gifMaxSide = 480,
    this.hdr = false,
  });

  /// 換掉來源／片段、其餘欄位原封不動。倒轉片段先倒成暫存檔再重建 spec
  /// 用的就是這個——以前是手抄一遍建構子，抄漏了 hdr／fps／gif 三組：
  /// 有倒轉片段的 HDR 專案匯出來是 SDR、GIF 匯出來是影片
  ExportSpec copyWith({
    List<MediaSource>? sources,
    List<TimelineClip>? clips,
  }) => ExportSpec(
    sources: sources ?? this.sources,
    clips: clips ?? this.clips,
    timelineDuration: timelineDuration,
    speed: speed,
    watermarkPng: watermarkPng,
    outW: outW,
    outH: outH,
    wmStart: wmStart,
    wmEnd: wmEnd,
    wmAnimation: wmAnimation,
    wmSpeed: wmSpeed,
    wmRange: wmRange,
    overlayPngs: overlayPngs,
    crf: crf,
    fps: fps,
    gif: gif,
    gifFps: gifFps,
    gifMaxSide: gifMaxSide,
    hdr: hdr,
  );

  /// 輸出影片實際長度（變速後）
  double get outputDuration => math.max(0.01, timelineDuration / speed);

  /// 動畫週期（閃爍一輪／跑馬燈掃一輪的秒數）
  double get wmCycle =>
      wmAnimation == WmAnimation.marquee ? 8 / wmSpeed : 1.2 / wmSpeed;

  /// 閃爍時亮著的秒數
  double get wmOn => wmCycle * (0.58 * wmRange).clamp(0.1, 0.92);
}

/// 快速匯出的門票：這支影片在目前輸出模式下「可以拿來當匯出來源的
/// 1080p 代理」是哪一份。回 null＝沒有（得用原檔）。
///
/// SDR 輸出：SDR 工作檔（709、H.264）。
/// HDR 輸出：素材本身是 HDR 就要 HLG 代理（2020/HLG、HEVC 10-bit，
/// 像素是 HDR 匯出同一顆合成器渲染的，標記與內容一致，進 HDR 匯出
/// 顏色不會變）；素材是 SDR 的用 SDR 工作檔（跟原檔一樣是 709，進
/// HDR 合成器走同一條色彩管理）。是不是 HDR 由 [isHdr] 講；沒人講
/// 的話有 HLG 代理就一定是 HDR，其他一律當「不知道」＝不冒險——
/// 把 HDR 素材換成 SDR 工作檔，Swift 端讀不到 HLG 標記，整支 HDR
/// 匯出會靜默變成 SDR（原本的規則正是這樣：保留 HDR＋1080p＋標準
/// 畫質＝所有 HDR 素材換成 SDR 工作檔）
String? exportProxyPath(MediaSource s, {required bool hdr, bool? isHdr}) {
  if (!s.isVideo) return null;
  if (!hdr) return s.workPath;
  final h = isHdr ?? (s.workHdrPath != null ? true : null);
  if (h == true) return s.workHdrPath;
  if (h == false) return s.workPath;
  return null;
}

/// 快速匯出：影片來源換成代理的條件成立時，回傳替換過的來源清單。
///
/// 代理是「1080p 短邊、轉正好、密關鍵幀」的版本（哪一份見
/// [exportProxyPath]）——輸出不超過 1080p、畫質在標準以下時，拿它當
/// 匯出來源可以把「解 4K HEVC」換成「解 1080p」，合成器每格的像素
/// 也少四倍，是匯出最大宗的省。HDR 模式以前完全走不到這裡（只認
/// SDR 工作檔，而 HDR 模式根本不做那份）——4K HDR 專案選標準畫質
/// 照樣整支從 4K 原檔過 4K 半浮點 CI 合成器，是全 App 最慢的一條路。
/// 選了極致／無損畫質、或輸出解析度超過代理時照舊用原檔，畫質不妥協。
/// 回傳 (來源清單, 換掉幾支)；一支都沒換時清單就是原本那份
(List<MediaSource>, int) fastExportSources(
  List<MediaSource> sources, {
  required int outW,
  required int outH,
  required ExportQuality quality,
  bool hdr = false,
  bool? Function(MediaSource s)? isHdr,
}) {
  final eligible =
      math.min(outW, outH) <= 1080 &&
      (quality == ExportQuality.standard || quality == ExportQuality.low);
  if (!eligible) return (sources, 0);
  var swapped = 0;
  final out = <MediaSource>[];
  for (final s in sources) {
    final p = exportProxyPath(s, hdr: hdr, isHdr: isHdr?.call(s));
    if (p != null) {
      out.add(s.withPath(p));
      swapped++;
    } else {
      out.add(s);
    }
  }
  return (swapped == 0 ? sources : out, swapped);
}

/// 依選項計算輸出畫布大小。
/// 比例：選了固定比例就用它，否則取「最底層（主軌）、最早出現」的影片；
/// 長邊上限不超過素材本身（不放大）。
/// [customAspect] 是裁切算出來的自訂比例（寬/高）。有值就蓋過 [ratio]——
/// 「裁成什麼形狀，成品就是什麼形狀」，不再塞回原本的畫布留黑邊
(int, int) computeCanvasSize(
  TimelineModel timeline,
  ExportResolution res, [
  CanvasRatio ratio = CanvasRatio.original,
  double? customAspect,
]) {
  // 影片「或圖片」都算畫面素材。只認影片的話，純照片的時間軸
  //（照片做成影片）會一路拿到寫死的 1920x1080：比例選單每一項
  // 都顯示同一個數字、匯出畫布跟預覽（直式照片）完全對不上，
  // 浮水印的位置比例整個歪掉（裝置實測回報）
  bool visual(MediaSource s) => s.isVideo || s.kind == ClipKind.image;
  final videos =
      timeline.clips.where((c) => visual(timeline.sourceOf(c))).toList()
        ..sort((a, b) {
          final t = a.track.compareTo(b.track);
          return t != 0 ? t : a.offset.compareTo(b.offset);
        });
  if (videos.isEmpty) return (1920, 1080);

  final base = timeline.sourceOf(videos.first);
  final allVideo = timeline.sources.where(visual);
  // 有些機種／編碼在 initialize() 完成當下 size 還是 0，
  // 讓它一路傳到 ffmpeg 會變成 s=0x0 直接匯出失敗
  var maxLong = allVideo.fold(0, (m, s) => math.max(m, math.max(s.w, s.h)));
  if (maxLong < 16) maxLong = 1920;

  int targetLong = switch (res) {
    ExportResolution.original => maxLong,
    ExportResolution.fhd1080 => 1920,
    ExportResolution.hd720 => 1280,
  };
  // 只縮不放：素材沒那麼大時放大不會更清晰，只是白白變大變慢
  if (targetLong > maxLong) targetLong = maxLong;

  var aspect = customAspect ?? ratio.value ?? base.aspect; // 寬/高
  if (!aspect.isFinite || aspect <= 0) aspect = 16 / 9;
  int w, h;
  if (aspect >= 1) {
    w = targetLong;
    h = (targetLong / aspect).round();
  } else {
    h = targetLong;
    w = (targetLong * aspect).round();
  }
  // H.264 需要偶數尺寸，而且不能是 0
  w -= w % 2;
  h -= h % 2;
  return (math.max(2, w), math.max(2, h));
}
