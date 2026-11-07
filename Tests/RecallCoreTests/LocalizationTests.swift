import Foundation
import Testing

@testable import ScreenRecall

@Test func allWorkspaceLanguagesCanBeSaved() throws {
  #expect(AppLanguage.allCases.count == 9)
  for language in [
    "english", "traditionalChinese", "simplifiedChinese", "korean", "japanese", "spanish",
    "russian", "ukrainian",
  ] {
    let data = Data("{\"source\":\"/fixture\",\"language\":\"\(language)\"}".utf8)
    let preferences = try JSONDecoder().decode(Preferences.self, from: data)
    let saved = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
    #expect(saved["language"] as? String == language)
  }
}

@MainActor @Test func morningAndAfternoonTimestampsRemainDistinct() {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: "/fixture")
  model.preferences.language = .english
  let calendar = Calendar.current
  let morning = calendar.date(
    from: DateComponents(year: 2026, month: 9, day: 12, hour: 2, minute: 15))!
  let afternoon = calendar.date(
    from: DateComponents(year: 2026, month: 9, day: 12, hour: 14, minute: 15))!
  #expect(
    morning.formatted(model.clockStyle(seconds: true))
      != afternoon.formatted(model.clockStyle(seconds: true)))
}

@Test func systemLanguageResolvesChineseScriptsAndSupportedRegionalVariants() {
  #expect(AppLanguage.preferredCode(for: ["zh-TW"]) == "zh-Hant")
  #expect(AppLanguage.preferredCode(for: ["zh-Hant-HK"]) == "zh-Hant")
  #expect(AppLanguage.preferredCode(for: ["zh-CN"]) == "zh-Hans")
  #expect(AppLanguage.preferredCode(for: ["zh-SG"]) == "zh-Hans")
  #expect(AppLanguage.preferredCode(for: ["es-MX"]) == "es")
  #expect(AppLanguage.preferredCode(for: ["fr-FR", "uk-UA"]) == "uk")
  #expect(AppLanguage.preferredCode(for: ["fr-FR"]) == "en")
}

@Test func everyLanguageShipsTheSameKeysAndInterpolationSlots() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(
      path: "Resources/Localization")
  func strings(_ code: String) throws -> [String: String] {
    let data = try Data(contentsOf: root.appending(path: "\(code).lproj/Localizable.strings"))
    return try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
  }
  let source = try strings("en")
  let placeholder = try NSRegularExpression(pattern: "%[0-9$]*[df@]")
  for language in AppLanguage.allCases where language != .system {
    let localized = try strings(language.localizationCode)
    #expect(Set(localized.keys) == Set(source.keys))
    for (key, value) in source {
      let translation = try #require(localized[key])
      #expect(!translation.isEmpty)
      func slots(_ string: String) -> [String] {
        placeholder.matches(in: string, range: NSRange(string.startIndex..., in: string)).map {
          (string as NSString).substring(with: $0.range)
        }
      }
      #expect(slots(value) == slots(translation))
    }
  }
}

@Test func intervalLabelsUseNativePluralRules() {
  #expect(AppLanguage.english.minutes(1).contains("minute"))
  #expect(!AppLanguage.english.minutes(1).contains("minutes"))
  #expect(AppLanguage.english.minutes(2).contains("minutes"))
  #expect(AppLanguage.spanish.minutes(1).contains("minuto"))
  #expect(AppLanguage.spanish.minutes(2).contains("minutos"))
  #expect(AppLanguage.russian.minutes(1).contains("минута"))
  #expect(AppLanguage.russian.minutes(2).contains("минуты"))
}
