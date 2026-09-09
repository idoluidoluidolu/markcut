import 'dart:typed_data';
import 'dart:math' as math;

import 'gif_strip.dart' show nearestLoaded, stripFillOrder;
import 'native_frames.dart' show NativeFrameSample;

/// 精抽的縮圖帶一秒一格（[thumbStripCount]）、最多幾格
const kThumbCellSeconds = 1.0;
const kThumbStripMax = 120;

/// 一條縮圖帶要幾格：一秒一格、最少 10、最多 [kThumbStripMax]。
///
/// 以前固定 10 格：48 秒的片一格 4.8 秒，時間軸縮放到一磚 1.5 秒時同一張
/// 圖連鋪六磚，指針下那磚跟上方畫面差好幾秒（實測 199「指針位置的縮圖跟
/// 播放畫面不同」）。壞輸入（長度讀不到）回 10
int thumbStripCount(double duration) {
  if (!duration.isFinite || duration <= 0) return 10;
  return (duration / kThumbCellSeconds).ceil().clamp(10, kThumbStripMax);
}

/// 時間軸上一塊磚該畫縮圖帶的哪一格：磚中央那一刻的來源時間落在哪一格。
/// [centerFrac]＝磚中央在片段方塊裡的位置（0～1），[reverse]＝倒轉片段
///（來源時間從右往左走）。
///
/// 以前用 `i0 + k * span ~/ count`：磚「左緣」那格的整數近似——指針落在
/// 磚裡任何位置，畫的都可能是一磚寬以前的畫面
int stripIndexForTile({
  required double trimStart,
  required double trimEnd,
  required double duration,
  required int frames,
  required double centerFrac,
  bool reverse = false,
}) {
  if (frames <= 0 || !duration.isFinite || duration <= 0) return 0;
  final f = centerFrac.isFinite ? centerFrac.clamp(0.0, 1.0) : 0.0;
  final span = trimEnd - trimStart;
  final at = reverse ? trimEnd - span * f : trimStart + span * f;
  if (!at.isFinite) return 0;
  return (at / duration * frames).floor().clamp(0, frames - 1);
}

/// 時間軸縮圖帶的「粗抽」：進場閘門用（使用者指定：先把縮圖跑完再放行，
/// 最高 5 秒）。
///
/// 原本的縮圖帶是精抽（容忍 0.15 秒）：手機錄的 HEVC 原檔關鍵幀每
/// 20~28 格，每一格縮圖都得從上一個關鍵幀一路解 20 幾張 4K 過來，
/// 五支要 7~15 秒——所以以前才排到「全部閒置才補」，而 4K HDR 那個閒置
/// 根本不會來（代理轉 66 秒、使用者全程在滑），結果就是只剩每支一張封面
/// 拉滿整條（實測回報「縮圖跟畫面對不上、只有第一張」）。
///
/// 粗抽一格只解一張關鍵幀（4K 也只要幾十毫秒），五支 1~2 秒就整條有了。
/// 容忍值放寬會有「拿到的不是要的那格」的問題——所以每一格都用原生回報
/// 的 actualSeconds 放進它真正屬於的格子，空的格子借最近的一格。縮圖帶
/// 從不宣稱精準（它是印象，不是指針），但每一格畫的都是那一段附近真的
/// 存在的畫面、順序也對。閒置時再由精抽把它升級。
///
/// 一格要差多少毫秒才能貼到關鍵幀：半格寬，但至少 1 秒——手機 HEVC 的
/// GOP 最長約 1 秒，窗口比 GOP 短的話裡面可能沒有關鍵幀，解碼器就得
/// 精準解到那一格（回到慢路）。短片（半格不到 1 秒）因此會有相鄰格子
/// 共用同一個關鍵幀，那是誠實的：2 秒的片本來就只有兩三個關鍵幀
int coarseStripTolMs(double duration, int count) {
  if (!duration.isFinite || duration <= 0 || count <= 0) return 1000;
  final halfCellMs = duration / count * 1000 / 2;
  return math.max(1000, halfCellMs.round());
}

/// 原生回報的實際取樣時間落在哪一格
int coarseCellIndex(double actualSeconds, double duration, int count) {
  if (!duration.isFinite || duration <= 0 || count <= 0) return 0;
  return (actualSeconds / duration * count).floor().clamp(0, count - 1);
}

/// 空格借最近的一格（跟 GIF 頁的縮圖帶同一套）；一格都沒有就回空清單
List<Uint8List> fillStripGaps(List<Uint8List?> cells) {
  if (cells.every((c) => c == null)) return const [];
  return [for (var i = 0; i < cells.length; i++) nearestLoaded(cells, i)!];
}

/// 一格的抽幀：[seconds] 那一刻、允許差 [tolMs] 毫秒。回 null＝抽不到
typedef CoarseStripFetch =
    Future<NativeFrameSample?> Function(double seconds, int tolMs);

/// 抽一條粗縮圖帶。[deadline] 到了就停、[alive] 回 false 就停——已經抽到
/// 的照樣鋪成一整條（二分順序：頭、尾、中……被截斷也是均勻的）。
/// 回傳長度＝[count]（空格借最近的），一格都沒抽到才回空清單
Future<List<Uint8List>> loadCoarseStrip({
  required double duration,
  required int count,
  required CoarseStripFetch fetch,
  DateTime? deadline,
  bool Function()? alive,
  // 測試用：假時鐘才能把「截止時間到了」驗得確定，不靠真時鐘的毫秒競賽
  DateTime Function() now = DateTime.now,
}) async {
  if (!duration.isFinite || duration <= 0 || count <= 0) return const [];
  final cells = List<Uint8List?>.filled(count, null);
  final tol = coarseStripTolMs(duration, count);
  for (final i in stripFillOrder(count)) {
    if (alive != null && !alive()) break;
    // 剩餘預算也套在「這一次抽」身上：原生永遠不回（或測試環境沒掛
    // 假通道）時，只在兩次抽之間看時間是攔不住的，5 秒就不是硬上限了。
    // 逾時的那一格當抽不到；原生晚到的回覆落在已完成的 Future 上，丟掉
    final remaining = deadline?.difference(now());
    if (remaining != null && remaining <= Duration.zero) break;
    // fetch 交出來的 Future 可能比宣告的窄（async 閉包會推成
    // Future<NativeFrameSample>）：直接在它上面 .timeout(onTimeout: () => null)
    // 會在執行期炸型別——onTimeout 的回傳要對上那顆 Future 真正的型別參數。
    // 先 then 一次換成我們宣告的可空型別，timeout 才掛得上去
    var pending = fetch(
      duration * (i + 0.5) / count,
      tol,
    ).then<NativeFrameSample?>((s) => s);
    if (remaining != null) {
      pending = pending.timeout(remaining, onTimeout: () => null);
    }
    final sample = await pending;
    if (sample == null) continue;
    // 舊原生端不回 actualSeconds：只能相信它落在要的那格
    final at = sample.actualSeconds;
    final cell = at == null ? i : coarseCellIndex(at, duration, count);
    // 同一個關鍵幀被相鄰兩格要到：先到的留著，後到的不覆蓋
    cells[cell] ??= sample.bytes;
  }
  return fillStripGaps(cells);
}
