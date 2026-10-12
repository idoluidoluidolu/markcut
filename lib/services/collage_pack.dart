import 'dart:math' as math;
import 'dart:ui' as ui;

/// 自由模式的自動排版：把一批照片照各自的長寬比塞滿整張畫布
///（測試回報要的：「加入一堆照片自動排列塞滿、再隨機換一種排法」）。
///
/// 做法是「二分樹拼貼」：每張照片是一片葉子，內部節點把兩邊「左右並排
///（等高）」或「上下疊放（等寬）」。葉子的長寬比定了，整棵樹的長寬比就
/// 定了（並排＝比例相加；疊放＝倒數相加再取倒數），每片葉子都是照片本來
/// 的形狀、彼此不重疊也沒縫。隨機長幾百棵樹，挑整體比例最接近畫布的那
/// 一棵。剩下的一點差距整組拉開蓋滿畫布（每張照片兩邊各被裁掉幾個百分
/// 點，看不出來）；差太多（一兩張照片時常常湊不出來）就改成整組置中縮進
/// 畫布留邊——寧可留邊也不把照片裁掉一大塊，不然「照片比例被改變」的
/// 抱怨又會回來。
///
/// 只有數學，沒有 widget；預覽與合成都拿這裡算出來的方塊直接畫。

/// 整組拉開蓋滿畫布的上限：樹的比例跟畫布差在這個範圍內就直接拉滿
///（每張照片兩邊各裁掉不到 10%），差更多就置中縮進去留邊
const kCollagePackMaxStretch = 0.2;

/// 一張照片至少要有「平均大小」的多少：低於這個的排法扣分，
/// 不然隨機樹偶爾會把某一張擠成一個看不見的小點
const _kMinShare = 0.25;

/// 把 [aspects]（每張照片的寬/高）排進比例為 [canvasAspect]（寬/高）的畫布，
/// 回傳每張照片的方塊（畫布的 0~1 比例座標，跟 CollageFreeItem.rect 同一套），
/// 順序跟 [aspects] 一樣。同一組輸入＋同一個 [seed] 永遠排出同一種；
/// 換個 seed 就是另一種排法（「隨機排列」鈕就是換 seed）
List<ui.Rect> packCollage(
  List<double> aspects,
  double canvasAspect, {
  int seed = 0,
}) {
  final n = aspects.length;
  if (n == 0) return const [];
  final rng = math.Random(seed);
  final target = math.log(canvasAspect);
  // 一張照片只有一種排法。幾百棵樹對 30 張也只是幾毫秒；張數少時
  // 多試幾棵能把比例差再壓低一點（三四張常常只差幾棵就從留邊變拉滿）
  final rounds = n == 1 ? 1 : 400;
  _Node? best;
  var bestScore = double.infinity;
  final slots = List<ui.Rect>.filled(n, ui.Rect.zero);
  for (var k = 0; k < rounds; k++) {
    final perm = List<int>.generate(n, (i) => i)..shuffle(rng);
    final node = _grow(perm, 0, n, aspects, rng);
    // 比例差用對數比：差一倍跟差一半一樣遠
    final err = (math.log(node.aspect) - target).abs();
    _place(node, 0, 0, node.aspect, 1, slots);
    var minArea = double.infinity;
    for (final r in slots) {
      minArea = math.min(minArea, r.width * r.height);
    }
    final minShare = minArea / (node.aspect / n);
    final score = err + math.max(0.0, _kMinShare - minShare);
    if (score < bestScore) {
      bestScore = score;
      best = node;
    }
    // 已經幾乎剛好又沒有太小的：不必再找
    if (err < 0.01 && minShare >= _kMinShare) break;
  }
  return _fit(best!, n, canvasAspect);
}

/// 把整棵樹放進畫布：比例差在 [kCollagePackMaxStretch] 內就拉滿，差更多
/// 就置中縮進去留邊。回傳葉子 0..[n]-1 的方塊
List<ui.Rect> _fit(_Node tree, int n, double canvasAspect) {
  final slots = List<ui.Rect>.filled(n, ui.Rect.zero);
  _place(tree, 0, 0, tree.aspect, 1, slots);
  final a = tree.aspect;
  final ratio = (math.log(a) - math.log(canvasAspect)).abs();
  if (ratio <= math.log(1 + kCollagePackMaxStretch)) {
    // 拉滿：樹的框直接對到整張畫布，每片葉子等比例地被拉開一點點
    return [
      for (final r in slots)
        ui.Rect.fromLTWH(r.left / a, r.top, r.width / a, r.height),
    ];
  }
  // 留邊：整組等比縮到放得進畫布、置中。像素空間畫布是 canvasAspect×1
  final s = math.min(canvasAspect / a, 1.0);
  final ox = (canvasAspect - a * s) / 2;
  final oy = (1 - s) / 2;
  return [
    for (final r in slots)
      ui.Rect.fromLTWH(
        (r.left * s + ox) / canvasAspect,
        r.top * s + oy,
        r.width * s / canvasAspect,
        r.height * s,
      ),
  ];
}

/// 拆排法時，兩塊的邊差這麼多以內算「貼在同一條線上」
///（自動排出來的邊是同一套浮點運算算的，差在 1e-12 等級）
const _kEdgeEps = 1e-6;

/// 插新照片時「原本那幾塊被搬動多少」的權重：比例差一樣好時，挑原本的
/// 位置大小變最少的那一種（不然常常整組縮一圈、或讓大張的那塊讓位）
const _kMoveWeight = 0.3;

/// 插新照片時「有一張小於平均的 [_kMinShare]」的扣分倍數。重排可以換
/// 整棵樹去躲，插入只能在原本的樹上找位置，倍數不拉高的話新照片常常
/// 被塞進某個小格子裡再切一半，小到看不清
const _kShareWeight = 3.0;

/// 一張一張插的時候同時留著幾種最好的半成品（只留最好的一種的話，
/// 第一張插得剛好，第二張就沒地方去）。實測（隨機 300 組、五種畫布）
/// 留 12 種時新照片最小的一張平均是平均大小的 0.38、最差 0.17；只留
/// 一種最差會擠到 0.05。一次加很多張時每張少留幾種，總工作量封頂
///（桌機 1＋29 張約 120ms → 20ms）
const _kBeamMax = 12;
const _kBeamWork = 48;

/// 已經排好的畫布上再加照片：原本的排法不打散（使用者回報：「加入照片
/// 後會整個重新排序原本的排列」——以前是連同原本的整組換一棵新的隨機樹
/// 重排，誰在哪裡全部洗牌）。
///
/// 先從現有方塊拆回排法的二分樹：找一刀切得開（每塊都完整落在線的一邊）
/// 的直線或橫線，兩邊再各自切；葉子照各自照片的長寬比——自動排出來的
/// 方塊本來就是這樣長出來的，拆回來就是同一棵樹。新照片一張一張插進樹
/// 裡：每個節點都試「並排在左／右、疊在上／下」，挑整體比例最接近畫布、
/// 沒有哪張被擠太小、原本那幾塊搬動最少的那一種。原本的照片彼此的
/// 左右上下關係一個都不變，只是讓出位置、跟著縮放；最後一樣照畫布拉滿
/// 或置中留邊（同 [packCollage]）。
///
/// [rects]／[aspects]：現有的方塊（畫布 0~1 比例）與各自照片的長寬比，
/// 同順序；[added]：新照片的長寬比。回傳現有的（同順序）再接新加的。
/// 拆不出二分樹（方塊互相重疊、風車形）回 null，由呼叫端決定怎麼放
List<ui.Rect>? extendCollage(
  List<ui.Rect> rects,
  List<double> aspects,
  List<double> added,
  double canvasAspect,
) {
  final m = rects.length;
  if (m == 0) return packCollage(added, canvasAspect);
  final all = [...aspects, ...added];
  final rebuilt = _rebuild([for (var i = 0; i < m; i++) i], rects, all);
  if (rebuilt == null) return null;
  final width = (_kBeamWork ~/ added.length).clamp(2, _kBeamMax);
  var beam = [rebuilt];
  for (var k = 0; k < added.length; k++) {
    final count = m + k + 1;
    final leaf = _leaf(m + k, all);
    final next = <(_Node, double)>[];
    for (final tree in beam) {
      for (final at in _nodes(tree)) {
        for (final horiz in const [true, false]) {
          for (final before in const [false, true]) {
            final cand = _replace(
              tree,
              at,
              before
                  ? _Node.join(horiz, leaf, at)
                  : _Node.join(horiz, at, leaf),
            );
            next.add((cand, _extendScore(cand, count, canvasAspect, rects)));
          }
        }
      }
    }
    next.sort((a, b) => a.$2.compareTo(b.$2));
    beam = [for (final c in next.take(width)) c.$1];
  }
  return _fit(beam.first, all.length, canvasAspect);
}

/// 插好之後的樹打幾分（越小越好）：整體比例離畫布多遠＋有沒有哪張被擠
/// 太小＋原本那幾塊（[before]，葉子 0..before.length-1）被搬動多少
double _extendScore(
  _Node tree,
  int count,
  double canvasAspect,
  List<ui.Rect> before,
) {
  final slots = List<ui.Rect>.filled(count, ui.Rect.zero);
  _place(tree, 0, 0, tree.aspect, 1, slots);
  var minArea = double.infinity;
  for (final r in slots) {
    minArea = math.min(minArea, r.width * r.height);
  }
  final minShare = minArea / (tree.aspect / count);
  final fitted = _fit(tree, count, canvasAspect);
  var moved = 0.0;
  for (var i = 0; i < before.length; i++) {
    final a = before[i], b = fitted[i];
    moved +=
        (a.left - b.left).abs() +
        (a.top - b.top).abs() +
        (a.right - b.right).abs() +
        (a.bottom - b.bottom).abs();
  }
  return (math.log(tree.aspect) - math.log(canvasAspect)).abs() +
      _kShareWeight * math.max(0.0, _kMinShare - minShare) +
      _kMoveWeight * moved / before.length;
}

/// 照片 [i] 的葉子（壞資料當正方形，同 [_grow]）
_Node _leaf(int i, List<double> aspects) {
  final a = aspects[i];
  return _Node.leaf(i, a.isFinite && a > 0 ? a : 1.0);
}

/// 從方塊拆回二分樹：[ids] 這幾塊找一刀切得開的線（先試直的＝左右並排，
/// 再試橫的＝上下疊放），兩邊各自再拆。有空格（宮格抄過來、少幾張）
/// 也拆得開；互相重疊或風車形拆不開就回 null
_Node? _rebuild(List<int> ids, List<ui.Rect> rects, List<double> aspects) {
  if (ids.length == 1) return _leaf(ids.single, aspects);
  for (final horiz in const [true, false]) {
    final cuts = {
      for (final i in ids) horiz ? rects[i].right : rects[i].bottom,
    }.toList()..sort();
    for (final c in cuts) {
      final a = <int>[], b = <int>[];
      var ok = true;
      for (final i in ids) {
        final r = rects[i];
        if ((horiz ? r.right : r.bottom) <= c + _kEdgeEps) {
          a.add(i);
        } else if ((horiz ? r.left : r.top) >= c - _kEdgeEps) {
          b.add(i);
        } else {
          ok = false;
          break;
        }
      }
      if (!ok || a.isEmpty || b.isEmpty) continue;
      final x = _rebuild(a, rects, aspects);
      final y = _rebuild(b, rects, aspects);
      if (x == null || y == null) return null;
      return _Node.join(horiz, x, y);
    }
  }
  return null;
}

/// 樹上的每一個節點（葉子跟內部節點都算：新照片可以插在任何一個旁邊）
List<_Node> _nodes(_Node n) => [
  n,
  if (n.leaf < 0) ...[..._nodes(n.a!), ..._nodes(n.b!)],
];

/// 把樹裡的 [target]（照「哪一個」比）換成 [repl]，一路往上重建比例
_Node _replace(_Node n, _Node target, _Node repl) {
  if (identical(n, target)) return repl;
  if (n.leaf >= 0) return n;
  final a = _replace(n.a!, target, repl);
  final b = _replace(n.b!, target, repl);
  if (identical(a, n.a) && identical(b, n.b)) return n;
  return _Node.join(n.horiz, a, b);
}

/// 樹的節點：葉子記照片索引；內部節點記兩個孩子跟「並排／疊放」。
/// [aspect] 建好就算好（並排相加、疊放倒數相加再取倒數）
class _Node {
  final int leaf;
  final bool horiz;
  final _Node? a;
  final _Node? b;
  final double aspect;

  _Node.leaf(this.leaf, this.aspect) : horiz = false, a = null, b = null;

  _Node.join(this.horiz, _Node x, _Node y)
    : leaf = -1,
      a = x,
      b = y,
      aspect = horiz
          ? x.aspect + y.aspect
          : (x.aspect * y.aspect) / (x.aspect + y.aspect);
}

/// 把 perm[lo, hi) 隨機長成一棵樹：切點跟並排／疊放都隨機，
/// 一張大的配幾張小的、兩排三排都長得出來
_Node _grow(List<int> perm, int lo, int hi, List<double> aspects, math.Random rng) {
  if (hi - lo == 1) {
    final i = perm[lo];
    // 壞資料（0 或負的）當正方形，不要讓一張圖把整棵樹算成 NaN
    final a = aspects[i];
    return _Node.leaf(i, a.isFinite && a > 0 ? a : 1.0);
  }
  final k = lo + 1 + rng.nextInt(hi - lo - 1);
  return _Node.join(
    rng.nextBool(),
    _grow(perm, lo, k, aspects, rng),
    _grow(perm, k, hi, aspects, rng),
  );
}

/// 把節點放進 (x,y,w,h) 這個框：框的比例就是節點的比例，所以並排時
/// 寬度照兩邊比例分、疊放時高度照兩邊比例的倒數分，葉子自然是照片的形狀
void _place(_Node n, double x, double y, double w, double h, List<ui.Rect> out) {
  if (n.leaf >= 0) {
    out[n.leaf] = ui.Rect.fromLTWH(x, y, w, h);
    return;
  }
  final a = n.a!, b = n.b!;
  if (n.horiz) {
    final wa = w * a.aspect / (a.aspect + b.aspect);
    _place(a, x, y, wa, h, out);
    _place(b, x + wa, y, w - wa, h, out);
  } else {
    // 等寬疊放：高度 ∝ 1/比例，所以上面那塊佔 b/(a+b)
    final ha = h * b.aspect / (a.aspect + b.aspect);
    _place(a, x, y, w, ha, out);
    _place(b, x, y + ha, w, h - ha, out);
  }
}
