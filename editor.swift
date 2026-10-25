import AppKit

// 截图标注窗口：画笔 / 矩形 / 椭圆 / 箭头，每画一笔都会同步到剪贴板并保存回原文件

// 剪贴板只放 PNG（不放 TIFF：未压缩，整屏截图要几十 MB）
// 记下最后一次复制的是哪张截图，删除时只清掉自己放进剪贴板的内容
var clipboardOwner: (file: URL, changeCount: Int)?

// 用 ImageIO 直接生成小尺寸缩略图，不需要先解码整张原图
func makeThumbnail(_ file: URL, maxPixel: Int = 480) -> NSImage? {
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                    kCGImageSourceCreateThumbnailWithTransform: true]
    guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

func copyToClipboard(png: Data, file: URL) {
    let item = NSPasteboardItem()
    item.setData(png, forType: .png)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.writeObjects([item])
    clipboardOwner = (file, pb.changeCount)
}

// 删除截图：文件移到废纸篓（可恢复），剪贴板里还是这张图的话一并清掉
func trashScreenshot(_ file: URL) {
    try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
    let pb = NSPasteboard.general
    if let owner = clipboardOwner, owner.file == file, owner.changeCount == pb.changeCount {
        pb.clearContents()
        clipboardOwner = nil
    }
}

enum Tool: Int { case pen, rect, ellipse, arrow }

struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat      // 图片坐标下的线宽
    var points: [CGPoint]   // 图片坐标；画笔为全部点，其余为起点和终点

    func draw() {
        guard let first = points.first, let last = points.last else { return }
        color.set()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let rect = NSRect(x: min(first.x, last.x), y: min(first.y, last.y),
                          width: abs(last.x - first.x), height: abs(last.y - first.y))
        switch tool {
        case .pen:
            path.move(to: first)
            if points.count == 1 { path.line(to: first) }  // 单击也画出一个点
            for p in points.dropFirst() { path.line(to: p) }
            path.stroke()
        case .rect:
            path.appendRect(rect)
            path.stroke()
        case .ellipse:
            path.appendOval(in: rect)
            path.stroke()
        case .arrow:
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(width * 4, 12)
            let back = CGPoint(x: last.x - cos(angle) * head * 0.8, y: last.y - sin(angle) * head * 0.8)
            path.move(to: first)
            path.line(to: back)
            path.stroke()
            let tip = NSBezierPath()
            tip.move(to: last)
            tip.line(to: CGPoint(x: last.x - cos(angle - 0.45) * head, y: last.y - sin(angle - 0.45) * head))
            tip.line(to: CGPoint(x: last.x - cos(angle + 0.45) * head, y: last.y - sin(angle + 0.45) * head))
            tip.close()
            tip.fill()
        }
    }
}

final class CanvasView: NSView {
    let image: NSImage
    var annotations: [Annotation] = []
    var current: Annotation?
    var tool: Tool = .pen
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4   // 屏幕上看到的粗细
    var onChange: () -> Void = {}
    var onHistoryChange: () -> Void = {}

    // 撤销 / 重做：每次修改前把整组标注存一份快照，撤销、重做就是在快照之间切换
    // （比“删掉最后一笔”通用：之后移动、改文字这类修改也能撤销）
    var undoStack: [[Annotation]] = []
    var redoStack: [[Annotation]] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func commit(_ change: () -> Void) {
        undoStack.append(annotations)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        change()
        needsDisplay = true
        onChange()
        onHistoryChange()
    }

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    var imageRect: NSRect {
        let s = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = image.size.width * s, h = image.size.height * s
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    var scale: CGFloat { imageRect.width / image.size.width }

    func toImage(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let r = imageRect
        return CGPoint(x: (p.x - r.minX) / scale, y: (p.y - r.minY) / scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        let r = imageRect
        image.draw(in: r)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        let t = NSAffineTransform()
        t.translateX(by: r.minX, yBy: r.minY)
        t.scale(by: scale)
        t.concat()
        annotations.forEach { $0.draw() }
        current?.draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(imageRect, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        current = Annotation(tool: tool, color: color, width: lineWidth / scale, points: [toImage(event)])
    }

    override func mouseDragged(with event: NSEvent) {
        guard var c = current else { return }
        let p = toImage(event)
        if c.tool == .pen { c.points.append(p) } else { c.points = [c.points[0], p] }
        current = c
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = current else { return }
        current = nil
        let a = c.points.first!, b = c.points.last!
        if c.tool == .pen || hypot(b.x - a.x, b.y - a.y) > 2 {  // 形状工具误点一下不算
            commit { annotations.append(c) }
        }
        needsDisplay = true
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = last
        needsDisplay = true
        onChange()
        onHistoryChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        needsDisplay = true
        onChange()
        onHistoryChange()
    }

    // 按原图像素尺寸合成，保证清晰度不变
    func renderPNG() -> Data? {
        let src = image.representations.first
        let pw = src?.pixelsWide ?? Int(image.size.width), ph = src?.pixelsHigh ?? Int(image.size.height)
        guard var rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        if let cs = (src as? NSBitmapImageRep)?.colorSpace, let tagged = rep.retagging(with: cs) { rep = tagged }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        annotations.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

final class EditorWindow: NSWindow {
    var onRedo: () -> Void = {}

    override func cancelOperation(_ sender: Any?) { close() }  // Esc 关闭

    // ⌘⇧Z 重做：按键码判断（按钮的快捷键写法匹配不上 Shift 产生的大写 Z）
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == [.command, .shift] && event.keyCode == 6 {
            onRedo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class EditorController: NSObject, NSWindowDelegate {
    let window: EditorWindow
    let canvas: CanvasView
    let file: URL
    var onClose: () -> Void = {}
    let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .black, .white]
    var colorButtons: [NSButton] = []
    let widths: [CGFloat] = [2, 4, 8]
    let undoButton = NSButton()
    let redoButton = NSButton()

    init(file: URL, image: NSImage) {
        self.file = file
        canvas = CanvasView(image: image)

        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        super.init()
        window.title = "标注 — \(file.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.delegate = self

        canvas.onChange = { [weak self] in self?.sync() }
        canvas.onHistoryChange = { [weak self] in self?.updateHistoryButtons() }
        window.onRedo = { [weak self] in self?.canvas.redo() }
        buildUI(barHeight: barHeight)
        window.subtitle = "画完自动复制到剪贴板"
        fitToImage()
    }

    let barHeight: CGFloat = 48
    var aspect: CGFloat { canvas.image.size.height / canvas.image.size.width }
    var minCanvasWidth: CGFloat = 0

    // 画布严格按图片比例，不留黑边；图片比工具栏窄时放大显示（导出仍是原图分辨率）
    func fitToImage() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let titleH = window.frame.height - window.contentLayoutRect.height
        let maxW = vf.width * 0.9, maxH = vf.height * 0.9 - barHeight - titleH
        minCanvasWidth = min(window.contentView!.subviews.first!.fittingSize.width, maxW)

        let img = canvas.image.size
        var w = min(img.width, maxW, maxH / aspect)   // 默认原尺寸，太大就缩小
        w = max(w, minCanvasWidth)                     // 太窄就放大到工具栏宽度
        let h = min(w * aspect, maxH)                  // 极端细长图才会在左右留边
        window.setContentSize(NSSize(width: w, height: h + barHeight))
        window.contentMinSize = NSSize(width: minCanvasWidth, height: min(minCanvasWidth * aspect, maxH) + barHeight)
    }

    // 拖动改变窗口大小时保持图片比例
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let titleH = sender.frame.height - sender.contentLayoutRect.height
        let w = max(frameSize.width, minCanvasWidth)
        return NSSize(width: w, height: w * aspect + barHeight + titleH)
    }

    func buildUI(barHeight: CGFloat) {
        let tools = NSSegmentedControl(images: ["pencil.tip", "rectangle", "circle", "arrow.up.right"].map {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)!
        }, trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        for (i, tip) in ["画笔", "矩形", "椭圆", "箭头"].enumerated() { tools.setToolTip(tip, forSegment: i) }
        tools.selectedSegment = 0

        let colorRow = NSStackView()
        colorRow.spacing = 6
        for (i, c) in colors.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(colorChanged(_:)))
            b.isBordered = false
            b.tag = i
            b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 9
            b.layer?.borderColor = NSColor.separatorColor.cgColor
            b.layer?.borderWidth = 1
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorButtons.append(b)
            colorRow.addArrangedSubview(b)
        }
        highlightColor(0)

        let width = NSSegmentedControl(labels: ["细", "中", "粗"], trackingMode: .selectOne,
                                       target: self, action: #selector(widthChanged(_:)))
        width.selectedSegment = 1

        undoButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "撤销")
        undoButton.target = self
        undoButton.action = #selector(undoClicked)
        undoButton.bezelStyle = .rounded
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = .command
        undoButton.toolTip = "撤销 ⌘Z"
        redoButton.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "重做")
        redoButton.target = self
        redoButton.action = #selector(redoClicked)
        redoButton.bezelStyle = .rounded
        redoButton.toolTip = "重做 ⌘⇧Z"
        let history = NSStackView(views: [undoButton, redoButton])
        history.spacing = 4
        updateHistoryButtons()

        let preview = NSButton(image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "用预览打开")!,
                               target: self, action: #selector(openInPreview))
        preview.bezelStyle = .rounded
        preview.toolTip = "用预览打开"
        let done = NSButton(title: "完成", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let trash = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")!,
                             target: self, action: #selector(deleteClicked))
        trash.bezelStyle = .rounded
        trash.contentTintColor = .systemRed
        trash.keyEquivalent = "\u{8}"   // ⌘⌫
        trash.keyEquivalentModifierMask = .command
        trash.toolTip = "删除这张截图 ⌘⌫（移到废纸篓）"

        let bar = NSStackView(views: [tools, colorRow, width, history, spacer, trash, preview, done])
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        let content = window.contentView!
        for v in [bar, canvas] as [NSView] {   // bar 必须是第一个子视图，fitToImage 用它算最小宽度
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: barHeight),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // 每次修改：合成新图 → 写回原文件 → 复制到剪贴板
    func sync() {
        guard let png = canvas.renderPNG() else {
            window.subtitle = "合成失败"
            return
        }
        try? png.write(to: file, options: .atomic)
        copyToClipboard(png: png, file: file)
        window.subtitle = "✓ 已同步到剪贴板"
    }

    func highlightColor(_ index: Int) {
        for (i, b) in colorButtons.enumerated() {
            b.layer?.borderWidth = i == index ? 3 : 1
            b.layer?.borderColor = (i == index ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }

    @objc func toolChanged(_ sender: NSSegmentedControl) { canvas.tool = Tool(rawValue: sender.selectedSegment) ?? .pen }
    @objc func colorChanged(_ sender: NSButton) { canvas.color = colors[sender.tag]; highlightColor(sender.tag) }
    @objc func widthChanged(_ sender: NSSegmentedControl) { canvas.lineWidth = widths[sender.selectedSegment] }
    @objc func undoClicked() { canvas.undo() }
    @objc func redoClicked() { canvas.redo() }

    func updateHistoryButtons() {
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
    }
    @objc func openInPreview() { NSWorkspace.shared.open(file) }
    @objc func doneClicked() { window.close() }

    @objc func deleteClicked() {
        trashScreenshot(file)
        window.close()
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}
