import RecallCore
import SwiftUI

struct RecordingSettings: View {
  @Bindable var model: RecallModel
  @State private var customInterval = false
  @Environment(\.recallSettingsPreview) private var preview
  var wide = false
  var body: some View {
    if wide {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 12) {
          dailySection
          imageSettingsSection
        }.frame(maxWidth: .infinity, alignment: .topLeading)
        VStack(alignment: .leading, spacing: 12) {
          trackedCapacitySection
          BurstRecordingSection(model: model)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } else {
      VStack(alignment: .leading, spacing: 12) {
        dailySection
        imageSettingsSection
        trackedCapacitySection
        BurstRecordingSection(model: model)
      }
    }
  }
  private var trackedCapacitySection: some View {
    capacitySection
      .task {
        guard !preview else { return }
        model.refreshRecordingSizeStats()
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .seconds(86_400))
          } catch {
            return
          }
          guard !Task.isCancelled else { return }
          model.refreshRecordingSizeStats()
        }
      }
  }

  @ViewBuilder private var dailySection: some View {
    RecallSettingsSection(title: model.text("擷取設定"), nativeForm: false) {
      HStack {
        Button(model.text(recordingButtonKey), action: model.toggleRecording)
          .disabled(model.isDemo || model.recordingBusy).accessibilityIdentifier("recording.toggle")
        Spacer()
        if model.isBurstRecording, let remaining = model.burstRemainingSeconds {
          Text("\(model.text("短時記錄中")) · \(formatDuration(remaining))")
            .foregroundStyle(.orange).monospacedDigit()
        } else {
          Text(model.menuBarStatusText)
            .foregroundStyle(.secondary)
        }
      }
      RecallSettingsRow(label: model.text("擷取間隔")) {
        Picker(
          model.text("擷取間隔"),
          selection: Binding(
            get: {
              customInterval
                || ![60, 120, 180, 300, 420, 600, 900, 1800, 3600].contains(
                  model.preferences.recording.intervalSeconds)
                ? -1 : model.preferences.recording.intervalSeconds
            },
            set: { value in
              customInterval = value == -1
              if value > 0 { model.preferences.recording.intervalSeconds = value }
            })
        ) {
          ForEach([1, 2, 3, 5, 7, 10, 15, 30, 60], id: \.self) { minutes in
            Text(model.preferences.language.minutes(minutes)).tag(minutes * 60)
          }
          Text(model.text("自訂")).tag(-1)
        }.accessibilityIdentifier("recording.interval-preset")
      }
      if customInterval
        || ![60, 120, 180, 300, 420, 600, 900, 1800, 3600].contains(
          model.preferences.recording.intervalSeconds)
      {
        Stepper(value: $model.preferences.recording.intervalSeconds, in: 60...3600, step: 60) {
          Text(model.preferences.language.minutes(model.preferences.recording.intervalSeconds / 60))
        }.accessibilityIdentifier("recording.interval")
      }
      RecallSettingsRow(label: model.text("靜止畫面")) {
        Picker(model.text("靜止畫面"), selection: $model.preferences.recording.mode) {
          Text(model.text("每次擷取")).tag(RecordingCaptureMode.everyInterval)
          Text(model.text("未變更時略過")).tag(RecordingCaptureMode.skipUnchanged)
        }
        .pickerStyle(.menu)
      }
      if model.preferences.recording.mode == .skipUnchanged {
        Text(model.text("任一螢幕變更就保存整輪；全部未變更時略過。"))
          .recallFont(.caption).foregroundStyle(.secondary)
          .recallSettingsNote()
      }
      if model.preferences.recording.mode == .skipUnchanged && model.skippedRecordingCycles > 0 {
        Text("\(model.text("已略過")) \(model.skippedRecordingCycles) \(model.text("個未變更週期"))")
          .recallFont(.caption).foregroundStyle(.secondary)
          .recallSettingsNote()
      }
      if let error = model.recordingError { Text(model.text(error)).foregroundStyle(.orange) }
    }
  }

  @ViewBuilder private var imageSettingsSection: some View {
    RecallSettingsSection(title: model.text("影像設定"), nativeForm: false) {
      RecallSettingsRow(label: model.text("解析度")) {
        Slider(value: $model.preferences.recording.scale, in: 0.1...1, step: 0.1)
          .frame(width: 140).accessibilityLabel(model.text("解析度"))
        Text(model.preferences.recording.scale, format: .percent.precision(.fractionLength(0)))
          .frame(width: 42).monospacedDigit()
      }
      RecallSettingsRow(label: model.text("影像品質")) {
        Slider(value: $model.preferences.recording.quality, in: 0...1, step: 0.05)
          .disabled(model.preferences.recording.format == "png")
          .accessibilityIdentifier("recording.quality")
          .frame(width: 140).accessibilityLabel(model.text("影像品質"))
        Text("Q\(Int((model.preferences.recording.quality * 100).rounded()))")
          .frame(width: 42).monospacedDigit()
      }
      RecallSettingsRow(label: model.text("儲存格式")) {
        Picker(model.text("儲存格式"), selection: $model.preferences.recording.format) {
          Text("WebP").tag("webp")
          Text("HEIC").tag("heic")
          Text("JPEG").tag("jpeg")
          Text("PNG").tag("png")
        }.pickerStyle(.menu).accessibilityIdentifier("recording.format")
      }
      if model.connectedDisplays.isEmpty {
        Text(model.text("目前沒有連接的螢幕")).foregroundStyle(.secondary)
      } else {
        ForEach(model.connectedDisplays) { screen in
          LabeledContent(model.connectedDisplayTitle(screen)) {
            Text(
              "\(scaled(screen.width, by: model.preferences.recording.scale)) × \(scaled(screen.height, by: model.preferences.recording.scale)) px"
            )
            .monospacedDigit()
          }
          .help(screen.name)
        }
      }
      Text(model.text("本程式視窗不會被記錄。"))
        .recallFont(.caption).foregroundStyle(.secondary)
        .recallSettingsNote()
    }
    .accessibilityIdentifier("recording.image-settings")
  }

  @ViewBuilder private var capacitySection: some View {
    RecallSettingsSection(title: model.text("近期實際用量"), nativeForm: false) {
      if let stats = model.recordingRecentSizeStats {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            forecastColumn("近 24 小時", bytes(stats.last24Hours.byteCount))
            Spacer()
            forecastColumn("近 7 天", bytes(stats.last7Days.byteCount))
            Spacer()
            forecastColumn("近 30 天", bytes(stats.last30Days.byteCount))
          }
          .accessibilityIdentifier("recording.actual-usage")
          Text(
            model.text(
              "依擷取時間統計實際影像檔案大小。開啟設定時更新，頁面開啟期間每日更新。")
          )
          .recallFont(.caption)
          .foregroundStyle(.secondary)
          .recallSettingsNote()
          if model.recordingStatsBusy {
            ProgressView().controlSize(.small)
          }
        }
      } else if model.recordingStatsBusy {
        HStack {
          ProgressView().controlSize(.small)
          Text(model.text("正在讀取實際用量…"))
            .recallFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        Text(model.text("無法讀取實際用量。"))
          .recallFont(.caption).foregroundStyle(.secondary)
          .recallSettingsNote()
      }
      DisclosureGroup(model.text("容量與試拍")) {
        HStack {
          Button(model.text("試拍並更新估算"), action: model.sampleRecording)
            .disabled(model.isDemo || model.recordingPreviewBusy || model.isBurstRecording)
            .accessibilityIdentifier("recording.sample")
          if model.recordingPreviewBusy { ProgressView().controlSize(.small) }
          Spacer()
          if model.recordingPreview != nil {
            Button(model.text("查看試拍")) { model.showRecordingPreview = true }
          }
        }
        if let stats = model.recordingCycleStats, let estimate = model.recordingCapacityEstimate {
          ForEach(model.connectedDisplays) { display in
            if let size = model.averageBytes(for: display.id) {
              LabeledContent(model.connectedDisplayTitle(display), value: bytes(size))
                .help(display.name)
            }
          }
          LabeledContent(model.text("每輪合計"), value: bytes(stats.averageBytes))
            .fontWeight(.semibold).accessibilityIdentifier("recording.cycle-bytes")
          HStack {
            forecastColumn("每日", bytes(estimate.bytesPerDay()))
            Spacer()
            forecastColumn("7 天", bytes(estimate.bytesPerDay(multiplier: 7)))
            Spacer()
            forecastColumn("30 天", bytes(estimate.bytesPerDay(multiplier: 30)))
          }.accessibilityIdentifier("recording.forecast")
          Text("\(model.text("符合目前設定的完整擷取樣本"))：\(stats.sampleCount)")
            .recallFont(.caption).foregroundStyle(.secondary)
            .recallSettingsNote()
          Text(model.text("按全天每輪保存所有螢幕估算，未扣除靜止畫面；內容會影響檔案大小，並非容量上限。"))
            .recallFont(.caption).foregroundStyle(.secondary)
            .recallSettingsNote()
        } else {
          Text(model.text("目前格式、品質或螢幕配置尚無樣本。試拍一次，或等待下一輪記錄。"))
            .recallFont(.caption).foregroundStyle(.secondary)
            .recallSettingsNote()
        }
        if let stats = model.recordingSizeStats {
          LabeledContent(
            model.text("圖片庫實際佔用"), value: bytes(stats.averageBytes * Double(stats.sampleCount)))
        }
        if let updatedAt = model.recordingStatsUpdatedAt {
          Text(
            "\(model.text("讀取時間"))：\(updatedAt.formatted(.dateTime.year().month().day().hour().minute().second().locale(model.preferences.language.locale)))"
          )
          .recallFont(.caption).foregroundStyle(.secondary)
          .recallSettingsNote()
        }
        Text(model.text("每個螢幕分開保存；同一次擷取在預覽中一起顯示。估算不含索引。"))
          .recallFont(.caption).foregroundStyle(.secondary)
          .recallSettingsNote()
      }
    }
  }

  private func forecastColumn(_ key: String, _ value: String) -> some View {
    VStack(alignment: .leading) {
      Text(model.text(key)).recallFont(.caption).foregroundStyle(.secondary)
      Text(value).monospacedDigit().fontWeight(.medium)
    }
  }

  private var recordingButtonKey: String {
    if model.isBurstRecording { return "結束短時記錄" }
    return model.recordingRequested ? "暫停記錄" : "開始記錄"
  }

  private func scaled(_ pixels: Int, by scale: Double) -> Int {
    max(1, Int((Double(pixels) * scale).rounded(.toNearestOrAwayFromZero)))
  }

  private func bytes(_ value: Double) -> String {
    bytes(Int64(value.rounded()))
  }

  private func bytes(_ value: Int64) -> String {
    model.preferences.language.bytes(value)
  }

  private func formatDuration(_ seconds: Int) -> String {
    let minutes = seconds / 60
    let remainder = seconds % 60
    return "\(minutes):\(String(format: "%02d", remainder))"
  }

}

private struct BurstRecordingSection: View {
  @Bindable var model: RecallModel

  var body: some View {
    RecallSettingsSection(title: model.text("短時高頻記錄"), nativeForm: false) {
      intervalRow
      durationRow
      planSummary
      actionButton
      Text(model.text("間隔為目標頻率；擷取或編碼來不及時略過排程，不累積補拍。"))
        .recallFont(.caption).foregroundStyle(.secondary)
        .recallSettingsNote()
      if model.isBurstRecording {
        Text(model.text("短時記錄結束後，若啟動前正在日常記錄，會自動回到日常設定；手動結束則保持暫停。"))
          .recallFont(.caption)
          .foregroundStyle(.secondary)
          .recallSettingsNote()
      }
    }
    .accessibilityIdentifier("recording.burst-settings")
  }

  private var intervalRow: some View {
    RecallSettingsRow(label: model.text("短時擷取間隔")) {
      Picker(model.text("短時擷取間隔"), selection: $model.burstIntervalSeconds) {
        ForEach(RecordingBurstPlan.intervalChoices, id: \.self) { seconds in
          Text(model.preferences.language.seconds(seconds)).tag(seconds)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .disabled(model.isBurstRecording || model.recordingBusy)
      .accessibilityIdentifier("recording.burst-interval")
    }
  }

  private var durationRow: some View {
    RecallSettingsRow(label: model.text("短時持續時間")) {
      Picker(model.text("短時持續時間"), selection: $model.burstDurationMinutes) {
        ForEach(RecordingBurstPlan.durationChoicesMinutes, id: \.self) { minutes in
          Text(model.preferences.language.minutes(minutes)).tag(minutes)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .disabled(model.isBurstRecording || model.recordingBusy)
      .accessibilityIdentifier("recording.burst-duration")
    }
  }

  @ViewBuilder private var planSummary: some View {
    if let plan = model.burstPlan {
      Text(planDescription(plan))
        .recallFont(.caption)
        .foregroundStyle(.secondary)
        .recallSettingsNote()
      if let estimate = model.burstEstimatedBytes {
        Text(estimateDescription(estimate))
          .recallFont(.caption)
          .foregroundStyle(.secondary)
          .recallSettingsNote()
      } else {
        Text(model.text("開始記錄後，這裡會用實際檔案大小估算短時用量。"))
          .recallFont(.caption)
          .foregroundStyle(.secondary)
          .recallSettingsNote()
      }
    }
  }

  private var actionButton: some View {
    Button(model.text(model.isBurstRecording ? "結束短時記錄" : "開始短時記錄")) {
      if model.isBurstRecording {
        model.pauseRecording()
      } else {
        model.startBurstRecording()
      }
    }
    .buttonStyle(.borderedProminent)
    .tint(model.isBurstRecording ? .orange : nil)
    .disabled(model.isDemo || model.recordingBusy)
    .accessibilityIdentifier("recording.burst-toggle")
  }

  private func planDescription(_ plan: RecordingBurstPlan) -> String {
    "\(model.text("每輪固定保存所有螢幕；短時模式不會改寫日常設定。"))\n\(model.text("預計")) \(plan.cycleCount) \(model.text("輪")) · \(model.preferences.language.seconds(plan.intervalSeconds)) × \(model.preferences.language.minutes(plan.durationMinutes))"
  }

  private func estimateDescription(_ estimate: Double) -> String {
    "\(model.text("這段記錄約")) \(model.preferences.language.bytes(Int64(estimate.rounded()))) · \(model.text("實際會隨內容與螢幕數變化。"))"
  }
}

struct PermissionView: View {
  @Bindable var model: RecallModel
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label(model.text("需要螢幕錄製權限"), systemImage: "rectangle.inset.filled.and.person.filled")
        .recallFont(.title2, weight: .bold)
      Text(model.text("開啟螢幕錄製權限後，返回 App 再次檢查。"))
        .foregroundStyle(.secondary)
      HStack {
        Button(model.text("稍後")) { model.needsPermission = false }
        Spacer()
        Button(model.text("開啟系統設定")) { CaptureRecorder.openPermissionSettings() }
          .accessibilityIdentifier("permission.settings")
        Button(model.text(model.permissionGranted ? "開始記錄" : "再次檢查")) {
          model.refreshDevicesAndPermission()
          if model.permissionGranted { model.startRecording() }
        }.buttonStyle(.borderedProminent).accessibilityIdentifier("permission.check")
      }
    }.padding(28).frame(width: 500)
      .environment(\.locale, model.preferences.language.locale)
  }
}
