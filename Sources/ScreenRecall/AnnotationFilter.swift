import Foundation

enum AnnotationFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case marked
  case notes

  var id: Self { self }

  var localizationKey: String {
    switch self {
    case .all: "全部"
    case .marked: "標記"
    case .notes: "有筆記"
    }
  }
}
