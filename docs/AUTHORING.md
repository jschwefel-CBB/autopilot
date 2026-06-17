# Writing an autopilot Test Plan

This is the canonical guide for authoring autopilot test plans. It is written to
be usable by **both an AI agent and a human**. An agent working on a target app
should be able to read this file and produce a valid, runnable plan.

A plan is a single JSON file describing a sequence of GUI steps and assertions.
The executor runs it mechanically and deterministically — **there is no LLM in
the execution path**, so the same plan against the same app build produces the
same result every run.

---

## 1. The mental model

```
You / an agent  ──writes──▶  plan.json  ──fed to──▶  autopilot  ──drives via AX──▶  the target app
                                                          │
                                                          └──▶ report.json + artifacts (screenshots, AX dumps)
```

- **You author offline.** The plan is the entire contract. The executor knows
  nothing about your app beyond what the plan and the Accessibility (AX) tree
  tell it.
- **Targeting is by accessibility, not pixels.** You name elements by their AX
  role / identifier; autopilot finds them in the live AX tree. (A pixel-based
  vision fallback exists for custom-drawn controls — see §7.)
- **Everything polls.** Every step waits up to a timeout for its precondition
  (element present, etc.) — you never insert manual sleeps to "wait for the UI".

---

## 2. Minimal plan skeleton

```json
{
  "schemaVersion": "1.0",
  "name": "human-readable plan name",
  "target": { "bundleId": "com.example.app" },
  "defaults": { "timeoutMs": 5000, "retryIntervalMs": 100 },
  "steps": [
    { "id": "step-1", "action": "click", "target": { "identifier": "okButton" } }
  ]
}
```

Required top-level fields:

| Field | Required | Notes |
|---|---|---|
| `schemaVersion` | yes | Must be exactly `"1.0"`. Any other value is rejected. |
| `name` | yes | Free text; appears in the report. |
| `target` | yes | Must set **either** `bundleId` **or** `path` (see §3). |
| `steps` | yes | Ordered list of step objects (§4). May be empty. |
| `include` | no | List of sub-plan files to prepend (§6). |
| `defaults` | no | `timeoutMs` (default **5000**) and `retryIntervalMs` (default **100**). |

---

## 3. The target

```json
"target": {
  "bundleId": "com.jschwefel.medit",      // resolve an installed app by bundle id
  "path": "/path/to/App.app",             // OR launch a specific .app bundle
  "launchArgs": ["--reset-state"],         // optional process args
  "launchFiles": ["/tmp/sample.txt"]       // optional files to open with the app
}
```

- Set **exactly one** of `bundleId` or `path`. Setting neither is a plan error.
- **`path` must point at a real `.app` bundle**, not a bare executable. A bare
  Mach-O does not launch as a foreground GUI app and exposes no AX tree.
- `launchArgs` is how you pass a test hook like `--reset-state` (the target app
  must honor it — see §9).

---

## 4. Steps

Each step is one action. Common shape:

```json
{ "id": "unique-id", "action": "<action>", "target": { ... }, "args": { ... }, "assert": { ... }, "timeoutMs": 4000 }
```

- `id` — **must be unique** within the plan (duplicates are rejected). Appears in
  the report, so name it meaningfully (`type-search-query`, not `s3`).
- `timeoutMs` (optional per-step) overrides the plan default for this step only.

### Action reference

| Action | Needs `target`? | Needs `args`? | What it does |
|---|---|---|---|
| `launch` | no | no | No-op marker (the app is launched automatically before step 1). |
| `terminate` | no | no | Quits the target app. **Add this as the last step** so runs don't leak instances. |
| `click` | **yes** | no | Single left click at the element's center. |
| `doubleClick` | **yes** | no | Double click. |
| `rightClick` | **yes** | no | Right click. |
| `type` | **yes** | `text` | Clicks the element to focus it, then types `text` as unicode key events. |
| `keyPress` | **yes** | `keys` | Sends a key chord, e.g. `"cmd+f"` (see §5). |
| `setValue` | **yes** (AX element) | `text` | Sets the element's AX value directly (no keystrokes). Does **not** fire keystroke-driven side effects. |
| `scroll` | **yes** | `deltaX`/`deltaY` | Scrolls by the given pixel deltas. |
| `waitFor` | **yes** | `present` | Waits until the element appears (`present: true`, default) or disappears (`present: false`). |
| `screenshot` | no | `path` (optional) | Captures the main display to PNG (defaults into the artifacts dir). |
| `assert` | **yes** | — (`assert` block) | Checks a property or presence (§4, assertions). |
| `wait` | no | `seconds` | Fixed delay. **Discouraged** — prefer `waitFor`. Use only as a last resort. |

`args` fields (only the relevant ones are read per action):

| Field | Type | Used by |
|---|---|---|
| `text` | string | `type`, `setValue` |
| `keys` | string | `keyPress` (e.g. `"shift+cmd+a"`) |
| `deltaX`, `deltaY` | int | `scroll` |
| `seconds` | number | `wait` |
| `path` | string | `screenshot` (output PNG path) |
| `present` | bool | `waitFor` (true = appears, false = disappears) |

### Assertions

An `assert` step carries an `assert` block instead of (or alongside) plain args:

```json
{ "id": "check", "action": "assert",
  "target": { "identifier": "countLabel" },
  "assert": { "property": "value", "op": "contains", "expected": "count: 1" } }
```

**Properties** (`assert.property`): `value`, `title`, `enabled`, `focused`,
`position`, `size`, `exists`.

**Operators** (`assert.op`):

| Operator | Meaning | `expected` |
|---|---|---|
| `equals` | exact string match | required |
| `notEquals` | not equal | required |
| `contains` | substring | required |
| `matches` | regular expression (NSRegularExpression) | required (the pattern) |
| `greaterThan` | numeric `>` (both sides parsed as Double; non-numeric → fail) | required |
| `lessThan` | numeric `<` | required |
| `exists` | the element resolves (presence check) | — |
| `notExists` | the element does **not** resolve | — |

Notes:
- `exists` / `notExists` assert on **presence**, not on a property value — they
  poll the AX tree for the element. Use these to verify a panel opened/closed.
- Property assertions (`value`, `title`, …) require the element to resolve via
  AX. They **cannot** be evaluated on a vision-only (pixel) match — there is no
  property to read off a pixel region.

---

## 5. Key chords (`keyPress`)

`keys` is a `+`-joined chord, case-insensitive. Modifiers: `cmd`/`command`,
`shift`, `opt`/`option`/`alt`, `ctrl`/`control`. The final token is the key.

Supported keys: letters `a`–`z`, digits `0`–`9`, and named keys `return`/`enter`,
`tab`, `space`, `delete`, `escape`, `left`, `right`, `up`, `down`.

Examples: `"cmd+s"`, `"shift+cmd+a"`, `"cmd+f"`, `"escape"`, `"ctrl+space"`.

An unknown modifier or key is a plan/runtime error — keep chords to the supported
set above.

---

## 6. Selectors — naming an element

A selector is a set of predicates that are **ANDed** together. Resolution must
match **exactly one** element: zero matches or multiple matches is a hard error
(by design — ambiguity is a bug in your plan, and the report includes a nearby
AX-subtree dump so you can fix it).

### Which selector fields actually work

| Field | Status | Notes |
|---|---|---|
| `identifier` | ✅ works | **Preferred.** Matches `AXIdentifier`. Stable, set in the app's code. |
| `role` | ✅ works | The AX role, e.g. `AXButton`, `AXTextField`, `AXTextArea`, `AXStaticText`, `AXWindow`. |
| `title` | ✅ works | Matches `AXTitle` (e.g. a button's visible label). |
| `value` | ✅ works | Matches `AXValue` (e.g. a field's current text). |
| `vision` | ✅ works | Pixel-template fallback (§7). |
| `label` | ⚠️ **not functional** | Declared in the schema but never populated during matching — a `label` selector will never match. Do not use it; use `title` or `identifier`. |
| `path` | ⚠️ **not functional** | Declared in the schema but the resolver does not consult it — silently ignored. Do not rely on it. |

> If you need to target something that only has a `label`/`path`, the right fix
> is to add an `AXIdentifier` to that control in the app (see §8), not to use the
> non-functional fields.

### Selector examples

```json
{ "identifier": "okButton" }                          // best: by identifier
{ "role": "AXButton", "title": "OK" }                 // by role + visible title
{ "role": "AXTextField", "identifier": "nameField" }  // role + identifier (extra safety)
{ "role": "AXWindow" }                                // the app's window (useful for waitFor)
```

---

## 7. Vision fallback (custom-drawn controls)

If an element exposes no usable accessibility, attach a `vision` block. The
executor screenshots the display and does a **deterministic** normalized
cross-correlation against your template image (no LLM, fixed threshold):

```json
"target": {
  "vision": { "image": "templates/play-icon.png", "confidence": 0.9 }
}
```

- `image` is a path to a PNG template (resolved relative to where you run from).
- `confidence` is the required match score `0…1`.
- Vision only fires **after** AX resolution fails. It returns a **point**, so you
  can `click`/`type` at it but you **cannot** read properties from it — property
  assertions need a real AX element.
- The template must have internal contrast; a flat/solid-color template has zero
  variance and will not match (NCC is undefined for it).

**Prefer AX identifiers.** Vision is the fallback for genuinely custom-drawn UI.

---

## 8. Discovering identifiers

You can't write good selectors without knowing what the app exposes. Two ways:

**Via the MCP server (`dump_axtree`)** — launches an app and dumps its AX tree:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"dump_axtree","arguments":{"bundleId":"com.example.app"}}}' \
  | .build/debug/AutopilotMCP
```

The result lists every node's `role`, `identifier`, `title`, and `value`. Use it
to pick selectors. (`bundleId` or `path` both work.)

**If a control has no identifier:** add one in the app's source. In AppKit:

```swift
button.setAccessibilityIdentifier("okButton")
```

In SwiftUI:

```swift
.accessibilityIdentifier("okButton")
```

This is the single highest-leverage thing you can do to make an app testable —
it moves the element onto the deterministic AX path.

---

## 9. Hygiene patterns (learned the hard way)

These aren't optional niceties — skipping them causes flaky runs.

1. **Always end with a `terminate` step.** Plans leave the app running otherwise,
   and a leaked instance poisons the next run (the resolver may walk a different
   instance's tree). Last step:
   ```json
   { "id": "quit", "action": "terminate" }
   ```

2. **Start from known state with a reset hook.** Pass a launch arg the app honors
   to clear its persisted state:
   ```json
   "target": { "bundleId": "com.example.app", "launchArgs": ["--reset-state"] }
   ```
   The app must implement it, e.g.:
   ```swift
   if CommandLine.arguments.contains("--reset-state") {
       if let domain = Bundle.main.bundleIdentifier {
           UserDefaults.standard.removePersistentDomain(forName: domain)
       }
   }
   ```

3. **Wait for the window before acting.** The first step after launch should be a
   `waitFor` on `{ "role": "AXWindow" }` so you don't act before the UI exists.

4. **Don't assert on action-only side effects.** If a label updates only on a
   field's commit (Enter/focus-loss), typing won't update it live. Either assert
   on the field's own `value`, or make the app update derived state on every
   keystroke (`controlTextDidChange`).

---

## 10. Running a plan

```bash
# Build once
swift build

# Check Accessibility permission (required to drive other apps)
.build/debug/autopilot doctor

# Run
.build/debug/autopilot run plan.json --artifacts ./artifacts
```

**Flags:** `--artifacts <dir>` (report + failure artifacts), `--keep-going`
(continue past a failing step instead of stopping), `--json` (print report JSON
instead of the human summary).

**Exit codes:** `0` pass · `1` test failure/error · `2` plan or parse error ·
`3` Accessibility permission missing.

**On failure**, autopilot writes a screenshot and an AX-tree snapshot into the
artifacts dir next to `report.json`, plus `expected`/`actual` on the failing
step — that's your debugging surface.

---

## 11. Worked end-to-end example

This is a **real, verified** plan (run against the `medit` editor). It launches
medit clean, waits for the window, types a line, asserts the editor contains that
text, and quits.

```json
{
  "schemaVersion": "1.0",
  "name": "medit: type into editor",
  "target": { "bundleId": "com.jschwefel.medit", "launchArgs": ["--reset-state"] },
  "defaults": { "timeoutMs": 6000, "retryIntervalMs": 100 },
  "steps": [
    { "id": "wait-window", "action": "waitFor",
      "target": { "role": "AXWindow" }, "args": { "present": true } },

    { "id": "type", "action": "type",
      "target": { "identifier": "editorTextView" },
      "args": { "text": "hello world" } },

    { "id": "assert-value", "action": "assert",
      "target": { "identifier": "editorTextView" },
      "assert": { "property": "value", "op": "contains", "expected": "hello world" } },

    { "id": "quit", "action": "terminate" }
  ]
}
```

Expected report: all four steps `pass`, overall `PASS`, exit `0`.

> **Why assert the editor's own value, not the status bar?** This is the central
> lesson of authoring against a real app: **assert the most direct evidence, and
> assert what the control actually shows — not what you assume.**
>
> The obvious-looking assertion — "after typing, the status bar shows line 2" —
> turned out brittle: medit's `positionLabel` reads `"Ln N, Col M"` (1-indexed,
> not a bare number), and the exact cursor position varied between runs depending
> on focus timing. Asserting the **editor's own `value` contains the typed text**
> is both more direct (it proves the typing worked) and stable (it doesn't depend
> on where the cursor ended up).
>
> When you don't know a control's exact string, **run the plan once and read
> `actual` in the failure report**, or use `dump_axtree` — never hard-code a
> guessed format.

### Composing with `include`

Factor shared setup (launch + wait-for-window) into one file and reuse it. The
included steps are **prepended** before the host plan's steps:

`setups/launch.json`:
```json
{
  "schemaVersion": "1.0",
  "name": "launch clean",
  "target": { "bundleId": "com.example.app", "launchArgs": ["--reset-state"] },
  "defaults": { "timeoutMs": 6000, "retryIntervalMs": 100 },
  "steps": [
    { "id": "wait-window", "action": "waitFor", "target": { "role": "AXWindow" }, "args": { "present": true } }
  ]
}
```

`my-test.json`:
```json
{
  "schemaVersion": "1.0",
  "name": "my test",
  "include": ["setups/launch.json"],
  "target": { "bundleId": "com.example.app", "launchArgs": ["--reset-state"] },
  "defaults": { "timeoutMs": 6000, "retryIntervalMs": 100 },
  "steps": [
    { "id": "do-thing", "action": "click", "target": { "identifier": "thingButton" } },
    { "id": "quit", "action": "terminate" }
  ]
}
```

Includes are resolved relative to the plan file, are cycle-detected, and are
depth-limited. The host plan's `target`/`defaults` win.

---

## 12. Quick checklist before you run

- [ ] `schemaVersion` is `"1.0"`.
- [ ] `target` sets exactly one of `bundleId` / `path` (path → a real `.app`).
- [ ] Every step `id` is unique and descriptive.
- [ ] Selectors use **`identifier`/`role`/`title`/`value`** (not `label`/`path`).
- [ ] First step waits for `{ "role": "AXWindow" }`.
- [ ] Actions that need it have a `target`; `type`/`setValue` have `args.text`;
      `keyPress` has `args.keys`; `assert` has an `assert` block.
- [ ] Last step is `terminate`.
- [ ] `autopilot doctor` says Accessibility: OK.
