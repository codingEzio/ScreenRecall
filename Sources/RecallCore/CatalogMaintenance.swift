import Foundation
import SQLite3

public enum CatalogMaintenance {
  public static let keepLast = 3
  public static let autoPrefix = "auto-"

  /// Copies a consistent catalog snapshot for the local day if one is not already present.
  /// Only `auto-*` folders are pruned. Manual recovery folders are left untouched.
  /// A failed snapshot is removed; the source catalog is never deleted.
  @discardableResult
  public static func snapshotIfDue(
    from catalog: URL, into maintenanceRoot: URL, now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian), keepLast: Int = keepLast
  ) throws -> URL? {
    var calendar = calendar
    calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
    let parts = calendar.dateComponents([.year, .month, .day], from: now)
    guard let year = parts.year, let month = parts.month, let day = parts.day else {
      throw CatalogError.database("snapshot date is invalid")
    }
    let name = String(format: "%@%04d-%02d-%02d", autoPrefix, year, month, day)
    let folder = maintenanceRoot.appending(path: name, directoryHint: .isDirectory)
    let destination = folder.appending(path: "catalog.sqlite")
    if FileManager.default.fileExists(atPath: destination.path) { return nil }
    guard FileManager.default.fileExists(atPath: catalog.path) else { return nil }

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    do {
      try CaptureCatalog.backup(from: catalog, to: destination)
      guard try CaptureCatalog.integrityOK(at: destination) else {
        try? FileManager.default.removeItem(at: folder)
        throw CatalogError.database("snapshot failed integrity_check")
      }
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
    try pruneAutoSnapshots(in: maintenanceRoot, keepLast: keepLast)
    return destination
  }

  public static func pruneAutoSnapshots(in maintenanceRoot: URL, keepLast: Int) throws {
    let keep = max(1, keepLast)
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: maintenanceRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []
    let autos = contents.filter { url in
      url.lastPathComponent.hasPrefix(autoPrefix)
        && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard autos.count > keep else { return }
    for extra in autos.prefix(autos.count - keep) {
      try FileManager.default.removeItem(at: extra)
    }
  }
}
