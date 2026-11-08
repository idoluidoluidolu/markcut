import 'dart:math' as math;

import '../models/timeline.dart';

/// 快速 Vlog：一堆影片各取一小段、照挑選順序頭尾接成一支。
///
/// 使用者 11-07 的規格：「各取兩秒（預設）、可以調整時間跟段落、
/// 也可以個別調整影片長度，不卡死全部都要共同秒數」；畫布選甲＝原本的
/// 剪輯畫面，左上多一顆「每段 N 秒」。11-08：要能「全部改成 0.5 秒一個」，
/// 左上那顆放大、秒數表加快選鈕（[kVlogPresets]）。
///
/// 規則：
/// - 剛接進來的每一支取「中間」[kVlogDefaultSec] 秒；不到就整支
/// - 改「每段」＝每一段都換成新長度（中心不動），個別改過的也一起改；
///   原片不夠長的就整支
/// - 個別改一段（選著它的「這段」、拖把手、換段、變速）照樣可以，時間軸
///   上標琥珀字；「跟著每段走」不另外記旗標，看長度就知道（見 [vlogFollows]）
/// - 改完長度整軌頭尾接齊：變長的把後面推開、變短的空隙收掉、從 0 開始

/// 每段預設幾秒（使用者指定 2 秒）
const double kVlogDefaultSec = 2.0;

/// 「每段」滑桿的範圍。下限 0.5：再短就只剩一閃，影片看不出內容
const double kVlogMinSec = 0.5;
const double kVlogMaxSec = 10.0;

/// 秒數表上那排快選（使用者 11-08 舉的例子就是「全部改成 0.5 秒一個」）
const List<double> kVlogPresets = [0.5, 1, 1.5, 2, 3, 5];

/// 長度差多少以內算「一樣長」：滑桿 0.1 秒一格，拖把手、變速換算都會
/// 留浮點尾數
const double kVlogLenTolerance = 0.05;

/// 秒數給人看：整數不帶小數點（「2」），其他一位小數（「2.5」）
String vlogSecLabel(double sec) {
  final r = (sec * 10).round() / 10;
  return r % 1 == 0 ? r.toInt().toString() : r.toStringAsFixed(1);
}

/// 這種素材能不能當 Vlog 的一段：影片、圖片（GIF 也算）。聲音、文字、
/// 浮水印、馬賽克都是疊在上面的東西，不是「一段」
bool isVlogSegment(MediaSource s) =>
    s.kind == ClipKind.video || s.kind == ClipKind.image;

/// Vlog 那一軌上的每一段（照時間排）
List<TimelineClip> vlogSegments(TimelineModel tl, {int track = 0}) => [
  for (final c in tl.onTrack(track))
    if (isVlogSegment(tl.sourceOf(c))) c,
];

/// 素材本身有多長（原片秒）。靜態圖片沒有長度上限，回 null
double? _sourceCap(MediaSource s) =>
    s.kind == ClipKind.image && !s.isGif ? null : s.duration;

double _speedOf(TimelineClip c) => c.speed.clamp(0.1, 16.0).toDouble();

/// 這一段是不是跟著「每段 [sec] 秒」走（時間軸片段右下角標白字；不是＝
/// 個別改過，標琥珀字）：時間軸長度就是 [sec]；或素材本身比 [sec] 短、
/// 整支都已經用上了（它能給的最長就這樣，也算跟著走）
bool vlogFollows(TimelineClip c, MediaSource s, double sec) {
  if ((c.length - sec).abs() <= kVlogLenTolerance) return true;
  final cap = _sourceCap(s);
  if (cap == null) return false;
  final capLen = cap / _speedOf(c);
  return capLen < sec - kVlogLenTolerance && c.srcLength >= cap - 0.01;
}

/// 把 [c] 改成時間軸上 [len] 秒長。影片的中心不動（夾在原片範圍內，
/// 原片不夠長就整支）；靜態圖片從 0 開始
void vlogSetLength(TimelineClip c, MediaSource s, double len) {
  final speed = _speedOf(c);
  final cap = _sourceCap(s);
  var srcLen = math.max(0.0, len) * speed;
  if (cap == null) {
    c.trimStart = 0;
    c.trimEnd = srcLen;
    return;
  }
  srcLen = math.min(srcLen, cap);
  final center = (c.trimStart + c.trimEnd) / 2;
  final start = (center - srcLen / 2)
      .clamp(0.0, math.max(0.0, cap - srcLen))
      .toDouble();
  c.trimStart = start;
  c.trimEnd = start + srcLen;
}

/// 剛接進來的一支：取原片正中間 [len] 秒（不到就整支）
void vlogTakeMiddle(TimelineClip c, MediaSource s, double len) {
  final cap = _sourceCap(s);
  c.trimStart = 0;
  c.trimEnd = cap ?? 0;
  vlogSetLength(c, s, len);
}

/// 整軌頭尾接齊：變長的把後面推開、變短的空隙收掉，從 0 開始
void vlogRelay(TimelineModel tl, {int track = 0}) {
  tl.resolveOverlaps(track: track);
  tl.closeGaps(track: track, fromZero: true);
}

/// 一次「改每段」（一張秒數表從打開到關掉）：開始時記下每一段原本取的
/// 是哪一截，之後每一格（滑桿每動一格、每按一次快選）都從原本的樣子重算。
///
/// 為什麼不一格一格接著改：中途碰到原片頭尾被夾住的段，中心會一格一格
/// 偏掉，拖回原值回不到原本那一截
class VlogSecondsEdit {
  VlogSecondsEdit(this.tl, {this.track = 0}) {
    for (final c in vlogSegments(tl, track: track)) {
      _orig[c.id] = (c.trimStart, c.trimEnd);
    }
  }

  final TimelineModel tl;
  final int track;
  final Map<int, (double, double)> _orig = {};

  /// 這次會動到幾段
  int get count => _orig.length;

  /// 每一段都改成 [sec] 秒（原片不夠長的整支），整軌接齊
  void apply(double sec) {
    for (final c in tl.clips) {
      final o = _orig[c.id];
      if (o == null) continue;
      c.trimStart = o.$1;
      c.trimEnd = o.$2;
      vlogSetLength(c, tl.sourceOf(c), sec);
    }
    vlogRelay(tl, track: track);
  }
}

/// 「每段」改成 [to] 秒：每一段都換成新長度，再整軌接齊。回傳改了幾段
int vlogApplySeconds(TimelineModel tl, {required double to, int track = 0}) {
  final edit = VlogSecondsEdit(tl, track: track)..apply(to);
  return edit.count;
}

/// 這一段最長能拉到幾秒（時間軸秒）：滑桿上限，不超過 [kVlogMaxSec]，
/// 也不超過原片能給的長度
double vlogMaxLength(TimelineClip c, MediaSource s) {
  final cap = _sourceCap(s);
  final max = cap == null ? kVlogMaxSec : cap / _speedOf(c);
  return math.min(kVlogMaxSec, math.max(kVlogMinSec, max));
}
