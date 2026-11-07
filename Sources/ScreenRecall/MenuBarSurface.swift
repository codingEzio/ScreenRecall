import RecallCore
import SwiftUI

struct MenuBarSurface: View {
  @Bindable var model: RecallModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Group {
      Text(model.menuBarStatusText)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("menu.status")
      Divider()
      Button(model.text(model.recordingRequested ? "暫停記錄" : "開始記錄")) {
        model.toggleRecording()
      }
      .keyboardShortcut("r")
      .disabled(model.isDemo || model.recordingBusy)
      Button(model.text("立即截圖"), action: model.captureNow)
        .disabled(model.isDemo || model.recordingBusy || model.isBurstRecording)
      Menu(model.text("短時記錄")) {
        ForEach(RecordingBurstPlan.durationChoicesMinutes, id: \.self) { duration in
          Menu(model.preferences.language.minutes(duration)) {
            ForEach(RecordingBurstPlan.intervalChoices, id: \.self) { interval in
              Button(model.preferences.language.seconds(interval)) {
                model.startBurstRecording(intervalSeconds: interval, durationMinutes: duration)
              }
            }
          }
        }
      }
      .disabled(model.isDemo || model.recordingBusy || model.isBurstRecording)
      if let error = model.recordingError {
        Text(model.text(error)).foregroundStyle(.orange)
      }
      Divider()
      Button(model.text("開啟歷史")) {
        model.goToNow()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      }
      SettingsLink { Text(model.text("設定")) }
        .keyboardShortcut(",")
      Divider()
      Button(model.text("結束 ScreenRecall")) { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
    .frame(width: 270)
    .recallFont(.body)
  }
}
