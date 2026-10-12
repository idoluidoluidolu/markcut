// 診斷用 UI 測試（只在 claude/gif-pick-diag 分支）：照使用者的路徑
// 個人中心 → GIF → ＋ → 從相簿匯入 GIF → 點一張 → 等「已匯入 GIF」，
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
    let text = app.debugDescription
    let a = XCTAttachment(string: text)
    a.name = "\(name).txt"
    a.lifetime = .keepAlways
    add(a)
    print("[gifpick-ui] ===== tree \(name) =====")
    print(text)
    print("[gifpick-ui] ===== end \(name) =====")
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

  /// 相簿選取器裡的第一格。PHPicker 是另一個程序畫的，元素不一定看得到；
  /// 看不到就照格子的位置點
  private func tapFirstPickerItem() {
    let w = app.frame.width
    let imgs = app.images.allElementsBoundByIndex.filter {
      $0.exists && $0.frame.width > 40 && $0.frame.width < w * 0.6 && $0.frame.minY > 90
    }
    print("[gifpick-ui] picker images: \(imgs.map { "'\($0.label)' \($0.frame)" })")
    if let first = imgs.min(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
      print("[gifpick-ui] tap picker image '\(first.label)' at \(first.frame)")
      first.tap()
      return
    }
    let cells = app.cells.allElementsBoundByIndex.filter { $0.exists && $0.frame.minY > 90 }
    print("[gifpick-ui] picker cells: \(cells.map { "'\($0.label)' \($0.frame)" })")
    if let first = cells.min(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
      print("[gifpick-ui] tap picker cell '\(first.label)' at \(first.frame)")
      first.tap()
      return
    }
    print("[gifpick-ui] no picker element found, tapping grid position")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.32)).tap()
  }

  /// 剪輯 → 空白專案 → 加素材 → GIF → 相簿挑一張（使用者回報的第二條路）
  func testEditorAddGifFromGallery() throws {
    app.launch()
    sleep(8)
    shot("e01-launch")
    if element("開始") == nil {
      // 第一次開的聚光燈提示：點旁邊收掉
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
      sleep(2)
    }
    XCTAssertTrue(tap("開始", timeout: 15), "首頁「開始」找不到")
    sleep(2)
    shot("e02-menu")
    XCTAssertTrue(tap("剪輯", timeout: 10), "「剪輯」找不到")
    sleep(6)
    shot("e03-editor")
    XCTAssertTrue(tap("加素材", timeout: 20), "「加素材」找不到")
    sleep(2)
    shot("e04-add-menu")
    dump("e04-add-menu")
    XCTAssertTrue(tap("GIF", timeout: 10), "選單裡的「GIF」找不到")
    sleep(5)
    shot("e05-after-gif")
    if element("從相簿選") != nil {
      // 我的 GIF 已經有東西：先出那張面板，相簿在右上角
      tap("從相簿選")
      sleep(5)
    }
    shot("e06-picker")
    dump("e06-picker")
    tapFirstPickerItem()
    sleep(2)
    shot("e07-after-pick-2s")
    sleep(6)
    shot("e08-after-pick-8s")
    dump("e08-after-pick-8s")
  }

  func testImportGifFromGallery() throws {
    app.launch()
    sleep(8)
    shot("01-launch")
    dump("01-launch")

    // 首頁右上角「個人中心」（第一次開會有聚光燈提示，點目標也會進個人中心）
    if !tap("個人中心", timeout: 20) {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.08)).tap()
    }
    sleep(3)
    shot("02-after-profile-tap")
    if element("範本") == nil {
      // 第一下只收掉了提示
      tap("個人中心", timeout: 5)
      sleep(3)
      shot("02b-after-profile-tap-again")
    }
    dump("02-profile")

    XCTAssertTrue(tap("GIF", timeout: 10), "GIF 分頁找不到")
    sleep(2)
    shot("03-gif-tab")
    dump("03-gif-tab")

    // 右下角黑圓 ＋
    let w = app.frame.width
    let h = app.frame.height
    let fabs = app.buttons.allElementsBoundByIndex.filter {
      $0.exists && $0.frame.minX > w * 0.6 && $0.frame.minY > h * 0.7 && $0.frame.width < 100
    }
    print("[gifpick-ui] fab candidates: \(fabs.map { "'\($0.label)' \($0.frame)" })")
    if let fab = fabs.last {
      fab.tap()
    } else {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.9)).tap()
    }
    sleep(2)
    shot("04-add-sheet")
    dump("04-add-sheet")

    XCTAssertTrue(tap("從相簿匯入 GIF", contains: true, timeout: 10), "「從相簿匯入 GIF」找不到")
    sleep(5)
    shot("05-picker")
    dump("05-picker")

    tapFirstPickerItem()
    sleep(1)
    shot("06-after-pick-1s")
    sleep(4)
    shot("07-after-pick-5s")
    dump("07-after-pick-5s")

    let imported = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "已匯入")).firstMatch
    let ok = imported.waitForExistence(timeout: 30)
    shot("08-final")
    dump("08-final")
    XCTAssertTrue(ok, "選完 GIF 之後沒有出現「已匯入 GIF」")
  }
}
