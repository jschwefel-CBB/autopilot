import Foundation
import AutopilotCore
import MacOSDriver

/// Minimal MCP (JSON-RPC 2.0 over stdio) server exposing autopilot tools.
public final class MCPServer {
    let reporter = Reporter()
    var lastReport: Report?

    /// Where emitted JSON-RPC messages go. Defaults to stdout; tests inject a
    /// collector so they can assert on the responses without a real pipe.
    var sink: (String) -> Void

    public init(sink: @escaping (String) -> Void = { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }) {
        self.sink = sink
    }

    public func run() {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Parse error: reply per JSON-RPC so a strict client doesn't hang.
                respond(id: nil, error: ["code": -32700, "message": "Parse error: not valid JSON"]); continue
            }
            handle(msg)
        }
    }

    public func handle(_ msg: [String: Any]) {
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            respond(id: id, error: ["code": -32600, "message": "Invalid Request: missing 'method'"]); return
        }
        switch method {
        case "initialize":
            respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "autopilot", "version": "2.0.0"]
            ])
        case "tools/list":
            respond(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            handleToolCall(id: id, params: msg["params"] as? [String: Any] ?? [:])
        default:
            respond(id: id, error: ["code": -32601, "message": "Method not found: \(method)"])
        }
    }

    func handleToolCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "run_plan": runPlan(id: id, args: args)
        case "get_report": getReport(id: id)
        case "dump_axtree": dumpAXTree(id: id, args: args)
        case "find_element": findElement(id: id, args: args)
        case "suggest_selectors": suggestSelectors(id: id, args: args)
        case "lint_plan": lintPlan(id: id, args: args)
        default: respond(id: id, error: ["code": -32602, "message": "Unknown tool: \(name)"])
        }
    }

    /// Attach to a running app (bundleId/path/pid) — shared by find/suggest.
    private func attach(_ args: [String: Any]) throws -> LaunchedApp {
        if let pid = args["pid"] as? Int { return try AppLauncher().attach(pid: pid_t(pid)) }
        if let b = args["bundleId"] as? String { return try AppLauncher().attach(TargetApp(bundleId: b)) }
        if let p = args["path"] as? String { return try AppLauncher().attach(TargetApp(path: p)) }
        throw AppLaunchError.noRunningInstance("(needs bundleId, path, or pid)")
    }

    func findElement(id: Any?, args: [String: Any]) {
        do {
            let launched = try attach(args)
            let app = AXTree.application(pid: launched.pid)
            _ = Targeting().waitForPresence(Selector(role: "AXWindow"), present: true, app: app, timeoutMs: 2000, intervalMs: 100)
            let sel = Selector(role: args["role"] as? String,
                               identifier: args["identifier"] as? String,
                               title: args["title"] as? String)
            let matches = MacAXResolver().findAll(in: app, selector: sel)
            let payload: [String: Any] = ["count": matches.count, "matches": matches]
            respondToolText(id: id, text: String(data: try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]), encoding: .utf8) ?? "{}")
        } catch let e as AppLaunchError {
            respond(id: id, error: ["code": -32011, "message": "\(e)"])
        } catch { respond(id: id, error: ["code": -32603, "message": String(describing: error)]) }
    }

    func suggestSelectors(id: Any?, args: [String: Any]) {
        do {
            let launched = try attach(args)
            let app = AXTree.application(pid: launched.pid)
            _ = Targeting().waitForPresence(Selector(role: "AXWindow"), present: true, app: app, timeoutMs: 2000, intervalMs: 100)
            let suggestions = SelectorSuggester.suggest(from: AXTree.snapshot(app).nodes).map { s -> [String: Any] in
                let sel = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s.selector))) ?? [:]
                return ["role": s.role, "label": s.label, "selector": sel, "note": s.note]
            }
            respondToolText(id: id, text: String(data: try JSONSerialization.data(withJSONObject: suggestions, options: [.prettyPrinted]), encoding: .utf8) ?? "[]")
        } catch let e as AppLaunchError {
            respond(id: id, error: ["code": -32011, "message": "\(e)"])
        } catch { respond(id: id, error: ["code": -32603, "message": String(describing: error)]) }
    }

    func lintPlan(id: Any?, args: [String: Any]) {
        do {
            let data: Data; let baseDir: URL
            if let path = args["path"] as? String {
                let url = URL(fileURLWithPath: path); data = try Data(contentsOf: url); baseDir = url.deletingLastPathComponent()
            } else if let planObj = args["plan"] {
                data = try JSONSerialization.data(withJSONObject: planObj); baseDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            } else { respond(id: id, error: ["code": -32602, "message": "lint_plan needs 'plan' or 'path'"]); return }
            let plan = try PlanParser().parse(data: data, baseDirectory: baseDir)
            let findings = PlanLinter().lint(plan).map { ["severity": $0.severity.rawValue, "stepId": $0.stepId ?? "", "message": $0.message] }
            respondToolText(id: id, text: String(data: try JSONSerialization.data(withJSONObject: ["findings": findings], options: [.prettyPrinted]), encoding: .utf8) ?? "{}")
        } catch { respond(id: id, error: ["code": -32603, "message": String(describing: error)]) }
    }

    func runPlan(id: Any?, args: [String: Any]) {
        do {
            let data: Data
            let baseDir: URL
            if let path = args["path"] as? String {
                let url = URL(fileURLWithPath: path)
                data = try Data(contentsOf: url); baseDir = url.deletingLastPathComponent()
            } else if let planObj = args["plan"] {
                data = try JSONSerialization.data(withJSONObject: planObj)
                baseDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            } else {
                respond(id: id, error: ["code": -32602, "message": "run_plan needs 'plan' or 'path'"]); return
            }
            let plan = try PlanParser().parse(data: data, baseDirectory: baseDir)
            let artifacts = URL(fileURLWithPath: (args["artifactsDir"] as? String) ?? "artifacts")
            let keepGoing = (args["keepGoing"] as? Bool) ?? false
            let updateSnapshots = (args["updateSnapshots"] as? Bool) ?? false
            // Thread planBaseDir + updateSnapshots so snapshot/vision relative
            // paths resolve against the plan dir (not CWD) and an MCP caller can
            // create/refresh a snapshot baseline — parity with the CLI.
            let report = try PlanRunner(driver: MacOSDriver()).run(plan, options: RunOptions(
                keepGoing: keepGoing, artifactsDir: artifacts,
                planBaseDir: baseDir, updateSnapshots: updateSnapshots))
            lastReport = report
            let jsonText = String(data: try reporter.json(report), encoding: .utf8) ?? "{}"
            respondToolText(id: id, text: jsonText)
        } catch {
            respond(id: id, error: ["code": -32603, "message": String(describing: error)])
        }
    }

    func getReport(id: Any?) {
        guard let report = lastReport, let text = try? reporter.json(report),
              let s = String(data: text, encoding: .utf8) else {
            respond(id: id, error: ["code": -32603, "message": "No report yet"]); return
        }
        respondToolText(id: id, text: s)
    }

    func dumpAXTree(id: Any?, args: [String: Any]) {
        // ATTACH to the running instance and dump ITS tree — never launch or
        // terminate. Inspecting must observe the app as the user sees it.
        do {
            let launched: LaunchedApp
            if let pid = args["pid"] as? Int {
                launched = try AppLauncher().attach(pid: pid_t(pid))
            } else if let bundleId = args["bundleId"] as? String {
                launched = try AppLauncher().attach(TargetApp(bundleId: bundleId))
            } else if let path = args["path"] as? String {
                launched = try AppLauncher().attach(TargetApp(path: path))
            } else {
                respond(id: id, error: ["code": -32602, "message": "dump_axtree needs bundleId, path, or pid"]); return
            }
            let app = AXTree.application(pid: launched.pid)
            _ = Targeting().waitForPresence(Selector(role: "AXWindow"), present: true, app: app, timeoutMs: 2000, intervalMs: 100)
            let snap = AXTree.snapshot(app)
            let interactiveOnly = (args["interactiveOnly"] as? Bool) ?? false
            let nodes = interactiveOnly ? snap.nodes.filter { AXRoles.isInteractive($0["role"]) } : snap.nodes
            let payload: [String: Any] = [
                "pid": Int(launched.pid),
                "appName": launched.runningApp.localizedName ?? "",
                "truncated": snap.truncated, "nodeCount": nodes.count, "nodes": nodes,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            respondToolText(id: id, text: String(data: data, encoding: .utf8) ?? "{}")
        } catch let e as AppLaunchError {
            // e.g. noRunningInstance — say so clearly instead of returning a blank tree.
            respond(id: id, error: ["code": -32011, "message": "\(e)"])
        } catch {
            respond(id: id, error: ["code": -32603, "message": String(describing: error)])
        }
    }

    // MARK: - JSON-RPC plumbing

    static let toolDefinitions: [[String: Any]] = [
        ["name": "run_plan",
         "description": "Run a GUI test plan (inline 'plan' object or 'path' to JSON). LAUNCHES a fresh app instance. Returns report JSON.",
         "inputSchema": ["type": "object", "properties": [
            "plan": ["type": "object"], "path": ["type": "string"],
            "artifactsDir": ["type": "string"], "keepGoing": ["type": "boolean"],
            "updateSnapshots": ["type": "boolean"]]]],
        ["name": "get_report",
         "description": "Return the JSON report from the most recent run_plan.",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "dump_axtree",
         "description": "Attach to a RUNNING app (by bundleId, path, or pid) and dump its accessibility tree — the same tree the user sees. Never launches or terminates the app; errors clearly if no matching instance is running. Returns pid + appName so you can confirm you inspected the right process.",
         "inputSchema": ["type": "object", "properties": [
            "bundleId": ["type": "string"], "path": ["type": "string"],
            "pid": ["type": "integer"], "interactiveOnly": ["type": "boolean"]]]],
        ["name": "find_element",
         "description": "Attach to a RUNNING app and show which elements a selector (role/identifier/title) resolves to, with frames. Never launches.",
         "inputSchema": ["type": "object", "properties": [
            "bundleId": ["type": "string"], "path": ["type": "string"], "pid": ["type": "integer"],
            "role": ["type": "string"], "identifier": ["type": "string"], "title": ["type": "string"]]]],
        ["name": "suggest_selectors",
         "description": "Attach to a RUNNING app and suggest the best selector for each interactive element. Never launches.",
         "inputSchema": ["type": "object", "properties": [
            "bundleId": ["type": "string"], "path": ["type": "string"], "pid": ["type": "integer"]]]],
        ["name": "lint_plan",
         "description": "Statically check a plan (inline 'plan' object or 'path') for common mistakes. Returns findings.",
         "inputSchema": ["type": "object", "properties": [
            "plan": ["type": "object"], "path": ["type": "string"]]]],
    ]

    func respondToolText(id: Any?, text: String) {
        respond(id: id, result: ["content": [["type": "text", "text": text]]])
    }

    func respond(id: Any?, result: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        emit(msg)
    }

    func respond(id: Any?, error: [String: Any]) {
        // JSON-RPC: an error response carries id null when it can't be determined,
        // so a client can still correlate (omitting it breaks strict clients).
        let msg: [String: Any] = ["jsonrpc": "2.0", "error": error, "id": id ?? NSNull()]
        emit(msg)
    }

    func emit(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: data, encoding: .utf8) else { return }
        sink(s)
    }
}
