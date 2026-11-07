import CryptoKit
import Foundation
import ImageIO
import SQLite3

public struct CatalogSyncSummary: Equatable, Sendable {
  public let indexedCaptures: Int
  public let preservedNotes: Int
  public let preservedUsage: Int
  public let deferredOCRRows: Int
  public let ownedMoments: Int
  public let ownedFrames: Int
  public let hashedAssets: Int
  public let conflicts: Int
  public let inspectedPaths: Int
  public let unchangedPaths: Int
  public let addedPaths: Int
  public let changedPaths: Int
  public let missingPaths: Int
  public let walkMilliseconds: Double
  public let writeMilliseconds: Double
  public let totalMilliseconds: Double
  public let catalogBytesBefore: Int64
  public let catalogBytesAfter: Int64
  public let walBytesBefore: Int64
  public let walBytesAfter: Int64

  public init(
    indexedCaptures: Int, preservedNotes: Int, preservedUsage: Int, deferredOCRRows: Int,
    ownedMoments: Int = 0, ownedFrames: Int = 0, hashedAssets: Int = 0, conflicts: Int = 0,
    inspectedPaths: Int = 0, unchangedPaths: Int = 0, addedPaths: Int = 0, changedPaths: Int = 0,
    missingPaths: Int = 0, walkMilliseconds: Double = 0, writeMilliseconds: Double = 0,
    totalMilliseconds: Double = 0, catalogBytesBefore: Int64 = 0, catalogBytesAfter: Int64 = 0,
    walBytesBefore: Int64 = 0, walBytesAfter: Int64 = 0
  ) {
    self.indexedCaptures = indexedCaptures
    self.preservedNotes = preservedNotes
    self.preservedUsage = preservedUsage
    self.deferredOCRRows = deferredOCRRows
    self.ownedMoments = ownedMoments
    self.ownedFrames = ownedFrames
    self.hashedAssets = hashedAssets
    self.conflicts = conflicts
    self.inspectedPaths = inspectedPaths
    self.unchangedPaths = unchangedPaths
    self.addedPaths = addedPaths
    self.changedPaths = changedPaths
    self.missingPaths = missingPaths
    self.walkMilliseconds = walkMilliseconds
    self.writeMilliseconds = writeMilliseconds
    self.totalMilliseconds = totalMilliseconds
    self.catalogBytesBefore = catalogBytesBefore
    self.catalogBytesAfter = catalogBytesAfter
    self.walBytesBefore = walBytesBefore
    self.walBytesAfter = walBytesAfter
  }
}

public struct CatalogSourceMergeSummary: Equatable, Sendable {
  public let sourceID: Int64
  public let destinationID: Int64
  public let mergedMoments: Int
  public let mergedFrames: Int

  public init(sourceID: Int64, destinationID: Int64, mergedMoments: Int, mergedFrames: Int) {
    self.sourceID = sourceID
    self.destinationID = destinationID
    self.mergedMoments = mergedMoments
    self.mergedFrames = mergedFrames
  }
}

public enum CatalogSyncMode: Sendable {
  case incremental
  case full
}

public struct CatalogSearchResult: Identifiable, Sendable {
  public let id: Int64
  public let capture: Capture
  public let sourceRoot: URL

  public init(id: Int64, capture: Capture, sourceRoot: URL) {
    self.id = id
    self.capture = capture
    self.sourceRoot = sourceRoot
  }
}

public struct CaptureAnnotation: Equatable, Sendable {
  public let marked: Bool
  public let note: String
  public let updatedAt: TimeInterval

  public init(marked: Bool, note: String, updatedAt: TimeInterval) {
    self.marked = marked
    self.note = note
    self.updatedAt = updatedAt
  }
}

public struct CatalogAnnotationResult: Identifiable, Sendable {
  public let id: Int64
  public let capture: Capture
  public let sourceRoot: URL
  public let marked: Bool
  public let note: String
  public let updatedAt: TimeInterval

  public init(
    id: Int64, capture: Capture, sourceRoot: URL, marked: Bool, note: String,
    updatedAt: TimeInterval
  ) {
    self.id = id
    self.capture = capture
    self.sourceRoot = sourceRoot
    self.marked = marked
    self.note = note
    self.updatedAt = updatedAt
  }
}

public enum CatalogError: LocalizedError, Sendable {
  case cannotOpen(String)
  case database(String)
  case invalidLegacyDatabase(String)
  case unsupportedSchemaVersion(Int)
  case schemaChecksumMismatch(Int)
  case unknownSchema(String)

  public var errorDescription: String? {
    switch self {
    case .cannotOpen(let path): "無法開啟 ScreenRecall 索引：\(path)"
    case .database(let message): "ScreenRecall 索引錯誤：\(message)"
    case .invalidLegacyDatabase(let name): "無法讀取舊資料庫 \(name)，為保護資料而停止承接。"
    case .unsupportedSchemaVersion(let version):
      "ScreenRecall 索引版本 \(version) 太新，為保護資料而停止處理。"
    case .schemaChecksumMismatch(let version):
      "ScreenRecall 索引 migration \(version) 驗證失敗，為保護資料而停止處理。"
    case .unknownSchema(let table):
      "ScreenRecall 索引結構無法辨識（\(table)），為保護資料而停止處理。"
    }
  }
}

/// Owns a rebuildable SQLite index while leaving image trees and legacy databases untouched.
public actor CaptureCatalog {
  private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
      self.pointer = pointer
    }

    deinit {
      sqlite3_close(pointer)
    }
  }

  private struct PendingCapture {
    let relativePath: String
    let timestamp: TimeInterval
    let dayKey: String
    let clockKey: String
    let displayID: String?
    let byteCount: Int64
    let modifiedAt: TimeInterval?
    let width: Int?
    let height: Int?
    let codec: String?
  }

  private struct OwnedSyncSummary {
    var moments = 0
    var frames = 0
    var hashedAssets = 0
    var conflicts = 0
  }

  private struct StoredCapture {
    let byteCount: Int64
    let modifiedAt: TimeInterval?
    let present: Bool
  }

  private struct PreparedSync {
    let captures: [PendingCapture]
    let missingPaths: [String]
    let unchanged: Int
    let added: Int
    let changed: Int
    let missing: Int
  }

  private struct PendingSource {
    let source: CatalogSource
    let rootPath: String
    let captures: [PendingCapture]
  }

  private struct LegacySummary {
    var notes = 0
    var usage = 0
    var ocr = 0
  }

  public nonisolated let databaseURL: URL
  private let connection: SQLiteHandle
  private var database: OpaquePointer { connection.pointer }

  private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private static let upsertCaptureSQL = """
    INSERT INTO captures(
      source_id, relative_path, timestamp, day_key, clock_key, display_id,
      byte_count, modified_at, present, first_seen, last_seen)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
    ON CONFLICT(source_id, relative_path) DO UPDATE SET
      timestamp = excluded.timestamp, day_key = excluded.day_key,
      clock_key = excluded.clock_key, display_id = excluded.display_id,
      byte_count = excluded.byte_count, modified_at = excluded.modified_at,
      present = 1, last_seen = excluded.last_seen;
    """

  public init(databaseURL: URL) throws {
    self.databaseURL = databaseURL.standardizedFileURL
    let directory = databaseURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    var opened: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &opened, flags, nil) == SQLITE_OK, let opened else {
      throw CatalogError.cannotOpen(databaseURL.path)
    }
    connection = SQLiteHandle(opened)
    do {
      sqlite3_busy_timeout(opened, 5_000)
      try Self.execute(opened, "PRAGMA foreign_keys = ON;")
      try Self.execute(opened, "PRAGMA journal_mode = WAL;")
      try Self.execute(opened, "PRAGMA synchronous = NORMAL;")
      try RecallSchema.prepare(opened)
      try Self.protectFiles(at: databaseURL)
    } catch {
      throw error
    }
  }

  /// Copies a live catalog, including WAL, through SQLite's Backup API.
  /// The destination file must not already exist. The source is opened read-only.
  public static func backup(from source: URL, to destination: URL) throws {
    let sourceURL = source.standardizedFileURL
    let destinationURL = destination.standardizedFileURL
    guard sourceURL.path != destinationURL.path else {
      throw CatalogError.database("backup destination must be a different file")
    }
    let directory = destinationURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      throw CatalogError.database("backup destination already exists")
    }

    var sourceDB: OpaquePointer?
    guard
      sqlite3_open_v2(
        sourceURL.path, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let sourceDB
    else {
      throw CatalogError.cannotOpen(sourceURL.path)
    }
    defer { sqlite3_close(sourceDB) }
    sqlite3_busy_timeout(sourceDB, 15_000)

    var destinationDB: OpaquePointer?
    guard
      sqlite3_open_v2(
        destinationURL.path, &destinationDB,
        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let destinationDB
    else {
      throw CatalogError.cannotOpen(destinationURL.path)
    }
    defer { sqlite3_close(destinationDB) }

    guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
      throw CatalogError.database(String(cString: sqlite3_errmsg(destinationDB)))
    }

    var result = sqlite3_backup_step(backup, -1)
    var waits = 0
    while result == SQLITE_BUSY || result == SQLITE_LOCKED {
      waits += 1
      if waits > 40 {
        _ = sqlite3_backup_finish(backup)
        throw CatalogError.database("catalog backup timed out while the source was busy")
      }
      sqlite3_sleep(50)
      result = sqlite3_backup_step(backup, -1)
    }
    let finish = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finish == SQLITE_OK else {
      throw CatalogError.database("catalog backup failed (\(result)/\(finish))")
    }
    // Fold the copy into a single file. The source catalog stays on WAL.
    try? execute(destinationDB, "PRAGMA wal_checkpoint(TRUNCATE);")
    try? execute(destinationDB, "PRAGMA journal_mode = DELETE;")
    try protectFiles(at: destinationURL)
  }

  /// Read-only integrity probe. It does not migrate schema or write the source.
  public static func integrityOK(at url: URL) throws -> Bool {
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.standardizedFileURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let database
    else {
      throw CatalogError.cannotOpen(url.path)
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 5_000)
    var check: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA integrity_check;", -1, &check, nil) == SQLITE_OK,
      let check
    else {
      return false
    }
    defer { sqlite3_finalize(check) }
    guard sqlite3_step(check) == SQLITE_ROW,
      let text = sqlite3_column_text(check, 0),
      String(cString: text) == "ok"
    else { return false }
    var keys: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA foreign_key_check;", -1, &keys, nil) == SQLITE_OK,
      let keys
    else { return false }
    defer { sqlite3_finalize(keys) }
    return sqlite3_step(keys) != SQLITE_ROW
  }

  public func checkpointPassive() throws {
    try execute("PRAGMA wal_checkpoint(PASSIVE);")
  }

  public func storageBytes() throws -> (catalog: Int64, wal: Int64) {
    Self.storageBytes(at: databaseURL)
  }

  public func synchronize(
    roots: [URL], importLegacy: Bool = true, hashAssets: Bool = false,
    mode: CatalogSyncMode = .incremental
  ) async throws -> CatalogSyncSummary {
    let sources = roots.map { root in
      CatalogSource(
        key: Self.defaultSourceKey(for: root), root: root,
        domain: "image-tree", profile: "discovered")
    }
    return try await synchronize(
      sources: sources, importLegacy: importLegacy, hashAssets: hashAssets, mode: mode)
  }

  public func synchronize(
    sources: [CatalogSource], importLegacy: Bool = true, hashAssets: Bool = false,
    mode: CatalogSyncMode = .incremental
  ) async throws -> CatalogSyncSummary {
    let totalStart = ContinuousClock.now
    let before = Self.storageBytes(at: databaseURL)
    var pending: [PendingSource] = []
    var seen = Set<String>()
    let walkStart = ContinuousClock.now
    for source in sources {
      try Task.checkCancellation()
      let library = try CaptureLibrary(root: source.root)
      let pendingSource = try await pendingSource(
        for: source, library: library, includeImageMetadata: mode == .full)
      guard seen.insert(pendingSource.source.key).inserted else { continue }
      pending.append(pendingSource)
    }

    guard !pending.isEmpty else {
      throw LibraryError.invalidRoot
    }

    var preparedByKey: [String: PreparedSync] = [:]
    if mode == .incremental {
      for source in pending {
        try Task.checkCancellation()
        if let sourceID = try sourceID(forRootPath: source.rootPath) {
          preparedByKey[source.source.key] = try prepareIncrementalSync(
            source: source, sourceID: sourceID)
        } else {
          let captures = source.captures.map {
            $0.width == nil ? withImageMetadata($0, rootPath: source.rootPath) : $0
          }
          preparedByKey[source.source.key] = PreparedSync(
            captures: captures, missingPaths: [],
            unchanged: 0, added: captures.count, changed: 0, missing: 0)
        }
      }
    }
    let walkMilliseconds = Self.elapsedMilliseconds(walkStart)

    let writeStart = ContinuousClock.now
    try execute("BEGIN IMMEDIATE;")
    do {
      var indexed = 0
      var unchanged = 0
      var added = 0
      var changed = 0
      var missing = 0
      var legacy = LegacySummary()
      var ownedMoments = 0
      var ownedFrames = 0
      var hashedAssets = 0
      var conflicts = 0
      for source in pending {
        try Task.checkCancellation()
        let scanStartedAt = Date().timeIntervalSince1970
        let sourceID = try upsertSource(rootPath: source.rootPath, source: source.source)
        let prepared: PreparedSync
        if mode == .full {
          prepared = try prepareFullSync(source: source, sourceID: sourceID)
        } else {
          prepared =
            preparedByKey[source.source.key]
            ?? PreparedSync(
              captures: source.captures, missingPaths: [],
              unchanged: 0, added: source.captures.count, changed: 0, missing: 0)
        }
        unchanged += prepared.unchanged
        added += prepared.added
        changed += prepared.changed
        missing += prepared.missing
        let statement = try prepare(Self.upsertCaptureSQL)
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        for capture in prepared.captures {
          try Task.checkCancellation()
          try upsert(capture: capture, sourceID: sourceID, seenAt: now, using: statement)
        }
        try markCapturesAbsent(sourceID: sourceID, relativePaths: prepared.missingPaths)
        let sourceURL = URL(fileURLWithPath: source.rootPath)
        let imported =
          importLegacy
          ? try importLegacyData(near: sourceURL, sourceID: sourceID)
          : LegacySummary()
        let owned = try synchronizeOwnedModel(
          source: PendingSource(
            source: source.source, rootPath: source.rootPath, captures: prepared.captures),
          sourceID: sourceID, hashAssets: hashAssets, markAllAbsent: mode == .full)
        indexed += source.captures.count
        ownedMoments += owned.moments
        ownedFrames += owned.frames
        hashedAssets += owned.hashedAssets
        conflicts += owned.conflicts
        legacy.notes += imported.notes
        legacy.usage += imported.usage
        legacy.ocr += imported.ocr
        try recordCompletedScan(
          sourceID: sourceID, count: source.captures.count, startedAt: scanStartedAt)
      }
      try execute("COMMIT;")
      try? execute("PRAGMA wal_checkpoint(PASSIVE);")
      let writeMilliseconds = Self.elapsedMilliseconds(writeStart)
      let after = Self.storageBytes(at: databaseURL)
      return CatalogSyncSummary(
        indexedCaptures: indexed,
        preservedNotes: legacy.notes,
        preservedUsage: legacy.usage,
        deferredOCRRows: legacy.ocr,
        ownedMoments: ownedMoments,
        ownedFrames: ownedFrames,
        hashedAssets: hashedAssets,
        conflicts: conflicts,
        inspectedPaths: indexed,
        unchangedPaths: unchanged,
        addedPaths: added,
        changedPaths: changed,
        missingPaths: missing,
        walkMilliseconds: walkMilliseconds,
        writeMilliseconds: writeMilliseconds,
        totalMilliseconds: Self.elapsedMilliseconds(totalStart),
        catalogBytesBefore: before.catalog,
        catalogBytesAfter: after.catalog,
        walBytesBefore: before.wal,
        walBytesAfter: after.wal)
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  public func currentCaptureCount() throws -> Int {
    let statement = try prepare("SELECT COUNT(*) FROM captures WHERE present = 1;")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
    return Int(sqlite3_column_int64(statement, 0))
  }

  /// Merges an old image-tree source into the one ScreenRecall-owned image pool.
  ///
  /// The operation changes only catalog relationships. The caller must move the
  /// source files first and synchronize afterward. Primary keys and annotations
  /// stay stable; the retired source row is removed only after all references
  /// point at the destination source.
  public func mergeSource(from sourceRoot: URL, into destinationRoot: URL) throws
    -> CatalogSourceMergeSummary
  {
    let sourcePath = sourceRoot.standardizedFileURL.path
    let destinationPath = destinationRoot.standardizedFileURL.path
    guard let retiredID = try sourceID(forRootPath: sourcePath),
      let destinationID = try sourceID(forRootPath: destinationPath)
    else {
      throw CatalogError.database("source merge requires both catalog sources")
    }
    guard retiredID != destinationID else {
      return CatalogSourceMergeSummary(
        sourceID: retiredID, destinationID: destinationID, mergedMoments: 0, mergedFrames: 0)
    }

    let collisionChecks: [(table: String, columns: [String])] = [
      ("captures", ["relative_path"]),
      ("moments", ["timestamp_us"]),
      ("frames", ["relative_path"]),
      ("frames", ["moment_id", "member_key"]),
      ("annotations", ["relative_path"]),
      ("legacy_artifacts", ["name"]),
      ("legacy_notes", ["legacy_id"]),
      ("legacy_usage", ["legacy_id"]),
    ]
    for (table, columns) in collisionChecks {
      let columnSQL = columns.map { "old.\($0) = current.\($0)" }.joined(separator: " AND ")
      let statement = try prepare(
        """
        SELECT EXISTS(
          SELECT 1 FROM \(table) AS old
          JOIN \(table) AS current ON \(columnSQL)
          WHERE old.source_id = ? AND current.source_id = ?
        );
        """)
      defer { sqlite3_finalize(statement) }
      bind(integer: retiredID, to: statement, index: 1)
      bind(integer: destinationID, to: statement, index: 2)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
      if sqlite3_column_int(statement, 0) != 0 {
        throw CatalogError.database(
          "source merge collision in \(table).\(columns.joined(separator: ","))")
      }
    }

    let moments = try rowCount(
      "SELECT COUNT(*) FROM moments WHERE source_id = \(retiredID);")
    let frames = try rowCount(
      "SELECT COUNT(*) FROM frames WHERE source_id = \(retiredID);")
    try execute("BEGIN IMMEDIATE;")
    do {
      for table in [
        "captures", "moments", "frames", "annotations", "legacy_artifacts", "legacy_notes",
        "legacy_usage", "scan_runs", "frame_conflicts", "app_events",
      ] {
        try execute(
          "UPDATE \(table) SET source_id = \(destinationID) WHERE source_id = \(retiredID);")
      }
      try execute("DELETE FROM sources WHERE id = \(retiredID);")
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
    return CatalogSourceMergeSummary(
      sourceID: retiredID, destinationID: destinationID, mergedMoments: moments,
      mergedFrames: frames)
  }

  public func schemaStatus() throws -> CatalogSchemaStatus {
    try RecallSchema.status(database)
  }

  public func viewState() throws -> CatalogViewState? {
    let statement = try prepare(
      "SELECT day_key, timestamp, display_id FROM view_state WHERE state_id = 1;")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let dayKey = columnText(statement, 0) else {
      return nil
    }
    return CatalogViewState(
      dayKey: dayKey, timestamp: sqlite3_column_double(statement, 1),
      displayID: columnText(statement, 2))
  }

  public func saveViewState(dayKey: String, timestamp: TimeInterval, displayID: String? = nil)
    throws
  {
    try execute("BEGIN IMMEDIATE;")
    do {
      let statement = try prepare(
        """
        INSERT INTO view_state(state_id, day_key, timestamp, display_id, updated_at)
        VALUES (1, ?, ?, ?, ?)
        ON CONFLICT(state_id) DO UPDATE SET
          day_key = excluded.day_key, timestamp = excluded.timestamp,
          display_id = excluded.display_id, updated_at = excluded.updated_at;
        """)
      defer { sqlite3_finalize(statement) }
      bind(text: dayKey, to: statement, index: 1)
      bind(double: timestamp, to: statement, index: 2)
      bind(text: displayID, to: statement, index: 3)
      bind(double: Date().timeIntervalSince1970, to: statement, index: 4)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  public func dayMomentCounts() throws -> [(dayKey: String, count: Int)] {
    let statement = try prepare(
      """
      SELECT day_key, COUNT(*) FROM moments
      GROUP BY day_key
      ORDER BY day_key ASC;
      """)
    defer { sqlite3_finalize(statement) }
    var rows: [(dayKey: String, count: Int)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let dayKey = columnText(statement, 0) else { continue }
      rows.append((dayKey, Int(sqlite3_column_int64(statement, 1))))
    }
    return rows
  }

  public func presentDays(roots: [URL]) throws -> [CaptureDay] {
    var days: [CaptureDay] = []
    var seen = Set<String>()
    for root in roots {
      let library = try CaptureLibrary(root: root)
      let screenshots = library.screenshots
      let rootPath = screenshots.deletingLastPathComponent().path
      let statement = try prepare(
        """
        SELECT DISTINCT m.day_key
        FROM moments AS m
        JOIN frames AS f ON f.moment_id = m.moment_id
        JOIN sources AS s ON s.id = m.source_id
        WHERE f.status = 'present' AND s.root_path = ?
        ORDER BY m.day_key;
        """)
      defer { sqlite3_finalize(statement) }
      bind(text: rootPath, to: statement, index: 1)
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let dayKey = columnText(statement, 0),
          let day = CaptureDay.fromCatalog(dayKey: dayKey, screenshots: screenshots),
          seen.insert(day.id).inserted
        else { continue }
        days.append(day)
      }
    }
    return days.sorted { $0.id < $1.id }
  }

  public func presentCaptures(on day: CaptureDay, root: URL) throws -> [Capture] {
    let library = try CaptureLibrary(root: root)
    let screenshots = library.screenshots
    let rootPath = screenshots.deletingLastPathComponent().path
    let statement = try prepare(
      """
      SELECT f.relative_path, m.timestamp_us, f.display_id
      FROM frames AS f
      JOIN moments AS m ON m.moment_id = f.moment_id
      JOIN sources AS s ON s.id = f.source_id
      WHERE f.status = 'present' AND s.root_path = ? AND m.day_key = ?
      ORDER BY m.timestamp_us, f.relative_path;
      """)
    defer { sqlite3_finalize(statement) }
    bind(text: rootPath, to: statement, index: 1)
    bind(text: day.catalogDayKey, to: statement, index: 2)
    var captures: [Capture] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let relative = columnText(statement, 0) else { continue }
      captures.append(
        Capture(
          url: screenshots.appending(path: relative),
          timestamp: Double(sqlite3_column_int64(statement, 1)) / 1_000_000,
          displayID: columnText(statement, 2)))
    }
    return captures
  }

  public func ownershipSummary() throws -> CatalogOwnershipSummary {
    func count(_ sql: String) throws -> Int {
      let statement = try prepare(sql)
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
      return Int(sqlite3_column_int64(statement, 0))
    }
    return CatalogOwnershipSummary(
      sourceCount: try count("SELECT COUNT(*) FROM sources WHERE source_key IS NOT NULL;"),
      momentCount: try count("SELECT COUNT(*) FROM moments;"),
      frameCount: try count("SELECT COUNT(*) FROM frames WHERE status = 'present';"),
      assetCount: try count(
        "SELECT COUNT(DISTINCT asset_id) FROM frames WHERE status = 'present';"),
      sharedAssetCount: try count(
        "SELECT COUNT(*) FROM (SELECT asset_id FROM frames WHERE status = 'present' GROUP BY asset_id HAVING COUNT(*) > 1);"
      ),
      annotationCount: try count(
        "SELECT COUNT(*) FROM annotations WHERE marked = 1 OR length(trim(note)) > 0;"),
      applicationCount: try count("SELECT COUNT(*) FROM applications;"),
      appEventCount: try count("SELECT COUNT(*) FROM app_events;")
    )
  }

  public func annotations(
    markedOnly: Bool = false, notesOnly: Bool = false, limit: Int = 100
  ) throws -> [CatalogAnnotationResult] {
    var predicates = [
      "c.present = 1",
      "(a.marked = 1 OR length(trim(a.note)) > 0)",
    ]
    if markedOnly { predicates.append("a.marked = 1") }
    if notesOnly { predicates.append("length(trim(a.note)) > 0") }
    let statement = try prepare(
      """
      SELECT c.id, s.root_path, f.relative_path, c.timestamp, f.display_id,
             a.marked, a.note, a.updated_at
      FROM annotations AS a
      JOIN frames AS f
        ON (f.frame_id = a.frame_id)
        OR (a.frame_id IS NULL AND f.source_id = a.source_id AND f.relative_path = a.relative_path)
      JOIN captures AS c
        ON c.source_id = f.source_id AND c.relative_path = f.relative_path AND c.present = 1
      JOIN sources AS s ON s.id = a.source_id
      WHERE f.status = 'present' AND \(predicates.joined(separator: " AND "))
      ORDER BY a.updated_at DESC, c.timestamp DESC, c.relative_path ASC
      LIMIT ?;
      """
    )
    defer { sqlite3_finalize(statement) }
    bind(integer: Int64(max(1, min(limit, 500))), to: statement, index: 1)

    var results: [CatalogAnnotationResult] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard let root = columnText(statement, 1), let relative = columnText(statement, 2)
        else { continue }
        let sourceRoot = URL(fileURLWithPath: root)
        let capture = Capture(
          url: sourceRoot.appending(path: "screenshots").appending(path: relative),
          timestamp: sqlite3_column_double(statement, 3), displayID: columnText(statement, 4))
        results.append(
          CatalogAnnotationResult(
            id: sqlite3_column_int64(statement, 0), capture: capture, sourceRoot: sourceRoot,
            marked: sqlite3_column_int(statement, 5) != 0, note: columnText(statement, 6) ?? "",
            updatedAt: sqlite3_column_double(statement, 7)))
      case SQLITE_DONE:
        return results
      default:
        throw databaseError()
      }
    }
  }

  public func annotation(for capture: Capture) throws -> CaptureAnnotation? {
    guard let key = try captureKey(for: capture) else { return nil }
    let statement = try prepare(
      """
      SELECT marked, note, updated_at FROM annotations
      WHERE (frame_id IS NOT NULL AND frame_id = ?)
         OR (frame_id IS NULL AND source_id = ? AND relative_path = ?)
      ORDER BY frame_id IS NOT NULL DESC
      LIMIT 1;
      """
    )
    defer { sqlite3_finalize(statement) }
    bind(text: key.frameID, to: statement, index: 1)
    bind(integer: key.sourceID, to: statement, index: 2)
    bind(text: key.relativePath, to: statement, index: 3)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return CaptureAnnotation(
      marked: sqlite3_column_int(statement, 0) != 0,
      note: columnText(statement, 1) ?? "",
      updatedAt: sqlite3_column_double(statement, 2))
  }

  public func saveAnnotation(
    for capture: Capture, marked: Bool, note: String,
    updatedAt: TimeInterval? = nil
  ) throws {
    guard let key = try captureKey(for: capture) else {
      throw CatalogError.database("capture is not indexed")
    }
    let note = String(note.prefix(4_000))
    try execute("BEGIN IMMEDIATE;")
    do {
      if !marked && note.isEmpty {
        let statement = try prepare(
          "DELETE FROM annotations WHERE frame_id = ? OR (source_id = ? AND relative_path = ?);"
        )
        defer { sqlite3_finalize(statement) }
        bind(text: key.frameID, to: statement, index: 1)
        bind(integer: key.sourceID, to: statement, index: 2)
        bind(text: key.relativePath, to: statement, index: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
      } else {
        let cleanup = try prepare(
          "DELETE FROM annotations WHERE frame_id = ? AND NOT (source_id = ? AND relative_path = ?);"
        )
        defer { sqlite3_finalize(cleanup) }
        bind(text: key.frameID, to: cleanup, index: 1)
        bind(integer: key.sourceID, to: cleanup, index: 2)
        bind(text: key.relativePath, to: cleanup, index: 3)
        guard sqlite3_step(cleanup) == SQLITE_DONE else { throw databaseError() }
        let statement = try prepare(
          """
          INSERT INTO annotations(source_id, relative_path, frame_id, marked, note, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(source_id, relative_path) DO UPDATE SET
            frame_id = excluded.frame_id, marked = excluded.marked,
            note = excluded.note, updated_at = excluded.updated_at;
          """
        )
        defer { sqlite3_finalize(statement) }
        bind(integer: key.sourceID, to: statement, index: 1)
        bind(text: key.relativePath, to: statement, index: 2)
        bind(text: key.frameID, to: statement, index: 3)
        bind(integer: marked ? 1 : 0, to: statement, index: 4)
        bind(text: note, to: statement, index: 5)
        bind(double: updatedAt ?? Date().timeIntervalSince1970, to: statement, index: 6)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
      }
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  /// Searches only indexed metadata: date, time, display ID, and relative filename.
  /// It intentionally does not search OCR text.
  public func search(_ query: String, limit: Int = 100) throws -> [CatalogSearchResult] {
    let tokens = query.split(whereSeparator: { $0.isWhitespace }).map {
      String($0).replacingOccurrences(of: "/", with: "-")
    }.filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return [] }

    let clause = Array(
      repeating:
        "(c.day_key LIKE ? ESCAPE '\\' OR c.clock_key LIKE ? ESCAPE '\\' "
        + "OR c.relative_path LIKE ? ESCAPE '\\' OR COALESCE(c.display_id, '') LIKE ? ESCAPE '\\')",
      count: tokens.count
    ).joined(separator: " AND ")
    let sql = """
      SELECT c.id, s.root_path, c.relative_path, c.timestamp, c.display_id
      FROM captures AS c
      JOIN sources AS s ON s.id = c.source_id
      WHERE c.present = 1 AND \(clause)
      ORDER BY c.timestamp DESC, c.relative_path ASC
      LIMIT ?;
      """
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    var index: Int32 = 1
    for token in tokens {
      let value = "%\(escapedLike(token))%"
      bind(text: value, to: statement, index: index)
      bind(text: value, to: statement, index: index + 1)
      bind(text: value, to: statement, index: index + 2)
      bind(text: value, to: statement, index: index + 3)
      index += 4
    }
    bind(integer: Int64(max(1, min(limit, 500))), to: statement, index: index)

    var results: [CatalogSearchResult] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard let root = columnText(statement, 1), let relative = columnText(statement, 2) else {
          continue
        }
        let sourceRoot = URL(fileURLWithPath: root)
        let url = sourceRoot.appending(path: "screenshots").appending(path: relative)
        let displayID = columnText(statement, 4)
        results.append(
          CatalogSearchResult(
            id: sqlite3_column_int64(statement, 0),
            capture: Capture(
              url: url, timestamp: sqlite3_column_double(statement, 3), displayID: displayID),
            sourceRoot: sourceRoot))
      case SQLITE_DONE:
        return results
      default:
        throw databaseError()
      }
    }
  }

  public func legacyArtifactStatus(_ name: String) throws -> String? {
    let statement = try prepare(
      "SELECT status FROM legacy_artifacts WHERE name = ? ORDER BY updated_at DESC LIMIT 1;")
    defer { sqlite3_finalize(statement) }
    bind(text: name, to: statement, index: 1)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return columnText(statement, 0)
  }

  private static func createSchema(on database: OpaquePointer) throws {
    try execute(
      database,
      """
      CREATE TABLE IF NOT EXISTS sources (
        id INTEGER PRIMARY KEY,
        root_path TEXT NOT NULL UNIQUE,
        kind TEXT NOT NULL DEFAULT 'image-tree',
        first_seen REAL NOT NULL,
        last_seen REAL NOT NULL
      );
      CREATE TABLE IF NOT EXISTS captures (
        id INTEGER PRIMARY KEY,
        source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        relative_path TEXT NOT NULL,
        timestamp REAL NOT NULL,
        day_key TEXT NOT NULL,
        clock_key TEXT NOT NULL,
        display_id TEXT,
        byte_count INTEGER NOT NULL DEFAULT 0,
        modified_at REAL,
        present INTEGER NOT NULL DEFAULT 1,
        first_seen REAL NOT NULL,
        last_seen REAL NOT NULL,
        UNIQUE(source_id, relative_path)
      );
      CREATE INDEX IF NOT EXISTS captures_time ON captures(present, timestamp);
      CREATE INDEX IF NOT EXISTS captures_day ON captures(present, day_key);
      CREATE TABLE IF NOT EXISTS legacy_artifacts (
        source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        row_count INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY(source_id, name)
      );
      CREATE TABLE IF NOT EXISTS legacy_notes (
        source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        legacy_id INTEGER NOT NULL,
        timestamp REAL NOT NULL,
        note TEXT NOT NULL,
        PRIMARY KEY(source_id, legacy_id)
      );
      CREATE TABLE IF NOT EXISTS legacy_usage (
        source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        legacy_id INTEGER NOT NULL,
        timestamp TEXT NOT NULL,
        identifier TEXT NOT NULL,
        name TEXT NOT NULL,
        PRIMARY KEY(source_id, legacy_id)
      );
      CREATE TABLE IF NOT EXISTS annotations (
        source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        relative_path TEXT NOT NULL,
        marked INTEGER NOT NULL DEFAULT 0,
        note TEXT NOT NULL DEFAULT '',
        updated_at REAL NOT NULL,
        PRIMARY KEY(source_id, relative_path)
      );
      CREATE TABLE IF NOT EXISTS scan_runs (
        id INTEGER PRIMARY KEY,
        source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        started_at REAL NOT NULL,
        completed_at REAL NOT NULL,
        indexed_count INTEGER NOT NULL,
        status TEXT NOT NULL
      );
      PRAGMA user_version = 1;
      """)
  }

  private static func protectFiles(at url: URL) throws {
    for suffix in ["", "-wal", "-shm"] {
      let path = url.path + suffix
      guard FileManager.default.fileExists(atPath: path) else { continue }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
  }

  public static func storageBytes(at url: URL) -> (catalog: Int64, wal: Int64) {
    func size(_ path: String) -> Int64 {
      Int64(
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
          .int64Value ?? 0)
    }
    return (size(url.path), size(url.path + "-wal"))
  }

  static func elapsedMilliseconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
  }

  private func pendingSource(
    for source: CatalogSource, library: CaptureLibrary, includeImageMetadata: Bool
  ) async throws -> PendingSource {
    let screenshots = library.screenshots
    let prefix = screenshots.path + "/"
    let calendar = Self.localCalendar
    var captures: [PendingCapture] = []
    for day in try await library.days() {
      for capture in try await library.captures(on: day) {
        try Task.checkCancellation()
        let path = capture.url.resolvingSymlinksInPath().path
        guard path.hasPrefix(prefix) else { continue }
        let components = calendar.dateComponents(
          [.year, .month, .day, .hour, .minute, .second], from: capture.date)
        guard let year = components.year, let month = components.month, let day = components.day,
          let hour = components.hour, let minute = components.minute, let second = components.second
        else { continue }
        let values = try? capture.url.resourceValues(
          forKeys: [.fileSizeKey, .contentModificationDateKey])
        let metadata =
          includeImageMetadata
          ? Self.imageMetadata(at: capture.url) : (width: nil, height: nil, codec: nil)
        captures.append(
          PendingCapture(
            relativePath: String(path.dropFirst(prefix.count)),
            timestamp: capture.timestamp,
            dayKey: String(format: "%04d-%02d-%02d", year, month, day),
            clockKey: String(format: "%02d:%02d:%02d", hour, minute, second),
            displayID: capture.displayID,
            byteCount: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate?.timeIntervalSince1970,
            width: metadata.width,
            height: metadata.height,
            codec: metadata.codec))
      }
    }
    return PendingSource(
      source: source,
      rootPath: screenshots.deletingLastPathComponent().path,
      captures: captures)
  }

  private func prepareFullSync(source: PendingSource, sourceID: Int64) throws -> PreparedSync {
    try markCapturesAbsent(sourceID: sourceID)
    return PreparedSync(
      captures: source.captures, missingPaths: [],
      unchanged: 0, added: 0, changed: source.captures.count, missing: 0)
  }

  private func prepareIncrementalSync(source: PendingSource, sourceID: Int64) throws -> PreparedSync
  {
    let stored = try storedCaptures(sourceID: sourceID)
    var seen = Set<String>()
    var captures: [PendingCapture] = []
    var unchanged = 0
    var added = 0
    var changed = 0
    for capture in source.captures {
      try Task.checkCancellation()
      seen.insert(capture.relativePath)
      if let old = stored[capture.relativePath], old.present,
        old.byteCount == capture.byteCount,
        Self.sameModification(old.modifiedAt, capture.modifiedAt)
      {
        unchanged += 1
        continue
      }
      captures.append(
        capture.width == nil
          ? withImageMetadata(capture, rootPath: source.rootPath) : capture)
      if stored[capture.relativePath] == nil { added += 1 } else { changed += 1 }
    }
    let missingPaths =
      stored
      .compactMap { path, old in old.present && !seen.contains(path) ? path : nil }
      .sorted()
    return PreparedSync(
      captures: captures, missingPaths: missingPaths,
      unchanged: unchanged, added: added, changed: changed, missing: missingPaths.count)
  }

  private func storedCaptures(sourceID: Int64) throws -> [String: StoredCapture] {
    let statement = try prepare(
      """
      SELECT relative_path, byte_count, modified_at, present
      FROM captures WHERE source_id = ?;
      """)
    defer { sqlite3_finalize(statement) }
    bind(integer: sourceID, to: statement, index: 1)
    var stored: [String: StoredCapture] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let path = columnText(statement, 0) else { continue }
      let modified =
        sqlite3_column_type(statement, 2) == SQLITE_NULL
        ? nil : sqlite3_column_double(statement, 2)
      stored[path] = StoredCapture(
        byteCount: sqlite3_column_int64(statement, 1),
        modifiedAt: modified,
        present: sqlite3_column_int(statement, 3) != 0)
    }
    return stored
  }

  private func withImageMetadata(_ capture: PendingCapture, rootPath: String) -> PendingCapture {
    let url = URL(fileURLWithPath: rootPath).appending(path: "screenshots")
      .appending(path: capture.relativePath)
    let metadata = Self.imageMetadata(at: url)
    return PendingCapture(
      relativePath: capture.relativePath, timestamp: capture.timestamp, dayKey: capture.dayKey,
      clockKey: capture.clockKey, displayID: capture.displayID, byteCount: capture.byteCount,
      modifiedAt: capture.modifiedAt, width: metadata.width, height: metadata.height,
      codec: metadata.codec)
  }

  private static func sameModification(_ left: TimeInterval?, _ right: TimeInterval?) -> Bool {
    switch (left, right) {
    case (nil, nil): return true
    case (let left?, let right?): return abs(left - right) < 0.51
    default: return false
    }
  }

  private func synchronizeOwnedModel(
    source: PendingSource, sourceID: Int64, hashAssets: Bool, markAllAbsent: Bool
  ) throws -> OwnedSyncSummary {
    var summary = OwnedSyncSummary()
    let now = Date().timeIntervalSince1970
    // Existing catalogs may use the pre-v2 discovered key. Keep their actual
    // key for stable moment/frame IDs while the source root is relocated.
    let logicalSourceKey = try sourceKey(sourceID)
    if markAllAbsent {
      try execute("UPDATE frames SET status = 'absent' WHERE source_id = \(sourceID);")
    }

    var legacyCounts: [Int64: Int] = [:]
    for capture in source.captures where capture.displayID == nil {
      legacyCounts[Self.timestampMicros(capture.timestamp), default: 0] += 1
    }
    var seenMoments = Set<String>()
    for capture in source.captures {
      try Task.checkCancellation()
      let timestamp = Self.timestampMicros(capture.timestamp)
      let generatedMomentID = Self.stableID(
        prefix: "moment", value: "\(logicalSourceKey)|\(timestamp)")
      let memberKey: String
      if let displayID = capture.displayID {
        memberKey = "display:\(displayID)"
      } else if legacyCounts[timestamp, default: 0] > 1 {
        memberKey = "legacy-path:\(capture.relativePath)"
      } else {
        memberKey = "legacy"
      }
      let generatedFrameID = Self.stableID(
        prefix: "frame", value: "\(logicalSourceKey)|\(timestamp)|\(memberKey)")
      let existing = try existingFrame(sourceID: sourceID, relativePath: capture.relativePath)
      if let existing, existing.timestampUS != timestamp {
        try recordFrameConflict(
          sourceID: sourceID, relativePath: capture.relativePath,
          existingFrameID: existing.frameID, incomingFrameID: generatedFrameID,
          incomingTimestamp: timestamp, detectedAt: now)
        summary.conflicts += 1
        continue
      }
      // A source merge can preserve an existing frame ID whose old logical
      // source key is different. Reuse that frame and moment instead of
      // creating duplicate history during the first post-merge scan.
      let momentID = existing?.momentID ?? generatedMomentID
      let frameID = existing?.frameID ?? generatedFrameID
      let imageURL = URL(fileURLWithPath: source.rootPath)
        .appending(path: "screenshots").appending(path: capture.relativePath)
      let digest = hashAssets ? try Self.sha256(at: imageURL) : nil
      let assetID = digest.map { "sha256:\($0)" } ?? "pending:\(frameID)"

      if seenMoments.insert(momentID).inserted {
        try upsertMoment(
          momentID: momentID, sourceID: sourceID, timestamp: capture.timestamp,
          timestampText: String(format: "%.6f", capture.timestamp), dayKey: capture.dayKey,
          seenAt: now)
        summary.moments += 1
      }
      try upsertAsset(
        assetID: assetID, sha256: digest, byteCount: capture.byteCount,
        width: capture.width, height: capture.height, codec: capture.codec, seenAt: now)
      if digest != nil { summary.hashedAssets += 1 }

      try upsertFrame(
        frameID: frameID, sourceID: sourceID, momentID: momentID, memberKey: memberKey,
        relativePath: capture.relativePath, displayID: capture.displayID, assetID: assetID,
        seenAt: now)
      try updateAnnotationFrameID(
        sourceID: sourceID, relativePath: capture.relativePath, frameID: frameID)
      try linkLegacyNotes(
        sourceID: sourceID, timestamp: capture.timestamp, frameID: frameID)
      summary.frames += 1
    }
    return summary
  }

  private func upsertMoment(
    momentID: String, sourceID: Int64, timestamp: TimeInterval, timestampText: String,
    dayKey: String, seenAt: TimeInterval
  ) throws {
    let statement = try prepare(
      """
      INSERT INTO moments(
        moment_id, source_id, timestamp_us, timestamp_text, day_key, first_seen, last_seen)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(moment_id) DO UPDATE SET
        timestamp_text = excluded.timestamp_text, day_key = excluded.day_key,
        last_seen = excluded.last_seen;
      """
    )
    defer { sqlite3_finalize(statement) }
    bind(text: momentID, to: statement, index: 1)
    bind(integer: sourceID, to: statement, index: 2)
    bind(integer: Self.timestampMicros(timestamp), to: statement, index: 3)
    bind(text: timestampText, to: statement, index: 4)
    bind(text: dayKey, to: statement, index: 5)
    bind(double: seenAt, to: statement, index: 6)
    bind(double: seenAt, to: statement, index: 7)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func upsertAsset(
    assetID: String, sha256: String?, byteCount: Int64, width: Int?, height: Int?, codec: String?,
    seenAt: TimeInterval
  ) throws {
    let statement = try prepare(
      """
      INSERT INTO assets(
        asset_id, sha256, byte_count, width, height, codec, status, first_seen, last_seen)
      VALUES (?, ?, ?, ?, ?, ?, 'available', ?, ?)
      ON CONFLICT(asset_id) DO UPDATE SET
        sha256 = COALESCE(excluded.sha256, assets.sha256),
        byte_count = excluded.byte_count, width = COALESCE(excluded.width, assets.width),
        height = COALESCE(excluded.height, assets.height), codec = COALESCE(excluded.codec, assets.codec),
        status = 'available', last_seen = excluded.last_seen;
      """
    )
    defer { sqlite3_finalize(statement) }
    bind(text: assetID, to: statement, index: 1)
    bind(text: sha256, to: statement, index: 2)
    bind(integer: byteCount, to: statement, index: 3)
    bind(integer: width.map(Int64.init), to: statement, index: 4)
    bind(integer: height.map(Int64.init), to: statement, index: 5)
    bind(text: codec, to: statement, index: 6)
    bind(double: seenAt, to: statement, index: 7)
    bind(double: seenAt, to: statement, index: 8)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private struct ExistingFrame {
    let frameID: String
    let momentID: String
    let timestampUS: Int64
  }

  private func existingFrame(sourceID: Int64, relativePath: String) throws -> ExistingFrame? {
    let statement = try prepare(
      """
      SELECT f.frame_id, f.moment_id, m.timestamp_us
      FROM frames AS f JOIN moments AS m ON m.moment_id = f.moment_id
      WHERE f.source_id = ? AND f.relative_path = ? LIMIT 1;
      """)
    defer { sqlite3_finalize(statement) }
    bind(integer: sourceID, to: statement, index: 1)
    bind(text: relativePath, to: statement, index: 2)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    guard let frameID = columnText(statement, 0), let momentID = columnText(statement, 1) else {
      throw databaseError()
    }
    return ExistingFrame(
      frameID: frameID, momentID: momentID, timestampUS: sqlite3_column_int64(statement, 2))
  }

  private func upsertFrame(
    frameID: String, sourceID: Int64, momentID: String, memberKey: String,
    relativePath: String, displayID: String?, assetID: String, seenAt: TimeInterval
  ) throws {
    let statement = try prepare(
      """
      INSERT INTO frames(
        frame_id, source_id, moment_id, member_key, relative_path, display_id, asset_id,
        status, first_seen, last_seen)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'present', ?, ?)
      ON CONFLICT(frame_id) DO UPDATE SET
        source_id = excluded.source_id, moment_id = excluded.moment_id,
        member_key = excluded.member_key, relative_path = excluded.relative_path,
        display_id = excluded.display_id, asset_id = excluded.asset_id,
        status = 'present', last_seen = excluded.last_seen;
      """
    )
    defer { sqlite3_finalize(statement) }
    bind(text: frameID, to: statement, index: 1)
    bind(integer: sourceID, to: statement, index: 2)
    bind(text: momentID, to: statement, index: 3)
    bind(text: memberKey, to: statement, index: 4)
    bind(text: relativePath, to: statement, index: 5)
    bind(text: displayID, to: statement, index: 6)
    bind(text: assetID, to: statement, index: 7)
    bind(double: seenAt, to: statement, index: 8)
    bind(double: seenAt, to: statement, index: 9)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func updateAnnotationFrameID(
    sourceID: Int64, relativePath: String, frameID: String
  ) throws {
    let statement = try prepare(
      "UPDATE annotations SET frame_id = ? WHERE source_id = ? AND relative_path = ?;")
    defer { sqlite3_finalize(statement) }
    bind(text: frameID, to: statement, index: 1)
    bind(integer: sourceID, to: statement, index: 2)
    bind(text: relativePath, to: statement, index: 3)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func linkLegacyNotes(sourceID: Int64, timestamp: TimeInterval, frameID: String) throws {
    let statement = try prepare(
      "UPDATE legacy_notes SET frame_id = ? WHERE source_id = ? AND timestamp = ?;")
    defer { sqlite3_finalize(statement) }
    bind(text: frameID, to: statement, index: 1)
    bind(integer: sourceID, to: statement, index: 2)
    bind(double: timestamp, to: statement, index: 3)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func recordFrameConflict(
    sourceID: Int64, relativePath: String, existingFrameID: String, incomingFrameID: String,
    incomingTimestamp: Int64, detectedAt: TimeInterval
  ) throws {
    let statement = try prepare(
      """
      INSERT INTO frame_conflicts(
        source_id, relative_path, existing_frame_id, incoming_frame_id,
        existing_timestamp_us, incoming_timestamp_us, detected_at)
      SELECT ?, ?, ?, ?, m.timestamp_us, ?, ?
      FROM frames AS f JOIN moments AS m ON m.moment_id = f.moment_id
      WHERE f.frame_id = ?;
      """
    )
    defer { sqlite3_finalize(statement) }
    bind(integer: sourceID, to: statement, index: 1)
    bind(text: relativePath, to: statement, index: 2)
    bind(text: existingFrameID, to: statement, index: 3)
    bind(text: incomingFrameID, to: statement, index: 4)
    bind(integer: incomingTimestamp, to: statement, index: 5)
    bind(double: detectedAt, to: statement, index: 6)
    bind(text: existingFrameID, to: statement, index: 7)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func upsertSource(rootPath: String, source: CatalogSource) throws -> Int64 {
    let now = Date().timeIntervalSince1970
    if let existing = try sourceID(forRootPath: rootPath) {
      try updateSourceMetadata(existing, source: source, seenAt: now)
      return existing
    }
    if source.key == "screenmemory.legacy.image-tree",
      let relocated = try relocateDiscoveredScreenMemorySource(
        to: rootPath, source: source, seenAt: now)
    {
      return relocated
    }

    let statement = try prepare(
      """
      INSERT INTO sources(root_path, kind, first_seen, last_seen, source_key, domain, profile)
      VALUES (?, 'image-tree', ?, ?, ?, ?, ?)
      ON CONFLICT(source_key) DO UPDATE SET
        root_path = excluded.root_path, domain = excluded.domain,
        profile = excluded.profile, last_seen = excluded.last_seen;
      """)
    defer { sqlite3_finalize(statement) }
    bind(text: rootPath, to: statement, index: 1)
    bind(double: now, to: statement, index: 2)
    bind(double: now, to: statement, index: 3)
    bind(text: source.key, to: statement, index: 4)
    bind(text: source.domain, to: statement, index: 5)
    bind(text: source.profile, to: statement, index: 6)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }

    let lookup = try prepare("SELECT id FROM sources WHERE source_key = ?;")
    defer { sqlite3_finalize(lookup) }
    bind(text: source.key, to: lookup, index: 1)
    guard sqlite3_step(lookup) == SQLITE_ROW else { throw databaseError() }
    return sqlite3_column_int64(lookup, 0)
  }

  private func sourceID(forRootPath rootPath: String) throws -> Int64? {
    let statement = try prepare("SELECT id FROM sources WHERE root_path = ? LIMIT 1;")
    defer { sqlite3_finalize(statement) }
    bind(text: rootPath, to: statement, index: 1)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int64(statement, 0)
  }

  private func rowCount(_ sql: String) throws -> Int {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func sourceKey(_ sourceID: Int64) throws -> String {
    let statement = try prepare("SELECT source_key FROM sources WHERE id = ? LIMIT 1;")
    defer { sqlite3_finalize(statement) }
    bind(integer: sourceID, to: statement, index: 1)
    guard sqlite3_step(statement) == SQLITE_ROW, let key = columnText(statement, 0) else {
      throw databaseError()
    }
    return key
  }

  private func updateSourceMetadata(
    _ sourceID: Int64, source: CatalogSource, seenAt: TimeInterval
  ) throws {
    let statement = try prepare(
      "UPDATE sources SET domain = ?, profile = ?, last_seen = ? WHERE id = ?;"
    )
    defer { sqlite3_finalize(statement) }
    bind(text: source.domain, to: statement, index: 1)
    bind(text: source.profile, to: statement, index: 2)
    bind(double: seenAt, to: statement, index: 3)
    bind(integer: sourceID, to: statement, index: 4)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  /// Relocate the one clearly recognizable legacy ScreenMemory source before
  /// a Q50/source switch. Keep its pre-v2 key so existing moment/frame IDs and
  /// annotations remain valid without a destructive primary-key rewrite.
  private func relocateDiscoveredScreenMemorySource(
    to rootPath: String, source: CatalogSource, seenAt: TimeInterval
  ) throws -> Int64? {
    let statement = try prepare(
      "SELECT id, root_path FROM sources WHERE source_key = 'image-tree.discovered';")
    defer { sqlite3_finalize(statement) }
    var candidates: [(id: Int64, rootPath: String)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let oldRoot = columnText(statement, 1) else { continue }
      candidates.append((sqlite3_column_int64(statement, 0), oldRoot))
    }
    guard candidates.count == 1, let candidate = candidates.first,
      Self.isLegacyScreenMemoryTree(at: URL(fileURLWithPath: candidate.rootPath))
    else { return nil }

    let update = try prepare(
      """
      UPDATE sources SET root_path = ?, domain = ?, profile = ?, last_seen = ?
      WHERE id = ? AND source_key = 'image-tree.discovered';
      """
    )
    defer { sqlite3_finalize(update) }
    bind(text: rootPath, to: update, index: 1)
    bind(text: source.domain, to: update, index: 2)
    bind(text: source.profile, to: update, index: 3)
    bind(double: seenAt, to: update, index: 4)
    bind(integer: candidate.id, to: update, index: 5)
    guard sqlite3_step(update) == SQLITE_DONE else { throw databaseError() }
    return candidate.id
  }

  private func captureKey(for capture: Capture) throws -> (
    sourceID: Int64, relativePath: String, frameID: String?
  )? {
    let statement = try prepare(
      """
      SELECT f.source_id, f.relative_path, f.frame_id
      FROM frames AS f
      JOIN sources AS s ON s.id = f.source_id
      WHERE f.status = 'present'
        AND ? = s.root_path || '/screenshots/' || f.relative_path
      ORDER BY f.last_seen DESC
      LIMIT 1;
      """
    )
    defer { sqlite3_finalize(statement) }
    bind(text: capture.url.standardizedFileURL.path, to: statement, index: 1)
    guard sqlite3_step(statement) == SQLITE_ROW, let relativePath = columnText(statement, 1)
    else { return nil }
    return (sqlite3_column_int64(statement, 0), relativePath, columnText(statement, 2))
  }

  private func markCapturesAbsent(sourceID: Int64) throws {
    let statement = try prepare("UPDATE captures SET present = 0 WHERE source_id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(integer: sourceID, to: statement, index: 1)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func markCapturesAbsent(sourceID: Int64, relativePaths: [String]) throws {
    guard !relativePaths.isEmpty else { return }
    let captures = try prepare(
      "UPDATE captures SET present = 0 WHERE source_id = ? AND relative_path = ?;")
    defer { sqlite3_finalize(captures) }
    let frames = try prepare(
      "UPDATE frames SET status = 'absent' WHERE source_id = ? AND relative_path = ?;")
    defer { sqlite3_finalize(frames) }
    for path in relativePaths {
      sqlite3_reset(captures)
      sqlite3_clear_bindings(captures)
      bind(integer: sourceID, to: captures, index: 1)
      bind(text: path, to: captures, index: 2)
      guard sqlite3_step(captures) == SQLITE_DONE else { throw databaseError() }
      sqlite3_reset(frames)
      sqlite3_clear_bindings(frames)
      bind(integer: sourceID, to: frames, index: 1)
      bind(text: path, to: frames, index: 2)
      guard sqlite3_step(frames) == SQLITE_DONE else { throw databaseError() }
    }
  }

  private func upsert(
    capture: PendingCapture, sourceID: Int64, seenAt: TimeInterval, using statement: OpaquePointer
  ) throws {
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    bind(integer: sourceID, to: statement, index: 1)
    bind(text: capture.relativePath, to: statement, index: 2)
    bind(double: capture.timestamp, to: statement, index: 3)
    bind(text: capture.dayKey, to: statement, index: 4)
    bind(text: capture.clockKey, to: statement, index: 5)
    bind(text: capture.displayID, to: statement, index: 6)
    bind(integer: capture.byteCount, to: statement, index: 7)
    bind(double: capture.modifiedAt, to: statement, index: 8)
    bind(double: seenAt, to: statement, index: 9)
    bind(double: seenAt, to: statement, index: 10)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func recordCompletedScan(sourceID: Int64, count: Int, startedAt: TimeInterval) throws {
    let statement = try prepare(
      """
      INSERT INTO scan_runs(source_id, started_at, completed_at, indexed_count, status)
      VALUES (?, ?, ?, ?, 'complete');
      """)
    defer { sqlite3_finalize(statement) }
    bind(integer: sourceID, to: statement, index: 1)
    bind(double: startedAt, to: statement, index: 2)
    bind(double: Date().timeIntervalSince1970, to: statement, index: 3)
    bind(integer: Int64(count), to: statement, index: 4)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func importLegacyData(near imageRoot: URL, sourceID: Int64) throws -> LegacySummary {
    var result = LegacySummary()
    for name in ["notes.sqlite", "usage.sqlite", "text.sqlite"] {
      let url = imageRoot.appending(path: name)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      switch name {
      case "notes.sqlite":
        result.notes = try importNotes(at: url, sourceID: sourceID)
      case "usage.sqlite":
        result.usage = try importUsage(at: url, sourceID: sourceID)
      default:
        result.ocr = try deferOCR(at: url, sourceID: sourceID)
      }
    }
    return result
  }

  private func importNotes(at url: URL, sourceID: Int64) throws -> Int {
    let legacy = try openLegacy(url, name: "notes.sqlite")
    defer { sqlite3_close(legacy) }
    guard try tableExists("notes", in: legacy) else {
      try recordArtifact(
        sourceID: sourceID, name: "notes.sqlite", url: url, kind: "notes", count: 0,
        status: "unrecognized")
      return 0
    }
    let count = try scalarCount("SELECT COUNT(*) FROM notes;", in: legacy)
    let read = try prepare(legacy, "SELECT id, timestamp, note FROM notes;")
    let insert = try prepare(
      """
      INSERT INTO legacy_notes(source_id, legacy_id, timestamp, note) VALUES (?, ?, ?, ?)
      ON CONFLICT(source_id, legacy_id) DO UPDATE SET timestamp = excluded.timestamp, note = excluded.note;
      """)
    defer {
      sqlite3_finalize(read)
      sqlite3_finalize(insert)
    }
    while true {
      let result = sqlite3_step(read)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw legacyDatabaseError("notes.sqlite") }
      sqlite3_reset(insert)
      sqlite3_clear_bindings(insert)
      bind(integer: sourceID, to: insert, index: 1)
      bind(integer: sqlite3_column_int64(read, 0), to: insert, index: 2)
      bind(double: Double(sqlite3_column_int64(read, 1)), to: insert, index: 3)
      bind(text: columnText(read, 2) ?? "", to: insert, index: 4)
      guard sqlite3_step(insert) == SQLITE_DONE else { throw databaseError() }
    }
    try recordArtifact(
      sourceID: sourceID, name: "notes.sqlite", url: url, kind: "notes", count: count,
      status: "preserved")
    return count
  }

  private func importUsage(at url: URL, sourceID: Int64) throws -> Int {
    let legacy = try openLegacy(url, name: "usage.sqlite")
    defer { sqlite3_close(legacy) }
    guard try tableExists("usage", in: legacy) else {
      try recordArtifact(
        sourceID: sourceID, name: "usage.sqlite", url: url, kind: "usage", count: 0,
        status: "unrecognized")
      return 0
    }
    let count = try scalarCount("SELECT COUNT(*) FROM usage;", in: legacy)
    let read = try prepare(legacy, "SELECT id, timestamp, identifier, name FROM usage;")
    let insert = try prepare(
      """
      INSERT INTO legacy_usage(source_id, legacy_id, timestamp, timestamp_us, identifier, name)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_id, legacy_id) DO UPDATE SET
        timestamp = excluded.timestamp, timestamp_us = excluded.timestamp_us,
        identifier = excluded.identifier, name = excluded.name;
      """)
    let application = try prepare(
      """
      INSERT INTO applications(application_id, identifier, name) VALUES (?, ?, ?)
      ON CONFLICT(identifier, name) DO UPDATE SET application_id = excluded.application_id;
      """
    )
    let event = try prepare(
      """
      INSERT INTO app_events(
        event_id, source_id, legacy_id, timestamp_text, timestamp_us, identifier, name,
        application_id, conflict_key)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(event_id) DO UPDATE SET
        timestamp_text = excluded.timestamp_text, timestamp_us = excluded.timestamp_us,
        identifier = excluded.identifier, name = excluded.name,
        application_id = excluded.application_id, conflict_key = excluded.conflict_key;
      """
    )
    defer {
      sqlite3_finalize(read)
      sqlite3_finalize(insert)
      sqlite3_finalize(application)
      sqlite3_finalize(event)
    }
    while true {
      let result = sqlite3_step(read)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw legacyDatabaseError("usage.sqlite") }
      let legacyID = sqlite3_column_int64(read, 0)
      let timestampText = columnText(read, 1) ?? ""
      let identifier = columnText(read, 2) ?? ""
      let name = columnText(read, 3) ?? ""
      let timestamp = Self.legacyTimestampMicros(timestampText)
      let applicationID = Self.stableID(
        prefix: "application", value: "\(identifier)\u{001F}\(name)")
      sqlite3_reset(insert)
      sqlite3_clear_bindings(insert)
      bind(integer: sourceID, to: insert, index: 1)
      bind(integer: legacyID, to: insert, index: 2)
      bind(text: timestampText, to: insert, index: 3)
      bind(integer: timestamp, to: insert, index: 4)
      bind(text: identifier, to: insert, index: 5)
      bind(text: name, to: insert, index: 6)
      guard sqlite3_step(insert) == SQLITE_DONE else { throw databaseError() }

      sqlite3_reset(application)
      sqlite3_clear_bindings(application)
      bind(text: applicationID, to: application, index: 1)
      bind(text: identifier, to: application, index: 2)
      bind(text: name, to: application, index: 3)
      guard sqlite3_step(application) == SQLITE_DONE else { throw databaseError() }

      sqlite3_reset(event)
      sqlite3_clear_bindings(event)
      bind(
        text: Self.stableID(prefix: "app-event", value: "\(sourceID)|\(legacyID)"), to: event,
        index: 1)
      bind(integer: sourceID, to: event, index: 2)
      bind(integer: legacyID, to: event, index: 3)
      bind(text: timestampText, to: event, index: 4)
      bind(integer: timestamp, to: event, index: 5)
      bind(text: identifier, to: event, index: 6)
      bind(text: name, to: event, index: 7)
      bind(text: applicationID, to: event, index: 8)
      bind(text: "\(timestampText)|\(identifier)|\(name)", to: event, index: 9)
      guard sqlite3_step(event) == SQLITE_DONE else { throw databaseError() }
    }
    try recordArtifact(
      sourceID: sourceID, name: "usage.sqlite", url: url, kind: "usage", count: count,
      status: "preserved")
    return count
  }

  private func deferOCR(at url: URL, sourceID: Int64) throws -> Int {
    let legacy = try openLegacy(url, name: "text.sqlite")
    defer { sqlite3_close(legacy) }
    guard try tableExists("ocrresults", in: legacy) else {
      try recordArtifact(
        sourceID: sourceID, name: "text.sqlite", url: url, kind: "ocr", count: 0,
        status: "unrecognized")
      return 0
    }
    let count = try scalarCount("SELECT COUNT(*) FROM ocrresults;", in: legacy)
    try recordArtifact(
      sourceID: sourceID, name: "text.sqlite", url: url, kind: "ocr", count: count,
      status: "deferred-ocr")
    return count
  }

  private func recordArtifact(
    sourceID: Int64, name: String, url: URL, kind: String, count: Int, status: String
  ) throws {
    let statement = try prepare(
      """
      INSERT INTO legacy_artifacts(source_id, name, path, kind, row_count, status, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_id, name) DO UPDATE SET
        path = excluded.path, kind = excluded.kind, row_count = excluded.row_count,
        status = excluded.status, updated_at = excluded.updated_at;
      """)
    defer { sqlite3_finalize(statement) }
    bind(integer: sourceID, to: statement, index: 1)
    bind(text: name, to: statement, index: 2)
    bind(text: url.path, to: statement, index: 3)
    bind(text: kind, to: statement, index: 4)
    bind(integer: Int64(count), to: statement, index: 5)
    bind(text: status, to: statement, index: 6)
    bind(double: Date().timeIntervalSince1970, to: statement, index: 7)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
  }

  private func openLegacy(_ url: URL, name: String) throws -> OpaquePointer {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw CatalogError.invalidLegacyDatabase(name)
    }
    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    guard result == SQLITE_OK, let opened else {
      let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      if let opened { sqlite3_close(opened) }
      throw CatalogError.invalidLegacyDatabase("\(name): \(message)")
    }
    return opened
  }

  private func tableExists(_ name: String, in database: OpaquePointer) throws -> Bool {
    let statement = try prepare(
      database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;")
    defer { sqlite3_finalize(statement) }
    bind(text: name, to: statement, index: 1)
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func scalarCount(_ sql: String, in database: OpaquePointer) throws -> Int {
    let statement = try prepare(database, sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw legacyDatabaseError("legacy") }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    try prepare(database, sql)
  }

  private func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw databaseError(database) }
    return statement
  }

  private func execute(_ sql: String) throws {
    try Self.execute(database, sql)
  }

  private static func execute(_ database: OpaquePointer, _ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    defer { if let message { sqlite3_free(message) } }
    guard result == SQLITE_OK else {
      throw CatalogError.database(message.map { String(cString: $0) } ?? "unknown SQLite error")
    }
  }

  private func bind(text: String?, to statement: OpaquePointer, index: Int32) {
    guard let text else {
      sqlite3_bind_null(statement, index)
      return
    }
    _ = text.withCString { value in
      sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }
  }

  private func bind(integer: Int64?, to statement: OpaquePointer, index: Int32) {
    guard let integer else {
      sqlite3_bind_null(statement, index)
      return
    }
    sqlite3_bind_int64(statement, index, integer)
  }

  private func bind(double: Double?, to statement: OpaquePointer, index: Int32) {
    guard let double else {
      sqlite3_bind_null(statement, index)
      return
    }
    sqlite3_bind_double(statement, index, double)
  }

  private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
  }

  private func databaseError(_ database: OpaquePointer? = nil) -> CatalogError {
    let database = database ?? self.database
    return CatalogError.database(String(cString: sqlite3_errmsg(database)))
  }

  private func legacyDatabaseError(_ name: String) -> CatalogError {
    CatalogError.invalidLegacyDatabase(name)
  }

  private func escapedLike(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  private static func defaultSourceKey(for root: URL) -> String {
    let candidate = root.standardizedFileURL
    // The configured legacy source is often its containing ScreenMemoryDB
    // directory, while a candidate tree is passed as its own directory. Look
    // through CaptureLibrary's resolved screenshots path so both forms share
    // one logical source identity before a source switch.
    let imageTree =
      (try? CaptureLibrary(root: candidate))?.screenshots.deletingLastPathComponent()
      ?? candidate
    let names =
      (try? FileManager.default.contentsOfDirectory(
        at: imageTree, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
      .map(\.lastPathComponent) ?? []
    // A Q50 tree is a codec replacement for the legacy image source, not a
    // second history. Keeping the logical key stable lets an explicit source
    // switch update frame paths without duplicating moments or annotations.
    if names.contains("q50-config.json") {
      return "screenmemory.legacy.image-tree"
    }
    if names.contains("notes.sqlite") || names.contains("usage.sqlite")
      || names.contains("text.sqlite")
    {
      return "screenmemory.legacy.image-tree"
    }
    if candidate.lastPathComponent == "CaptureLibrary" {
      return "screenrecall.capture-library"
    }
    return "image-tree.discovered"
  }

  private static func isLegacyScreenMemoryTree(at root: URL) -> Bool {
    guard let library = try? CaptureLibrary(root: root) else { return false }
    let imageTree = library.screenshots.deletingLastPathComponent()
    let names =
      (try? FileManager.default.contentsOfDirectory(
        at: imageTree, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
      .map(\.lastPathComponent) ?? []
    return names.contains("notes.sqlite") || names.contains("usage.sqlite")
      || names.contains("text.sqlite")
  }

  private static func timestampMicros(_ timestamp: TimeInterval) -> Int64 {
    Int64((timestamp * 1_000_000).rounded())
  }

  private static func legacyTimestampMicros(_ value: String) -> Int64? {
    guard let timestamp = Double(value), timestamp.isFinite else { return nil }
    return timestampMicros(timestamp)
  }

  private static func stableID(prefix: String, value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\(prefix):\(digest)"
  }

  private static func sha256(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      try Task.checkCancellation()
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func imageMetadata(at url: URL) -> (width: Int?, height: Int?, codec: String?) {
    let source = CGImageSourceCreateWithURL(
      url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    let properties = source.flatMap {
      CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
    }
    return (
      properties?[kCGImagePropertyPixelWidth] as? Int,
      properties?[kCGImagePropertyPixelHeight] as? Int,
      url.pathExtension.lowercased()
    )
  }

  private static var localCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
  }
}
