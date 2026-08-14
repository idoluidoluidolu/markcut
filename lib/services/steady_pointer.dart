import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 全 App 的觸控過濾：把「抬手那一下的小位移」擋在手勢辨識之前。
///
/// 放開手指時每個拖曳都會跳一下（滑桿、時間軸搬素材、預覽上拖浮水印），
/// 原因有兩個，都在事件進到手勢辨識器之前就發生了：
///
/// 一、手指離開的瞬間，接觸面會變形，回報的座標會偏個一兩像素。平台把
/// 「抬手的位置」跟「最後一次移動的位置」對齊的方式，是在 up 事件之前
/// 補一個 move 事件，並標記 [PointerEvent.synthesized]。Flutter 的拖曳
/// 辨識器不看這個旗標，照單全收——那一下就是放手時的位移。這裡直接不送
/// 這種事件出去：位置本身沒被改掉（up 事件照樣帶著真正的座標），只是
/// 不再被當成「使用者移動了手指」。
///
/// 二、抬起的過程中也會回報幾個真的 move 事件（手指是滾開的，不是瞬間
/// 離開）。這個沒有旗標可認，只能看幅度：累積不到 [_slop] 的移動先留著
/// 不送，超過門檻才一次送出。慢慢拖不受影響——位移會累積，只是變成
/// 一格一格套上去；手抖也順帶濾掉。抬手時剩下的那點沒送出的位移，
/// 在 up/cancel 時直接丟掉。
///
/// 只對觸控做。滑鼠與觸控筆本來就沒有這個問題，過濾只會讓它們變鈍
class SteadyPointerBinding extends WidgetsFlutterBinding {
  static SteadyPointerBinding? _instance;

  /// 取代 WidgetsFlutterBinding.ensureInitialized()（main 一開始呼叫）
  static WidgetsBinding ensureInitialized() =>
      _instance ??= SteadyPointerBinding();

  /// 門檻（邏輯像素）。抬手的抖動大約一兩像素，1.5 擋得掉又不會讓
  /// 慢速微調變成跳格
  static const double _slop = 1.5;

  /// 每根手指還沒送出去的位移
  final Map<int, Offset> _pending = {};

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      super.handlePointerEvent(event);
      return;
    }
    if (event is PointerMoveEvent) {
      if (event.synthesized) return; // 抬手時平台補的那一下
      final pend = (_pending[event.pointer] ?? Offset.zero) + event.delta;
      if (pend.distance < _slop) {
        // 還不夠，先存著。位移沒有被丟掉，下一次一起送
        _pending[event.pointer] = pend;
        return;
      }
      _pending[event.pointer] = Offset.zero;
      // 位置維持真實座標，只把中間扣住的位移補回 delta，
      // 讓吃 delta 的（拖曳辨識器）跟吃 position 的都拿到對的值
      super.handlePointerEvent(event.copyWith(delta: pend));
      return;
    }
    if (event is PointerUpEvent ||
        event is PointerCancelEvent ||
        event is PointerDownEvent) {
      // 沒送出去的殘量就到此為止——那正是抬手的抖動
      _pending.remove(event.pointer);
    }
    super.handlePointerEvent(event);
  }
}
