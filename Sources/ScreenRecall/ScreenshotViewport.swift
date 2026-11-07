import RecallCore
import SwiftUI

enum ScreenshotZoom {
  static func offset(
    keepingFocus focus: CGPoint, in size: CGSize, baseOffset: CGSize, baseScale: CGFloat,
    newScale: CGFloat
  ) -> CGSize {
    guard baseScale > 0, size.width > 0, size.height > 0 else { return baseOffset }
    let factor = newScale / baseScale
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    return CGSize(
      width: (focus.x - center.x) * (1 - factor) + baseOffset.width * factor,
      height: (focus.y - center.y) * (1 - factor) + baseOffset.height * factor)
  }

  static func clamped(
    _ offset: CGSize, scale: CGFloat, fitted: CGSize, view: CGSize
  ) -> CGSize {
    let maxX = max(0, (fitted.width * scale - view.width) / 2)
    let maxY = max(0, (fitted.height * scale - view.height) / 2)
    return CGSize(
      width: min(max(offset.width, -maxX), maxX),
      height: min(max(offset.height, -maxY), maxY))
  }
}

struct ScreenshotViewport: View {
  let decoded: DecodedImage
  let zoomed: Bool
  let scale: CGFloat
  let onScaleChanged: (CGFloat) -> Void
  let loading: Bool
  let label: String
  let identifier: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var offset: CGSize = .zero
  @State private var gestureBaseScale = 1.0
  @State private var gestureBaseOffset: CGSize = .zero
  @State private var magnifying = false
  @State private var panning = false
  var body: some View {
    GeometryReader { geometry in
      let image = decoded.image
      let ratio = CGFloat(image.width) / CGFloat(image.height)
      let fittedWidth = min(geometry.size.width, geometry.size.height * ratio)
      let fitted = CGSize(width: fittedWidth, height: fittedWidth / ratio)
      let effectiveScale = max(1, scale)
      Image(decorative: image, scale: 1).resizable().interpolation(.high)
        .frame(width: fitted.width, height: fitted.height)
        .scaleEffect(effectiveScale)
        .offset(offset)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
        .animation(
          reduceMotion || magnifying || panning ? nil : .smooth(duration: 0.22), value: scale
        )
        .contentShape(Rectangle())
        .gesture(magnify(in: geometry.size, fitted: fitted))
        .simultaneousGesture(pan(in: geometry.size, fitted: fitted, scale: effectiveScale))
        .onChange(of: scale) { _, newScale in
          offset = ScreenshotZoom.clamped(
            newScale <= 1.01 ? .zero : offset, scale: max(1, newScale), fitted: fitted,
            view: geometry.size)
        }
        .onChange(of: geometry.size) { _, size in
          offset = ScreenshotZoom.clamped(offset, scale: effectiveScale, fitted: fitted, view: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(loading ? "loading" : "ready")
        .accessibilityIdentifier(identifier)
        .overlay(alignment: .topTrailing) {
          if loading { ProgressView().controlSize(.small).padding(12).glassEffect() }
        }
    }
  }

  private func magnify(in size: CGSize, fitted: CGSize) -> some Gesture {
    MagnifyGesture()
      .onChanged { value in
        if !magnifying {
          magnifying = true
          gestureBaseScale = scale
          gestureBaseOffset = offset
        }
        let newScale = min(4, max(1, gestureBaseScale * value.magnification))
        onScaleChanged(newScale)
        offset = ScreenshotZoom.clamped(
          ScreenshotZoom.offset(
            keepingFocus: value.startLocation, in: size, baseOffset: gestureBaseOffset,
            baseScale: gestureBaseScale, newScale: newScale),
          scale: newScale, fitted: fitted, view: size)
      }
      .onEnded { value in
        let newScale = min(4, max(1, gestureBaseScale * value.magnification))
        onScaleChanged(newScale)
        offset = ScreenshotZoom.clamped(
          ScreenshotZoom.offset(
            keepingFocus: value.startLocation, in: size, baseOffset: gestureBaseOffset,
            baseScale: gestureBaseScale, newScale: newScale),
          scale: newScale, fitted: fitted, view: size)
        magnifying = false
        gestureBaseOffset = offset
      }
  }

  private func pan(in size: CGSize, fitted: CGSize, scale: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        guard scale > 1.01, !magnifying else { return }
        if !panning {
          panning = true
          gestureBaseOffset = offset
        }
        offset = ScreenshotZoom.clamped(
          CGSize(
            width: gestureBaseOffset.width + value.translation.width,
            height: gestureBaseOffset.height + value.translation.height),
          scale: scale, fitted: fitted, view: size)
      }
      .onEnded { _ in
        panning = false
        gestureBaseOffset = offset
      }
  }
}
