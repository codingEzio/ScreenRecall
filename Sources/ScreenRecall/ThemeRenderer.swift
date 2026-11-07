import AppKit
import Foundation
import RecallCore
import SwiftUI

/// Synthetic, offscreen previews. Does not bootstrap or use production preferences/catalog.
@MainActor
enum RecallThemeRenderer {
  /// Render the real product view from an explicitly marked synthetic library.
  static func renderProduct(to root: URL) async throws {
    let fixture = root.appending(path: "synthetic")
    guard FileManager.default.fileExists(atPath: fixture.appending(path: ".screenrecall-fixture").path)
    else { throw CocoaError(.fileReadNoSuchFile) }
    let model = RecallModel(sourceOverride: fixture.path, demoOverride: true)
    model.preferences.language = .english
    model.openSource()
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while model.captures.isEmpty || model.decoded == nil || model.catalogBusy || model.annotationsBusy || model.decodedScreens.count < model.currentGroup.count {
      if let error = model.catalogError { throw NSError(domain: "SyntheticPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
      guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
      try await Task.sleep(for: .milliseconds(20))
    }
    for dark in [false, true] {
      model.preferences.appearance = dark ? "dark" : "light"
      let view = NSHostingView(rootView: RecallView(model: model)
        .recallFont(.body)
        .environment(\.recallTypography, model.preferences.typography)
        .environment(\.locale, model.preferences.language.locale)
        .recallSurface(model.preferences.visualTheme)
        .preferredColorScheme(dark ? .dark : .light))
      view.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
      view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      let host = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
      host.contentView = view
      view.layoutSubtreeIfNeeded()
      // Let SwiftUI's fixture-only thumbnail tasks complete before exporting the view.
      for capture in model.captures.suffix(12) {
        _ = try await model.images.image(at: capture.url, maxPixels: 256)
      }
      await Task.yield()
      try snapshot(view, to: root.appending(path: dark ? "product-dark.png" : "product-light.png"))
      host.contentView = nil
    }
  }

  static func render(to root: URL) throws {
    if ProcessInfo.processInfo.arguments.contains("--settings-only") {
      try renderSettings(to: root)
      return
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = RecallModel(
      configURL: root.appending(path: "preview-preferences.json"),
      sourceOverride: root.appending(path: "synthetic").path, demoOverride: false)
    model.preferences.recording.intervalSeconds = 300
    let controller = RecallMenuBarController(model: model, history: {}, settings: {})
    for language in AppLanguage.allCases where language != .system {
      model.preferences.language = language
      for dark in [false, true] {
        model.preferences.appearance = dark ? "dark" : "light"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        for theme in RecallVisualTheme.allCases {
          model.preferences.visualTheme = theme
          let name = "\(theme.rawValue)-\(dark ? "dark" : "light")-\(language.rawValue)"
          if theme == .monochrome {
            let panel = controller.makePanel()
            panel.appearance = appearance
            try snapshot(panel, to: root.appending(path: "menu-\(name).png"))
            model.isRecording = true
            model.preferences.recordingIntent = .active
            let recordingPanel = controller.makePanel()
            recordingPanel.appearance = appearance
            try snapshot(recordingPanel, to: root.appending(path: "menu-recording-\(name).png"))
            model.isBurstRecording = true
            model.burstIntervalSeconds = 3
            model.burstDurationMinutes = 10
            model.burstRemainingSeconds = 91
            let burstPanel = controller.makePanel()
            burstPanel.appearance = appearance
            try snapshot(burstPanel, to: root.appending(path: "menu-burst-\(name).png"))
            model.isBurstRecording = false
            model.burstRemainingSeconds = nil
            model.recordingError = "需要螢幕錄製權限"
            let errorPanel = controller.makePanel()
            errorPanel.appearance = appearance
            try snapshot(errorPanel, to: root.appending(path: "menu-error-\(name).png"))
            model.isRecording = false
            model.preferences.recordingIntent = .paused
            model.recordingError = nil
          }
          for tab in ["recording", "general"] {
            let settings = NSHostingView(
              rootView: RecallSettings(model: model, initialTab: tab)
                .recallFont(.body)
                .environment(\.recallTypography, model.preferences.typography)
                .environment(\.locale, model.preferences.language.locale)
                .recallSurface(theme)
                .preferredColorScheme(dark ? .dark : .light))
            settings.frame = NSRect(x: 0, y: 0, width: 680, height: 590)
            settings.appearance = appearance
            try snapshot(settings, to: root.appending(path: "settings-\(tab)-\(name).png"))
            if theme == .monochrome && [.english, .russian, .traditionalChinese].contains(language)
            {
              settings.frame.size.width = 600
              try snapshot(settings, to: root.appending(path: "settings-\(tab)-narrow-\(name).png"))
              settings.frame.size = NSSize(width: 840, height: 590)
              try snapshot(settings, to: root.appending(path: "settings-\(tab)-wide-\(name).png"))
              settings.frame.size = NSSize(width: 680, height: 1400)
              try snapshot(settings, to: root.appending(path: "settings-\(tab)-full-\(name).png"))
              let pixelSettings = NSHostingView(
                rootView: RecallSettings(model: model, initialTab: tab)
                  .recallFont(.body)
                  .environment(\.recallTypography, RecallTypography.compact)
                  .environment(\.locale, model.preferences.language.locale)
                  .recallSurface(theme)
                  .preferredColorScheme(dark ? .dark : .light))
              pixelSettings.frame = NSRect(
                x: 0, y: 0, width: 600, height: 590)
              pixelSettings.appearance = appearance
              try snapshot(
                pixelSettings, to: root.appending(path: "settings-\(tab)-pixel-narrow-\(name).png"))
            }
          }
        }
      }
    }
  }

  /// Bounded Settings-only visual check, independent from capture/bootstrap.
  private static func renderSettings(to root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = RecallModel(
      configURL: root.appending(path: "preview-preferences.json"),
      sourceOverride: root.appending(path: "synthetic").path, demoOverride: false)
    model.preferences.recording.intervalSeconds = 300
    model.burstIntervalSeconds = 3
    model.burstDurationMinutes = 10
    let summary = try usageFixture(at: root.appending(path: "usage-fixture"))
    model.recordingRecentSizeStats = summary.recent
    model.recordingSizeStats = summary.allFiles
    model.recordingStatsUpdatedAt = summary.readAt
    model.recordingStatsBusy = false
    print(
      "Synthetic usage: 24h=\(summary.recent.last24Hours.byteCount), 7d=\(summary.recent.last7Days.byteCount), 30d=\(summary.recent.last30Days.byteCount)"
    )
    for language in [AppLanguage.english, .traditionalChinese, .russian] {
      model.preferences.language = language
      for dark in [false, true] {
        model.preferences.appearance = dark ? "dark" : "light"
        for tab in ["general", "recording"] {
          for width: CGFloat in [840, 600] {
            try settingsSnapshot(
              model: model, tab: tab, width: width, theme: .monochrome,
              typography: .system, dark: dark, root: root)
            if dark && language != .english {
              try settingsSnapshot(
                model: model, tab: tab, width: width, theme: .monochrome,
                typography: .compact, dark: dark, root: root)
            }
          }
          if !dark && language == .english {
            try settingsSnapshot(
              model: model, tab: tab, width: 840, theme: .classic,
              typography: .system, dark: dark, root: root)
          }
        }
      }
    }
  }

  private static func settingsSnapshot(
    model: RecallModel, tab: String, width: CGFloat,
    theme: RecallVisualTheme, typography: RecallTypography, dark: Bool, root: URL
  ) throws {
    model.preferences.visualTheme = theme
    let view = NSHostingView(
      rootView: RecallSettings(model: model, initialTab: tab)
        .recallFont(.body).environment(\.recallTypography, typography)
        .environment(\.recallSettingsPreview, true)
        .environment(\.locale, model.preferences.language.locale).recallSurface(theme)
        .preferredColorScheme(dark ? .dark : .light))
    view.frame = NSRect(x: 0, y: 0, width: width, height: width >= 800 ? 620 : 1100)
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let name =
      "settings-\(tab)-\(theme.rawValue)-\(typography.rawValue)-\(dark ? "dark" : "light")-\(model.preferences.language.rawValue)-\(Int(width)).png"
    try snapshot(view, to: root.appending(path: name))
  }

  /// Metadata-only disposable fixtures; production model/data owners are not used.
  private static func usageFixture(at root: URL) throws -> CaptureLibraryFileSizeSummary {
    let reference = Date(timeIntervalSince1970: 1_790_467_200)
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy/MM/dd/HH"
    for (age, count) in [(3600.0, 131_072), (3 * 86_400.0, 524_288), (20 * 86_400.0, 1_572_864)] {
      let date = reference.addingTimeInterval(-age)
      let directory = root.appending(path: "screenshots/" + formatter.string(from: date))
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      // Only file size/name metadata is consumed; these are not decoded images.
      try Data(repeating: 0, count: count).write(
        to: directory.appending(path: "\(date.timeIntervalSince1970)_fixture.webp"))
    }
    let result = RecallRenderSummary()
    let ready = DispatchSemaphore(value: 0)
    Task.detached {
      do {
        result.store(
          .success(try await CaptureLibrary(root: root).fileSizeSummary(asOf: reference)))
      } catch { result.store(.failure(error)) }
      ready.signal()
    }
    guard ready.wait(timeout: .now() + 10) == .success, let value = result.value else {
      throw CocoaError(.fileReadUnknown)
    }
    return try value.get()
  }

  private static func snapshot(_ view: NSView, to output: URL) throws {
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.appearance = view.appearance
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: output)
  }
}

private final class RecallRenderSummary: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<CaptureLibraryFileSizeSummary, Error>?
  func store(_ value: Result<CaptureLibraryFileSizeSummary, Error>) {
    lock.withLock { result = value }
  }
  var value: Result<CaptureLibraryFileSizeSummary, Error>? { lock.withLock { result } }
}
