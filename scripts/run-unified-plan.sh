#!/usr/bin/env bash
# Run the unified capability plan via the autopilot CLI against the built
# TestHostApp fixture, exactly as an end user would. This is the macOS analogue
# of the iOS XCUITest / Android instrumented run: it exercises the full 78-step
# plan end-to-end and FAILS (non-zero) if any step fails.
#
# Targets the fixture BY ABSOLUTE PATH (not bundleId) so it is deterministic and
# never resolves a same-bundle-id app from elsewhere on the machine.
#
# Requires: Accessibility + Screen Recording permission for the process running
# this (locally: grant your terminal; in CI the runner grants them). Build the
# CLI (`swift build`) and the fixture (`Fixtures/TestHostApp/make-app.sh`) first,
# or pass --build to have this script do both.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CLI="$REPO_ROOT/.build/debug/autopilot"
APP="$REPO_ROOT/Fixtures/TestHostApp/.build/TestHostApp.app"
PLAN_SRC="$REPO_ROOT/Fixtures/TestHostApp/test-all-capabilities.json"

if [ "${1:-}" = "--build" ]; then
  echo "==> Building CLI"
  swift build
  echo "==> Building TestHostApp fixture"
  "$REPO_ROOT/Fixtures/TestHostApp/make-app.sh"
fi

[ -x "$CLI" ] || { echo "CLI not built at $CLI (run: swift build)"; exit 2; }
[ -d "$APP" ] || { echo "Fixture not built at $APP (run: Fixtures/TestHostApp/make-app.sh)"; exit 2; }
[ -f "$PLAN_SRC" ] || { echo "Plan not found at $PLAN_SRC"; exit 2; }

# Stage the plan with its target rewritten to the fixture's absolute path.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$PLAN_SRC" "$APP" "$WORK/plan.json" <<'PY'
import json, sys
src, app, dst = sys.argv[1], sys.argv[2], sys.argv[3]
plan = json.load(open(src))
plan["target"] = {"path": app}
json.dump(plan, open(dst, "w"), indent=2)
PY

echo "==> Running unified plan against $APP"
# --update-snapshots: create the snapshot baseline on first run (the snapshot
# step compares a 30x30 swatch crop; with no committed baseline it would fail).
# --keep-going: run ALL steps so the report shows every failure at once (the
# report.json check below still fails the job on any failed step). AP_DEBUG_FILE
# lets the fixture log whether advanceTapped actually fired (diagnosing the CI
# progress-advance failure).
export AP_DEBUG_FILE="$WORK/ap-debug.log"
: > "$AP_DEBUG_FILE"
"$CLI" run "$WORK/plan.json" --artifacts "$WORK/artifacts" --update-snapshots --keep-going || true
echo "==> AP_DEBUG (advanceTapped trace):"
cat "$AP_DEBUG_FILE" 2>/dev/null || echo "(empty — advanceTapped never fired)"

# Belt-and-suspenders: assert the report shows zero failures even if the exit
# code were ever masked.
REPORT="$(find "$WORK/artifacts" -name report.json | head -1)"
python3 - "$REPORT" <<'PY'
import json, sys
from collections import Counter
r = json.load(open(sys.argv[1]))
c = Counter(s["result"] for s in r["steps"])
fails = [s["id"] for s in r["steps"] if s["result"] == "fail"]
print(f"unified plan: {dict(c)} over {len(r['steps'])} steps; overall={r['result']}")
if fails:
    print("FAILED STEPS:", fails)
    sys.exit(1)
if r["result"] != "pass":
    print("overall result not pass"); sys.exit(1)
PY

echo "==> Unified plan PASSED"
