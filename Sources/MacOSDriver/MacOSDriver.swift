import Foundation
import AppKit
import ApplicationServices
import AutopilotCore

// MARK: - AXElement box (ElementHandle conformance)

/// Boxes an AXUIElement so it can be passed through the AppDriver protocol
/// as an opaque ElementHandle. Only MacOSDriver downcasts it back.
final class AXElementHandle: ElementHandle, @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

// MARK: - MacOSDriver

/// The macOS backend for AutopilotCore's AppDriver protocol.
/// Delegates all platform work to the existing platform helpers.
public struct MacOSDriver: AppDriver {

    let launcher    = AppLauncher()
    let actions     = ActionEngine()
    let assertions  = MacAssertionReader()
    let menuNav     = MenuNavigator()
    let permissions = Permissions()

    public init() {}

    // MARK: Permissions

    public func hasAccessibility() -> Bool { permissions.hasAccessibility() }
    public func hasScreenRecording() -> Bool { permissions.hasScreenRecording() }
    public func accessibilityInstructions() -> String { permissions.accessibilityInstructions() }
    public func screenRecordingInstructions() -> String { permissions.screenRecordingInstructions() }

    // MARK: Lifecycle

    public func launch(_ target: TargetApp) throws -> LaunchedHandle {
        let app = try launcher.launch(target)
        return LaunchedHandle(pid: app.pid, appName: app.runningApp.localizedName ?? "")
    }

    public func attach(_ target: TargetApp) throws -> LaunchedHandle {
        let app = try launcher.attach(target)
        return LaunchedHandle(pid: app.pid, appName: app.runningApp.localizedName ?? "")
    }

    public func attach(pid: Int32) throws -> LaunchedHandle {
        let app = try launcher.attach(pid: pid)
        return LaunchedHandle(pid: app.pid, appName: app.runningApp.localizedName ?? "")
    }

    public func terminate(_ app: LaunchedHandle) {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        running.terminate()
    }

    public func activate(_ app: LaunchedHandle, timeoutMs: Int, intervalMs: Int) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return false }
        let launched = LaunchedApp(pid: app.pid, runningApp: running)
        return launcher.activate(launched, timeoutMs: timeoutMs, intervalMs: intervalMs)
    }

    // MARK: Resolution

    private func appElement(for handle: LaunchedHandle) -> AXUIElement {
        AXUIElementCreateApplication(handle.pid)
    }

    private func targeting(clock: Clock = SystemClock()) -> Targeting {
        Targeting(poller: Poller(clock: clock))
    }

    public func resolve(_ selector: AutopilotCore.Selector, app: LaunchedHandle,
                        timeoutMs: Int, intervalMs: Int, baseDir: URL?) throws -> ResolvedElement {
        let appEl = appElement(for: app)
        let ref = try targeting().resolve(selector, app: appEl,
                                         timeoutMs: timeoutMs, intervalMs: intervalMs,
                                         baseDir: baseDir)
        switch ref {
        case .ax(let el): return .element(AXElementHandle(el))
        case .point(let pt): return .point(Point(x: pt.x, y: pt.y))
        }
    }

    public func waitForPresence(_ selector: AutopilotCore.Selector, present: Bool, app: LaunchedHandle,
                                timeoutMs: Int, intervalMs: Int) -> Bool {
        targeting().waitForPresence(selector, present: present, app: appElement(for: app),
                                   timeoutMs: timeoutMs, intervalMs: intervalMs)
    }

    public func matchCount(_ selector: AutopilotCore.Selector, app: LaunchedHandle) -> Int {
        targeting().matchCount(selector, app: appElement(for: app))
    }

    public func findAll(_ selector: AutopilotCore.Selector, app: LaunchedHandle) -> [String] {
        MacAXResolver().findAll(in: appElement(for: app), selector: selector)
    }

    // MARK: Actions

    public func perform(action: Action, args: ActionArgs?, on element: ResolvedElement?) throws {
        let ref = element.flatMap { elementRef(from: $0) }
        try actions.perform(action: action, args: args, ref: ref)
    }

    public func point(for element: ResolvedElement) -> Point? {
        guard let ref = elementRef(from: element) else { return nil }
        guard let pt = actions.point(for: ref) else { return nil }
        return Point(x: pt.x, y: pt.y)
    }

    public func performDrag(from: Point, to: Point) throws {
        // The runner resolves both endpoints to screen points and hands them here;
        // synthesize the low-level drag directly (mouse-down, moves, mouse-up).
        EventSynthesizer.drag(from: CGPoint(x: from.x, y: from.y),
                              to: CGPoint(x: to.x, y: to.y))
    }

    public func selectMenuPath(_ path: [String], app: LaunchedHandle) throws {
        try menuNav.selectPath(path, app: appElement(for: app))
    }

    // MARK: Property reads

    public func readProperty(_ property: AssertProperty, of element: any ElementHandle) -> String? {
        guard let box = element as? AXElementHandle else { return nil }
        return assertions.readProperty(property, from: box.element)
    }

    // MARK: Visual capture

    public func captureElementScreenshot(_ element: any ElementHandle, to path: String,
                                         padding: Int, metadata: [String: String]) -> String? {
        guard let box = element as? AXElementHandle else { return "not an AX element" }
        return Screenshot.captureElement(box.element, to: path, padding: Double(padding),
                                         metadata: metadata)
    }

    public func captureMainDisplay(to path: String, metadata: [String: String]) -> Bool {
        Screenshot.captureMainDisplay(to: path, metadata: metadata)
    }

    public func captureRegion(_ rect: Rect, to path: String, metadata: [String: String]) -> Bool {
        Screenshot.captureRegion(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                                 to: path, metadata: metadata)
    }

    public func samplePixel(at point: Point) -> AutopilotCore.RGBColor? {
        MacPixelSampler.sample(at: CGPoint(x: point.x, y: point.y))
    }

    public func sampleRegion(_ rect: Rect) -> [AutopilotCore.RGBColor] {
        MacPixelSampler.sampleRegion(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }

    public func loadPNG(_ path: String) -> [AutopilotCore.RGBColor]? {
        MacPixelSampler.loadPNG(path)
    }

    // MARK: Inspection

    public func dumpTree(app: LaunchedHandle) -> TreeSnapshot {
        let snap = AXTree.snapshot(appElement(for: app))
        return TreeSnapshot(nodes: snap.nodes, truncated: snap.truncated)
    }

    public func suggestSelectors(app: LaunchedHandle) -> [SelectorSuggester.Suggestion] {
        let snap = AXTree.snapshot(appElement(for: app))
        return SelectorSuggester.suggest(from: snap.nodes)
    }

    // MARK: Helpers

    private func elementRef(from resolved: ResolvedElement) -> ElementRef? {
        switch resolved {
        case .element(let h):
            guard let box = h as? AXElementHandle else { return nil }
            return .ax(box.element)
        case .point(let p):
            return .point(CGPoint(x: p.x, y: p.y))
        }
    }
}
