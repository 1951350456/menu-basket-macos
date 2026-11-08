import AppKit

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return dir.appendingPathComponent("MenuBasket.log")
    }()
    private static let queue = DispatchQueue(label: "menubasket.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try! handle.close()
            } else {
                try! line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}

/// 收纳篮图标 + 紧贴其左侧的分隔条。
/// 分隔条在“隐藏”状态下撑到 10000pt，把它左侧的所有状态项挤出屏幕；
/// 在“露出”状态下缩成一条细竖线，供 ⌘ 拖动时作为隐藏/显示的分界。
final class ControlItems {
    enum State { case hiding, revealed }

    static let expandedLength: CGFloat = 10_000
    static let revealedLength: CGFloat = 14

    let basket: NSStatusItem
    let divider: NSStatusItem
    private(set) var state: State = .hiding

    private static let basketName = "MenuBasket.Basket"
    private static let dividerName = "MenuBasket.Divider"

    init(target: AnyObject, basketAction: Selector) {
        // 首次运行时把收纳篮放在最右侧（紧挨系统项目），分隔条紧贴其左，
        // 这样默认会隐藏所有第三方图标；之后用户 ⌘ 拖动的位置由系统按 autosaveName 记住。
        let defaults = UserDefaults.standard
        for (name, position) in [(Self.basketName, 0), (Self.dividerName, 1)] {
            let key = "NSStatusItem Preferred Position \(name)"
            if defaults.object(forKey: key) == nil { defaults.set(position, forKey: key) }
        }

        basket = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        basket.autosaveName = Self.basketName
        let image = NSImage(systemSymbolName: "basket", accessibilityDescription: "收纳篮")!
        image.isTemplate = true
        basket.button!.image = image
        basket.button!.target = target
        basket.button!.action = basketAction
        basket.button!.sendAction(on: [.leftMouseUp, .rightMouseUp])
        basket.button!.toolTip = "收纳篮：点击显示被隐藏的图标"

        divider = NSStatusBar.system.statusItem(withLength: Self.expandedLength)
        divider.autosaveName = Self.dividerName
        divider.button!.image = nil
        divider.button!.target = target
        divider.button!.action = basketAction
        divider.button!.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func setState(_ newState: State) {
        state = newState
        switch newState {
        case .hiding:
            divider.button!.image = nil
            divider.length = Self.expandedLength
        case .revealed:
            divider.button!.image = Self.lineImage
            divider.length = Self.revealedLength
        }
    }

    private static let lineImage: NSImage = {
        let img = NSImage(size: NSSize(width: 4, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 0, width: 2, height: rect.height), xRadius: 1, yRadius: 1).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()

    /// 两个状态项窗口在 CG 坐标中的位置（主线程调用）。
    var basketFrameCG: CGRect { Geometry.cgRect(fromCocoa: basket.button!.window!.frame) }
    var dividerFrameCG: CGRect { Geometry.cgRect(fromCocoa: divider.button!.window!.frame) }
    var screen: NSScreen { basket.button!.window!.screen ?? NSScreen.screens[0] }
}
