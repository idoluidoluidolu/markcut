import 'package:flutter/material.dart';

/// 編輯模式的頁面路由：關掉「右滑＝上一頁」。
///
/// 使用者指定：影片編輯模式、圖片編輯模式、GIF 製作等等，都不要加入
/// 右滑上一頁。編輯頁滿場都是橫向手勢——拖時間軸、拉指針、搬素材、
/// 掃描預覽——手指往右一劃就退出去、正在做的東西跟著沒了，實測常
/// 誤觸。瀏覽用的頁（個人中心、草稿夾、範本夾、關於…）不在此列，
/// 那裡的右滑很好用。
///
/// 關在路由這一層、不是各頁自己包一層 widget：新的編輯頁只要用
/// [editRoute] 推就自動沒有右滑，不會有人漏包。
///
/// [PageRoute.popGestureEnabled] 是 iOS 左緣返回（Cupertino 轉場塞進去
/// 的 _CupertinoBackGestureDetector）與 Android predictive back 共用的
/// 開關，回 false 兩邊一起關。
///
/// 沒有動到的三件事：左上角的返回鍵、程式自己呼叫的 Navigator.pop、
/// 各頁的離開保護（PopScope／「要不要保留草稿」）——那些都不是手勢，
/// 照常運作
class EditPageRoute<T> extends MaterialPageRoute<T> {
  EditPageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog,
  });

  @override
  bool get popGestureEnabled => false;
}

/// 推一個編輯頁：跟 `MaterialPageRoute(...)` 同樣的用法，
/// 只是右滑不會退回上一頁（見 [EditPageRoute]）
Route<T> editRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) => EditPageRoute<T>(
  builder: builder,
  settings: settings,
  fullscreenDialog: fullscreenDialog,
);
