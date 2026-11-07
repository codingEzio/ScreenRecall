import SwiftUI

/// UI text uses system sans; timestamps and technical values use system mono.
/// The bundled compact face remains a persisted, app-wide option.
enum RecallTypography: String, Codable, CaseIterable {
  case system
  case compact

  var localizationKey: String {
    switch self {
    case .system: "系統字體"
    case .compact: "像素字體"
    }
  }

  func font(_ style: Font.TextStyle, weight: Font.Weight = .regular, technical: Bool = false)
    -> Font
  {
    switch self {
    case .system: .system(style, design: technical ? .monospaced : .default).weight(weight)
    case .compact: CompactFont.textFont(style, weight: weight)
    }
  }
}

extension EnvironmentValues {
  @Entry var recallTypography: RecallTypography = .system
  @Entry var recallSettingsTextWidth: CGFloat = 360
  @Entry var recallSettingsControlWidth: CGFloat = 220
  @Entry var recallSettingsPreview = false
}

private struct RecallFont: ViewModifier {
  @Environment(\.recallTypography) private var typography
  let style: Font.TextStyle
  let weight: Font.Weight
  let technical: Bool

  func body(content: Content) -> some View {
    content.font(typography.font(style, weight: weight, technical: technical))
  }
}

extension View {
  func recallFont(
    _ style: Font.TextStyle, weight: Font.Weight = .regular, technical: Bool = false
  ) -> some View {
    modifier(RecallFont(style: style, weight: weight, technical: technical))
  }
}

/// Visual identity is independent of font and macOS color appearance.
enum RecallVisualTheme: String, Codable, CaseIterable {
  case monochrome
  case classic

  var localizationKey: String { self == .monochrome ? "單色" : "經典" }
}

struct RecallPalette {
  let theme: RecallVisualTheme
  let dark: Bool

  private func color(_ light: UInt32, _ dark: UInt32) -> Color {
    let hex = self.dark ? dark : light
    return Color(
      red: Double((hex >> 16) & 255) / 255,
      green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255)
  }

  var canvas: Color {
    theme == .classic ? Color(nsColor: .windowBackgroundColor) : color(0xF2F2F0, 0x181818)
  }
  var surface: Color {
    theme == .classic ? Color(nsColor: .controlBackgroundColor) : color(0xFFFFFF, 0x242424)
  }
  var primary: Color { theme == .classic ? .primary : color(0x1C1C1C, 0xF3F3F0) }
  var secondary: Color { theme == .classic ? .secondary : color(0x626260, 0xA7A7A3) }
  var accent: Color { theme == .classic ? .accentColor : color(0xC92A26, 0xFF625B) }
}

extension EnvironmentValues {
  @Entry var recallVisualTheme: RecallVisualTheme = .monochrome
}

private struct RecallSurface: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let theme: RecallVisualTheme

  func body(content: Content) -> some View {
    let palette = RecallPalette(theme: theme, dark: colorScheme == .dark)
    content
      .environment(\.recallVisualTheme, theme)
      .tint(theme == .monochrome ? palette.secondary : palette.accent)
      .foregroundStyle(palette.primary)
      .background(theme == .monochrome ? palette.canvas : .clear)
  }
}

extension View {
  func recallSurface(_ theme: RecallVisualTheme) -> some View {
    modifier(RecallSurface(theme: theme))
  }
}

struct RecallDotMark: View {
  let active: Bool
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
    Canvas { context, size in
      let color = RecallPalette(theme: .monochrome, dark: colorScheme == .dark)
      for y in 0..<5 {
        for x in 0..<5
        where (x == 0 || x == 4 || y == 0 || y == 4) && !((x == 0 || x == 4) && (y == 0 || y == 4))
        {
          let rect = CGRect(x: 2 + x * 3, y: 2 + y * 3, width: 2, height: 2)
          context.fill(Path(ellipseIn: rect), with: .color(active ? color.accent : color.secondary))
        }
      }
      if active {
        context.fill(
          Path(ellipseIn: CGRect(x: 7, y: 7, width: 4, height: 4)), with: .color(color.accent))
      }
    }.accessibilityHidden(true)
  }
}

private struct RecallSettingsNote: ViewModifier {
  @Environment(\.recallSettingsTextWidth) private var width
  func body(content: Content) -> some View {
    content.frame(width: width, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}

extension View {
  func recallSettingsNote() -> some View { modifier(RecallSettingsNote()) }
}

/// Pixel identity is independent of the readable body typography preference.
struct RecallSettingsHeading: View {
  let text: String
  var topSpacing: CGFloat = 10
  @Environment(\.recallVisualTheme) private var theme
  var body: some View {
    Text(text)
      .font(theme == .monochrome ? CompactFont.textFont(.headline) : .system(.headline))
      .padding(.top, topSpacing)
      .accessibilityAddTraits(.isHeader)
  }
}

/// Native control layout inside the same quiet section surface as VoxTypeMac.
struct RecallSettingsSection<Content: View>: View {
  let title: String
  var nativeForm = true
  @ViewBuilder var content: () -> Content
  @Environment(\.recallVisualTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  private var palette: RecallPalette {
    RecallPalette(theme: theme, dark: colorScheme == .dark)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        if theme == .monochrome {
          Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3) { row in
              GridRow {
                ForEach(0..<3) { column in
                  Circle().fill(palette.primary.opacity(row == 1 && column == 1 ? 1 : 0.5))
                    .frame(width: 3, height: 3)
                }
              }
            }
          }.frame(width: 15, height: 15).fixedSize().accessibilityHidden(true)
        }
        Text(title)
          .font(
            theme == .monochrome
              ? .custom(CompactFont.postScriptName, size: 15) : .system(size: 15, weight: .semibold)
          )
          .accessibilityAddTraits(.isHeader)
      }
      if theme == .monochrome {
        Rectangle().fill(palette.secondary.opacity(0.22)).frame(height: 1)
      }
      if nativeForm {
        Form { content() }
          .formStyle(.columns)
          .scrollContentBackground(.hidden)
      } else {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) { content() }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .padding(10)
    .background(
      theme == .monochrome ? palette.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
  }
}

struct RecallSettingsRow<Content: View>: View {
  let label: String
  @ViewBuilder var content: () -> Content
  @Environment(\.recallSettingsControlWidth) private var width
  var body: some View {
    GridRow(alignment: .center) {
      Text(label)
        .frame(width: 108, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) { content() }
        .labelsHidden()
        .frame(width: width, alignment: .leading)
    }
  }
}
