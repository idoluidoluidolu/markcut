import 'package:flutter/material.dart';

/// 批次頁沒有播放器時間軸，用獨立時鐘預覽浮水印動畫。
/// 每幀只重建浮水印；縮圖、原圖與設定面板不跟著重建。
class WatermarkAnimationPreview extends StatefulWidget {
  final bool enabled;
  final Widget Function(BuildContext context, double? time) builder;

  const WatermarkAnimationPreview({
    super.key,
    required this.enabled,
    required this.builder,
  });

  @override
  State<WatermarkAnimationPreview> createState() =>
      _WatermarkAnimationPreviewState();
}

class _WatermarkAnimationPreviewState extends State<WatermarkAnimationPreview>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _clock = AnimationController(
    vsync: this,
    upperBound: 3600,
    duration: const Duration(hours: 1),
  );
  bool _foreground = true;
  bool _routeVisible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeVisible =
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled;
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant WatermarkAnimationPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncClock();
  }

  void _syncClock() {
    if (widget.enabled && _foreground && _routeVisible) {
      if (!_clock.isAnimating) {
        _clock.repeat();
      }
    } else {
      _clock.stop();
      if (!widget.enabled) _clock.value = 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _clock,
    builder: (context, _) =>
        widget.builder(context, widget.enabled ? _clock.value : null),
  );
}
