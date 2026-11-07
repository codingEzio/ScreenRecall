import CWebP
import CoreGraphics
import Foundation

/// Matches the benchmark's libwebp default method and quality, in-process.
/// Normalizing to opaque sRGB makes capture color space independent of the display.
enum WebPEncoding {
  static func data(image: CGImage, quality: Double) throws -> Data {
    guard quality.isFinite, (0...1).contains(quality),
      image.width > 0, image.height > 0, image.width <= 16_383, image.height <= 16_383,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue),
      let pixels = context.data
    else { throw CaptureRecorderError.imageEncodingFailed }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(bounds)
    context.draw(image, in: bounds)
    var output: UnsafeMutablePointer<UInt8>?
    let count = WebPEncodeRGBA(
      pixels.assumingMemoryBound(to: UInt8.self),
      Int32(image.width), Int32(image.height), Int32(context.bytesPerRow), Float(quality * 100),
      &output)
    guard count > 0, let output else { throw CaptureRecorderError.imageEncodingFailed }
    defer { WebPFree(output) }
    return Data(bytes: output, count: count)
  }
}
