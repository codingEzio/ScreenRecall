import AppKit
import Observation
import QuartzCore
import SwiftUI

@MainActor @Observable
final class DisplayProbe: NSObject {
  var running = false
  var callbacks = 0
  var callbackHz = 0.0
  var p95Milliseconds = 0.0
  @ObservationIgnored private var link: CADisplayLink?
  @ObservationIgnored private var intervals: [Double] = []
  @ObservationIgnored private var last = 0.0

  var report: [String: Any] {
    [
      "running": running, "callbacks": callbacks, "observed_callback_hz": callbackHz,
      "callback_interval_p95_ms": p95Milliseconds,
      "scope": "main-run-loop display callbacks, not compositor presentation FPS",
    ]
  }

  func start() {
    guard !running, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
      let view = window.contentView
    else { return }
    intervals = []
    last = 0
    callbacks = 0
    running = true
    let displayLink = view.displayLink(target: self, selector: #selector(tick(_:)))
    let maximum = Float(min(120, window.screen?.maximumFramesPerSecond ?? 60))
    displayLink.preferredFrameRateRange = CAFrameRateRange(
      minimum: min(60, maximum), maximum: maximum, preferred: maximum)
    displayLink.add(to: .main, forMode: .common)
    link = displayLink
    Task {
      try? await Task.sleep(for: .seconds(5))
      finish()
    }
    window.makeKeyAndOrderFront(nil)
  }

  @objc private func tick(_ displayLink: CADisplayLink) {
    let now = CACurrentMediaTime()
    if last > 0 { intervals.append(now - last) }
    last = now
    // Do not publish per-frame UI updates: the probe must not create its own rendering load.
  }

  private func finish() {
    link?.invalidate()
    link = nil
    callbacks = intervals.count + (last > 0 ? 1 : 0)
    if !intervals.isEmpty {
      callbackHz = Double(intervals.count) / intervals.reduce(0, +)
      p95Milliseconds = intervals.sorted()[Int(Double(intervals.count - 1) * 0.95)] * 1000
    }
    running = false
  }
}

struct RecallCommands: Commands {
  let model: RecallModel
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    CommandGroup(after: .help) {
      Button(model.text("ScreenRecall 診斷…")) { openWindow(id: "diagnostics") }
        .keyboardShortcut("d", modifiers: [.command, .option])
    }
  }
}

struct DiagnosticsView: View {
  let model: RecallModel
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(model.text("效能與狀態")).recallFont(.title2, weight: .bold)
      Text(model.text("只包含版本、數量、延遲與選圖狀態。螢幕最高 Hz 是硬體能力，不代表實測 FPS。"))
        .foregroundStyle(.secondary)
      ScrollView {
        Text(model.diagnosticReport())
          .recallFont(.callout, technical: true).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("diagnostics.report")
      }
      HStack {
        Button(model.text(model.displayProbe.running ? "量測中…" : "量測 5 秒回應節奏")) {
          model.displayProbe.start()
        }
        .disabled(model.displayProbe.running).accessibilityIdentifier("diagnostics.measure")
        Button(model.text("重建本機索引")) {
          model.rebuildLocalIndex()
        }
        .disabled(model.catalogBusy)
        .help(model.text("從檔案系統重新核對全部圖片索引。收藏與筆記不會刪除。"))
        .accessibilityIdentifier("diagnostics.reindex")
        Spacer()
        Button(model.text("複製匿名報告")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(model.diagnosticReport(), forType: .string)
        }.accessibilityIdentifier("diagnostics.copy")
      }
    }.padding(24).frame(minWidth: 460, minHeight: 480)
      .preferredColorScheme(
        model.preferences.appearance == "system"
          ? nil : model.preferences.appearance == "dark" ? .dark : .light)
  }
}
