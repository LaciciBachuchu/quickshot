import AppKit
import ScreenCaptureKit

// 冻结画面：按下快捷键的那一刻用 ScreenCaptureKit 把每块屏幕整屏拍下来，
// 选区遮罩显示这张冻结画面，松手后从里面裁剪结果——这样弹出菜单、下拉框即使随后关掉也能截到。
//
// 拍屏用 captureImage(in:)：实测约 30ms，是排除窗口的整屏过滤器方式（70~130ms）的一半不到。
// 它不能排除 QuickShot 自己的窗口，所以拍屏时遮罩先保持完全透明，拍完再显示（见 SelectionOverlay.begin）。
//
// 右键截窗口：窗口本身单独渲染（被其他窗口挡住的部分也完整），
// 窗口上展开的菜单、下拉框从冻结画面里取出来叠上去。

struct FrozenScreen {
    let displayID: CGDirectDisplayID
    let image: CGImage
    let frame: CGRect      // 全局坐标，左上角为原点（点）
    let scale: CGFloat     // 每点多少像素
}

enum ScreenFreezer {
    // 所有屏幕并行拍一张；screens 是（显示器编号，全局坐标里的屏幕范围）
    static func captureAll(_ screens: [(CGDirectDisplayID, CGRect)]) async -> [FrozenScreen] {
        await withTaskGroup(of: FrozenScreen?.self) { group in
            for (id, frame) in screens {
                group.addTask {
                    guard let img = try? await SCScreenshotManager.captureImage(in: frame), frame.width > 0 else { return nil }
                    return FrozenScreen(displayID: id, image: img, frame: frame, scale: CGFloat(img.width) / frame.width)
                }
            }
            var out: [FrozenScreen] = []
            for await s in group { if let s { out.append(s) } }
            return out
        }
    }

    // 当前屏幕上的窗口列表（单独渲染窗口要用）；按快捷键时就开始取，右键时通常已经就绪
    static func shareableWindows() async -> SCShareableContent? {
        try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    // 单独渲染一个窗口：不受其他窗口遮挡，不带阴影
    static func captureWindow(_ id: CGWindowID, in content: SCShareableContent) async -> CGImage? {
        guard let w = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(w.frame.width * scale)
        config.height = Int(w.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // 窗口图 + 冻结画面里的弹出菜单，拼成一张：画布是窗口和菜单的并集，其余地方透明
    static func composeWindow(_ window: CGImage, frame: CGRect, popups: [CGRect], frozen: [FrozenScreen]) -> FrozenScreen? {
        guard frame.width > 0 else { return nil }
        let scale = CGFloat(window.width) / frame.width
        let pieces = popups.compactMap { crop(frozen, rect: $0) }
        let bounds = pieces.reduce(frame) { $0.union($1.frame) }
        guard let ctx = CGContext(data: nil, width: Int((bounds.width * scale).rounded()), height: Int((bounds.height * scale).rounded()),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: window.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 全局坐标左上原点 → 位图左下原点
        func place(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - bounds.minX) * scale, y: (bounds.maxY - r.maxY) * scale, width: r.width * scale, height: r.height * scale)
        }
        ctx.draw(window, in: place(frame))
        for p in pieces { ctx.draw(p.image, in: place(p.frame)) }
        guard let img = ctx.makeImage() else { return nil }
        return FrozenScreen(displayID: 0, image: img, frame: bounds, scale: scale)
    }

    // 从冻结画面里裁出一块（全局坐标，左上原点）：取包含区域中心的那块屏幕，超出屏幕的部分裁掉
    static func crop(_ shots: [FrozenScreen], rect: CGRect) -> FrozenScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let s = shots.first(where: { $0.frame.contains(center) }) ?? shots.first(where: { $0.frame.intersects(rect) }) else { return nil }
        let visible = rect.intersection(s.frame)
        let local = visible.offsetBy(dx: -s.frame.minX, dy: -s.frame.minY)
        let px = CGRect(x: local.minX * s.scale, y: local.minY * s.scale, width: local.width * s.scale, height: local.height * s.scale).integral
        guard px.width >= 1, px.height >= 1, let img = s.image.cropping(to: px) else { return nil }
        return FrozenScreen(displayID: s.displayID, image: img, frame: visible, scale: s.scale)
    }

    // 写成 PNG，带上 DPI，Retina 截图在预览等 App 里按原尺寸显示
    static func writePNG(_ shot: FrozenScreen, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        let dpi = 72 * shot.scale
        CGImageDestinationAddImage(dest, shot.image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
