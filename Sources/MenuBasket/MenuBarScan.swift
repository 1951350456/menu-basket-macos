import AppKit

/// 菜单栏上的一个第三方/系统状态项。
struct MenuBarItem {
    let windowID: CGWindowID
    let bounds: CGRect
    let isOnScreen: Bool
    /// 创建该状态项的进程（经 AX 解析）。解析不到时为 nil，此时无法移动它。
    let sourcePID: pid_t?
    let appName: String?
    let label: String?

    var displayName: String {
        let label = label?.split(whereSeparator: \.isNewline).first.map(String.init)
        switch (appName, label) {
        case let (app?, label?) where label != app: return "\(app) — \(label)"
        case let (app?, _): return app
        case let (nil, label?): return label
        default: return "未知项目 #\(windowID)"
        }
    }
}

/// 一次菜单栏快照：分隔条、收纳篮，以及两侧的项目。
struct MenuBarSnapshot {
    let divider: WindowInfo
    let basket: WindowInfo
    /// 分隔条左侧（被隐藏）的项目，按 x 从左到右。
    let hidden: [MenuBarItem]
    /// 收纳篮右侧（可见）的项目，按 x 从左到右。
    let visible: [MenuBarItem]
    /// 夹在分隔条与收纳篮之间的项目。“收纳篮左边一律隐藏”，所以它们应被移到分隔条左侧。
    let stranded: [MenuBarItem]

    func item(_ id: CGWindowID) -> MenuBarItem? {
        hidden.first { $0.windowID == id } ?? visible.first { $0.windowID == id }
    }
}

enum MenuBarScanner {
    /// 状态项宽度上限：超过这个宽度的是其它菜单栏管理器的撑开分隔条，而不是可点的图标。
    static let maxItemWidth: CGFloat = 400

    static func scan(dividerID: CGWindowID, basketID: CGWindowID) -> MenuBarSnapshot {
        let windows = WindowServer.statusItemWindows()
        let divider = windows.first { $0.id == dividerID }!
        let basket = windows.first { $0.id == basketID }!
        let barY = basket.bounds.minY
        let extras = AX.isTrusted ? AX.extraItems() : []
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var items: [MenuBarItem] = []
        for w in windows where w.id != dividerID && w.id != basketID {
            guard
                abs(w.bounds.minY - barY) < 1,
                w.bounds.width >= 2,
                w.bounds.width <= maxItemWidth
            else { continue }
            let match = extras.first { $0.frame.center.distance(to: w.bounds.center) <= 1.5 }
            if match?.pid == ownPID { continue }
            items.append(MenuBarItem(
                windowID: w.id,
                bounds: w.bounds,
                isOnScreen: w.isOnScreen,
                sourcePID: match?.pid,
                appName: match?.appName,
                label: match?.label
            ))
        }
        items.sort { $0.bounds.minX < $1.bounds.minX }
        let hidden = items.filter { $0.bounds.maxX <= divider.bounds.minX + 1 }
        let visible = items.filter { $0.bounds.minX >= basket.bounds.maxX - 1 }
        let stranded = items.filter {
            $0.bounds.minX >= divider.bounds.maxX - 1 && $0.bounds.maxX <= basket.bounds.minX + 1
        }
        return MenuBarSnapshot(divider: divider, basket: basket, hidden: hidden, visible: visible, stranded: stranded)
    }
}
