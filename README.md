# AutoPilot

Declarative macOS GUI testing via the Accessibility API. No LLM in the execution path.

![CI](https://github.com/jschwefel-CBB/autopilot/actions/workflows/ci.yml/badge.svg)

## What it does

- Test any Mac app without touching its source code. Write a JSON plan; AutoPilot drives the app via the Accessibility API and reports pass/fail.
- Plans are deterministic contracts. The same plan plus the same app build produces the same result every run.
- Targets UI elements by AX identifier, role, or title. Falls back to normalized cross-correlation template matching for custom-drawn controls the Accessibility API cannot see.
- Asserts element properties, pixel colors, region colors, and snapshot diffs for full visual coverage.
- Captures screenshots at any step — full display, cropped to a named element, or an absolute region. Add `captureTarget: true` to any step for a zero-overhead visual log on every run.
- Runs a whole directory of plans in one command and produces an aggregate report.

## Install

### Homebrew (recommended)

```bash
brew tap jschwefel-CBB/autopilot
brew install autopilot
```

After install, grant **Accessibility** permission to Terminal (or whichever app runs `autopilot`) in System Settings → Privacy & Security → Accessibility. Run `autopilot doctor` to verify.

### Direct download

Download the latest `autopilot-<version>-<arch>.tar.gz` from the [Releases page](https://github.com/jschwefel-CBB/autopilot/releases), extract, and place both `autopilot` and `AutopilotMCP` somewhere on your `$PATH`:

```bash
tar -xzf autopilot-<version>-arm64.tar.gz
sudo mv autopilot AutopilotMCP /usr/local/bin/
```

On first launch macOS may show a Gatekeeper warning. Clear the quarantine attribute:

```bash
xattr -d com.apple.quarantine /usr/local/bin/autopilot
xattr -d com.apple.quarantine /usr/local/bin/AutopilotMCP
```

### Build from source

```bash
git clone https://github.com/jschwefel-CBB/autopilot.git
cd autopilot
swift build -c release
# Binaries land in .build/release/autopilot and .build/release/AutopilotMCP
```

Requires Xcode 16+ (Swift 6 toolchain) and macOS 14+.

## Quick start

Save this plan as `calculator-smoke.json`:

```json
{
  "schemaVersion": "1.0",
  "name": "calculator-smoke",
  "target": { "bundleId": "com.apple.calculator" },
  "steps": [
    { "id": "wait-window", "action": "waitFor",
      "target": { "role": "AXWindow" } },
    { "id": "press-1",   "action": "click",
      "target": { "identifier": "One" } },
    { "id": "press-plus","action": "click",
      "target": { "identifier": "Add" } },
    { "id": "press-2",   "action": "click",
      "target": { "identifier": "Two" } },
    { "id": "press-eq",  "action": "click",
      "target": { "identifier": "Equals" } },
    { "id": "check-result", "action": "assert",
      "target": { "role": "AXStaticText", "within": { "identifier": "StandardResultView" } },
      "assert": { "property": "value", "op": "equals", "expected": "3" } },
    { "id": "done", "action": "terminate" }
  ]
}
```

Run it:

```bash
autopilot run calculator-smoke.json --artifacts /tmp/autopilot-demo
```

Expected output:

```
RESULT pass 7/7
```

Calculator is pre-installed on every Mac, so this plan runs immediately with no setup beyond granting Accessibility permission.

For a guided walkthrough, read the **[User Manual](docs/MANUAL.md)**.

## Plan format at a glance

| Action | Needs `target`? | Key args | What it does |
|---|---|---|---|
| `click` | yes | — | Single left click at the element's center. |
| `press` | yes | — | AX press action. More robust than a coordinate click. Prefer for buttons. |
| `type` | yes | `text`, `clear`, `commit` | Focus the element and type text. |
| `waitFor` | yes | `present` | Wait until the element appears or disappears. |
| `assert` | yes | `property`, `op`, `expected` | Check a property value (`equals`, `contains`, `matches`, …). |
| `terminate` | no | — | Quit the target app. Add as the last step to avoid leaked instances. |

Full action reference, selector syntax, visual assertions, and suite-runner docs: **[docs/AUTHORING.md](docs/AUTHORING.md)**.

## MCP server

AutoPilot ships an MCP server (`AutopilotMCP`) that exposes the test engine to AI agents.

Wire it to Claude Desktop by adding this to your `claude_desktop_config.json`:

```json
{ "mcpServers": { "autopilot": { "command": "/usr/local/bin/AutopilotMCP" } } }
```

The server exposes 6 tools:

| Tool | What it does |
|---|---|
| `run_plan` | Run a JSON plan (inline or from a file path) and return structured results. |
| `get_report` | Fetch the last run's report JSON, including per-step outcomes and artifact paths. |
| `dump_axtree` | Dump an app's AX tree so an agent can discover selectors. |
| `find_element` | Resolve a selector against a running app and report what it matches. |
| `suggest_selectors` | Suggest the best selector for each interactive element in a running app. |
| `lint_plan` | Static-check a plan for non-functional selectors, missing terminate, and missing required args. |

## Permissions

AutoPilot requires two macOS permissions:

**Accessibility** — required for all plans. Grants read/write access to the UI element tree. Grant it to Terminal (or your CI runner) in System Settings → Privacy & Security → Accessibility.

**Screen Recording** — required for visual actions: `assertPixel`, `assertRegion`, `snapshot`, `screenshot`, and `captureTarget`. Grant it in System Settings → Privacy & Security → Screen Recording.

Run `autopilot doctor` at any time to check the status of both permissions.

## Requirements

- macOS 14 or later.
- Swift 6 toolchain (Xcode 16+) — required only when building from source. The Homebrew and direct-download binaries are pre-built.
- No App Sandbox. AutoPilot drives other apps via the Accessibility API, which is incompatible with the sandbox.

## Contributing / license

Contributions are welcome. Open an issue or pull request against [jschwefel-CBB/autopilot](https://github.com/jschwefel-CBB/autopilot). For significant changes, open an issue first to discuss scope.

Released under the MIT license.
