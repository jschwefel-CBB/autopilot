import Foundation
import ApplicationServices
import ArgumentParser
import AutopilotCore

struct Autopilot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autopilot",
        abstract: "Run a declarative GUI test plan against a macOS app.",
        subcommands: [Run.self, Doctor.self, DumpAxtree.self, Lint.self, Find.self, Suggest.self],
        defaultSubcommand: Run.self
    )
}

/// Shared helper for inspection commands (dump-axtree/find/suggest): ATTACH to a
/// running instance (never launch/terminate). Resolves by --pid first, else by
/// the bundleId/path argument → frontmost running instance.
enum Inspect {
    /// The shared macOS backend the inspection commands route through.
    static let driver = MacOSDriver()

    static func attach(app appArg: String?, pid: Int32?) throws -> LaunchedHandle {
        guard driver.hasAccessibility() else {
            FileHandle.standardError.write(Data("Accessibility permission required (run: autopilot doctor)\n".utf8))
            throw ExitCode(3)
        }
        do {
            let handle: LaunchedHandle
            if let pid {
                handle = try driver.attach(pid: pid)
            } else {
                guard let appArg else {
                    FileHandle.standardError.write(Data("Provide an app (bundle id or .app path) or --pid.\n".utf8))
                    throw ExitCode(2)
                }
                let target: TargetApp = appArg.hasSuffix(".app") || appArg.hasPrefix("/")
                    ? TargetApp(path: appArg) : TargetApp(bundleId: appArg)
                handle = try driver.attach(target)
            }
            // Wait briefly for the AX tree to be queryable before inspecting it.
            _ = driver.waitForPresence(Selector(role: "AXWindow"), present: true,
                                       app: handle, timeoutMs: 2000, intervalMs: 100)
            return handle
        } catch let e as AppLaunchError {
            FileHandle.standardError.write(Data("\(e)\n".utf8))
            throw ExitCode(2)
        }
    }
}

struct Suggest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suggest",
        abstract: "Attach to a RUNNING app and suggest a selector for each interactive element.")

    @Argument(help: "Bundle id or path to a .app bundle (of the running app).")
    var app: String?

    @Option(name: .long, help: "Attach to a specific running process by pid (unambiguous).")
    var pid: Int32?

    func run() throws {
        let handle = try Inspect.attach(app: app, pid: pid)   // attach, never launch
        let suggestions = Inspect.driver.suggestSelectors(app: handle)
        for s in suggestions {
            let sel = (try? String(data: JSONEncoder.pretty.encode(s.selector), encoding: .utf8)) ?? ""
            let oneLine = sel.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
            let label = s.label.isEmpty ? "" : "  “\(s.label)”"
            print("\(s.role)\(label)\n    \(oneLine)\n    # \(s.note)")
        }
    }
}

struct DumpAxtree: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-axtree",
        abstract: "Attach to a RUNNING app and print its accessibility tree (for authoring selectors).")

    @Argument(help: "Bundle id (com.example.app) or a path to a .app bundle (of the running app).")
    var app: String?

    @Option(name: .long, help: "Attach to a specific running process by pid (unambiguous).")
    var pid: Int32?

    @Flag(name: .long, help: "Only include interactive elements (buttons, fields, rows, …).")
    var interactiveOnly: Bool = false

    func run() throws {
        let handle = try Inspect.attach(app: app, pid: pid)   // attach, never launch
        let snap = Inspect.driver.dumpTree(app: handle)
        let nodes = interactiveOnly ? snap.nodes.filter { AXRoles.isInteractive($0["role"]) } : snap.nodes
        let payload: [String: Any] = [
            "pid": handle.pid,
            "appName": handle.appName,
            "truncated": snap.truncated, "nodeCount": nodes.count, "nodes": nodes,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct Lint: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lint",
        abstract: "Statically check a plan (or a directory of plans) for common mistakes.")

    @Argument(help: "Path to a plan .json file or a directory of plans.")
    var path: String

    func run() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            FileHandle.standardError.write(Data("Not found: \(path)\n".utf8)); throw ExitCode(2)
        }
        let urls = isDir.boolValue
            ? Run.discoverPlans(in: URL(fileURLWithPath: path))
            : [URL(fileURLWithPath: path)]
        var anyFindings = false
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let plan: Plan
            do { plan = try PlanParser().parse(data: data, baseDirectory: url.deletingLastPathComponent()) }
            catch {
                print("\(url.lastPathComponent): ERROR \(error)")
                anyFindings = true; continue
            }
            let findings = PlanLinter().lint(plan)
            if findings.isEmpty {
                print("\(url.lastPathComponent): ok")
            } else {
                anyFindings = true
                for f in findings {
                    let loc = f.stepId.map { " [\($0)]" } ?? ""
                    print("\(url.lastPathComponent):\(loc) \(f.severity.rawValue): \(f.message)")
                }
            }
        }
        if anyFindings { throw ExitCode(1) }
    }
}

struct Find: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Attach to a RUNNING app and show which elements a selector resolves to.")

    @Argument(help: "Bundle id or path to a .app bundle (of the running app).")
    var app: String?

    @Option(name: .long, help: "Attach to a specific running process by pid (unambiguous).")
    var pid: Int32?

    @Option(name: .long, help: "AX role to match, e.g. AXButton.")
    var role: String?
    @Option(name: .long, help: "AX identifier to match.")
    var identifier: String?
    @Option(name: .long, help: "AX title to match.")
    var title: String?

    func run() throws {
        let handle = try Inspect.attach(app: app, pid: pid)   // attach, never launch
        let selector = Selector(role: role, identifier: identifier, title: title)
        let matches = Inspect.driver.findAll(selector, app: handle)
        print("\(matches.count) match(es) for \(AXResolver.describe(selector)):")
        for m in matches { print("  \(m)") }
        if matches.count != 1 { throw ExitCode(1) }
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Execute a plan JSON file.")

    @Argument(help: "Path to the plan JSON file.")
    var planPath: String

    @Option(name: .long, help: "Directory for report.json and failure artifacts.")
    var artifacts: String = "artifacts"

    @Flag(name: .long, help: "Continue after a failing step instead of stopping.")
    var keepGoing: Bool = false

    @Flag(name: .long, help: "Write/overwrite snapshot reference images (otherwise a missing reference fails).")
    var updateSnapshots: Bool = false

    @Flag(name: .long, help: "Print report.json to stdout instead of the human summary.")
    var json: Bool = false

    func run() throws {
        let url = URL(fileURLWithPath: planPath)
        let artifactsURL = URL(fileURLWithPath: artifacts)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            FileHandle.standardError.write(Data("Cannot read plan: \(planPath)\n".utf8)); throw ExitCode(2)
        }
        if isDir.boolValue {
            try runSuite(dir: url, artifactsURL: artifactsURL)
        } else {
            try runSingle(planURL: url, artifactsURL: artifactsURL)
        }
    }

    private func runSingle(planURL: URL, artifactsURL: URL) throws {
        let baseDir = planURL.deletingLastPathComponent()
        let data: Data
        do { data = try Data(contentsOf: planURL) }
        catch { FileHandle.standardError.write(Data("Cannot read plan: \(planURL.path)\n".utf8)); throw ExitCode(2) }

        let plan: Plan
        do { plan = try PlanParser().parse(data: data, baseDirectory: baseDir) }
        catch {
            FileHandle.standardError.write(Data("Plan error: \(error)\n".utf8))
            throw ExitCode(2)
        }

        let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(
            keepGoing: keepGoing, artifactsDir: artifactsURL, planBaseDir: baseDir,
            updateSnapshots: updateSnapshots))
        let reporter = Reporter()
        if json {
            FileHandle.standardOutput.write(try reporter.json(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(reporter.humanSummary(report))
        }
        FileHandle.standardError.write(Data((reporter.summaryLine(report) + "\n").utf8))

        if report.permissions?.accessibility == false { throw ExitCode(3) }
        switch report.result {
        case .pass, .skipped: return
        case .fail, .error: throw ExitCode(1)
        }
    }

    /// Run every *.json plan in `dir` (recursively, sorted) sequentially.
    /// Plans MUST run one at a time: macOS has a single keyboard/mouse focus,
    /// so input-driving plans cannot run in parallel without fighting over it.
    private func runSuite(dir: URL, artifactsURL: URL) throws {
        let planURLs = Self.discoverPlans(in: dir)
        guard !planURLs.isEmpty else {
            FileHandle.standardError.write(Data("No .json plans found under: \(dir.path)\n".utf8))
            throw ExitCode(2)
        }
        var reports: [Report] = []
        var permMissing = false
        for planURL in planURLs {
            let baseDir = planURL.deletingLastPathComponent()
            let name = planURL.lastPathComponent
            // An unreadable/invalid plan is an ERROR, not a silent skip — else a
            // suite of all-broken plans would report SUITE pass 0/0 and exit 0.
            guard let data = try? Data(contentsOf: planURL) else {
                reports.append(Self.errorReport(name, "could not read plan file"))
                FileHandle.standardError.write(Data("  [error] \(name): unreadable\n".utf8)); continue
            }
            let plan: Plan
            do { plan = try PlanParser().parse(data: data, baseDirectory: baseDir) }
            catch {
                reports.append(Self.errorReport(name, "invalid plan: \(error)"))
                FileHandle.standardError.write(Data("  [error] \(name): invalid (\(error))\n".utf8)); continue
            }
            // A thrown launch (or other) error for ONE plan must not abort the
            // whole suite — record it as an error report and keep going so the
            // remaining plans run and suite.json is always written.
            let report: Report
            do {
                report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(
                    keepGoing: keepGoing, artifactsDir: artifactsURL, planBaseDir: baseDir,
                    updateSnapshots: updateSnapshots))
            } catch {
                report = Self.errorReport(plan.name, "run failed: \(error)")
            }
            if report.permissions?.accessibility == false { permMissing = true }
            reports.append(report)
            FileHandle.standardError.write(Data("  [\(report.result.rawValue)] \(report.plan)\n".utf8))
        }
        let suite = SuiteReport(reports: reports)
        // Write the aggregate suite report next to the per-plan artifact dirs.
        if let suiteData = try? JSONEncoder.pretty.encode(suite) {
            try? FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
            try? suiteData.write(to: artifactsURL.appendingPathComponent("suite.json"))
        }
        if json {
            FileHandle.standardOutput.write((try? JSONEncoder.pretty.encode(suite)) ?? Data())
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(suite.humanSummary())
        }
        FileHandle.standardError.write(Data((suite.summaryLine() + "\n").utf8))

        if permMissing { throw ExitCode(3) }
        switch suite.result {
        case .pass, .skipped: return
        case .fail, .error: throw ExitCode(1)
        }
    }

    /// A synthetic error Report for a plan that couldn't be read/parsed/run, so
    /// the suite aggregate counts it (and exits non-zero) instead of skipping it.
    static func errorReport(_ name: String, _ message: String) -> Report {
        var r = Report(plan: name)
        r.add(StepResult(id: "_plan", result: .error, durationMs: 0, message: message))
        r.finalize(permissions: PermissionStatus(accessibility: true, screenRecording: true))
        return r
    }

    /// All *.json plan files under `dir`, recursively, in stable sorted order.
    /// Files under a `setups/` directory are treated as include-only fragments
    /// (not standalone plans) and skipped — a common suite convention.
    static func discoverPlans(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where u.pathExtension == "json" {
            if u.pathComponents.contains("setups") { continue }
            out.append(u)
        }
        return out.sorted { $0.path < $1.path }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check required permissions.")
    func run() throws {
        let driver = MacOSDriver()
        var missing = false
        if driver.hasAccessibility() {
            print("Accessibility:    OK")
        } else {
            print("Accessibility:    MISSING")
            print(driver.accessibilityInstructions())
            missing = true
        }
        // Screen Recording is required for visual actions. Report it but don't
        // make it fatal on its own — many plans don't use visual assertions.
        if driver.hasScreenRecording() {
            print("Screen Recording: OK")
        } else {
            print("Screen Recording: MISSING (needed only for assertPixel/assertRegion/snapshot/screenshot)")
            print(driver.screenRecordingInstructions())
        }
        if missing { throw ExitCode(3) }
    }
}

Autopilot.main()
