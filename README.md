# AutoPilot

A deterministic, app-agnostic macOS GUI test driver. It executes declarative
JSON test plans against any Mac app via the Accessibility API — no LLM in the
execution path, so the same plan + same app build produces the same result
every run.

> The product is **AutoPilot**. The CLI binary, Swift targets, and repository
> use lowercase/`Autopilot` spellings (`autopilot`, `AutopilotCore`,
> `AutopilotMCP`) — those are technical identifiers and are intentionally left
> as-is.

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

On first launch macOS may show a Gatekeeper warning — right-click the binary in Finder and choose Open, or run:

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

## What it does

- Drives any macOS app: launch, click, **press**, **menu**, type, key chords,
  **drag**, scroll, wait, assert.
- **Plan-as-contract:** an offline author (agent or human) writes a JSON plan;
  the executor runs it mechanically and reports structured results + failure
  artifacts (screenshots, AX-tree snapshots).
- **AX-first targeting** with a deterministic vision fallback (normalized
  cross-correlation template match) for custom-drawn controls.
- **Pixel-color assertions** for visual features the Accessibility API can't see
  (syntax colors, rainbow brackets, gutters).
- **Menu-bar navigation** drives commands with no key equivalent; reads menu
  checkmark state.
- Value assertions **poll** until they match (no flaky one-shot reads); the app
  is **activated** before input so keystrokes aren't dropped.
- **Region & snapshot visual assertions** (`assertRegion` average/dominant color,
  `snapshot` reference-image diff) for robust glyph/visual-regression checks.
- **Screenshot capture** in three modes: full display, element-scoped (crops to
  a named AX element's frame + optional padding), or absolute region. Use the
  `screenshot` action or add `captureTarget: true` to any step for a
  zero-overhead visual log entry on every run. PNG files embed step metadata.
- **Suite runner:** `autopilot run <dir>/` runs a whole directory of plans with
  one aggregate report.
- **Authoring aids:** `dump-axtree`, `find`, `suggest`, and `lint` CLI commands.
- Selector disambiguators: `index` (nth match) and `within` (parent scoping).
- Two front-ends over one shared core: a **CLI** and an **MCP server**
  (`run_plan`, `get_report`, `dump_axtree`).
- Plan composition via `include`; per-plan artifact namespacing; reliable
  back-to-back relaunch.
- **Attach mode** (`target.attach: true`): drive an already-running instance
  without a terminate-relaunch, for documentation-capture and transient-state
  workflows where you have arranged the app before the plan runs.

## Layout

```
Sources/
  AutopilotCore/      engine: plan parser, targeting, actions, assertions, reporter
  autopilot/          CLI executable
  AutopilotMCP/       MCP server (run_plan, get_report, dump_axtree)
Tests/AutopilotCoreTests/
Fixtures/TestHostApp/  tiny AppKit app with known AX identifiers, for self-testing
```

## Quick start

```bash
swift build
.build/debug/autopilot doctor                       # check Accessibility permission
.build/debug/autopilot run plan.json --artifacts ./out
.build/debug/autopilot run uitests/ --artifacts ./out   # run a whole directory (suite)
```

Exit codes: `0` pass, `1` test failure/error, `2` plan/parse error, `3` permission missing.

### Commands

| Command | What it does |
|---|---|
| `run <plan.json\|dir>` | Run a plan, or every plan in a directory (sequential, aggregate report). |
| `doctor` | Check the Accessibility permission. |
| `lint <plan\|dir>` | Static checks: non-functional selectors, missing terminate/window-wait, missing required args. |
| `dump-axtree <app> [--interactive-only]` | Print an app's AX tree to discover selectors. |
| `find <app> --identifier/--role/--title` | Show what a selector resolves to. |
| `suggest <app>` | Suggest the best selector for each interactive element. |

`run` flags: `--artifacts <dir>`, `--keep-going` (continue past failures),
`--json` (emit report JSON), `--update-snapshots` (write/refresh `snapshot`
reference images — a missing reference otherwise **fails**).

`<app>` is a bundle id (`com.example.app`) or a path to a `.app` bundle.

**Writing plans:** see **[docs/AUTHORING.md](docs/AUTHORING.md)** — the complete
plan-authoring guide (actions, assertions, selectors, discovery, hygiene
patterns, and a worked end-to-end example). Written to be usable by both an
AI agent and a human.

## Plan example

```json
{
  "schemaVersion": "1.0",
  "name": "click OK and verify count",
  "target": { "bundleId": "com.example.app" },
  "defaults": { "timeoutMs": 4000, "retryIntervalMs": 100 },
  "steps": [
    { "id": "click", "action": "click", "target": { "identifier": "okButton" } },
    { "id": "check", "action": "assert", "target": { "identifier": "countLabel" },
      "assert": { "property": "value", "op": "contains", "expected": "count: 1" } },
    { "id": "quit", "action": "terminate" }
  ]
}
```

## Requirements

macOS 14+, Swift 6 toolchain, and **Accessibility** permission granted to the
process (or terminal) running `autopilot`. **Screen Recording** permission is
additionally required for the visual actions (`assertPixel`/`assertRegion`/
`snapshot`/`screenshot`/`captureTarget`). `autopilot doctor` reports both.

## Design & roadmap

- **Authoring guide:** [docs/AUTHORING.md](docs/AUTHORING.md) — how to write plans
  (actions, assertions, selectors, suite runner, visual assertions, CLI, troubleshooting).
- **Plan schema:** [schema/plan.schema.json](schema/plan.schema.json) — point your
  editor at it for autocomplete/validation.
- **CI & releases:** [docs/CI.md](docs/CI.md).
- **Roadmap:** [docs/ROADMAP.md](docs/ROADMAP.md) — candidate work for future versions.
- **Consumer feedback & dispositions:** [docs/feedback-response.md](docs/feedback-response.md),
  [docs/review-findings.md](docs/review-findings.md).
- Original design spec and implementation plan live in the companion `medit` repo
  (`docs/specs/2026-06-16-gui-test-driver-design.md`,
  `docs/plans/2026-06-16-autopilot.md`).
