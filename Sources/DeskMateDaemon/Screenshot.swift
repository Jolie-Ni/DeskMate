import CoreGraphics
import Foundation
import ImageIO
import DeskMateCore
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Screenshot {
    /// Capture the main display via ScreenCaptureKit.
    ///
    /// Throws nothing — a failure here (usually a missing Screen Recording
    /// grant) shouldn't take down the capture loop, so we log and return nil
    /// and let the next tick try again.
    static func capture() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)

            let displayID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first
            else {
                print("[deskmate] no shareable display found")
                return nil
            }

            let config = SCStreamConfiguration()
            let size = targetSize(for: display)
            config.width = size.width
            config.height = size.height
            config.captureResolution = .best
            config.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)

            // Normally a no-op — the config above already asks for the capped
            // size. Kept as a backstop for displays whose pixel dimensions we
            // couldn't read.
            return downscale(image, maxDimension: Config.screenshotMaxDimension) ?? image
        } catch {
            print("[deskmate] screen capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Save as JPEG. Returns the file URL on success.
    static func save(_ image: CGImage, dir: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(stamp).jpg"
        let url = dir.appendingPathComponent(filename)

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1, nil
        ) else { return nil }

        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Config.jpegQuality,
        ]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
    }

    /// ScreenCaptureKit sizes its output in pixels, but `SCDisplay` reports
    /// points. Ask the display mode for real pixel dimensions so a Retina
    /// screen is scaled down from full resolution instead of captured at 1x —
    /// OCR quality depends on it.
    private static func targetSize(for display: SCDisplay) -> (width: Int, height: Int) {
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let pixelWidth = mode?.pixelWidth ?? display.width
        let pixelHeight = mode?.pixelHeight ?? display.height
        guard pixelWidth > 0, pixelHeight > 0 else {
            return (display.width, display.height)
        }

        let maxCurrent = max(pixelWidth, pixelHeight)
        guard maxCurrent > Config.screenshotMaxDimension else {
            return (pixelWidth, pixelHeight)
        }

        let scale = Double(Config.screenshotMaxDimension) / Double(maxCurrent)
        return (
            max(1, Int((Double(pixelWidth) * scale).rounded())),
            max(1, Int((Double(pixelHeight) * scale).rounded()))
        )
    }

    private static func downscale(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let maxCurrent = max(width, height)
        if maxCurrent <= maxDimension { return image }

        let scale = Double(maxDimension) / Double(maxCurrent)
        let newWidth = Int(Double(width) * scale)
        let newHeight = Int(Double(height) * scale)

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }
}
