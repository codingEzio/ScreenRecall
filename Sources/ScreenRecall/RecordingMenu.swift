import AppKit

@MainActor
final class RecordingMenu: NSObject, NSMenuDelegate {
  private weak var model: RecallModel?
  private var item: NSStatusItem?
  init(model: RecallModel) {
    self.model = model
    super.init()
  }

  func update() {
    guard let model, model.isRecording else {
      if let item { NSStatusBar.system.removeStatusItem(item) }
      item = nil
      return
    }
    if item == nil {
      item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      let menu = NSMenu()
      menu.delegate = self
      item?.menu = menu
      item?.button?.setAccessibilityIdentifier("recording.status")
    }
    let symbol = model.recordingError == nil ? "record.circle" : "exclamationmark.circle"
    item?.button?.image = NSImage(
      systemSymbolName: symbol, accessibilityDescription: model.text("記錄中"))
    item?.button?.image?.isTemplate = true
    item?.button?.toolTip = "ScreenRecall · \(model.text("記錄中"))"
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard let model else { return }
    menu.removeAllItems()
    for (title, action, key) in [
      (model.text("暫停記錄"), #selector(pause), ""),
      ("ScreenRecall", #selector(openMain), ""),
      (model.text("結束 ScreenRecall"), #selector(quit), "q"),
    ] {
      if key == "q" { menu.addItem(.separator()) }
      let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
      row.target = self
      menu.addItem(row)
    }
  }
  @objc private func pause() { model?.pauseRecording() }
  @objc private func openMain() { model?.showMainWindow?() }
  @objc private func quit() { NSApp.terminate(nil) }
}
