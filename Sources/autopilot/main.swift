import Foundation
import ArgumentParser
import AutopilotCore

struct Autopilot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autopilot",
        abstract: "Run a declarative GUI test plan against a macOS app.",
        subcommands: [Run.self, Doctor.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Execute a plan JSON file.")

    @Argument(help: "Path to the plan JSON file.")
    var planPath: String

    @Option(name: .long, help: "Directory for report.json and failure artifacts.")
    var artifacts: String = "artifacts"

    @Flag(name: .long, help: "Continue after a failing step instead of stopping.")
    var keepGoing: Bool = false

    @Flag(name: .long, help: "Print report.json to stdout instead of the human summary.")
    var json: Bool = false

    func run() throws {
        let planURL = URL(fileURLWithPath: planPath)
        let baseDir = planURL.deletingLastPathComponent()
        let data: Data
        do { data = try Data(contentsOf: planURL) }
        catch { FileHandle.standardError.write(Data("Cannot read plan: \(planPath)\n".utf8)); throw ExitCode(2) }

        let plan: Plan
        do { plan = try PlanParser().parse(data: data, baseDirectory: baseDir) }
        catch {
            FileHandle.standardError.write(Data("Plan error: \(error)\n".utf8))
            throw ExitCode(2)
        }

        let artifactsURL = URL(fileURLWithPath: artifacts)
        let report = try PlanRunner().run(plan, options: RunOptions(keepGoing: keepGoing, artifactsDir: artifactsURL))
        let reporter = Reporter()
        try reporter.write(report, to: artifactsURL)

        if json {
            FileHandle.standardOutput.write(try reporter.json(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(reporter.humanSummary(report))
        }
        // Always emit a single machine-greppable summary line on stderr, so shell
        // loops can read it without parsing the human summary or report.json,
        // and without colliding with --json stdout.
        FileHandle.standardError.write(Data((reporter.summaryLine(report) + "\n").utf8))

        // Distinct exit codes.
        if report.permissions?.accessibility == false { throw ExitCode(3) }
        switch report.result {
        case .pass, .skipped: return
        case .fail: throw ExitCode(1)
        case .error: throw ExitCode(1)
        }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check required permissions.")
    func run() throws {
        let perms = Permissions()
        if perms.hasAccessibility() {
            print("Accessibility: OK")
        } else {
            print("Accessibility: MISSING")
            print(perms.accessibilityInstructions())
            throw ExitCode(3)
        }
    }
}

Autopilot.main()
