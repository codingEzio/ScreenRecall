import RecallCore
import SwiftUI

enum DisplayArrangement: String, Codable, CaseIterable, Sendable, Identifiable {
  case automatic
  case sideBySide
  case stacked

  var id: Self { self }

  var systemImage: String {
    switch self {
    case .automatic: "rectangle.split.2x1"
    case .sideBySide: "rectangle.split.2x1"
    case .stacked: "rectangle.split.1x2"
    }
  }
}

struct DisplayOrigin: Equatable, Sendable {
  let x: Double
  let y: Double
}

enum DisplayWallLayout: Equatable, Sendable {
  case sideBySide
  case stacked

  static func resolve(
    mode: DisplayArrangement,
    aspectRatios: [Double],
    displayOrigins: [DisplayOrigin] = [],
    width: Double,
    height: Double
  ) -> Self {
    guard aspectRatios.count > 1, width > 0, height > 0 else { return .sideBySide }
    switch mode {
    case .sideBySide: return .sideBySide
    case .stacked: return .stacked
    case .automatic: break
    }

    if let physicalLayout = physicalLayout(for: displayOrigins) {
      return physicalLayout
    }

    // Historical metadata may not contain display coordinates. Keep that case stable
    // instead of changing the layout whenever the app window is resized.
    return .stacked
  }

  private static func physicalLayout(for origins: [DisplayOrigin]) -> Self? {
    guard origins.count > 1 else { return nil }
    let xValues = origins.map(\.x)
    let yValues = origins.map(\.y)
    let xSpread = (xValues.max() ?? 0) - (xValues.min() ?? 0)
    let ySpread = (yValues.max() ?? 0) - (yValues.min() ?? 0)
    guard xSpread > 0 || ySpread > 0 else { return nil }
    if ySpread > xSpread * 1.15 { return .stacked }
    if xSpread > ySpread * 1.15 { return .sideBySide }
    return nil
  }
}

struct DisplayWall: View {
  let captures: [Capture]
  let decoded: DecodedImage?
  let decodedScreens: [URL: DecodedImage]
  let zoomed: Bool
  let imageScale: CGFloat
  let onScaleChanged: (CGFloat) -> Void
  let onNavigate: (Int) -> Void
  let arrangement: DisplayArrangement
  let displayOrigins: [String: DisplayOrigin]
  let displayName: (String) -> String
  let label: String

  var body: some View {
    GeometryReader { geometry in
      let layout = DisplayWallLayout.resolve(
        mode: arrangement,
        aspectRatios: captures.enumerated().map(aspectRatio),
        displayOrigins: captures.compactMap { capture in
          capture.displayID.flatMap { displayOrigins[$0] }
        },
        width: geometry.size.width,
        height: geometry.size.height)
      layoutView(layout)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 24)
            .onEnded { value in
              guard imageScale <= 1.01 else { return }
              let horizontal = value.translation.width
              let vertical = value.translation.height
              guard abs(horizontal) > 70, abs(horizontal) > abs(vertical) * 1.2 else { return }
              onNavigate(horizontal < 0 ? 1 : -1)
            }
        )
    }
  }

  @ViewBuilder
  private func layoutView(_ layout: DisplayWallLayout) -> some View {
    switch layout {
    case .sideBySide:
      HStack(spacing: 12) { cards }
    case .stacked:
      VStack(spacing: 12) { cards }
    }
  }

  @ViewBuilder private var cards: some View {
    ForEach(Array(captures.enumerated()), id: \.element.id) { item in
      card(item.element, index: item.offset)
    }
  }

  private func aspectRatio(_ item: (offset: Int, element: Capture)) -> Double {
    let image = decodedScreens[item.element.url] ?? (item.offset == 0 ? decoded : nil)
    guard let image, image.originalHeight > 0 else { return 16.0 / 9.0 }
    return Double(image.originalWidth) / Double(image.originalHeight)
  }

  @ViewBuilder private func card(_ capture: Capture, index: Int) -> some View {
    VStack(spacing: 8) {
      if captures.count > 1 {
        Text(displayName(capture.displayID ?? "legacy"))
          .recallFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let image = decodedScreens[capture.url] ?? (index == 0 ? decoded : nil) {
        ScreenshotViewport(
          decoded: image,
          zoomed: zoomed,
          scale: imageScale,
          onScaleChanged: onScaleChanged,
          loading: decodedScreens[capture.url] == nil,
          label: label,
          identifier: index == 0 ? "image.current" : "image.screen.\(index)")
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }
}
