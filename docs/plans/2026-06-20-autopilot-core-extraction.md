# AutoPilot Core Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `autopilot-macos` so all platform-agnostic orchestration sits behind driver protocols, then extract that agnostic layer into a standalone published `autopilot-core` SPM package that `autopilot-macos` depends on — proving the seam with one real backend before iOS/Android exist.

**Architecture:** Introduce a small set of driver protocols (`AppDriver`, `ElementHandle`, and supporting value types) that express everything `PlanRunner` needs from a platform: launch/attach/terminate, resolve a selector to an element, perform an action, read a property, capture screenshots/regions, sample pixels, snapshot-diff, and dump the element tree. `PlanRunner` and all orchestration logic become platform-agnostic and depend only on these protocols. The macOS code (AX, CGEvent, ScreenCaptureKit) becomes a concrete `MacOSDriver` conforming to them. Then the agnostic half moves to a new `autopilot-core` repo as an SPM package; `autopilot-macos` adds it as a remote package dependency and keeps only `MacOSDriver` + the two executables.

**Tech Stack:** Swift 6 (SwiftPM tools-version 6.0, language mode v5), macOS 14+, swift-argument-parser. Element handle abstraction uses an **existential `any ElementHandle`** (not generics). Step-loop logic uses **thin drivers, fat core** — the entire step switch lives in core; drivers expose only a minimal protocol surface.

## Global Constraints

- Swift tools-version 6.0; every target sets `swiftSettings: [.swiftLanguageMode(.v5)]` — copy this onto every new target.
- macOS deployment floor: `.macOS(.v14)`. The `autopilot-core` package itself must NOT declare a macOS-only floor in a way that blocks Linux/iOS — set `platforms` to `[.macOS(.v14), .iOS(.v16)]` so it stays portable; it must not `import AppKit`, `ApplicationServices`, `CoreGraphics`, or `ScreenCaptureKit` anywhere.
- The element-handle abstraction is an existential: `public protocol ElementHandle: Sendable {}`. macOS wraps `AXUIElement` in a final class conforming to it. Core NEVER downcasts; only the macOS driver downcasts `any ElementHandle` back to its concrete type.
- Driver protocol surface (final, agreed): `resolve`, `matchCount`, `waitForPresence`, `perform`, `pointForLastResolved`/point lookup, `readProperty`, `captureElementScreenshot`, `captureMainDisplay`, `captureRegion`, `samplePixel`, `sampleRegion`, `dumpTree`, `findAll`, `suggestSelectors`, `launch`, `attach`, `terminate`, `activate`, `hasAccessibility`, `hasScreenRecording`, plus permission-instruction strings. (Exact signatures are defined in Task 2.)
- All 126 existing tests must keep passing after every task. Integration tests require Accessibility permission + the `Fixtures/TestHostApp/make-app.sh` fixture (already built in CI on `macos-15`).
- Geometry crossing the core boundary uses a platform-neutral `Rect`/`Point` (defined in core), NOT `CGRect`/`CGPoint`. The macOS driver converts at its boundary.
- Public API names stay stable where the CLI and MCP server already call them (`PlanRunner.run(_:options:)`, `RunOptions`, `Reporter`, `PlanParser`, `PlanLinter`, `SelectorSuggester`, `SuiteReport`, `Report`) — these move to core unchanged in signature.
- Do NOT commit/push medit's in-progress branch work. This plan touches only the `autopilot` repo.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Git author is the configured `jschwefel@coldboreballisticsllc.com`; never override with `-c`.
- **Versioning: this is a clean major break — the whole effort ships as `v2.0.0` when complete.** The first `autopilot-core` release is `v2.0.0`; the next `autopilot-macos` release (after extraction) is `v2.0.0`; the `Package.swift` core pin is `from: "2.0.0"`; the Homebrew formula `version` becomes `2.0.0`; and the MCP `serverInfo.version` string in `MCPServer.swift` (currently `"1.0.0"`) becomes `"2.0.0"`. (Future iOS/Android backends will also debut at `2.0.0` to keep the family version-aligned.)
- **Do NOT tag any release until the entire plan is complete.** All Phase 1/2/3 work lands on a development branch (`v2-core-extraction`); intermediate commits are never tagged or released. Only after the final task — both repos building green against each other — does `autopilot-core` get tagged `v2.0.0`, then `autopilot-macos` get tagged `v2.0.0`. Tagging core before macOS is wired to it is fine (macOS needs the tag to pin), but no `v1.x` release ever happens again on either repo.

---

## File Structure

This refactor proceeds in two phases inside the **existing `autopilot-macos` repo**, then a third phase that extracts the agnostic half into the new `autopilot-core` repo.

### Phase 1 — Introduce the seam (in `autopilot-macos`, no repo split yet)

New files (platform-agnostic, will later move to core):
- `Sources/AutopilotCore/Driver/Geometry.swift` — `Point`, `Rect` value types (neutral geometry).
- `Sources/AutopilotCore/Driver/ElementHandle.swift` — `public protocol ElementHandle: Sendable {}` and `ResolvedElement` (handle-or-point).
- `Sources/AutopilotCore/Driver/AppDriver.swift` — the driver protocol(s) + supporting value types (`DriverError`, `LaunchedHandle`, `TreeSnapshot`, `RGBColor`).
- `Sources/AutopilotCore/Driver/ChordValidator.swift` — pure chord-syntax validator (replaces `ActionEngine.parseChord` call in the parser).

New files (macOS driver — the concrete conformance):
- `Sources/AutopilotCore/MacOS/MacOSElement.swift` — `final class MacOSElement: ElementHandle { let ax: AXUIElement }`.
- `Sources/AutopilotCore/MacOS/MacOSDriver.swift` — `struct MacOSDriver: AppDriver` wrapping the existing AX/CGEvent/SCK code.

Modified files (logic split so the agnostic part talks to protocols):
- `Sources/AutopilotCore/Runner/PlanRunner.swift` — depends on `any AppDriver`, no longer imports `ApplicationServices`; step switch uses `ResolvedElement` not `AXUIElement`.
- `Sources/AutopilotCore/Plan/PlanParser.swift` — calls `ChordValidator.validate` instead of `ActionEngine.parseChord`.
- `Sources/AutopilotCore/Assertions/AssertionEngine.swift` — `readProperty(from: AXUIElement)` moves to `MacOSDriver`; the pure `evaluate`/`pollEvaluate` stay.
- `Sources/AutopilotCore/Assertions/PixelColor.swift` — pure RGB algebra stays in core (`RGBColor`); CGImage/screen sampling moves to `MacOSDriver`.
- `Sources/AutopilotCore/Targeting/VisionResolver.swift` — pure NCC `bestMatch` stays; grayscale/CGImage decode moves to `MacOSDriver`.
- `Sources/AutopilotCore/Targeting/AXResolver.swift` — pure `matches(node:selector:)`/`describe` stay; AX-walking `resolveOne`/`findAll`/`count` move into `MacOSDriver`.
- `Sources/AutopilotMCPKit/MCPServer.swift` — constructs a `MacOSDriver` and passes it to `PlanRunner`/targeting calls instead of calling `AXTree`/`Targeting`/`AXResolver` directly.
- `Sources/autopilot/main.swift` — same: inject `MacOSDriver`.

### Phase 2 — Verify the seam holds

No new files; this is the green-bar checkpoint. After Phase 1, `PlanRunner` and the agnostic files import only `Foundation`. A grep gate confirms zero platform imports in the agnostic set.

### Phase 3 — Extract `autopilot-core` repo

- New repo `jschwefel-CBB/autopilot-core` with its own `Package.swift` exposing `AutopilotCore` (agnostic only).
- `autopilot-macos` `Package.swift` adds `.package(url: "https://github.com/jschwefel-CBB/autopilot-core", from: "2.0.0")` and a local `AutopilotMacOS` target (the driver) depending on it.
- The agnostic files physically move to the new repo; the macOS files stay.

### What lands where (final state)

| Module | Repo | Contents |
|---|---|---|
| `AutopilotCore` (library) | `autopilot-core` | Plan model, parser, linter, report, suite report, `PlanRunner`, driver protocols, `Poller`, `Clock`, `evaluate`, pure `PixelColor` algebra, pure `VisionResolver` NCC, `AXResolver.matches`, `SelectorSuggester`, `AXRoles`, `TargetingError`, `ChordValidator`, neutral `Geometry`. |
| `AutopilotMacOS` (library) | `autopilot-macos` | `MacOSDriver`, `MacOSElement`, AX tree, CGEvent synth, ScreenCaptureKit, screenshot/PNG, NSWorkspace launcher, permissions probes, menu navigator, macOS keymap. |
| `autopilot`, `AutopilotMCP` (executables) + `AutopilotMCPKit` | `autopilot-macos` | unchanged responsibilities; now wire `MacOSDriver`. |

---

## Tasks

The tasks are ordered so the codebase **compiles and all tests pass after every single task**. Phase 1 introduces agnostic types and the driver, migrates the runner, and rewires consumers — all in one repo. Phase 3 physically splits the repo. There is no task where `main` is left red.

### Task 1: Neutral geometry + element handle protocol

**Files:**
- Create: `Sources/AutopilotCore/Driver/Geometry.swift`
- Create: `Sources/AutopilotCore/Driver/ElementHandle.swift`
- Test: `Tests/AutopilotCoreTests/GeometryTests.swift`

**Interfaces:**
- Produces: `public struct Point: Equatable, Sendable { public var x: Double; public var y: Double; public init(x:Double,y:Double) }`
- Produces: `public struct Rect: Equatable, Sendable { public var x, y, width, height: Double; public init(x:Double,y:Double,width:Double,height:Double); public var midX: Double; public var midY: Double }`
- Produces: `public protocol ElementHandle: AnyObject, Sendable {}`
- Produces: `public enum ResolvedElement { case element(any ElementHandle); case point(Point) }`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AutopilotCoreTests/GeometryTests.swift
import XCTest
@testable import AutopilotCore

final class GeometryTests: XCTestCase {
    func testRectMidpoints() {
        let r = Rect(x: 10, y: 20, width: 100, height: 40)
        XCTAssertEqual(r.midX, 60)
        XCTAssertEqual(r.midY, 40)
    }
    func testPointEquatable() {
        XCTAssertEqual(Point(x: 1, y: 2), Point(x: 1, y: 2))
        XCTAssertNotEqual(Point(x: 1, y: 2), Point(x: 2, y: 1))
    }
    func testResolvedElementPointCase() {
        let re = ResolvedElement.point(Point(x: 5, y: 6))
        guard case .point(let p) = re else { return XCTFail("expected point") }
        XCTAssertEqual(p, Point(x: 5, y: 6))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GeometryTests`
Expected: FAIL — `cannot find 'Rect' in scope` (types not defined yet).

- [ ] **Step 3: Write the geometry types**

```swift
// Sources/AutopilotCore/Driver/Geometry.swift
import Foundation

/// Platform-neutral 2D point. Drivers convert to/from CGPoint at their boundary.
public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Platform-neutral rectangle. Drivers convert to/from CGRect at their boundary.
public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}
```

- [ ] **Step 4: Write the element handle protocol**

```swift
// Sources/AutopilotCore/Driver/ElementHandle.swift
import Foundation

/// An opaque, backend-defined handle to a resolved UI element. Core never
/// inspects it; only the owning driver downcasts it back to its concrete type.
/// AnyObject so a backend can hold a reference type (e.g. an AXUIElement box).
public protocol ElementHandle: AnyObject, Sendable {}

/// The result of resolving a selector: either a real element handle, or a bare
/// screen point produced by the vision (template-match) fallback when no element
/// handle is available.
public enum ResolvedElement {
    case element(any ElementHandle)
    case point(Point)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter GeometryTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AutopilotCore/Driver/Geometry.swift Sources/AutopilotCore/Driver/ElementHandle.swift Tests/AutopilotCoreTests/GeometryTests.swift
git commit -m "feat(core): add neutral geometry and ElementHandle protocol"
```

---

### Task 2: AppDriver protocol + supporting value types

**Files:**
- Create: `Sources/AutopilotCore/Driver/AppDriver.swift`
- Test: `Tests/AutopilotCoreTests/FakeDriverTests.swift`

**Interfaces:**
- Consumes: `Point`, `Rect`, `ResolvedElement`, `any ElementHandle` (Task 1); `Selector`, `Action`, `ActionArgs`, `AssertProperty`, `TargetApp`, `TargetingError` (existing).
- Produces: `public struct RGBColor: Equatable, Sendable { public var r, g, b: Int; public init(r:Int,g:Int,b:Int) }`
- Produces: `public struct LaunchedHandle: Sendable { public let pid: Int32; public let appName: String; public init(pid:Int32, appName:String) }`
- Produces: `public struct TreeSnapshot: Sendable { public let nodes: [[String:String]]; public let truncated: Bool; public init(nodes:[[String:String]], truncated:Bool) }`
- Produces: `public protocol AppDriver` with the full method surface (below). All methods are the seam between core orchestration and a platform backend.

The driver protocol is the heart of the abstraction. Every method core needs from a platform appears here. The macOS driver (Task 9) implements all of it; future iOS/Android drivers implement the same protocol.

- [ ] **Step 1: Write the failing test (a Fake driver proving the protocol is implementable in pure Swift)**

```swift
// Tests/AutopilotCoreTests/FakeDriverTests.swift
import XCTest
@testable import AutopilotCore

/// A pure-Swift fake proves the AppDriver protocol carries no platform types —
/// if this compiles and runs with zero platform imports, the seam is clean.
final class FakeElement: ElementHandle { let id: String; init(_ id: String) { self.id = id } }

struct FakeDriver: AppDriver {
    var nodes: [[String: String]] = []
    func launch(_ target: TargetApp) throws -> LaunchedHandle { LaunchedHandle(pid: 1, appName: "Fake") }
    func attach(_ target: TargetApp) throws -> LaunchedHandle { LaunchedHandle(pid: 1, appName: "Fake") }
    func attach(pid: Int32) throws -> LaunchedHandle { LaunchedHandle(pid: pid, appName: "Fake") }
    func terminate(_ app: LaunchedHandle) {}
    func activate(_ app: LaunchedHandle, timeoutMs: Int, intervalMs: Int) -> Bool { true }
    func hasAccessibility() -> Bool { true }
    func hasScreenRecording() -> Bool { true }
    func accessibilityInstructions() -> String { "grant ax" }
    func screenRecordingInstructions() -> String { "grant sr" }
    func resolve(_ selector: Selector, app: LaunchedHandle, timeoutMs: Int, intervalMs: Int, baseDir: URL?) throws -> ResolvedElement {
        if nodes.contains(where: { AXResolverMatchShim.matches($0, selector) }) { return .element(FakeElement("x")) }
        throw TargetingError.notFound(selector: "{}")
    }
    func waitForPresence(_ selector: Selector, present: Bool, app: LaunchedHandle, timeoutMs: Int, intervalMs: Int) -> Bool { present }
    func matchCount(_ selector: Selector, app: LaunchedHandle) -> Int { nodes.count }
    func findAll(_ selector: Selector, app: LaunchedHandle) -> [String] { [] }
    func perform(action: Action, args: ActionArgs?, on element: ResolvedElement?) throws {}
    func point(for element: ResolvedElement) -> Point? { if case .point(let p) = element { return p }; return Point(x: 0, y: 0) }
    func performDrag(from: Point, to: Point) throws {}
    func selectMenuPath(_ path: [String], app: LaunchedHandle) throws {}
    func readProperty(_ property: AssertProperty, of element: any ElementHandle) -> String? { "fake" }
    func captureElementScreenshot(_ element: any ElementHandle, to path: String, padding: Int, metadata: [String: String]) -> String? { nil }
    func captureMainDisplay(to path: String, metadata: [String: String]) -> Bool { true }
    func captureRegion(_ rect: Rect, to path: String, metadata: [String: String]) -> Bool { true }
    func samplePixel(at point: Point) -> RGBColor? { RGBColor(r: 0, g: 0, b: 0) }
    func sampleRegion(_ rect: Rect) -> [RGBColor] { [] }
    func loadPNG(_ path: String) -> [RGBColor]? { nil }
    func dumpTree(app: LaunchedHandle) -> TreeSnapshot { TreeSnapshot(nodes: nodes, truncated: false) }
    func suggestSelectors(app: LaunchedHandle) -> [SelectorSuggester.Suggestion] { [] }
}

/// Shim so the test can reuse the pure matcher without importing it under a new name.
enum AXResolverMatchShim { static func matches(_ n: [String:String], _ s: Selector) -> Bool { AXResolver.matches(node: n, selector: s) } }

final class FakeDriverTests: XCTestCase {
    func testFakeResolvesKnownNode() throws {
        let d = FakeDriver(nodes: [["role": "AXButton", "identifier": "ok"]])
        let app = try d.launch(TargetApp(bundleId: "x"))
        let re = try d.resolve(Selector(identifier: "ok"), app: app, timeoutMs: 100, intervalMs: 10, baseDir: nil)
        guard case .element = re else { return XCTFail("expected element") }
    }
    func testFakeThrowsOnMissing() throws {
        let d = FakeDriver(nodes: [])
        let app = try d.launch(TargetApp(bundleId: "x"))
        XCTAssertThrowsError(try d.resolve(Selector(identifier: "nope"), app: app, timeoutMs: 100, intervalMs: 10, baseDir: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FakeDriverTests`
Expected: FAIL — `cannot find type 'AppDriver' in scope`, etc.

Note: the suggester's element type is `SelectorSuggester.Suggestion` (confirmed: `public struct Suggestion: Equatable` nested in `enum SelectorSuggester`, with fields `role`, `label`, `selector`, `note`). The protocol's `suggestSelectors` returns `[SelectorSuggester.Suggestion]`. Do not introduce a new type.

- [ ] **Step 3: Write the protocol + value types**

```swift
// Sources/AutopilotCore/Driver/AppDriver.swift
import Foundation

/// An 8-bit RGB color sampled from the screen. Neutral replacement for the
/// macOS-only PixelColor.RGB at the driver boundary.
public struct RGBColor: Equatable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int
    public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
}

/// A launched/attached app, identified by pid + display name. Neutral
/// replacement for the macOS-only LaunchedApp at the driver boundary.
public struct LaunchedHandle: Sendable {
    public let pid: Int32
    public let appName: String
    public init(pid: Int32, appName: String) { self.pid = pid; self.appName = appName }
}

/// A flattened element-tree snapshot: each node is a [attribute: value] dict,
/// `truncated` true if the walk hit its node cap before finishing.
public struct TreeSnapshot: Sendable {
    public let nodes: [[String: String]]
    public let truncated: Bool
    public init(nodes: [[String: String]], truncated: Bool) {
        self.nodes = nodes; self.truncated = truncated
    }
}

/// Everything PlanRunner needs from a platform. A backend (macOS AX, iOS
/// XCUITest, Android via Appium) implements this; core orchestration depends
/// only on this protocol and never on any platform API.
public protocol AppDriver {
    // Lifecycle
    func launch(_ target: TargetApp) throws -> LaunchedHandle
    func attach(_ target: TargetApp) throws -> LaunchedHandle
    func attach(pid: Int32) throws -> LaunchedHandle
    func terminate(_ app: LaunchedHandle)
    func activate(_ app: LaunchedHandle, timeoutMs: Int, intervalMs: Int) -> Bool

    // Permissions
    func hasAccessibility() -> Bool
    func hasScreenRecording() -> Bool
    func accessibilityInstructions() -> String
    func screenRecordingInstructions() -> String

    // Resolution
    func resolve(_ selector: Selector, app: LaunchedHandle,
                 timeoutMs: Int, intervalMs: Int, baseDir: URL?) throws -> ResolvedElement
    func waitForPresence(_ selector: Selector, present: Bool, app: LaunchedHandle,
                         timeoutMs: Int, intervalMs: Int) -> Bool
    func matchCount(_ selector: Selector, app: LaunchedHandle) -> Int
    func findAll(_ selector: Selector, app: LaunchedHandle) -> [String]

    // Actions
    func perform(action: Action, args: ActionArgs?, on element: ResolvedElement?) throws
    func point(for element: ResolvedElement) -> Point?
    /// Drag from one screen point to another (file-less; coordinate drag only).
    /// The runner resolves both endpoints to points, then calls this.
    func performDrag(from: Point, to: Point) throws
    /// Select a menu-bar path (e.g. ["File", "Save As…"]) on the app.
    func selectMenuPath(_ path: [String], app: LaunchedHandle) throws

    // Property read (assertions)
    func readProperty(_ property: AssertProperty, of element: any ElementHandle) -> String?

    // Visual capture
    func captureElementScreenshot(_ element: any ElementHandle, to path: String,
                                  padding: Int, metadata: [String: String]) -> String?
    func captureMainDisplay(to path: String, metadata: [String: String]) -> Bool
    func captureRegion(_ rect: Rect, to path: String, metadata: [String: String]) -> Bool
    func samplePixel(at point: Point) -> RGBColor?
    func sampleRegion(_ rect: Rect) -> [RGBColor]
    /// Load a PNG into a flat row-major pixel array (for snapshot diffing).
    func loadPNG(_ path: String) -> [RGBColor]?

    // Inspection
    func dumpTree(app: LaunchedHandle) -> TreeSnapshot
    func suggestSelectors(app: LaunchedHandle) -> [SelectorSuggester.Suggestion]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FakeDriverTests`
Expected: PASS (2 tests). The whole point: a driver implemented in pure Swift, no platform imports, compiles against the protocol.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutopilotCore/Driver/AppDriver.swift Tests/AutopilotCoreTests/FakeDriverTests.swift
git commit -m "feat(core): add AppDriver protocol and neutral driver value types"
```

---

### Task 3: Pure ChordValidator (sever the parser's macOS dependency)

**Files:**
- Create: `Sources/AutopilotCore/Driver/ChordValidator.swift`
- Modify: `Sources/AutopilotCore/Plan/PlanParser.swift:107`
- Test: `Tests/AutopilotCoreTests/ChordValidatorTests.swift`

**Interfaces:**
- Produces: `public enum ChordValidator { public static func validate(_ s: String) throws }` — throws `PlanError.unsupportedKey`/`PlanError.decode` on an unparseable chord, returns void on success. Pure string logic; no CoreGraphics.
- Consumes: nothing platform. Replaces the `_ = try ActionEngine.parseChord(keys)` call at `PlanParser.swift:107`.

**Context:** `PlanParser.swift:107` currently calls `ActionEngine.parseChord(keys)` purely to *validate* a key chord at parse time (it discards the result with `_ =`). `ActionEngine` is macOS-only (returns a `Chord` of `CGKeyCode`/`CGEventFlags`). This is the single line dragging macOS into the otherwise-agnostic parser. `ChordValidator` reproduces the *validation* (same accepted tokens) without producing CoreGraphics types. The macOS `ActionEngine.parseChord` stays as-is for actual event synthesis; only the parser's validation call changes.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AutopilotCoreTests/ChordValidatorTests.swift
import XCTest
@testable import AutopilotCore

final class ChordValidatorTests: XCTestCase {
    func testAcceptsModifiersAndNamedKey() throws {
        XCTAssertNoThrow(try ChordValidator.validate("cmd+s"))
        XCTAssertNoThrow(try ChordValidator.validate("cmd+shift+z"))
        XCTAssertNoThrow(try ChordValidator.validate("cmd+plus"))
        XCTAssertNoThrow(try ChordValidator.validate("return"))
        XCTAssertNoThrow(try ChordValidator.validate("f5"))
        XCTAssertNoThrow(try ChordValidator.validate("cmd+comma"))
    }
    func testRejectsUnknownModifier() {
        XCTAssertThrowsError(try ChordValidator.validate("hyper+s"))
    }
    func testRejectsUnknownKey() {
        XCTAssertThrowsError(try ChordValidator.validate("cmd+notakey"))
    }
    func testRejectsEmpty() {
        XCTAssertThrowsError(try ChordValidator.validate(""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChordValidatorTests`
Expected: FAIL — `cannot find 'ChordValidator' in scope`.

- [ ] **Step 3: Write the validator**

The accepted token sets must match `ActionEngine`'s exactly (letters/digits/punctuation in `letterKeyCodes`, names in `namedKeyCodes`, modifiers, and the `plus` special-case). Reproduce them as `Set<String>`/`Set<Character>` of keys (not the keycode values — validation only needs membership).

```swift
// Sources/AutopilotCore/Driver/ChordValidator.swift
import Foundation

/// Pure, platform-agnostic validation of a key-chord string ("cmd+shift+z").
/// Mirrors the token vocabulary ActionEngine.parseChord accepts, but produces
/// no platform types — used by PlanParser to reject bad chords at parse time.
public enum ChordValidator {
    /// Single-character keys ActionEngine maps (ANSI letters, digits, punctuation).
    static let singleCharKeys: Set<Character> = [
        "a","s","d","f","h","g","z","x","c","v","b","q","w","e","r","y","t",
        "o","u","i","p","l","j","k","n","m",
        "1","2","3","4","5","6","7","8","9","0",
        "=","-","]","[","'",";","\\",",","/",".","`"
    ]
    /// Named keys ActionEngine maps.
    static let namedKeys: Set<String> = [
        "return","enter","tab","space","delete","forwarddelete","escape",
        "left","right","down","up","home","end","pageup","pagedown",
        "comma","period","slash","semicolon","quote","leftbracket","rightbracket",
        "backslash","grave","minus","equal",
        "f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f11","f12"
    ]
    static let modifiers: Set<String> = [
        "cmd","command","shift","opt","option","alt","ctrl","control"
    ]

    public static func validate(_ s: String) throws {
        let parts = s.lowercased().split(separator: "+").map(String.init)
        guard let keyToken = parts.last, !keyToken.isEmpty else {
            throw PlanError.decode("empty key chord")
        }
        for mod in parts.dropLast() {
            guard modifiers.contains(mod) else { throw PlanError.unsupportedKey("modifier '\(mod)'") }
        }
        // `plus` is the literal plus key (Shift+'=' on ANSI); always valid as a key token.
        if keyToken == "plus" { return }
        if namedKeys.contains(keyToken) { return }
        if keyToken.count == 1, let ch = keyToken.first, singleCharKeys.contains(ch) { return }
        throw PlanError.unsupportedKey(keyToken)
    }
}
```

- [ ] **Step 4: Run the new test to verify it passes**

Run: `swift test --filter ChordValidatorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Switch the parser to the pure validator**

In `Sources/AutopilotCore/Plan/PlanParser.swift`, replace line 107:

```swift
            _ = try ActionEngine.parseChord(keys)
```

with:

```swift
            try ChordValidator.validate(keys)
```

- [ ] **Step 6: Run the parser tests to verify nothing regressed**

Run: `swift test --filter PlanParserTests`
Expected: PASS — all existing parser tests still pass, including any that assert a bad chord is rejected at parse time.

- [ ] **Step 7: Commit**

```bash
git add Sources/AutopilotCore/Driver/ChordValidator.swift Sources/AutopilotCore/Plan/PlanParser.swift Tests/AutopilotCoreTests/ChordValidatorTests.swift
git commit -m "refactor(core): validate key chords with pure ChordValidator in parser"
```

---

### Task 4: Split PixelColor — pure algebra stays, sampling moves out

**Files:**
- Modify: `Sources/AutopilotCore/Assertions/PixelColor.swift`
- Create: `Sources/AutopilotCore/MacOS/MacOSPixelSampler.swift`
- Test: `Tests/AutopilotCoreTests/PixelColorTests.swift` (existing — keep passing; add a conversion test)

**Interfaces:**
- `PixelColor` keeps ONLY pure algebra and drops `import CoreGraphics`/`import AppKit`: `RGB`, `parseHex`, `distance`, `matches`, `average`, `dominant`, `diffFraction`. These remain `public static`.
- Produces (new bridge): `extension PixelColor.RGB { var asRGBColor: RGBColor }` and `init(_ c: RGBColor)` so the runner can convert between the assertion algebra type and the neutral driver `RGBColor`.
- Moves to macOS: `sRGBPixels(of:)`, `sampleRegion(_ rect: CGRect)`, `loadPNG`, `sample(at: CGPoint)` → become methods on `MacOSPixelSampler` returning `[PixelColor.RGB]`/`PixelColor.RGB?`.

**Context:** `PixelColor` currently imports `CoreGraphics` + `AppKit` only for the four sampling functions. The color math (`distance`, `average`, `dominant`, `diffFraction`, `parseHex`, `matches`) is pure. Move the four image/screen functions to a macOS-only file; keep the algebra agnostic. The runner (Task 9) will call the driver's `samplePixel`/`sampleRegion` (returning neutral `RGBColor`) and convert to `PixelColor.RGB` for the algebra.

- [ ] **Step 1: Add the failing conversion test**

```swift
// Add to Tests/AutopilotCoreTests/PixelColorTests.swift
func testRGBColorBridgeRoundTrips() {
    let neutral = RGBColor(r: 10, g: 20, b: 30)
    let algebra = PixelColor.RGB(neutral)
    XCTAssertEqual(algebra.r, 10); XCTAssertEqual(algebra.g, 20); XCTAssertEqual(algebra.b, 30)
    XCTAssertEqual(algebra.asRGBColor, neutral)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PixelColorTests/testRGBColorBridgeRoundTrips`
Expected: FAIL — `cannot find 'RGBColor'`/missing initializer.

- [ ] **Step 3: Reduce PixelColor to pure algebra + the bridge**

Rewrite `Sources/AutopilotCore/Assertions/PixelColor.swift` to drop the platform imports and the four sampling functions, and add the bridge:

```swift
import Foundation

/// Deterministic pixel-color algebra. Sampling lives in the platform driver;
/// this file is pure and portable. No LLM — a fixed Euclidean RGB threshold.
public enum PixelColor {
    public struct RGB: Equatable {
        public var r: Int; public var g: Int; public var b: Int   // 0...255
        public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
    }

    public static func parseHex(_ hex: String) -> RGB? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return RGB(r: (v >> 16) & 0xFF, g: (v >> 8) & 0xFF, b: v & 0xFF)
    }
    public static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = Double(a.r - b.r), dg = Double(a.g - b.g), db = Double(a.b - b.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
    public static func matches(_ actual: RGB, _ expected: RGB, tolerance: Double) -> Bool {
        distance(actual, expected) <= tolerance
    }
    public static func average(of pixels: [RGB]) -> RGB? {
        guard !pixels.isEmpty else { return nil }
        var r = 0, g = 0, b = 0
        for p in pixels { r += p.r; g += p.g; b += p.b }
        let n = pixels.count
        return RGB(r: r / n, g: g / n, b: b / n)
    }
    public static func dominant(of pixels: [RGB], buckets: Int = 16) -> RGB? {
        guard !pixels.isEmpty, buckets > 0 else { return nil }
        let step = 256 / buckets
        func bucket(_ v: Int) -> Int { v / step }
        var counts: [Int: Int] = [:]
        var sums: [Int: (r: Int, g: Int, b: Int)] = [:]
        for p in pixels {
            let key = (bucket(p.r) << 16) | (bucket(p.g) << 8) | bucket(p.b)
            counts[key, default: 0] += 1
            var s = sums[key] ?? (0, 0, 0)
            s.r += p.r; s.g += p.g; s.b += p.b
            sums[key] = s
        }
        let best = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }!
        let s = sums[best.key]!, n = best.value
        return RGB(r: s.r / n, g: s.g / n, b: s.b / n)
    }
    public static func diffFraction(_ a: [RGB], _ b: [RGB], perPixelTolerance: Double) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var differing = 0
        for i in a.indices where distance(a[i], b[i]) > perPixelTolerance { differing += 1 }
        return Double(differing) / Double(a.count)
    }
}

/// Bridge between the assertion algebra type and the neutral driver color type.
public extension PixelColor.RGB {
    init(_ c: RGBColor) { self.init(r: c.r, g: c.g, b: c.b) }
    var asRGBColor: RGBColor { RGBColor(r: r, g: g, b: b) }
}
```

- [ ] **Step 4: Create the macOS sampler with the moved functions**

```swift
// Sources/AutopilotCore/MacOS/MacOSPixelSampler.swift
import Foundation
import CoreGraphics
import AppKit

/// macOS screen/PNG pixel sampling — the platform half of the old PixelColor.
/// Returns PixelColor.RGB so the pure algebra in core can consume it.
enum MacOSPixelSampler {
    static func sRGBPixels(of image: CGImage) -> [PixelColor.RGB] {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [PixelColor.RGB] = []; out.reserveCapacity(w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            out.append(PixelColor.RGB(r: Int(buf[o]), g: Int(buf[o + 1]), b: Int(buf[o + 2])))
        }
        return out
    }
    static func sampleRegion(_ rect: CGRect) -> [PixelColor.RGB] {
        guard let image = try? ScreenCapture.image(of: rect) else { return [] }
        return sRGBPixels(of: image)
    }
    static func loadPNG(_ path: String) -> [PixelColor.RGB]? {
        guard let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return sRGBPixels(of: cg)
    }
    static func sample(at point: CGPoint) -> PixelColor.RGB? {
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        guard let image = try? ScreenCapture.image(of: rect) else { return nil }
        return sRGBPixels(of: image).first
    }
}
```

- [ ] **Step 5: Run the full suite to verify nothing references the moved functions yet**

Run: `swift build`
Expected: FAIL — `PlanRunner` and any caller of `PixelColor.sample`/`sampleRegion`/`loadPNG` no longer compile. THIS IS EXPECTED at this step; those call sites are migrated in Task 9 (runner). To keep the tree green *between* tasks, this task adds a temporary compatibility shim:

Add to the bottom of `MacOSPixelSampler.swift`:

```swift
// TEMPORARY back-compat shim so PlanRunner keeps compiling until Task 9 migrates
// it to the driver. Removed in Task 9.
extension PixelColor {
    static func sampleRegion(_ rect: CGRect) -> [RGB] { MacOSPixelSampler.sampleRegion(rect) }
    static func loadPNG(_ path: String) -> [RGB]? { MacOSPixelSampler.loadPNG(path) }
    static func sample(at point: CGPoint) -> RGB? { MacOSPixelSampler.sample(at: point) }
}
```

- [ ] **Step 6: Run build + tests**

Run: `swift build && swift test --filter PixelColorTests`
Expected: PASS — build succeeds via the shim; PixelColorTests pass (existing + new bridge test).

- [ ] **Step 7: Commit**

```bash
git add Sources/AutopilotCore/Assertions/PixelColor.swift Sources/AutopilotCore/MacOS/MacOSPixelSampler.swift Tests/AutopilotCoreTests/PixelColorTests.swift
git commit -m "refactor(core): split PixelColor into pure algebra + macOS sampler"
```

---

### Task 5: Split VisionResolver — pure NCC stays, image decode moves out

**Files:**
- Modify: `Sources/AutopilotCore/Targeting/VisionResolver.swift`
- Create: `Sources/AutopilotCore/MacOS/MacOSImageDecoder.swift`
- Test: `Tests/AutopilotCoreTests/VisionResolverTests.swift` (create if absent; otherwise extend)

**Interfaces:**
- `VisionResolver` keeps ONLY `Match` and `bestMatch(haystack:needle:)` and drops `import CoreGraphics`/`import AppKit`.
- Moves to macOS: `grayscaleBuffer(pngPath:)`, `grayscaleBuffer(of: CGImage)`, `grayscale(from: CGImage)` → `MacOSImageDecoder`.

**Context:** `bestMatch` is pure math over `[[Double]]`. The grayscale loaders need CoreGraphics/AppKit. The only caller of the grayscale loaders is `Targeting.resolve`'s vision fallback (which moves into the macOS driver in Task 8). So no temporary shim is needed here — but `Targeting` still references them until Task 8. To keep green, Task 5 leaves a shim on `VisionResolver` delegating to `MacOSImageDecoder`, removed in Task 8.

- [ ] **Step 1: Write/confirm the failing test for pure bestMatch**

```swift
// Tests/AutopilotCoreTests/VisionResolverTests.swift
import XCTest
@testable import AutopilotCore

final class VisionResolverTests: XCTestCase {
    func testBestMatchFindsNeedle() {
        // 3x3 haystack with a 2x2 bright block at (1,1).
        let haystack: [[Double]] = [
            [0,0,0],
            [0,1,1],
            [0,1,1],
        ]
        let needle: [[Double]] = [[1,1],[1,1]]
        let m = VisionResolver.bestMatch(haystack: haystack, needle: needle)
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.x, 1); XCTAssertEqual(m?.y, 1)
    }
    func testZeroVarianceNeedleReturnsNil() {
        XCTAssertNil(VisionResolver.bestMatch(haystack: [[0.5,0.5],[0.5,0.5]], needle: [[0.5]]))
    }
}
```

- [ ] **Step 2: Run to verify it fails or passes**

Run: `swift test --filter VisionResolverTests`
Expected: PASS already if the file exists (bestMatch is unchanged) — that's fine; this test pins the behavior we must preserve through the split. If VisionResolverTests is new, it should PASS immediately.

- [ ] **Step 3: Reduce VisionResolver to pure NCC**

Rewrite `Sources/AutopilotCore/Targeting/VisionResolver.swift` to keep only `Match` + `bestMatch` (drop the two `import`s and the three grayscale functions). Keep `bestMatch`'s body byte-for-byte as it is today.

```swift
import Foundation

/// Deterministic template matching via normalized cross-correlation.
/// Pure math over grayscale buffers; image decoding lives in the platform driver.
public enum VisionResolver {
    public struct Match { public var x: Int; public var y: Int; public var score: Double }

    public static func bestMatch(haystack: [[Double]], needle: [[Double]]) -> Match? {
        let H = haystack.count, W = haystack.first?.count ?? 0
        let h = needle.count, w = needle.first?.count ?? 0
        guard H >= h, W >= w, h > 0, w > 0 else { return nil }
        var nSum = 0.0
        for row in needle { for v in row { nSum += v } }
        let nMean = nSum / Double(h * w)
        var nVar = 0.0
        for row in needle { for v in row { nVar += (v - nMean) * (v - nMean) } }
        guard nVar > 0 else { return nil }
        var best: Match? = nil
        for oy in 0...(H - h) {
            for ox in 0...(W - w) {
                var wSum = 0.0
                for y in 0..<h { for x in 0..<w { wSum += haystack[oy + y][ox + x] } }
                let wMean = wSum / Double(h * w)
                var cov = 0.0, wVar = 0.0
                for y in 0..<h {
                    for x in 0..<w {
                        let a = haystack[oy + y][ox + x] - wMean
                        let b = needle[y][x] - nMean
                        cov += a * b
                        wVar += a * a
                    }
                }
                guard wVar > 0 else { continue }
                let score = cov / (wVar.squareRoot() * nVar.squareRoot())
                if best == nil || score > best!.score { best = Match(x: ox, y: oy, score: score) }
            }
        }
        return best
    }
}
```

- [ ] **Step 4: Create the macOS image decoder with the moved functions + a temporary shim**

```swift
// Sources/AutopilotCore/MacOS/MacOSImageDecoder.swift
import Foundation
import CoreGraphics
import AppKit

/// macOS grayscale decoding for the vision template matcher — the platform half
/// of the old VisionResolver.
enum MacOSImageDecoder {
    static func grayscaleBuffer(pngPath: String) -> [[Double]]? {
        guard let img = NSImage(contentsOfFile: pngPath),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return grayscale(from: cg)
    }
    static func grayscaleBuffer(of image: CGImage) -> [[Double]]? { grayscale(from: image) }
    static func grayscale(from cg: CGImage) -> [[Double]]? {
        let width = cg.width, height = cg.height
        let cs = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rows = Array(repeating: Array(repeating: 0.0, count: width), count: height)
        for y in 0..<height { for x in 0..<width { rows[y][x] = Double(pixels[y * width + x]) / 255.0 } }
        return rows
    }
}

// TEMPORARY back-compat shim so Targeting keeps compiling until Task 8 moves the
// vision fallback into MacOSDriver. Removed in Task 8.
extension VisionResolver {
    static func grayscaleBuffer(pngPath: String) -> [[Double]]? { MacOSImageDecoder.grayscaleBuffer(pngPath: pngPath) }
    static func grayscaleBuffer(of image: CGImage) -> [[Double]]? { MacOSImageDecoder.grayscaleBuffer(of: image) }
}
```

- [ ] **Step 5: Run build + the two test files**

Run: `swift build && swift test --filter VisionResolverTests`
Expected: PASS — build succeeds via shim; bestMatch tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AutopilotCore/Targeting/VisionResolver.swift Sources/AutopilotCore/MacOS/MacOSImageDecoder.swift Tests/AutopilotCoreTests/VisionResolverTests.swift
git commit -m "refactor(core): split VisionResolver into pure NCC + macOS decoder"
```

---

### Task 6: Split AssertionEngine — pure compare stays, AX read moves to driver

**Files:**
- Modify: `Sources/AutopilotCore/Assertions/AssertionEngine.swift`
- Create: `Sources/AutopilotCore/MacOS/MacOSPropertyReader.swift`
- Test: `Tests/AutopilotCoreTests/AssertionEngineTests.swift` (existing — keep passing)

**Interfaces:**
- `AssertionEngine` keeps `PollOutcome`, `pollEvaluate(...)`, `evaluate(...)` and DROPS `import ApplicationServices` and `readProperty(_:from: AXUIElement)`.
- Moves to macOS: `readProperty(_ property: AssertProperty, from element: AXUIElement) -> String?` → `MacOSPropertyReader.read(_:from:)`. The macOS driver's `readProperty(_:of: any ElementHandle)` downcasts to `MacOSElement` and calls this.

**Context:** `AssertionEngine.evaluate`/`pollEvaluate` are pure. `pollEvaluate` already takes a `readActual: () -> String` closure — so the AX read is already injectable. Only `readProperty(from: AXUIElement)` is macOS. Move it verbatim into `MacOSPropertyReader`.

- [ ] **Step 1: Confirm existing pure tests pin evaluate/pollEvaluate**

Run: `swift test --filter AssertionEngineTests`
Expected: PASS (existing). These cover `evaluate` ops; we must keep them green.

- [ ] **Step 2: Remove readProperty + import from AssertionEngine**

In `Sources/AutopilotCore/Assertions/AssertionEngine.swift`: delete `import ApplicationServices` (line 2) and delete the entire `readProperty(_:from:)` method (lines 50–72). Leave `evaluate`, `pollEvaluate`, `PollOutcome` untouched. The file now imports only `Foundation`.

- [ ] **Step 3: Create the macOS property reader (verbatim move)**

```swift
// Sources/AutopilotCore/MacOS/MacOSPropertyReader.swift
import Foundation
import ApplicationServices

/// Reads AssertProperty values off a live AX element — the platform half of the
/// old AssertionEngine.readProperty.
enum MacOSPropertyReader {
    static func read(_ property: AssertProperty, from element: AXUIElement) -> String? {
        switch property {
        case .value: return AXTree.valueString(element, kAXValueAttribute as String)
        case .title: return AXTree.string(element, kAXTitleAttribute as String)
        case .enabled: return AXTree.bool(element, kAXEnabledAttribute as String).map { $0 ? "true" : "false" }
        case .focused: return AXTree.bool(element, kAXFocusedAttribute as String).map { $0 ? "true" : "false" }
        case .position:
            guard let f = AXTree.frame(element) else { return nil }
            return "\(Int(f.minX)),\(Int(f.minY))"
        case .size:
            guard let f = AXTree.frame(element) else { return nil }
            return "\(Int(f.width)),\(Int(f.height))"
        case .marked:
            let mark = AXTree.menuMarkChar(element) ?? ""
            return mark.isEmpty ? "false" : "true"
        case .count:
            return nil
        }
    }
}
```

- [ ] **Step 4: Build — expect the one caller (PlanRunner) to break**

Run: `swift build`
Expected: FAIL — `PlanRunner.runAssert` calls `assertions.readProperty(...)`, which no longer exists. EXPECTED; migrated in Task 9. Add a TEMPORARY shim to keep green:

Add to the bottom of `MacOSPropertyReader.swift`:

```swift
// TEMPORARY back-compat shim so PlanRunner keeps compiling until Task 9.
extension AssertionEngine {
    func readProperty(_ property: AssertProperty, from element: AXUIElement) -> String? {
        MacOSPropertyReader.read(property, from: element)
    }
}
```

(The shim needs `import ApplicationServices` in that file — already present.)

- [ ] **Step 5: Build + tests**

Run: `swift build && swift test --filter AssertionEngineTests`
Expected: PASS — build via shim, assertion tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/AutopilotCore/Assertions/AssertionEngine.swift Sources/AutopilotCore/MacOS/MacOSPropertyReader.swift
git commit -m "refactor(core): split AssertionEngine pure compare from macOS AX read"
```

---

### Task 7: Split AXResolver — pure matcher stays, AX walk moves to a macOS resolver

**Files:**
- Modify: `Sources/AutopilotCore/Targeting/AXResolver.swift`
- Create: `Sources/AutopilotCore/MacOS/MacOSAXResolver.swift`
- Test: `Tests/AutopilotCoreTests/SelectorResolutionTests.swift` (existing — keep passing)

**Interfaces:**
- `AXResolver` keeps the pure statics and DROPS `import ApplicationServices`: `static matches(node: [String:String], selector:) -> Bool`, `static describe(_ s: Selector) -> String`, and `static let maxReportedMatches`. It becomes an agnostic `enum` (currently a `struct` with an `init`; convert to `enum` since only statics remain, OR keep `struct` with the statics — keep `struct AXResolver { public init() {} }` to avoid touching call sites that say `AXResolver()`, but ensure no instance methods remain). **Decision: keep it a `struct` named `AXResolver` with ONLY the pure statics; move all instance methods out.**
- Moves to macOS: `node(of:)`, `describeNode(_:)`, `rootFor(_:in:)`, `resolveOne(in:selector:)`, `findAll(in:selector:)`, `count(in:selector:stopAt:)` → `MacOSAXResolver` (a `struct` with `public init()`), operating on `AXUIElement`.

**Context:** `AXResolver.matches`/`describe` are pure (operate on `[String:String]` + `Selector`). Everything else walks `AXUIElement`. Move the walkers to `MacOSAXResolver`; the macOS driver (Task 8) uses it. The existing `SelectorResolutionTests` likely call the instance walkers against a live app — those tests move to exercising `MacOSAXResolver` (same method names, new type). Update the test's resolver construction from `AXResolver()` to `MacOSAXResolver()` where it calls `resolveOne`/`findAll`/`count`.

- [ ] **Step 1: Read the existing resolution test to see which methods it calls**

Run: `swift test --filter SelectorResolutionTests` first to confirm current green, then read `Tests/AutopilotCoreTests/SelectorResolutionTests.swift` to inventory calls to `AXResolver().resolveOne/findAll/count` and `AXResolver.matches/describe`.

- [ ] **Step 2: Reduce AXResolver to the pure statics**

Rewrite `Sources/AutopilotCore/Targeting/AXResolver.swift` to drop `import ApplicationServices` and keep only `matches`, `describe`, `maxReportedMatches`:

```swift
import Foundation

/// Pure selector matching + description. The AX-tree walk lives in the platform
/// driver (MacOSAXResolver); this half is portable.
public struct AXResolver {
    public init() {}

    /// Pure predicate: does a snapshot node satisfy the selector?
    /// All present predicates are ANDed. An all-nil selector matches nothing.
    public static func matches(node: [String: String], selector: Selector) -> Bool {
        var anyPredicate = false
        func check(_ value: String?, _ key: String) -> Bool {
            guard let value else { return true }
            anyPredicate = true
            return node[key] == value
        }
        let ok = check(selector.role, "role")
            && check(selector.identifier, "identifier")
            && check(selector.title, "title")
            && check(selector.label, "label")
            && check(selector.value, "value")
        return anyPredicate && ok
    }

    static let maxReportedMatches = 5

    public static func describe(_ s: Selector) -> String {
        var parts: [String] = []
        if let r = s.role { parts.append("role=\(r)") }
        if let id = s.identifier { parts.append("identifier=\(id)") }
        if let t = s.title { parts.append("title=\(t)") }
        if let l = s.label { parts.append("label=\(l)") }
        if let v = s.value { parts.append("value=\(v)") }
        if let p = s.path { parts.append("path=\(p.joined(separator: "/"))") }
        return "{" + parts.joined(separator: ", ") + "}"
    }
}
```

- [ ] **Step 3: Create MacOSAXResolver with the moved AX walk**

Move `node(of:)`, `describeNode(_:)`, `rootFor`, `resolveOne`, `findAll`, `count` verbatim into the new file, changing internal references from `Self.matches`/`Self.describe`/`Self.maxReportedMatches`/`Self.describeNode`/`Self.node` to `AXResolver.matches`/`AXResolver.describe`/`AXResolver.maxReportedMatches`/`Self.describeNode`/`Self.node` (the latter two now live on `MacOSAXResolver`).

```swift
// Sources/AutopilotCore/MacOS/MacOSAXResolver.swift
import Foundation
import ApplicationServices

/// Resolves a Selector against a running app's live AX tree — the platform half
/// of the old AXResolver.
public struct MacOSAXResolver {
    public init() {}

    static func node(of el: AXUIElement) -> [String: String] {
        var node: [String: String] = [:]
        if let r = AXTree.string(el, kAXRoleAttribute as String) { node["role"] = r }
        if let id = AXTree.string(el, kAXIdentifierAttribute as String) { node["identifier"] = id }
        if let t = AXTree.string(el, kAXTitleAttribute as String) { node["title"] = t }
        if let v = AXTree.string(el, kAXValueAttribute as String) { node["value"] = v }
        return node
    }

    func rootFor(_ selector: Selector, in appElement: AXUIElement) throws -> AXUIElement {
        guard let parent = selector.withinSelector else { return appElement }
        return try resolveOne(in: appElement, selector: parent)
    }

    public func resolveOne(in appElement: AXUIElement, selector: Selector) throws -> AXUIElement {
        let root = try rootFor(selector, in: appElement)
        var matches: [AXUIElement] = []
        var descriptors: [String] = []
        let walk = AXTree.walk(root) { el in
            if AXResolver.matches(node: Self.node(of: el), selector: selector) {
                matches.append(el)
                if descriptors.count < AXResolver.maxReportedMatches { descriptors.append(Self.describeNode(el)) }
            }
            return true
        }
        let desc = AXResolver.describe(selector)
        if matches.isEmpty {
            if walk.truncated { throw TargetingError.treeTruncated(selector: desc, visited: walk.visited) }
            throw TargetingError.notFound(selector: desc)
        }
        if let idx = selector.index {
            guard idx >= 0, idx < matches.count else {
                throw TargetingError.notFound(selector: "\(desc) — index \(idx) out of range (\(matches.count) matches)")
            }
            return matches[idx]
        }
        if matches.count > 1 {
            throw TargetingError.ambiguous(selector: desc, count: matches.count, matches: descriptors)
        }
        return matches[0]
    }

    public func findAll(in appElement: AXUIElement, selector: Selector) -> [String] {
        guard let root = try? rootFor(selector, in: appElement) else { return [] }
        var out: [String] = []
        AXTree.walk(root) { el in
            if AXResolver.matches(node: Self.node(of: el), selector: selector) { out.append(Self.describeNode(el)) }
            return true
        }
        return out
    }

    public func count(in appElement: AXUIElement, selector: Selector, stopAt: Int = 2) -> Int {
        guard let root = try? rootFor(selector, in: appElement) else { return 0 }
        var n = 0
        AXTree.walk(root) { el in
            if AXResolver.matches(node: Self.node(of: el), selector: selector) {
                n += 1
                if n >= stopAt { return false }
            }
            return true
        }
        return n
    }

    static func describeNode(_ el: AXUIElement) -> String {
        let n = node(of: el)
        var parts: [String] = []
        if let r = n["role"] { parts.append(r) }
        if let id = n["identifier"], !id.isEmpty { parts.append("id=\(id)") }
        if let t = n["title"], !t.isEmpty { parts.append("title=\(t)") }
        if let v = n["value"], !v.isEmpty { parts.append("value=\(v.prefix(40))") }
        if let f = AXTree.frame(el) { parts.append("@(\(Int(f.minX)),\(Int(f.minY)))") }
        return parts.joined(separator: " ")
    }
}
```

- [ ] **Step 4: Repoint Targeting + tests at MacOSAXResolver**

`Targeting` (Task 8 will fold it into the driver, but it still exists now) constructs `let axResolver = AXResolver()` and calls `axResolver.resolveOne/count`. Change `Targeting`'s stored resolver to `let axResolver = MacOSAXResolver()`. In `SelectorResolutionTests`, change any `AXResolver().resolveOne/findAll/count` to `MacOSAXResolver()...`. Leave `AXResolver.matches`/`describe` test calls as-is.

- [ ] **Step 5: Build + tests**

Run: `swift build && swift test --filter SelectorResolutionTests`
Expected: PASS — resolution tests green against `MacOSAXResolver`.

- [ ] **Step 6: Commit**

```bash
git add Sources/AutopilotCore/Targeting/AXResolver.swift Sources/AutopilotCore/MacOS/MacOSAXResolver.swift Sources/AutopilotCore/Targeting/Targeting.swift Tests/AutopilotCoreTests/SelectorResolutionTests.swift
git commit -m "refactor(core): split AXResolver pure matcher from macOS AX walk"
```

---

### Task 8: MacOSElement + MacOSDriver (the concrete conformance)

**Files:**
- Create: `Sources/AutopilotCore/MacOS/MacOSElement.swift`
- Create: `Sources/AutopilotCore/MacOS/MacOSDriver.swift`
- Test: `Tests/AutopilotCoreTests/MacOSDriverTests.swift`

**Interfaces:**
- Produces: `public final class MacOSElement: ElementHandle { public let ax: AXUIElement; public init(_ ax: AXUIElement) }`
- Produces: `public struct MacOSDriver: AppDriver` — conforms to the full protocol from Task 2 by delegating to the existing macOS types (`AppLauncher`, `Permissions`, `ActionEngine`, `EventSynthesizer`, `MenuNavigator`, `AXTree`, `Screenshot`, `MacOSAXResolver`, `MacOSPropertyReader`, `MacOSPixelSampler`, `MacOSImageDecoder`).

**Context:** This is the keystone. `MacOSDriver` adapts the neutral protocol to the existing concrete macOS code. It owns: the AX-tree resolution (via `MacOSAXResolver` + the vision fallback moved here from `Targeting.resolve`), action dispatch (via `ActionEngine`/`EventSynthesizer`/`MenuNavigator`), property reads (via `MacOSPropertyReader`), captures (via `Screenshot`), pixel sampling (via `MacOSPixelSampler`), and tree dump (via `AXTree.snapshot`). It converts neutral `Point`/`Rect`/`RGBColor` ↔ `CGPoint`/`CGRect`/`PixelColor.RGB` at the boundary.

Key conversions:
- `LaunchedHandle` ⇄ macOS `LaunchedApp`: the driver keeps a private map from pid → `LaunchedApp` (since `LaunchedApp` wraps `NSRunningApplication`, which the neutral handle can't carry). On `launch`/`attach`, store `LaunchedApp` keyed by pid; return `LaunchedHandle(pid:appName:)`. On `terminate`/`activate`, look up by pid.
- `ResolvedElement` ⇄ `ElementRef`: `.element(MacOSElement(ax))` ⇄ `.ax(ax)`; `.point(Point)` ⇄ `.point(CGPoint)`.

The vision-fallback block currently in `Targeting.resolve` (lines 24–44) moves into `MacOSDriver.resolve`. The `ScreenCapture.image`, `CGMainDisplayID`, `VisionResolver.bestMatch`, and `MacOSImageDecoder.grayscaleBuffer` calls live here.

- [ ] **Step 1: Write the failing test (driver constructs + reports permissions; element wraps AX)**

```swift
// Tests/AutopilotCoreTests/MacOSDriverTests.swift
import XCTest
import ApplicationServices
@testable import AutopilotCore

final class MacOSDriverTests: XCTestCase {
    func testElementWrapsAX() {
        // A bogus AXUIElement for type plumbing only (not messaged).
        let appEl = AXUIElementCreateApplication(getpid())
        let wrapped = MacOSElement(appEl)
        XCTAssertTrue(wrapped is ElementHandle)
    }
    func testDriverConformsAndReportsPermissions() {
        let d = MacOSDriver()
        // These call the real probes; on a dev/CI box with AX granted they're true,
        // but we only assert the calls return a Bool (the conformance compiles + runs).
        _ = d.hasAccessibility()
        _ = d.hasScreenRecording()
        XCTAssertFalse(d.accessibilityInstructions().isEmpty)
        XCTAssertFalse(d.screenRecordingInstructions().isEmpty)
    }
    func testNeutralToCGConversionsRoundTrip() {
        XCTAssertEqual(MacOSDriver.cgPoint(Point(x: 3, y: 4)), CGPoint(x: 3, y: 4))
        XCTAssertEqual(MacOSDriver.cgRect(Rect(x: 1, y: 2, width: 5, height: 6)), CGRect(x: 1, y: 2, width: 5, height: 6))
        XCTAssertEqual(MacOSDriver.point(CGPoint(x: 7, y: 8)), Point(x: 7, y: 8))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MacOSDriverTests`
Expected: FAIL — `cannot find 'MacOSDriver'`/`MacOSElement`.

- [ ] **Step 3: Write MacOSElement**

```swift
// Sources/AutopilotCore/MacOS/MacOSElement.swift
import Foundation
import ApplicationServices

/// macOS element handle: wraps a live AXUIElement behind the neutral
/// ElementHandle protocol. AnyObject (final class) so it satisfies the
/// AnyObject-constrained protocol and can be downcast by MacOSDriver.
public final class MacOSElement: ElementHandle {
    public let ax: AXUIElement
    public init(_ ax: AXUIElement) { self.ax = ax }
}
```

- [ ] **Step 4: Write MacOSDriver**

Implement every `AppDriver` method by delegating to existing macOS code. Include the static conversion helpers used by the test, the pid→`LaunchedApp` map, and the vision fallback (moved from `Targeting.resolve`).

```swift
// Sources/AutopilotCore/MacOS/MacOSDriver.swift
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
                let imagePath = Targeting.resolveImagePath(vision.image, baseDir: baseDir)
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
        Screenshot.captureElement((element as! MacOSElement).ax, to: path, padding: padding, metadata: metadata)
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
```

NOTE: Confirm `AppLauncher.attach(pid:)`, `.attach(_:)`, `.launch(_:)`, `.terminate(_:)`, `.activate(_:timeoutMs:intervalMs:clock:)` and `LaunchedApp.pid`/`.runningApp` exact signatures by reading `Sources/AutopilotCore/Runtime/AppLauncher.swift` and `Screenshot.captureMainDisplay/captureRegion/captureElement` signatures in `Sources/AutopilotCore/Runtime/Screenshot.swift` before writing this file; adjust delegation calls to match exactly. Also confirm `Screenshot.captureMainDisplay`/`captureRegion` return `Bool` and `captureElement` returns `String?` (nil = success).

- [ ] **Step 5: Remove the now-dead vision fallback from Targeting (it lives in the driver now)**

In `Sources/AutopilotCore/Targeting/Targeting.swift`, the `resolve`/`waitForPresence`/`matchCount` methods are now duplicated by the driver. Leave `Targeting` in place for now (the runner still calls it until Task 9) BUT change its `resolve` to drop the vision block ONLY IF it still compiles for the runner — simpler: leave `Targeting` entirely untouched this task; it is deleted wholesale in Task 9 when the runner switches to the driver. Remove the `VisionResolver` shim added in Task 5 only after Task 9. (No edit to Targeting in Task 8.)

- [ ] **Step 6: Build + tests**

Run: `swift build && swift test --filter MacOSDriverTests`
Expected: PASS (3 tests). Full `swift build` still green (Targeting + shims intact).

- [ ] **Step 7: Commit**

```bash
git add Sources/AutopilotCore/MacOS/MacOSElement.swift Sources/AutopilotCore/MacOS/MacOSDriver.swift Tests/AutopilotCoreTests/MacOSDriverTests.swift
git commit -m "feat(macos): add MacOSDriver conforming AppDriver to the AX stack"
```

---

### Task 9: Migrate PlanRunner to AppDriver (the seam closes)

**Files:**
- Modify: `Sources/AutopilotCore/Runner/PlanRunner.swift`
- Modify: `Sources/AutopilotMCPKit/MCPServer.swift` (consumer — inject the driver)
- Modify: `Sources/autopilot/main.swift` (consumer — inject the driver)
- Delete: `Sources/AutopilotCore/Targeting/Targeting.swift` (its logic now lives in `MacOSDriver`)
- Remove temporary shims: in `MacOSPixelSampler.swift`, `MacOSImageDecoder.swift`, `MacOSPropertyReader.swift`
- Test: `Tests/AutopilotCoreTests/IntegrationTests.swift`, `AttachTests.swift`, `CLITests.swift` (existing — keep passing)

This task is larger than most because deleting `Targeting` and changing `PlanRunner`'s initializer forces both consumers to migrate in the same task to restore a green build — they cannot be split out without leaving the tree red.

**Interfaces:**
- `PlanRunner` gains a stored `let driver: any AppDriver` and a new initializer `public init(driver: any AppDriver, clock: Clock = SystemClock())`. The element type threaded through `runStep`/`runAssert*`/`runSnapshot` changes from `AXUIElement` to `LaunchedHandle` (for the app) and `ResolvedElement`/`any ElementHandle` (for resolved elements). `PlanRunner` drops `import ApplicationServices`, `let permissions/launcher/actions/assertions` concrete fields (assertions' pure `evaluate`/`pollEvaluate` stay via a kept `let assertions = AssertionEngine()`; that type is now pure).

**Context:** This is the migration that makes `PlanRunner` agnostic. The full `AppDriver` protocol surface — including `performDrag`, `selectMenuPath`, and `loadPNG` — was defined in Task 2 and implemented by both `FakeDriver` (Task 2 test) and `MacOSDriver` (Task 8). No protocol changes are needed here; this task only rewrites the runner to call the driver instead of concrete macOS types. The mechanical substitutions, applied throughout `PlanRunner`:

| Current (macOS-coupled) | Replace with (driver) |
|---|---|
| `app: AXUIElement` parameter | `app: LaunchedHandle` |
| `let appElement = AXTree.application(pid:)` | use the `LaunchedHandle` directly |
| `targeting.resolve(...)` | `driver.resolve(...)` |
| `case .ax(let el)` | `case .element(let h)` |
| `assertions.readProperty(p, from: el)` | `driver.readProperty(p, of: h)` |
| `Screenshot.captureElement(el, ...)` | `driver.captureElementScreenshot(h, ...)` |
| `Screenshot.captureMainDisplay/captureRegion` | `driver.captureMainDisplay/captureRegion` |
| `PixelColor.sample/sampleRegion/loadPNG` | `driver.samplePixel/sampleRegion/loadPNG` (then `PixelColor.RGB($0)` for the algebra) |
| `actions.point(for: ref)` | `driver.point(for: ref)` |
| `EventSynthesizer.drag(from:to:)` | `driver.performDrag(from:to:)` |
| `MenuNavigator().selectPath(path, app:)` | `driver.selectMenuPath(path, app:)` |
| `AXTree.snapshot(app)` | `driver.dumpTree(app:)` (`.nodes`/`.truncated`) |
| `permissions.hasAccessibility()` etc. | `driver.hasAccessibility()` etc. |
| `launcher.launch/attach/terminate/activate` | `driver.launch/attach/terminate/activate` |
| `Targeting.resolveImagePath(...)` | `PlanRunner.resolveImagePath(...)` (added in Step 3) |

- [ ] **Step 1: Rewrite PlanRunner's fields + initializer**

Replace the field block (`let permissions/launcher/actions/assertions/reporter` + `init`) with:
```swift
let driver: any AppDriver
let clock: Clock
let assertions = AssertionEngine()   // now pure: evaluate/pollEvaluate only
let reporter = Reporter()
public init(driver: any AppDriver, clock: Clock = SystemClock()) {
    self.driver = driver; self.clock = clock
}
```
Drop `import ApplicationServices` (keep `import Foundation`).

- [ ] **Step 2: Apply the substitution table to run/runStep/runAssert/runAssertPixel/runAssertRegion/runSnapshot/writeAXDump**

Work method by method using the table above. Specifics that need care:
- `runStep` loses the `launched`/`targeting` params: signature becomes `runStep(_ step: Step, app: LaunchedHandle, timeoutMs: Int, intervalMs: Int, options: RunOptions)`. Update the one call site in `run(_:options:)`.
- `.screenshot` element-crop branch: `if case .element(let h) = try? driver.resolve(...)` then `driver.captureElementScreenshot(h, to:, padding:, metadata:)` (returns `String?`, nil = success — same convention as the old `Screenshot.captureElement`). Absolute-region branch builds a neutral `Rect(x:y:width:height:)`.
- `runAssert` property branch: `guard case .element(let h) = try driver.resolve(...) else { return <vision-only fail> }`, then `assertions.pollEvaluate(...) { driver.readProperty(assertion.property, of: h) ?? "" }`.
- `runAssertPixel`/`runAssertRegion`: sample via `driver.samplePixel(at: Point)` / `driver.sampleRegion(Rect)`; wrap the returned `RGBColor` with `PixelColor.RGB($0)` before the `PixelColor.matches/average/dominant` algebra. The center/offset math uses neutral `Point`; the region uses neutral `Rect`.
- `runSnapshot`: capture via `driver.captureRegion(Rect, ...)`; load both images via `driver.loadPNG(path)` → `[RGBColor]?`, map each to `[PixelColor.RGB]` (`$0.map { PixelColor.RGB($0) }`) before `PixelColor.diffFraction`.
- `writeAXDump`: `let snap = driver.dumpTree(app: app)`; use `snap.nodes`/`snap.truncated` (the JSON write is unchanged).

- [ ] **Step 3: Add resolveImagePath to PlanRunner (pure)**

```swift
// in PlanRunner
static func resolveImagePath(_ image: String, baseDir: URL?) -> String {
    if image.hasPrefix("/") { return image }
    if let baseDir { return baseDir.appendingPathComponent(image).path }
    return image
}
```
And in `MacOSDriver.resolve` (Task 8), the vision fallback's `Targeting.resolveImagePath(...)` becomes `PlanRunner.resolveImagePath(...)`.

- [ ] **Step 4: Delete Targeting.swift and remove the three temporary shims**

```bash
git rm Sources/AutopilotCore/Targeting/Targeting.swift
```
Then delete the three temporary `extension` shims added in Tasks 4/5/6:
- the `extension PixelColor { sampleRegion/loadPNG/sample }` shim in `MacOSPixelSampler.swift`
- the `extension VisionResolver { grayscaleBuffer... }` shim in `MacOSImageDecoder.swift`
- the `extension AssertionEngine { readProperty(from: AXUIElement) }` shim in `MacOSPropertyReader.swift`

Confirm no remaining references: `grep -rn 'Targeting' Sources/` must show no `Targeting.` calls (the type is gone).

Note on green-ness: deleting `Targeting` and changing `PlanRunner`'s initializer breaks the two consumers (`MCPServer.swift`, `autopilot/main.swift`), which still call `PlanRunner()` and `Targeting()`/`AXTree` directly. They are migrated in Steps 5–6 of THIS task. The tree is therefore red between Step 4 and Step 6 — that is acceptable WITHIN a task; the task's deliverable (Step 7 green build) is the atomic unit the reviewer sees. Do not commit until Step 7 is green.

- [ ] **Step 5: Migrate MCPServer.swift to the driver**

In `Sources/AutopilotMCPKit/MCPServer.swift`, add a stored `let driver = MacOSDriver()` property and a `let runner = PlanRunner(driver: driver)` where it ran plans. Replace:
- `AppLauncher().attach(...)` → `driver.attach(...)` returning `LaunchedHandle` (the private `attach(_:)` helper and `dumpAXTree`/`findElement`/`suggestSelectors` now thread `LaunchedHandle`).
- `AXTree.application(pid:)` + `Targeting().waitForPresence(...)` → `driver.waitForPresence(Selector(role:"AXWindow"), present:true, app: handle, timeoutMs:2000, intervalMs:100)`.
- `AXResolver().findAll(in: app, selector:)` → `driver.findAll(sel, app: handle)`.
- `SelectorSuggester.suggest(from: AXTree.snapshot(app).nodes)` → `driver.suggestSelectors(app: handle)`.
- `AXTree.snapshot(app)` in `dumpAXTree` → `driver.dumpTree(app: handle)` (use `.nodes`/`.truncated`); `launched.runningApp.localizedName` → `handle.appName`.
- `PlanRunner().run(...)` → `PlanRunner(driver: driver).run(...)`.
- `AXRoles.isInteractive($0["role"])` for `interactiveOnly` stays (agnostic).

- [ ] **Step 6: Migrate autopilot/main.swift to the driver**

Read `Sources/autopilot/main.swift`; wherever it constructs `PlanRunner()` or calls `Targeting`/`AXResolver`/`AXTree`/`SelectorSuggester`/`AppLauncher`/`Permissions` directly (for the `run`, `find`, `suggest`, `dump-axtree`, `doctor` subcommands), inject `let driver = MacOSDriver()` and route through it exactly as the MCP server now does. `PlanRunner()` → `PlanRunner(driver: MacOSDriver())`. `doctor` uses `driver.hasAccessibility()/hasScreenRecording()` + `driver.accessibilityInstructions()/screenRecordingInstructions()`.

- [ ] **Step 7: Build + full test suite**

Run: `swift build && Fixtures/TestHostApp/make-app.sh && swift test`
Expected: PASS — all 126 (+ new) tests green. Integration/attach/CLI tests exercise the real `MacOSDriver` end-to-end. This is the proof the seam holds with the real backend.

- [ ] **Step 8: Grep gate — confirm PlanRunner is now agnostic**

Run:
```bash
grep -nE 'import (AppKit|ApplicationServices|CoreGraphics|ScreenCaptureKit)' Sources/AutopilotCore/Runner/PlanRunner.swift Sources/AutopilotCore/Assertions/AssertionEngine.swift Sources/AutopilotCore/Assertions/PixelColor.swift Sources/AutopilotCore/Targeting/VisionResolver.swift Sources/AutopilotCore/Targeting/AXResolver.swift Sources/AutopilotCore/Targeting/SelectorSuggester.swift Sources/AutopilotCore/Plan/PlanParser.swift
```
Expected: NO output (zero platform imports in the agnostic set).

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: migrate PlanRunner + consumers to AppDriver; delete Targeting"
```

---

### Task 10: Phase-2 checkpoint — module boundary gate + folder reorg

**Files:**
- Modify: `Package.swift`
- Move: agnostic files into a clean `Sources/AutopilotCore/`; macOS files into a new target `Sources/AutopilotMacOS/`
- Create: `scripts/check-core-purity.sh`

**Interfaces:**
- After this task the SwiftPM package has THREE library-ish targets in ONE repo: `AutopilotCore` (agnostic), `AutopilotMacOS` (driver, depends on `AutopilotCore`), and the existing `AutopilotMCPKit` (now depends on `AutopilotMacOS`). Executables depend on `AutopilotMacOS`. This is the in-repo dress rehearsal for the repo split — if the package compiles with `AutopilotCore` as a separate target that does NOT depend on `AutopilotMacOS`, the boundary is real.

**Context:** Until now everything lived in one `AutopilotCore` target, so a stray macOS import would still compile. This task physically separates the targets so the compiler enforces the boundary: `AutopilotCore` must build without the macOS files. This catches any missed coupling before the repo split.

- [ ] **Step 1: Create the macOS target directory and move driver files**

```bash
mkdir -p Sources/AutopilotMacOS
git mv Sources/AutopilotCore/MacOS/MacOSElement.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/MacOS/MacOSDriver.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/MacOS/MacOSAXResolver.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/MacOS/MacOSPropertyReader.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/MacOS/MacOSPixelSampler.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/MacOS/MacOSImageDecoder.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/Runtime/AppLauncher.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/Runtime/Permissions.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/Runtime/ScreenCapture.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/Runtime/Screenshot.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/Actions/ActionEngine.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/Actions/EventSynthesizer.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/Actions/KeyMap.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/Actions/MenuNavigator.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/Targeting/AXTree.swift Sources/AutopilotMacOS/
git mv Sources/AutopilotCore/Targeting/ElementRef.swift Sources/AutopilotMacOS/
```

The agnostic files remaining in `AutopilotCore`: everything under `Plan/`, `Report/`, `Runner/`, `Driver/`, plus `Runtime/Clock.swift`, `Runtime/Poller.swift`, `Assertions/AssertionEngine.swift`, `Assertions/PixelColor.swift`, `Targeting/AXResolver.swift`, `Targeting/AXRoles.swift`, `Targeting/SelectorSuggester.swift`, `Targeting/TargetingError.swift`, `Targeting/VisionResolver.swift`.

- [ ] **Step 2: Make ElementRef internal to the macOS target**

`ElementRef` (now in `Sources/AutopilotMacOS/ElementRef.swift`) is macOS-only and used by `ActionEngine`/`MacOSDriver`. It can stay `public` or become `internal` to the macOS target; leave as-is. Confirm nothing in `AutopilotCore` references `ElementRef` (it shouldn't — the runner uses `ResolvedElement` now): `grep -rn 'ElementRef' Sources/AutopilotCore/` must be empty.

- [ ] **Step 3: Rewrite Package.swift with separate targets**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "autopilot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutopilotCore", targets: ["AutopilotCore"]),
        .library(name: "AutopilotMacOS", targets: ["AutopilotMacOS"]),
        .executable(name: "autopilot", targets: ["autopilot"]),
        .executable(name: "AutopilotMCP", targets: ["AutopilotMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "AutopilotCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "AutopilotMacOS",
                dependencies: ["AutopilotCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "autopilot",
            dependencies: [
                "AutopilotMacOS",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "AutopilotMCPKit",
                dependencies: ["AutopilotMacOS"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "AutopilotMCP",
            dependencies: ["AutopilotMCPKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "AutopilotCoreTests",
            dependencies: ["AutopilotCore", "AutopilotMacOS"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "AutopilotMCPKitTests",
            dependencies: ["AutopilotMCPKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
```

NOTE: `AutopilotCoreTests` depends on BOTH `AutopilotCore` and `AutopilotMacOS` because the test suite contains both pure tests and macOS-driver/integration tests. The pure-only tests (`GeometryTests`, `ChordValidatorTests`, `FakeDriverTests`, `AssertionEngineTests`, `PixelColorTests`, `VisionResolverTests`, `PlanParserTests`, `PlanLinterTests`, `ReporterTests`, `SuiteReportTests`, `SelectorSuggesterTests`, `PollerTests`, `KeyMapTests`) only need `AutopilotCore`; the rest (`IntegrationTests`, `AttachTests`, `CLITests`, `SelectorResolutionTests`, `MenuNavigatorTests`, `MacOSDriverTests`) need `AutopilotMacOS`. Keeping them in one test target with both deps is simplest and avoids splitting test files now.

`KeyMapTests` and `MenuNavigatorTests` test macOS types (`ActionEngine`/`MenuNavigator`) now in `AutopilotMacOS` — their `@testable import AutopilotCore` must become `@testable import AutopilotMacOS` (and keep `@testable import AutopilotCore` if they also touch core types). Update imports in every test file per which module the symbols now live in. Build errors will name each one.

- [ ] **Step 4: Fix test imports**

Build, read each "no such module"/"cannot find X" error, and add `@testable import AutopilotMacOS` to the test files that exercise macOS types. Likely: `IntegrationTests`, `AttachTests`, `CLITests`, `SelectorResolutionTests`, `MenuNavigatorTests`, `KeyMapTests`, `MacOSDriverTests`.

- [ ] **Step 5: Create the purity-check script**

```bash
# scripts/check-core-purity.sh
#!/usr/bin/env bash
# Fails if any platform framework is imported anywhere in the AutopilotCore target.
set -euo pipefail
HITS=$(grep -rnE 'import (AppKit|ApplicationServices|CoreGraphics|ScreenCaptureKit|Cocoa|Quartz)' Sources/AutopilotCore/ || true)
if [ -n "$HITS" ]; then
  echo "ERROR: AutopilotCore must stay platform-agnostic. Found platform imports:" >&2
  echo "$HITS" >&2
  exit 1
fi
echo "AutopilotCore purity OK — no platform imports."
```
Make it executable: `chmod +x scripts/check-core-purity.sh`.

- [ ] **Step 6: Build, test, and run the purity gate**

Run: `swift build && Fixtures/TestHostApp/make-app.sh && swift test && bash scripts/check-core-purity.sh`
Expected: all PASS; purity script prints OK. The compiler now ENFORCES the boundary — `AutopilotCore` builds as its own target with no macOS dependency.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: split AutopilotMacOS target from AutopilotCore; enforce purity gate"
```

---

### Task 11: Update CI + version strings to v2.0.0

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `Sources/AutopilotMCPKit/MCPServer.swift:42` (serverInfo version)
- Modify: `docs/CI.md`

**Context:** CI must run the purity gate and build the now-multi-target package. The MCP `serverInfo.version` is hardcoded `"1.0.0"` and becomes `"2.0.0"`.

- [ ] **Step 1: Bump the MCP server version string**

In `Sources/AutopilotMCPKit/MCPServer.swift`, the `initialize` response:
```swift
                "serverInfo": ["name": "autopilot", "version": "2.0.0"]
```

- [ ] **Step 2: Update the MCP server test that asserts the version (if any)**

`grep -n '1.0.0' Tests/AutopilotMCPKitTests/MCPServerTests.swift`. If a test asserts `"1.0.0"`, change it to `"2.0.0"`. Run `swift test --filter MCPServerTests` → PASS.

- [ ] **Step 3: Add the purity gate to CI**

In `.github/workflows/ci.yml`, in the `build-and-test` job, add a step after "Build" and before "Test":
```yaml
      - name: Core purity gate
        run: bash scripts/check-core-purity.sh
```

- [ ] **Step 4: Update docs/CI.md**

Add a short subsection documenting the purity gate (what it checks, why) and that the package now has `AutopilotCore` + `AutopilotMacOS` targets. Keep it factual, one paragraph.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml Sources/AutopilotMCPKit/MCPServer.swift Tests/AutopilotMCPKitTests/MCPServerTests.swift docs/CI.md
git commit -m "ci: add core purity gate; bump MCP serverInfo to 2.0.0"
```

---

### Task 12: Extract autopilot-core into its own repo

**Files:**
- New repo `jschwefel-CBB/autopilot-core` (created via `gh`/MCP)
- New: `autopilot-core/Package.swift`, `autopilot-core/README.md`, `autopilot-core/.github/workflows/ci.yml`
- Move: the `AutopilotCore` sources + their pure tests into the new repo

**Context:** Physically split. The agnostic target leaves `autopilot-macos` and becomes the `autopilot-core` package. `autopilot-macos` then depends on it by URL. This is done as a careful sequence so both repos build green and the core's git history is preserved where feasible (a clean copy is acceptable — the canonical history stays on `autopilot-macos` up to the split commit).

This task is inherently manual/structural (repo creation, two Package.swifts, CI). It is ONE task because none of its sub-steps yields an independently shippable artifact — the split only works once both sides build.

- [ ] **Step 1: Create the new repo**

```bash
gh repo create jschwefel-CBB/autopilot-core --public \
  --description "Platform-agnostic core for AutoPilot: plan model, runner, and driver protocols."
```

- [ ] **Step 2: Assemble the core package in a scratch dir**

```bash
SCRATCH=$(mktemp -d)
git -C "$SCRATCH" clone https://github.com/jschwefel-CBB/autopilot-core.git
mkdir -p "$SCRATCH/autopilot-core/Sources/AutopilotCore" "$SCRATCH/autopilot-core/Tests/AutopilotCoreTests"
# Copy the agnostic sources (the current AutopilotCore target) verbatim.
cp -R Sources/AutopilotCore/. "$SCRATCH/autopilot-core/Sources/AutopilotCore/"
# Copy ONLY the pure tests (see list in Task 10 Step 3 NOTE).
for t in GeometryTests ChordValidatorTests FakeDriverTests AssertionEngineTests PixelColorTests VisionResolverTests PlanParserTests PlanLinterTests ReporterTests SuiteReportTests SelectorSuggesterTests PollerTests IncludeResolutionTests; do
  cp "Tests/AutopilotCoreTests/$t.swift" "$SCRATCH/autopilot-core/Tests/AutopilotCoreTests/" 2>/dev/null || true
done
```
NOTE: `FakeDriverTests` defines `FakeDriver` — it belongs in core (pure). `KeyMapTests`, `MenuNavigatorTests`, `SelectorResolutionTests`, `IntegrationTests`, `AttachTests`, `CLITests`, `MacOSDriverTests` are macOS-only and stay in `autopilot-macos`. Verify each copied test compiles against core alone.

- [ ] **Step 3: Write autopilot-core/Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutopilotCore",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "AutopilotCore", targets: ["AutopilotCore"]),
    ],
    targets: [
        .target(name: "AutopilotCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "AutopilotCoreTests",
                    dependencies: ["AutopilotCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
```

- [ ] **Step 4: Write a README + CI for the core repo**

`autopilot-core/README.md`: a short description (platform-agnostic core for AutoPilot; defines the plan model, the `PlanRunner`, and the `AppDriver` protocol that platform backends implement; not useful standalone — pair with a backend like `autopilot-macos`). `autopilot-core/.github/workflows/ci.yml`: `runs-on: macos-15`, `swift build` + `swift test` + the purity gate (copy `scripts/check-core-purity.sh`).

- [ ] **Step 5: Verify the core package builds + tests in isolation**

```bash
cd "$SCRATCH/autopilot-core" && swift build && swift test && bash scripts/check-core-purity.sh
```
Expected: PASS — core builds and its pure tests pass with ZERO platform code present. This is the strongest proof the extraction is clean: the package literally contains no macOS files and still compiles.

- [ ] **Step 6: Commit + push core to main — DO NOT TAG**

```bash
cd "$SCRATCH/autopilot-core"
git add -A
git commit -m "feat: initial autopilot-core extraction"
git push origin main
git rev-parse HEAD   # record this SHA — Task 13 pins to it
```
**RELEASE-GATE RULE: do NOT tag `v2.0.0` here.** Per the user's explicit instruction, NO tag is created on either repo until the final manual go in Task 15. `autopilot-macos` will pin `autopilot-core` by this exact commit SHA (a `revision:` pin in `Package.swift`), not by version, until the gate. Report the SHA back to the controller; it is the input to Task 13 Step 2.

- [ ] **Step 7: Record the core HEAD SHA for the controller**

The full SHA printed by `git rev-parse HEAD` is the handoff artifact from this task. No source change in `autopilot-macos` yet; the wiring happens in Task 13.

---

### Task 13: Wire autopilot-macos to the published core; remove the local core sources

**Files:**
- Modify: `Package.swift` (autopilot-macos)
- Delete: `Sources/AutopilotCore/` (now provided by the remote package)
- Delete: the pure tests that moved to core (keep macOS tests)
- Modify: `.github/workflows/ci.yml` (drop the local purity gate — core now owns it)

**Context:** `autopilot-macos` stops carrying the core sources and depends on `autopilot-core` v2.0.0 by URL. The `AutopilotMacOS` target now imports `AutopilotCore` from the package dependency. Executables and `AutopilotMCPKit` are unchanged except the dependency graph root.

- [ ] **Step 1: Remove the local core sources + moved tests**

```bash
git rm -r Sources/AutopilotCore
# Remove the pure tests that now live in autopilot-core:
for t in GeometryTests ChordValidatorTests FakeDriverTests AssertionEngineTests PixelColorTests VisionResolverTests PlanParserTests PlanLinterTests ReporterTests SuiteReportTests SelectorSuggesterTests PollerTests IncludeResolutionTests; do
  git rm "Tests/AutopilotCoreTests/$t.swift" 2>/dev/null || true
done
```
KEEP in autopilot-macos: `IntegrationTests`, `AttachTests`, `CLITests`, `SelectorResolutionTests`, `MenuNavigatorTests`, `KeyMapTests`, `MacOSDriverTests` (rename the test target dir if it now only holds macOS tests — keep `AutopilotCoreTests` name to minimize churn, OR rename to `AutopilotMacOSTests`; **keep the name** to avoid touching CI filters).

- [ ] **Step 2: Rewrite autopilot-macos Package.swift to depend on the remote core**

**RELEASE-GATE RULE:** because no `v2.0.0` tag exists yet (it is created only at the final manual go in Task 15), pin `autopilot-core` by the EXACT COMMIT SHA from Task 12 Step 6 — a `revision:` pin, NOT `from: "2.0.0"`. Substitute the real 40-char SHA for `<CORE_SHA>` below. Task 15 flips this to `from: "2.0.0"` as part of the gated release, after the tag is pushed.

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "autopilot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutopilotMacOS", targets: ["AutopilotMacOS"]),
        .executable(name: "autopilot", targets: ["autopilot"]),
        .executable(name: "AutopilotMCP", targets: ["AutopilotMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // Pinned by revision until the gated v2.0.0 release (Task 15 switches to from: "2.0.0").
        .package(url: "https://github.com/jschwefel-CBB/autopilot-core", revision: "<CORE_SHA>"),
    ],
    targets: [
        .target(
            name: "AutopilotMacOS",
            dependencies: [.product(name: "AutopilotCore", package: "autopilot-core")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "autopilot",
            dependencies: [
                "AutopilotMacOS",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "AutopilotMCPKit",
                dependencies: ["AutopilotMacOS"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "AutopilotMCP",
            dependencies: ["AutopilotMCPKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "AutopilotCoreTests",
            dependencies: ["AutopilotMacOS", .product(name: "AutopilotCore", package: "autopilot-core")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "AutopilotMCPKitTests",
            dependencies: ["AutopilotMCPKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
```

- [ ] **Step 3: Resolve + build against the published core**

```bash
swift package resolve
swift build
```
Expected: SPM fetches `autopilot-core` v2.0.0; build succeeds. If `Package.resolved` needs updating, commit it.

- [ ] **Step 4: Drop the local purity gate from autopilot-macos CI**

In `.github/workflows/ci.yml`, remove the "Core purity gate" step (core's own CI owns purity now). Also remove `scripts/check-core-purity.sh` from autopilot-macos (`git rm scripts/check-core-purity.sh`).

- [ ] **Step 5: Build + full macOS test suite against the remote core**

Run: `swift build && Fixtures/TestHostApp/make-app.sh && swift test`
Expected: PASS — all macOS + integration tests green against the published `autopilot-core`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "build: depend on published autopilot-core v2.0.0; remove vendored core"
```

---

### Task 14: Update docs, README, schema, and Homebrew for v2.0.0

**Files:**
- Modify: `README.md`, `docs/MANUAL.md`, `docs/AUTHORING.md` (if it mentions internals/architecture)
- Modify: `Formula/autopilot.rb` in `jschwefel-CBB/homebrew-autopilot`
- Modify: `.github/workflows/release.yml` (version/tag references stay `v*`; confirm it still builds the macOS package)

**Context:** Reflect the new two-repo architecture and the v2.0.0 release in user-facing docs and the tap. The README gains a short "Architecture" note (core + macOS driver; iOS/Android planned). The Homebrew formula bumps to 2.0.0 (its URLs/shasums are filled by the release workflow on tag; just bump the literal `version` and the placeholder URLs/version interpolation).

- [ ] **Step 1: README architecture note + version**

Add a short "## Architecture" section to `README.md` after "What it does": AutoPilot is split into `autopilot-core` (platform-agnostic plan model, runner, and the `AppDriver` protocol) and platform backends (`autopilot-macos` today; iOS and Android planned). Keep it to ~4 sentences. Ensure no remaining `1.0.0` references imply the current release.

- [ ] **Step 2: MANUAL/AUTHORING sweep**

`grep -rn '1\.0\.0' docs/` and update any version references to 2.0.0 where they denote the current release (NOT historical changelog entries). If `docs/AUTHORING.md` or `docs/MANUAL.md` describes the architecture/module layout, update to mention the core/driver split.

- [ ] **Step 3: Bump the Homebrew formula to 2.0.0**

In `jschwefel-CBB/homebrew-autopilot` `Formula/autopilot.rb`, set `version "2.0.0"` and update the `on_arm`/`on_intel` URLs to the `v2.0.0` release tag pattern (the release workflow overwrites sha256 + URL on tag, but set the literal version so a manual read is correct). Commit via the GitHub MCP/`gh`.

- [ ] **Step 4: Confirm release.yml targets the macOS package**

Read `.github/workflows/release.yml`; confirm `scripts/release.sh` still builds the (now `AutopilotMacOS`-rooted) executables. The executables' names (`autopilot`, `AutopilotMCP`) are unchanged, so `release.sh` should still work. If `release.sh` references a removed target name, update it. Do NOT trigger a release here.

- [ ] **Step 5: Commit docs**

```bash
git add README.md docs/
git commit -m "docs: document core/driver architecture; bump references to 2.0.0"
```

---

### Task 15: Release gate — verify, STOP for manual go, then cut v2.0.0

**Files:** `Package.swift` (flip the core pin from `revision:` to `from: "2.0.0"` — only after the go)

**Context:** The whole effort is assembled: `autopilot-core` is on `main` (untagged); `autopilot-macos` builds green against it via a `revision:` pin; docs and tap are updated. **This task is the release gate.** It splits into two halves separated by a HARD MANUAL STOP: (1) verify the 5 gate conditions and present the green state; (2) — only after the user explicitly says go — tag both repos `v2.0.0`, flip the pin, and let the release workflow publish.

**RELEASE-GATE RULE (the user's explicit instruction): create NO tag, GitHub Release, or Homebrew publish until the user says go. The executor STOPS after Step 2 and waits.**

- [ ] **Step 1: Verify the 5 gate conditions**

Run and confirm each is green:
1. `autopilot-core`: in its checkout, `swift build && swift test && bash scripts/check-core-purity.sh` — all pass.
2. `autopilot-macos`: `swift build && Fixtures/TestHostApp/make-app.sh && swift test` — all pass (incl. integration tests) against the `revision:`-pinned core.
3. Purity grep clean: `grep -rnE 'import (AppKit|ApplicationServices|CoreGraphics|ScreenCaptureKit)' <core checkout>/Sources/` → no output.
4. Docs/README/Homebrew formula all say 2.0.0 (no stray 1.0.0 as a current-version reference).
5. The `v2-core-extraction` branch is merged-ready (working tree clean; tests green on the would-be-merged state).

- [ ] **Step 2: STOP — present the green state and wait for the user's go**

Report the 5 conditions as a checklist with their results, the exact `autopilot-core` HEAD SHA the macOS repo is pinned to, and the precise irreversible actions that the go will trigger (tag core v2.0.0, tag macOS v2.0.0, flip the pin, push tags → release workflow publishes the GitHub Release + updates the tap). **Do not proceed past this step without an explicit go.** The controller surfaces this to the user and halts.

- [ ] **Step 3: (AFTER GO) Tag autopilot-core v2.0.0**

In the `autopilot-core` checkout, on the exact commit `autopilot-macos` is pinned to:
```bash
git tag v2.0.0 && git push origin v2.0.0
```

- [ ] **Step 4: (AFTER GO) Flip the macOS core pin to the version range**

In `autopilot-macos` `Package.swift`, change the dependency from `revision: "<CORE_SHA>"` back to `from: "2.0.0"`, then:
```bash
swift package update autopilot-core
swift build && swift test
git add Package.swift Package.resolved
git commit -m "build: pin autopilot-core to v2.0.0 release"
```
Expected: resolves to the just-pushed v2.0.0 tag; build + tests green.

- [ ] **Step 5: (AFTER GO) Finish the branch and tag the macOS release**

Use superpowers:finishing-a-development-branch to merge `v2-core-extraction` → `main`; verify tests on the merged result. Then:
```bash
git checkout main && git pull
git tag v2.0.0 && git push origin v2.0.0
```

- [ ] **Step 6: (AFTER GO) Watch the release workflow + verify artifacts**

```bash
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')"
gh release view v2.0.0 --repo jschwefel-CBB/autopilot-macos
```
Expected: green — GitHub Release `v2.0.0` created with the arm64 tarball; tap `Formula/autopilot.rb` points at the v2.0.0 URL + real sha256.

---
