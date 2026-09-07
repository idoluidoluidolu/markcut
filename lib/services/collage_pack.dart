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
  final tree = best!;
  _place(tree, 0, 0, tree.aspect, 1, slots);
  final a = tree.aspect;
  final ratio = (math.log(a) - target).abs();
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
