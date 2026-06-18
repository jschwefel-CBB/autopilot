import Testing
import Foundation
import ApplicationServices
@testable import AutopilotCore

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
        let runner = PlanRunner()
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
        let report = try PlanRunner().run(plan, options: RunOptions(artifactsDir: artifacts))
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
                     target: Selector(identifier: "searchField"),
                     args: { var a = ActionArgs(); a.text = "Query 9"; a.focus = false; return a }()),
                Step(id: "assert-search", action: .assert,
                     target: Selector(identifier: "searchField"),
                     assert: Assertion(property: .value, op: .equals, expected: "Query 9")),
                Step(id: "quit", action: .terminate),
            ]
        )
        let report = try PlanRunner().run(plan, options: RunOptions(artifactsDir: artifacts))
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
        let report = try PlanRunner().run(plan, options: RunOptions(artifactsDir: artifacts))
        // The click step must resolve (not error on ambiguity) — that's the point.
        let clickStep = report.steps.first { $0.id == "click-first-button" }
        #expect(clickStep?.result == .pass, "report: \(Reporter().humanSummary(report))")
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
        let report = try PlanRunner().run(plan, options: RunOptions(artifactsDir: artifacts))
        #expect(report.result == .pass, "report: \(Reporter().humanSummary(report))")
    }
}
