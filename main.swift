import AppKit
import ServiceManagement
import Carbon.HIToolbox

// 菜单栏截图：左键点图标或按快捷键（默认 ⌘⇧2）→ 左键拖动框选 / 右键单击截取窗口；菜单栏图标右键 → 菜单
// 截完右下角弹出缩略图：点击打开标注窗口（改动实时同步到剪贴板），可直接拖进微信/邮件等，几秒后自动消失

// MARK: - 快捷键

struct HotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon 修饰键
    var display: String

    static let `default` = HotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧2")

    static func load() -> HotKey {
        let d = UserDefaults.standard
        guard let s = d.string(forKey: "hotKeyDisplay") else { return .default }
        return HotKey(keyCode: UInt32(d.integer(forKey: "hotKeyCode")),
                      modifiers: UInt32(d.integer(forKey: "hotKeyMods")), display: s)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: "hotKeyCode")
        d.set(Int(modifiers), forKey: "hotKeyMods")
        d.set(display, forKey: "hotKeyDisplay")
    }

    static let specialKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_Space: "空格", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]

    static func isFunctionKey(_ code: Int) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19].contains(code)
    }

    // 从按键事件生成快捷键；没有修饰键的普通键不接受（F 键除外），避免影响正常打字
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = 0, symbols = ""
        if flags.contains(.control) { mods |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { mods |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { mods |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { mods |= cmdKey; symbols += "⌘" }
        let code = Int(event.keyCode)
        if mods == 0 && !HotKey.isFunctionKey(code) { return nil }
        if mods == shiftKey && !HotKey.isFunctionKey(code) { return nil }
        let key = HotKey.specialKeys[code]
            ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: UInt32(mods), display: symbols + key)
    }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.display = display
    }
}

// MARK: - 设置窗口

final class SettingsController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let recordButton = NSButton(title: "", target: nil, action: nil)
    let hint = NSTextField(labelWithString: "")
    var monitor: Any?
    weak var app: AppDelegate?

    init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 230),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "QuickShot 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let label = NSTextField(labelWithString: "截图快捷键：")
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(startRecording)
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetDefault))
        reset.bezelStyle = .rounded
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        let row = NSStackView(views: [label, recordButton, reset])
        row.spacing = 8
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let glass = NSButton(checkboxWithTitle: "移动时实时重算玻璃形状", target: self, action: #selector(toggleLiveGlass(_:)))
        glass.state = UserDefaults.standard.bool(forKey: "liveGlassShape") ? .on : .off
        let glassNote = NSTextField(wrappingLabelWithString:
            "关闭（推荐）：移动中拉伸已有的玻璃，背后折射仍是实时的，停稳后再按新尺寸重算，流畅省电。\n打开：每一帧都按真实尺寸重算，边缘高光更准确，但每帧多 4~8ms CPU，快速切换时可能掉帧。")
        glassNote.textColor = .secondaryLabelColor
        glassNote.font = .systemFont(ofSize: 11)
        glassNote.preferredMaxLayoutWidth = 400

        let stack = NSStackView(views: [row, hint, glass, glassNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
        ])
        refresh()
    }

    @objc func toggleLiveGlass(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "liveGlassShape")
    }

    func show() {
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refresh(_ message: String = "点击按钮后，直接按下想要的组合键（需包含 ⌘ / ⌥ / ⌃，或用 F1–F19）") {
        recordButton.title = app?.hotKey.display ?? ""
        hint.stringValue = message
    }

    @objc func startRecording() {
        stopRecording()
        app?.unregisterHotKey()   // 录制时先停用旧快捷键，否则按下会直接触发截图
        recordButton.title = "请按下快捷键…"
        hint.stringValue = "按 Esc 取消"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.finish(nil)
            } else if let key = HotKey(event: event) {
                self.finish(key)
            } else {
                self.hint.stringValue = "这个组合不行：请加上 ⌘ / ⌥ / ⌃ 之一，或使用 F 键"
            }
            return nil
        }
    }

    func finish(_ key: HotKey?) {
        stopRecording()
        guard let app else { return }
        if let key {
            let old = app.hotKey
            app.hotKey = key
            if app.registerHotKey() {
                key.save()
                refresh("已设置为 \(key.display)")
            } else {
                app.hotKey = old
                app.registerHotKey()
                refresh("\(key.display) 已被其他程序占用，请换一个")
            }
        } else {
            app.registerHotKey()
            refresh()
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    @objc func resetDefault() { finish(.default) }

    func windowWillClose(_ notification: Notification) {
        if monitor != nil { finish(nil) }
    }
}

// MARK: - 右下角缩略图

final class ThumbnailView: NSView, NSDraggingSource {
    let file: URL
    let image: NSImage
    var onClose: () -> Void = {}
    var onClick: () -> Void = {}
    var onDelete: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onDrag: (Bool) -> Void = { _ in }
    let closeButton = NSButton()
    var mouseDownEvent: NSEvent?

    init(file: URL, image: NSImage, frame: NSRect) {
        self.file = file
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor

        let iv = NSImageView(frame: bounds)
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(iv)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.frame = NSRect(x: 6, y: bounds.height - 26, width: 20, height: 20)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        return bounds.contains(local) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false; onHover(true) }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true; onHover(false) }
    @objc func closeClicked() { onClose() }

    // 浮窗不是活动窗口，没有这个第一次按下会被吞掉，拖不动
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let d = hypot(event.locationInWindow.x - start.locationInWindow.x,
                      event.locationInWindow.y - start.locationInWindow.y)
        guard d > 4 else { return }
        mouseDownEvent = nil
        // 同时提供文件和图片数据：Finder/微信/邮件拿文件，其他 App 直接拿图片
        let pbItem = NSPasteboardItem()
        pbItem.setString(file.absoluteString, forType: .fileURL)
        if let png = try? Data(contentsOf: file) { pbItem.setData(png, forType: .png) }
        let item = NSDraggingItem(pasteboardWriter: pbItem)
        item.setDraggingFrame(bounds, contents: image)
        onDrag(true)
        window?.alphaValue = 0.3
        beginDraggingSession(with: [item], event: start, source: self)
    }

    // 右键：在旁边弹出「删除」确认，点了才删
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "删除这张截图", action: #selector(deleteConfirmed), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(withTitle: "取消", action: nil, keyEquivalent: "")
        menu.popUp(positioning: item, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc func deleteConfirmed() { onDelete() }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        onClick()   // 单击：打开标注窗口
        onClose()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        window?.alphaValue = 1
        onDrag(false)
        if operation != [] { onClose() }
    }
}

final class ThumbnailPanel {
    let panel: NSPanel
    var timer: Timer?
    var dragging = false
    var finalFrame: NSRect
    var onDismiss: () -> Void = {}
    var onClick: () -> Void = {}

    init(file: URL, image: NSImage) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let maxW: CGFloat = 220, maxH: CGFloat = 160
        let scale = min(maxW / max(image.size.width, 1), maxH / max(image.size.height, 1), 1)
        let size = NSSize(width: max(image.size.width * scale, 60), height: max(image.size.height * scale, 40))
        let vf = screen.visibleFrame
        finalFrame = NSRect(x: vf.maxX - size.width - 20, y: vf.minY + 20, width: size.width, height: size.height)

        panel = NSPanel(contentRect: finalFrame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let view = ThumbnailView(file: file, image: image, frame: NSRect(origin: .zero, size: size))
        view.onClose = { [weak self] in self?.dismiss() }
        view.onClick = { [weak self] in self?.onClick() }
        view.onDelete = { [weak self] in
            trashScreenshot(file)
            self?.dismiss()
        }
        view.onHover = { [weak self] inside in
            guard let self, !self.dragging else { return }
            if inside { self.timer?.invalidate() } else { self.startTimer() }
        }
        // 拖动过程中不能自动收起，否则拖到一半浮窗没了
        view.onDrag = { [weak self] active in
            guard let self else { return }
            self.dragging = active
            if active { self.timer?.invalidate() } else { self.startTimer() }
        }
        panel.contentView = view
    }

    func show() {
        var start = finalFrame
        start.origin.x += finalFrame.width + 40
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    func dismiss() {
        timer?.invalidate()
        var end = finalFrame
        end.origin.x += finalFrame.width + 40
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.onDismiss()
        })
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let saveDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Screenshots")
    var hotKey = HotKey.load()
    var hotKeyRef: EventHotKeyRef?
    var thumbnail: ThumbnailPanel?
    var editors: [EditorController] = []
    lazy var settings = SettingsController(app: self)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图")
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        installHotKeyHandler()
        if !registerHotKey() {
            hotKey = .default
            registerHotKey()
        }
        _ = readyOverlay()   // 启动时就建好遮罩并预热，第一次截图也不卡
    }

    // 全局快捷键（用 Carbon 注册，不需要辅助功能权限）
    func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async {
                if hk.id == 2 { me.overlay?.finish(nil) } else { me.capture() }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    @discardableResult
    func registerHotKey() -> Bool {
        unregisterHotKey()
        let id = EventHotKeyID(signature: OSType(0x51534854), id: 1)  // 'QSHT'
        return RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, id,
                                   GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }

    // 截图期间临时把 Esc 注册成全局快捷键：即使本程序不在前台，Esc 也一定能取消
    var escRef: EventHotKeyRef?
    func registerEsc() {
        let id = EventHotKeyID(signature: OSType(0x51534854), id: 2)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &escRef)
    }

    func unregisterEsc() {
        if let escRef { UnregisterEventHotKey(escRef) }
        escRef = nil
    }

    func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    @objc func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            capture()
        }
    }

    func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "框选截图  \(hotKey.display)", action: #selector(capture), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开截图文件夹", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let login = menu.addItem(withTitle: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    var capturing = false

    var overlay: SelectionOverlay?

    // 复用同一个遮罩；屏幕布局变了才重建（重建后预热一次）
    func readyOverlay() -> SelectionOverlay {
        if let o = overlay, o.matchesScreens { return o }
        let o = SelectionOverlay()
        overlay = o
        o.prewarm()
        return o
    }

    @objc func capture() {
        guard !capturing else { return }  // 防止重复触发
        capturing = true
        thumbnail?.dismiss()
        // 左键拖选区域 / 右键选窗口，Esc 取消
        registerEsc()
        readyOverlay().begin { [weak self] target in
            guard let self else { return }
            self.unregisterEsc()
            if let target { self.shoot(target) } else { self.capturing = false }
        }
    }

    func shoot(_ target: CaptureTarget) {
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let file = saveDir.appendingPathComponent("截图 \(fmt.string(from: Date())).png")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        switch target {
        case .region(let r):
            task.arguments = ["-R\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))", file.path]
        case .window(let id):
            task.arguments = ["-o", "-l\(id)", file.path]   // -o: 不带窗口阴影
        }
        task.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.capturing = false
                guard let data = try? Data(contentsOf: file) else { return }  // 取消时没有文件
                copyToClipboard(png: data, file: file)
                // 缩略图在后台线程解码（整屏 PNG 解码约 20ms，放在主线程会卡掉一帧）
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let thumb = makeThumbnail(file) else { return }
                    DispatchQueue.main.async { self.showThumbnail(file: file, image: thumb) }
                }
            }
        }
        do { try task.run() } catch { capturing = false }
    }


    func showThumbnail(file: URL, image: NSImage) {
        let t = ThumbnailPanel(file: file, image: image)
        t.onDismiss = { [weak self, weak t] in
            if self?.thumbnail === t { self?.thumbnail = nil }
        }
        t.onClick = { [weak self] in self?.openEditor(file: file) }
        thumbnail = t
        t.show()
    }

    // 点开标注时才加载原图
    func openEditor(file: URL) {
        guard let image = NSImage(contentsOf: file) else { return }
        let e = EditorController(file: file, image: image)
        e.onClose = { [weak self, weak e] in self?.editors.removeAll { $0 === e } }
        editors.append(e)
        e.show()
    }

    @objc func openSettings() { settings.show() }

    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveDir)
    }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled { try? service.unregister() } else { try? service.register() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
