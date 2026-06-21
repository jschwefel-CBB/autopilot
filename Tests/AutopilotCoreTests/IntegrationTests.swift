import Testing
import Foundation
import ApplicationServices
@testable import AutopilotCore
@testable import AutopilotMacOS

// Serialized: these drive the live GUI and share global frontmost-app state.
// Running them in parallel launches multiple TestHostApp instances at once,
// so input/assertions land on the wrong instance.
@Suite(.serialized) struct IntegrationTests {
    /// Path to the built TestHostApp .app bundle. A bare Mach-O does not launch
    /// as a foreground GUI app with its own Accessibility tree, so the fixture is
    /// assembled into a real .app bundle by `Fixtures/TestHostApp/make-app.sh`.
    func testHostApp() -> URL {
        // Resolves relative to the package root when run via `swift test`.
        let pkgRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AutopilotCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        return pkgRoot
            .appendingPathComponent("Fixtures/TestHostApp/.build/TestHostApp.app")
    }

    /// Terminate any running TestHostApp instances (best-effort) so the test
    /// is hermetic regardless of leaked processes from earlier runs.
    func killExistingTestHostApps() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "TestHostApp.app"]
        try? p.run()
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.4)
    }

    @Test func typeUpdatesStatusLabel() async throws {
        guard AXIsProcessTrusted() else {
            // Skip when no AX permission; do not fail CI.
            return
        }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else {
            Issue.record("TestHostApp.app not built. Run: Fixtures/TestHostApp/make-app.sh")
            return
        }

        // Hermetic precondition: kill any leftover TestHostApp instances so a
        // leaked process from a prior run cannot poison element resolution
        // (the resolver would otherwise walk a different instance's tree).
        killExistingTestHostApps()
        defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-it-\(UUID().uuidString)")
        let plan = Plan(
            schemaVersion: "1.0",
            name: "host: type updates status",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "type-name", action: .type,
                     target: Selector(role: "AXTextField", identifier: "nameField"),
                     args: { var a = ActionArgs(); a.text = "Ada"; return a }()),
                Step(id: "assert-status", action: .assert,
                     target: Selector(identifier: "statusLabel"),
                     assert: Assertion(property: .value, op: .contains, expected: "Ada")),
                // Terminate so we don't leak a TestHostApp instance across runs.
                Step(id: "quit", action: .terminate),
            ]
        )
        let runner = PlanRunner(driver: MacOSDriver())
        let report = try runner.run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    @Test func menuActionInvokesNoShortcutItem() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else {
            Issue.record("TestHostApp.app not built. Run: Fixtures/TestHostApp/make-app.sh")
            return
        }
        killExistingTestHostApps()
        defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-menu-\(UUID().uuidString)")
        let plan = Plan(
            schemaVersion: "1.0",
            name: "host: menu toggles flag",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor,
                     target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                // "Toggle Flag" has no key equivalent — only reachable via the menu.
                Step(id: "menu-toggle", action: .menu,
                     args: { var a = ActionArgs(); a.menuPath = ["View", "Toggle Flag"]; return a }()),
                Step(id: "assert-flag", action: .assert,
                     target: Selector(identifier: "statusLabel"),
                     assert: Assertion(property: .value, op: .contains, expected: "flag=true")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    @Test func typeIntoSearchFieldViaKeycodes() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else {
            Issue.record("TestHostApp.app not built. Run: Fixtures/TestHostApp/make-app.sh")
            return
        }
        killExistingTestHostApps()
        defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-sf-\(UUID().uuidString)")
        let plan = Plan(
            schemaVersion: "1.0",
            name: "host: type into search field",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor,
                     target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                // focus:false — the app already made the search field first
                // responder; keycode-based type must land text in its field editor.
                Step(id: "type-search", action: .type,
                     target: Selector(role: "AXTextField", identifier: "searchField"),
                     args: { var a = ActionArgs(); a.text = "Query 9"; a.focus = false; return a }()),
                Step(id: "assert-search", action: .assert,
                     target: Selector(role: "AXTextField", identifier: "searchField"),
                     assert: Assertion(property: .value, op: .equals, expected: "Query 9")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    @Test func indexDisambiguatesMultipleButtons() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps()
        defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-idx-\(UUID().uuidString)")
        // {role: AXButton} matches several buttons → ambiguous. `index` picks one,
        // so the click resolves instead of erroring.
        let plan = Plan(
            schemaVersion: "1.0",
            name: "host: index disambiguation",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor,
                     target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "click-first-button", action: .click,
                     target: Selector(role: "AXButton", index: 0)),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        // The click step must resolve (not error on ambiguity) — that's the point.
        let clickStep = report.steps.first { $0.id == "click-first-button" }
        #expect(clickStep?.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    @Test func assertRegionReadsKnownColor() async throws {
        guard AXIsProcessTrusted() else { return }
        guard CGPreflightScreenCaptureAccess() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-region-\(UUID().uuidString)")
        // colorSwatch is a solid #3478F6 view; assertRegion over its center must match.
        let plan = Plan(
            schemaVersion: "1.0", name: "host: region color",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                // dominant mode over the solid swatch. Captured pixels are
                // normalized to sRGB, so the swatch's sRGB #3478F6 matches within
                // a tight tolerance even on a wide-gamut display.
                Step(id: "region", action: .assertRegion, target: Selector(identifier: "colorSwatch"),
                     args: { var a = ActionArgs(); a.color = "#3478F6"; a.width = 12; a.height = 12
                             a.mode = "dominant"; a.tolerance = 16; return a }()),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    @Test func snapshotMissingReferenceFailsWithoutFlag() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-snap-\(UUID().uuidString)")
        let artifacts = dir.appendingPathComponent("art")
        let refPath = "ref/swatch.png"   // does not exist
        func makePlan() -> Plan {
            Plan(schemaVersion: "1.0", name: "host: snapshot",
                 target: TargetApp(path: binary.path),
                 defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
                 steps: [
                    Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                         args: { var a = ActionArgs(); a.present = true; return a }()),
                    Step(id: "snap", action: .snapshot, target: Selector(identifier: "colorSwatch"),
                         args: { var a = ActionArgs(); a.reference = refPath; a.width = 30; a.height = 30; return a }()),
                    Step(id: "quit", action: .terminate),
                 ])
        }
        // 1) Without --update-snapshots: a missing reference is a FAILURE.
        let r1 = try PlanRunner(driver: MacOSDriver()).run(makePlan(),
            options: RunOptions(artifactsDir: artifacts, planBaseDir: dir, updateSnapshots: false))
        #expect(r1.steps.first { $0.id == "snap" }?.result == .fail)

        killExistingTestHostApps()
        // 2) With --update-snapshots: writes the reference and passes.
        let r2 = try PlanRunner(driver: MacOSDriver()).run(makePlan(),
            options: RunOptions(artifactsDir: artifacts, planBaseDir: dir, updateSnapshots: true))
        #expect(r2.steps.first { $0.id == "snap" }?.result == .pass)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(refPath).path))
    }

    @Test func liveActionAndAssertCoverage() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-actions-\(UUID().uuidString)")
        // Exercise several previously-untested live paths in one plan:
        // keyPress (cmd+a select-all is harmless), setValue, and a spread of
        // assert operators/properties (matches, notEquals, enabled, title).
        let plan = Plan(
            schemaVersion: "1.0", name: "host: action+assert coverage",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                // setValue writes the field's AX value directly.
                Step(id: "setval", action: .setValue, target: Selector(identifier: "nameField"),
                     args: { var a = ActionArgs(); a.text = "Zed-42"; return a }()),
                Step(id: "matches", action: .assert, target: Selector(identifier: "nameField"),
                     assert: Assertion(property: .value, op: .matches, expected: #"Zed-\d+"#)),
                Step(id: "notEquals", action: .assert, target: Selector(identifier: "nameField"),
                     assert: Assertion(property: .value, op: .notEquals, expected: "other")),
                // okButton title is "OK" and it's enabled.
                Step(id: "title", action: .assert, target: Selector(identifier: "okButton"),
                     assert: Assertion(property: .title, op: .equals, expected: "OK")),
                Step(id: "enabled", action: .assert, target: Selector(identifier: "okButton"),
                     assert: Assertion(property: .enabled, op: .equals, expected: "true")),
                // keyPress to the field (cmd+a select-all — no destructive effect).
                Step(id: "keypress", action: .keyPress, target: Selector(identifier: "nameField"),
                     args: { var a = ActionArgs(); a.keys = "cmd+a"; return a }()),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    @Test func countAssertionMatchesMultipleElements() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-count-\(UUID().uuidString)")
        // TestHostApp's window has several AXButtons — count must be > 1, which a
        // single-match assert could never express (it would throw 'ambiguous').
        let plan = Plan(
            schemaVersion: "1.0", name: "host: count assertion",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "count-buttons", action: .assert,
                     target: Selector(role: "AXButton", within: Selector(role: "AXWindow")),
                     assert: Assertion(property: .count, op: .greaterThan, expected: "1")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    @Test func withinScopesPresenceChecks() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-within-\(UUID().uuidString)")
        // okButton exists in the window but NOT inside the menu bar. A `notExists`
        // assert scoped within the menu bar must PASS — proving count() honors
        // `within` (before the fix it walked the whole app and would FAIL).
        let withinMenuBar = Selector(identifier: "okButton", within: Selector(role: "AXMenuBar"))
        let plan = Plan(
            schemaVersion: "1.0", name: "host: within scope",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "ok-not-in-menubar", action: .assert, target: withinMenuBar,
                     assert: Assertion(property: .value, op: .notExists)),
                // Sanity: okButton DOES exist unscoped.
                Step(id: "ok-exists", action: .assert, target: Selector(identifier: "okButton"),
                     assert: Assertion(property: .value, op: .exists)),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    @Test func checkboxNumericValueIsReadable() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else {
            Issue.record("TestHostApp.app not built. Run: Fixtures/TestHostApp/make-app.sh")
            return
        }
        killExistingTestHostApps()
        defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-cb-\(UUID().uuidString)")
        let plan = Plan(
            schemaVersion: "1.0",
            name: "host: checkbox numeric value",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor,
                     target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                // A checkbox AXValue is an NSNumber — readable now via valueString.
                Step(id: "assert-unchecked", action: .assert,
                     target: Selector(identifier: "flagCheckbox"),
                     assert: Assertion(property: .value, op: .equals, expected: "0")),
                // Use AX press (robust) rather than a coordinate click on the
                // small checkbox hit-area.
                Step(id: "check-it", action: .press,
                     target: Selector(identifier: "flagCheckbox")),
                Step(id: "assert-checked", action: .assert,
                     target: Selector(identifier: "flagCheckbox"),
                     assert: Assertion(property: .value, op: .equals, expected: "1")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    // MARK: - doubleClick

    @Test func doubleClickIncrementsCounter() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-dbl-\(UUID().uuidString)")
        // dblButton is a custom view registered as AX button; doubleClick fires
        // clickCount==2 which the view checks and increments dblCount.
        let plan = Plan(
            schemaVersion: "1.0", name: "host: doubleClick",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "dbl", action: .doubleClick, target: Selector(identifier: "dblButton")),
                // After a double-click dblCount becomes 1, label reads "dbl: 1".
                Step(id: "check", action: .assert, target: Selector(identifier: "dblLabel"),
                     assert: Assertion(property: .value, op: .equals, expected: "dbl: 1")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    // MARK: - rightClick

    @Test func rightClickOpensContextMenu() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-rc-\(UUID().uuidString)")
        // rightClickTarget is a purple NSView. Right-clicking opens a context menu
        // with a single item "ContextAction". Selecting it updates statusLabel.
        // We right-click the target, then press the menu item via `menu`-style path.
        // Because the context menu is transient (not in the main menu bar), we use
        // click-based resolution: after rightClick the context menu window appears;
        // press on "ContextAction" AXMenuItem selects it.
        let plan = Plan(
            schemaVersion: "1.0", name: "host: rightClick context menu",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "right-click", action: .rightClick,
                     target: Selector(identifier: "rightClickTarget")),
                // After right-click, a context menu appears. Press the AXMenuItem
                // by its title to dismiss and fire the action.
                Step(id: "pick-item", action: .press,
                     target: Selector(role: "AXMenuItem", title: "ContextAction")),
                // The action updates statusLabel to "status: context-tapped".
                Step(id: "check-status", action: .assert, target: Selector(identifier: "statusLabel"),
                     assert: Assertion(property: .value, op: .contains, expected: "context-tapped")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    // MARK: - scroll

    @Test func scrollRevealsHiddenContent() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-scroll-\(UUID().uuidString)")
        // scrollView contains 10 numbered labels; "scroll-end" is near the bottom
        // and hidden in the initial viewport. A negative deltaY scrolls down (moves
        // content up) to reveal it; then we waitFor its presence.
        let plan = Plan(
            schemaVersion: "1.0", name: "host: scroll reveals content",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                // Scroll the scroll view down (deltaY negative = scroll down)
                Step(id: "scroll-down", action: .scroll, target: Selector(identifier: "scrollView"),
                     args: { var a = ActionArgs(); a.deltaY = -300; return a }()),
                // After scrolling, "scroll-end" becomes visible in the AX tree clip
                Step(id: "assert-end", action: .waitFor,
                     target: Selector(identifier: "scroll-end"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    // MARK: - drag

    @Test func dragMovesSliderThumb() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-drag-\(UUID().uuidString)")
        // The slider starts at 0. Dragging from its center to the sliderValueLabel
        // (which sits to the right of the slider) moves the mouse far enough right
        // that the slider value becomes > 0. We assert it changed.
        let plan = Plan(
            schemaVersion: "1.0", name: "host: drag slider",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                // Confirm slider starts at 0.
                Step(id: "assert-zero", action: .assert, target: Selector(identifier: "sliderValueLabel"),
                     assert: Assertion(property: .value, op: .equals, expected: "slider: 0")),
                // Drag from slider center to the value label (well to its right).
                Step(id: "drag-right", action: .drag,
                     target: Selector(identifier: "slider"),
                     args: { var a = ActionArgs(); a.to = Selector(identifier: "sliderValueLabel"); return a }()),
                // After drag the slider must be above 0.
                Step(id: "assert-moved", action: .assert, target: Selector(identifier: "sliderValueLabel"),
                     assert: Assertion(property: .value, op: .notEquals, expected: "slider: 0")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    // MARK: - assertPixel

    @Test func assertPixelSamplesKnownColor() async throws {
        guard AXIsProcessTrusted() else { return }
        guard CGPreflightScreenCaptureAccess() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-pixel-\(UUID().uuidString)")
        // colorSwatch is solid #3478F6 (sRGB 52,120,246). assertPixel at its center
        // must match within the default tolerance (16 RGB units).
        let plan = Plan(
            schemaVersion: "1.0", name: "host: assertPixel",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "pixel", action: .assertPixel, target: Selector(identifier: "colorSwatch"),
                     args: { var a = ActionArgs(); a.color = "#3478F6"; a.tolerance = 16; return a }()),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    // MARK: - screenshot

    @Test func screenshotElementCapturesFile() async throws {
        guard AXIsProcessTrusted() else { return }
        guard CGPreflightScreenCaptureAccess() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-shot-\(UUID().uuidString)")
        let outPath = dir.appendingPathComponent("swatch-crop.png").path
        let artifacts = dir.appendingPathComponent("art")
        // screenshot with a target crops the element; without a target it captures
        // the full display. We exercise the element-crop path and verify the file exists.
        let plan = Plan(
            schemaVersion: "1.0", name: "host: screenshot element",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "shot", action: .screenshot, target: Selector(identifier: "colorSwatch"),
                     args: { var a = ActionArgs(); a.path = outPath; a.padding = 4; return a }()),
                Step(id: "quit", action: .terminate),
            ]
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
        #expect(FileManager.default.fileExists(atPath: outPath), "screenshot file was not written to \(outPath)")
    }

    // MARK: - wait

    @Test func waitExplicitDelayPasses() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-wait-\(UUID().uuidString)")
        // wait is discouraged in production plans but must work correctly.
        // 0.05 seconds keeps the test fast while still exercising the code path.
        let plan = Plan(
            schemaVersion: "1.0", name: "host: explicit wait",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "pause", action: .wait,
                     args: { var a = ActionArgs(); a.seconds = 0.05; return a }()),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    // MARK: - focused property

    @Test func focusedPropertyDetectsFirstResponder() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-focus-\(UUID().uuidString)")
        // searchField is made first responder in applicationDidFinishLaunching.
        // After the window appears it should report focused=true.
        let plan = Plan(
            schemaVersion: "1.0", name: "host: focused property",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "search-focused", action: .assert, target: Selector(identifier: "searchField"),
                     assert: Assertion(property: .focused, op: .equals, expected: "true")),
                // nameField is NOT the first responder — must be false.
                Step(id: "name-not-focused", action: .assert, target: Selector(identifier: "nameField"),
                     assert: Assertion(property: .focused, op: .equals, expected: "false")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    // MARK: - position and size properties

    @Test func positionAndSizePropertiesAreReadable() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-possize-\(UUID().uuidString)")
        // position and size are returned as "{x, y}" and "{w, h}" strings.
        // We assert they're non-empty and contain a comma (format sanity).
        let plan = Plan(
            schemaVersion: "1.0", name: "host: position+size",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                Step(id: "pos", action: .assert, target: Selector(identifier: "colorSwatch"),
                     assert: Assertion(property: .position, op: .contains, expected: ",")),
                Step(id: "size", action: .assert, target: Selector(identifier: "colorSwatch"),
                     assert: Assertion(property: .size, op: .contains, expected: ",")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }

    // MARK: - marked property (menu-item checkmark)

    @Test func markedPropertyReadsMenuItemCheckmark() async throws {
        guard AXIsProcessTrusted() else { return }
        let binary = testHostApp()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }
        killExistingTestHostApps(); defer { killExistingTestHostApps() }

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-marked-\(UUID().uuidString)")
        // "Toggle Flag" starts unchecked (marked=false). After toggling it via the
        // menu action, the menu item's AXMenuItemMarkChar becomes non-empty (marked=true).
        let plan = Plan(
            schemaVersion: "1.0", name: "host: marked property",
            target: TargetApp(path: binary.path),
            defaults: PlanDefaults(timeoutMs: 4000, retryIntervalMs: 100),
            steps: [
                Step(id: "wait-window", action: .waitFor, target: Selector(role: "AXWindow"),
                     args: { var a = ActionArgs(); a.present = true; return a }()),
                // Before toggle: not marked.
                Step(id: "unchecked", action: .assert,
                     target: Selector(role: "AXMenuItem", title: "Toggle Flag"),
                     assert: Assertion(property: .marked, op: .equals, expected: "false")),
                // Toggle the flag via menu action (same as menuActionInvokesNoShortcutItem).
                Step(id: "toggle", action: .menu,
                     args: { var a = ActionArgs(); a.menuPath = ["View", "Toggle Flag"]; return a }()),
                // After toggle: marked.
                Step(id: "checked", action: .assert,
                     target: Selector(role: "AXMenuItem", title: "Toggle Flag"),
                     assert: Assertion(property: .marked, op: .equals, expected: "true")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }
}
