import Foundation
import Testing

@testable import ScreenRecall

@Test func typographyChoiceSurvivesPreferencesRoundTrip() throws {
  for choice in ["system", "compact"] {
    let input = Data("{\"source\":\"/fixture\",\"typography\":\"\(choice)\"}".utf8)
    let preferences = try JSONDecoder().decode(Preferences.self, from: input)
    let output = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
    #expect(output["typography"] as? String == choice)
  }
}

@Test func absentOrUnknownTypographyUsesNativeSystemDefault() throws {
  for json in ["{\"source\":\"/fixture\"}", "{\"source\":\"/fixture\",\"typography\":\"unknown\"}"]
  {
    let preferences = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
    let output = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
    #expect(output["typography"] as? String == "system")
  }
}

@MainActor @Test func typographyChoicePersistsToDiskAndReloads() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let config = root.appending(path: "preferences.json")
  let model = RecallModel(configURL: config, sourceOverride: root.path)
  for choice in RecallTypography.allCases {
    model.preferences.typography = choice
    model.savePreferences()
    #expect(model.notice == nil)
    let saved = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: config))
    #expect(saved.typography == choice)
    #expect(RecallModel(configURL: config).preferences.typography == choice)
  }
}
