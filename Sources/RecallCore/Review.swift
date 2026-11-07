import Foundation

/// A review rate controls how long each captured moment remains visible.
/// It intentionally does not pretend that sparse historical captures are video.
public enum PlaybackRate: String, CaseIterable, Codable, Sendable, Identifiable {
  case half = "0.5x"
  case one = "1x"
  case two = "2x"
  case four = "4x"

  public var id: Self { self }

  public var delayMilliseconds: Int {
    switch self {
    case .half: 800
    case .one: 400
    case .two: 200
    case .four: 100
    }
  }
}

public enum PlaybackSchedule {
  public static func nextIndex(current: Int, count: Int, looping: Bool) -> Int? {
    guard count > 0, current >= 0, current < count else { return nil }
    if current + 1 < count { return current + 1 }
    return looping ? 0 : nil
  }

  public static func delayMilliseconds(for rate: PlaybackRate) -> Int {
    rate.delayMilliseconds
  }
}
