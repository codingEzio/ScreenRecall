import Foundation

/// Bounded, privacy-safe fault records for later diagnosis.
///
/// Writing never retries after a filesystem failure, and a full file is compacted
/// at most once per process. The journal never logs its own write failures.
public final class FaultJournal: @unchecked Sendable {
  public static let maxFileBytes = 256 * 1024
  public static let maxSessionRecords = 80
  public static let maxDetailCharacters = 180
  public static let dedupInterval: TimeInterval = 60

  public private(set) var disabled = false
  public private(set) var writtenThisSession = 0

  private let fileURL: URL
  private let fileManager: FileManager
  private let now: () -> Date
  private let maxFileBytes: Int
  private let maxSessionRecords: Int
  private let lock = NSLock()
  private var lastCode: String?
  private var lastWrittenAt: TimeInterval = 0
  private var compactedThisProcess = false

  public init(
    fileURL: URL,
    fileManager: FileManager = .default,
    now: @escaping () -> Date = Date.init,
    maxFileBytes: Int = FaultJournal.maxFileBytes,
    maxSessionRecords: Int = FaultJournal.maxSessionRecords
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    self.now = now
    self.maxFileBytes = max(128, maxFileBytes)
    self.maxSessionRecords = max(1, maxSessionRecords)
  }

  public func record(code: String, detail: String = "") {
    lock.lock()
    defer { lock.unlock() }
    guard !disabled, writtenThisSession < maxSessionRecords else { return }
    let trimmedCode = String(code.prefix(80)).replacingOccurrences(of: "\n", with: ".")
    guard !trimmedCode.isEmpty else { return }
    let instant = now().timeIntervalSince1970
    if trimmedCode == lastCode, instant - lastWrittenAt < Self.dedupInterval { return }

    let line =
      #"{"at":\#(Int(instant)),"code":"\#(Self.jsonEscape(trimmedCode))","detail":"\#(Self.jsonEscape(Self.sanitize(detail)))"}"#
      + "\n"
    let payload = Data(line.utf8)
    do {
      try append(payload)
      lastCode = trimmedCode
      lastWrittenAt = instant
      writtenThisSession += 1
    } catch {
      disabled = true
    }
  }

  public func readLines() throws -> [String] {
    lock.lock()
    defer { lock.unlock() }
    guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
    let text = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }

  public func recentCodes(limit: Int = 12) -> [String] {
    let lines = (try? readLines()) ?? []
    return Array(
      lines.suffix(limit).compactMap { line -> String? in
        guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let code = object["code"] as? String
        else { return nil }
        return code
      })
  }

  public static func sanitize(_ raw: String) -> String {
    var text = raw
    text = text.replacingOccurrences(
      of: #"(?i)(/Users/|/Volumes/|/private/|/tmp/)[^\s\"']+"#,
      with: "<path>",
      options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"(?i)\S+\.(webp|jpeg|jpg|png|heic|sqlite|jsonl|json)"#,
      with: "<file>",
      options: .regularExpression)
    text = text.replacingOccurrences(of: "\n", with: " ")
    if text.count > maxDetailCharacters {
      text = String(text.prefix(maxDetailCharacters))
    }
    return text
  }

  private func append(_ payload: Data) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
    if !fileManager.fileExists(atPath: fileURL.path) {
      fileManager.createFile(
        atPath: fileURL.path, contents: nil,
        attributes: [
          .posixPermissions: 0o600
        ])
    }
    let current =
      (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
      .intValue ?? 0
    if current + payload.count > maxFileBytes {
      guard !compactedThisProcess else { throw POSIXError(.ENOSPC) }
      compactedThisProcess = true
      try compact(adding: payload.count)
      let after =
        (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
        .intValue ?? 0
      if after + payload.count > maxFileBytes { throw POSIXError(.ENOSPC) }
    }
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: payload)
  }

  private func compact(adding incoming: Int) throws {
    let data = try Data(contentsOf: fileURL)
    let budget = max(0, maxFileBytes - incoming - 1)
    let keep = data.count <= budget ? data : Data(data.suffix(budget))
    let cut = keep.firstIndex(of: 0x0A).map { keep.index(after: $0) } ?? keep.startIndex
    let trimmed = Data(keep[cut...])
    try trimmed.write(to: fileURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private static func jsonEscape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
