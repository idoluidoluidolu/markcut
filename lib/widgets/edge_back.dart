import 'package:flutter/material.dart';

/// 整頁甩動＝返回上一頁（編輯畫面版：帶排除區）。
///
/// 判定跟 [SwipeBack] 同款抓嚴：單指、450ms 內往右超過 110px、
/// 水平位移是垂直的 2 倍以上——是「甩」不是「慢慢拖」。
///
/// [exclude] 給畫布／時間軸／修剪條這些自己吃橫向手勢的區域：
/// 起手點落在裡面就整輪放棄（使用者指定：整頁甩動，但除了
/// 畫布區域）。
///
/// 用 Listener 收原始指標事件、不進手勢競技場，頁面原本的拖曳照常；
/// 觸發走 maybePop，各頁的離開保護（PopScope）照樣攔得住。
class EdgeBack extends StatefulWidget {
  final Widget child;
  final List<GlobalKey> exclude;

  const EdgeBack({super.key, required this.child, this.exclude = const []});

  @override
  State<EdgeBack> createState() => _EdgeBackState();
}

class _EdgeBackState extends State<EdgeBack> {
  final Set<int> _down = {};
  int? _pointer;
  Offset _start = Offset.zero;
  DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);
  double _maxDy = 0;
  bool _done = false;

  bool _inExcluded(Offset p) {
    for (final k in widget.exclude) {
      final ctx = k.currentContext;
      final box = ctx?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final r = box.localToGlobal(Offset.zero) & box.size;
      if (r.contains(p)) return true;
    }
    return false;
  }

  void _onDown(PointerDownEvent e) {
    _down.add(e.pointer);
    if (_down.length > 1) {
      _pointer = null;
      _done = true;
      return;
    }
    // 落在畫布等排除區就整輪放棄；其他地方整頁都收（使用者指定）
    if (_inExcluded(e.position)) {
      _pointer = null;
      _done = true;
      return;
    }
    _pointer = e.pointer;
    _start = e.position;
    _at = DateTime.now();
    _maxDy = 0;
    _done = false;
  }

  void _onMove(PointerMoveEvent e) {
    if (_done || e.pointer != _pointer) return;
    final d = e.position - _start;
    _maxDy = _maxDy < d.dy.abs() ? d.dy.abs() : _maxDy;
    if (DateTime.now().difference(_at).inMilliseconds > 450) {
      _done = true;
      return;
    }
    if (d.dx > 110 && d.dx > _maxDy * 2) {
      _done = true;
      Navigator.of(context).maybePop();
    }
  }

  void _onUp(int pointer) {
    _down.remove(pointer);
    if (pointer == _pointer) _pointer = null;
    if (_down.isEmpty) _done = false;
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    onPointerMove: _onMove,
    onPointerUp: (e) => _onUp(e.pointer),
    onPointerCancel: (e) => _onUp(e.pointer),
    child: widget.child,
  );
}
