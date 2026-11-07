import AppKit
import CoreText
import ImageIO
import RecallCore
import SQLite3
import UniformTypeIdentifiers

func milliseconds(_ start: ContinuousClock.Instant) -> Double {
  let duration = start.duration(to: .now).components
  return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
}

func fixture(at root: URL) throws {
  let marker = root.appending(path: ".screenrecall-fixture")
  if FileManager.default.fileExists(atPath: root.path),
    !FileManager.default.fileExists(atPath: marker.path),
    !(try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty
  {
    throw LibraryError.invalidRoot
  }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try Data("Synthetic ScreenRecall library".utf8).write(to: marker)
  let calendar = Calendar(identifier: .gregorian)
  for day in 4...6 {
    let directory = root.appending(path: "screenshots/2026/09/0\(day)/14")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for frame in 0..<30 {
      for monitor in 0..<(day == 6 ? 2 : 1) {
        let date = calendar.date(
          from: DateComponents(year: 2026, month: 9, day: day, hour: 14, minute: frame))!
        let suffix = day == 6 ? "_display-\(monitor)" : ""
        let url = directory.appending(path: "\(Int(date.timeIntervalSince1970))\(suffix).png")
        let width = monitor == 0 ? 1600 : 1000
        let height = monitor == 0 ? 1000 : 1600
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.92, green: 0.94, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.14, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 180, height: height))
        for row in 0..<6 {
          context.setFillColor(CGColor(red: 0.75, green: 0.8, blue: 0.86, alpha: 1))
          context.fill(
            CGRect(
              x: 240, y: 120 + row * 110, width: width - 330 - ((row + frame) % 4) * 40, height: 65)
          )
        }
        context.textPosition = CGPoint(x: 240, y: height - 130)
        let title = NSAttributedString(
          string: "Screen \(monitor + 1)  ·  Frame \(frame + 1)",
          attributes: [
            .font: NSFont.systemFont(ofSize: 36, weight: .semibold),
            .foregroundColor: NSColor.black,
          ])
        CTLineDraw(CTLineCreateWithAttributedString(title), context)
        let destination = CGImageDestinationCreateWithURL(
          url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.unreadableImage }
      }
    }
  }
  let displays = [
    "display-0": RecordingDisplay(
      id: "display-0", name: "Landscape", width: 1600, height: 1000, originX: 0, originY: 0),
    "display-1": RecordingDisplay(
      id: "display-1", name: "Portrait", width: 1000, height: 1600, originX: 1600, originY: 0),
  ]
  try JSONEncoder().encode(displays).write(to: root.appending(path: "screenshots/displays.json"))
  print("fixture_days=3 fixture_moments=90 fixture_images=120")
}

private func ownershipDictionary(_ ownership: CatalogOwnershipSummary) -> [String: Any] {
  [
    "source_count": ownership.sourceCount,
    "moment_count": ownership.momentCount,
    "frame_count": ownership.frameCount,
    "asset_count": ownership.assetCount,
    "annotation_count": ownership.annotationCount,
    "application_count": ownership.applicationCount,
    "app_event_count": ownership.appEventCount,
  ]
}

private func sourceSwitchPreflight(
  legacyRoot: URL, candidateRoot: URL, outputRoot: URL
) async throws {
  let legacyRoot = legacyRoot.standardizedFileURL
  let candidateRoot = candidateRoot.standardizedFileURL
  let outputRoot = outputRoot.standardizedFileURL
  let sourcePaths = [legacyRoot.path, candidateRoot.path]
  guard
    !sourcePaths.contains(where: { outputRoot.path == $0 || outputRoot.path.hasPrefix($0 + "/") })
  else {
    throw LibraryError.invalidRoot
  }

  var isDirectory = ObjCBool(false)
  if FileManager.default.fileExists(atPath: outputRoot.path, isDirectory: &isDirectory) {
    guard isDirectory.boolValue,
      (try FileManager.default.contentsOfDirectory(atPath: outputRoot.path)).isEmpty
    else { throw LibraryError.invalidRoot }
  } else {
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputRoot.path)

  let legacyLibrary = try CaptureLibrary(root: legacyRoot)
  let firstLegacyDay = try await legacyLibrary.days().first
  let firstLegacyCapture: Capture?
  if let firstLegacyDay {
    firstLegacyCapture = try await legacyLibrary.captures(on: firstLegacyDay).first
  } else {
    firstLegacyCapture = nil
  }
  guard let firstLegacyCapture else { throw LibraryError.invalidRoot }

  let databaseURL = outputRoot.appending(path: "catalog.sqlite")
  let catalog = try CaptureCatalog(databaseURL: databaseURL)
  let sourceKey = "screenmemory.legacy.image-tree"
  let source = CatalogSource(
    key: sourceKey, root: legacyRoot, domain: "screenmemory", profile: "legacy")
  let oldSync = try await catalog.synchronize(
    sources: [source], importLegacy: false, hashAssets: false)
  let beforeAnnotation = try await catalog.ownershipSummary()
  try await catalog.saveAnnotation(
    for: firstLegacyCapture, marked: true, note: "source-switch-preflight")

  let candidateSource = CatalogSource(
    key: sourceKey, root: candidateRoot, domain: "screenmemory", profile: "q50")
  let candidateSync = try await catalog.synchronize(
    sources: [candidateSource], importLegacy: false, hashAssets: false)
  let after = try await catalog.ownershipSummary()
  let annotations = try await catalog.annotations(limit: 10)
  let movedAnnotation = annotations.first { $0.note == "source-switch-preflight" }
  let jpegResults = try await catalog.search(".jpeg", limit: 1)
  let webpResults = try await catalog.search(".webp", limit: 1)

  let checks: [String: Bool] = [
    "one_logical_source": after.sourceCount == 1,
    "moments_not_duplicated": oldSync.ownedMoments == candidateSync.ownedMoments
      && beforeAnnotation.momentCount == after.momentCount,
    "candidate_frames_present": after.frameCount == candidateSync.ownedFrames
      && candidateSync.conflicts == 0,
    "annotation_points_to_candidate": movedAnnotation?.capture.url.pathExtension.lowercased()
      == "webp",
    "no_present_legacy_jpeg": jpegResults.isEmpty,
    "candidate_webp_is_searchable_metadata": !webpResults.isEmpty,
    "legacy_usage_and_ocr_not_required": oldSync.preservedUsage == 0
      && oldSync.deferredOCRRows == 0 && candidateSync.preservedUsage == 0
      && candidateSync.deferredOCRRows == 0,
  ]
  let ready = checks.values.allSatisfy { $0 }
  let report: [String: Any] = [
    "status": ready ? "ready" : "needs-review",
    "read_only_formal_source": true,
    "source_key": sourceKey,
    "legacy_root": legacyRoot.path,
    "candidate_root": candidateRoot.path,
    "output_catalog": databaseURL.path,
    "legacy_sync": [
      "indexed_captures": oldSync.indexedCaptures,
      "owned_moments": oldSync.ownedMoments,
      "owned_frames": oldSync.ownedFrames,
      "conflicts": oldSync.conflicts,
    ],
    "candidate_sync": [
      "indexed_captures": candidateSync.indexedCaptures,
      "owned_moments": candidateSync.ownedMoments,
      "owned_frames": candidateSync.ownedFrames,
      "conflicts": candidateSync.conflicts,
    ],
    "before_annotation": ownershipDictionary(beforeAnnotation),
    "after": ownershipDictionary(after),
    "annotation_target": movedAnnotation?.capture.url.path ?? NSNull(),
    "checks": checks,
  ]
  let reportURL = outputRoot.appending(path: "source-switch-preflight.json")
  let data = try JSONSerialization.data(
    withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: reportURL, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
  print(
    "Source-switch preflight \(ready ? "ready" : "needs review"): \(reportURL.path)"
  )
  print(
    "legacy_images=\(oldSync.indexedCaptures) candidate_images=\(candidateSync.indexedCaptures)"
  )
  print("moments_before=\(beforeAnnotation.momentCount) moments_after=\(after.momentCount)")
  print(
    "frames_after=\(after.frameCount) annotation_target=\(movedAnnotation?.capture.url.pathExtension ?? "none")"
  )
  if !ready { exit(1) }
}

private struct CompatibilityAnnotation {
  let relativePath: String
  let marked: Bool
  let note: String
  let updatedAt: TimeInterval
}

private func readCompatibilityAnnotations(from url: URL) throws -> [CompatibilityAnnotation] {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(
      url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
    let database
  else {
    throw CatalogError.cannotOpen(url.path)
  }
  defer { sqlite3_close(database) }

  let sql = """
    SELECT relative_path, marked, note, updated_at
    FROM annotations
    WHERE marked <> 0 OR length(trim(note)) > 0
    ORDER BY updated_at ASC, relative_path ASC;
    """
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
    let statement
  else {
    throw CatalogError.database("無法讀取相容註記資料庫")
  }
  defer { sqlite3_finalize(statement) }

  var result: [CompatibilityAnnotation] = []
  while sqlite3_step(statement) == SQLITE_ROW {
    guard let relative = sqlite3_column_text(statement, 0),
      let note = sqlite3_column_text(statement, 2)
    else { continue }
    let path = String(cString: relative)
    guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
      throw CatalogError.database("相容註記含有不安全路徑")
    }
    result.append(
      CompatibilityAnnotation(
        relativePath: path,
        marked: sqlite3_column_int(statement, 1) != 0,
        note: String(cString: note),
        updatedAt: sqlite3_column_double(statement, 3)))
  }
  return result
}

private func q50RelativePath(for legacyRelativePath: String) -> String {
  let extensionLength = (legacyRelativePath as NSString).pathExtension.count
  guard extensionLength > 0 else { return legacyRelativePath + ".webp" }
  return String(legacyRelativePath.dropLast(extensionLength)) + "webp"
}

private func timestamp(for relativePath: String) throws -> TimeInterval {
  let name = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
  let token = name.split(separator: "_", maxSplits: 1).first.map(String.init) ?? ""
  guard let value = Double(token), value.isFinite, value > 0 else {
    throw CatalogError.database("相容註記無法解析時間: \(relativePath)")
  }
  return value
}

private func adoptQ50(
  compatibilityCatalogURL: URL, formalCatalogURL: URL, q50Root: URL,
  reportURL: URL?
) async throws {
  let annotations = try readCompatibilityAnnotations(from: compatibilityCatalogURL)
  let catalog = try CaptureCatalog(databaseURL: formalCatalogURL)
  let source = CatalogSource(
    key: "screenmemory.legacy.image-tree", root: q50Root,
    domain: "screenmemory", profile: "q50")
  let sync = try await catalog.synchronize(
    sources: [source], importLegacy: false, hashAssets: false)

  var imported = 0
  for annotation in annotations {
    let relative = q50RelativePath(for: annotation.relativePath)
    let imageURL = q50Root.appending(path: "screenshots").appending(path: relative)
    guard FileManager.default.fileExists(atPath: imageURL.path) else {
      throw CatalogError.database("Q50 找不到註記對應檔案: \(relative)")
    }
    try await catalog.saveAnnotation(
      for: Capture(url: imageURL, timestamp: try timestamp(for: relative)),
      marked: annotation.marked, note: annotation.note, updatedAt: annotation.updatedAt)
    imported += 1
  }

  let ownership = try await catalog.ownershipSummary()
  let moved = try await catalog.annotations(limit: max(10, imported))
  let checks: [String: Bool] = [
    "indexed_q50_frames": sync.ownedFrames == 224908 && sync.conflicts == 0,
    "annotations_imported": ownership.annotationCount == imported,
    "annotations_point_to_q50": moved.allSatisfy {
      $0.sourceRoot.standardizedFileURL == q50Root.standardizedFileURL
        && $0.capture.url.pathExtension.lowercased() == "webp"
    },
  ]
  let ready = checks.values.allSatisfy { $0 }
  let output: [String: Any] = [
    "status": ready ? "ready" : "needs-review",
    "compatibility_catalog": compatibilityCatalogURL.path,
    "formal_catalog": formalCatalogURL.path,
    "q50_root": q50Root.path,
    "indexed_captures": sync.indexedCaptures,
    "owned_frames": sync.ownedFrames,
    "conflicts": sync.conflicts,
    "imported_annotations": imported,
    "ownership": ownershipDictionary(ownership),
    "checks": checks,
  ]
  if let reportURL {
    try FileManager.default.createDirectory(
      at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: reportURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
  }
  print("Q50 adoption \(ready ? "ready" : "needs review")")
  print("indexed=\(sync.indexedCaptures) owned_frames=\(sync.ownedFrames) annotations=\(imported)")
  if !ready { exit(1) }
}

private func mergeOwnedSource(
  catalogURL: URL, retiredRoot: URL, destinationRoot: URL, reportURL: URL?
) async throws {
  let catalog = try CaptureCatalog(databaseURL: catalogURL)
  let merged = try await catalog.mergeSource(from: retiredRoot, into: destinationRoot)
  let ownership = try await catalog.ownershipSummary()
  let output: [String: Any] = [
    "status": "merged",
    "catalog": catalogURL.path,
    "retired_root": retiredRoot.standardizedFileURL.path,
    "destination_root": destinationRoot.standardizedFileURL.path,
    "source_id": merged.sourceID,
    "destination_id": merged.destinationID,
    "merged_moments": merged.mergedMoments,
    "merged_frames": merged.mergedFrames,
    "ownership": ownershipDictionary(ownership),
  ]
  if let reportURL {
    try FileManager.default.createDirectory(
      at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: reportURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
  }
  print("Owned source merge complete")
  print(
    "retired_source=\(merged.sourceID) destination_source=\(merged.destinationID) "
      + "moments=\(merged.mergedMoments) frames=\(merged.mergedFrames)"
  )
  print(
    "sources=\(ownership.sourceCount) moments=\(ownership.momentCount) "
      + "frames=\(ownership.frameCount) annotations=\(ownership.annotationCount)"
  )
}

private func synchronizeOwnedLibrary(catalogURL: URL, root: URL) async throws {
  let catalog = try CaptureCatalog(databaseURL: catalogURL)
  let sync = try await catalog.synchronize(
    roots: [root.standardizedFileURL], importLegacy: false, hashAssets: false)
  let ownership = try await catalog.ownershipSummary()
  print(
    "Owned library sync complete: indexed=\(sync.indexedCaptures) "
      + "unchanged=\(sync.unchangedPaths) added=\(sync.addedPaths) "
      + "changed=\(sync.changedPaths) missing=\(sync.missingPaths) "
      + "conflicts=\(sync.conflicts) walk_ms=\(Int(sync.walkMilliseconds.rounded())) "
      + "write_ms=\(Int(sync.writeMilliseconds.rounded())) "
      + "wal_before=\(sync.walBytesBefore) wal_after=\(sync.walBytesAfter)"
  )
  guard ownership.sourceCount == 1, sync.conflicts == 0 else { exit(1) }
}

private func syncDictionary(_ sync: CatalogSyncSummary) -> [String: Any] {
  [
    "indexed_captures": sync.indexedCaptures,
    "owned_moments": sync.ownedMoments,
    "owned_frames": sync.ownedFrames,
    "conflicts": sync.conflicts,
    "inspected_paths": sync.inspectedPaths,
    "unchanged_paths": sync.unchangedPaths,
    "added_paths": sync.addedPaths,
    "changed_paths": sync.changedPaths,
    "missing_paths": sync.missingPaths,
    "walk_ms": sync.walkMilliseconds,
    "write_ms": sync.writeMilliseconds,
    "total_ms": sync.totalMilliseconds,
    "catalog_bytes_before": sync.catalogBytesBefore,
    "catalog_bytes_after": sync.catalogBytesAfter,
    "wal_bytes_before": sync.walBytesBefore,
    "wal_bytes_after": sync.walBytesAfter,
  ]
}

private func measureCatalogBaseline(
  liveCatalog: URL, imageRoot: URL, outputRoot: URL
) async throws {
  let liveCatalog = liveCatalog.standardizedFileURL
  let imageRoot = imageRoot.standardizedFileURL
  let outputRoot = outputRoot.standardizedFileURL
  if FileManager.default.fileExists(atPath: outputRoot.path) {
    throw LibraryError.invalidRoot
  }
  try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputRoot.path)

  let copyURL = outputRoot.appending(path: "catalog.sqlite")
  let backupStart = ContinuousClock.now
  try CaptureCatalog.backup(from: liveCatalog, to: copyURL)
  let backupMS = milliseconds(backupStart)
  let copied = CaptureCatalog.storageBytes(at: copyURL)

  let library = try CaptureLibrary(root: imageRoot)
  let daysStart = ContinuousClock.now
  let days = try await library.days()
  let daysMS = milliseconds(daysStart)

  let catalog = try CaptureCatalog(databaseURL: copyURL)
  let ownership = try await catalog.ownershipSummary()
  let dayCounts = try await catalog.dayMomentCounts()
  func probe(_ folderID: String) async throws -> [String: Any] {
    guard let day = days.first(where: { $0.id == folderID }) else {
      return ["folder_id": folderID, "missing": true]
    }
    let start = ContinuousClock.now
    let captures = try await library.captures(on: day)
    return [
      "folder_id": folderID,
      "catalog_day_key": day.catalogDayKey,
      "frames": captures.count,
      "milliseconds": milliseconds(start),
    ]
  }

  let ranked = dayCounts.sorted { $0.count < $1.count }
  let small = ranked.first
  let large = ranked.last
  let median = ranked.isEmpty ? nil : ranked[ranked.count / 2]
  let smallProbe =
    small == nil ? nil : try await probe(CaptureDay.folderID(fromCatalogDayKey: small!.dayKey))
  let medianProbe =
    median == nil ? nil : try await probe(CaptureDay.folderID(fromCatalogDayKey: median!.dayKey))
  let largeProbe =
    large == nil ? nil : try await probe(CaptureDay.folderID(fromCatalogDayKey: large!.dayKey))

  print("Measuring full synchronize against the catalog copy only…")
  let sync = try await catalog.synchronize(
    roots: [imageRoot], importLegacy: false, hashAssets: false, mode: .full)
  let after = try await catalog.storageBytes()
  let report: [String: Any] = [
    "status": "baseline",
    "wrote_live_catalog": false,
    "backup_ms": backupMS,
    "copied_catalog_bytes": copied.catalog,
    "copied_wal_bytes": copied.wal,
    "browser_ready": [
      "date_walk_ms": daysMS,
      "recorded_days": days.count,
      "small_day": smallProbe as Any,
      "median_day": medianProbe as Any,
      "large_day": largeProbe as Any,
    ],
    "background_index": syncDictionary(sync),
    "ownership": ownershipDictionary(ownership),
    "after_copy_catalog_bytes": after.catalog,
    "after_copy_wal_bytes": after.wal,
  ]
  let reportURL = outputRoot.appending(path: "baseline.json")
  let data = try JSONSerialization.data(
    withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: reportURL, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
  print("Catalog baseline written: \(reportURL.path)")
  print(
    "browser_date_walk_ms=\(Int(daysMS.rounded())) days=\(days.count) "
      + "index_walk_ms=\(Int(sync.walkMilliseconds.rounded())) "
      + "index_write_ms=\(Int(sync.writeMilliseconds.rounded()))"
  )
}

let args = CommandLine.arguments
guard args.count >= 3 else {
  print("Usage: RecallCheck --benchmark|--audit|--fixture <library-folder>")
  print(
    "       RecallCheck --migration-audit <ScreenMemoryData> <new-output-directory> [--hash-images]"
  )
  print(
    "       RecallCheck --migration-sample <ScreenMemoryData> <manifest.sqlite> <new-output-directory>"
  )
  print("       RecallCheck --catalog-status <catalog.sqlite>")
  print(
    "       RecallCheck --source-switch-preflight <legacy-root> <q50-root> <new-output-directory>"
  )
  print(
    "       RecallCheck --adopt-q50 <compatibility-catalog> <formal-catalog> <q50-root> [report.json]"
  )
  print(
    "       RecallCheck --merge-owned-source <catalog.sqlite> <retired-root> <destination-root> [report.json]"
  )
  print("       RecallCheck --sync-owned <catalog.sqlite> <owned-root>")
  print(
    "       RecallCheck --measure-catalog <live-catalog.sqlite> <image-root> <new-output-directory>"
  )
  exit(2)
}
if args[1] == "--source-switch-preflight" {
  guard args.count == 5 else { exit(2) }
  try await sourceSwitchPreflight(
    legacyRoot: URL(fileURLWithPath: args[2]),
    candidateRoot: URL(fileURLWithPath: args[3]),
    outputRoot: URL(fileURLWithPath: args[4]))
  exit(0)
}
if args[1] == "--adopt-q50" {
  guard args.count == 5 || args.count == 6 else { exit(2) }
  try await adoptQ50(
    compatibilityCatalogURL: URL(fileURLWithPath: args[2]),
    formalCatalogURL: URL(fileURLWithPath: args[3]),
    q50Root: URL(fileURLWithPath: args[4]),
    reportURL: args.count == 6 ? URL(fileURLWithPath: args[5]) : nil)
  exit(0)
}
if args[1] == "--merge-owned-source" {
  guard args.count == 5 || args.count == 6 else { exit(2) }
  try await mergeOwnedSource(
    catalogURL: URL(fileURLWithPath: args[2]),
    retiredRoot: URL(fileURLWithPath: args[3]),
    destinationRoot: URL(fileURLWithPath: args[4]),
    reportURL: args.count == 6 ? URL(fileURLWithPath: args[5]) : nil)
  exit(0)
}
if args[1] == "--sync-owned" {
  guard args.count == 4 else { exit(2) }
  try await synchronizeOwnedLibrary(
    catalogURL: URL(fileURLWithPath: args[2]), root: URL(fileURLWithPath: args[3]))
  exit(0)
}
if args[1] == "--measure-catalog" {
  guard args.count == 5 else { exit(2) }
  try await measureCatalogBaseline(
    liveCatalog: URL(fileURLWithPath: args[2]),
    imageRoot: URL(fileURLWithPath: args[3]),
    outputRoot: URL(fileURLWithPath: args[4]))
  exit(0)
}
let root = URL(fileURLWithPath: args[2])
if args[1] == "--catalog-status" {
  guard args.count == 3 else { exit(2) }
  let catalog = try CaptureCatalog(databaseURL: root)
  let schema = try await catalog.schemaStatus()
  let ownership = try await catalog.ownershipSummary()
  let output: [String: Any] = [
    "user_version": schema.userVersion,
    "migration_versions": schema.migrationVersions,
    "tables": schema.tables.sorted(),
    "sources": ownership.sourceCount,
    "moments": ownership.momentCount,
    "frames": ownership.frameCount,
    "assets": ownership.assetCount,
    "shared_assets": ownership.sharedAssetCount,
    "annotations": ownership.annotationCount,
    "applications": ownership.applicationCount,
    "app_events": ownership.appEventCount,
  ]
  let data = try JSONSerialization.data(
    withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
  print(String(decoding: data, as: UTF8.self))
} else if args[1] == "--migration-sample" {
  guard args.count == 5 else { exit(2) }
  let samples = try MigrationAudit.sampleCompression(
    source: root, manifest: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4]))
  print("Created \(samples.count) private compression samples: \(args[4])/index.html")
} else if args[1] == "--migration-audit" {
  guard args.count == 4 || (args.count == 5 && args[4] == "--hash-images") else { exit(2) }
  let summary = try MigrationAudit.run(
    source: root, output: URL(fileURLWithPath: args[3]), hashImages: args.contains("--hash-images"))
  print("Audited \(summary.imageCount) images; report: \(args[3])/summary.json")
} else if args[1] == "--fixture" {
  try fixture(at: root)
} else {
  let begin = ContinuousClock.now
  let library = try CaptureLibrary(root: root)
  let days = try await library.days()
  let catalogMS = milliseconds(begin)
  guard let day = days.last else { throw LibraryError.invalidRoot }
  let dayStart = ContinuousClock.now
  let captures = try await library.captures(on: day)
  let dayMS = milliseconds(dayStart)
  guard let last = captures.last else { throw LibraryError.unreadableImage }
  let images = ImageStore()
  let previewStart = ContinuousClock.now
  _ = try await images.image(at: last.url, maxPixels: 1280)
  let previewMS = milliseconds(previewStart)
  let firstReadyMS = milliseconds(begin)
  var decodes: [Double] = []
  for capture in captures.suffix(30).reversed() {
    let start = ContinuousClock.now
    _ = try await images.image(at: capture.url, maxPixels: 1280)
    decodes.append(milliseconds(start))
  }
  let cachedStart = ContinuousClock.now
  _ = try await images.image(at: last.url, maxPixels: 1280)
  let cachedMS = milliseconds(cachedStart)
  let seekStart = ContinuousClock.now
  var checksum = 0
  for step in 0..<10000 {
    let time =
      captures[0].timestamp + (last.timestamp - captures[0].timestamp) * Double(step) / 9999
    checksum += Timeline.nearest(to: time, in: captures) ?? 0
  }
  let seekMS = milliseconds(seekStart)
  var scrubDecodes: [Double] = []
  for capture in captures.suffix(30).reversed() {
    let start = ContinuousClock.now
    _ = try await images.image(at: capture.url, maxPixels: 640)
    scrubDecodes.append(milliseconds(start))
  }
  var result: [String: Any] = [
    "days": days.count, "latest_day_images": captures.count, "catalog_ms": catalogMS,
    "latest_day_metadata_ms": dayMS, "first_preview_decode_ms": previewMS,
    "catalog_to_first_preview_ms": firstReadyMS, "cached_preview_ms": cachedMS,
    "preview_sample_count": decodes.count,
    "preview_decode_p95_ms": decodes.sorted()[Int(Double(decodes.count - 1) * 0.95)],
    "seek_10000_ms": seekMS, "seek_checksum": checksum,
    "scrub_decode_p95_ms": scrubDecodes.sorted()[Int(Double(scrubDecodes.count - 1) * 0.95)],
    "screen_max_hz": await MainActor.run { NSScreen.screens.map(\.maximumFramesPerSecond) },
  ]
  if args[1] == "--audit" {
    var total = 0
    var sampleCount = 0
    for day in days {
      let captures = try await library.captures(on: day)
      total += captures.count
      if let sample = captures.first {
        _ = try await images.image(at: sample.url, maxPixels: 256)
        sampleCount += 1
      }
    }
    result["readable_image_records"] = total
    result["decoded_daily_samples"] = sampleCount
  }
  let data = try JSONSerialization.data(
    withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
  print(String(decoding: data, as: UTF8.self))
}
