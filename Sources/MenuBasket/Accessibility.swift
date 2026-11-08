import AppKit
import ApplicationServices

/// 通过辅助功能 API 找出每个状态栏项真正属于哪个 App。
/// macOS 26 起 CGWindowList 把所有状态栏项窗口都报告为“控制中心”所有，
/// 只有各 App 的 AXExtrasMenuBar 子元素才带有真实归属，按帧中心与窗口匹配。
enum AX {
    struct ExtraItem {
        let pid: pid_t
        let appName: String
        let frame: CGRect
        let label: String?
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let posValue = attribute(element, kAXPositionAttribute),
            let sizeValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let s = attribute(element, name) as? String, !s.isEmpty else { return nil }
        return s
    }

    /// 枚举所有 App 的状态栏项（AXExtrasMenuBar 的子元素）。
    static func extraItems() -> [ExtraItem] {
        var result: [ExtraItem] = []
        for app in NSWorkspace.shared.runningApplications
        where app.isFinishedLaunching && !app.isTerminated && app.activationPolicy != .prohibited {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            guard
                let barRef = attribute(appElement, "AXExtrasMenuBar"),
                let children = attribute(barRef as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]
            else { continue }
            let appName = app.localizedName ?? app.bundleIdentifier ?? "PID \(app.processIdentifier)"
            for child in children {
                guard let frame = frame(of: child) else { continue }
                let label = string(child, kAXTitleAttribute)
                    ?? string(child, kAXDescriptionAttribute)
                    ?? string(child, kAXHelpAttribute)
                result.append(ExtraItem(pid: app.processIdentifier, appName: appName, frame: frame, label: label))
            }
        }
        return result
    }

    /// 当前占据菜单栏的 App 的菜单（“文件/编辑/…”）最右端 x（CG 坐标）。
    static func applicationMenuMaxX() -> CGFloat? {
        guard let app = NSWorkspace.shared.menuBarOwningApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard
            let barRef = attribute(appElement, kAXMenuBarAttribute),
            let children = attribute(barRef as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        return children.compactMap { frame(of: $0)?.maxX }.max()
    }
}
