import Foundation
import Testing

@testable import RecallCore

@Test func faultJournalDeduplicatesTheSameCodeWithinAMinute() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  var now = Date(timeIntervalSince1970: 1_788_674_400)
  let journal = FaultJournal(
    fileURL: root.appending(path: "faults.jsonl"), now: { now })
  journal.record(code: "catalog.sync.failed", detail: "busy")
  journal.record(code: "catalog.sync.failed", detail: "busy again")
  #expect(journal.writtenThisSession == 1)
  #expect(try journal.readLines().count == 1)

  now = now.addingTimeInterval(61)
  journal.record(code: "catalog.sync.failed", detail: "later")
  #expect(journal.writtenThisSession == 2)
  #expect(try journal.readLines().count == 2)
}

@Test func faultJournalSanitizesPathsAndFilenames() {
  let text = FaultJournal.sanitize(
    "cannot open /tmp/screenrecall-fixture/catalog.sqlite for note.webp")
  #expect(!text.contains("/tmp/"))
  #expect(!text.contains("screenrecall-fixture"))
  #expect(!text.contains("catalog.sqlite"))
  #expect(!text.contains("note.webp"))
  #expect(text.contains("<path>"))
  #expect(text.contains("<file>"))
}

@Test func faultJournalStopsAfterAWriteFailureAndDoesNotRetry() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let blocked = root.appending(path: "not-a-directory")
  try Data([1]).write(to: blocked)
  let journal = FaultJournal(fileURL: blocked.appending(path: "faults.jsonl"))
  journal.record(code: "catalog.open.failed", detail: "first")
  #expect(journal.disabled)
  #expect(journal.writtenThisSession == 0)
  journal.record(code: "catalog.open.failed", detail: "second")
  journal.record(code: "annotation.save.failed", detail: "third")
  #expect(journal.disabled)
  #expect(journal.writtenThisSession == 0)
  #expect(!FileManager.default.fileExists(atPath: blocked.appending(path: "faults.jsonl").path))
}

@Test func faultJournalCompactsOnceThenDisablesInsteadOfGrowingForever() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  var now = Date(timeIntervalSince1970: 1_788_674_400)
  let journal = FaultJournal(
    fileURL: root.appending(path: "faults.jsonl"),
    now: { now },
    maxFileBytes: 160,
    maxSessionRecords: 40)
  let detail = String(repeating: "x", count: 80)
  for index in 0..<12 {
    now = now.addingTimeInterval(61)
    journal.record(code: "code.\(index)", detail: detail)
  }
  let file = root.appending(path: "faults.jsonl")
  let size =
    ((try FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.intValue
    ?? 0
  #expect(journal.disabled)
  #expect(size <= 160)
  let written = journal.writtenThisSession
  journal.record(code: "after.disable", detail: detail)
  #expect(journal.writtenThisSession == written)
  let laterSize =
    ((try FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.intValue
    ?? 0
  #expect(laterSize == size)
}

@Test func faultJournalHonorsASessionCap() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  var now = Date(timeIntervalSince1970: 1_788_674_400)
  let journal = FaultJournal(
    fileURL: root.appending(path: "faults.jsonl"),
    now: { now }, maxSessionRecords: 2)
  journal.record(code: "a")
  now = now.addingTimeInterval(61)
  journal.record(code: "b")
  now = now.addingTimeInterval(61)
  journal.record(code: "c")
  #expect(journal.writtenThisSession == 2)
  #expect(try journal.readLines().count == 2)
  #expect(!journal.disabled)
}
