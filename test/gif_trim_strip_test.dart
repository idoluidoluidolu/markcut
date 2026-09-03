// GIF 頁修剪條的手勢層。
//
// 舊行為（已刪）：起點把手、終點把手、播放頭各一個熱區疊在 Stack 裡
// 搶手勢，把手贏播放頭。使用者指定改成「拉桿無法靠觸控拖曳，頭尾一律
// 靠自己按起點終點」，所以這一條的每一次觸碰都只做一件事——移動播放
// 頭，而且不受起訖點限制。
//
// 這支測試釘住三件事：
//   1. 在把手上拖曳不會動到起訖點（把手只剩畫的）
//   2. 播放頭可以被拖到選取範圍外面，而且停在那裡
//   3. 修剪條上根本沒有能改起訖點的出口
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/widgets/gif_trim_strip.dart';

const double kDur = 30;
const double kStripW = 300; // 1px = 0.1 秒
const double kStart = 10; // xs = 100
const double kEnd = 20; // xe = 200

/// 照 GifScreen 的接法把修剪條接起來：拖曳一律走播放頭
class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  // 起訖點：這一頁沒有任何手勢能改它，只有「設起點／設終點」兩顆鈕
  double start = kStart;
  double end = kEnd;

  final pos = ValueNotifier<double>(12);
  double? _from;
  double _acc = 0;

  /// 收到的回呼順序，用來確認把手沒有把手勢吃掉
  final events = <String>[];

  void _scrubBySeconds(double dt) {
    final f = _from;
    if (f == null) return;
    _acc += dt;
    pos.value = (f + _acc).clamp(0.0, kDur);
  }

  /// 「設起點」／「設終點」：唯一能改起訖點的入口（規則見
  /// gif_trim_range.dart，這裡只要有東西能改就好）
  void setStartHere() => setState(() => start = pos.value);
  void setEndHere() => setState(() => end = pos.value);

  @override
  void dispose() {
    pos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(
        width: kStripW,
        child: GifTrimStrip(
          dur: kDur,
          start: start,
          end: end,
          pos: pos,
          cells: List<Uint8List?>.filled(10, null),
          onTapAt: (t) {
            events.add('tap');
            pos.value = t;
          },
          onScrubStart: (t) {
            events.add('scrubStart');
            _from = t;
            _acc = 0;
            pos.value = t;
          },
          onScrubBy: (dt) {
            events.add('scrubBy');
            _scrubBySeconds(dt);
          },
          onScrubEnd: () {
            events.add('scrubEnd');
            _from = null;
          },
        ),
      ),
    ),
  );
}

void main() {
  /// 修剪條左緣的螢幕座標（置中的 300pt）
  Offset at(double x, WidgetTester tester) {
    final r = tester.getRect(find.byType(GifTrimStrip));
    return Offset(r.left + x, r.center.dy);
  }

  Future<_HostState> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: _Host()));
    return tester.state<_HostState>(find.byType(_Host));
  }

  /// 從修剪條的 [fromX] 下手，分兩段拖 [dx] px 之後放開。
  /// 分兩段是為了讓 onStart 之外也真的收到 onUpdate（一次到位的話
  /// 手勢辨識器只會給 onStart）
  Future<void> dragStrip(WidgetTester tester, double fromX, double dx) async {
    final g = await tester.startGesture(at(fromX, tester));
    await tester.pump();
    await g.moveBy(Offset(dx / 2, 0));
    await tester.pump();
    await g.moveBy(Offset(dx / 2, 0));
    await tester.pump();
    await g.up();
    await tester.pump();
  }

  testWidgets('在起點把手上拖曳：起訖點動都不動，動的是播放頭', (tester) async {
    final host = await pumpHost(tester);
    // 起點直條佔 [100, 113]：正中間（106.5px＝10.65 秒）下手，
    // 往左拉 50px＝5 秒
    await dragStrip(tester, 100 + GifTrimStrip.barWidth / 2, -50);

    expect(host.start, kStart, reason: '把手不吃觸控，起點不該被拉走');
    expect(host.end, kEnd);
    expect(host.events, contains('scrubStart'));
    expect(host.events, contains('scrubBy'));
    expect(host.pos.value, closeTo(5.65, 0.01));
  });

  testWidgets('在終點把手上拖曳：一樣只有播放頭會動', (tester) async {
    final host = await pumpHost(tester);
    // 終點直條佔 [187, 200]
    await dragStrip(tester, 200 - GifTrimStrip.barWidth / 2, 40);

    expect(host.start, kStart);
    expect(host.end, kEnd, reason: '把手不吃觸控，終點不該被拉走');
    expect(host.pos.value, closeTo(23.35, 0.01));
  });

  testWidgets('播放頭拖到選取範圍右邊外面，放手後停在那裡', (tester) async {
    final host = await pumpHost(tester);
    // 從範圍中間（150px＝15 秒）往右拉 120px＝12 秒 → 27 秒，遠在終點外
    await dragStrip(tester, 150, 120);

    expect(host.pos.value, closeTo(27, 0.01));
    expect(host.pos.value, greaterThan(host.end), reason: '指針不再被夾回起訖點內');
    // 放手之後不會被誰彈回範圍裡
    await tester.pump(const Duration(milliseconds: 500));
    expect(host.pos.value, closeTo(27, 0.01));
  });

  testWidgets('播放頭也可以拖到起點左邊外面', (tester) async {
    final host = await pumpHost(tester);
    await dragStrip(tester, 150, -130);

    expect(host.pos.value, closeTo(2, 0.01));
    expect(host.pos.value, lessThan(host.start));
  });

  testWidgets('點在把手上也是跳指針（不是抓把手）', (tester) async {
    final host = await pumpHost(tester);
    await tester.tapAt(at(100 + GifTrimStrip.barWidth / 2, tester));
    await tester.pump();

    expect(host.events, contains('tap'));
    expect(host.start, kStart);
    expect(host.end, kEnd);
    expect(host.pos.value, closeTo(10.65, 0.01));
  });

  testWidgets('起點／終點只有按鈕改得動', (tester) async {
    final host = await pumpHost(tester);
    // 指針拖到範圍外的 27 秒
    await dragStrip(tester, 150, 120);
    expect(host.end, kEnd, reason: '拖曳本身不會改終點');

    // 按下「設終點」才會動
    host.setEndHere();
    await tester.pump();
    expect(host.end, closeTo(27, 0.01));

    host.pos.value = 3;
    host.setStartHere();
    await tester.pump();
    expect(host.start, 3);
  });
}
