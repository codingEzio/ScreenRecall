import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import RecallCore

@Test func previewDownsamplesWithoutChangingSource() async throws {
  let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
  defer { try? FileManager.default.removeItem(at: url) }
  let context = try #require(
    CGContext(
      data: nil, width: 1800, height: 900, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  let image = try #require(context.makeImage())
  let destination = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
  let original = try Data(contentsOf: url)
  let store = ImageStore()
  let preview = try await store.image(at: url, maxPixels: 256)
  #expect(preview.image.width == 256)
  #expect(preview.image.height == 128)
  #expect(preview.originalWidth == 1800)
  let full = try await store.image(at: url, maxPixels: 0)
  #expect(full.image.width == 1800)
  #expect(try Data(contentsOf: url) == original)
}

@Test func thumbnailCacheWritesADownsampledCopyForLaterHits() async throws {
  let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appending(path: "source.png")
  let thumbs = folder.appending(path: "thumbs")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let context = try #require(
    CGContext(
      data: nil, width: 1800, height: 900, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  let image = try #require(context.makeImage())
  let destination = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
  let store = ImageStore(diskRoot: thumbs)
  let preview = try await store.image(at: url, maxPixels: 1280)
  #expect(preview.image.width == 1280)
  await store.clear()
  let cached = try FileManager.default.contentsOfDirectory(atPath: thumbs.path)
  #expect(cached.contains { $0.hasSuffix(".jpg") })
  let thumb = try await store.image(at: url, maxPixels: 256)
  #expect(thumb.image.width == 256)
  #expect(thumb.originalWidth == 1800)
}

@Test func thumbnailCacheNeverRewritesTheSourceAndStopsWhenOverBudget() async throws {
  let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appending(path: "source.png")
  let thumbs = folder.appending(path: "thumbs")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let context = try #require(
    CGContext(
      data: nil, width: 1800, height: 900, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  let image = try #require(context.makeImage())
  let destination = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
  let original = try Data(contentsOf: url)
  let store = ImageStore(diskRoot: thumbs, thumbnailBudgetBytes: 1)
  _ = try await store.image(at: url, maxPixels: 256)
  #expect(try Data(contentsOf: url) == original)
  let cached = (try? FileManager.default.contentsOfDirectory(atPath: thumbs.path)) ?? []
  #expect(!cached.contains { $0.hasSuffix(".jpg") })
}

@Test func missingImageFailsWithoutPoisoningCache() async {
  let store = ImageStore()
  await #expect(throws: (any Error).self) {
    try await store.image(at: URL(fileURLWithPath: "/missing-image.png"), maxPixels: 256)
  }
}
