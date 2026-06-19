import Foundation
import AppKit

public struct LaunchedApp {
    public let pid: pid_t
    public let runningApp: NSRunningApplication
}

public enum AppLaunchError: Error, CustomStringConvertible {
    case notFound(String)
    case launchFailed(String)
    case noRunningInstance(String)
    public var description: String {
        switch self {
        case .notFound(let s): return "App not found: \(s)"
        case .launchFailed(let s): return "Failed to launch: \(s)"
        case .noRunningInstance(let s):
            return "No running instance of \(s) — start it first, or pass --pid, " +
                   "or use a command that launches the app (run)."
        }
    }
}

public struct AppLauncher {
    public init() {}

    /// Resolve the app URL from a TargetApp (bundleId or explicit path).
    public func resolveURL(_ target: TargetApp) throws -> URL {
        if let path = target.path { return URL(fileURLWithPath: path) }
        if let bundleId = target.bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url
        }
        throw AppLaunchError.notFound(target.bundleId ?? target.path ?? "?")
    }

    /// Launch the target app, opening any launchFiles, and return the running app.
    public func launch(_ target: TargetApp) throws -> LaunchedApp {
        let url = try resolveURL(target)
        // Wait for any already-running instance of the same app to exit first, so
        // back-to-back plans (a suite) never race a fresh launch against a prior
        // instance's teardown — which otherwise drops the first input step.
        waitForExistingInstancesToExit(of: url, timeout: 3.0)
        let config = NSWorkspace.OpenConfiguration()
        if let args = target.launchArgs { config.arguments = args }
        let fileURLs = (target.launchFiles ?? []).map { URL(fileURLWithPath: $0) }

        // LaunchServices can transiently refuse to start an app that was just
        // terminated ("a miscellaneous error occurred") while it finishes tearing
        // the prior instance down. Retry a few times with a short backoff so a
        // suite's back-to-back relaunch of the same app is reliable.
        var lastError: Error = AppLaunchError.launchFailed(url.path)
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
            let sem = DispatchSemaphore(value: 0)
            var result: Result<NSRunningApplication, Error>?
            let completion: (NSRunningApplication?, Error?) -> Void = { app, err in
                if let app { result = .success(app) }
                else { result = .failure(err ?? AppLaunchError.launchFailed(url.path)) }
                sem.signal()
            }
            if fileURLs.isEmpty {
                NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: completion)
            } else {
                NSWorkspace.shared.open(fileURLs, withApplicationAt: url, configuration: config, completionHandler: completion)
            }
            sem.wait()
            switch result! {
            case .success(let app): return LaunchedApp(pid: app.processIdentifier, runningApp: app)
            case .failure(let err): lastError = err   // transient: retry
            }
        }
        throw lastError
    }

    public func terminate(_ app: LaunchedApp) {
        app.runningApp.terminate()
    }

    /// Pure selection: from a list of running apps, choose the one to inspect —
    /// the active (frontmost) one if any is active, else the first. Returns nil
    /// for an empty list. Kept separate from AppKit so it is unit-testable via
    /// a parallel helper; the live version uses NSRunningApplication directly.
    static func chooseFrontmost<T>(_ apps: [T], isActive: (T) -> Bool) -> T? {
        if let active = apps.first(where: isActive) { return active }
        return apps.first
    }

    /// Attach to the already-running instance of `target` WITHOUT launching or
    /// terminating anything — for inspection commands (dump-axtree/find/suggest).
    /// Prefers the frontmost instance. Throws if nothing matching is running.
    public func attach(_ target: TargetApp) throws -> LaunchedApp {
        let url = try resolveURL(target)
        let matches = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == url.standardizedFileURL
                || (target.bundleId != nil && $0.bundleIdentifier == target.bundleId)
        }
        guard let app = Self.chooseFrontmost(matches, isActive: { $0.isActive }) else {
            throw AppLaunchError.noRunningInstance(target.bundleId ?? target.path ?? url.path)
        }
        return LaunchedApp(pid: app.processIdentifier, runningApp: app)
    }

    /// Attach to a specific running process by pid. The unambiguous escape hatch.
    public func attach(pid: pid_t) throws -> LaunchedApp {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw AppLaunchError.noRunningInstance("pid \(pid)")
        }
        return LaunchedApp(pid: pid, runningApp: app)
    }

    /// Block until no running application shares `url`'s bundle, or the timeout
    /// elapses (then forcibly terminate stragglers so the next launch is clean).
    func waitForExistingInstancesToExit(of url: URL, timeout: TimeInterval) {
        func instances() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { $0.bundleURL == url }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var running = instances()
        while !running.isEmpty, Date() < deadline {
            running.forEach { $0.terminate() }
            Thread.sleep(forTimeInterval: 0.1)
            running = instances()
        }
        // Last resort: force-kill anything still up.
        instances().forEach { $0.forceTerminate() }
    }

    /// Bring the app frontmost and poll until it is active, so synthesized
    /// keystrokes land on its key window rather than a not-yet-foreground one.
    /// Returns whether the app became active within the timeout.
    @discardableResult
    public func activate(_ app: LaunchedApp, timeoutMs: Int, intervalMs: Int,
                         clock: Clock = SystemClock()) -> Bool {
        let poller = Poller(clock: clock)
        return poller.waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            if !app.runningApp.isActive {
                app.runningApp.activate(options: [.activateAllWindows])
            }
            return app.runningApp.isActive
        }
    }
}
