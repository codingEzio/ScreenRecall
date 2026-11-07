import AppKit
import CoreText
import CryptoKit
import Foundation
import Testing

@testable import ScreenRecall

struct CompactFontTests {
  @Test
  func sourceFontHasTheShippedContractAndAllProductTextGlyphs() throws {
    let fontURL = sourceFontURL()
    #expect(FileManager.default.fileExists(atPath: fontURL.path))
    #expect(
      try sha256(at: fontURL) == "74adf4919c690e61aa7bdd4c369a6f5c84029413a7da5e85d687ea7fa6b502e7")

    let descriptor = try #require(descriptor(at: fontURL))
    let font = CTFontCreateWithFontDescriptor(descriptor, 17, nil)
    #expect(CTFontCopyFamilyName(font) as String == CompactFont.familyName)
    #expect(CTFontCopyPostScriptName(font) as String == CompactFont.postScriptName)
    #expect(missingGlyphs(in: "Credential ScreenRecall 中文螢幕設定", font: font).isEmpty)
  }

  @Test
  func bundledResourceLookupUsesFontsDirectory() {
    #expect(CompactFont.resourceFileName == "DeparturePixelZhCompact-Regular.ttf")
    #expect(CompactFont.postScriptName == "DeparturePixelZhCompact-Regular")
  }

  @Test
  func registeredNameResolvesToTheSameSourceURL() throws {
    let fontURL = sourceFontURL().resolvingSymlinksInPath()
    #expect(CompactFont.registerFont(at: fontURL))
    #expect(CompactFont.providerURL(for: CompactFont.postScriptName) == fontURL)
  }

  @Test
  func semanticSizesUseTheCurrentMacOSTextStyles() {
    #expect(
      CompactFont.nativePointSize(for: .body) == NSFont.preferredFont(forTextStyle: .body).pointSize
    )
    #expect(
      CompactFont.nativePointSize(for: .title2)
        == NSFont.preferredFont(forTextStyle: .title2).pointSize)
    #expect(
      CompactFont.nativePointSize(for: .caption)
        == NSFont.preferredFont(forTextStyle: .caption1).pointSize)
  }

  private func sourceFontURL() -> URL {
    if let explicit = ProcessInfo.processInfo.environment["DEPARTURE_PIXEL_ZH_BUILD_ROOT"] {
      return URL(fileURLWithPath: explicit)
        .appendingPathComponent("DeparturePixelZhCompact-Regular.ttf")
    }
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundled = root.appendingPathComponent(
      "Dependencies/DeparturePixelZh/DeparturePixelZhCompact-Regular.ttf")
    if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
    return URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("X-DeparturePixelZh/Build/DeparturePixelZhCompact-Regular.ttf")
  }

  private func descriptor(at url: URL) -> CTFontDescriptor? {
    (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
  }

  private func missingGlyphs(in text: String, font: CTFont) -> [UnicodeScalar] {
    text.unicodeScalars.filter { scalar in
      let units = Array(String(scalar).utf16)
      var glyphs = [CGGlyph](repeating: 0, count: units.count)
      let mapped = units.withUnsafeBufferPointer { unitBuffer in
        glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
          guard let unitsBase = unitBuffer.baseAddress,
            let glyphsBase = glyphBuffer.baseAddress
          else { return false }
          return CTFontGetGlyphsForCharacters(font, unitsBase, glyphsBase, units.count)
        }
      }
      return !mapped || glyphs.contains(0)
    }
  }

  private func sha256(at url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }
}
