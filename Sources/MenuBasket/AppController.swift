import AppKit
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, BasketPanelDelegate {
    private var controls: ControlItems!
    private let panel = BasketPanel()
    /// 所有会阻塞等待的菜单栏操作（扫描、移动、点击）都串行地在这里执行。
    private let ops = DispatchQueue(label: "menubasket.ops")
    private var monitors: [Any] = []
    private var refreshTimer: Timer?
    /// 面板是否应该处于打开状态。异步刷新完成时据此判断要不要显示，避免关闭后又被刷新重新弹出。
    private var panelWanted = false

    /// 我们自己两个状态项在 Window Server 中的窗口 ID。
    private var dividerID: CGWindowID = 0
    private var basketID: CGWindowID = 0

    /// 正在进行后台操作时，忽略“点击面板外部即关闭”。
    private var busy = false
    private var revealedByDrag = false
    private var strandedBeforeDrag: Set<CGWindowID> = []

    /// 临时显示的项目：菜单/弹窗关闭后要移回原位。
    private struct TemporarilyShown {
        let item: MenuBarItem
        let returnTarget: CGWindowID
        let returnSide: MoveSide
    }
    private var tempShown: TemporarilyShown?
    private var cancelRehideWait = false

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("==== MenuBasket launched (pid \(ProcessInfo.processInfo.processIdentifier))")
        controls = ControlItems(target: self, basketAction: #selector(controlItemClicked(_:)))
        panel.basketDelegate = self
        installMonitors()
        #if DEBUG_IPC
        installDebugCommands()
        #endif

        if !AX.isTrusted || !CGPreflightScreenCaptureAccess() {
            AX.promptForTrust()
            CGRequestScreenCaptureAccess()
        }
        // 状态项窗口需要一个 runloop 周期才会被 Window Server 放置好。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.resolveOwnWindowIDs() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前把临时显示的项目放回去。
        if tempShown != nil {
            cancelRehideWait = true
            ops.sync { self.rehideTemporarilyShown() }
        }
    }

    /// 按帧匹配找出我们自己的两个状态项窗口（macOS 26 中它们由控制中心托管，窗口号与 NSWindow 不同）。
    private func resolveOwnWindowIDs() {
        let windows = WindowServer.statusItemWindows()
        func match(_ frame: CGRect) -> CGWindowID? {
            windows.first {
                abs($0.bounds.minX - frame.minX) < 1.5 && abs($0.bounds.minY - frame.minY) < 1.5
                    && abs($0.bounds.width - frame.width) < 1.5
            }?.id
        }
        let bf = controls.basketFrameCG
        let df = controls.dividerFrameCG
        guard let b = match(bf), let d = match(df) else {
            Log.write("own windows not placed yet (basket \(bf), divider \(df)); retrying")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.resolveOwnWindowIDs() }
            return
        }
        basketID = b
        dividerID = d
        Log.write("own windows: basket #\(b) \(bf), divider #\(d) \(df)")
    }

    /// 当前夹在分隔条与收纳篮之间的窗口（只读 Window Server，足够快，可在主线程调用）。
    private func strandedWindowIDs() -> Set<CGWindowID> {
        guard let d = WindowServer.bounds(of: dividerID), let b = WindowServer.bounds(of: basketID) else { return [] }
        return Set(WindowServer.statusItemWindows().filter {
            $0.id != dividerID && $0.id != basketID && abs($0.bounds.minY - b.minY) < 1
                && $0.bounds.minX >= d.maxX - 1 && $0.bounds.maxX <= b.minX + 1
        }.map(\.id))
    }

    /// 规则：收纳篮左边的图标一律隐藏。用户 ⌘ 拖动后，把新落在分隔条与收纳篮之间的图标移到分隔条左侧。
    /// 拖动前就在那里的（系统自己放置、不可移动的临时指示器）不处理。
    private func enforceLeftIsHidden(except existing: Set<CGWindowID>) {
        busy = true
        ops.asyncAfter(deadline: .now() + 0.3) {
            defer { DispatchQueue.main.async { self.busy = false } }
            for item in self.scan().stranded where !existing.contains(item.windowID) {
                Log.write("stranded #\(item.windowID) \(item.displayName) -> leftOf divider")
                do {
                    try ItemMover.move(item, to: self.dividerID, side: .leftOf)
                } catch {
                    DispatchQueue.main.async { self.showError(error.localizedDescription) }
                }
            }
        }
    }

    private var isReady: Bool { basketID != 0 && dividerID != 0 }

    private func scan() -> MenuBarSnapshot {
        MenuBarScanner.scan(dividerID: dividerID, basketID: basketID)
    }

    // MARK: 收纳篮按钮

    @objc private func controlItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        closePanel()
        let menu = NSMenu()
        menu.addItem(withTitle: "显示隐藏的图标", action: #selector(menuOpenPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "登录时启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "权限设置…", action: #selector(showPermissionAlert), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重新启动收纳篮", action: #selector(relaunch), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出收纳篮", action: #selector(quit), keyEquivalent: "q").target = self
        controls.basket.menu = menu
        controls.basket.button!.performClick(nil)
        controls.basket.menu = nil
    }

    @objc private func menuOpenPanel() { openPanel() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("无法更改登录项：\(error.localizedDescription)")
        }
    }

    @objc private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; open \"\(path)\""]
        try! task.run()
        NSApp.terminate(nil)
    }

    @objc private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "收纳篮需要两项权限"
        let ax = AX.isTrusted ? "✅" : "❌"
        let sc = CGPreflightScreenCaptureAccess() ? "✅" : "❌"
        alert.informativeText = """
        \(ax) 辅助功能：识别每个图标属于哪个 App，并代你点击、移动图标。
        \(sc) 屏幕录制：截取被隐藏图标的样子，显示在下方一行中。

        在“系统设置 › 隐私与安全性”中打开后，请用菜单中的“重新启动收纳篮”使屏幕录制权限生效。
        """
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "打开屏幕录制设置")
        alert.addButton(withTitle: "关闭")
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AX.promptForTrust()
            NSWorkspace.shared.open(URL(string: base + "Privacy_Accessibility")!)
        case .alertSecondButtonReturn:
            CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(URL(string: base + "Privacy_ScreenCapture")!)
        default:
            break
        }
    }

    private func showError(_ message: String) {
        Log.write("ERROR: \(message)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "收纳篮"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: 面板

    private func togglePanel() {
        if panelWanted { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        guard AX.isTrusted, CGPreflightScreenCaptureAccess() else {
            showPermissionAlert()
            return
        }
        guard isReady, controls.state == .hiding else { return }
        panelWanted = true
        reloadPanel()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.panelWanted, !self.panel.isDragging, !self.busy else { return }
            self.reloadPanel()
        }
    }

    private func closePanel() {
        panelWanted = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        panel.orderOut(nil)
    }

    /// 重新扫描并截图，刷新面板内容（面板不可见时打开它）。
    private func reloadPanel() {
        ops.async {
            let snap = self.scan()
            var entries: [(MenuBarItem, NSImage)] = []
            for item in snap.hidden {
                guard let cg = WindowServer.capture(item.windowID) else {
                    Log.write("capture #\(item.windowID) returned nil (window vanished?)")
                    continue
                }
                entries.append((item, NSImage(cgImage: cg, size: item.bounds.size)))
            }
            DispatchQueue.main.async {
                guard self.panelWanted, self.controls.state == .hiding else { return }
                let window = self.controls.basket.button!.window!
                self.panel.show(
                    items: entries,
                    anchor: window.frame,
                    screen: self.controls.screen,
                    appearance: self.controls.basket.button!.effectiveAppearance
                )
            }
        }
    }

    // MARK: BasketPanelDelegate

    func panel(activate item: MenuBarItem, button: CGMouseButton) {
        closePanel()
        cancelRehideWait = true
        busy = true
        let screen = controls.screen
        ops.async {
            defer { DispatchQueue.main.async { self.busy = false } }
            self.rehideTemporarilyShown()
            self.cancelRehideWait = false
            do {
                try self.temporarilyShow(item.windowID, button: button, screen: screen)
            } catch {
                DispatchQueue.main.async { self.showError(error.localizedDescription) }
            }
        }
    }

    func panelDragDidBegin() {}

    func panel(drop item: MenuBarItem, at screenPoint: NSPoint, onto target: (MenuBarItem, MoveSide)?) {
        busy = true
        let p = Geometry.cgPoint(fromCocoa: screenPoint)
        let screenFrameCG = Geometry.cgRect(fromCocoa: controls.screen.frame)
        ops.async {
            defer { DispatchQueue.main.async { self.busy = false } }
            do {
                try self.handleDrop(item.windowID, at: p, screenFrameCG: screenFrameCG, onto: target)
            } catch {
                DispatchQueue.main.async { self.showError(error.localizedDescription) }
            }
            DispatchQueue.main.async {
                if self.panelWanted { self.reloadPanel() }
            }
        }
    }

    // MARK: 临时显示并点击（在 ops 队列中执行）

    private func temporarilyShow(_ itemID: CGWindowID, button: CGMouseButton, screen: NSScreen) throws {
        let snap = scan()
        guard let index = snap.hidden.firstIndex(where: { $0.windowID == itemID }) else {
            throw MoverError.windowGone(itemID)
        }
        let item = snap.hidden[index]
        // 记住原位置：它右边那个隐藏项的左侧；若它本来就是最右的隐藏项，则是分隔条左侧。
        let returnTarget = index + 1 < snap.hidden.count ? snap.hidden[index + 1].windowID : snap.divider.id

        // 找一个能放下它、且不会被刘海或 App 菜单遮住的位置。
        let notchMaxX = DispatchQueue.main.sync { screen.auxiliaryTopRightArea?.minX } ?? -.infinity
        let appMenuMaxX = AX.applicationMenuMaxX() ?? -.infinity
        let safeMinX = max(notchMaxX, appMenuMaxX) + 2
        guard let anchor = snap.visible.first(where: { $0.bounds.minX - item.bounds.width >= safeMinX }) else {
            throw NSError(domain: "MenuBasket", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "菜单栏右侧的空间不足，无法临时显示「\(item.displayName)」。请先把一些可见图标拖进收纳篮。"])
        }
        Log.write("temp show #\(itemID) \(item.displayName) leftOf #\(anchor.windowID) (safeMinX \(safeMinX))")
        try ItemMover.move(item, to: anchor.windowID, side: .leftOf)
        tempShown = TemporarilyShown(item: item, returnTarget: returnTarget, returnSide: .leftOf)

        usleep(120_000)
        guard let shownBounds = WindowServer.bounds(of: itemID) else { throw MoverError.windowGone(itemID) }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let before = Set(WindowServer.allWindows(onScreenOnly: true).map(\.id))
        ItemMover.click(at: shownBounds.center, button: button)

        // 等待它弹出的菜单/面板出现，再等它关闭后把图标放回去。
        usleep(500_000)
        let interface = WindowServer.allWindows(onScreenOnly: true).filter {
            !before.contains($0.id) && $0.layer != 0 && $0.ownerPID != ownPID
        }.map(\.id)
        Log.write("temp show #\(itemID): interface windows \(interface)")
        let start = Date()
        while !cancelRehideWait {
            usleep(250_000)
            if interface.isEmpty {
                if Date().timeIntervalSince(start) > 3 { break }
                continue
            }
            let onScreen = Set(WindowServer.allWindows(onScreenOnly: true).map(\.id))
            if interface.allSatisfy({ !onScreen.contains($0) }) {
                usleep(300_000)
                break
            }
        }
        rehideTemporarilyShown()
    }

    private func rehideTemporarilyShown() {
        guard let shown = tempShown else { return }
        tempShown = nil
        guard WindowServer.bounds(of: shown.item.windowID) != nil else { return }
        let target = WindowServer.bounds(of: shown.returnTarget) != nil ? shown.returnTarget : dividerID
        do {
            try ItemMover.move(shown.item, to: target, side: shown.returnSide)
            Log.write("rehid #\(shown.item.windowID)")
        } catch {
            DispatchQueue.main.async { self.showError(error.localizedDescription) }
        }
    }

    // MARK: 拖放（在 ops 队列中执行）

    private func handleDrop(_ itemID: CGWindowID, at p: CGPoint, screenFrameCG: CGRect, onto target: (MenuBarItem, MoveSide)?) throws {
        let snap = scan()
        guard let item = snap.item(itemID) else { throw MoverError.windowGone(itemID) }
        if let (t, side) = target {
            Log.write("drop #\(itemID) \(side.rawValue) hidden #\(t.windowID)")
            try ItemMover.move(item, to: t.windowID, side: side)
            return
        }
        let bar = CGRect(x: screenFrameCG.minX, y: snap.basket.bounds.minY - 2,
                         width: screenFrameCG.width, height: snap.basket.bounds.height + 6)
        guard bar.contains(p) else {
            Log.write("drop #\(itemID) outside menu bar at \(p): cancelled")
            return
        }
        guard p.x >= snap.basket.bounds.minX else {
            Log.write("drop #\(itemID) left of basket: stays hidden")
            return
        }
        if let v = snap.visible.first(where: { p.x < $0.bounds.midX }) {
            Log.write("drop #\(itemID) leftOf visible #\(v.windowID)")
            try ItemMover.move(item, to: v.windowID, side: .leftOf)
        } else if let last = snap.visible.last {
            try ItemMover.move(item, to: last.windowID, side: .leftOf)
        } else {
            try ItemMover.move(item, to: snap.basket.id, side: .rightOf)
        }
    }

    // MARK: 事件监听

    private func isInMenuBar(_ cocoaPoint: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) }) else { return false }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return cocoaPoint.y >= screen.frame.maxY - max(menuBarHeight, 24)
    }

    private func installMonitors() {
        // 用户在菜单栏里 ⌘ 拖动图标：露出分隔线，让图标可以被拖到收纳篮左侧（隐藏）或右侧（显示）。
        let dragHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.isReady, !self.panel.isDragging, !self.busy else { return }
            guard event.modifierFlags.contains(.command), self.controls.state == .hiding else { return }
            guard self.isInMenuBar(NSEvent.mouseLocation) else { return }
            self.closePanel()
            self.strandedBeforeDrag = self.strandedWindowIDs()
            self.revealedByDrag = true
            self.controls.setState(.revealed)
            Log.write("revealed for ⌘-drag")
        }
        let upHandler: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.revealedByDrag else { return }
            self.revealedByDrag = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.controls.setState(.hiding)
                Log.write("hidden after ⌘-drag")
                self.enforceLeftIsHidden(except: self.strandedBeforeDrag)
            }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: dragHandler)!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { dragHandler($0); return $0 }!)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: upHandler)!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { upHandler($0); return $0 }!)

        // 点击面板以外的地方 / 按 Esc：关闭面板。
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible, !self.busy, !self.panel.isDragging else { return }
            // 收纳篮按钮窗口由控制中心托管，点击它也会被当成“外部点击”；交给按钮自己的切换逻辑处理。
            guard !self.controls.basketFrameCG.contains(Geometry.cursorCG) else { return }
            self.closePanel()
        }!)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closePanel() }
        }!)
    }

#if DEBUG_IPC
    // MARK: 调试命令（DistributedNotification）。仅在 ./build.sh --debug-ipc 构建中编译：
    // 它允许任何本地进程借用本 App 的辅助功能权限点击/拖动，因此绝不能出现在正式构建里。

    private func installDebugCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.menubasket.cmd"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            self.runDebugCommand(command.split(separator: " ").map(String.init))
        }
    }

    private func runDebugCommand(_ args: [String]) {
        Log.write("debug command: \(args)")
        guard isReady else {
            Log.write("not ready yet: own status item windows unresolved")
            return
        }
        switch args.first {
        case "dump":
            Log.write("AX trusted \(AX.isTrusted), screen capture \(CGPreflightScreenCaptureAccess())")
            Log.write("basket frame \(controls.basketFrameCG) win#\(controls.basket.button!.window!.windowNumber), divider frame \(controls.dividerFrameCG) win#\(controls.divider.button!.window!.windowNumber)")
            ops.async {
                let snap = self.scan()
                Log.write("divider \(snap.divider.bounds) basket \(snap.basket.bounds)")
                for (n, i) in snap.hidden.enumerated() { Log.write("  hidden[\(n)] #\(i.windowID) \(i.bounds) pid \(i.sourcePID.map(String.init) ?? "nil") \(i.displayName)") }
                for (n, i) in snap.visible.enumerated() { Log.write("  visible[\(n)] #\(i.windowID) \(i.bounds) onscreen \(i.isOnScreen) pid \(i.sourcePID.map(String.init) ?? "nil") \(i.displayName)") }
            }
        case "capture":
            ops.async {
                let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MenuBasketCaptures")
                try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for i in self.scan().hidden {
                    guard let img = WindowServer.capture(i.windowID) else { Log.write("capture #\(i.windowID) nil"); continue }
                    let rep = NSBitmapImageRep(cgImage: img)
                    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(i.windowID).png"))
                    Log.write("captured #\(i.windowID) \(img.width)x\(img.height)")
                }
            }
        case "snap":
            // snap <name> <x> <y> <w> <h>：截取屏幕区域（CG 坐标）
            let rect = CGRect(x: Double(args[2])!, y: Double(args[3])!, width: Double(args[4])!, height: Double(args[5])!)
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MenuBasketCaptures")
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let img = WindowServer.captureScreen(rect) else { Log.write("snap failed"); return }
            let rep = NSBitmapImageRep(cgImage: img)
            try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(args[1]).png"))
            Log.write("snap \(args[1]) \(img.width)x\(img.height)")
        case "layout":
            for (item, frame) in panel.itemFramesCG { Log.write("  panel #\(item.windowID) \(frame) \(item.displayName)") }
        case "simdrag":
            // simdrag <x1> <y1> <x2> <y2>：模拟用户按住 ⌘ 拖动（CG 坐标）
            let v = args.dropFirst().map { Double($0)! }
            DispatchQueue.global().async {
                let src = CGEventSource(stateID: .hidSystemState)
                func post(_ t: CGEventType, _ x: Double, _ y: Double) {
                    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
                    e.flags = .maskCommand
                    e.post(tap: .cghidEventTap)
                }
                post(.mouseMoved, v[0], v[1]); usleep(100_000)
                post(.leftMouseDown, v[0], v[1]); usleep(150_000)
                for i in 1...30 {
                    let t = Double(i) / 30
                    post(.leftMouseDragged, v[0] + (v[2] - v[0]) * t, v[1] + (v[3] - v[1]) * t)
                    usleep(20_000)
                }
                usleep(300_000)
                post(.leftMouseUp, v[2], v[3])
            }
        case "simclick":
            // simclick <x> <y> [right]：模拟用户点击（CG 坐标）
            let p = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
            let button: CGMouseButton = args.count > 3 && args[3] == "right" ? .right : .left
            DispatchQueue.global().async { ItemMover.click(at: p, button: button) }
        case "open": openPanel()
        case "close": closePanel()
        case "reveal": controls.setState(.revealed)
        case "hide": controls.setState(.hiding)
        case "activate":
            // activate <hiddenIndex> [left|right]
            let n = Int(args[1])!
            let button: CGMouseButton = args.count > 2 && args[2] == "right" ? .right : .left
            ops.async {
                let item = self.scan().hidden[n]
                DispatchQueue.main.async { self.panel(activate: item, button: button) }
            }
        case "show":
            // show <hiddenIndex>：移到可见区（第一个可见项左侧）
            let n = Int(args[1])!
            ops.async {
                let snap = self.scan()
                do { try ItemMover.move(snap.hidden[n], to: snap.visible.first!.windowID, side: .leftOf) }
                catch { Log.write("show failed: \(error.localizedDescription)") }
            }
        case "tuck":
            // tuck <visibleIndex>：移到分隔条左侧（隐藏）
            let n = Int(args[1])!
            ops.async {
                let snap = self.scan()
                do { try ItemMover.move(snap.visible[n], to: snap.divider.id, side: .leftOf) }
                catch { Log.write("tuck failed: \(error.localizedDescription)") }
            }
        default:
            Log.write("unknown debug command")
        }
    }
#endif
}
