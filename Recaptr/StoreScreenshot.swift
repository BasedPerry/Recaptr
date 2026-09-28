//
//  StoreScreenshot.swift
//  Recaptr
//
//  Debug-only App Store screenshots: the main window at 1440×900 points,
//  captured at 2880×1800 pixels.
//

#if DEBUG
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum StoreScreenshot {
    static let size = CGSize(width: 1440, height: 900)

    /// The capture window: the largest visible titled window that isn't a panel.
    private static var mainWindow: NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    static func sizeWindow() {
        guard let window = mainWindow else { return }
        window.setContentSize(size)
        window.center()
    }

    /// Saves a PNG to `<save folder>/Store Screenshots/` and returns its URL.
    static func capture(into saveDir: URL) async throws -> URL {
        guard let window = mainWindow else { throw CaptureError.unsupported("No window") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CaptureError.unsupported("Window isn't on screen")
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        // The store rejects transparency, so flatten the rounded corners onto black.
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CaptureError.unsupported("Couldn't flatten the image")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.black)
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { throw CaptureError.unsupported("Couldn't flatten the image") }

        let folder = saveDir.appendingPathComponent("Store Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("Recaptr_Store_\(stamp)_\(image.width)x\(image.height).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.unsupported("Couldn't write the PNG")
        }
        CGImageDestinationAddImage(dest, flat, nil)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.unsupported("Couldn't write the PNG") }
        return url
    }
}
#endif
