import AppKit
import CoreText
import CryptoKit
import Foundation

let expectedFileName = "DeparturePixelZhCompact-Regular.ttf"
let expectedPostScriptName = "DeparturePixelZhCompact-Regular"
let expectedFamilyName = "DeparturePixelZh Compact"
let expectedSHA256 = "74adf4919c690e61aa7bdd4c369a6f5c84029413a7da5e85d687ea7fa6b502e7"
let probeText = "Credential ScreenRecall 中文螢幕設定"
let expectedLicenseFileCount = 25

guard CommandLine.arguments.count >= 2 else {
  print("usage: verify_compact_font_bundle.swift APP_BUNDLE [REPORT]")
  exit(2)
}

let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
let fontURL = resourcesURL.appendingPathComponent("Fonts", isDirectory: true)
  .appendingPathComponent(expectedFileName)
let licensesURL = resourcesURL.appendingPathComponent("Licenses", isDirectory: true)

func fail(_ message: String) -> Never {
  print("compact font bundle verification failed: \(message)")
  exit(1)
}

guard FileManager.default.fileExists(atPath: fontURL.path) else { fail("missing font") }
for fileName in ["OFL.txt", "NOTICE.md", "provenance.json"] {
  guard FileManager.default.fileExists(atPath: resourcesURL.appendingPathComponent(fileName).path)
  else { fail("missing resource \(fileName)") }
}

let digest = SHA256.hash(data: (try? Data(contentsOf: fontURL)) ?? Data())
let sha256 = digest.map { String(format: "%02x", $0) }.joined()
guard sha256 == expectedSHA256 else { fail("font SHA-256 \(sha256)") }

guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL)
  as? [CTFontDescriptor], let descriptor = descriptors.first else {
  fail("CoreText could not read the font URL")
}
let font = CTFontCreateWithFontDescriptor(descriptor, 17, nil)
guard CTFontCopyFamilyName(font) as String == expectedFamilyName else { fail("family name") }
guard CTFontCopyPostScriptName(font) as String == expectedPostScriptName else {
  fail("PostScript name")
}

func missingGlyphs(in text: String, font: CTFont) -> [String] {
  text.unicodeScalars.compactMap { scalar in
    let units = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    let mapped = units.withUnsafeBufferPointer { unitBuffer in
      glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
        guard let unitsBase = unitBuffer.baseAddress,
          let glyphsBase = glyphBuffer.baseAddress else { return false }
        return CTFontGetGlyphsForCharacters(font, unitsBase, glyphsBase, units.count)
      }
    }
    return !mapped || glyphs.contains(0) ? String(scalar) : nil
  }
}

guard missingGlyphs(in: probeText, font: font).isEmpty else {
  fail("missing glyphs in probe text")
}

var registrationError: Unmanaged<CFError>?
let registered = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registrationError)
let registrationStatus: String
var registrationErrorCode: Int?
if registered {
  registrationStatus = "registered"
} else if let registrationError {
  let code = CFErrorGetCode(registrationError.takeUnretainedValue())
  guard code == 105 else { fail("CoreText registration error code \(code)") }
  registrationStatus = "alreadyRegistered"
  registrationErrorCode = code
} else {
  fail("CoreText registration failed without an error")
}
let namedFont = CTFontCreateWithName(expectedPostScriptName as CFString, 17, nil)
let providerURL = (CTFontCopyAttribute(namedFont, kCTFontURLAttribute) as? URL)?.resolvingSymlinksInPath()
let providerMatchesBundle = providerURL == fontURL.resolvingSymlinksInPath()
guard providerMatchesBundle else { fail("named CoreText font did not resolve to staged URL") }

let line = CTLineCreateWithAttributedString(
  NSAttributedString(string: probeText, attributes: [.font: namedFont]))
let providers = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).map { run in
  let attributes = CTRunGetAttributes(run) as NSDictionary
  return CTFontCopyPostScriptName(attributes[kCTFontAttributeName] as! CTFont) as String
}
guard !providers.isEmpty, providers.allSatisfy({ $0 == expectedPostScriptName }) else {
  fail("unexpected CoreText providers \(providers)")
}

let licenseFiles = (try? FileManager.default.contentsOfDirectory(
  at: licensesURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
let regularLicenseFiles = licenseFiles.filter {
  (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}
guard regularLicenseFiles.count == expectedLicenseFileCount else {
  fail("expected \(expectedLicenseFileCount) license files, found \(regularLicenseFiles.count)")
}

let provenanceData = try! Data(contentsOf: resourcesURL.appendingPathComponent("provenance.json"))
guard let provenance = try? JSONSerialization.jsonObject(with: provenanceData) as? [String: Any],
  provenance["variants"] != nil else { fail("invalid provenance.json") }

let report: [String: Any] = [
  "bundle": bundleURL.path,
  "font": fontURL.path,
  "sha256": sha256,
  "family": CTFontCopyFamilyName(font) as String,
  "postScriptName": CTFontCopyPostScriptName(font) as String,
  "probeText": probeText,
  "missingGlyphs": missingGlyphs(in: probeText, font: font),
  "registeredInProcess": registered,
  "registrationStatus": registrationStatus,
  "providerURL": providerURL?.path ?? "",
  "providerMatchesBundle": providerMatchesBundle,
  "providers": providers,
  "licenseFileCount": regularLicenseFiles.count,
]
var reportWithRegistration = report
if let registrationErrorCode {
  reportWithRegistration["registrationErrorCode"] = registrationErrorCode
}
if let reportPath = CommandLine.arguments.dropFirst(2).first {
  let reportURL = URL(fileURLWithPath: reportPath)
  try FileManager.default.createDirectory(
    at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  let data = try JSONSerialization.data(
    withJSONObject: reportWithRegistration, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: reportURL, options: .atomic)
}
print("compact font bundle verified: \(fontURL.path)")
