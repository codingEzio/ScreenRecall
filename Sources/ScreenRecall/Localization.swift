import Foundation

enum AppLanguage: String, Codable, CaseIterable, Sendable {
  case system
  case english
  case traditionalChinese
  case simplifiedChinese
  case korean
  case japanese
  case spanish
  case russian
  case ukrainian

  var locale: Locale {
    self == .system ? .current : Locale(identifier: localizationCode)
  }

  /// The timeline always uses an unambiguous 00–23 clock, preserving locale digits.
  var timelineLocale: Locale {
    var components = Locale.Components(identifier: locale.identifier)
    components.hourCycle = .zeroToTwentyThree
    return Locale(components: components)
  }

  func minutes(_ count: Int) -> String {
    Duration.seconds(count * 60).formatted(.units(allowed: [.minutes], width: .wide).locale(locale))
  }

  func seconds(_ count: Int) -> String {
    Duration.seconds(count).formatted(.units(allowed: [.seconds], width: .wide).locale(locale))
  }

  func bytes(_ count: Int64) -> String {
    count.formatted(.byteCount(style: .file).locale(locale))
  }

  var localizedName: String {
    switch self {
    case .system: "跟隨系統"
    case .english: "English"
    case .traditionalChinese: "繁體中文"
    case .simplifiedChinese: "简体中文"
    case .korean: "한국어"
    case .japanese: "日本語"
    case .spanish: "Español"
    case .russian: "Русский"
    case .ukrainian: "Українська"
    }
  }

  private static let localizedBundles: [String: Bundle] = {
    var bundles: [String: Bundle] = [:]
    for language in allCases where language != .system {
      let code = language.localizationCode
      if let url = Bundle.main.url(forResource: code, withExtension: "lproj"),
        let bundle = Bundle(url: url)
      {
        bundles[code] = bundle
      }
    }
    return bundles
  }()

  func text(_ key: String) -> String {
    Self.localizedBundles[localizationCode]?.localizedString(forKey: key, value: nil, table: nil)
      ?? key
  }

  var localizationCode: String {
    switch self {
    case .system: Self.preferredCode(for: Locale.preferredLanguages)
    case .english: "en"
    case .traditionalChinese: "zh-Hant"
    case .simplifiedChinese: "zh-Hans"
    case .korean: "ko"
    case .japanese: "ja"
    case .spanish: "es"
    case .russian: "ru"
    case .ukrainian: "uk"
    }
  }

  static func preferredCode(for languages: [String]) -> String {
    for language in languages {
      let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
      if code.hasPrefix("zh") {
        return code.contains("hant") || code.hasPrefix("zh-tw")
          || code.hasPrefix("zh-hk") || code.hasPrefix("zh-mo") ? "zh-Hant" : "zh-Hans"
      }
      let base = String(code.split(separator: "-").first ?? "")
      if ["en", "ko", "ja", "es", "ru", "uk"].contains(base) { return base }
    }
    return "en"
  }
}
