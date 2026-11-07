import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
import UniformTypeIdentifiers

@testable import RecallCore

@Test func migrationAuditKeepsImagesWithoutOCRAndReportsBrokenLinks() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appending(path: "source")
  let images = source.appending(path: "screenshots/2026/05/16/15")
  try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
  let context = try #require(
    CGContext(
      data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  let image = try #require(context.makeImage())
  for name in ["1778915627.jpeg", "1778915747.jpeg"] {
    let writer = try #require(
      CGImageDestinationCreateWithURL(
        images.appending(path: name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, nil)
    #expect(CGImageDestinationFinalize(writer))
  }
  try Data("broken".utf8).write(to: images.appending(path: "bad.jpeg"))
  try FileManager.default.createSymbolicLink(
    at: images.appending(path: "linked.jpeg"),
    withDestinationURL: images.appending(path: "1778915627.jpeg"))
  try auditFixtureDatabase(
    source.appending(path: "notes.sqlite"),
    sql: "CREATE TABLE notes(id INTEGER PRIMARY KEY, timestamp INTEGER, note TEXT);")
  try auditFixtureDatabase(
    source.appending(path: "usage.sqlite"),
    sql: """
      CREATE TABLE usage(id INTEGER PRIMARY KEY, timestamp TEXT, identifier TEXT, name TEXT);
      INSERT INTO usage VALUES(1,'1778915627','test.app','Test');
      INSERT INTO usage VALUES(2,'1778915627','test.other','Other');
      """)
  try auditFixtureDatabase(
    source.appending(path: "text.sqlite"),
    sql: """
      CREATE TABLE ocrresults(id INTEGER PRIMARY KEY, imagetimestamp TEXT, imagepath TEXT, imagedate TEXT, imagetext TEXT);
      INSERT INTO ocrresults VALUES(1,'1778915627','2026/05/16/15/1778915627.jpeg','2026/05/16/15','DO_NOT_COPY_OCR');
      INSERT INTO ocrresults VALUES(2,'1778915800','../../escape.jpeg','2026/05/16/15','DO_NOT_COPY_OCR');
      """)
  let before = try Data(contentsOf: source.appending(path: "text.sqlite"))
  let output = root.appending(path: "audit")
  let result = try MigrationAudit.run(source: source, output: output, hashImages: true)
  #expect(result.imageCount == 3)
  #expect(result.invalidImageCount == 1)
  #expect(result.skippedSymlinkCount == 1)
  #expect(result.imagesWithoutOCR == 1)
  #expect(result.ocrWithoutImage == 1)
  #expect(result.usageAmbiguousTimestamps == 1)
  #expect(result.hashedImageCount == 3)
  let samples = try MigrationAudit.sampleCompression(
    source: source, manifest: output.appending(path: "manifest.sqlite"),
    output: root.appending(path: "samples"))
  #expect(samples.count == 2)
  #expect(samples.allSatisfy { Set($0.encodedBytes.keys) == ["30", "50", "70"] })
  #expect(samples.allSatisfy { $0.width == 8 && $0.height == 4 })
  #expect(try Data(contentsOf: source.appending(path: "text.sqlite")) == before)
  let manifest = try Data(contentsOf: output.appending(path: "manifest.sqlite"))
  #expect(!String(decoding: manifest, as: UTF8.self).contains("DO_NOT_COPY_OCR"))
  #expect(throws: (any Error).self) {
    try MigrationAudit.run(source: source, output: output, hashImages: false)
  }
  #expect(throws: (any Error).self) {
    try MigrationAudit.run(
      source: source, output: source.appending(path: "audit"), hashImages: false)
  }
}

private func auditFixtureDatabase(_ url: URL, sql: String) throws {
  var database: OpaquePointer?
  #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
  defer { sqlite3_close(database) }
  #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
}

@Test func migrationAuditCrossesTenThousandRowBatchWithoutDroppingImages() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appending(path: "source")
  let directory = source.appending(path: "screenshots/2026/05/16/15")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  // Invalid image payloads are still inventoried, never silently excluded.
  for index in 0..<10_001 {
    try Data([1]).write(to: directory.appending(path: "\(1_778_915_627 + index).jpeg"))
  }
  let output = root.appending(path: "audit")
  let result = try MigrationAudit.run(source: source, output: output, hashImages: false)
  #expect(result.imageCount == 10_001)
  #expect(result.imageBytes == 10_001)
  #expect(result.invalidImageCount == 10_001)
  #expect(result.hashedImageCount == 0)
  #expect(result.imagesWithoutOCR == 10_001)
  #expect(result.databaseChecks["text.sqlite"] == "missing")
  var database: OpaquePointer?
  #expect(
    sqlite3_open_v2(
      output.appending(path: "manifest.sqlite").path, &database, SQLITE_OPEN_READONLY, nil)
      == SQLITE_OK)
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  #expect(
    sqlite3_prepare_v2(database, "SELECT count(*) FROM images", -1, &statement, nil) == SQLITE_OK)
  defer { sqlite3_finalize(statement) }
  #expect(sqlite3_step(statement) == SQLITE_ROW)
  #expect(sqlite3_column_int64(statement, 0) == 10_001)
}

@Test func migrationAuditRejectsWALBeforeCreatingSourceSidecars() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appending(path: "source")
  try FileManager.default.createDirectory(
    at: source.appending(path: "screenshots"), withIntermediateDirectories: true)
  let database = source.appending(path: "usage.sqlite")
  try auditFixtureDatabase(
    database,
    sql: """
      PRAGMA journal_mode=WAL;
      CREATE TABLE usage(id INTEGER PRIMARY KEY, timestamp TEXT, identifier TEXT, name TEXT);
      """)
  let original = try Data(contentsOf: database)
  let files = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
  #expect(throws: (any Error).self) {
    try MigrationAudit.run(source: source, output: root.appending(path: "audit"), hashImages: false)
  }
  #expect(try Data(contentsOf: database) == original)
  #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() == files)
}
