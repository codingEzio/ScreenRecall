import CryptoKit
import Foundation
import SQLite3

/// A stable description of an image-tree source. The key is the source identity;
/// `root` is only its current location and may change between synchronizations.
public struct CatalogSource: Equatable, Hashable, Sendable {
  public let key: String
  public let root: URL
  public let domain: String
  public let profile: String

  public init(key: String, root: URL, domain: String, profile: String) {
    self.key = key
    self.root = root
    self.domain = domain
    self.profile = profile
  }
}

public struct CatalogSchemaStatus: Equatable, Sendable {
  public let userVersion: Int
  public let migrationVersions: [Int]
  public let tables: Set<String>

  public init(userVersion: Int, migrationVersions: [Int], tables: Set<String>) {
    self.userVersion = userVersion
    self.migrationVersions = migrationVersions
    self.tables = tables
  }
}

public struct CatalogOwnershipSummary: Equatable, Sendable {
  public let sourceCount: Int
  public let momentCount: Int
  public let frameCount: Int
  public let assetCount: Int
  public let sharedAssetCount: Int
  public let annotationCount: Int
  public let applicationCount: Int
  public let appEventCount: Int

  public init(
    sourceCount: Int, momentCount: Int, frameCount: Int, assetCount: Int,
    sharedAssetCount: Int, annotationCount: Int, applicationCount: Int, appEventCount: Int
  ) {
    self.sourceCount = sourceCount
    self.momentCount = momentCount
    self.frameCount = frameCount
    self.assetCount = assetCount
    self.sharedAssetCount = sharedAssetCount
    self.annotationCount = annotationCount
    self.applicationCount = applicationCount
    self.appEventCount = appEventCount
  }
}

public struct CatalogViewState: Equatable, Sendable {
  public let dayKey: String
  public let timestamp: TimeInterval
  public let displayID: String?

  public init(dayKey: String, timestamp: TimeInterval, displayID: String? = nil) {
    self.dayKey = dayKey
    self.timestamp = timestamp
    self.displayID = displayID
  }
}

enum RecallSchema {
  static let currentVersion = 3

  // Version 1 records the compatibility catalog that shipped before the owned
  // model. It is intentionally kept as a migration, not silently re-created.
  static let migration1SQL = """
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
    """

  // The checksum covers the authoritative v2 operation list. Conditional
  // column additions are executed by `applyV2` so old v1 catalogs can be
  // upgraded without destructive table replacement.
  static let migration2SQL = """
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      checksum TEXT NOT NULL,
      applied_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS moments (
      moment_id TEXT PRIMARY KEY,
      source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      timestamp_us INTEGER NOT NULL,
      timestamp_text TEXT NOT NULL,
      day_key TEXT NOT NULL,
      first_seen REAL NOT NULL,
      last_seen REAL NOT NULL,
      UNIQUE(source_id, timestamp_us)
    );
    CREATE TABLE IF NOT EXISTS assets (
      asset_id TEXT PRIMARY KEY,
      sha256 TEXT UNIQUE,
      byte_count INTEGER NOT NULL,
      width INTEGER,
      height INTEGER,
      codec TEXT,
      status TEXT NOT NULL,
      first_seen REAL NOT NULL,
      last_seen REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS frames (
      frame_id TEXT PRIMARY KEY,
      source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      moment_id TEXT NOT NULL REFERENCES moments(moment_id) ON DELETE CASCADE,
      member_key TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      display_id TEXT,
      asset_id TEXT NOT NULL REFERENCES assets(asset_id),
      status TEXT NOT NULL,
      first_seen REAL NOT NULL,
      last_seen REAL NOT NULL,
      UNIQUE(source_id, relative_path),
      UNIQUE(moment_id, member_key)
    );
    CREATE INDEX IF NOT EXISTS moments_time ON moments(timestamp_us);
    CREATE INDEX IF NOT EXISTS frames_present_time ON frames(status, moment_id);
    CREATE INDEX IF NOT EXISTS frames_asset ON frames(asset_id);
    CREATE TABLE IF NOT EXISTS frame_conflicts (
      conflict_id INTEGER PRIMARY KEY,
      source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      relative_path TEXT NOT NULL,
      existing_frame_id TEXT NOT NULL,
      incoming_frame_id TEXT NOT NULL,
      existing_timestamp_us INTEGER,
      incoming_timestamp_us INTEGER,
      detected_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS applications (
      application_id TEXT PRIMARY KEY,
      identifier TEXT NOT NULL,
      name TEXT NOT NULL,
      UNIQUE(identifier, name)
    );
    CREATE TABLE IF NOT EXISTS app_events (
      event_id TEXT PRIMARY KEY,
      source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      legacy_id INTEGER,
      timestamp_text TEXT NOT NULL,
      timestamp_us INTEGER,
      identifier TEXT NOT NULL,
      name TEXT NOT NULL,
      application_id TEXT REFERENCES applications(application_id),
      conflict_key TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS app_events_time ON app_events(source_id, timestamp_us);
    CREATE TABLE IF NOT EXISTS maintenance_runs (
      run_id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at REAL NOT NULL,
      completed_at REAL,
      source_snapshot TEXT,
      error TEXT
    );
    CREATE TABLE IF NOT EXISTS maintenance_items (
      run_id TEXT NOT NULL REFERENCES maintenance_runs(run_id) ON DELETE CASCADE,
      item_key TEXT NOT NULL,
      source_ref TEXT,
      source_hash TEXT,
      target_hash TEXT,
      parameters TEXT,
      status TEXT NOT NULL,
      error TEXT,
      updated_at REAL NOT NULL,
      PRIMARY KEY(run_id, item_key)
    );
    CREATE INDEX IF NOT EXISTS maintenance_items_status ON maintenance_items(run_id, status);
    """

  static let migration3SQL = """
    CREATE TABLE IF NOT EXISTS view_state (
      state_id INTEGER PRIMARY KEY CHECK(state_id = 1),
      day_key TEXT NOT NULL,
      timestamp REAL NOT NULL,
      display_id TEXT,
      updated_at REAL NOT NULL
    );
    """

  static func prepare(_ database: OpaquePointer) throws {
    let version = try integer(database, "PRAGMA user_version;")
    guard version <= currentVersion else { throw CatalogError.unsupportedSchemaVersion(version) }

    let tables = try tableNames(database)
    if version == 0 {
      if tables.isEmpty || tables == ["sqlite_sequence"] {
        try execute(database, migration1SQL)
      } else {
        try validateCompatibilitySchema(database)
      }
      try execute(database, "PRAGMA user_version = 1;")
    } else if version == 1 {
      try validateCompatibilitySchema(database)
    }

    try applyV2(database)
    try execute(database, "PRAGMA user_version = 2;")
    try applyV3(database)
    try execute(database, "PRAGMA user_version = 3;")
    try verifyChecksums(database)
  }

  static func status(_ database: OpaquePointer) throws -> CatalogSchemaStatus {
    let version = try integer(database, "PRAGMA user_version;")
    let tables = try tableNames(database)
    guard tables.contains("schema_migrations") else {
      return CatalogSchemaStatus(userVersion: version, migrationVersions: [], tables: tables)
    }
    let rows = try integers(database, "SELECT version FROM schema_migrations ORDER BY version;")
    return CatalogSchemaStatus(userVersion: version, migrationVersions: rows, tables: tables)
  }

  private static func applyV2(_ database: OpaquePointer) throws {
    try execute(database, migration2SQL)
    try addColumnIfMissing(database, table: "sources", column: "source_key TEXT")
    try addColumnIfMissing(database, table: "sources", column: "domain TEXT")
    try addColumnIfMissing(database, table: "sources", column: "profile TEXT")
    try addColumnIfMissing(database, table: "annotations", column: "frame_id TEXT")
    try addColumnIfMissing(database, table: "legacy_notes", column: "frame_id TEXT")
    try addColumnIfMissing(database, table: "legacy_usage", column: "timestamp_us INTEGER")
    try execute(
      database,
      """
      UPDATE sources
      SET source_key = 'legacy.catalog.source.' || id,
          domain = COALESCE(domain, 'unknown'), profile = COALESCE(profile, 'legacy-v1')
      WHERE source_key IS NULL;
      """
    )
    try execute(
      database, "CREATE UNIQUE INDEX IF NOT EXISTS sources_source_key ON sources(source_key);")
    try execute(database, "CREATE INDEX IF NOT EXISTS annotations_frame ON annotations(frame_id);")
    try recordMigration(database, version: 1, name: "compatibility-catalog", sql: migration1SQL)
    try recordMigration(database, version: 2, name: "owned-history-model", sql: migration2SQL)
  }

  private static func applyV3(_ database: OpaquePointer) throws {
    try execute(database, migration3SQL)
    try recordMigration(database, version: 3, name: "view-state", sql: migration3SQL)
  }

  private static func verifyChecksums(_ database: OpaquePointer) throws {
    let expected = [1: migration1SQL, 2: migration2SQL, 3: migration3SQL]
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT version, checksum FROM schema_migrations ORDER BY version;", -1,
        &statement, nil) == SQLITE_OK, let statement
    else { throw CatalogError.database(String(cString: sqlite3_errmsg(database))) }
    defer { sqlite3_finalize(statement) }
    var seen = Set<Int>()
    while sqlite3_step(statement) == SQLITE_ROW {
      let version = Int(sqlite3_column_int(statement, 0))
      guard let sql = expected[version], let checksum = sqlite3_column_text(statement, 1) else {
        throw CatalogError.schemaChecksumMismatch(version)
      }
      let actual = String(cString: checksum)
      guard actual == digest(sql) else { throw CatalogError.schemaChecksumMismatch(version) }
      seen.insert(version)
    }
    guard seen == Set(expected.keys) else { throw CatalogError.schemaChecksumMismatch(0) }
  }

  private static func recordMigration(
    _ database: OpaquePointer, version: Int, name: String, sql: String
  ) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "INSERT OR IGNORE INTO schema_migrations(version,name,checksum,applied_at) VALUES(?,?,?,?);",
        -1, &statement, nil) == SQLITE_OK, let statement
    else { throw CatalogError.database(String(cString: sqlite3_errmsg(database))) }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int(statement, 1, Int32(version))
    _ = name.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
    let checksum = digest(sql)
    _ = checksum.withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
    sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw CatalogError.database(String(cString: sqlite3_errmsg(database)))
    }
  }

  private static func validateCompatibilitySchema(_ database: OpaquePointer) throws {
    for (table, columns) in [
      ("sources", ["id", "root_path"]),
      ("captures", ["source_id", "relative_path", "timestamp"]),
      ("annotations", ["source_id", "relative_path", "marked", "note"]),
    ] {
      let names = try columnNames(database, table: table)
      guard !names.isEmpty, Set(columns).isSubset(of: names) else {
        throw CatalogError.unknownSchema(table)
      }
    }
  }

  private static func addColumnIfMissing(
    _ database: OpaquePointer, table: String, column: String
  ) throws {
    let name = column.split(separator: " ", maxSplits: 1).first.map(String.init) ?? column
    guard try !columnNames(database, table: table).contains(name) else { return }
    try execute(database, "ALTER TABLE \(table) ADD COLUMN \(column);")
  }

  private static func tableNames(_ database: OpaquePointer) throws -> Set<String> {
    var result = Set<String>()
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT name FROM sqlite_master WHERE type='table';", -1, &statement, nil)
        == SQLITE_OK,
      let statement
    else { throw CatalogError.database(String(cString: sqlite3_errmsg(database))) }
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
      if let value = sqlite3_column_text(statement, 0) { result.insert(String(cString: value)) }
    }
    return result
  }

  private static func columnNames(_ database: OpaquePointer, table: String) throws -> Set<String> {
    var result = Set<String>()
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil)
        == SQLITE_OK, let statement
    else { throw CatalogError.database(String(cString: sqlite3_errmsg(database))) }
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
      if let value = sqlite3_column_text(statement, 1) { result.insert(String(cString: value)) }
    }
    return result
  }

  private static func integer(_ database: OpaquePointer, _ sql: String) throws -> Int {
    let values = try integers(database, sql)
    guard let value = values.first else { throw CatalogError.database("missing SQLite value") }
    return value
  }

  private static func integers(_ database: OpaquePointer, _ sql: String) throws -> [Int] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement
    else { throw CatalogError.database(String(cString: sqlite3_errmsg(database))) }
    defer { sqlite3_finalize(statement) }
    var result: [Int] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      result.append(Int(sqlite3_column_int64(statement, 0)))
    }
    return result
  }

  private static func execute(_ database: OpaquePointer, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    defer { if let error { sqlite3_free(error) } }
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
      throw CatalogError.database(error.map { String(cString: $0) } ?? "unknown SQLite error")
    }
  }

  private static func digest(_ sql: String) -> String {
    SHA256.hash(data: Data(sql.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
