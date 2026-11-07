import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DecodedImage: Sendable {
  public let image: CGImage
  public let originalWidth: Int
  public let originalHeight: Int
}

private final class ImageBox: @unchecked Sendable {
  let value: DecodedImage
  init(_ value: DecodedImage) { self.value = value }
}

private final class MemoryImageCache: @unchecked Sendable {
  private let cache = NSCache<NSString, ImageBox>()

  init(megabytes: Int) {
    cache.totalCostLimit = max(1, megabytes) * 1024 * 1024
  }

  func object(forKey key: NSString) -> DecodedImage? {
    cache.object(forKey: key)?.value
  }

  func set(_ value: DecodedImage, forKey key: NSString, cost: Int) {
    cache.setObject(ImageBox(value), forKey: key, cost: cost)
  }

  func removeAll() { cache.removeAllObjects() }
}

private final class ThumbnailDiskGate: @unchecked Sendable {
  private let lock = NSLock()
  private var disabled = false
  private var measured: Int64 = 0
  private var writesSinceMeasure = 32
  private let budget: Int64
  private let root: URL?

  init(root: URL?, budget: Int64) {
    self.root = root
    self.budget = max(0, budget)
  }

  func allow(incoming: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !disabled, let root, budget > 0 else { return false }
    writesSinceMeasure += 1
    if writesSinceMeasure >= 32 {
      measured = Self.directoryBytes(root)
      writesSinceMeasure = 0
    }
    if measured + Int64(incoming) > budget {
      disabled = true
      return false
    }
    measured += Int64(incoming)
    return true
  }

  func disable() {
    lock.lock()
    disabled = true
    lock.unlock()
  }

  private static func directoryBytes(_ root: URL) -> Int64 {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
    else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
      total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
  }
}

/// Admission is FIFO. Cancelled requests leave the queue before a decode starts.
actor DecodeLimiter {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
  }
  private var running = 0
  private var waiting: [Waiter] = []
  private let limit: Int

  init(limit: Int) { self.limit = max(1, limit) }
  var queuedCount: Int { waiting.count }

  func acquire() async throws {
    try Task.checkCancellation()
    if running < limit {
      running += 1
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiting.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
    // A release may win the race with cancellation. Return that permit exactly once.
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
  }

  private func cancel(_ id: UUID) {
    guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
    waiting.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  func release() {
    if waiting.isEmpty {
      running = max(0, running - 1)
    } else {
      waiting.removeFirst().continuation.resume()
    }
  }
}

/// Decoding is concurrent and bounded. The cache never writes source images.
public actor ImageStore {
  public static let thumbnailPixels = 256
  public static let defaultCacheMegabytes = 192
  public static let maximumDecodeWorkers = 4
  public nonisolated let cacheBudgetMegabytes: Int
  public static let defaultThumbnailBudgetBytes: Int64 = 512 * 1024 * 1024
  nonisolated private let cache: MemoryImageCache
  nonisolated private let diskRoot: URL?
  nonisolated private let thumbGate: ThumbnailDiskGate
  private let limiter = DecodeLimiter(limit: ImageStore.maximumDecodeWorkers)

  public init(
    cacheMegabytes: Int = ImageStore.defaultCacheMegabytes, diskRoot: URL? = nil,
    thumbnailBudgetBytes: Int64 = ImageStore.defaultThumbnailBudgetBytes
  ) {
    cacheBudgetMegabytes = max(1, cacheMegabytes)
    cache = MemoryImageCache(megabytes: cacheBudgetMegabytes)
    self.diskRoot = diskRoot
    self.thumbGate = ThumbnailDiskGate(root: diskRoot, budget: thumbnailBudgetBytes)
  }

  public func clear() {
    cache.removeAll()
  }

  nonisolated public func cached(at url: URL, maxPixels: Int) -> DecodedImage? {
    cache.object(forKey: cacheKey(url, maxPixels))
  }

  nonisolated public func cachedPreview(at url: URL) -> DecodedImage? {
    cached(at: url, maxPixels: 1280) ?? cached(at: url, maxPixels: 640)
      ?? cached(at: url, maxPixels: Self.thumbnailPixels)
  }

  public func image(at url: URL, maxPixels: Int) async throws -> DecodedImage {
    try Task.checkCancellation()
    if let cached = cached(at: url, maxPixels: maxPixels) { return cached }
    try await limiter.acquire()
    do {
      try Task.checkCancellation()
      let worker = Task.detached(priority: .userInitiated) { [self] in
        try Task.checkCancellation()
        if let cached = cached(at: url, maxPixels: maxPixels) { return cached }
        if maxPixels <= Self.thumbnailPixels,
          let disk = Self.readThumbnail(url: url, root: diskRoot)
        {
          try Task.checkCancellation()
          remember(disk, at: url, maxPixels: Self.thumbnailPixels)
          return disk
        }
        let decoded = try Self.decode(url: url, maxPixels: maxPixels)
        try Task.checkCancellation()
        remember(decoded, at: url, maxPixels: maxPixels)
        rememberThumbnail(decoded, for: url)
        return decoded
      }
      let decoded = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      try Task.checkCancellation()
      await limiter.release()
      return decoded
    } catch {
      await limiter.release()
      throw error
    }
  }

  nonisolated private func remember(_ decoded: DecodedImage, at url: URL, maxPixels: Int) {
    cache.set(
      decoded, forKey: cacheKey(url, maxPixels),
      cost: decoded.image.bytesPerRow * decoded.image.height)
  }

  nonisolated private func rememberThumbnail(_ decoded: DecodedImage, for url: URL) {
    guard let thumb = Self.downsampled(decoded.image, maxPixels: Self.thumbnailPixels) else {
      return
    }
    let value = DecodedImage(
      image: thumb, originalWidth: decoded.originalWidth, originalHeight: decoded.originalHeight)
    remember(value, at: url, maxPixels: Self.thumbnailPixels)
    writeThumbnail(value, for: url)
  }

  nonisolated private func cacheKey(_ url: URL, _ maxPixels: Int) -> NSString {
    "\(url.path)|\(maxPixels)" as NSString
  }

  nonisolated private static func decode(url: URL, maxPixels: Int) throws -> DecodedImage {
    try Task.checkCancellation()
    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 32768, height <= 32768
    else { throw LibraryError.unreadableImage }
    let requested = maxPixels == 0 ? max(width, height) : max(128, maxPixels)
    let limit = min(requested, 8192)
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: limit,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw LibraryError.unreadableImage }
    try Task.checkCancellation()
    return DecodedImage(image: image, originalWidth: width, originalHeight: height)
  }

  nonisolated private static func downsampled(_ image: CGImage, maxPixels: Int) -> CGImage? {
    let longest = max(image.width, image.height)
    guard longest > maxPixels else { return image }
    let scale = CGFloat(maxPixels) / CGFloat(longest)
    let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
    let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  nonisolated private static func sourceFingerprint(_ url: URL) -> (TimeInterval, Int)? {
    let values = try? url.resourceValues(forKeys: [
      .contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey,
    ])
    guard values?.isSymbolicLink != true, let size = values?.fileSize, size > 0 else { return nil }
    let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    return (mtime, size)
  }

  nonisolated private static func thumbnailURL(
    for url: URL, root: URL, mtime: TimeInterval, bytes: Int
  ) -> URL {
    let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return root.appending(path: "\(hex).\(Int(mtime * 1000)).\(bytes).\(thumbnailPixels).jpg")
  }

  nonisolated private static func readThumbnail(url: URL, root: URL?) -> DecodedImage? {
    guard let root, let fingerprint = sourceFingerprint(url) else { return nil }
    let file = thumbnailURL(for: url, root: root, mtime: fingerprint.0, bytes: fingerprint.1)
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    guard
      let source = CGImageSourceCreateWithURL(file as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    var originalWidth = image.width
    var originalHeight = image.height
    if let original = CGImageSourceCreateWithURL(
      url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    {
      originalWidth = width
      originalHeight = height
    }
    return DecodedImage(image: image, originalWidth: originalWidth, originalHeight: originalHeight)
  }

  nonisolated private func writeThumbnail(_ decoded: DecodedImage, for url: URL) {
    guard let root = diskRoot, let fingerprint = Self.sourceFingerprint(url) else { return }
    let file = Self.thumbnailURL(
      for: url, root: root, mtime: fingerprint.0, bytes: fingerprint.1)
    if FileManager.default.fileExists(atPath: file.path) { return }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(
      destination, decoded.image,
      [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return }
    guard thumbGate.allow(incoming: data.count) else { return }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      try data.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
      thumbGate.disable()
    }
  }
}
