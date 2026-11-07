import CryptoKit
import Darwin
import Foundation
import ImageIO
import SQLite3

/// Preparatory evidence only. Does not import into the app or modify source files.
public enum MigrationAudit {
  public struct Summary: Codable, Sendable {
    public var source: String
    public var startedAt: Date
    public var completedAt: Date?
    public var imageCount = 0
    public var imageBytes: Int64 = 0
    public var invalidImageCount = 0
    public var skippedSymlinkCount = 0
    public var hashedImageCount = 0
    public var imagesWithoutOCR = 0
    public var ocrWithoutImage = 0
    public var usageAmbiguousTimestamps = 0
    public var statistics: [String: Int64] = [:]
    public var dimensions: [String: Int64] = [:]
    public var databaseChecks: [String: String] = [:]
    public var limitations = [
      "Live observations, not a frozen cross-database/filesystem snapshot.",
      "ImageIO headers checked; all-image pixel decoding and visual quality are not verified.",
      "No OCR text copied. SHA256 only computed when hashImages is true.",
      "No source files copied, recompressed, deleted, or used to update the app catalog.",
    ]
  }

  public static func run(source: URL, output: URL, hashImages: Bool) throws -> Summary {
    let manager = FileManager.default
    let root = source.standardizedFileURL.resolvingSymlinksInPath()
    let destination = output.standardizedFileURL.resolvingSymlinksInPath()
    guard manager.fileExists(atPath: root.appending(path: "screenshots").path),
      try root.appending(path: "screenshots").resourceValues(forKeys: [.isSymbolicLinkKey])
        .isSymbolicLink != true,
      destination.path != root.path,
      !destination.path.hasPrefix(root.path + "/"),
      !root.path.hasPrefix(destination.path + "/"),
      !manager.fileExists(atPath: destination.path)
    else { throw AuditError.invalidPaths }
    try reserveOutput(destination)
    let manifestURL = destination.appending(path: "manifest.sqlite")
    let manifest = try AuditDatabase(url: manifestURL, readOnly: false)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    try manifest.execute(
      """
      PRAGMA journal_mode=DELETE;
      CREATE TABLE audit_state(state TEXT NOT NULL);
      INSERT INTO audit_state VALUES('incomplete');
      CREATE TABLE images(
        relative_path TEXT PRIMARY KEY, timestamp_text TEXT, byte_count INTEGER NOT NULL,
        width INTEGER, height INTEGER, image_type TEXT, modified_at REAL,
        sha256 TEXT, header_readable INTEGER NOT NULL, changed_during_read INTEGER NOT NULL,
        folder_matches_taipei INTEGER NOT NULL);
      CREATE INDEX images_timestamp ON images(timestamp_text);
      CREATE TABLE ocr_links(id INTEGER, timestamp_text TEXT, relative_path TEXT, day_path TEXT);
      CREATE INDEX ocr_timestamp ON ocr_links(timestamp_text);
      CREATE TABLE usage_links(id INTEGER, timestamp_text TEXT, identifier TEXT, name TEXT);
      CREATE INDEX usage_timestamp ON usage_links(timestamp_text);
      CREATE TABLE issues(relative_path TEXT, reason TEXT);
      CREATE TABLE source_schema(database_name TEXT, name TEXT, sql TEXT);
      """)
    var summary = Summary(source: root.path, startedAt: Date())
    var readers: [(String, AuditDatabase, Int64)] = []
    for (file, table, sql, target) in [
      ("notes.sqlite", "notes", "", ""),
      ("usage.sqlite", "usage", "SELECT id,timestamp,identifier,name FROM usage", "usage_links"),
      (
        "text.sqlite", "ocrresults",
        "SELECT id,imagetimestamp,imagepath,imagedate FROM ocrresults", "ocr_links"
      ),
    ] {
      let url = root.appending(path: file)
      guard manager.fileExists(atPath: url.path) else {
        summary.databaseChecks[file] = "missing"
        continue
      }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw AuditError.invalidPaths
      }
      let reader = try AuditDatabase(url: url, readOnly: true)
      let version = try reader.integer("PRAGMA data_version")
      try reader.execute("BEGIN")
      summary.databaseChecks[file] = try reader.string("PRAGMA quick_check")
      summary.statistics[file + ".rows"] = try reader.integer("SELECT count(*) FROM " + table)
      summary.statistics[file + ".bytes"] = Int64(
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
      try reader.rows("SELECT name,sql FROM sqlite_schema WHERE sql IS NOT NULL") { row in
        try manifest.insert("INSERT INTO source_schema VALUES(?,?,?)", [file, row[0], row[1]])
      }
      if !sql.isEmpty {
        try manifest.execute("BEGIN")
        do {
          try reader.rows(sql) { row in
            try manifest.insert("INSERT INTO " + target + " VALUES(?,?,?,?)", row)
          }
          try manifest.execute("COMMIT")
        } catch {
          try? manifest.execute("ROLLBACK")
          throw error
        }
      }
      readers.append((file, reader, version))
    }

    let screenshotRoot = root.appending(path: "screenshots").resolvingSymlinksInPath()
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
      .contentModificationDateKey,
    ]
    var enumerationFailure: Error?
    guard
      let enumerator = manager.enumerator(
        at: screenshotRoot, includingPropertiesForKeys: Array(keys),
        options: [],
        errorHandler: { _, error in
          enumerationFailure = error
          return false
        })
    else { throw AuditError.invalidPaths }
    let calendar = Calendar(identifier: .gregorian)
    let timeZone = TimeZone(identifier: "Asia/Taipei")!
    var hourPaths: [Int64: String] = [:]
    try manifest.execute("BEGIN")
    for case let url as URL in enumerator {
      try autoreleasepool {
        let values = try url.resourceValues(forKeys: keys)
        let located = url.deletingLastPathComponent().resolvingSymlinksInPath()
          .appending(path: url.lastPathComponent)
        guard located.path.hasPrefix(screenshotRoot.path + "/") else {
          throw AuditError.invalidPaths
        }
        let relative = String(located.path.dropFirst(screenshotRoot.path.count + 1))
        if values.isSymbolicLink == true {
          enumerator.skipDescendants()
          summary.skippedSymlinkCount += 1
          try manifest.insert(
            "INSERT INTO issues VALUES(?,?)", [relative, "symbolic link excluded"])
          return
        }
        guard values.isRegularFile == true else { return }
        guard ["jpg", "jpeg", "png", "heic", "webp"].contains(url.pathExtension.lowercased()) else {
          try manifest.insert(
            "INSERT INTO issues VALUES(?,?)", [relative, "non-image file excluded"])
          return
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let epoch = Int64(stem)
        let timestamp = epoch.flatMap { $0 > 0 ? String($0) : nil }
        if timestamp == nil {
          try manifest.insert(
            "INSERT INTO issues VALUES(?,?)", [relative, "invalid legacy timestamp"])
        }
        let source = CGImageSourceCreateWithURL(
          url as CFURL,
          [
            kCGImageSourceShouldCache: false
          ] as CFDictionary)
        let properties = source.flatMap {
          CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        let width = properties?[kCGImagePropertyPixelWidth] as? Int
        let height = properties?[kCGImagePropertyPixelHeight] as? Int
        let readable = (width ?? 0) > 0 && (height ?? 0) > 0
        let type = source.flatMap { CGImageSourceGetType($0) as String? }
        let digest = hashImages ? try hash(url) : nil
        // Clear URL's cached values before checking a source changed during the read.
        var freshURL = URL(fileURLWithPath: url.path)
        freshURL.removeAllCachedResourceValues()
        let after = try freshURL.resourceValues(forKeys: keys)
        let changed =
          after.fileSize != values.fileSize
          || after.contentModificationDate != values.contentModificationDate
        let byteCount = Int64(values.fileSize ?? 0)
        var folderMatches = false
        if let epoch {
          let hour = epoch / 3600
          if hourPaths[hour] == nil {
            let components = calendar.dateComponents(
              in: timeZone, from: Date(timeIntervalSince1970: Double(epoch)))
            hourPaths[hour] = String(
              format: "%04d/%02d/%02d/%02d",
              components.year!, components.month!, components.day!, components.hour!)
          }
          folderMatches =
            url.deletingLastPathComponent().path
            == screenshotRoot.appending(path: hourPaths[hour]!).path
        }
        try manifest.insert(
          "INSERT INTO images VALUES(?,?,?,?,?,?,?,?,?,?,?)",
          [
            relative, timestamp, String(byteCount), width.map(String.init), height.map(String.init),
            type,
            values.contentModificationDate.map { String($0.timeIntervalSince1970) }, digest,
            readable ? "1" : "0", changed ? "1" : "0", folderMatches ? "1" : "0",
          ])
        summary.imageCount += 1
        summary.imageBytes += byteCount
        summary.invalidImageCount += readable ? 0 : 1
        summary.hashedImageCount += digest == nil ? 0 : 1
        if summary.imageCount % 10_000 == 0 {
          try manifest.execute("COMMIT; BEGIN")
          FileHandle.standardError.write(Data("Audited \(summary.imageCount) images\n".utf8))
        }
      }
    }
    if let enumerationFailure { throw enumerationFailure }
    try manifest.execute("COMMIT")

    summary.imagesWithoutOCR = Int(
      try manifest.integer(
        """
        SELECT count(*) FROM images i WHERE timestamp_text IS NOT NULL AND NOT EXISTS
        (SELECT 1 FROM ocr_links o WHERE o.timestamp_text=i.timestamp_text)
        """))
    summary.ocrWithoutImage = Int(
      try manifest.integer(
        """
        SELECT count(*) FROM ocr_links o WHERE NOT EXISTS
        (SELECT 1 FROM images i WHERE i.timestamp_text=o.timestamp_text)
        """))
    summary.usageAmbiguousTimestamps = Int(
      try manifest.integer(
        """
        SELECT count(*) FROM (SELECT timestamp_text FROM usage_links GROUP BY timestamp_text HAVING count(*)>1)
        """))
    for (name, sql) in [
      ("invalid_timestamps", "SELECT count(*) FROM images WHERE timestamp_text IS NULL"),
      (
        "duplicate_image_timestamps",
        "SELECT count(*) FROM (SELECT timestamp_text FROM images WHERE timestamp_text IS NOT NULL GROUP BY timestamp_text HAVING count(*)>1)"
      ),
      (
        "folder_timezone_mismatches",
        "SELECT count(*) FROM images WHERE timestamp_text IS NOT NULL AND folder_matches_taipei=0"
      ),
      ("changed_images_during_read", "SELECT count(*) FROM images WHERE changed_during_read=1"),
      ("usage_distinct_apps", "SELECT count(DISTINCT identifier) FROM usage_links"),
      (
        "usage_without_image",
        "SELECT count(*) FROM usage_links u WHERE NOT EXISTS (SELECT 1 FROM images i WHERE i.timestamp_text=u.timestamp_text)"
      ),
      (
        "images_without_usage",
        "SELECT count(*) FROM images i WHERE timestamp_text IS NOT NULL AND NOT EXISTS (SELECT 1 FROM usage_links u WHERE u.timestamp_text=i.timestamp_text)"
      ),
      (
        "ocr_path_mismatches",
        "SELECT count(*) FROM ocr_links o JOIN images i ON i.timestamp_text=o.timestamp_text WHERE i.relative_path<>o.relative_path"
      ),
      (
        "duplicate_content_groups",
        "SELECT count(*) FROM (SELECT sha256 FROM images WHERE sha256 IS NOT NULL GROUP BY sha256 HAVING count(*)>1)"
      ),
      ("first_timestamp", "SELECT min(CAST(timestamp_text AS INTEGER)) FROM images"),
      ("last_timestamp", "SELECT max(CAST(timestamp_text AS INTEGER)) FROM images"),
    ] {
      summary.statistics[name] = try manifest.integer(sql)
    }
    try manifest.rows(
      "SELECT width||'x'||height,count(*) FROM images WHERE header_readable=1 GROUP BY width,height"
    ) { row in
      summary.dimensions[row[0]!] = Int64(row[1]!)
    }
    for (name, reader, version) in readers {
      try reader.execute("COMMIT")
      summary.statistics[name + ".changed_during_audit"] =
        try reader.integer("PRAGMA data_version") == version ? 0 : 1
    }
    summary.completedAt = Date()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let report = destination.appending(path: "summary.json")
    try encoder.encode(summary).write(to: report, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
    try manifest.execute("UPDATE audit_state SET state='completed'")
    return summary
  }

  public struct CompressionSample: Codable, Sendable {
    public var originalPath: String
    public var originalBytes: Int64
    public var originalSHA256: String
    public var width: Int
    public var height: Int
    public var profile: String?
    public var orientation: Int?
    public var encodedBytes: [String: Int64]
  }

  /// Bounded exploratory samples, not approval of a migration quality setting.
  public static func sampleCompression(source: URL, manifest: URL, output: URL) throws
    -> [CompressionSample]
  {
    let manager = FileManager.default
    let root = source.standardizedFileURL.resolvingSymlinksInPath()
    let destination = output.standardizedFileURL.resolvingSymlinksInPath()
    guard !manager.fileExists(atPath: destination.path),
      destination.path != root.path, !destination.path.hasPrefix(root.path + "/"),
      !root.path.hasPrefix(destination.path + "/")
    else { throw AuditError.invalidPaths }
    let database = try AuditDatabase(url: manifest, readOnly: true)
    guard try database.string("SELECT state FROM audit_state") == "completed" else {
      throw AuditError.database("Audit manifest is incomplete")
    }
    // Small / median / large encoded files in the ten most common dimensions,
    // plus the earliest, latest and largest-pixel image. No random sampling drift.
    let selection = """
      WITH ranked AS (
        SELECT *,row_number() OVER (PARTITION BY width,height ORDER BY byte_count,relative_path) n,
          count(*) OVER (PARTITION BY width,height) total
        FROM images WHERE header_readable=1 AND timestamp_text IS NOT NULL AND image_type='public.jpeg'
      ), common AS (
        SELECT width,height FROM ranked GROUP BY width,height ORDER BY count(*) DESC,width,height LIMIT 10
      ), chosen AS (
        SELECT relative_path FROM ranked JOIN common USING(width,height)
          WHERE n=1 OR n=(total+1)/2 OR n=total
        UNION SELECT relative_path FROM (SELECT * FROM ranked ORDER BY CAST(timestamp_text AS INTEGER),relative_path LIMIT 1)
        UNION SELECT relative_path FROM (SELECT * FROM ranked ORDER BY CAST(timestamp_text AS INTEGER) DESC,relative_path LIMIT 1)
        UNION SELECT relative_path FROM (SELECT * FROM ranked ORDER BY width*height DESC,relative_path LIMIT 1)
      )
      SELECT i.relative_path,i.sha256 FROM images i JOIN chosen USING(relative_path) ORDER BY relative_path
      """
    var selected: [(String, String)] = []
    try database.rows(selection) { row in
      guard let path = row[0], let digest = row[1] else {
        throw AuditError.database("Compression samples require a hashed audit")
      }
      selected.append((path, digest))
    }
    guard !selected.isEmpty, selected.count <= 33 else { throw AuditError.invalidPaths }
    try reserveOutput(destination)
    var results: [CompressionSample] = []
    var html = """
      <!doctype html><meta charset="utf-8"><title>ScreenRecall legacy compression samples</title>
      <style>body{font:15px system-ui;margin:24px;background:#171717;color:#eee}section{margin:32px 0}
      .row{display:flex;gap:12px;overflow:auto}figure{margin:0;min-width:480px;max-width:720px}
      img{width:100%;height:320px;object-fit:contain;background:#222}a{color:#a8d1ff}</style>
      <h1>Legacy JPEG → WebP</h1><p>Private samples. Click an image to inspect its full size.
      Sizes are measured; visual quality is not automatically accepted. No source was replaced. WebP candidates use the current sRGB-converting encoder; original profiles are retained in the JPEG copies.</p>
      """
    for (index, selectedImage) in selected.enumerated() {
      try autoreleasepool {
        let (relative, expectedHash) = selectedImage
        let sourceURL = root.appending(path: "screenshots").appending(path: relative)
          .resolvingSymlinksInPath()
        guard sourceURL.path.hasPrefix(root.appending(path: "screenshots").path + "/") else {
          throw AuditError.invalidPaths
        }
        let prefix = String(format: "%02d", index + 1)
        let original = prefix + "-original.jpeg"
        let originalURL = destination.appending(path: original)
        try manager.copyItem(at: sourceURL, to: originalURL)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalURL.path)
        guard try hash(originalURL) == expectedHash,
          let imageSource = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width <= 16383, height <= 16383, width * height <= 40_000_000,
          let image = CGImageSourceCreateImageAtIndex(
            imageSource, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw LibraryError.unreadableImage }
        let size = Int64(try originalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        var sample = CompressionSample(
          originalPath: relative, originalBytes: size, originalSHA256: expectedHash,
          width: width, height: height, profile: properties[kCGImagePropertyProfileName] as? String,
          orientation: properties[kCGImagePropertyOrientation] as? Int, encodedBytes: [:])
        html +=
          "<section><h2>Sample " + prefix + " · " + String(width) + " × " + String(height)
          + "</h2><div class=row>"
        html +=
          "<figure><figcaption>Original JPEG · " + String(size) + " bytes</figcaption><a href='"
          + original + "'><img src='" + original + "'></a></figure>"
        for quality in [30, 50, 70] {
          let name = prefix + "-q" + String(quality) + ".webp"
          let url = destination.appending(path: name)
          let data = try WebPEncoding.data(image: image, quality: Double(quality) / 100)
          try data.write(to: url, options: .withoutOverwriting)
          guard let encodedSource = CGImageSourceCreateWithURL(url as CFURL, nil),
            let decoded = CGImageSourceCreateImageAtIndex(
              encodedSource, 0,
              [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
            decoded.width == width, decoded.height == height
          else { throw LibraryError.unreadableImage }
          sample.encodedBytes[String(quality)] = Int64(data.count)
          html +=
            "<figure><figcaption>WebP Q" + String(quality) + " · " + String(data.count)
            + " bytes</figcaption><a href='" + name + "'><img src='" + name + "'></a></figure>"
        }
        html += "</div></section>"
        results.append(sample)
        FileHandle.standardError.write(Data("Sampled \(index + 1)/\(selected.count) images\n".utf8))
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(
      to: destination.appending(path: "samples.json"), options: .atomic)
    try Data(html.utf8).write(to: destination.appending(path: "index.html"))
    for url in try manager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    return results
  }

  private static func reserveOutput(_ destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    // Reserve a new output atomically; concurrent runs must not share a manifest.
    guard mkdir(destination.path, 0o700) == 0 else { throw AuditError.invalidPaths }
  }

  private static func hash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
      hasher.update(data: bytes)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private enum AuditError: LocalizedError {
  case invalidPaths
  case database(String)
  var errorDescription: String? {
    switch self {
    case .invalidPaths:
      "Audit requires a source with screenshots and a new, separate output directory."
    case .database(let detail): "Migration audit database: " + detail
    }
  }
}

private final class AuditDatabase {
  private var handle: OpaquePointer?
  private var prepared: [String: OpaquePointer] = [:]
  init(url: URL, readOnly: Bool) throws {
    if readOnly {
      // READONLY alone may create shared-memory sidecars for a WAL database.
      // Require a stopped/checkpointed source or a separately prepared private snapshot.
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      let header = try file.read(upToCount: 100) ?? Data()
      guard header.count >= 100,
        String(decoding: header.prefix(16), as: UTF8.self) == "SQLite format 3\0",
        header[18] == 1, header[19] == 1,
        !["-wal", "-shm", "-journal"].contains(where: {
          FileManager.default.fileExists(atPath: url.path + $0)
        })
      else {
        throw AuditError.database(
          "WAL/journal or unsupported header; prepare a stable private snapshot before auditing.")
      }
    }
    let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
      let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      sqlite3_close(handle)
      handle = nil
      throw AuditError.database(detail)
    }
    sqlite3_busy_timeout(handle, 5000)
    try execute("PRAGMA trusted_schema=OFF")
    if readOnly { try execute("PRAGMA query_only=ON") }
  }
  deinit {
    for statement in prepared.values { sqlite3_finalize(statement) }
    sqlite3_close(handle)
  }
  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
  }
  func insert(_ sql: String, _ values: [String?]) throws {
    let statement: OpaquePointer
    if let existing = prepared[sql] {
      statement = existing
    } else {
      var compiled: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &compiled, nil) == SQLITE_OK, let compiled else {
        throw error()
      }
      prepared[sql] = compiled
      statement = compiled
    }
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    for (index, value) in values.enumerated() {
      if let value {
        guard
          sqlite3_bind_text(
            statement, Int32(index + 1), value, -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
        else { throw error() }
      } else {
        sqlite3_bind_null(statement, Int32(index + 1))
      }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
  }
  func rows(_ sql: String, body: ([String?]) throws -> Void) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
    defer { sqlite3_finalize(statement) }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw error() }
      let values = (0..<sqlite3_column_count(statement)).map { index -> String? in
        sqlite3_column_text(statement, index).map { String(cString: $0) }
      }
      try body(values)
    }
  }
  func integer(_ sql: String) throws -> Int64 {
    Int64(try string(sql)) ?? 0
  }
  func string(_ sql: String) throws -> String {
    var result = ""
    try rows(sql) { row in if let value = row.first ?? nil { result = value } }
    return result
  }
  private func error() -> AuditError { .database(String(cString: sqlite3_errmsg(handle))) }
}
