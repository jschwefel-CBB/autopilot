import Foundation

public struct Reporter {
    public init() {}

    /// Encode the report as pretty JSON.
    public func json(_ report: Report) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(report)
    }

    /// Write report.json into `directory`, creating it if needed. Returns the file URL.
    @discardableResult
    public func write(_ report: Report, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("report.json")
        try json(report).write(to: url)
        return url
    }

    /// One-line-per-step human summary for stdout.
    public func humanSummary(_ report: Report) -> String {
        var lines = ["Plan: \(report.plan)  =>  \(report.result.rawValue.uppercased())  (\(report.durationMs)ms)"]
        for s in report.steps {
            var line = "  [\(s.result.rawValue)] \(s.id) (\(s.durationMs)ms)"
            if s.result == .fail, let e = s.expected, let a = s.actual {
                line += "  expected=\(e) actual=\(a)"
            }
            if let m = s.message { line += "  \(m)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
