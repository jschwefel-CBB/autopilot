import Foundation
import ApplicationServices
import CoreGraphics

/// The macOS backend: conforms the neutral AppDriver protocol to the live
/// Accessibility / CGEvent / ScreenCaptureKit stack.
public struct MacOSDriver: AppDriver {
    private let permissions = Permissions()
    private let launcher = AppLauncher()
    private let actions = ActionEngine()
    private let axResolver = MacOSAXResolver()
    private let clock: Clock

    // LaunchedApp wraps NSRunningApplication, which the neutral LaunchedHandle
    // can't carry; keep them keyed by pid so terminate/activate can recover them.
    private final class AppStore: @unchecked Sendable {
        var byPid: [Int32: LaunchedApp] = [:]
        let lock = NSLock()
        func put(_ app: LaunchedApp) { lock.lock(); byPid[app.pid] = app; lock.unlock() }
        func get(_ pid: Int32) -> LaunchedApp? { lock.lock(); defer { lock.unlock() }; return byPid[pid] }
    }
    private let store = AppStore()

    public init(clock: Clock = SystemClock()) { self.clock = clock }

    // MARK: neutral<->CG conversions (internal; static for testability)
    static func cgPoint(_ p: Point) -> CGPoint { CGPoint(x: p.x, y: p.y) }
    static func cgRect(_ r: Rect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
    static func point(_ p: CGPoint) -> Point { Point(x: Double(p.x), y: Double(p.y)) }

    private func appElement(_ app: LaunchedHandle) -> AXUIElement { AXTree.application(pid: app.pid) }
    private func toRef(_ re: ResolvedElement) -> ElementRef {
        switch re {
        case .element(let h): return .ax((h as! MacOSElement).ax)
        case .point(let p): return .point(Self.cgPoint(p))
        }
    }

    // MARK: lifecycle
    public func launch(_ target: TargetApp) throws -> LaunchedHandle {
        let a = try launcher.launch(target); store.put(a)
        return LaunchedHandle(pid: a.pid, appName: a.runningApp.localizedName ?? "")
    }
    public func attach(_ target: TargetApp) throws -> LaunchedHandle {
        let a = try launcher.attach(target); store.put(a)
        return LaunchedHandle(pid: a.pid, appName: a.runningApp.localizedName ?? "")
    }
    public func attach(pid: Int32) throws -> LaunchedHandle {
        let a = try launcher.attach(pid: pid); store.put(a)
        return LaunchedHandle(pid: a.pid, appName: a.runningApp.localizedName ?? "")
    }
    public func terminate(_ app: LaunchedHandle) { if let a = store.get(app.pid) { launcher.terminate(a) } }
    public func activate(_ app: LaunchedHandle, timeoutMs: Int, intervalMs: Int) -> Bool {
        guard let a = store.get(app.pid) else { return false }
        return launcher.activate(a, timeoutMs: timeoutMs, intervalMs: intervalMs, clock: clock)
    }

    // MARK: permissions
    public func hasAccessibility() -> Bool { permissions.hasAccessibility() }
    public func hasScreenRecording() -> Bool { permissions.hasScreenRecording() }
    public func accessibilityInstructions() -> String { permissions.accessibilityInstructions() }
    public func screenRecordingInstructions() -> String { permissions.screenRecordingInstructions() }

    // MARK: resolution
    public func resolve(_ selector: Selector, app: LaunchedHandle,
                        timeoutMs: Int, intervalMs: Int, baseDir: URL?) throws -> ResolvedElement {
        let appEl = appElement(app)
        let poller = Poller(clock: clock)
        var lastError: Error = TargetingError.timedOut(selector: AXResolver.describe(selector), timeoutMs: timeoutMs)
        let ok = poller.waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            do { _ = try axResolver.resolveOne(in: appEl, selector: selector); return true }
            catch { lastError = error; return false }
        }
        guard ok else {
            if let vision = selector.vision {
                let imagePath = PlanRunner.resolveImagePath(vision.image, baseDir: baseDir)
                let mainID = CGMainDisplayID()
                let screenRect = CGRect(x: 0, y: 0,
                                        width: CGFloat(CGDisplayPixelsWide(mainID)),
                                        height: CGFloat(CGDisplayPixelsHigh(mainID)))
                guard let img = try? ScreenCapture.image(of: screenRect),
                      let haystack = MacOSImageDecoder.grayscaleBuffer(of: img),
                      let needle = MacOSImageDecoder.grayscaleBuffer(pngPath: imagePath),
                      let match = VisionResolver.bestMatch(haystack: haystack, needle: needle),
                      match.score >= vision.confidence
                else { throw lastError }
                let nW = (needle.first?.count ?? 0), nH = needle.count
                return .point(Point(x: Double(match.x + nW / 2), y: Double(match.y + nH / 2)))
            }
            throw lastError
        }
        let el = try axResolver.resolveOne(in: appEl, selector: selector)
        return .element(MacOSElement(el))
    }
    public func waitForPresence(_ selector: Selector, present: Bool, app: LaunchedHandle,
                                timeoutMs: Int, intervalMs: Int) -> Bool {
        let appEl = appElement(app)
        return Poller(clock: clock).waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            (axResolver.count(in: appEl, selector: selector) > 0) == present
        }
    }
    public func matchCount(_ selector: Selector, app: LaunchedHandle) -> Int {
        axResolver.count(in: appElement(app), selector: selector, stopAt: .max)
    }
    public func findAll(_ selector: Selector, app: LaunchedHandle) -> [String] {
        axResolver.findAll(in: appElement(app), selector: selector)
    }

    // MARK: actions
    public func perform(action: Action, args: ActionArgs?, on element: ResolvedElement?) throws {
        try actions.perform(action: action, args: args, ref: element.map(toRef))
    }
    public func point(for element: ResolvedElement) -> Point? {
        actions.point(for: toRef(element)).map(Self.point)
    }
    public func performDrag(from: Point, to: Point) throws {
        EventSynthesizer.drag(from: Self.cgPoint(from), to: Self.cgPoint(to))
    }
    public func selectMenuPath(_ path: [String], app: LaunchedHandle) throws {
        try MenuNavigator().selectPath(path, app: appElement(app))
    }

    // MARK: property read
    public func readProperty(_ property: AssertProperty, of element: any ElementHandle) -> String? {
        MacOSPropertyReader.read(property, from: (element as! MacOSElement).ax)
    }

    // MARK: capture
    public func captureElementScreenshot(_ element: any ElementHandle, to path: String,
                                         padding: Int, metadata: [String: String]) -> String? {
        // Screenshot.captureElement returns nil on success, reason on failure.
        Screenshot.captureElement((element as! MacOSElement).ax, to: path, padding: Double(padding), metadata: metadata)
    }
    public func captureMainDisplay(to path: String, metadata: [String: String]) -> Bool {
        Screenshot.captureMainDisplay(to: path, metadata: metadata)
    }
    public func captureRegion(_ rect: Rect, to path: String, metadata: [String: String]) -> Bool {
        Screenshot.captureRegion(Self.cgRect(rect), to: path, metadata: metadata)
    }
    public func samplePixel(at point: Point) -> RGBColor? {
        MacOSPixelSampler.sample(at: Self.cgPoint(point)).map { $0.asRGBColor }
    }
    public func sampleRegion(_ rect: Rect) -> [RGBColor] {
        MacOSPixelSampler.sampleRegion(Self.cgRect(rect)).map { $0.asRGBColor }
    }
    public func loadPNG(_ path: String) -> [RGBColor]? {
        MacOSPixelSampler.loadPNG(path).map { $0.map { $0.asRGBColor } }
    }

    // MARK: inspection
    public func dumpTree(app: LaunchedHandle) -> TreeSnapshot {
        let snap = AXTree.snapshot(appElement(app))
        return TreeSnapshot(nodes: snap.nodes, truncated: snap.truncated)
    }
    public func suggestSelectors(app: LaunchedHandle) -> [SelectorSuggester.Suggestion] {
        SelectorSuggester.suggest(from: AXTree.snapshot(appElement(app)).nodes)
    }
}
