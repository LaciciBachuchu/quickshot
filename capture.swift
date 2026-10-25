import AppKit
import ScreenCaptureKit

// 冻结画面：按下快捷键的那一刻用 ScreenCaptureKit 把每块屏幕整屏拍下来，
// 选区遮罩显示这张冻结画面，松手后从里面裁剪结果——这样弹出菜单、下拉框即使随后关掉也能截到。
// 拍屏时排除 QuickShot 自己的窗口，所以遮罩可以和拍屏同时出现，不用等拍完。

struct FrozenScreen {
    let displayID: CGDirectDisplayID
    let image: CGImage
    let frame: CGRect      // 全局坐标，左上角为原点（点）
    let scale: CGFloat     // 每点多少像素
}

enum ScreenFreezer {
    // SCShareableContent 每次都要枚举所有窗口和显示器（可能要几百毫秒），所以按显示器缓存拍屏用的过滤器
    private static var filters: [CGDirectDisplayID: (filter: SCContentFilter, frame: CGRect)] = [:]
    private static let lock = NSLock()

    // 启动时、屏幕布局变化时调用：建好每块屏幕的过滤器（排除本程序的所有窗口）
    static func prepare() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var built: [CGDirectDisplayID: (SCContentFilter, CGRect)] = [:]
        for d in content.displays {
            built[d.displayID] = (SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []), d.frame)
        }
        lock.withLock { filters = built }
    }

    static func invalidate() {
        lock.withLock { filters.removeAll() }
    }

    // 所有屏幕并行拍一张
    static func captureAll() async -> [FrozenScreen] {
        var current = lock.withLock { filters }
        if current.isEmpty {
            await prepare()
            current = lock.withLock { filters }
        }
        return await withTaskGroup(of: FrozenScreen?.self) { group in
            for (id, entry) in current {
                group.addTask {
                    let f = entry.filter
                    let scale = CGFloat(f.pointPixelScale)
                    let config = SCStreamConfiguration()
                    config.width = Int(f.contentRect.width * scale)
                    config.height = Int(f.contentRect.height * scale)
                    config.showsCursor = false
                    config.captureResolution = .best
                    guard let img = try? await SCScreenshotManager.captureImage(contentFilter: f, configuration: config) else { return nil }
                    return FrozenScreen(displayID: id, image: img, frame: entry.frame, scale: scale)
                }
            }
            var out: [FrozenScreen] = []
            for await s in group { if let s { out.append(s) } }
            return out
        }
    }

    // 从冻结画面里裁出一块（全局坐标，左上原点）：取包含区域中心的那块屏幕，超出屏幕的部分裁掉
    static func crop(_ shots: [FrozenScreen], rect: CGRect) -> FrozenScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let s = shots.first(where: { $0.frame.contains(center) }) ?? shots.first(where: { $0.frame.intersects(rect) }) else { return nil }
        let local = rect.intersection(s.frame).offsetBy(dx: -s.frame.minX, dy: -s.frame.minY)
        let px = CGRect(x: local.minX * s.scale, y: local.minY * s.scale, width: local.width * s.scale, height: local.height * s.scale).integral
        guard px.width >= 1, px.height >= 1, let img = s.image.cropping(to: px) else { return nil }
        return FrozenScreen(displayID: s.displayID, image: img, frame: rect, scale: s.scale)
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
