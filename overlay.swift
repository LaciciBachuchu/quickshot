import AppKit

// 自己的选区遮罩：左键拖动框选区域，右键单击截取鼠标下的窗口，Esc 取消
// 系统的 screencapture -i 不支持右键，所以这里自己画遮罩，选好后从冻结画面裁剪（见 capture.swift）

enum CaptureTarget {
    case region(CGRect)       // 全局坐标，左上角为原点
    // 窗口编号 + 外框（全局坐标，左上原点）+ 按快捷键时这个 App 在窗口附近展开的菜单 / 下拉框
    case window(CGWindowID, CGRect, popups: [CGRect])
}

struct WindowInfo {
    let id: CGWindowID
    let frame: CGRect         // 全局坐标，左上角为原点
    var pid: pid_t = 0
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
              let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let b = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: b),
              frame.width > 20, frame.height > 20 else { return nil }
        return WindowInfo(id: id, frame: frame, pid: pid)
    }
}

// 屏幕上的弹出层窗口（菜单、下拉框、弹出框等，层级高于普通窗口），不含菜单栏、程序坞和本程序
func popupWindows() -> [WindowInfo] {
    let me = ProcessInfo.processInfo.processIdentifier
    let skip: Set<Int> = [Int(CGWindowLevelForKey(.dockWindow)), Int(CGWindowLevelForKey(.mainMenuWindow)),
                          Int(CGWindowLevelForKey(.statusWindow))]
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return list.compactMap { info in
        guard let layer = info[kCGWindowLayer as String] as? Int, layer > 0, !skip.contains(layer),
              layer < Int(CGShieldingWindowLevel()),
              let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let b = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: b),
              frame.width > 4, frame.height > 4 else { return nil }
        return WindowInfo(id: id, frame: frame, pid: pid)
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

// 遮罩面板：既不激活本程序，也永远不成为 key 窗口——
// 否则别的 App 正展开的菜单、下拉框会因为失去焦点而关掉。键盘（Esc）走全局热键，不需要 key 窗口
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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

    // 减速曲线（指数趋近）：一开始速度最快，越接近目标越慢，不会冲过头；tau 越小越快
    mutating func ease(_ dt: CGFloat, tau: CGFloat) {
        let k = 1 - exp(-dt / tau)
        for i in value.indices {
            value[i] += (target[i] - value[i]) * k
            velocity[i] = 0
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

// 遮罩画面：窗口玻璃轮廓 + 选区框 + 光标旁的玻璃提示（屏幕其他地方保持原样，不变暗）
// 性能要点：全部用普通 CALayer 的 frame / border 实现（GPU 直接合成），不用 CAShapeLayer（改路径要在 CPU 上重新光栅化）；
// 玻璃只沿轮廓摆四条，而不是整个窗口大小的玻璃再用遮罩裁掉；
// 弹簧静止后暂停 display link，不空转
final class OverlayView: NSView {
    weak var controller: SelectionOverlay?
    var start: NSPoint?
    var current: NSPoint?
    var hovered: WindowInfo? { didSet { if hovered?.id != oldValue?.id { hoverChanged() } } }

    static let windowRadius: CGFloat = 12   // 窗口圆角
    // 玻璃轮廓粗细：太细（7pt）看不出折射和高光，只像一条灰线；14pt 偏粗，取 9pt
    static let ringWidth: CGFloat = 9

    // 玻璃轮廓 = 一整块玻璃 + 环形遮罩：只有一块所以没有拼接缝（多块玻璃拼接处各自有边缘高光，一定会断）
    static let ringRadius = windowRadius + ringWidth / 2   // 外圈圆角；内圈 = 外圈 - 粗细，正好贴合窗口圆角
    let ringGlass = NSView()                                // 只用来整体控制透明度
    let ringPiece = makeGlass(cornerRadius: OverlayView.ringRadius)
    let ringMask = CALayer()
    let lineView = NSView()
    let selBorder = CALayer()
    let sizeLabel = CATextLayer()
    let hint = makeGlass(cornerRadius: 17)

    // 轮廓位置：减速曲线，起步最快、到位前慢下来，不回弹；约 100ms 走完 90%，200ms 基本停稳
    var ring = Spring([0, 0, 0, 0], stiffness: 0, damping: 0)
    static let ringTau: CGFloat = 0.045
    var ringAlpha = Spring([0], stiffness: 900, damping: 60)
    var hintPos = Spring([0, 0], stiffness: 0, damping: 0)        // 提示直接贴着光标，不做弹簧，避免拖尾
    var hintAlpha = Spring([0], stiffness: 900, damping: 60)
    var ringShown = false
    var link: CADisplayLink?
    var lastRingFrame = CGRect.null
    var lastHintOrigin = CGPoint(x: -1, y: -1)

    // 冻结画面：按快捷键那一刻拍下的整屏图，铺在遮罩最底层
    let frozenView = NSView()

    func showFrozen(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frozenView.layer?.contents = image
        CATransaction.commit()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        frozenView.frame = bounds
        frozenView.wantsLayer = true
        frozenView.layer?.contentsGravity = .resize
        addSubview(frozenView)
        for v in [ringGlass, lineView] {
            v.frame = bounds
            v.wantsLayer = true
            addSubview(v)
        }
        lineView.autoresizingMask = [.width, .height]

        ringPiece.wantsLayer = true
        ringGlass.addSubview(ringPiece)
        ringMask.borderColor = NSColor.black.cgColor
        ringMask.borderWidth = OverlayView.ringWidth
        ringMask.cornerRadius = OverlayView.ringRadius
        ringMask.anchorPoint = .zero
        ringMask.position = .zero
        ringPiece.layer!.mask = ringMask
        ringGlass.layer!.opacity = 0

        selBorder.borderColor = NSColor.white.cgColor
        selBorder.borderWidth = 1
        selBorder.isHidden = true
        sizeLabel.foregroundColor = NSColor.white.cgColor
        sizeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        sizeLabel.alignmentMode = .center
        sizeLabel.cornerRadius = 5
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.fontSize = 11
        sizeLabel.isHidden = true
        for l in [selBorder, sizeLabel] { lineView.layer!.addSublayer(l) }

        buildHint()
        hint.wantsLayer = true
        addSubview(hint)
        hint.layer!.opacity = 0
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
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)  // ProMotion 屏跑满 120Hz
            l.add(to: .main, forMode: .common)
            link = l
        }
        updateLayers()
    }

    func pause() { link?.isPaused = true }

    // 每次截图开始前回到初始状态（轮廓、提示都隐藏，选区清空）；玻璃视图保留上次的尺寸，不用重建
    func reset() {
        start = nil
        current = nil
        hovered = nil
        ringShown = false
        ringAlpha.value = [0]; ringAlpha.target = [0]
        hintAlpha.value = [0]; hintAlpha.target = [0]
        lastHintOrigin = CGPoint(x: -1, y: -1)
        showFrozen(nil)   // 上一次的冻结画面不留在内存里
        updateLayers()
        pause()
    }

    // 预热：在屏幕中间放一个轮廓和提示，让玻璃完整渲染几帧
    func warmUp() {
        let r = CGRect(x: bounds.midX - 400, y: bounds.midY - 250, width: 800, height: 500)
        hovered = WindowInfo(id: 0, frame: toCG(window!.convertToScreen(r)))
        moveHint(to: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    // 有东西要动时再开动画循环
    func kick() { link?.isPaused = false }

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
            if !ringShown && ringAlpha.value[0] < 0.05 {
                // 从无到有：从稍大一圈收拢进来
                ring.value = r.insetBy(dx: -14, dy: -14).vec
                ring.velocity = [0, 0, 0, 0]
                // 玻璃直接按真实尺寸建好（否则会从一个很小的初始尺寸被放大，圆角被拉成巨大的椭圆，直到第一次停稳才恢复）
                let start = CGRect(vec: ring.value).insetBy(dx: -OverlayView.ringWidth / 2, dy: -OverlayView.ringWidth / 2)
                // 玻璃已经有合理尺寸（预热过/用过）就只用变换摆过去，省掉一次 4~8ms 的视图布局
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if ringPiece.frame.width < 40 || ringPiece.frame.height < 40 { settleRing(start) } else { placeRing(start) }
                CATransaction.commit()
                lastRingFrame = start
            }
            ringShown = true
            ringAlpha.target = [1]
        } else {
            // 离开窗口（比如移到 Dock）：轮廓留在原地淡出
            ringShown = false
            ringAlpha.target = [0]
        }
        kick()
    }

    @objc func tick(_ l: CADisplayLink) {
        if let p = pendingMouse, let win = window {
            pendingMouse = nil
            controller?.hover(at: win.convertPoint(toScreen: p))
            moveHint(to: p, commit: false)
        }
        let dt = CGFloat(min(max(l.targetTimestamp - l.timestamp, 1.0 / 240), 1.0 / 30))
        // 分两小步积分，弹簧更稳
        for _ in 0..<2 {
            ring.ease(dt / 2, tau: OverlayView.ringTau); ringAlpha.step(dt / 2); hintPos.step(dt / 2); hintAlpha.step(dt / 2)
        }
        let idle = ring.settled && ringAlpha.settled && hintPos.settled && hintAlpha.settled
        if idle { ring.snap(); ringAlpha.snap(); hintPos.snap(); hintAlpha.snap() }
        updateLayers()
        if idle {
            settleGlass()
            l.isPaused = true
        }
    }

    // 把玻璃放到目标位置 d：
    // 移动中不改视图 frame（会触发 AppKit 布局，每次 4~8ms），而是给玻璃图层加“拉伸 + 平移”变换，
    // 同时给遮罩加反向缩放，抵消拉伸，所以露出来的那一圈粗细、圆角始终准确
    // 设置里的开关：移动中每帧都按真实尺寸重算玻璃形状（更精确，但每帧多 4~8ms CPU，可能掉帧）
    static var liveGlassShape: Bool { UserDefaults.standard.bool(forKey: "liveGlassShape") }

    func placeRing(_ d: CGRect) {
        if OverlayView.liveGlassShape {
            settleRing(d)
            return
        }
        guard let layer = ringPiece.layer else { return }
        let f = ringPiece.frame
        if f.width < 1 || f.height < 1 || d.width < 1 || d.height < 1 {
            settleRing(d)
            return
        }
        let sx = d.width / f.width, sy = d.height / f.height
        let a = layer.anchorPoint
        layer.setAffineTransform(CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                                   tx: d.minX + sx * a.x * f.width - (f.minX + a.x * f.width),
                                                   ty: d.minY + sy * a.y * f.height - (f.minY + a.y * f.height)))
        ringMask.bounds = CGRect(origin: .zero, size: d.size)
        ringMask.setAffineTransform(CGAffineTransform(scaleX: 1 / sx, y: 1 / sy))
    }

    // 停稳后真正设置一次视图 frame（玻璃按真实尺寸重新渲染），去掉临时变换
    func settleRing(_ d: CGRect) {
        ringPiece.frame = d
        ringPiece.layer!.setAffineTransform(.identity)
        ringMask.bounds = CGRect(origin: .zero, size: d.size)
        ringMask.setAffineTransform(.identity)
    }

    func settleGlass() {
        guard !lastRingFrame.isNull,
              ringPiece.frame != lastRingFrame || !CATransform3DIsIdentity(ringPiece.layer!.transform) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        settleRing(lastRingFrame)
        CATransaction.commit()
    }

    func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let alpha = max(0, min(1, ringAlpha.value[0]))
        let r = CGRect(vec: ring.value)
        let rw = OverlayView.ringWidth

        if let sel = selection {
            selBorder.frame = sel.insetBy(dx: -1, dy: -1)
            selBorder.isHidden = false
            let text = "\(Int(sel.width)) × \(Int(sel.height))"
            if sizeLabel.string as? String != text {
                sizeLabel.string = text
                let w = (text as NSString).size(withAttributes: [.font: sizeLabel.font as! NSFont]).width + 14
                sizeLabel.bounds.size = CGSize(width: w, height: 17)
            }
            var y = sel.minY - 24
            if y < 4 { y = sel.minY + 4 }
            sizeLabel.frame.origin = CGPoint(x: sel.minX, y: y)
            sizeLabel.isHidden = false
        } else {
            selBorder.isHidden = true
            sizeLabel.isHidden = true
        }

        // 玻璃轮廓：外框比窗口大半圈（骑在窗口边缘上），移动中用变换，停稳后 settleGlass 设真实 frame
        let outer = r.insetBy(dx: -rw / 2, dy: -rw / 2)
        if (ringShown || alpha > 0.01) && outer != lastRingFrame {   // 还没出现过时不摆放（此时没有有效位置）
            lastRingFrame = outer
            placeRing(outer)
        }
        ringGlass.layer!.opacity = Float(selection == nil ? alpha : 0)

        // 提示的视图固定在原点，用图层平移来移动（同样避开 AppKit 布局，实测 6.9ms → 0.03ms）
        let origin = CGPoint(x: hintPos.value[0].rounded(), y: hintPos.value[1].rounded())
        if origin != lastHintOrigin {
            lastHintOrigin = origin
            hint.layer!.setAffineTransform(CGAffineTransform(translationX: origin.x, y: origin.y))
        }
        hint.layer!.opacity = Float(max(0, min(1, hintAlpha.value[0])))
        CATransaction.commit()
    }

    // 光标旁的提示：在右下方，靠近屏幕边缘时翻到另一侧
    // 光标旁提示的位置；commit = false 时只记目标，由下一帧 tick 统一提交
    func moveHint(to p: NSPoint, commit: Bool = true) {
        let size = hint.frame.size
        var x = p.x + 18, y = p.y - 22 - size.height
        if x + size.width > bounds.width - 8 { x = p.x - 18 - size.width }
        if y < 8 { y = p.y + 22 }
        // 位置直接跟到光标（同一帧立刻生效），只有淡入淡出走动画
        hintPos.target = [x, y]
        hintPos.snap()
        hintAlpha.target = [selection == nil ? 1 : 0]
        guard commit else { return }
        updateLayers()
        if !hintAlpha.settled { kick() }
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
        moveHint(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hintAlpha.target = [0]
        kick()
    }

    func globalPoint(_ event: NSEvent) -> NSPoint {
        window!.convertPoint(toScreen: convert(event.locationInWindow, from: nil))
    }

    // 鼠标事件比屏幕刷新还频繁（触控板/高回报率鼠标一帧能来好几次），
    // 这里只记下位置，等下一帧统一处理一次，避免每个事件都重新查窗口、提交一次图层
    var pendingMouse: NSPoint?

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        pendingMouse = convert(event.locationInWindow, from: nil)
        kick()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.crosshair.set()
        start = convert(event.locationInWindow, from: nil)
        current = start
        controller?.clearHover()
        hintAlpha.target = [0]
        kick()
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

// 截图遮罩：App 启动时建好并预热一次，之后每次截图复用
// （每次新建窗口和玻璃视图，头 0.2 秒每帧要 10~30ms 做初始化，Instruments 里掉帧几乎都集中在这里）
final class SelectionOverlay {
    var windows: [OverlayPanel] = []
    var views: [OverlayView] = []
    var targets: [WindowInfo] = []
    var completion: ((CaptureTarget?) -> Void)?
    var finished = true          // true = 当前没有在截图
    let screenFrames: [NSRect]

    init() {
        screenFrames = NSScreen.screens.map(\.frame)
        for screen in NSScreen.screens {
            let w = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.isOpaque = false
            // 几乎全透明但不是 0：完全透明的地方鼠标点击会穿透到下面的窗口
            w.backgroundColor = NSColor(white: 0, alpha: 0.004)
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

    // 屏幕布局变了（接/拔显示器、改分辨率）就要重建
    var matchesScreens: Bool { NSScreen.screens.map(\.frame) == screenFrames }

    // 预热：用几乎看不见、不接收鼠标的状态把玻璃轮廓和提示完整渲染几帧
    func prewarm() {
        for w in windows {
            w.alphaValue = 0.01
            w.ignoresMouseEvents = true
            w.orderFrontRegardless()
        }
        views.forEach { $0.warmUp() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.finished else { return }   // 预热期间已经开始截图了，就不收起
            for w in self.windows {
                w.orderOut(nil)
                w.alphaValue = 1
                w.ignoresMouseEvents = false
            }
            self.views.forEach { $0.reset() }
        }
    }

    var popups: [WindowInfo] = []

    // hidden = true：遮罩先完全透明地就位（拍屏用的 captureImage(in:) 不能排除本程序窗口），拍完再 reveal()
    func begin(hidden: Bool = false, completion: @escaping (CaptureTarget?) -> Void) {
        targets = visibleWindows()   // 遮罩出现前先记下窗口位置
        popups = popupWindows()
        self.completion = completion
        finished = false
        fadeGeneration += 1
        setAlpha(hidden ? 0 : 1)
        for w in windows { w.ignoresMouseEvents = false }
        views.forEach { $0.reset() }
        show()
    }

    func reveal() {
        guard !finished else { return }
        setAlpha(1)
    }

    // 用 0 时长的动画来设，能打断上一次还没结束的淡出
    func setAlpha(_ a: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            for w in windows { w.animator().alphaValue = a }
        }
    }

    func show() {
        allowCursorInBackground()
        for w in windows { w.orderFrontRegardless() }
        // 不让任何遮罩成为 key 窗口（见 OverlayPanel），Esc 由全局热键处理
        let mouse = NSEvent.mouseLocation
        NSCursor.crosshair.set()
        for v in views {
            if let w = v.window, NSMouseInRect(mouse, w.frame, false) {
                v.moveHint(to: w.convertPoint(fromScreen: mouse))
            }
        }
        hover(at: mouse)
    }

    func showFrozen(_ shots: [FrozenScreen]) {
        guard !finished else { return }
        for v in views {
            guard let id = v.window?.screen?.displayID else { continue }
            v.showFrozen(shots.first { $0.displayID == id }?.image)
        }
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
        // 同一个 App 在这个窗口附近展开的菜单 / 下拉框一起带上
        let near = w.frame.insetBy(dx: -40, dy: -40)
        finish(.window(w.id, w.frame, popups: popups.filter { $0.pid == w.pid && $0.frame.intersects(near) }.map(\.frame)))
    }

    var fadeGeneration = 0

    // 退出时淡出而不是瞬间撤掉：冻结画面和实时画面之间的差别（玻璃轮廓、提示、截图期间变了的内容）
    // 一帧内跳变看起来就是“闪一下”，淡出 0.15 秒就平滑过渡过去了
    func finish(_ target: CaptureTarget?) {
        guard !finished else { return }
        finished = true
        fadeGeneration += 1
        let gen = fadeGeneration
        for w in windows { w.ignoresMouseEvents = true }   // 淡出期间点击直接穿透
        NSCursor.arrow.set()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for w in windows { w.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard let self, self.finished, self.fadeGeneration == gen else { return }   // 淡出途中又开始截图了
            for w in self.windows { w.orderOut(nil) }
            self.views.forEach { $0.pause() }
        })
        let done = completion
        completion = nil
        // 结果从冻结画面裁剪 / 单独渲染窗口，都不受遮罩影响，不用等它消失
        done?(target)
    }
}
