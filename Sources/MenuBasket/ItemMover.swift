import AppKit
import CoreGraphics

enum MoveSide: String {
    case leftOf, rightOf
}

enum MoverError: LocalizedError {
    case unresolvedOwner(MenuBarItem)
    case windowGone(CGWindowID)
    case noResponse(String)

    var errorDescription: String? {
        switch self {
        case .unresolvedOwner(let item):
            return "无法确定「\(item.displayName)」属于哪个 App（需要辅助功能权限），因此不能移动它。"
        case .windowGone(let id):
            return "菜单栏项 #\(id) 已经不存在。"
        case .noResponse(let name):
            return "「\(name)」没有响应移动操作。部分系统项目（如时钟、控制中心）无法被移动。"
        }
    }
}

/// 通过合成 ⌘+拖拽 事件移动菜单栏项，以及合成点击。必须在后台线程调用（内部会阻塞等待）。
enum ItemMover {
    /// CGEventField 0x33：事件携带的窗口 ID（未在公开头文件中命名）。
    private static let windowIDField = CGEventField(rawValue: 0x33)!

    private static let source: CGEventSource = {
        let s = CGEventSource(stateID: .hidSystemState)!
        return s
    }()

    /// 解除 Window Server 在合成事件后对本地输入的短暂抑制。
    private static func permitLocalEvents() {
        let s = CGEventSource(stateID: .combinedSessionState)!
        let mask: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        s.setLocalEventsFilterDuringSuppressionState(mask, state: .eventSuppressionStateRemoteMouseDrag)
        s.setLocalEventsFilterDuringSuppressionState(mask, state: .eventSuppressionStateSuppressionInterval)
        s.localEventsSuppressionInterval = 0
    }

    private static func makeEvent(
        _ type: CGEventType, at point: CGPoint, windowID: CGWindowID, pid: pid_t, flags: CGEventFlags
    ) -> CGEvent {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        e.flags = flags
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        e.setIntegerValueField(windowIDField, value: Int64(windowID))
        e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        return e
    }

    private static func deliver(_ e: CGEvent, pid: pid_t) {
        e.post(tap: .cgSessionEventTap)
        usleep(5_000)
        e.postToPid(pid)
    }

    /// 轮询直到窗口原点改变或超时。
    private static func waitForOriginChange(_ id: CGWindowID, from origin: CGPoint, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let b = WindowServer.bounds(of: id), b.origin != origin { return true }
            usleep(5_000)
        }
        return false
    }

    private static func isPlaced(_ item: CGRect, _ target: CGRect, _ side: MoveSide) -> Bool {
        switch side {
        case .leftOf: return abs(item.maxX - target.minX) <= 1
        case .rightOf: return abs(item.minX - target.maxX) <= 1
        }
    }

    /// 把 item 移到 target 的左侧/右侧。
    static func move(_ item: MenuBarItem, to targetID: CGWindowID, side: MoveSide) throws {
        guard let pid = item.sourcePID else { throw MoverError.unresolvedOwner(item) }
        let savedCursor = Geometry.cursorCG
        defer {
            CGWarpMouseCursorPosition(savedCursor)
        }
        permitLocalEvents()

        for attempt in 1...4 {
            guard let ib = WindowServer.bounds(of: item.windowID) else { throw MoverError.windowGone(item.windowID) }
            guard let tb = WindowServer.bounds(of: targetID) else { throw MoverError.windowGone(targetID) }
            if isPlaced(ib, tb, side) { return }

            var start: CGPoint
            var end: CGPoint
            switch side {
            case .leftOf:
                start = CGPoint(x: tb.minX, y: tb.minY)
                end = start
                if ib.maxX <= tb.minX { end.x -= ib.width } else { start.x -= 1 }
            case .rightOf:
                start = CGPoint(x: tb.maxX, y: tb.minY)
                end = start
                if ib.minX <= tb.maxX { end.x -= ib.width } else { start.x += 1 }
            }

            let down = makeEvent(.leftMouseDown, at: start, windowID: item.windowID, pid: pid, flags: .maskCommand)
            let up = makeEvent(.leftMouseUp, at: end, windowID: targetID, pid: pid, flags: [])

            deliver(down, pid: pid)
            _ = waitForOriginChange(item.windowID, from: ib.origin, timeout: 0.25)
            let mid = WindowServer.bounds(of: item.windowID)?.origin ?? ib.origin
            deliver(up, pid: pid)
            deliver(up, pid: pid) // 第二次 mouseUp 防止项目卡在“拖动中”状态
            _ = waitForOriginChange(item.windowID, from: mid, timeout: 0.25)
            usleep(60_000)

            if let nb = WindowServer.bounds(of: item.windowID), let nt = WindowServer.bounds(of: targetID),
               isPlaced(nb, nt, side) {
                Log.write("move #\(item.windowID) \(side.rawValue) #\(targetID) ok (attempt \(attempt))")
                return
            }
            Log.write("move #\(item.windowID) \(side.rawValue) #\(targetID) attempt \(attempt) not placed yet")
        }
        throw MoverError.noResponse(item.displayName)
    }

    /// 在屏幕上的某点合成一次真实的鼠标点击（左键或右键），完成后把指针放回原处。
    static func click(at point: CGPoint, button: CGMouseButton) {
        let savedCursor = Geometry.cursorCG
        permitLocalEvents()
        let (downType, upType): (CGEventType, CGEventType) =
            button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button)!
        let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button)!
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
        usleep(40_000)
        CGWarpMouseCursorPosition(savedCursor)
    }
}
