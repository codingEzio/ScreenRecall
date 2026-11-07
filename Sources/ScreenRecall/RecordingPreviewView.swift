import RecallCore
import SwiftUI

struct RecordingPreviewView: View {
  @Bindable var model: RecallModel
  @Environment(\.dismiss) private var dismiss
  @State private var decoded: [URL: DecodedImage] = [:]
  @State private var error: String?
  @State private var zoomed = false
  private let images = ImageStore()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(model.text("試拍預覽")).recallFont(.headline)
        if let preview = model.recordingPreview {
          Text(
            "\(preview.measurement.format.uppercased()) · Q\(Int((preview.measurement.quality * 100).rounded())) · \(ByteCountFormatter.string(fromByteCount: preview.measurement.totalBytes, countStyle: .file))"
          )
          .foregroundStyle(.secondary)
        }
        Spacer()
        Toggle(model.text("放大"), isOn: $zoomed).toggleStyle(.button)
        Button(model.text("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
      }
      if let preview = model.recordingPreview {
        DisplayWall(
          captures: preview.urls.map {
            Capture(
              url: $0, timestamp: preview.measurement.date.timeIntervalSince1970,
              displayID: String(
                $0.deletingPathExtension().lastPathComponent.split(separator: "_", maxSplits: 1)
                  .last ?? ""))
          },
          decoded: nil, decodedScreens: decoded, zoomed: zoomed,
          imageScale: 1, onScaleChanged: { _ in }, onNavigate: { _ in },
          arrangement: model.preferences.displayArrangement,
          displayOrigins: model.connectedDisplayOrigins,
          displayName: { id in model.connectedDisplays.first(where: { $0.id == id })?.name ?? id },
          label: model.text("試拍預覽"))
      }
      if let error { Text(error).foregroundStyle(.orange) }
      Text(model.text("這組試拍只用於比較畫質與估算，不會加入時間軸。"))
        .recallFont(.caption).foregroundStyle(.secondary)
    }.padding(20).frame(minWidth: 960, idealWidth: 1100, minHeight: 600, idealHeight: 720)
      .task {
        guard let preview = model.recordingPreview else { return }
        do {
          for url in preview.urls { decoded[url] = try await images.image(at: url, maxPixels: 0) }
        } catch { self.error = error.localizedDescription }
      }
  }
}
