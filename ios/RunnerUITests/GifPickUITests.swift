// 診斷用 UI 測試（只在 claude/gif-pick-diag 分支）：照使用者的兩條路
//   A. 個人中心 → GIF → ＋ → 從相簿匯入 GIF → 點一張 → 等「已匯入 GIF」
//   B. 首頁 開始 → 剪輯 → 加素材 → GIF → 相簿點一張
// 每一步截圖、把畫面上的元素樹印出來
import XCTest

final class GifPickUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = true
    app = XCUIApplication()
    addUIInterruptionMonitor(withDescription: "system alerts") { alert in
      for b in ["Allow", "OK", "Allow Full Access", "允許", "好", "Don’t Allow", "不允許"] {
        if alert.buttons[b].exists {
          alert.buttons[b].tap()
          return true
        }
      }
      return false
    }
  }

  private func shot(_ name: String) {
    let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
    print("[gifpick-ui] shot \(name)")
  }

  private func dump(_ name: String) {
    let a = XCTAttachment(string: app.debugDescription)
    a.name = "\(name).txt"
    a.lifetime = .keepAlways
    add(a)
  }

  /// 畫面上 label 符合的元素，取最上面那一個
  private func element(_ label: String, contains: Bool = false) -> XCUIElement? {
    let pred =
      contains
      ? NSPredicate(format: "label CONTAINS %@", label)
      : NSPredicate(format: "label == %@", label)
    let all = app.descendants(matching: .any).matching(pred).allElementsBoundByIndex
      .filter { $0.exists && !$0.frame.isEmpty }
    return all.min { $0.frame.minY < $1.frame.minY }
  }

  @discardableResult
  private func tap(_ label: String, contains: Bool = false, timeout: TimeInterval = 15) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let e = element(label, contains: contains) {
        print("[gifpick-ui] tap '\(label)' at \(e.frame)")
        e.tap()
        return true
      }
      sleep(1)
    }
    print("[gifpick-ui] '\(label)' not found")
    return false
  }

  private func tapPoint(_ x: CGFloat, _ y: CGFloat, _ why: String) {
    let f = app.frame
    print("[gifpick-ui] tap point (\(x), \(y)) in \(f.size): \(why)")
    app.coordinate(withNormalizedOffset: CGVector(dx: x / f.width, dy: y / f.height)).tap()
  }

  /// 相簿選取器裡點第一格。PHPicker 是另一個程序畫的，元素樹裡看不到，
  /// 只能照格子的位置點：第一次開會有「Private Access to Photos」說明框
  /// 把格子往下推（第一格在 y≈312～445），收掉之後格子從 y≈150 開始
  private func pickFirstGif(done: () -> Bool) {
    // 等相簿從「Loading…」載完
    sleep(10)
    shot("picker-loaded")
    tapPoint(66, 378, "first cell below the privacy banner")
    sleep(4)
    if done() { return }
    shot("picker-after-first-tap")
    tapPoint(66, 216, "first cell without the banner")
    sleep(4)
  }

  func testA_ProfileImportGif() throws {
    app.launch()
    sleep(8)
    shot("a01-launch")

    // 首頁右上角「個人中心」（第一次開會有聚光燈提示，點目標也會進個人中心）
    if !tap("個人中心", timeout: 20) {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.08)).tap()
    }
    sleep(3)
    if element("範本") == nil {
      // 第一下只收掉了提示
      tap("個人中心", timeout: 5)
      sleep(3)
    }
    shot("a02-profile")

    XCTAssertTrue(tap("GIF", timeout: 10), "GIF 分頁找不到")
    sleep(2)
    shot("a03-gif-tab")

    // 右下角黑圓 ＋
    let w = app.frame.width
    let h = app.frame.height
    let fabs = app.buttons.allElementsBoundByIndex.filter {
      $0.exists && $0.frame.minX > w * 0.6 && $0.frame.minY > h * 0.7 && $0.frame.width < 100
    }
    if let fab = fabs.last {
      fab.tap()
    } else {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.9)).tap()
    }
    sleep(2)
    shot("a04-add-sheet")

    XCTAssertTrue(tap("從相簿匯入 GIF", contains: true, timeout: 10), "「從相簿匯入 GIF」找不到")

    let imported = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "已匯入")).firstMatch
    pickFirstGif { imported.exists }
    let ok = imported.waitForExistence(timeout: 20)
    shot("a05-final")
    dump("a05-final")
    XCTAssertTrue(ok, "選完 GIF 之後沒有出現「已匯入 GIF」")
  }

  func testB_EditorAddGif() throws {
    app.launch()
    sleep(8)
    shot("b01-launch")
    XCTAssertTrue(tap("開始", contains: true, timeout: 15), "首頁「開始」找不到")
    sleep(2)
    shot("b02-menu")
    XCTAssertTrue(tap("剪輯", contains: true, timeout: 10), "「剪輯」找不到")
    sleep(6)
    shot("b03-editor")
    XCTAssertTrue(tap("加素材", contains: true, timeout: 20), "「加素材」找不到")
    sleep(2)
    shot("b04-add-menu")
    dump("b04-add-menu")
    XCTAssertTrue(tap("GIF", timeout: 10), "選單裡的「GIF」找不到")
    sleep(3)
    shot("b05-after-gif")
    if element("從相簿選", contains: true) != nil {
      // 我的 GIF 已經有東西（A 收進來的）：先出那張面板，相簿在右上角
      tap("從相簿選", contains: true)
    }
    // 加上去之後時間軸上會多一段：選取工具列出現「換一個」之類的字以前，
    // 先用「選取器關了」當訊號——這裡沒有好認的文字，靠截圖跟記錄判斷
    pickFirstGif { false }
    sleep(4)
    shot("b06-final")
    dump("b06-final")
  }
}
