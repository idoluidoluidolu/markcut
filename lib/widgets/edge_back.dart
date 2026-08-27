import 'package:flutter/material.dart';

/// 左緣快滑＝返回上一頁（編輯畫面用的保守版）。
///
/// 跟 [SwipeBack]（整頁甩動）不同：只認「從螢幕最左緣 28px 內起手、
/// 400ms 內往右快滑 70px、幾乎水平」的手勢——編輯畫面滿是橫向拖曳
///（滑桿、時間軸、修剪條），整頁判定一定誤觸，左緣起手的窄判定
/// 才共存得了。
///
/// [exclude] 給「畫布」等左緣也有自己手勢的區域：起手點落在這些
/// 元件的範圍內就整輪放棄（使用者指定：除了畫布上面，其他地方
/// 都要有上一頁手勢）。
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
    // 只認最左緣起手；落在畫布等排除區就整輪放棄
    if (e.position.dx > 28 || _inExcluded(e.position)) {
      _pointer = null;
      _done = true;
      return;
    }
    _pointer = e.pointer;
    _start = e.position;
    _at = DateTime.now();
    _done = false;
  }

  void _onMove(PointerMoveEvent e) {
    if (_done || e.pointer != _pointer) return;
    final d = e.position - _start;
    if (DateTime.now().difference(_at).inMilliseconds > 400 ||
        d.dy.abs() > 40) {
      _done = true;
      return;
    }
    if (d.dx > 70) {
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
