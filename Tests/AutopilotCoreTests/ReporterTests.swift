import Testing
import Foundation
@testable import AutopilotCore

@Suite struct ReporterTests {
    @Test func encodesReportWithStepResults() throws {
        var report = Report(plan: "smoke")
        report.add(StepResult(id: "s1", result: .pass, durationMs: 12))
        report.add(StepResult(id: "s2", result: .fail, durationMs: 30,
                              expected: "2", actual: "1"))
        report.finalize(permissions: PermissionStatus(accessibility: true, automation: true))

        #expect(report.result == .fail) // any fail => overall fail
        let data = try JSONEncoder().encode(report)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["result"] as? String == "fail")
        let steps = obj["steps"] as! [[String: Any]]
        #expect(steps.count == 2)
        #expect(steps[1]["actual"] as? String == "1")
    }

    @Test func allPassYieldsPass() throws {
        var report = Report(plan: "p")
        report.add(StepResult(id: "a", result: .pass, durationMs: 1))
        report.finalize(permissions: PermissionStatus(accessibility: true, automation: true))
        #expect(report.result == .pass)
    }

    @Test func summaryLinePass() {
        var report = Report(plan: "p")
        report.add(StepResult(id: "a", result: .pass, durationMs: 1))
        report.add(StepResult(id: "b", result: .pass, durationMs: 1))
        report.finalize(permissions: PermissionStatus(accessibility: true, automation: true))
        #expect(Reporter().summaryLine(report) == "RESULT pass 2/2")
    }

    @Test func summaryLineFailNamesFailures() {
        var report = Report(plan: "p")
        report.add(StepResult(id: "ok", result: .pass, durationMs: 1))
        report.add(StepResult(id: "bad", result: .fail, durationMs: 1))
        report.finalize(permissions: PermissionStatus(accessibility: true, automation: true))
        #expect(Reporter().summaryLine(report) == "RESULT fail 1/2 (failed: bad)")
    }
}
