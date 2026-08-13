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

/// 輸出畫面比例（原始 = 跟第一個影片一樣）
enum CanvasRatio { original, r16_9, r9_16, r1_1, r4_3, r3_4 }

extension CanvasRatioInfo on CanvasRatio {
  String get label => switch (this) {
        CanvasRatio.original => '原始',
        CanvasRatio.r16_9 => '16:9',
        CanvasRatio.r9_16 => '9:16',
        CanvasRatio.r1_1 => '1:1',
        CanvasRatio.r4_3 => '4:3',
        CanvasRatio.r3_4 => '3:4',
      };

  /// 寬/高；null = 依素材
  double? get value => switch (this) {
        CanvasRatio.original => null,
        CanvasRatio.r16_9 => 16 / 9,
        CanvasRatio.r9_16 => 9 / 16,
        CanvasRatio.r1_1 => 1,
        CanvasRatio.r4_3 => 4 / 3,
        CanvasRatio.r3_4 => 3 / 4,
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
  String get label => switch (this) {
        ExportQuality.low => '低',
        ExportQuality.standard => '標準',
        ExportQuality.ultra => '極高',
        ExportQuality.lossless => '最高',
      };

  String get note => switch (this) {
        ExportQuality.low => '匯出速度最快',
        ExportQuality.standard => '視覺無損，建議日常使用',
        ExportQuality.ultra => '檔案約大一倍',
        ExportQuality.lossless => '位元率拉滿，檔案非常大',
      };

  int get crf => switch (this) {
        ExportQuality.low => 26,
        ExportQuality.standard => 17,
        ExportQuality.ultra => 12,
        ExportQuality.lossless => 0,
      };

  /// 粗估檔案大小相對「標準」的倍率
  double get sizeFactor => switch (this) {
        ExportQuality.low => 0.45,
        ExportQuality.standard => 1,
        ExportQuality.ultra => 1.8,
        ExportQuality.lossless => 6,
      };
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
  });

  /// 輸出影片實際長度（變速後）
  double get outputDuration => math.max(0.01, timelineDuration / speed);

  /// 動畫週期（閃爍一輪／跑馬燈掃一輪的秒數）
  double get wmCycle => wmAnimation == WmAnimation.marquee
      ? 8 / wmSpeed
      : 1.2 / wmSpeed;

  /// 閃爍時亮著的秒數
  double get wmOn => wmCycle * (0.58 * wmRange).clamp(0.1, 0.92);
}

/// 依選項計算輸出畫布大小。
/// 比例：選了固定比例就用它，否則取「最上層、最早出現」的影片片段；
/// 長邊上限不超過素材本身（不放大）。
(int, int) computeCanvasSize(TimelineModel timeline, ExportResolution res,
    [CanvasRatio ratio = CanvasRatio.original]) {
  final videos = timeline.clips
      .where((c) => timeline.sourceOf(c).isVideo)
      .toList()
    ..sort((a, b) {
      final t = a.track.compareTo(b.track);
      return t != 0 ? t : a.offset.compareTo(b.offset);
    });
  if (videos.isEmpty) return (1920, 1080);

  final base = timeline.sourceOf(videos.first);
  final allVideo = timeline.sources.where((s) => s.isVideo);
  // 有些機種／編碼在 initialize() 完成當下 size 還是 0，
  // 讓它一路傳到 ffmpeg 會變成 s=0x0 直接匯出失敗
  var maxLong = allVideo.map((s) => math.max(s.w, s.h)).reduce(math.max);
  if (maxLong < 16) maxLong = 1920;

  int targetLong = switch (res) {
    ExportResolution.original => maxLong,
    ExportResolution.fhd1080 => 1920,
    ExportResolution.hd720 => 1280,
  };
  // 只縮不放：素材沒那麼大時放大不會更清晰，只是白白變大變慢
  if (targetLong > maxLong) targetLong = maxLong;

  var aspect = ratio.value ?? base.aspect; // 寬/高
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
