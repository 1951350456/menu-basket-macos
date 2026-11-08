import AppKit
import CoreGraphics

/// 菜单栏状态项窗口在 Window Server 中的信息（全部坐标为 CG 全局坐标：原点在主屏左上角，y 向下）。
struct WindowInfo {
    let id: CGWindowID
    let ownerPID: pid_t
    let bounds: CGRect
    let layer: Int
    let isOnScreen: Bool

    init?(_ dict: [String: Any]) {
        guard
            let id = dict[kCGWindowNumber as String] as? CGWindowID,
            let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
            let layer = dict[kCGWindowLayer as String] as? Int,
            let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        self.id = id
        self.ownerPID = pid
        self.bounds = bounds
        self.layer = layer
        self.isOnScreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }
}

enum WindowServer {
    static let statusLayer = Int(CGWindowLevelForKey(.statusWindow))

    static func allWindows(onScreenOnly: Bool) -> [WindowInfo] {
        let option: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly] : [.optionAll]
        let list = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as! [[String: Any]]
        return list.compactMap(WindowInfo.init)
    }

    /// 所有状态栏项窗口（包括被挤到屏幕外的）。
    static func statusItemWindows() -> [WindowInfo] {
        allWindows(onScreenOnly: false).filter { $0.layer == statusLayer }
    }

    /// 按窗口 ID 查询（包括屏幕外的窗口；`.optionIncludingWindow` 只返回屏幕上的）。
    static func info(of id: CGWindowID) -> WindowInfo? {
        let list = CGWindowListCreateDescriptionFromArray(windowArray([id])) as! [[String: Any]]
        return list.compactMap(WindowInfo.init).first { $0.id == id }
    }

    /// 构造 CGWindowList 系列接口所需的“窗口 ID 数组”（元素是 ID 本身，不是 CFNumber）。
    private static func windowArray(_ ids: [CGWindowID]) -> CFArray {
        var pointers: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        return CFArrayCreate(nil, &pointers, pointers.count, nil)!
    }

    static func bounds(of id: CGWindowID) -> CGRect? {
        info(of: id)?.bounds
    }

    // MARK: 截图

    /// CGWindowListCreateImageFromArray 在 Swift SDK 中被标为不可用，但它是唯一能截取
    /// “位于屏幕外”的菜单栏项窗口的接口（ScreenCaptureKit 不支持屏外窗口），因此通过 dlsym 调用。
    private typealias CreateImageFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    private static let createImageFromArray: CreateImageFromArray = {
        let handle = dlopen(nil, RTLD_NOW)
        let symbol = dlsym(handle, "CGWindowListCreateImageFromArray")!
        return unsafeBitCast(symbol, to: CreateImageFromArray.self)
    }()

    #if DEBUG_IPC
    private typealias CreateImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    private static let createImage: CreateImage = {
        let handle = dlopen(nil, RTLD_NOW)
        return unsafeBitCast(dlsym(handle, "CGWindowListCreateImage")!, to: CreateImage.self)
    }()

    /// 截取屏幕上某个区域（仅供调试命令使用）。
    static func captureScreen(_ rect: CGRect) -> CGImage? {
        createImage(rect, CGWindowListOption.optionOnScreenOnly.rawValue, kCGNullWindowID, CGWindowImageOption.bestResolution.rawValue)?
            .takeRetainedValue()
    }
    #endif

    static func capture(_ id: CGWindowID) -> CGImage? {
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return createImageFromArray(.null, windowArray([id]), options.rawValue)?.takeRetainedValue()
    }
}

// MARK: - 坐标换算

enum Geometry {
    /// 主屏高度（Cocoa 与 CG 坐标的换算基准）。
    static var primaryHeight: CGFloat { NSScreen.screens[0].frame.height }

    static func cgRect(fromCocoa r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cgPoint(fromCocoa p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func cocoaRect(fromCG r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static var cursorCG: CGPoint { CGEvent(source: nil)!.location }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}
