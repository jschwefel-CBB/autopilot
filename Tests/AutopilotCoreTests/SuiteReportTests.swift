import Testing
import Foundation
@testable import AutopilotCore

@Suite struct SuiteReportTests {
    func report(_ name: String, _ outcome: StepOutcome) -> Report {
        var r = Report(plan: name)
        r.add(StepResult(id: "s", result: outcome, durationMs: 10))
        r.finalize(permissions: PermissionStatus(accessibility: true, screenRecording: true))
        return r
    }

    @Test func allPassAggregates() {
        let s = SuiteReport(reports: [report("a", .pass), report("b", .pass)])
        #expect(s.total == 2 && s.passed == 2 && s.result == .pass)
        #expect(s.summaryLine() == "SUITE pass 2/2")
    }

    @Test func failDominatesAndIsNamed() {
        let s = SuiteReport(reports: [report("a", .pass), report("bad", .fail)])
        #expect(s.result == .fail)
        #expect(s.summaryLine() == "SUITE fail 1/2 (failed: bad)")
    }

    @Test func errorDominatesFail() {
        let s = SuiteReport(reports: [report("a", .fail), report("b", .error)])
        #expect(s.result == .error)
        #expect(s.errored == 1 && s.failed == 1)
    }

    @Test func durationsSum() {
        let s = SuiteReport(reports: [report("a", .pass), report("b", .pass)])
        #expect(s.durationMs == 20)
    }

    @Test func emptySuiteIsErrorNotPass() {
        let s = SuiteReport(reports: [])
        #expect(s.result == .error)
        #expect(s.total == 0)
    }

    @Test func emptyStepsReportIsError() {
        var r = Report(plan: "no-steps")
        r.finalize(permissions: PermissionStatus(accessibility: true, screenRecording: true))
        #expect(r.result == .error)
    }
}
