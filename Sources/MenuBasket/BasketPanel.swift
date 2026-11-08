import AppKit

protocol BasketPanelDelegate: AnyObject {
    func panel(activate item: MenuBarItem, button: CGMouseButton)
    /// ⌘ 拖动结束。`screenPoint` 为 Cocoa 屏幕坐标；`target` 为落在面板内另一个图标上时的目标。
    func panel(drop item: MenuBarItem, at screenPoint: NSPoint, onto target: (MenuBarItem, MoveSide)?)
    func panelDragDidBegin()
}

/// 菜单栏下方的一行，展示被隐藏的图标。
final class BasketPanel: NSPanel {
    weak var basketDelegate: BasketPanelDelegate?
    private let effect = NSVisualEffectView()
    private var itemViews: [ItemView] = []
    private(set) var isDragging = false
    /// 鼠标正按在某个图标上（点击或拖动进行中）。此时不能重建图标视图，否则会丢失后续的 mouseUp。
    fileprivate(set) var isTracking = false

    static let padding: CGFloat = 5
    static let spacing: CGFloat = 2

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer!.cornerRadius = 10
        effect.layer!.masksToBounds = true
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 显示/刷新面板。`anchor` 为收纳篮图标的 Cocoa 屏幕坐标。
    func show(items: [(MenuBarItem, NSImage)], anchor: NSRect, screen: NSScreen, appearance: NSAppearance?) {
        guard !isTracking else { return }
        self.appearance = appearance
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = []

        let maxRowWidth = screen.visibleFrame.width - 20
        var rows: [[ItemView]] = [[]]
        var rowWidth: CGFloat = 0
        for (item, image) in items {
            let view = ItemView(item: item, image: image, panel: self)
            let w = view.frame.width
            if rowWidth > 0, rowWidth + Self.spacing + w > maxRowWidth - 2 * Self.padding {
                rows.append([])
                rowWidth = 0
            }
            rowWidth += (rowWidth > 0 ? Self.spacing : 0) + w
            rows[rows.count - 1].append(view)
            itemViews.append(view)
        }

        let content: NSView
        if items.isEmpty {
            let label = NSTextField(labelWithString: "没有被隐藏的图标。⌘ 拖动菜单栏图标到收纳篮左侧即可隐藏。")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.sizeToFit()
            content = label
        } else {
            content = NSView()
        }
        effect.subviews.forEach { $0.removeFromSuperview() }

        let rowHeight = itemViews.map(\.frame.height).max() ?? content.frame.height
        let widths = rows.map { row in row.reduce(0) { $0 + $1.frame.width } + CGFloat(max(row.count - 1, 0)) * Self.spacing }
        let innerWidth = items.isEmpty ? content.frame.width + 10 : (widths.max() ?? 0)
        let innerHeight = items.isEmpty ? content.frame.height + 8 : CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * Self.spacing
        let size = NSSize(width: innerWidth + 2 * Self.padding, height: innerHeight + 2 * Self.padding)

        if items.isEmpty {
            content.setFrameOrigin(NSPoint(x: Self.padding + 5, y: Self.padding + 4))
            effect.addSubview(content)
        } else {
            for (r, row) in rows.enumerated() {
                var x = Self.padding
                let y = size.height - Self.padding - CGFloat(r + 1) * rowHeight - CGFloat(r) * Self.spacing
                for view in row {
                    view.setFrameOrigin(NSPoint(x: x, y: y + (rowHeight - view.frame.height) / 2))
                    effect.addSubview(view)
                    x += view.frame.width + Self.spacing
                }
            }
        }

        // 右端与收纳篮图标对齐，限制在屏幕范围内。
        let visible = screen.visibleFrame
        var originX = anchor.maxX - size.width
        originX = min(max(originX, visible.minX + 8), visible.maxX - size.width - 8)
        let originY = anchor.minY - 6 - size.height
        setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }

    #if DEBUG_IPC
    /// 每个图标在屏幕上的 CG 坐标（调试用）。
    var itemFramesCG: [(MenuBarItem, CGRect)] {
        itemViews.map { view in
            let inWindow = view.convert(view.bounds, to: nil)
            return (view.item, Geometry.cgRect(fromCocoa: convertToScreen(inWindow)))
        }
    }
    #endif

    // MARK: 拖动支持

    private var ghost: NSWindow?

    fileprivate func beginDrag(_ view: ItemView) {
        isDragging = true
        basketDelegate?.panelDragDidBegin()
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .popUpMenu
        w.ignoresMouseEvents = true
        w.alphaValue = 0.85
        w.appearance = appearance
        let iv = NSImageView(frame: NSRect(origin: .zero, size: view.frame.size))
        iv.image = view.image
        iv.imageScaling = .scaleNone
        w.contentView = iv
        ghost = w
        view.alphaValue = 0.3
        updateDrag(view)
        w.orderFrontRegardless()
    }

    fileprivate func updateDrag(_ view: ItemView) {
        let p = NSEvent.mouseLocation
        ghost?.setFrameOrigin(NSPoint(x: p.x - view.frame.width / 2, y: p.y - view.frame.height / 2))
    }

    fileprivate func endDrag(_ view: ItemView) {
        ghost?.orderOut(nil)
        ghost = nil
        view.alphaValue = 1
        isDragging = false
        let p = NSEvent.mouseLocation
        var target: (MenuBarItem, MoveSide)?
        if frame.contains(p) {
            let local = effect.convert(convertPoint(fromScreen: p), from: nil)
            if let hit = itemViews.first(where: { $0 !== view && $0.frame.insetBy(dx: -Self.spacing, dy: -Self.spacing).contains(local) }) {
                target = (hit.item, local.x < hit.frame.midX ? .leftOf : .rightOf)
            } else {
                return // 落在面板空白处：取消
            }
        }
        basketDelegate?.panel(drop: view.item, at: p, onto: target)
    }

    fileprivate func activate(_ view: ItemView, button: CGMouseButton) {
        basketDelegate?.panel(activate: view.item, button: button)
    }
}

/// 面板中的单个图标。
private final class ItemView: NSView {
    let item: MenuBarItem
    let image: NSImage
    private unowned let panel: BasketPanel
    private var mouseDownPoint: NSPoint?
    private var commandDrag = false
    private var dragging = false
    private var hovered = false { didSet { needsDisplay = true } }

    init(item: MenuBarItem, image: NSImage, panel: BasketPanel) {
        self.item = item
        self.image = image
        self.panel = panel
        super.init(frame: NSRect(origin: .zero, size: image.size))
        toolTip = item.displayName
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 4), xRadius: 6, yRadius: 6).fill()
        }
        image.draw(in: bounds)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = NSEvent.mouseLocation
        panel.isTracking = true
        commandDrag = event.modifierFlags.contains(.command)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard commandDrag, let start = mouseDownPoint else { return }
        if !dragging, start.distance(to: NSEvent.mouseLocation) > 3 {
            dragging = true
            panel.beginDrag(self)
        }
        if dragging { panel.updateDrag(self) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil; dragging = false; panel.isTracking = false }
        if dragging {
            panel.endDrag(self)
            return
        }
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            panel.activate(self, button: .left)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        panel.activate(self, button: .right)
    }
}
