import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 右滑＝返回上一頁。包在整個畫面外層，判定範圍就是整頁，
/// 不像 iOS 系統手勢只認左邊那條 20pt 的邊。
///
/// 用 Listener 收原始指標事件、不進手勢競技場，所以頁面裡的捲動、
/// 點擊都不受影響。只給「非編輯」的頁面用——編輯畫面（時間軸、
/// 拖浮水印）本來就充滿橫向拖曳，放這個一定誤觸。
///
/// 判定抓嚴：單指、450ms 內往右超過 110px、水平位移是垂直的 2 倍以上
/// ——是「甩」不是「慢慢拖」。
class SwipeBack extends StatefulWidget {
  final Widget child;

  /// 觸發時做什麼；不給就 Navigator.maybePop（會尊重 PopScope）
  final VoidCallback? onBack;

  const SwipeBack({super.key, required this.child, this.onBack});

  @override
  State<SwipeBack> createState() => _SwipeBackState();
}

class _SwipeBackState extends State<SwipeBack> {
  /// 目前壓在螢幕上的所有指頭（不只追蹤第一指——
  /// 只記一根的話，第三指下來會被誤認成「新的一輪」重新開始判定）
  final Set<int> _downPointers = {};
  int? _pointer;
  Offset _start = Offset.zero;
  DateTime _startAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _maxDy = 0;
  bool _done = false;

  void _down(PointerDownEvent e) {
    _downPointers.add(e.pointer);
    // 螢幕上超過一指（捏合）就整輪放棄，直到全部放開
    if (_downPointers.length > 1) {
      _pointer = null;
      _done = true;
      return;
    }
    _pointer = e.pointer;
    _start = e.position;
    _startAt = DateTime.now();
    _maxDy = 0;
    _done = false;
  }

  void _move(PointerMoveEvent e) {
    if (_done || e.pointer != _pointer) return;
    final d = e.position - _start;
    _maxDy = math.max(_maxDy, d.dy.abs());
    if (DateTime.now().difference(_startAt).inMilliseconds > 450) {
      _done = true; // 拖太久＝不是甩
      return;
    }
    if (d.dx > 110 && d.dx > _maxDy * 2) {
      _done = true;
      _pointer = null;
      (widget.onBack ?? () => Navigator.maybePop(context))();
    }
  }

  void _up(int pointer) {
    _downPointers.remove(pointer);
    if (pointer == _pointer) _pointer = null;
    // 全部指頭都離開螢幕才重新開放判定
    if (_downPointers.isEmpty) _done = false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (e) => _up(e.pointer),
      onPointerCancel: (e) => _up(e.pointer),
      child: widget.child,
    );
  }
}
