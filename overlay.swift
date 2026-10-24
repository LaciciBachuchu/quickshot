import AppKit

// 自己的选区遮罩：左键拖动框选区域，右键单击截取鼠标下的窗口，Esc 取消
// 系统的 screencapture -i 不支持右键，所以这里自己画遮罩，选好后再交给 screencapture -R / -l 截图

enum CaptureTarget {
    case region(CGRect)       // 全局坐标，左上角为原点（screencapture -R 用的坐标）
    case window(CGWindowID)
}

struct WindowInfo {
    let id: CGWindowID
    let frame: CGRect         // 全局坐标，左上角为原点
}

// 主屏高度，用来在 Cocoa（左下原点）和 CG（左上原点）坐标之间换算
var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

func toCG(_ r: NSRect) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

func toCocoa(_ r: CGRect) -> NSRect {
    NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

// 屏幕上的普通窗口，从前到后排列（不含本程序自己的窗口）
func visibleWindows() -> [WindowInfo] {
    let me = ProcessInfo.processInfo.processIdentifier
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return list.compactMap { info in
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              (info[kCGWindowOwnerPID as String] as? Int32) != me,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let b = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: b),
              frame.width > 20, frame.height > 20 else { return nil }
        return WindowInfo(id: id, frame: frame)
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class OverlayView: NSView {
    weak var controller: SelectionOverlay?
    var start: NSPoint?
    var current: NSPoint?
    var hovered: WindowInfo?

    var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    func globalPoint(_ event: NSEvent) -> NSPoint {
        window!.convertPoint(toScreen: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) { controller?.hover(at: globalPoint(event)) }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        controller?.clearHover()
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; current = nil; needsDisplay = true }
        guard let sel = selection, sel.width >= 4, sel.height >= 4 else {   // 只是点了一下，不算
            controller?.hover(at: globalPoint(event))
            return
        }
        let global = window!.convertToScreen(convert(sel, to: nil))
        controller?.finish(.region(toCG(global)))
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.pickWindow(at: globalPoint(event))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller?.finish(nil) }   // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        // 轻微变暗，选中部分 / 鼠标下的窗口保持原样
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        if let sel = selection {
            NSColor.clear.setFill()
            sel.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            drawLabel("\(Int(sel.width)) × \(Int(sel.height))", near: sel)
        } else if let w = hovered, let win = window {
            let local = convert(win.convertFromScreen(toCocoa(w.frame)), from: nil)
            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            local.fill(using: .copy)
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
        }

        if selection == nil {
            drawHint("左键拖动框选　·　右键截取窗口　·　Esc 取消")
        }
    }

    func drawLabel(_ text: String, near rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - 8)
        if origin.y < 4 { origin.y = rect.minY + 4 }
        let bg = NSRect(x: origin.x, y: origin.y, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: bg.minX + 5, y: bg.minY + 2), withAttributes: attrs)
    }

    func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let bg = NSRect(x: (bounds.width - size.width) / 2 - 14, y: 60, width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        text.draw(at: NSPoint(x: bg.minX + 14, y: bg.minY + 7), withAttributes: attrs)
    }
}

final class SelectionOverlay {
    var windows: [OverlayWindow] = []
    var views: [OverlayView] = []
    let targets: [WindowInfo]
    let completion: (CaptureTarget?) -> Void
    var finished = false

    init(completion: @escaping (CaptureTarget?) -> Void) {
        targets = visibleWindows()   // 遮罩出现前先记下窗口位置
        self.completion = completion
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false
            let v = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.controller = self
            w.contentView = v
            windows.append(w)
            views.append(v)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        // 鼠标所在屏幕的遮罩接收键盘（Esc）
        let mouse = NSEvent.mouseLocation
        let key = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        key?.makeKey()
        key?.makeFirstResponder(key?.contentView)
        hover(at: mouse)
    }

    func window(at point: NSPoint) -> WindowInfo? {
        let cg = CGPoint(x: point.x, y: primaryHeight - point.y)
        return targets.first { $0.frame.contains(cg) }
    }

    func hover(at point: NSPoint) {
        let w = window(at: point)
        for v in views where v.hovered?.id != w?.id {
            v.hovered = w
            v.needsDisplay = true
        }
    }

    func clearHover() {
        for v in views { v.hovered = nil; v.needsDisplay = true }
    }

    func pickWindow(at point: NSPoint) {
        guard let w = window(at: point) else { NSSound.beep(); return }   // 桌面空白处没有窗口
        finish(.window(w.id))
    }

    func finish(_ target: CaptureTarget?) {
        guard !finished else { return }
        finished = true
        for w in windows { w.orderOut(nil) }
        // 等遮罩真正从屏幕上消失再截图，否则会把半透明遮罩也截进去
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.windows.forEach { $0.close() }
            self.completion(target)
        }
    }
}
