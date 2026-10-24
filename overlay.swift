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

// 让本程序在后台时也能设置光标（否则别的 App 在前台时光标会被换回箭头）
// 这是系统私有接口，找不到就跳过
func allowCursorInBackground() {
    typealias MainConn = @convention(c) () -> Int32
    typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    let h = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
    guard let c = dlsym(h, "_CGSDefaultConnection"), let s = dlsym(h, "CGSSetConnectionProperty") else { return }
    let cid = unsafeBitCast(c, to: MainConn.self)()
    _ = unsafeBitCast(s, to: SetProp.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}

// 不激活本程序也能成为 key window、接收键盘
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// 用图层绘制（GPU 合成），拖动时只改路径，不重绘整屏，所以不卡
final class OverlayView: NSView {
    weak var controller: SelectionOverlay?
    var start: NSPoint?
    var current: NSPoint?
    var hovered: WindowInfo? { didSet { if hovered?.id != oldValue?.id { refresh() } } }

    let dim = CAShapeLayer()
    let border = CAShapeLayer()
    let sizeLabel = CATextLayer()
    let hint = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.18).cgColor
        border.lineWidth = 2
        for l in [sizeLabel, hint] {
            l.foregroundColor = NSColor.white.cgColor
            l.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
            l.alignmentMode = .center
            l.cornerRadius = 6
        }
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.fontSize = 11
        hint.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        hint.fontSize = 13
        hint.string = "左键拖动框选　·　右键截取窗口　·　Esc 取消"
        for l in [dim, border, sizeLabel, hint] { layer!.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        let scale = window?.backingScaleFactor ?? 2
        sizeLabel.contentsScale = scale
        hint.contentsScale = scale
        refresh()
    }

    var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)
        sizeLabel.isHidden = true
        hint.isHidden = selection != nil
        if let sel = selection {
            path.addRect(sel)
            border.path = CGPath(rect: sel.insetBy(dx: -1, dy: -1), transform: nil)
            border.strokeColor = NSColor.white.cgColor
            border.fillColor = nil
            border.lineWidth = 1
            let text = "\(Int(sel.width)) × \(Int(sel.height))"
            sizeLabel.string = text
            let w = (text as NSString).size(withAttributes: [.font: sizeLabel.font as! NSFont]).width + 14
            var y = sel.minY - 24
            if y < 4 { y = sel.minY + 4 }
            sizeLabel.frame = CGRect(x: sel.minX, y: y, width: w, height: 17)
            sizeLabel.isHidden = false
        } else if let h = hovered, let win = window {
            let local = convert(win.convertFromScreen(toCocoa(h.frame)), from: nil)
            border.path = CGPath(rect: local.insetBy(dx: 1, dy: 1), transform: nil)
            border.strokeColor = NSColor.systemBlue.cgColor
            border.fillColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
            border.lineWidth = 2
        } else {
            border.path = nil
        }
        dim.path = path
        let hintW = ((hint.string as? String ?? "") as NSString).size(withAttributes: [.font: hint.font as! NSFont]).width + 28
        hint.frame = CGRect(x: (bounds.width - hintW) / 2, y: 60, width: hintW, height: 26)
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                                                               .cursorUpdate, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // 每次鼠标动都重新设一次，防止光标被别的 App 换回箭头
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }

    func globalPoint(_ event: NSEvent) -> NSPoint {
        window!.convertPoint(toScreen: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        controller?.hover(at: globalPoint(event))
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.crosshair.set()
        start = convert(event.locationInWindow, from: nil)
        current = start
        controller?.clearHover()
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.crosshair.set()
        current = convert(event.locationInWindow, from: nil)
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        let sel = selection
        start = nil
        current = nil
        guard let sel, sel.width >= 4, sel.height >= 4 else {   // 只是点了一下，不算
            refresh()
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
}

final class SelectionOverlay {
    var windows: [OverlayPanel] = []
    var views: [OverlayView] = []
    let targets: [WindowInfo]
    let completion: (CaptureTarget?) -> Void
    var finished = false

    init(completion: @escaping (CaptureTarget?) -> Void) {
        targets = visibleWindows()   // 遮罩出现前先记下窗口位置
        self.completion = completion
        for screen in NSScreen.screens {
            let w = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.becomesKeyOnlyIfNeeded = false
            w.hidesOnDeactivate = false
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
        allowCursorInBackground()
        for w in windows { w.orderFrontRegardless() }
        // 鼠标所在屏幕的遮罩接收键盘（Esc）；面板不需要激活本程序也能拿到键盘
        let mouse = NSEvent.mouseLocation
        let key = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
        key?.makeFirstResponder(key?.contentView)
        NSCursor.crosshair.set()
        hover(at: mouse)
    }

    func window(at point: NSPoint) -> WindowInfo? {
        let cg = CGPoint(x: point.x, y: primaryHeight - point.y)
        return targets.first { $0.frame.contains(cg) }
    }

    func hover(at point: NSPoint) {
        let w = window(at: point)
        for v in views { v.hovered = w }
    }

    func clearHover() {
        for v in views { v.hovered = nil }
    }

    func pickWindow(at point: NSPoint) {
        guard let w = window(at: point) else { NSSound.beep(); return }   // 桌面空白处没有窗口
        finish(.window(w.id))
    }

    func finish(_ target: CaptureTarget?) {
        guard !finished else { return }
        finished = true
        for w in windows { w.orderOut(nil) }
        NSCursor.arrow.set()
        guard target != nil else {
            windows.forEach { $0.close() }
            completion(nil)
            return
        }
        // 等遮罩真正从屏幕上消失再截图，否则会把半透明遮罩也截进去
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.windows.forEach { $0.close() }
            self.completion(target)
        }
    }
}
