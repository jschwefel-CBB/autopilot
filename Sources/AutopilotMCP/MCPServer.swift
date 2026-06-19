import Foundation
import AutopilotCore

/// Minimal MCP (JSON-RPC 2.0 over stdio) server exposing autopilot tools.
final class MCPServer {
    let reporter = Reporter()
    var lastReport: Report?

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handle(msg)
        }
    }

    func handle(_ msg: [String: Any]) {
        let id = msg["id"]
        guard let method = msg["method"] as? String else { return }
        switch method {
        case "initialize":
            respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "autopilot", "version": "1.0.0"]
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
        default: respond(id: id, error: ["code": -32602, "message": "Unknown tool: \(name)"])
        }
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
            let report = try PlanRunner().run(plan, options: RunOptions(keepGoing: keepGoing, artifactsDir: artifacts))
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
         "description": "Run a GUI test plan (inline 'plan' object or 'path' to JSON). Returns report JSON.",
         "inputSchema": ["type": "object", "properties": [
            "plan": ["type": "object"], "path": ["type": "string"],
            "artifactsDir": ["type": "string"], "keepGoing": ["type": "boolean"]]]],
        ["name": "get_report",
         "description": "Return the JSON report from the most recent run_plan.",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "dump_axtree",
         "description": "Attach to a RUNNING app (by bundleId, path, or pid) and dump its accessibility tree — the same tree the user sees. Never launches or terminates the app; errors clearly if no matching instance is running. Returns pid + appName so you can confirm you inspected the right process.",
         "inputSchema": ["type": "object", "properties": [
            "bundleId": ["type": "string"], "path": ["type": "string"],
            "pid": ["type": "integer"], "interactiveOnly": ["type": "boolean"]]]],
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
        var msg: [String: Any] = ["jsonrpc": "2.0", "error": error]
        if let id { msg["id"] = id }
        emit(msg)
    }

    func emit(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
