import AppKit
import Observation
import RecallCore
import SwiftUI

/// The status item outlives the history window. AppKit owns the compact stack.
@MainActor
enum RecallMenuBarService {
  static var model: RecallModel?
  private static var controller: RecallMenuBarController?
  private static var history: (() -> Void)?
  private static var settings: (() -> Void)?
  private static var pendingSettings = false

  static func install() {
    guard controller == nil, let model else { return }
    controller = RecallMenuBarController(
      model: model,
      history: { openHistory() },
      settings: { openSettings() })
  }

  static func bind(history: @escaping () -> Void, settings: @escaping () -> Void) {
    self.history = history
    self.settings = settings
    if pendingSettings {
      pendingSettings = false
      settings()
    }
  }

  private static func openHistory() {
    if let history {
      history()
    } else {
      // SwiftUI creates the window scene only when the running app is opened.
      NSWorkspace.shared.open(Bundle.main.bundleURL)
    }
  }

  private static func openSettings() {
    if let settings {
      settings()
    } else {
      pendingSettings = true
      openHistory()
    }
  }
}

struct RecallMenuBarBridge: NSViewRepresentable {
  @Bindable var model: RecallModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
  func updateNSView(_ nsView: NSView, context: Context) {
    RecallMenuBarService.bind(
      history: {
        model.goToNow()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      },
      settings: {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
      })
  }
}

@MainActor
final class RecallMenuBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
  private let model: RecallModel
  private let history: () -> Void
  private let settings: () -> Void
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private var theme: RecallVisualTheme?
  private var panel: RecallPanelView?
  private var presentation: RecallMenuPresentation?
  private var burstActions: [Int: (Int, Int)] = [:]

  init(model: RecallModel, history: @escaping () -> Void, settings: @escaping () -> Void) {
    self.model = model
    self.history = history
    self.settings = settings
    super.init()
    popover.behavior = .applicationDefined
    popover.animates = false
    popover.delegate = self
    item.button?.target = self
    item.button?.action = #selector(togglePopover)
    item.button?.setAccessibilityIdentifier("screenrecall.status")
    observe()
  }

  private func observe() {
    withObservationTracking {
      update()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
  }

  private func update() {
    let current = RecallMenuPresentation(
      preferences: model.preferences, status: model.menuBarStatusText,
      symbol: model.menuBarSymbol, recording: model.isRecording,
      requested: model.recordingRequested, busy: model.recordingBusy,
      burst: model.isBurstRecording, demo: model.isDemo, error: model.recordingError)
    guard current != presentation else { return }
    presentation = current
    let selectedTheme = current.preferences.visualTheme
    if theme != selectedTheme {
      close()
      theme = selectedTheme
    }
    item.button?.image = NSImage(
      systemSymbolName: model.menuBarSymbol,
      accessibilityDescription: model.menuBarStatusText)
    item.button?.image?.isTemplate = true
    item.button?.toolTip = "ScreenRecall · \(model.menuBarStatusText)"
    if selectedTheme == .classic {
      let menu = NSMenu()
      menu.delegate = self
      item.menu = menu
    } else {
      item.menu = nil
      let appearance = appearanceForPreference()
      popover.appearance = appearance
      if panel == nil {
        let content = makePanel() as! RecallPanelView
        panel = content
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
      }
      if let panel {
        panel.appearance = appearance
        refreshPanel(panel)
        popover.contentSize = panel.frame.size
      }
      if popover.isShown, localMonitor == nil || globalMonitor == nil { installMonitors() }
    }
  }

  private func appearanceForPreference() -> NSAppearance? {
    switch model.preferences.appearance {
    case "dark": NSAppearance(named: .darkAqua)
    case "light": NSAppearance(named: .aqua)
    default: nil
    }
  }

  @objc private func togglePopover() {
    if popover.isShown {
      close()
      return
    }
    guard let button = item.button else { return }
    popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    if popover.isShown { installMonitors() }
  }

  private func installMonitors() {
    removeMonitors()
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .keyDown,
    ]) { [weak self] event in
      let consumed = MainActor.assumeIsolated {
        guard let self else { return false }
        if event.type == .keyDown, event.keyCode == 53 {
          self.close()
          return true
        }
        if event.type != .keyDown,
          !self.isOverStatusButton(),
          event.window != self.popover.contentViewController?.view.window,
          event.window != self.item.button?.window,
          event.window?.level != .popUpMenu
        {
          self.close()
        }
        return false
      }
      return consumed ? nil : event
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.isOverStatusButton() else { return }
        self.close()
      }
    }
  }

  private func isOverStatusButton() -> Bool {
    guard let button = item.button, let window = button.window else { return false }
    let bounds = window.convertToScreen(button.convert(button.bounds, to: nil))
    return bounds.contains(NSEvent.mouseLocation)
  }

  private func close() {
    popover.animates = false
    popover.performClose(nil)
    if popover.isShown { popover.close() }
    if popover.isShown { popover.contentViewController?.view.window?.orderOut(nil) }
    if !popover.isShown { removeMonitors() }
  }

  private func removeMonitors() {
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    localMonitor = nil
    globalMonitor = nil
  }

  func popoverDidClose(_ notification: Notification) { removeMonitors() }

  func makePanel() -> NSView {
    let panel = RecallPanelView()
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 7
    stack.detachesHiddenViews = true
    panel.stack = stack
    stack.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
      panel.widthAnchor.constraint(equalToConstant: 300),
    ])
    let header = NSStackView()
    header.orientation = .horizontal
    header.spacing = 8
    let status = NSTextField(wrappingLabelWithString: popoverStatusTitle)
    status.font =
      NSFont(name: CompactFont.postScriptName, size: 16)
      ?? .systemFont(ofSize: 16, weight: .semibold)
    status.textColor = RecallNativePalette.primary
    status.maximumNumberOfLines = 2
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    status.setContentCompressionResistancePriority(.required, for: .vertical)
    status.setAccessibilityIdentifier("menu.status")
    panel.status = status
    let mark = RecallRecordMark(active: model.isRecording)
    panel.mark = mark
    header.addArrangedSubview(mark)
    header.addArrangedSubview(status)
    add(header, to: stack)
    let detail = NSTextField(wrappingLabelWithString: "")
    detail.font = contentFont(size: 11, technical: true)
    detail.textColor = RecallNativePalette.secondary
    detail.maximumNumberOfLines = 1
    panel.detail = detail
    add(detail, to: stack)
    let historyButton = row(
      model.text("開啟 ScreenRecall"), symbol: "clock.arrow.circlepath",
      action: #selector(openHistory),
      enabled: true)
    historyButton.setAccessibilityIdentifier("menu.history")
    panel.history = historyButton
    add(historyButton, to: stack)
    let recording = row(
      model.text(model.recordingRequested ? "暫停記錄" : "開始記錄"),
      symbol: model.recordingRequested ? "pause.circle" : "record.circle",
      action: #selector(toggleRecording), enabled: !model.isDemo && !model.recordingBusy)
    panel.recording = recording
    add(recording, to: stack)
    let capture = row(
      model.text("立即截圖"), symbol: "camera", action: #selector(capture),
      enabled: !model.isDemo && !model.recordingBusy && !model.isBurstRecording)
    panel.capture = capture
    add(capture, to: stack)
    let burst = row(
      model.text("短時記錄"), symbol: "timer", action: #selector(showBurst),
      enabled: !model.isDemo && !model.recordingBusy && !model.isBurstRecording)
    panel.burst = burst
    add(burst, to: stack)
    let error = NSTextField(wrappingLabelWithString: "")
    error.font = .systemFont(ofSize: 11)
    error.textColor = RecallNativePalette.accent
    panel.error = error
    add(error, to: stack)
    separator(in: stack)
    let footer = NSStackView()
    footer.orientation = .horizontal
    footer.distribution = .fillEqually
    footer.spacing = 7
    for (title, symbol, action) in [
      (model.text("設定"), "slider.horizontal.3", #selector(openConfiguration)),
      (model.text("結束 ScreenRecall"), "power", #selector(quit)),
    ] {
      let button = nativeButton(title: title, symbol: symbol, action: action, compact: true)
      button.title = ""
      button.setAccessibilityIdentifier(
        action == #selector(openConfiguration) ? "menu.settings" : "menu.quit")
      if action == #selector(openConfiguration) { button.keyEquivalent = "," }
      if action == #selector(quit) { button.keyEquivalent = "q" }
      panel.footer.append(button)
      footer.addArrangedSubview(button)
    }
    add(footer, to: stack)
    refreshPanel(panel)
    return panel
  }

  private func refreshPanel(_ panel: RecallPanelView) {
    panel.status?.stringValue = popoverStatusTitle
    panel.detail?.stringValue = popoverSummary
    panel.detail?.font = contentFont(size: 11, technical: true)
    panel.history?.title = model.text("開啟 ScreenRecall")
    panel.mark?.active = model.isRecording
    panel.mark?.needsDisplay = true
    panel.recording?.title = model.text(model.recordingRequested ? "暫停記錄" : "開始記錄")
    panel.recording?.image = NSImage(
      systemSymbolName: model.recordingRequested ? "pause.circle" : "record.circle",
      accessibilityDescription: nil)
    panel.recording?.isEnabled = !model.isDemo && !model.recordingBusy
    panel.capture?.title = model.text("立即截圖")
    panel.burst?.title = model.text("短時記錄")
    panel.capture?.isEnabled = !model.isDemo && !model.recordingBusy && !model.isBurstRecording
    panel.burst?.isEnabled = !model.isDemo && !model.recordingBusy && !model.isBurstRecording
    panel.error?.stringValue = model.recordingError.map(model.text) ?? ""
    panel.error?.isHidden = model.recordingError == nil
    panel.recording?.contentTintColor =
      model.recordingRequested
      ? RecallNativePalette.accent : RecallNativePalette.primary
    let captions = [model.text("設定"), model.text("結束 ScreenRecall")]
    for (button, caption) in zip(panel.footer, captions) {
      button.setAccessibilityLabel(caption)
      button.toolTip = caption
    }
    for button in [panel.history, panel.recording, panel.capture, panel.burst].compactMap({ $0 }) {
      button.font = contentFont(size: 12, technical: false)
      button.setAccessibilityLabel(button.title)
      button.toolTip = button.title
    }
    panel.layoutSubtreeIfNeeded()
    panel.setFrameSize(NSSize(width: 300, height: (panel.stack?.fittingSize.height ?? 240) + 24))
  }

  private var popoverStatusTitle: String {
    if model.isBurstRecording && model.recordingError == nil && !model.isWaitingForScreen {
      return model.text("短時記錄中")
    }
    return model.menuBarStatusText
  }

  private func compactInterval(_ seconds: Int) -> String {
    let units: Set<Duration.UnitsFormatStyle.Unit> =
      seconds >= 60 && seconds % 60 == 0 ? [.minutes] : [.seconds]
    return Duration.seconds(seconds).formatted(
      .units(
        allowed: units,
        width: .abbreviated
      ).locale(model.preferences.language.locale))
  }

  private var popoverSummary: String {
    if model.isBurstRecording {
      let interval = compactInterval(model.burstIntervalSeconds)
      if let remaining = model.burstRemainingSeconds {
        let clock = "\(remaining / 60):\(String(format: "%02d", remaining % 60))"
        return "\(interval) · \(model.text("剩餘")) \(clock)"
      }
      return "\(interval) · \(compactInterval(model.burstDurationMinutes * 60))"
    }
    let format =
      model.preferences.recording.format == "webp"
      ? "WebP" : model.preferences.recording.format.uppercased()
    return "\(compactInterval(model.preferences.recording.intervalSeconds)) · \(format)"
  }

  private func add(_ view: NSView, to stack: NSStackView) {
    stack.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }
  private func separator(in stack: NSStackView) {
    let separator = NSBox()
    separator.boxType = .separator
    add(separator, to: stack)
  }
  private func row(_ title: String, symbol: String, action: Selector, enabled: Bool) -> NSButton {
    let button = nativeButton(title: title, symbol: symbol, action: action)
    button.isEnabled = enabled
    if action == #selector(toggleRecording) { button.keyEquivalent = "r" }
    return button
  }
  private func nativeButton(
    title: String, symbol: String, action: Selector, compact: Bool = false
  ) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.bezelStyle = .rounded
    button.controlSize = .regular
    button.alignment = compact ? .center : .left
    button.imagePosition = compact ? .imageOnly : .imageLeading
    button.contentTintColor = RecallNativePalette.primary
    button.font = contentFont(size: 12, technical: false)
    button.cell?.wraps = true
    button.keyEquivalentModifierMask = .command
    button.translatesAutoresizingMaskIntoConstraints = false
    button.heightAnchor.constraint(equalToConstant: compact ? 30 : 32).isActive = true
    button.setContentCompressionResistancePriority(.required, for: .vertical)
    button.setAccessibilityLabel(title)
    button.toolTip = title
    return button
  }

  private func contentFont(size: CGFloat, technical: Bool) -> NSFont {
    if model.preferences.typography == .compact,
      let font = NSFont(name: CompactFont.postScriptName, size: size)
    {
      return font
    }
    return technical
      ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
  }

  private func burstMenu() -> NSMenu {
    burstActions.removeAll()
    let menu = NSMenu(title: model.text("短時記錄"))
    var tag = 0
    for duration in RecordingBurstPlan.durationChoicesMinutes {
      let submenu = NSMenu()
      for interval in RecordingBurstPlan.intervalChoices {
        let row = NSMenuItem(
          title: model.preferences.language.seconds(interval), action: #selector(startBurst(_:)),
          keyEquivalent: "")
        row.target = self
        row.tag = tag
        burstActions[tag] = (interval, duration)
        tag += 1
        submenu.addItem(row)
      }
      let row = NSMenuItem(
        title: model.preferences.language.minutes(duration), action: nil, keyEquivalent: "")
      row.submenu = submenu
      menu.addItem(row)
    }
    return menu
  }

  func menuWillOpen(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(NSMenuItem(title: model.menuBarStatusText, action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    for (title, action, key, enabled) in [
      (
        model.text(model.recordingRequested ? "暫停記錄" : "開始記錄"), #selector(toggleRecording), "r",
        !model.isDemo && !model.recordingBusy
      ),
      (
        model.text("立即截圖"), #selector(capture), "",
        !model.isDemo && !model.recordingBusy && !model.isBurstRecording
      ),
    ] {
      let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
      row.target = self
      row.isEnabled = enabled
      menu.addItem(row)
    }
    menu.autoenablesItems = false
    let burst = NSMenuItem(title: model.text("短時記錄"), action: nil, keyEquivalent: "")
    burst.submenu = burstMenu()
    burst.isEnabled = !model.isDemo && !model.recordingBusy && !model.isBurstRecording
    menu.addItem(burst)
    if let error = model.recordingError {
      menu.addItem(NSMenuItem(title: model.text(error), action: nil, keyEquivalent: ""))
    }
    menu.addItem(.separator())
    for (title, action, key) in [
      (model.text("開啟 ScreenRecall"), #selector(openHistory), ""),
      (model.text("設定"), #selector(openConfiguration), ","),
      (model.text("結束 ScreenRecall"), #selector(quit), "q"),
    ] {
      if key == "q" { menu.addItem(.separator()) }
      let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
      row.target = self
      menu.addItem(row)
    }
  }
  @objc private func toggleRecording() {
    close()
    model.toggleRecording()
  }
  @objc private func capture() {
    close()
    model.captureNow()
  }
  @objc private func showBurst(_ sender: NSButton) {
    burstMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
  }
  @objc private func startBurst(_ sender: NSMenuItem) {
    guard let (interval, duration) = burstActions[sender.tag] else { return }
    close()
    model.startBurstRecording(intervalSeconds: interval, durationMinutes: duration)
  }
  @objc private func openHistory() {
    close()
    history()
  }
  @objc private func openConfiguration() {
    close()
    settings()
  }
  @objc private func quit() {
    close()
    NSApp.terminate(nil)
  }
}

private enum RecallNativePalette {
  static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
  }
  static let canvas = dynamic(0xF2F2F0, 0x181818)
  static let primary = dynamic(0x1C1C1C, 0xF3F3F0)
  static let secondary = dynamic(0x626260, 0xA7A7A3)
  static let accent = dynamic(0xC92A26, 0xFF625B)
}

private final class RecallPanelView: NSView {
  var stack: NSStackView?
  var status: NSTextField?
  var detail: NSTextField?
  var mark: RecallRecordMark?
  var history: NSButton?
  var recording: NSButton?
  var capture: NSButton?
  var burst: NSButton?
  var error: NSTextField?
  var footer: [NSButton] = []
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    RecallNativePalette.canvas.setFill()
    bounds.fill()
  }
}

private final class RecallRecordMark: NSView {
  var active: Bool
  init(active: Bool) {
    self.active = active
    super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
    translatesAutoresizingMaskIntoConstraints = false
    widthAnchor.constraint(equalToConstant: 18).isActive = true
    heightAnchor.constraint(equalToConstant: 18).isActive = true
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    (active ? RecallNativePalette.accent : RecallNativePalette.secondary).setFill()
    // A small dot matrix ring gives the recording identity one restrained motif.
    for y in 0..<5 {
      for x in 0..<5
      where (x == 0 || x == 4 || y == 0 || y == 4) && !((x == 0 || x == 4) && (y == 0 || y == 4)) {
        NSBezierPath(ovalIn: NSRect(x: 2 + x * 3, y: 2 + y * 3, width: 2, height: 2)).fill()
      }
    }
    if active { NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4)).fill() }
  }
}

private struct RecallMenuPresentation: Equatable {
  let preferences: Preferences
  let status: String
  let symbol: String
  let recording: Bool
  let requested: Bool
  let busy: Bool
  let burst: Bool
  let demo: Bool
  let error: String?
}
