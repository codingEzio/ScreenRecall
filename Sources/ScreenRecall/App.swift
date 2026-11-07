import AppKit
import RecallCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    CompactFont.registerBundledFont()
    if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--render-theme"),
      ProcessInfo.processInfo.arguments.indices.contains(index + 1)
    {
      let root = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1])
      if ProcessInfo.processInfo.arguments.contains("--product-only") {
        Task { @MainActor in
          do {
            try await RecallThemeRenderer.renderProduct(to: root)
            exit(0)
          } catch {
            fputs("Product render failed: \(error)\n", stderr)
            exit(1)
          }
        }
        return
      }
      do {
        try RecallThemeRenderer.render(to: root)
        exit(0)
      } catch {
        fputs("Theme render failed: \(error)\n", stderr)
        exit(1)
      }
    }
    RecallMenuBarService.install()
  }
}

@main
struct ScreenRecallApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var model: RecallModel
  init() {
    let args = ProcessInfo.processInfo.arguments
    if let index = args.firstIndex(of: "--render-theme"), args.indices.contains(index + 1) {
      let root = URL(fileURLWithPath: args[index + 1])
      let initialModel = RecallModel(
        configURL: root.appending(path: "preview-preferences.json"),
        sourceOverride: root.appending(path: "synthetic").path, demoOverride: true)
      _model = State(initialValue: initialModel)
    } else {
      let initialModel = RecallModel()
      _model = State(initialValue: initialModel)
      RecallMenuBarService.model = initialModel
    }
  }
  var body: some Scene {
    Window("ScreenRecall", id: "main") {
      RecallView(model: model)
        .frame(minWidth: 960, minHeight: 560)
        .recallFont(.body)
        .environment(\.recallTypography, model.preferences.typography)
        .recallSurface(model.preferences.visualTheme)
        .environment(\.locale, model.preferences.language.locale)
        .preferredColorScheme(
          model.preferences.appearance == "system"
            ? nil : model.preferences.appearance == "dark" ? .dark : .light
        )
        .background { RecallMenuBarBridge(model: model).frame(width: 0, height: 0) }
        .task {
          if !ProcessInfo.processInfo.arguments.contains("--render-theme") { model.bootstrap() }
        }
        .sheet(isPresented: $model.needsPermission) { PermissionView(model: model) }
        .alert(
          model.text("設定"),
          isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
        ) {
          Button(model.text("好")) { model.notice = nil }
        } message: {
          Text(model.text(model.notice ?? ""))
        }
    }
    .defaultSize(width: 1280, height: 820)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button(model.text("開啟歷史資料夾…")) { model.chooseFolder() }.keyboardShortcut("o")
      }
    }
    .commands { RecallCommands(model: model) }
    Settings {
      RecallSettings(model: model)
        .environment(\.locale, model.preferences.language.locale)
        .recallFont(.body)
        .environment(\.recallTypography, model.preferences.typography)
        .recallSurface(model.preferences.visualTheme)
    }
    Window(model.text("ScreenRecall 診斷"), id: "diagnostics") {
      DiagnosticsView(model: model)
        .recallFont(.body)
        .environment(\.recallTypography, model.preferences.typography)
        .recallSurface(model.preferences.visualTheme)
    }.defaultSize(width: 500, height: 560)

  }
}

struct RecallView: View {
  @Bindable var model: RecallModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.recallVisualTheme) private var visualTheme
  @Environment(\.colorScheme) private var colorScheme
  private var palette: RecallPalette {
    RecallPalette(theme: visualTheme, dark: colorScheme == .dark)
  }
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var timelineZooming = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      WorkspaceSidebar(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
    } detail: {
      detailContent
    }
    .searchable(
      text: $model.searchQuery, placement: .toolbar,
      prompt: Text(model.text("搜尋日期、時間、螢幕或檔名"))
    )
    .accessibilityIdentifier("library.search")
    .onChange(of: model.searchQuery) { _, _ in model.updateSearchResults() }
    .onChange(of: model.preferences.displayArrangement) { model.savePreferences() }
    .onAppear {
      model.showMainWindow = {
        model.goToNow()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button(action: model.chooseFolder) { Label(model.text("開啟歷史"), systemImage: "folder") }
          .help(model.text("開啟 ScreenRecall 圖片資料夾")).accessibilityIdentifier("library.open")
      }
      ToolbarItemGroup(placement: .navigation) {
        Button {
          model.moveDay(-1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .help(model.text("上一個有紀錄的日期")).disabled(model.selectedDay == model.days.first)
        .accessibilityLabel(model.text("上一天")).accessibilityIdentifier("day.previous")
        RecallDateField(
          selection: Binding(get: { model.selectedDay?.date ?? .now }, set: model.jump),
          locale: model.preferences.language.locale, enabled: !model.days.isEmpty
        )
        .frame(width: 112, height: 24)
        .help(model.text("跳到最接近的有紀錄日期")).accessibilityIdentifier("day.picker")
        Button {
          model.moveDay(1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .help(model.text("下一個有紀錄的日期")).disabled(model.selectedDay == model.days.last)
        .accessibilityLabel(model.text("下一天")).accessibilityIdentifier("day.next")
      }.sharedBackgroundVisibility(.hidden)
      ToolbarItem(placement: .automatic) {
        Menu {
          Picker(model.text("畫面排列"), selection: $model.preferences.displayArrangement) {
            Text(model.text("自動排列")).tag(DisplayArrangement.automatic)
            Text(model.text("左右並排")).tag(DisplayArrangement.sideBySide)
            Text(model.text("上下堆疊")).tag(DisplayArrangement.stacked)
          }
        } label: {
          Image(systemName: model.preferences.displayArrangement.systemImage)
        }
        .help(model.text("畫面排列"))
        .accessibilityLabel(model.text("畫面排列"))
        .accessibilityIdentifier("display.arrangement")
      }
      ToolbarItem(placement: .automatic) {
        if model.catalogBusy {
          ProgressView().controlSize(.small)
            .help(model.text("正在建立本機索引…"))
            .accessibilityLabel(model.text("正在建立本機索引…"))
        }
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button(action: model.toggleRecording) {
          Image(systemName: model.isRecording ? "pause.circle" : "record.circle")
        }.tint(model.isRecording ? .red : nil)
          .disabled(model.isDemo || model.recordingBusy)
          .help(model.text(model.isRecording ? "暫停記錄" : "開始記錄"))
          .accessibilityLabel(model.text(model.isRecording ? "暫停記錄" : "開始記錄"))
          .accessibilityIdentifier("recording.toolbar")
        Button {
          model.toggleZoom()
        } label: {
          Image(
            systemName: model.zoomed ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass"
          )
        }
        .disabled(model.decoded == nil).help(model.text(model.zoomed ? "符合視窗" : "放大兩倍"))
        .accessibilityLabel(model.text("切換放大")).accessibilityIdentifier("image.zoom")
        Button {
          model.goToNow()
        } label: {
          Label(model.text("回到現在"), systemImage: "arrow.clockwise")
        }
        .help(model.text("重新讀取並跳到最新畫面")).accessibilityIdentifier("library.refresh")
        SettingsLink { Image(systemName: "slider.horizontal.3") }.help(model.text("預覽設定"))
          .accessibilityIdentifier("settings.open")
          .accessibilityLabel(model.text("設定"))
      }.sharedBackgroundVisibility(.hidden)
    }
    .touchBar {
      HStack {
        Button {
          model.moveDay(-1)
        } label: {
          Label(model.text("上一天"), systemImage: "chevron.left.2")
        }
        Button {
          model.navigateBySwipe(-1)
        } label: {
          Label(model.text("上一張"), systemImage: "backward.frame")
        }
        .disabled(!model.canNavigate(-1))
        Text(
          Date(timeIntervalSince1970: model.playheadTime).formatted(model.clockStyle(seconds: true))
        )
        .monospacedDigit()
        Button {
          model.navigateBySwipe(1)
        } label: {
          Label(model.text("下一張"), systemImage: "forward.frame")
        }
        .disabled(!model.canNavigate(1))
        Button(action: model.togglePlayback) {
          Label(
            model.text(model.isPlaying ? "暫停回看" : "播放回看"),
            systemImage: model.isPlaying ? "pause.fill" : "play.fill")
        }
        .disabled(model.captures.count < 2)
        Button(action: model.toggleMark) {
          Label(
            model.text(model.annotationMarked ? "取消標記" : "標記"),
            systemImage: model.annotationMarked ? "bookmark.fill" : "bookmark")
        }
        .disabled(model.current == nil || model.annotationBusy)
        Button {
          model.moveDay(1)
        } label: {
          Label(model.text("下一天"), systemImage: "chevron.right.2")
        }
        Spacer()
        Button(action: model.toggleRecording) {
          Label(
            model.text(model.isRecording ? "暫停記錄" : "開始記錄"),
            systemImage: model.isRecording ? "pause.circle" : "record.circle")
        }
        .disabled(model.isDemo || model.recordingBusy)
      }
    }
  }

  private var detailContent: some View {
    VStack(spacing: 0) {
      imageArea.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
          visualTheme == .monochrome
            ? palette.canvas : Color(nsColor: .underPageBackgroundColor).opacity(0.35))
      if !model.captures.isEmpty {
        Divider()
        timeline
          .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 14)
          .background(
            visualTheme == .monochrome ? palette.surface : Color(nsColor: .windowBackgroundColor))
      }
    }
    .background(
      visualTheme == .monochrome ? palette.surface : Color(nsColor: .controlBackgroundColor)
    )
    .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
      if model.catalogError != nil || model.recordingError != nil || model.annotationError != nil {
        VStack(alignment: .leading, spacing: 6) {
          if let recordingError = model.recordingError {
            Label(model.text(recordingError), systemImage: "record.circle")
          }
          if model.catalogError != nil {
            Label(
              model.text("本機索引未完成，搜尋可能不完整。"),
              systemImage: "exclamationmark.triangle")
          }
          if let annotationError = model.annotationError {
            Label(annotationError, systemImage: "bookmark.slash")
          }
        }
        .recallFont(.caption).foregroundStyle(.orange)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.thinMaterial, in: .rect(cornerRadius: 10))
        .padding(16)
        .accessibilityIdentifier("status.warning")
      }
    }
  }

  @ViewBuilder private var imageArea: some View {
    if let error = model.error {
      ContentUnavailableView {
        Label(model.text("無法開啟歷史"), systemImage: "folder.badge.questionmark")
      } description: {
        Text(model.text(error))
      } actions: {
        Button(model.text("選擇資料夾…"), action: model.chooseFolder)
      }
    } else if let error = model.imageError {
      ContentUnavailableView {
        Label(model.text("截圖無法顯示"), systemImage: "photo.badge.exclamationmark")
      } description: {
        Text(model.text(error))
      } actions: {
        Button(model.text("重試"), action: model.requestImage)
      }
    } else if model.decoded != nil {
      DisplayWall(
        captures: model.currentGroup,
        decoded: model.decoded,
        decodedScreens: model.decodedScreens,
        zoomed: model.zoomed,
        imageScale: model.imageScale,
        onScaleChanged: model.setImageScale,
        onNavigate: model.navigateBySwipe,
        arrangement: model.preferences.displayArrangement,
        displayOrigins: model.connectedDisplayOrigins,
        displayName: model.displayName,
        label: model.text("歷史截圖"))
    } else if model.loading || model.current != nil {
      ProgressView(model.text("載入畫面…")).accessibilityIdentifier("library.loading")
    } else {
      ContentUnavailableView(
        model.text("這裡還沒有截圖"), systemImage: "photo.on.rectangle",
        description: Text(model.text("選擇 ScreenRecall 圖片資料夾，或切換到有紀錄的日期。")))
    }
  }

  private var timeline: some View {
    VStack(spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(model.text("時間軸")).recallFont(.caption, weight: .semibold)
        Text(
          String(
            format: model.text("frame_count"), locale: model.preferences.language.locale,
            model.selection + 1, model.captures.count)
        )
        .recallFont(.caption, technical: true)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("frame.position")
        Spacer()
        if let decoded = model.decoded {
          Text(
            String(
              format: model.text("original_dimensions"),
              locale: model.preferences.language.locale, decoded.originalWidth,
              decoded.originalHeight)
          )
          .recallFont(.caption, technical: true).foregroundStyle(.secondary)
        }
      }
      filmstrip
      VStack(spacing: 2) {
        TimelineCoverage(
          captures: model.captures, range: model.visibleTimeRange, playhead: model.playheadTime,
          marks: Timeline.rulerMarks(in: model.visibleTimeRange))
        Slider(
          value: Binding(
            get: {
              let range = model.visibleTimeRange
              return min(max(model.playheadTime, range.lowerBound), range.upperBound)
            }, set: model.scrub
          ),
          in: model.visibleTimeRange
        ) {
          Text(model.text("時間軸"))
        } onEditingChanged: {
          model.editingTimeline($0)
        }
        .labelsHidden()
        .disabled(model.captures.count < 2).accessibilityIdentifier("timeline.slider")
        TimelineHourLabels(
          range: model.visibleTimeRange, marks: Timeline.rulerMarks(in: model.visibleTimeRange))
      }
      ReviewControls(model: model)
    }
    .simultaneousGesture(
      MagnificationGesture()
        .onChanged { value in
          if !timelineZooming {
            timelineZooming = true
            model.beginTimelineZoom()
          }
          model.adjustTimelineZoom(by: value)
        }
        .onEnded { _ in timelineZooming = false }
    )
  }

  private var filmstrip: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 8) {
          ForEach(model.captures) { capture in
            Thumbnail(
              capture: capture, images: model.images,
              selected: capture.id == model.current?.id,
              timeLabel: capture.date.formatted(model.clockStyle(seconds: true))
            ) {
              model.choose(capture)
            }
            .frame(width: 116, height: 82)
            .id(capture.id)
          }
        }
      }
      .scrollIndicators(.hidden, axes: .horizontal)
      .frame(height: 82)
      .accessibilityIdentifier("timeline.filmstrip")
      .onAppear { scrollFilmstrip(proxy) }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: { _ in
        scrollFilmstrip(proxy, animated: false)
      }
      .onChange(of: model.current?.id) { _, _ in scrollFilmstrip(proxy) }
    }
  }

  private func scrollFilmstrip(_ proxy: ScrollViewProxy, animated: Bool = true) {
    guard let id = model.current?.id else { return }
    if model.scrubbing || model.isPlaying || reduceMotion || !animated {
      proxy.scrollTo(id, anchor: .center)
    } else {
      withAnimation(.snappy(duration: 0.2, extraBounce: 0)) { proxy.scrollTo(id, anchor: .center) }
    }
  }
}

private struct TimelineCoverage: View {
  let captures: [Capture]
  let range: ClosedRange<Double>
  let playhead: Double
  let marks: [Timeline.RulerMark]

  var body: some View {
    TimelineCoverageTrack(captures: captures, range: range, marks: marks)
      .equatable()
      .overlay {
        Canvas { context, size in
          let span = range.upperBound - range.lowerBound
          guard span > 0 else { return }
          let x = CGFloat((playhead - range.lowerBound) / span) * size.width
          var needle = Path()
          needle.move(to: CGPoint(x: x, y: 0))
          needle.addLine(to: CGPoint(x: x, y: size.height))
          context.stroke(needle, with: .color(.accentColor), lineWidth: 1.5)
        }
      }
      .frame(height: 16)
      .accessibilityHidden(true)
  }
}

/// The capture path stays unchanged while only the playhead moves.
private struct TimelineCoverageTrack: View, Equatable {
  let captures: [Capture]
  let range: ClosedRange<Double>
  let marks: [Timeline.RulerMark]

  var body: some View {
    Canvas { context, size in
      let span = range.upperBound - range.lowerBound
      guard span > 0, size.width > 0 else { return }
      context.fill(
        Path(CGRect(x: 0, y: 6, width: size.width, height: 4)),
        with: .color(.secondary.opacity(0.12)))
      for mark in marks where mark.major {
        let x = CGFloat((mark.timestamp - range.lowerBound) / span) * size.width
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(.secondary.opacity(0.28)), lineWidth: 1)
      }
      var bars = Path()
      for capture in captures where range.contains(capture.timestamp) {
        let x = CGFloat((capture.timestamp - range.lowerBound) / span) * size.width
        bars.addRect(CGRect(x: x, y: 3, width: 2, height: 10))
      }
      context.fill(bars, with: .color(.secondary.opacity(0.55)))
    }
  }
}

private struct TimelineHourLabels: View {
  @Environment(\.recallTypography) private var typography
  let range: ClosedRange<Double>
  let marks: [Timeline.RulerMark]

  var body: some View {
    Canvas { context, size in
      let span = range.upperBound - range.lowerBound
      guard span > 0, size.width > 0 else { return }
      for mark in marks where mark.major {
        let x = CGFloat((mark.timestamp - range.lowerBound) / span) * size.width
        let label = Timeline.rulerLabel(mark.timestamp, range: range)
        let text = Text(label).font(typography.font(.caption2, technical: true)).foregroundStyle(
          .secondary)
        let anchor: UnitPoint =
          x < 14 ? .leading : x > size.width - 14 ? .trailing : .center
        context.draw(context.resolve(text), at: CGPoint(x: x, y: size.height / 2), anchor: anchor)
      }
    }
    .frame(height: 16)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(hourAccessibilityLabel)
    .accessibilityIdentifier("timeline.hours")
  }

  private var hourAccessibilityLabel: String {
    marks.filter(\.major).map { Timeline.rulerLabel($0.timestamp, range: range) }.joined(
      separator: " ")
  }
}

struct Thumbnail: View {
  let capture: Capture
  let images: ImageStore
  let selected: Bool
  var timeLabel: String
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var decoded: DecodedImage?
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        ZStack {
          RoundedRectangle(cornerRadius: 6).fill(.quaternary)
          if let decoded {
            Image(decorative: decoded.image, scale: 1).resizable().scaledToFit()
          } else {
            Image(systemName: "photo").foregroundStyle(.tertiary)
          }
        }
        .frame(height: 56)
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(
              selected ? Color.accentColor : Color.primary.opacity(hovered ? 0.25 : 0.08),
              lineWidth: selected ? 2 : 1)
        }
        Text(timeLabel)
          .recallFont(.caption2, weight: selected ? .semibold : .regular, technical: true)
          .monospacedDigit()
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .lineLimit(1)
      }
      .padding(3)
      .background(
        selected ? Color.accentColor.opacity(0.08) : .clear,
        in: .rect(cornerRadius: 9)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
    .accessibilityLabel(timeLabel)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .task(id: capture.id) {
      let image = try? await images.image(at: capture.url, maxPixels: 256)
      guard !Task.isCancelled else { return }
      decoded = image
    }
  }
}

struct RecallSettings: View {
  @Bindable var model: RecallModel
  @State private var selectedTab: String
  init(model: RecallModel, initialTab: String = "recording") {
    self.model = model
    _selectedTab = State(initialValue: initialTab)
  }
  @Environment(\.colorScheme) private var colorScheme
  private var palette: RecallPalette {
    RecallPalette(theme: model.preferences.visualTheme, dark: colorScheme == .dark)
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker(model.text("設定"), selection: $selectedTab) {
          Text(model.text("記錄")).tag("recording")
          Text(model.text("一般")).tag("general")
        }
        .labelsHidden().pickerStyle(.segmented)
        .frame(maxWidth: 300)
        .accessibilityIdentifier("settings.tabs")
      }.frame(maxWidth: .infinity).frame(height: 48)
      Divider()
      GeometryReader { geometry in
        let wide = geometry.size.width >= 800
        let cardWidth = wide ? (geometry.size.width - 48) / 2 : geometry.size.width - 32
        ScrollView {
          Group {
            if selectedTab == "recording" {
              RecordingSettings(model: model, wide: wide)
            } else {
              VStack(alignment: .leading, spacing: 12) {
                if wide {
                  HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                      appearanceSection
                      integrationSection
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 12) {
                      previewSection
                      librarySection
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                  }
                } else {
                  appearanceSection
                  previewSection
                  integrationSection
                  librarySection
                }
              }
            }
          }
          .environment(\.recallSettingsTextWidth, cardWidth - 20)
          .environment(\.recallSettingsControlWidth, cardWidth - 138)
          .frame(width: geometry.size.width - 32, alignment: .leading)
          .padding(16)
        }
      }
    }.background(palette.canvas)
      .controlSize(.small)
      .frame(
        minWidth: 600, idealWidth: 840, maxWidth: .infinity, minHeight: 440,
        idealHeight: 620,
        maxHeight: .infinity, alignment: .top
      )
      .sheet(isPresented: $model.showRecordingPreview) { RecordingPreviewView(model: model) }
      .preferredColorScheme(
        model.preferences.appearance == "system"
          ? nil : model.preferences.appearance == "dark" ? .dark : .light
      )
      .onChange(of: model.preferences.visualTheme) { model.savePreferences() }
      .onChange(of: model.preferences.typography) { model.savePreferences() }
      .onChange(of: model.preferences.language) { model.savePreferences() }
      .onChange(of: model.preferences.recording) { model.updateRecordingOptions() }
      .onChange(of: model.preferences.appearance) { model.savePreferences() }
      .onChange(of: model.preferences.showInDock) {
        model.applyDockVisibility()
        model.savePreferences()
      }
      .onChange(of: model.preferences.previewPixels) {
        model.savePreferences()
        model.requestImage()
      }
  }

  private var appearanceSection: some View {
    RecallSettingsSection(title: model.text("介面與外觀"), nativeForm: false) {
      RecallSettingsRow(label: model.text("語言")) {
        Picker(model.text("語言"), selection: $model.preferences.language) {
          ForEach(AppLanguage.allCases, id: \.self) { language in
            Text(language == .system ? model.text("跟隨系統") : language.localizedName).tag(
              language)
          }
        }.pickerStyle(.menu).accessibilityIdentifier("settings.language")
      }
      RecallSettingsRow(label: model.text("主題")) {
        Picker(model.text("主題"), selection: $model.preferences.visualTheme) {
          ForEach(RecallVisualTheme.allCases, id: \.self) { theme in
            Text(model.text(theme.localizationKey)).tag(theme)
          }
        }.pickerStyle(.menu).accessibilityIdentifier("settings.visual-theme")
      }
      RecallSettingsRow(label: model.text("字體")) {
        Picker(model.text("字體"), selection: $model.preferences.typography) {
          ForEach(RecallTypography.allCases, id: \.self) { typography in
            Text(model.text(typography.localizationKey)).tag(typography)
          }
        }.pickerStyle(.menu).accessibilityIdentifier("settings.typography")
      }
      RecallSettingsRow(label: model.text("外觀")) {
        Picker(model.text("外觀"), selection: $model.preferences.appearance) {
          Text(model.text("跟隨系統")).tag("system")
          Text(model.text("淺色")).tag("light")
          Text(model.text("深色")).tag("dark")
        }.pickerStyle(.menu).accessibilityIdentifier("settings.appearance")
      }

    }
  }
  private var previewSection: some View {
    RecallSettingsSection(title: model.text("預覽設定"), nativeForm: false) {
      RecallSettingsRow(label: model.text("畫面排列")) {
        Picker(model.text("畫面排列"), selection: $model.preferences.displayArrangement) {
          Text(model.text("自動排列")).tag(DisplayArrangement.automatic)
          Text(model.text("左右並排")).tag(DisplayArrangement.sideBySide)
          Text(model.text("上下堆疊")).tag(DisplayArrangement.stacked)
        }.pickerStyle(.menu).accessibilityIdentifier("settings.display-arrangement")
      }
      RecallSettingsRow(label: model.text("清晰度")) {
        Picker(model.text("清晰度"), selection: $model.preferences.previewPixels) {
          Text(model.text("輕量 · 1280 px")).tag(1280)
          Text(model.text("均衡 · 2560 px")).tag(2560)
          Text(model.text("細緻 · 4096 px")).tag(4096)
          Text(model.text("原始尺寸 · 最高 8192 px")).tag(0)
        }.accessibilityIdentifier("settings.quality")
      }
      Text(model.text("拖曳時先顯示快速預覽，停下後補上所選清晰度。原始檔案不變，舊圖已失去的細節無法還原。"))
        .recallFont(.caption).foregroundStyle(.secondary)
        .recallSettingsNote()
        .fixedSize(horizontal: false, vertical: true)

    }
  }
  private var librarySection: some View {
    RecallSettingsSection(title: model.text("歷史來源"), nativeForm: false) {
      Text(model.text("資料夾")).recallFont(.caption).foregroundStyle(.secondary)
      Text(model.preferences.source).recallFont(.callout, technical: true)
        .textSelection(.enabled).recallSettingsNote()
      Button(model.text("選擇資料夾…"), action: model.chooseFolder)
      Text(model.text("舊歷史保持唯讀；新記錄分開儲存，不讀取 OCR。"))
        .recallFont(.caption).foregroundStyle(.secondary)
        .recallSettingsNote()
        .fixedSize(horizontal: false, vertical: true)
      Button(model.text("還原上一次設定"), action: model.restorePreferences)

    }
  }
  private var integrationSection: some View {
    RecallSettingsSection(title: model.text("系統整合"), nativeForm: false) {
      Toggle(model.text("顯示 Dock 圖示"), isOn: $model.preferences.showInDock)
        .accessibilityIdentifier("settings.show-in-dock")
      Toggle(
        model.text("登入時啟動"),
        isOn: Binding(
          get: { model.launchAtLoginEnabled },
          set: model.setLaunchAtLogin)
      )
      .accessibilityIdentifier("settings.launch-at-login")
      Text(model.text("登入時啟動使用 macOS 系統登入項目；實際狀態以系統為準。"))
        .recallFont(.caption).foregroundStyle(.secondary)
        .recallSettingsNote()
        .fixedSize(horizontal: false, vertical: true)

    }
  }

}
