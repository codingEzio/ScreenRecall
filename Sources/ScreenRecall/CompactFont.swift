import AppKit
import CoreText
import Foundation
import SwiftUI

enum CompactFont {
  static let resourceFileName = "DeparturePixelZhCompact-Regular.ttf"
  static let postScriptName = "DeparturePixelZhCompact-Regular"
  static let familyName = "DeparturePixelZh Compact"

  static var body: Font { textFont(.body) }
  static var callout: Font { textFont(.callout) }
  static var caption: Font { textFont(.caption) }
  static var caption2: Font { textFont(.caption2) }
  static var headline: Font { textFont(.headline) }
  static var subheadline: Font { textFont(.subheadline) }
  static var title2: Font { textFont(.title2) }

  static func textFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
    Font.custom(postScriptName, size: nativePointSize(for: style), relativeTo: style).weight(weight)
  }

  static func bundledFontURL(in bundle: Bundle = .main) -> URL? {
    let baseName = (resourceFileName as NSString).deletingPathExtension
    let extensionName = (resourceFileName as NSString).pathExtension
    let candidates = [
      bundle.url(forResource: baseName, withExtension: extensionName, subdirectory: "Fonts"),
      bundle.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
        .appendingPathComponent(resourceFileName),
    ]
    return candidates.compactMap { $0 }.first {
      FileManager.default.fileExists(atPath: $0.path)
    }
  }

  @discardableResult
  static func registerBundledFont(in bundle: Bundle = .main) -> Bool {
    guard let url = bundledFontURL(in: bundle) else { return false }
    guard registerFont(at: url),
      let providerURL = providerURL(for: postScriptName),
      providerURL == url.resolvingSymlinksInPath()
    else {
      return false
    }
    let font = CTFontCreateWithName(postScriptName as CFString, 17, nil)
    return CTFontCopyFamilyName(font) as String == familyName
  }

  @discardableResult
  static func registerFont(at url: URL) -> Bool {
    var error: Unmanaged<CFError>?
    if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
      return true
    }
    // CoreText reports an exact duplicate as AlreadyRegistered. Every other
    // error means that this process must not claim the bundled font is ready.
    guard let error else { return false }
    return CFErrorGetCode(error.takeUnretainedValue()) == 105
  }

  static func providerURL(for postScriptName: String) -> URL? {
    let font = CTFontCreateWithName(postScriptName as CFString, 17, nil)
    return (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.resolvingSymlinksInPath()
  }

  static func nativePointSize(for style: Font.TextStyle) -> CGFloat {
    NSFont.preferredFont(forTextStyle: appKitTextStyle(for: style)).pointSize
  }

  private static func appKitTextStyle(for style: Font.TextStyle) -> NSFont.TextStyle {
    switch style {
    case .largeTitle: .largeTitle
    case .title: .title1
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .subheadline: .subheadline
    case .body: .body
    case .callout: .callout
    case .footnote: .footnote
    case .caption: .caption1
    case .caption2: .caption2
    @unknown default: .body
    }
  }
}
