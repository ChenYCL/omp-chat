#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import OMPChatUI

/// The snapshot SDK draws a window's view tree instead of reading the screen.
/// These check that SwiftUI content really ends up in the PNG — a blank image
/// is the failure this approach is known for — and that a window which was
/// never put on screen still renders.
@MainActor
final class AppSnapshotTests: XCTestCase {
    private func window(_ content: some View, size: CGSize = CGSize(width: 200, height: 120)) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        return window
    }

    private func pixel(_ png: Data, atFraction point: CGPoint) throws -> (r: Int, g: Int, b: Int) {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let x = Int(CGFloat(rep.pixelsWide) * point.x)
        let y = Int(CGFloat(rep.pixelsHigh) * point.y)
        let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    func testOffscreenSwiftUIContentIsDrawn() throws {
        // Never ordered front: the case "the app is behind everything" relies on.
        let png = try XCTUnwrap(AppSnapshot.png(of: window(Color(red: 1, green: 0, blue: 0))))
        let center = try pixel(png, atFraction: CGPoint(x: 0.5, y: 0.6))
        // Channels come out in the display's colour space (pure red reads about
        // 255/74/…), so check the colour dominates rather than exact values. A
        // blank render would be transparent or white, never this.
        XCTAssertGreaterThan(center.r, 200, "SwiftUI 内容应画进 PNG，不能是空白：\(center)")
        XCTAssertGreaterThan(center.r - max(center.g, center.b), 120, "应明显是红色：\(center)")
    }

    func testTwoHalvesKeepTheirColours() throws {
        // A layout check, not just "something was drawn": left blue, right green.
        let content = HStack(spacing: 0) {
            Color(red: 0, green: 0, blue: 1)
            Color(red: 0, green: 1, blue: 0)
        }
        let png = try XCTUnwrap(AppSnapshot.png(of: window(content)))
        let left = try pixel(png, atFraction: CGPoint(x: 0.25, y: 0.6))
        let right = try pixel(png, atFraction: CGPoint(x: 0.75, y: 0.6))
        XCTAssertGreaterThan(left.b, 200, "左半应是蓝色：\(left)")
        XCTAssertGreaterThan(right.g, 200, "右半应是绿色：\(right)")
    }

    func testImageIsAtLeastTheWindowSize() throws {
        let png = try XCTUnwrap(AppSnapshot.png(of: window(Color.red, size: CGSize(width: 300, height: 180))))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertGreaterThanOrEqual(rep.pixelsWide, 300, "不能比窗口还小")
        XCTAssertGreaterThanOrEqual(rep.pixelsHigh, 180)
    }
}
#endif
