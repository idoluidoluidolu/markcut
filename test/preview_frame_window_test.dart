import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/preview_frame_window.dart';

/// 假的已解碼格：記住自己是第幾格、多大、有沒有被釋放
class _Frame {
  _Frame(this.index, this.bytes);
  final int index;
  final int bytes;
  bool disposed = false;
}

/// 拖曳快取窗的測試台：記下每一次解碼、每一格的釋放，
/// 也記窗裡最多同時留過幾格
class _Bench {
  _Bench({
    this.frameBytes = 2 << 20,
    this.manual = false,
    int byteBudget = 48 << 20,
  }) {
    window = PreviewFrameWindow<_Frame>(
      load: (i) {
        loads.add(i);
        if (manual) {
          final c = Completer<_Frame?>();
          waiting[i] = c;
          return c.future;
        }
        return Future<_Frame?>(() => _make(i));
      },
      bytesOf: (f) => f.bytes,
      disposeFrame: (f) {
        expect(f.disposed, isFalse, reason: '同一格不能釋放兩次');
        f.disposed = true;
      },
      onReady: () => ready++,
      byteBudget: byteBudget,
    );
  }

  final int frameBytes;

  /// 這支素材抽了幾格快取幀
  final int count = 400;
  final bool manual;
  late final PreviewFrameWindow<_Frame> window;
  final loads = <int>[];
  final made = <_Frame>[];
  final waiting = <int, Completer<_Frame?>>{};
  var ready = 0;
  var peak = 0;

  _Frame _make(int i) {
    final f = _Frame(i, frameBytes);
    made.add(f);
    return f;
  }

  bool available(int i) => i >= 0 && i < count;

  void focus(int center) {
    window.focus(center, available: available);
    if (window.length > peak) peak = window.length;
  }

  /// 讓背景解碼跑完，途中每一步都量一次窗裡留了幾格
  Future<void> settle() async {
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(Duration.zero);
      if (window.length > peak) peak = window.length;
      if (window.pending == 0) break;
    }
  }

  void complete(int i) => waiting.remove(i)!.complete(_make(i));

  /// 還活著（沒被釋放）的格子數，要剛好等於窗裡留的
  int get live => made.where((f) => !f.disposed).length;
}

void main() {
  test('跳兩次遠的位置：解完時再限額，任何時候都不超過 24 格', () async {
    final b = _Bench();
    b.focus(100);
    await b.settle();
    expect(b.window.length, 21, reason: '前後各 10 格');
    b.focus(300);
    await b.settle();
    b.focus(30);
    await b.settle();
    expect(b.peak, lessThanOrEqualTo(24));
    expect(b.window.length, lessThanOrEqualTo(24));
    for (var i = 20; i <= 40; i++) {
      expect(b.window[i], isNotNull, reason: '第 $i 格在窗內');
    }
    expect(b.live, b.window.length, reason: '丟掉的格子都要釋放');
    expect(b.window.bytes, b.window.length * b.frameBytes);
  });

  test('同時最多解 2 張；解好時手指早就拖走的結果直接丟、不進快取', () async {
    final b = _Bench(manual: true);
    b.focus(50);
    expect(b.loads, [50, 51]);
    expect(b.window.pending, 2);
    // 拖到很遠：舊的兩張還在解，新位置不能再多開
    b.focus(200);
    expect(b.loads, [50, 51]);
    b.complete(50);
    b.complete(51);
    await pumpEventQueue();
    expect(b.window[50], isNull);
    expect(b.window[51], isNull);
    expect(b.made.where((f) => f.index < 100).every((f) => f.disposed), isTrue);
    // 讓出來的名額馬上給新位置
    expect(b.loads.skip(2).take(2), [200, 201]);
    expect(b.window.pending, 2);
  });

  test('格子比預期大：窗照位元組上限縮小，不做「解完當場丟」的白工', () async {
    // 8MB 一格、上限 48MB＝只放得下 6 格
    final b = _Bench(frameBytes: 8 << 20);
    b.focus(100);
    await b.settle();
    expect(b.window.slots, 6);
    expect(b.window.length, 6);
    expect(b.made.where((f) => f.disposed), isEmpty);
    // 解過的格子數＝留下的格子數（只多中心旁邊同時在解的那一張）
    expect(b.loads.length, lessThanOrEqualTo(7));
    final before = b.loads.length;
    b.focus(101);
    await b.settle();
    expect(b.loads.length - before, 1, reason: '往前一格只要補解一張');
    expect(b.window.length, 6);
    expect(b.window.bytes, lessThanOrEqualTo(48 << 20));
    expect(b.live, b.window.length);
  });

  test('一格就超過整個上限：這個窗不解了，也不會每次 focus 都重解', () async {
    final b = _Bench(frameBytes: 64 << 20);
    b.focus(10);
    await b.settle();
    final first = b.loads.length;
    expect(b.window.length, 0);
    for (var i = 11; i < 20; i++) {
      b.focus(i);
      await b.settle();
    }
    expect(b.loads.length, first);
    expect(b.live, 0);
  });

  test('只有正要顯示的那格解好才通知重畫', () async {
    final b = _Bench();
    b.focus(40);
    await b.settle();
    expect(b.ready, 1);
    // 中心早就解好：再 focus 一次不該再通知
    b.focus(40);
    await b.settle();
    expect(b.ready, 1);
  });

  test('同一支素材兩層同時要不同位置：兩邊的格子都留得住、各自通知', () async {
    final b = _Bench();
    // 每一格畫面兩層都會重建、各自 focus 一次
    for (var round = 0; round < 3; round++) {
      b.window.focus(50, available: b.available, consumer: 'a');
      b.window.focus(300, available: b.available, consumer: 'b');
      await b.settle();
    }
    for (final i in [49, 50, 51, 299, 300, 301]) {
      expect(b.window[i], isNotNull, reason: '第 $i 格');
    }
    expect(b.window.length, lessThanOrEqualTo(24));
    expect(b.ready, greaterThanOrEqualTo(2), reason: '兩層的中心各通知一次');
    expect(b.live, b.window.length);
  });

  test('只剩一層在要：另一層的中心過一陣子就不算，窗回到單一中心', () async {
    final b = _Bench();
    b.window.focus(50, available: b.available, consumer: 'a');
    b.window.focus(300, available: b.available, consumer: 'b');
    await b.settle();
    for (var i = 0; i < 12; i++) {
      b.window.focus(300, available: b.available, consumer: 'b');
      await b.settle();
    }
    for (var i = 290; i <= 310; i++) {
      expect(b.window[i], isNotNull, reason: '第 $i 格');
    }
    expect(b.window.length, lessThanOrEqualTo(24));
    expect(b.live, b.window.length);
  });

  test('背景抽幀剛補上的格子：中心沒動也會補解', () async {
    final filled = <int>{50};
    final b = _Bench();
    b.window.focus(50, available: filled.contains);
    await b.settle();
    expect(b.window.length, 1);
    filled.addAll([49, 51, 52]);
    b.window.focus(50, available: filled.contains);
    await b.settle();
    expect(b.window.length, 4);
  });

  test('釋放之後才解好的那幾張也要放掉', () async {
    final b = _Bench(manual: true);
    b.focus(5);
    expect(b.window.pending, 2);
    b.window.dispose();
    b.complete(5);
    b.complete(6);
    await pumpEventQueue();
    expect(b.made, hasLength(2));
    expect(b.made.every((f) => f.disposed), isTrue);
    expect(b.window.length, 0);
  });

  test('解不開的那格不會原地重試成迴圈', () async {
    var calls = 0;
    final window = PreviewFrameWindow<_Frame>(
      load: (i) async {
        calls++;
        throw StateError('bad frame');
      },
      bytesOf: (f) => f.bytes,
      disposeFrame: (f) => f.disposed = true,
      onReady: () {},
    );
    window.focus(3, available: (i) => i == 3);
    await pumpEventQueue();
    expect(calls, 1);
    expect(window.length, 0);
    expect(window.pending, 0);
    window.dispose();
  });
}
