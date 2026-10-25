import AppKit

// 截图标注窗口：画笔 / 矩形 / 椭圆 / 箭头 / 马赛克 / 文字，每画一笔都会同步到剪贴板并保存回原文件

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

enum Tool: Int { case pen, rect, ellipse, arrow, mosaic, text }

struct Annotation: Equatable {
    var tool: Tool
    var color: NSColor
    var width: CGFloat      // 图片坐标下的线宽
    var points: [CGPoint]   // 图片坐标；画笔为全部点，其余为起点和终点；文字为锚点
    // 文字标注：文本框（图片坐标）、内容、字号
    var box: CGRect = .zero
    var text: String = ""
    var fontSize: CGFloat = 0

    // mosaic：给定色块大小，返回整张原图的像素化版本（由画布缓存提供）
    // showText = false：正在编辑的文字框只画框和引线，文字由上面的输入框显示
    func draw(mosaic: (CGFloat) -> CGImage? = { _ in nil }, showText: Bool = true) {
        guard let first = points.first, let last = points.last else { return }
        if tool == .mosaic {
            drawMosaic(mosaic)
            return
        }
        if tool == .text {
            drawText(showText: showText)
            return
        }
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
        case .mosaic, .text:
            break
        }
    }

    // MARK: 文字标注

    static func textFont(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }
    var textPadding: CGFloat { fontSize * 0.5 }
    var cornerRadius: CGFloat { fontSize * 0.4 }

    // 选白色时文字是白的，框改成深色底，否则一律白底
    var isLightColor: Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        return c.brightnessComponent > 0.9 && c.saturationComponent < 0.1
    }

    var textAttributes: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        return [.font: Annotation.textFont(fontSize), .foregroundColor: color, .paragraphStyle: para]
    }

    // 按框宽排版后需要的高度（至少一行）
    func fittedHeight(width: CGFloat) -> CGFloat {
        let inner = max(1, width - textPadding * 2)
        let h = (text.isEmpty ? " " : text as NSString).boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                                                                    options: [.usesLineFragmentOrigin], attributes: textAttributes).height
        return ceil(max(h, Annotation.textFont(fontSize).boundingRectForFont.height * 0.9)) + textPadding * 1.2
    }

    // 内容变了以后重新算高度（用户拉大过的高度保留）：
    // 框在锚点上方就往上长，在下方就往下长，始终不压住锚点
    mutating func refitBox() {
        let h = max(fittedHeight(width: box.width), box.height)
        let growsUp = (points.first?.y ?? 0) <= box.midY
        box = CGRect(x: box.minX, y: growsUp ? box.minY : box.maxY - h, width: box.width, height: h)
    }

    var textRect: CGRect { box.insetBy(dx: textPadding, dy: textPadding * 0.6) }

    func drawText(showText: Bool) {
        guard let anchor = points.first else { return }
        // 引线：从锚点连到文本框边缘上离它最近的点
        let target = CGPoint(x: min(max(anchor.x, box.minX), box.maxX), y: min(max(anchor.y, box.minY), box.maxY))
        color.set()
        if !box.contains(anchor) {
            let line = NSBezierPath()
            line.move(to: anchor)
            line.line(to: target)
            line.lineWidth = max(width * 0.75, fontSize * 0.08)
            line.lineCapStyle = .round
            line.stroke()
        }
        let r = max(width * 1.2, fontSize * 0.18)
        NSBezierPath(ovalIn: CGRect(x: anchor.x - r, y: anchor.y - r, width: r * 2, height: r * 2)).fill()

        let frame = NSBezierPath(roundedRect: box, xRadius: cornerRadius, yRadius: cornerRadius)
        (isLightColor ? NSColor.black.withAlphaComponent(0.78) : NSColor.white.withAlphaComponent(0.94)).setFill()
        frame.fill()
        color.setStroke()
        frame.lineWidth = max(width * 0.6, fontSize * 0.07)
        frame.stroke()
        if showText {
            (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin], attributes: textAttributes)
        }
    }

    // 马赛克色块大小（图片坐标）：跟随笔刷粗细
    var mosaicBlock: CGFloat { max(5, (width * 0.4).rounded()) }

    // 沿涂抹轨迹（圆头粗线）裁剪，在裁剪区内画整张图的像素化版本
    func drawMosaic(_ mosaic: (CGFloat) -> CGImage?) {
        guard let cg = NSGraphicsContext.current?.cgContext, let pixelated = mosaic(mosaicBlock),
              let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }   // 单击也打出一个圆点
        for p in points.dropFirst() { path.addLine(to: p) }
        cg.saveGState()
        cg.addPath(path)
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.replacePathWithStrokedPath()
        cg.clip()
        cg.interpolationQuality = .none   // 放大时保持色块的硬边
        cg.draw(pixelated, in: CGRect(origin: .zero, size: mosaicCanvasSize(pixelated)))
        cg.restoreGState()
    }

    // 像素化小图每个像素对应一个色块；按色块整数倍铺开，保证色块大小一致、和图片左下角对齐
    func mosaicCanvasSize(_ pixelated: CGImage) -> CGSize {
        CGSize(width: CGFloat(pixelated.width) * mosaicBlock, height: CGFloat(pixelated.height) * mosaicBlock)
    }
}

// 文字框里的输入框：Esc 结束编辑
final class TextBoxEditor: NSTextView {
    var onEnd: () -> Void = {}

    override func cancelOperation(_ sender: Any?) { onEnd() }
    override func complete(_ sender: Any?) { onEnd() }   // Esc 在文本框里默认是“补全”
}

final class CanvasView: NSView, NSTextViewDelegate {
    let image: NSImage
    var annotations: [Annotation] = []
    var current: Annotation?
    var tool: Tool = .pen
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4   // 屏幕上看到的粗细
    var mosaicWidth: CGFloat = 26   // 马赛克笔刷直径（屏幕上），跟随粗细档位

    // 按色块大小缓存整张原图的像素化版本：缩小（平均颜色）后的小图，绘制时最近邻放大成色块
    var mosaicCache: [CGFloat: CGImage] = [:]

    func pixelated(block: CGFloat) -> CGImage? {
        if let c = mosaicCache[block] { return c }
        guard let src = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = max(1, Int(ceil(image.size.width / block))), h = max(1, Int(ceil(image.size.height / block)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: src.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium   // 缩小时取平均色，色块颜色更自然
        // 原图按色块整数倍铺开（右/上边可能超出一点），和绘制时的铺法一致
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: image.size.width / block, height: image.size.height / block))
        let out = ctx.makeImage()
        mosaicCache[block] = out
        return out
    }
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

    // 图片坐标 ↔ 视图坐标
    func toView(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: r.minX + p.x * scale, y: r.minY + p.y * scale)
    }

    func toView(_ rect: CGRect) -> CGRect {
        CGRect(origin: toView(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
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
        for (i, a) in annotations.enumerated() { a.draw(mosaic: pixelated, showText: i != editingIndex) }
        current?.draw(mosaic: pixelated)
        NSGraphicsContext.restoreGraphicsState()
        // 文字框右下角的调整大小手柄（只在画面上显示，不进导出图）
        NSColor.controlAccentColor.setFill()
        for a in annotations where a.tool == .text {
            NSBezierPath(ovalIn: resizeHandle(for: a).insetBy(dx: 2, dy: 2)).fill()
        }
    }

    // MARK: 文字标注的交互

    var editingIndex: Int?             // 正在编辑的文字标注
    var editSnapshot: [Annotation]?    // 开始编辑前的状态（结束时作为一步撤销）
    var textEditor: TextBoxEditor?
    var gesture: (index: Int, kind: GestureKind, offset: CGPoint)?
    var gestureStart: [Annotation]?
    var syncTimer: Timer?
    enum GestureKind { case move, resize }

    var fontSize: CGFloat { [14, 18, 26][[2, 4, 8].firstIndex(of: lineWidth) ?? 1] }   // 字号跟随粗细档位

    func resizeHandle(for a: Annotation) -> CGRect {
        let b = toView(a.box)
        return CGRect(x: b.maxX - 7, y: b.minY - 7, width: 14, height: 14)
    }

    // 从上往下找鼠标点中的文字框
    func hitText(_ viewPoint: CGPoint) -> (Int, GestureKind)? {
        for i in annotations.indices.reversed() where annotations[i].tool == .text {
            if resizeHandle(for: annotations[i]).contains(viewPoint) { return (i, .resize) }
            if toView(annotations[i].box).contains(viewPoint) { return (i, .move) }
        }
        return nil
    }

    func beginEditing(_ index: Int, snapshot: [Annotation]) {
        editingIndex = index
        editSnapshot = snapshot
        let a = annotations[index]
        let tv = TextBoxEditor(frame: toView(a.textRect))
        tv.font = Annotation.textFont(a.fontSize * scale)
        tv.textColor = a.color
        tv.insertionPointColor = a.color
        tv.string = a.text
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.delegate = self
        tv.onEnd = { [weak self] in self?.endEditing() }
        addSubview(tv)
        window?.makeFirstResponder(tv)
        textEditor = tv
        needsDisplay = true
    }

    // 结束编辑：空文字就删掉这个标注；有变化就记一步撤销并同步
    func endEditing() {
        guard let i = editingIndex, let before = editSnapshot else { return }
        editingIndex = nil
        editSnapshot = nil
        textEditor?.removeFromSuperview()
        textEditor = nil
        syncTimer?.invalidate()
        if i < annotations.count, annotations[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.remove(at: i)
        }
        window?.makeFirstResponder(self)
        finishChange(from: before)
    }

    // 把一次手势 / 编辑合并成一步撤销
    func finishChange(from before: [Annotation]) {
        needsDisplay = true
        guard annotations != before else { return }
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        onChange()
        onHistoryChange()
    }

    func textDidChange(_ notification: Notification) {
        guard let i = editingIndex, let tv = textEditor else { return }
        annotations[i].text = tv.string
        annotations[i].refitBox()
        tv.frame = toView(annotations[i].textRect)
        needsDisplay = true
        // 打字时停顿一下就同步到剪贴板和文件
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.onChange() }
    }



    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(imageRect, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        if editingIndex != nil {   // 正在编辑：点别处先结束编辑
            if let tv = textEditor, tv.frame.contains(vp) { return }
            endEditing()
            return
        }
        // 点中已有的文字框：双击编辑，拖动移动，拖右下角调整大小（任何工具下都可以）
        if let (i, kind) = hitText(vp) {
            if event.clickCount >= 2 {
                beginEditing(i, snapshot: annotations)
                return
            }
            let p = toImage(event)
            gesture = (i, kind, CGPoint(x: p.x - annotations[i].box.minX, y: p.y - annotations[i].box.maxY))
            gestureStart = annotations
            return
        }
        if tool == .text {
            addText(at: toImage(event))
            return
        }
        let w = tool == .mosaic ? mosaicWidth : lineWidth
        current = Annotation(tool: tool, color: color, width: w / scale, points: [toImage(event)])
    }

    // 新建文字标注：文本框放在锚点右上方（放不下就放左边 / 下边），立刻进入编辑
    func addText(at anchor: CGPoint) {
        var a = Annotation(tool: .text, color: color, width: lineWidth / scale, points: [anchor])
        a.fontSize = fontSize / scale
        let gap = 24 / scale, w = 180 / scale
        a.box = CGRect(x: anchor.x + gap, y: anchor.y + gap, width: w, height: 0)
        a.refitBox()
        if a.box.maxX > image.size.width { a.box.origin.x = anchor.x - gap - w }
        if a.box.maxY > image.size.height { a.box.origin.y = anchor.y - gap - a.box.height }
        let before = annotations
        annotations.append(a)
        beginEditing(annotations.count - 1, snapshot: before)
    }

    override func mouseDragged(with event: NSEvent) {
        if let g = gesture {
            let p = toImage(event)
            var a = annotations[g.index]
            switch g.kind {
            case .move:   // 锚点不动，只移动文本框，引线跟着变
                a.box.origin = CGPoint(x: p.x - g.offset.x, y: p.y - g.offset.y - a.box.height)
            case .resize: // 上边和左边不动；宽度跟着拖，高度至少放得下文字
                let width = max(60 / scale, p.x - a.box.minX)
                let height = max(a.fittedHeight(width: width), a.box.maxY - p.y)
                a.box = CGRect(x: a.box.minX, y: a.box.maxY - height, width: width, height: height)
            }
            annotations[g.index] = a
            needsDisplay = true
            return
        }
        guard var c = current else { return }
        let p = toImage(event)
        if c.tool == .pen || c.tool == .mosaic { c.points.append(p) } else { c.points = [c.points[0], p] }
        current = c
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if gesture != nil, let before = gestureStart {
            gesture = nil
            gestureStart = nil
            finishChange(from: before)
            return
        }
        guard let c = current else { return }
        current = nil
        let a = c.points.first!, b = c.points.last!
        if c.tool == .pen || c.tool == .mosaic || hypot(b.x - a.x, b.y - a.y) > 2 {  // 形状工具误点一下不算
            commit { annotations.append(c) }
        }
        needsDisplay = true
    }

    func undo() {
        if editingIndex != nil { endEditing() }
        guard let last = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = last
        needsDisplay = true
        onChange()
        onHistoryChange()
    }

    func redo() {
        if editingIndex != nil { endEditing() }
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
        annotations.forEach { $0.draw(mosaic: pixelated) }
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
        if let tv = firstResponder as? TextBoxEditor {
            // 正在输入文字：⌘Z / ⌘⇧Z 撤销的是输入的文字；回车是换行，不触发“完成”
            if mods == .command && event.keyCode == 6 { tv.undoManager?.undo(); return true }
            if mods == [.command, .shift] && event.keyCode == 6 { tv.undoManager?.redo(); return true }
            if !mods.contains(.command) { return false }
        }
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
    let mosaicWidths: [CGFloat] = [14, 26, 44]   // 马赛克笔刷直径，对应细 / 中 / 粗
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
        let tools = NSSegmentedControl(images: ["pencil.tip", "rectangle", "circle", "arrow.up.right", "checkerboard.rectangle", "textformat"].map {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)!
        }, trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        for (i, tip) in ["画笔", "矩形", "椭圆", "箭头", "马赛克", "文字"].enumerated() { tools.setToolTip(tip, forSegment: i) }
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
    @objc func widthChanged(_ sender: NSSegmentedControl) {
        canvas.lineWidth = widths[sender.selectedSegment]
        canvas.mosaicWidth = mosaicWidths[sender.selectedSegment]
    }
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
