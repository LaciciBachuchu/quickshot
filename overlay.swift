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

// 液态玻璃视图（macOS 26+ 原生 NSGlassEffectView，旧系统退回毛玻璃）
func makeGlass(cornerRadius: CGFloat) -> NSView {
    if #available(macOS 26.0, *) {
        let g = NSGlassEffectView()
        g.cornerRadius = cornerRadius
        g.style = .regular
        return g
    }
    let v = NSVisualEffectView()
    v.material = .hudWindow
    v.blendingMode = .behindWindow
    v.state = .active
    v.wantsLayer = true
    v.layer?.cornerRadius = cornerRadius
    v.layer?.masksToBounds = true
    return v
}

func setGlassContent(_ glass: NSView, _ content: NSView) {
    if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
        g.contentView = content
    } else {
        content.frame = glass.bounds
        content.autoresizingMask = [.width, .height]
        glass.addSubview(content)
    }
}

// 简单的弹簧：数值朝目标“流”过去，略带回弹
struct Spring {
    var value: [CGFloat]
    var velocity: [CGFloat]
    var target: [CGFloat]
    let stiffness: CGFloat
    let damping: CGFloat

    init(_ v: [CGFloat], stiffness: CGFloat, damping: CGFloat) {
        value = v; target = v; velocity = Array(repeating: 0, count: v.count)
        self.stiffness = stiffness; self.damping = damping
    }

    mutating func step(_ dt: CGFloat) {
        for i in value.indices {
            let force = stiffness * (target[i] - value[i]) - damping * velocity[i]
            velocity[i] += force * dt
            value[i] += velocity[i] * dt
        }
    }

    mutating func snap() { value = target; velocity = velocity.map { _ in 0 } }

    var settled: Bool {
        value.indices.allSatisfy { abs(target[$0] - value[$0]) < 0.3 && abs(velocity[$0]) < 0.3 }
    }
}

extension CGRect {
    var vec: [CGFloat] { [minX, minY, width, height] }
    init(vec v: [CGFloat]) { self.init(x: v[0], y: v[1], width: max(v[2], 0), height: max(v[3], 0)) }
}

// 遮罩画面：变暗层 + 窗口玻璃轮廓 + 选区框 + 光标旁的玻璃提示
// 全部用图层/视图移动实现，配合 display link 逐帧弹簧动画，不整屏重绘
final class OverlayView: NSView {
    weak var controller: SelectionOverlay?
    var start: NSPoint?
    var current: NSPoint?
    var hovered: WindowInfo? { didSet { if hovered?.id != oldValue?.id { hoverChanged() } } }

    static let windowRadius: CGFloat = 12   // 窗口圆角
    static let ringWidth: CGFloat = 7       // 玻璃轮廓粗细

    let dimView = NSView()
    let dim = CAShapeLayer()
    let ringGlass = makeGlass(cornerRadius: 0)
    let ringMask = CAShapeLayer()
    let lineView = NSView()
    let ringLine = CAShapeLayer()
    let border = CAShapeLayer()
    let sizeLabel = CATextLayer()
    let hint = makeGlass(cornerRadius: 17)

    var ring = Spring([0, 0, 0, 0], stiffness: 240, damping: 22)   // 轮廓位置：欠阻尼，切换时有流动回弹
    var ringAlpha = Spring([0], stiffness: 300, damping: 30)
    var hintPos = Spring([0, 0], stiffness: 520, damping: 42)      // 提示跟随光标，稍微拖后一点
    var hintAlpha = Spring([0], stiffness: 300, damping: 30)
    var ringShown = false
    var mouse: NSPoint?
    var link: CADisplayLink?
    var lastTime: CFTimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        for v in [dimView, ringGlass, lineView] {
            v.frame = bounds
            v.wantsLayer = true
            addSubview(v)
        }
        dimView.autoresizingMask = [.width, .height]
        lineView.autoresizingMask = [.width, .height]
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.18).cgColor
        dimView.layer!.addSublayer(dim)

        // 玻璃只露出一圈：用环形遮罩挖掉中间
        ringMask.fillRule = .evenOdd
        ringGlass.layer!.mask = ringMask
        ringGlass.alphaValue = 0

        // 轮廓内侧一条细亮线，在白色窗口上也看得清
        ringLine.fillColor = nil
        ringLine.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        ringLine.lineWidth = 1.5
        ringLine.shadowColor = NSColor.black.cgColor
        ringLine.shadowOpacity = 0.35
        ringLine.shadowRadius = 2
        ringLine.shadowOffset = .zero
        ringLine.opacity = 0
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1
        sizeLabel.foregroundColor = NSColor.white.cgColor
        sizeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        sizeLabel.alignmentMode = .center
        sizeLabel.cornerRadius = 5
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.fontSize = 11
        sizeLabel.isHidden = true
        for l in [ringLine, border, sizeLabel] { lineView.layer!.addSublayer(l) }

        buildHint()
        addSubview(hint)
        hint.alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func buildHint() {
        func item(_ symbol: String, _ text: String) -> NSView {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            icon.contentTintColor = .labelColor
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .labelColor
            let s = NSStackView(views: [icon, label])
            s.spacing = 5
            return s
        }
        let dot = NSTextField(labelWithString: "·")
        dot.textColor = .secondaryLabelColor
        let row = NSStackView(views: [item("rectangle.dashed", "左键框选范围"), dot, item("macwindow", "右键截取窗口")])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        let size = row.fittingSize
        hint.frame = NSRect(x: 0, y: 0, width: size.width, height: 34)
        setGlassContent(hint, row)
    }

    override func viewDidMoveToWindow() {
        guard let window else { return }
        sizeLabel.contentsScale = window.backingScaleFactor
        ringLine.contentsScale = window.backingScaleFactor
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        updateLayers()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    func localRect(_ w: WindowInfo) -> NSRect? {
        guard let win = window else { return nil }
        return convert(win.convertFromScreen(toCocoa(w.frame)), from: nil)
    }

    func hoverChanged() {
        if let h = hovered, let r = localRect(h) {
            ring.target = r.vec
            if !ringShown || ringAlpha.value[0] < 0.05 {
                // 从无到有：从稍大一圈收拢进来
                ring.value = r.insetBy(dx: -14, dy: -14).vec
                ring.velocity = [0, 0, 0, 0]
            }
            ringShown = true
            ringAlpha.target = [1]
        } else {
            ringShown = false
            ringAlpha.target = [0]
        }
    }

    @objc func tick(_ l: CADisplayLink) {
        let dt = CGFloat(min(max(l.targetTimestamp - l.timestamp, 1.0 / 240), 1.0 / 30))
        // 分几小步积分，弹簧更稳
        for _ in 0..<2 {
            ring.step(dt / 2); ringAlpha.step(dt / 2); hintPos.step(dt / 2); hintAlpha.step(dt / 2)
        }
        updateLayers()
    }

    func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        let rad = max(0, min(radius, r.width / 2, r.height / 2))
        return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
    }

    func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)

        let alpha = max(0, min(1, ringAlpha.value[0]))
        let r = CGRect(vec: ring.value)
        let rw = OverlayView.ringWidth, rad = OverlayView.windowRadius
        if let sel = selection {
            path.addRect(sel)
            border.path = CGPath(rect: sel.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            let text = "\(Int(sel.width)) × \(Int(sel.height))"
            sizeLabel.string = text
            let w = (text as NSString).size(withAttributes: [.font: sizeLabel.font as! NSFont]).width + 14
            var y = sel.minY - 24
            if y < 4 { y = sel.minY + 4 }
            sizeLabel.frame = CGRect(x: sel.minX, y: y, width: w, height: 17)
            sizeLabel.isHidden = false
        } else {
            border.path = nil
            sizeLabel.isHidden = true
            if alpha > 0.01 { path.addPath(roundedPath(r, rad)) }   // 鼠标下的窗口不变暗
        }
        dim.path = path

        // 玻璃轮廓：外框比窗口大半圈，遮罩只留一圈环
        let outer = r.insetBy(dx: -rw / 2, dy: -rw / 2)
        ringGlass.frame = outer
        let ringPath = CGMutablePath()
        let local = CGRect(origin: .zero, size: outer.size)
        ringPath.addPath(roundedPath(local, rad + rw / 2))
        ringPath.addPath(roundedPath(local.insetBy(dx: rw, dy: rw), rad - rw / 2))
        ringMask.frame = local
        ringMask.path = ringPath
        ringGlass.alphaValue = alpha
        ringLine.path = roundedPath(r.insetBy(dx: rw / 2, dy: rw / 2), rad - rw / 2)
        ringLine.opacity = Float(alpha)

        // 光标旁的提示：在右下方，靠近屏幕边缘时翻到另一侧
        hint.frame.origin = NSPoint(x: hintPos.value[0], y: hintPos.value[1])
        hint.alphaValue = max(0, min(1, hintAlpha.value[0]))
        CATransaction.commit()
    }

    func moveHint(to p: NSPoint, snap: Bool = false) {
        mouse = p
        let size = hint.frame.size
        var x = p.x + 18, y = p.y - 22 - size.height
        if x + size.width > bounds.width - 8 { x = p.x - 18 - size.width }
        if y < 8 { y = p.y + 22 }
        hintPos.target = [x, y]
        if snap || hintAlpha.value[0] < 0.05 { hintPos.snap() }
        hintAlpha.target = [selection == nil ? 1 : 0]
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

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
        moveHint(to: convert(event.locationInWindow, from: nil), snap: true)
    }

    override func mouseExited(with event: NSEvent) { hintAlpha.target = [0] }

    func globalPoint(_ event: NSEvent) -> NSPoint {
        window!.convertPoint(toScreen: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        moveHint(to: convert(event.locationInWindow, from: nil))
        controller?.hover(at: globalPoint(event))
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.crosshair.set()
        start = convert(event.locationInWindow, from: nil)
        current = start
        controller?.clearHover()
        hintAlpha.target = [0]
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.crosshair.set()
        current = convert(event.locationInWindow, from: nil)
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        let sel = selection
        start = nil
        current = nil
        guard let sel, sel.width >= 4, sel.height >= 4 else {   // 只是点了一下，不算
            moveHint(to: convert(event.locationInWindow, from: nil))
            controller?.hover(at: globalPoint(event))
            updateLayers()
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
        for v in views {
            if let w = v.window, NSMouseInRect(mouse, w.frame, false) {
                v.moveHint(to: w.convertPoint(fromScreen: mouse), snap: true)
            }
        }
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
        views.forEach { $0.stop() }
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
