public enum RecordingCaptureMode: String, Codable, CaseIterable, Sendable {
  case everyInterval
  case skipUnchanged
}

/// Decides whether a complete multi-display cycle represents a new moment.
/// The decision is all-or-nothing so a changed display never gets separated from its peers.
public enum RecordingCyclePolicy {
  public static func shouldPersist(
    mode: RecordingCaptureMode,
    signatures: [String: UInt64],
    previousSignatures: [String: UInt64]
  ) -> Bool {
    guard mode == .skipUnchanged else { return true }
    guard !signatures.isEmpty, signatures.count == previousSignatures.count,
      signatures.keys.allSatisfy({ previousSignatures[$0] != nil })
    else { return true }
    return signatures.contains { previousSignatures[$0.key] != $0.value }
  }
}

/// A bounded, temporary high-frequency recording plan. It never becomes a persisted
/// `RecordingOptions` value; the caller applies it only for the current session.
public struct RecordingBurstPlan: Equatable, Sendable {
  public static let intervalChoices = [1, 3, 5, 10, 15, 30]
  public static let durationChoicesMinutes = [5, 10, 30]

  public let intervalSeconds: Int
  public let durationMinutes: Int

  public init?(intervalSeconds: Int, durationMinutes: Int) {
    guard Self.intervalChoices.contains(intervalSeconds),
      Self.durationChoicesMinutes.contains(durationMinutes)
    else { return nil }
    self.intervalSeconds = intervalSeconds
    self.durationMinutes = durationMinutes
  }

  public var cycleCount: Int {
    (durationMinutes * 60 + intervalSeconds - 1) / intervalSeconds
  }

  public func options(from base: RecordingOptions) -> RecordingOptions {
    var result = base
    result.intervalSeconds = intervalSeconds
    result.mode = .everyInterval
    return result
  }
}

public enum RecordingCadence {
  /// Slow encodes skip an interval instead of building an unbounded catch-up queue.
  public static func delay(intervalSeconds: Int, elapsedSeconds: Double) -> Double {
    let interval = Double(intervalSeconds)
    return elapsedSeconds < interval ? interval - elapsedSeconds : interval
  }

  /// A transient failure must not leave a daily recording idle for its full capture interval.
  /// Use the already supported one-minute daily minimum as the retry ceiling.
  public static func retryDelay(intervalSeconds: Int, elapsedSeconds: Double) -> Double {
    delay(
      intervalSeconds: min(intervalSeconds, RecordingOptions.minimumDailyIntervalSeconds),
      elapsedSeconds: elapsedSeconds)
  }
}
