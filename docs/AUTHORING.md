# Writing an AutoPilot Test Plan

> New to AutoPilot? Start with the **[User Manual](https://github.com/jschwefel-CBB/autopilot-core/blob/main/docs/MANUAL.md)** for a guided introduction (it lives in `autopilot-core` — the plan format is shared across platforms). This document is the macOS-specific reference.

This is the canonical guide for authoring AutoPilot test plans. It is written to
be usable by **both an AI agent and a human**. An agent working on a target app
should be able to read this file and produce a valid, runnable plan.

> **Naming:** the product is **AutoPilot**. The CLI binary is the lowercase
> `autopilot` and the Swift targets are `AutopilotCore` / `AutopilotMCP` —
> shown verbatim in command and code blocks below.

A plan is a single JSON file describing a sequence of GUI steps and assertions.
The executor runs it mechanically and deterministically — **there is no LLM in
the execution path**, so the same plan against the same app build produces the
same result every run.

> **Plans don't have to test.** Assertions are optional. A plan made only of
> action steps (`click`, `type`, `menu`, `waitFor`, `drag`, …) is an **automation
> script** that drives an app to accomplish a task rather than verify it — and
> with `target.attach: true` (see §3) it drives an already-running app from its
> current state. Everything in this reference applies equally whether you are
> writing a test plan or an automation plan; just include or omit `assert` steps
> as needed.

---

## 1. The mental model

```
You / an agent  ──writes──▶  plan.json  ──fed to──▶  AutoPilot  ──drives via AX──▶  the target app
                                                          │
                                                          └──▶ report.json + artifacts (screenshots, AX dumps)
```

- **You author offline.** The plan is the entire contract. The executor knows
  nothing about your app beyond what the plan and the Accessibility (AX) tree
  tell it.
- **Targeting is by accessibility, not pixels.** You name elements by their AX
  role / identifier; AutoPilot finds them in the live AX tree. (A pixel-based
  vision fallback exists for custom-drawn controls — see §7.)
- **Everything polls.** Every step waits up to a timeout for its precondition
  (element present, etc.) — you never insert manual sleeps to "wait for the UI".

---

## 2. Minimal plan skeleton

```json
{
  "schemaVersion": "1.1",
  "name": "human-readable plan name",
  "target": { "bundleId": "com.example.app" },
  "defaults": { "timeoutMs": 5000, "retryIntervalMs": 100 },
  "steps": [
    { "id": "step-1", "action": "click", "level": "happyPath", "target": { "identifier": "okButton" } }
  ]
}
```

Required top-level fields:

| Field | Required | Notes |
|---|---|---|
| `schemaVersion` | yes | Must be exactly `"1.1"`. Any other value is rejected. |
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
  "launchFiles": ["/tmp/sample.txt"],      // optional files to open with the app
  "attach": true                           // optional: use already-running instance
}
```

- Set **exactly one** of `bundleId` or `path`. Setting neither is a plan error.
- **`path` must point at a real `.app` bundle**, not a bare executable. A bare
  Mach-O does not launch as a foreground GUI app and exposes no AX tree.
- `launchArgs` is how you pass a test hook like `--reset-state` (the target app
  must honor it — see §9).
- **`attach: true`** — attach to the frontmost already-running instance instead
  of terminating and relaunching it. The run **fails immediately** if no matching
  instance is running. Use this when you need to drive the app from a specific
  state you arranged manually — e.g. a documentation-capture plan that needs a
  particular document open, or a transient UI state (open panel, Recent pane
  focused) that a fresh launch would reset. `launchArgs` and `launchFiles` are
  ignored when `attach: true`. PlanLinter warns if either is set alongside
  `attach: true`.

---

## 4. Steps

Each step is one action. Common shape:

```json
{ "id": "unique-id", "action": "<action>", "level": "happyPath", "target": { ... }, "args": { ... }, "assert": { ... }, "timeoutMs": 4000 }
```

- `id` — **must be unique** within the plan (duplicates are rejected). Appears in
  the report, so name it meaningfully (`type-search-query`, not `s3`).
- `level` — **REQUIRED** on every step. The step's coverage tier — one of
  `happyPath`, `integrationSuite`, `tryToBreakIt` (see §4a). A plan with a step
  missing `level`, or with an invalid value, is rejected at parse time.
- `timeoutMs` (optional per-step) overrides the plan default for this step only.
- `captureTarget` (optional, bool) — when `true`, AutoPilot saves a cropped
  screenshot of the step's `target` element on **any** outcome (pass or fail) as
  `<id>-target.png` in the artifacts dir. No dedicated `screenshot` step needed.
  Use `args.padding` (default 8) to add breathing room around the element.

### Action reference

| Action | Needs `target`? | Needs `args`? | What it does |
|---|---|---|---|
| `launch` | no | no | No-op marker (the app is launched automatically before step 1). |
| `terminate` | no | no | Quits the target app. **Add this as the last step** so runs don't leak instances. |
| `click` | **yes** | no | Single left click at the element's center. |
| `doubleClick` | **yes** | no | Double click. |
| `rightClick` | **yes** | no | Right click. |
| `press` | **yes** | no | Performs the AX **press** action on the element. More robust than a coordinate click, and works for elements with no clickable frame. Prefer for buttons. |
| `menu` | no | `menuPath` | Walks the menu bar by title path (e.g. `["View","Rainbow Brackets"]`) and invokes the item. **The only way to drive a menu command with no key equivalent** — a `click` cannot open a closed menu. |
| `type` | **yes** | `text` (+ `clear`/`commit`/`focus`) | Clicks the element to focus, then types `text`. `clear:true` selects-all+deletes first; `commit:true` presses Return after, firing end-editing (inline-rename fields). **`focus:false`** skips the focus-click — required for fields the app already focused (search fields, opened rename fields), where a click would drop focus. |
| `keyPress` | **yes** | `keys` | Sends a key chord, e.g. `"cmd+f"`, `"cmd+,"` (see §5). |
| `setValue` | **yes** (AX element) | `text` | Sets the element's AX value directly (no keystrokes). Does **not** fire the control's action / end-editing — use `type` with `commit` where the *commit* matters. |
| `scroll` | **yes** | `deltaX`/`deltaY` | Scrolls by the given pixel deltas. |
| `drag` | **yes** (source) | `to` | Drags from the source element to `to` (a destination selector). File drag-drop (`toFiles`) is **not supported** via synthetic events — use `target.launchFiles` instead. |
| `waitFor` | **yes** | `present` | Waits until the element appears (`present: true`, default) or disappears (`present: false`). |
| `screenshot` | optional | `path`, `padding` | Captures to PNG. Three modes — see §12. Requires Screen Recording permission (same as `assertPixel`). |
| `assert` | **yes** | — (`assert` block) | Checks a property or presence (§4, assertions). |
| `assertPixel` | optional | `color` (+ point) | Asserts a single screen pixel's color (visual features AX can't see). See §13. |
| `assertRegion` | optional | `color`,`width`,`height`,`mode` | Asserts the **average** or **dominant** color over a rectangle — robust for thin glyphs where `assertPixel` is fragile. See §13. |
| `snapshot` | optional | `reference`,`maxDiff` | Captures a region; writes a reference PNG on first run, diffs against it on later runs. Visual regression. See §13. |
| `wait` | no | `seconds` | Fixed delay. **Discouraged** — prefer `waitFor`. Use only as a last resort. |

## 4a. Comprehensive testing — the `level` tier + AX **and** vision

A good plan is *comprehensive* in two independent dimensions. Author for both.

### Dimension 1 — coverage tier (`level`, required)

Every step is tagged with one of three cumulative tiers:

```
happyPath   ⊂   integrationSuite   ⊂   tryToBreakIt
(innermost)     (middle)               (full set)
```

| Tier | What it covers | The question it answers |
|---|---|---|
| `happyPath` | The expected flow works with **valid** input. The minimal "is it alive and correct" set. | "Does it do what I want it to?" |
| `integrationSuite` | Features working **together** — realistic end-to-end flows, broader functional coverage beyond the single happy path. | "Do the pieces work together?" |
| `tryToBreakIt` | **Adversarial** — bad data, boundary values, out-of-order or rapid actions. Assert the app refuses or degrades **gracefully**. | "Can we break it?" |

**Cumulative, no duplication.** A step is tagged at exactly one tier. A run *at* a
tier executes that tier **plus every tier below it** — so each test case is written
once and reused by the higher tiers:

| Run at level | Executes | Skips |
|---|---|---|
| `happyPath` | happyPath | integrationSuite, tryToBreakIt |
| `integrationSuite` | happyPath + integrationSuite | tryToBreakIt |
| `tryToBreakIt` (default) | all three | — |

This is smoke ⊂ regression ⊂ full. CI maps naturally: PRs run `happyPath`, merges
run `integrationSuite`, nightly runs `tryToBreakIt`.

**`level` is a LABEL — it does NOT invert pass/fail.** A `tryToBreakIt` step still
**passes** by asserting the app refused correctly — an error message appears, the
submit button stays disabled, the bad value is rejected. Write the assertion to
express "should reject"; the tier only says which coverage bucket the step is in.

```jsonc
// A tryToBreakIt step passes when the app correctly refuses bad input:
{ "id": "submit-empty",  "action": "click",  "level": "tryToBreakIt",
  "target": { "identifier": "submit" } },
{ "id": "assert-rejected", "action": "assert", "level": "tryToBreakIt",
  "target": { "identifier": "form-error" },
  "assert": { "property": "value", "op": "contains", "expected": "required" } }
```

The report breaks results down per tier **and** cumulatively, so you can see
"happyPath 12/12, integrationSuite 6/6, tryToBreakIt 9/9" at a glance.

### Dimension 2 — verify **structure** (AX) *and* **rendering** (vision)

Targeting and most assertions go through the accessibility tree — that confirms an
element *exists, is named X, is enabled/has value Y*. It **cannot** confirm the
element *rendered correctly*. Where appearance is the requirement, add a visual
check alongside the structural one:

- **Target via AX first** — match on the most stable handle (the accessibility
  `identifier`; on web, the element's `id`). Fall back to role+title only when no id exists.
- **Add vision where it adds signal** — for "a chart drew", "the badge is the right
  color", "the layout didn't regress", or an AX-opaque custom/canvas control, add a
  `snapshot` / `assertRegion` / `assertPixel` (§13, §20), or use a `vision` selector
  (§7) to find an AX-opaque target. AX says the button is named "Save"; only pixels
  confirm it actually painted, un-clipped, in the right place.

A comprehensive plan therefore tags every step's `level` **and**, for
appearance-critical steps, verifies both the structure and the rendering. See
`Fixtures/TestHostApp/comprehensive-reference.json` for a worked example spanning
all three tiers and both dimensions.

### Worked examples for each action

```jsonc
// Every step needs a `level` (shown here as happyPath). See §4a.
// click / press — press is more robust on small controls (checkboxes, etc.)
{ "id": "ok",     "action": "click", "level": "happyPath", "target": { "identifier": "okButton" } }
{ "id": "toggle", "action": "press", "level": "happyPath", "target": { "identifier": "flagCheckbox" } }

// menu — the ONLY way to drive a command with no key equivalent
{ "id": "rainbow", "action": "menu", "level": "happyPath", "args": { "menuPath": ["View", "Rainbow Brackets"] } }

// type — plain, then the variants
{ "id": "t1", "action": "type", "level": "happyPath", "target": { "identifier": "editorTextView" },
  "args": { "text": "hello\nworld" } }
// into a field the app already focused (search/rename): skip the focus-click.
// type sends virtual-key events, so it works on NSSearchField (whose editing
// happens in a child field editor) — no need for keyPress-per-character.
{ "id": "t2", "action": "type", "level": "happyPath", "target": { "identifier": "searchField" },
  "args": { "text": "query", "focus": false } }
// replace a field's contents and commit (inline rename): clear, type, press Return
{ "id": "t3", "action": "type", "level": "happyPath", "target": { "identifier": "renameField" },
  "args": { "text": "newname.txt", "clear": true, "commit": true } }

// keyPress — chords incl. punctuation
{ "id": "find",  "action": "keyPress", "level": "happyPath", "target": { "identifier": "editorTextView" },
  "args": { "keys": "cmd+f" } }
{ "id": "prefs", "action": "keyPress", "level": "happyPath", "target": { "identifier": "editorTextView" },
  "args": { "keys": "cmd+," } }

// drag — element to element (file drag-drop is NOT supported; see below)
{ "id": "move", "action": "drag", "level": "happyPath", "target": { "identifier": "fileRow" },
  "args": { "to": { "identifier": "folderRow" } } }

// scroll
{ "id": "down", "action": "scroll", "level": "happyPath", "target": { "identifier": "editorTextView" },
  "args": { "deltaY": -300 } }

// setValue — sets the AX value directly, but fires NO action/end-editing.
// Use it for fast field population; use `type` with "commit" when the commit matters.
{ "id": "fill", "action": "setValue", "level": "happyPath", "target": { "identifier": "nameField" },
  "args": { "text": "draft" } }

// assert: a property, presence, or a menu checkmark
{ "id": "count",   "action": "assert", "level": "happyPath", "target": { "identifier": "countLabel" },
  "assert": { "property": "value", "op": "contains", "expected": "count: 1" } }
{ "id": "checked", "action": "assert", "level": "happyPath", "target": { "identifier": "wrapMenuItem" },
  "assert": { "property": "marked", "op": "equals", "expected": "true" } }
{ "id": "barGone", "action": "assert", "level": "happyPath", "target": { "identifier": "findField" },
  "assert": { "property": "value", "op": "notExists" } }

// waitFor (appear / disappear) and screenshot
{ "id": "appear", "action": "waitFor", "level": "happyPath", "target": { "identifier": "sheet" },
  "args": { "present": true } }

// screenshot — three modes
// Full display (no target):
{ "id": "snap",   "action": "screenshot", "level": "happyPath", "args": { "path": "/tmp/state.png" } }
// Element-scoped (crops to the sheet + 16pt padding on all sides):
{ "id": "sheet-shot", "action": "screenshot", "level": "happyPath",
  "target": { "identifier": "saveSheet" }, "args": { "padding": 16 } }
// Absolute region:
{ "id": "toolbar-shot", "action": "screenshot", "level": "happyPath",
  "args": { "atX": 0, "atY": 0, "width": 800, "height": 50 } }

// captureTarget — attach an element crop to ANY step, pass or fail, without a
// dedicated screenshot step. 8pt default padding.
{ "id": "check-label", "action": "assert", "level": "happyPath", "target": { "identifier": "statusLabel" },
  "assert": { "property": "value", "op": "equals", "expected": "Ready" },
  "captureTarget": true }
```

> **`marked` caveat:** menu checkmark state (`AXMenuItemMarkChar`) is not
> populated until the menu has been opened/validated by AppKit. A cold read
> returns `false`. Open the menu first (a `menu` step), or prefer asserting the
> toggle's **side effect** instead of its checkmark.

`args` fields (only the relevant ones are read per action):

| Field | Type | Used by |
|---|---|---|
| `text` | string | `type`, `setValue` |
| `clear` | bool | `type` (select-all + delete before typing) |
| `commit` | bool | `type` (press Return after, to fire end-editing) |
| `focus` | bool | `type` (default true; false = don't focus-click, for already-focused fields) |
| `keys` | string | `keyPress` (e.g. `"shift+cmd+a"`) |
| `menuPath` | [string] | `menu` (e.g. `["View","Toggle Flag"]`) |
| `to` | selector | `drag` (destination element) |
| `deltaX`, `deltaY` | int | `scroll` |
| `seconds` | number | `wait` |
| `path` | string | `screenshot` (output PNG path) |
| `present` | bool | `waitFor` (true = appears, false = disappears) |
| `color` | string | `assertPixel` (expected `#RRGGBB`) |
| `tolerance` | number | RGB distance (`assertPixel` default 16, `assertRegion` default 24) |
| `offsetX`, `offsetY` | int | `assertPixel` (sample point = target center + offset) |
| `atX`, `atY` | int | `assertPixel`: absolute sample point when no target. `screenshot`: origin of the absolute-region crop (requires `width` + `height`; all four must be present) |
| `width`, `height` | int | `assertRegion`, `snapshot`: region size. `screenshot` (absolute-region mode): region size — all four of `atX/atY/width/height` are required; any missing field silently falls back to full display |
| `path` | string | `screenshot` output path. Optional — defaults to `<step-id>.png` inside the plan's artifacts directory |
| `padding` | number | Points of margin added around the element frame on all sides. Default **0** for the `screenshot` action, **8** for `captureTarget`. Shared field; per-action defaults differ |

### Assertions

An `assert` step carries an `assert` block instead of (or alongside) plain args:

```json
{ "id": "check", "action": "assert", "level": "happyPath",
  "target": { "identifier": "countLabel" },
  "assert": { "property": "value", "op": "contains", "expected": "count: 1" } }
```

**Properties** (`assert.property`): `value`, `title`, `enabled`, `focused`,
`position`, `size`, `marked` (menu-item checkmark — `"true"`/`"false"` from
`AXMenuItemMarkChar`), and `count` (the **number of elements** matching the
selector — for collections; use with `equals`/`greaterThan`/`lessThan`, e.g.
`{ "property": "count", "op": "greaterThan", "expected": "1" }`). Presence is
checked with the `exists`/`notExists` **ops** (any property), not an `exists`
property.

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

Supported keys:
- Letters `a`–`z`, digits `0`–`9`.
- Punctuation: `,` `.` `/` `;` `'` `[` `]` `\` `` ` `` `-` `=` (and named aliases
  `comma`, `period`, `slash`, `semicolon`, `quote`, `leftbracket`,
  `rightbracket`, `backslash`, `grave`, `minus`, `equal`).
- Named keys: `return`/`enter`, `tab`, `space`, `delete`, `forwarddelete`,
  `escape`, `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`,
  `f1`–`f12`.

Examples: `"cmd+s"`, `"shift+cmd+a"`, `"cmd+f"`, `"cmd+,"` (Preferences),
`"escape"`, `"cmd+pagedown"`.

An unsupported key throws a distinct `unsupportedKey` error (not confused with a
malformed-JSON parse error). The `+` key is spelled **`plus`** (it is the chord
separator), e.g. `"cmd+plus"` for zoom-in.

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
| `index` | ✅ works | When the predicates match multiple elements, pick the nth (0-based) instead of erroring. A disambiguator of last resort — prefer an `identifier`. |
| `within` | ✅ works | Scope the search to inside a separately-resolved parent, e.g. `{"role":"AXButton","within":{"role":"AXRow","index":0}}`. |
| `label` | ❌ **rejected** | A `label` selector is a hard parse error (it never matched anything). Use `title` or `identifier`. |
| `path` | ❌ **rejected** | A `path` selector is a hard parse error (never consulted). Use `identifier`/`role`/`title`/`value` + `index`/`within`. |

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
   { "id": "quit", "action": "terminate", "level": "happyPath" }
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

**On failure**, AutoPilot writes a screenshot and an AX-tree snapshot into the
artifacts dir next to `report.json`, plus `expected`/`actual` on the failing
step — that's your debugging surface.

---

## 11. Worked end-to-end example

This is a **real, verified** plan (run against the `medit` editor). It launches
medit clean, waits for the window, types a line, asserts the editor contains that
text, and quits.

```json
{
  "schemaVersion": "1.1",
  "name": "medit: type into editor",
  "target": { "bundleId": "com.jschwefel.medit", "launchArgs": ["--reset-state"] },
  "defaults": { "timeoutMs": 6000, "retryIntervalMs": 100 },
  "steps": [
    { "id": "wait-window", "action": "waitFor", "level": "happyPath",
      "level": "happyPath",
      "target": { "role": "AXWindow" }, "args": { "present": true } },

    { "id": "type", "action": "type", "level": "happyPath",
      "level": "happyPath",
      "target": { "identifier": "editorTextView" },
      "args": { "text": "hello world" } },

    { "id": "assert-value", "action": "assert", "level": "happyPath",
      "level": "happyPath",
      "target": { "identifier": "editorTextView" },
      "assert": { "property": "value", "op": "contains", "expected": "hello world" } },

    { "id": "quit", "action": "terminate", "level": "happyPath" }
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
  "schemaVersion": "1.1",
  "name": "launch clean",
  "target": { "bundleId": "com.example.app", "launchArgs": ["--reset-state"] },
  "defaults": { "timeoutMs": 6000, "retryIntervalMs": 100 },
  "steps": [
    { "id": "wait-window", "action": "waitFor", "level": "happyPath", "target": { "role": "AXWindow" }, "args": { "present": true } }
  ]
}
```

`my-test.json`:
```json
{
  "schemaVersion": "1.1",
  "name": "my test",
  "include": ["setups/launch.json"],
  "target": { "bundleId": "com.example.app", "launchArgs": ["--reset-state"] },
  "defaults": { "timeoutMs": 6000, "retryIntervalMs": 100 },
  "steps": [
    { "id": "do-thing", "action": "click", "level": "happyPath", "target": { "identifier": "thingButton" } },
    { "id": "quit", "action": "terminate", "level": "happyPath" }
  ]
}
```

Includes are resolved relative to the plan file, are cycle-detected, and are
depth-limited. The host plan's `target`/`defaults` win.

---

## 12. More capabilities

The sections below cover the rest of the toolset — read these before authoring
anything beyond a basic click/type/assert plan:

- **§12a — Screenshot reference** (element-scoped, region, captureTarget).
- **§13 / §20 — Visual assertions** (`assertPixel`, `assertRegion`, `snapshot`)
  for colors and regions the Accessibility API can't see.
- **§14 — Output & reports** (stdout, `report.json`, artifacts, exit codes,
  outcome vocabulary).
- **§15 — AppKit → AX role cheat sheet** · **§16 — What is NOT observable**.
- **§17 — Troubleshooting** (symptom → cause → fix).
- **§19 — Running a suite** (a whole directory of plans).
- **§21 — CLI commands** (`dump-axtree`, `find`, `suggest`, `lint`).

The pre-flight checklist is at the very end (§22).

---

## 12a. Screenshot quick reference

> **Screen Recording permission required** — same permission as `assertPixel`.
> Without it, `screenshot` steps succeed but write nothing, and `captureTarget`
> silently skips. Run `autopilot doctor` to check.

### Three modes for the `screenshot` action

| Mode | How to trigger | What gets captured |
|---|---|---|
| **Full display** | No `target`, no `atX/atY` | Entire main display |
| **Element-scoped** | Set `target` selector | That element's AX frame ± `padding` pts (default 0) |
| **Absolute region** | Set `atX`, `atY`, `width`, `height` (all four required) | That rectangle in screen points |

**Precedence:** if both `target` and `atX/atY/width/height` are present, the
`target` path takes priority and the absolute-region fields are ignored.

**Unresolved target fallback:** if `target` is set but the element cannot be
resolved (timeout, ambiguous, app hung), the step does **not** fail — it falls
back to a full-display capture and sets `result.message` to
`"target did not resolve; fell back to full display"`. If the element *resolves*
but capture fails (element off-screen, window not yet rendered, Screen Recording
absent), the message will be `"element crop failed (<reason>); fell back to full
display"`. The step still returns `.pass` if capture succeeds. Check `message`
in `report.json` if you need to detect either case.

**Vision targets:** element-scoped capture only works for AX-resolved targets
(selector resolves to a real `AXUIElement`). If your selector uses a `vision`
block and the element is found only via image template matching (returning a
screen point, not an AX element), the screenshot falls back to full display.

**Multi-display:** capture handles negative-origin coordinates (e.g. a window on
a secondary display to the left of the primary) correctly. `atX/atY` absolute
regions also work across displays.

**Thin-element sharp edge:** element-scoped crops use the element's AX frame as
the capture region. For thin elements (1-line status labels, scroll indicators),
the frame is the element itself — padding expands it into surrounding content
rather than adding context around a "solid" region. For thin labels, capture the
parent container window and crop geometrically, or use the `atX/atY/width/height`
absolute-region mode with a region you measured from `dump-axtree`.

**`path`** is optional — defaults to `<step-id>.png` inside the plan's
artifacts directory. Omitting it is usually the right call.

```jsonc
// Full display
{ "id": "state", "action": "screenshot", "level": "happyPath" }

// Element-scoped — the Save sheet + 16 pt breathing room
{ "id": "save-sheet", "action": "screenshot", "level": "happyPath",
  "target": { "identifier": "saveSheet" }, "args": { "padding": 16 } }

// Absolute region (toolbar strip)
{ "id": "toolbar", "action": "screenshot", "level": "happyPath",
  "args": { "atX": 0, "atY": 0, "width": 800, "height": 44 } }

// Custom output path
{ "id": "before", "action": "screenshot", "level": "happyPath", "args": { "path": "/tmp/before.png" } }
```

### `captureTarget` — visual log without extra steps

Add `"captureTarget": true` to **any step that has a `target`**. AutoPilot
saves a cropped screenshot of that element as `<step-id>-target.png` in the
artifacts dir on **every run** — pass or fail.

```jsonc
{ "id": "check-label", "action": "assert", "level": "happyPath",
  "target": { "identifier": "statusLabel" },
  "assert": { "property": "value", "op": "equals", "expected": "Ready" },
  "captureTarget": true }
```

**Defaults and rules:**
- `args.padding` controls the margin added around the element (default **8** for
  `captureTarget`, **0** for the `screenshot` action).
- Only AX-resolved targets produce a crop. Vision-only matches are skipped silently.
- Requires Screen Recording permission; if missing, the crop is silently skipped
  and the step otherwise runs normally.
- `report.json`'s `screenshot` field points to the full-display failure shot
  (written on error/fail). The `<id>-target.png` is always written to disk but
  is not surfaced in that field unless no failure shot exists.
- PlanLinter warns if `captureTarget: true` is set on a step with no `target`.

### PNG metadata

Every AutoPilot screenshot embeds `tEXt` metadata chunks — useful when the PNG
lands in an artifacts folder without `report.json`:

| Key | Value |
|---|---|
| `autopilot-step` | Step ID |
| `autopilot-plan` | Plan name |
| `autopilot-action` | Action name (e.g. `screenshot`, `assert`) |
| `autopilot-result` | `pass` or `fail` |

---

## 13. Pixel-color assertion (`assertPixel`) — testing visual features

Some of the most important things in an app are **invisible to the Accessibility
API**: syntax-highlight colors, rainbow-bracket depth coloring, theme appearance,
the line-number gutter. These are drawn pixels, not AX elements. `assertPixel`
lets you verify them by sampling a screen pixel's color.

> **Permission:** the visual actions (`assertPixel`/`assertRegion`/`snapshot`/
> `screenshot`/`captureTarget`) require **Screen Recording** permission (separate
> from Accessibility). Without it, assert steps return a clear `.error`; for
> `screenshot` and `captureTarget`, capture silently produces nothing (the step
> still passes). Run `autopilot doctor` to check. Capture uses ScreenCaptureKit
> at point resolution.

```jsonc
// Sample at a target element's center, offset by (dx, dy):
{ "id": "bracket-is-gold", "action": "assertPixel", "level": "happyPath",
  "target": { "identifier": "editorTextView" },
  "args": { "offsetX": 14, "offsetY": -3, "color": "#E5B567", "tolerance": 24 } }

// Or sample an absolute screen point:
{ "id": "gutter-visible", "action": "assertPixel", "level": "happyPath",
  "args": { "atX": 30, "atY": 200, "color": "#2B2B2B", "tolerance": 16 } }
```

- `color` is the expected `#RRGGBB`. The match is a deterministic Euclidean RGB
  distance ≤ `tolerance` (`assertPixel` default 16; `assertRegion` default 24) — **no LLM**.
- The sample point is `target` center + `(offsetX, offsetY)`, or absolute
  `(atX, atY)` when no `target` is given.
- It **polls**, so a color that settles a frame after the action still passes.
- Use a **generous tolerance** (20–30): anti-aliasing, sub-pixel rendering, and
  theme/display differences mean the exact pixel is rarely the exact hex. Pick a
  sample point in the *solid interior* of the colored glyph/region, not its edge.

> **Color space:** captured pixels are **normalized to sRGB**, so you can use
> your app's source **sRGB** `#RRGGBB` values directly — they match within a
> tight tolerance even on a wide-gamut (Display P3) screen. (If your app draws in
> a non-sRGB space, or the color is theme/transparency-dependent, still prefer
> reading the `actual` hex from a first run and asserting that.)

**Limits:** exact hues are display- and theme-dependent; assert representative
points with tolerance, not pixel-perfect equality. **Sampling a thin,
anti-aliased glyph (e.g. one colored bracket character) is fragile** — the colored
pixels are a few px wide, surrounded by blended edge pixels, so a single-point
sample easily lands on the wrong color. `assertPixel` is reliable for **solid
fills** (a selected row, a colored bar, a filled swatch) but not for hunting a
specific glyph's color. For per-glyph color verification (syntax highlighting,
rainbow brackets), prefer snapshot-testing in the app's own test suite; treat
those as a manual/visual check otherwise. (Real-world note: a medit
rainbow-bracket color test was attempted and deliberately *not* shipped for this
reason.)

---

## 14. Output & reports — what you get back

Three surfaces:

**1. Human summary (stdout, default).** Header + one line per step; a failing step
shows `expected`/`actual` inline.
```
Plan: medit: type into editor  =>  PASS  (283ms)
  [pass] wait-window (52ms)
  [pass] type (113ms)
  [pass] assert-value (89ms)
  [pass] quit (29ms)
```

**2. Machine summary line (stderr, always).** For shell loops:
```
RESULT pass 4/4
RESULT fail 3/4 (failed: assert-value)
```

**3. `report.json` (written to a per-plan subdirectory of `--artifacts`).**
```jsonc
{
  "plan": "…", "result": "fail", "durationMs": 434,
  "artifactsDir": "/…/artifacts/my-plan",
  "permissions": { "accessibility": true, "screenRecording": true },
  "steps": [
    { "id": "type", "result": "pass", "durationMs": 108 },
    { "id": "assert-value", "result": "fail",
      "expected": "hello", "actual": "",
      "screenshot": "/…/assert-value.png",
      "axDump": "/…/assert-value.axtree.json" }
  ]
}
```
`--json` prints this to stdout instead of the human summary.

**Per-plan namespacing:** each plan's report and artifacts go in a slugified
subdirectory (`<artifacts>/<plan-name-slug>/`), so running many plans into one
`--artifacts` root never clobbers. AX dumps carry a `truncated` flag so a capped
tree is never mistaken for a complete one.

**Failure artifacts** (written on failure): `<step>.png` (full-display screenshot)
and `<step>.axtree.json` (the AX tree autopilot saw). These are your debugging
surface — read `actual`, the screenshot, and the tree to fix the plan or the app.
When the failing step had a `target` that could still be resolved, an additional
`<step>-target.png` crops to just that element.

**Pass artifacts** (`captureTarget: true` only): `<step>-target.png` — a cropped
screenshot of the target element saved even on a passing step, for visual logging.

**Exit codes:** `0` pass · `1` test failure/error · `2` plan/parse error ·
`3` Accessibility permission missing.

### Outcome vocabulary

- **`pass`** — the step did what the plan said.
- **`fail`** — the app didn't behave as asserted: an assertion mismatch, or a
  targeted element that never resolved (not found / ambiguous / timed out). *Your
  app or your selector is wrong.*
- **`error`** — an infrastructure problem: launch failed, an AX action failed, an
  unsupported key. *The harness couldn't run the step.*
- **`skipped`** — not executed (e.g. after an earlier stop without `--keep-going`).

`--keep-going` continues past a failing step instead of stopping at the first one;
the overall result is still the worst step outcome.

---

## 15. AppKit → AX role cheat sheet

What an AppKit control shows up as in the AX tree (use the right `role`):

| AppKit class | AX role |
|---|---|
| `NSTextField` | `AXTextField` (label fields → `AXStaticText`) |
| `NSTextView` | `AXTextArea` |
| `NSButton` | `AXButton` (checkboxes → `AXCheckBox`) |
| `NSPopUpButton` | `AXPopUpButton` / `AXMenuButton` |
| `NSOutlineView` | `AXOutline` |
| `NSTableView` rows / cells | `AXRow` / `AXCell` |
| `NSMenuItem` | `AXMenuItem` |
| `NSRulerView` (line-number gutter) | **not a discrete AX element** |
| custom-drawn views | often nothing — use `assertPixel` / `vision` |

Discover the truth for *your* app with `dump_axtree` (§8); don't guess.

---

## 16. What is NOT observable via AX (don't try to assert these)

These have no AX representation — asserting them wastes time. Use the noted
alternative:

- **Syntax-highlight / rainbow-bracket colors, caret emphasis** — layout-manager
  temporary attributes. → `assertPixel`, or snapshot-test in the app.
- **Line-number gutter, ruler views** — not AX elements. → `assertPixel`, or a
  headless test of the toggle's state.
- **Menu checkmark *visual*** — but `AXMenuItemMarkChar` *is* readable via the
  `marked` assert property. Prefer asserting the **side effect** of a toggle.
- **Theme/appearance, fonts, invisibles rendering, window chrome** — pure
  drawing. → `assertPixel` for representative points, or manual/snapshot checks.
- **A "hidden" pane that stays in the tree** (e.g. a collapsed sidebar) — assert
  its `size`/`position` (zero width) rather than `notExists`, since the element
  may persist after being hidden.

---

## 17. Troubleshooting (symptom → cause → fix)

| Symptom | Likely cause | Fix |
|---|---|---|
| `assert … actual=` (empty) | the value was read before it propagated | already mitigated — asserts poll; raise `timeoutMs` if needed |
| `Selector matched N elements (expected 1)` | ambiguous selector | add an `identifier`, or a more specific role/title; the error lists the matches |
| `No element matched selector` | wrong selector, or element not yet present | check with `dump_axtree`; ensure a `waitFor` precedes it |
| `Unsupported key in chord: X` | key not in the map | use a supported key (§5); punctuation is supported now |
| exit `3` / `Accessibility: MISSING` | no AX permission | run `autopilot doctor`; grant Accessibility to the runner |
| `Included plan not found … (resolved to /abs/path)` | include path is relative to the **plan file**, not CWD | fix the relative path (the error shows the resolved candidate) |
| a menu item "click" passes but nothing happens | `click` can't open a closed menu | use the `menu` action instead |
| `setValue` then Return doesn't commit | `setValue` fires no action | use `type` with `"commit": true` |
| keystrokes dropped on the first step | (mitigated) app not yet key | the runner now activates + waits; ensure a `waitFor` window step first |
| `type` into a search/rename field types nothing | type's focus-click dropped the app's existing first-responder | use `"focus": false` (the app already focused it). `type` sends virtual-key events, so search fields (`NSSearchField`) work too |
| non-ANSI characters (accents, emoji) don't type | only ANSI keys have virtual keycodes | those fall back to unicode-string synthesis automatically; if a field editor rejects them, that's a known limit |
| `assert value` on a checkbox reads empty | (fixed) numeric AXValue | now returns `"0"`/`"1"`; ensure you're on a current build |
| `assert marked` reads `false` on a fresh menu | menu state isn't populated until the menu is opened/validated | open the menu (or prefer asserting the toggle's side effect) |
| coordinate `click` on a small control does nothing | the click missed the hit-area | use `press` (AX press) — robust for checkboxes, buttons, menu items |

---

## 18. Sidebar/pane "hide" and other persistence gotchas

When a view is *hidden* rather than *removed*, it often stays in the AX tree, so
`assert notExists` won't fire. Assert its geometry instead:

```jsonc
{ "id": "sidebar-collapsed", "action": "assert", "level": "happyPath",
  "target": { "identifier": "sidebarOutline" },
  "assert": { "property": "size", "op": "equals", "expected": "0,0" } }
```

Similarly, document-based apps re-open the last document via state restoration /
autosave even with an app-side `--reset-state` that only wipes defaults. For a
clean baseline, the app's test flag should *also* disable
`NSQuitAlwaysKeepsWindows`, clear saved window state, and delete autosaved
documents — wiping `UserDefaults` alone is not enough.

---

## 19. Running a suite (a directory of plans)

Point `run` at a **directory** to execute every `*.json` plan under it
(recursively), one at a time, with one aggregate result:

```bash
autopilot run uitests/ --artifacts ./out
```

- Plans run **sequentially** — macOS has a single keyboard/mouse focus, so
  input-driving plans cannot truly run in parallel without fighting over it.
- Files under a `setups/` directory are treated as **include-only fragments**
  and are not run as standalone plans.
- Each plan's report + artifacts go in its own `out/<plan-slug>/` subdirectory;
  an aggregate `out/suite.json` is written, and a `SUITE pass N/M` line goes to
  stderr. Exit code is `0` only if every plan passed.

## 20. Visual assertions in depth (`assertPixel`, `assertRegion`, `snapshot`)

Three tools, increasing robustness:

```jsonc
// Single pixel — fine for solid fills, fragile on thin glyphs.
{ "id": "px", "action": "assertPixel", "level": "happyPath",
  "target": { "identifier": "swatch" },
  "args": { "color": "#3478F6", "tolerance": 16 } }

// Region average/dominant — robust for glyphs (anti-aliased edges).
// "dominant" quantizes colors so a few edge pixels don't skew the result.
{ "id": "bracket-gold", "action": "assertRegion", "level": "happyPath",
  "target": { "identifier": "editorTextView" },
  "args": { "offsetX": 14, "offsetY": -3, "width": 10, "height": 14,
            "mode": "dominant", "color": "#E5B567", "tolerance": 28 } }

// Snapshot regression — first run writes the reference, later runs diff it.
{ "id": "toolbar", "action": "snapshot", "level": "happyPath",
  "target": { "identifier": "toolbar" },
  "args": { "reference": "ref/toolbar.png", "width": 240, "height": 36,
            "maxDiff": 0.02 } }
```

- `assertRegion` `mode`: `average` (default) or `dominant`. Use `dominant` for
  thin colored glyphs; use a generous `tolerance` (24–30).
- `snapshot` `reference` resolves relative to the plan file. **Commit the
  reference PNG** so later runs compare against it; `maxDiff` is the allowed
  fraction of differing pixels (default `0.02`).
- **A missing reference is a FAILURE, not a silent pass.** To create or refresh
  a baseline, run with `autopilot run … --update-snapshots` (writes/overwrites
  the reference and passes). This is the standard snapshot-testing convention —
  it stops a bad or absent baseline from quietly "passing" on first run.
- All three **poll**, so a color/region that settles a frame late still passes.
- Limits unchanged: exact hues are display/theme-dependent — assert with
  tolerance, and prefer the app's own snapshot tests for dense pixel-perfect
  checks.

## 21. CLI commands (authoring & debugging aids)

Beyond `run`:

```bash
autopilot doctor                       # check Accessibility permission (exit 3 if missing)
autopilot dump-axtree <app> [--pid N] [--interactive-only]   # print the AX tree to discover selectors
autopilot find <app> --identifier foo  # show what a selector resolves to (and how many)
autopilot suggest <app>                # suggest the best selector for each interactive element
autopilot lint <plan|dir>              # flag non-functional label/path, missing terminate/window-wait
```

> **Inspect vs. run — important.** `run` **launches a fresh instance** (a test
> wants a clean app). The inspection commands (`dump-axtree`, `find`, `suggest`)
> do the opposite: they **attach to the already-running instance** and never
> launch or terminate it — so they show you the app exactly as it is on screen.
> If nothing matching is running, they say so (they do **not** return a blank
> tree). `<app>` is a bundle id or `.app` path → the **frontmost** running
> instance; pass `--pid N` to inspect a specific process unambiguously. The dump
> includes the `pid` and `appName` so you can confirm you inspected the right one.

All inspection commands need the Accessibility permission (`doctor` checks it).

> **MCP:** the `dump_axtree` tool attaches the same way — `{"bundleId":…}`,
> `{"path":…}`, or `{"pid":N}` — and errors with "No running instance …" rather
> than returning fabricated data.

> **Editor schema:** point your editor at `schema/plan.schema.json` for plan
> autocomplete and validation (see `docs/CI.md`).

---

## 22. Pre-flight checklist

Before running a plan:

- [ ] `schemaVersion` is `"1.1"`.
- [ ] `target` sets exactly one of `bundleId` / `path` (path → a real `.app`).
- [ ] Every step `id` is unique and descriptive.
- [ ] Selectors use **`identifier`/`role`/`title`/`value`** (not `label`/`path`,
      which are non-functional). Use `index`/`within` only to disambiguate.
- [ ] First step waits for `{ "role": "AXWindow" }`; the app is then activated
      automatically before input.
- [ ] Required args present per action:
      `type`/`setValue` → `text`; `keyPress` → `keys`; `menu` → `menuPath`;
      `drag` → `to`; `assert` → an `assert` block; `assertPixel`/`assertRegion`
      → `color` + a target or `atX`/`atY`; `snapshot` → `reference`.
- [ ] Typing into an already-focused field uses `"focus": false`.
- [ ] Last step is `terminate` (so the app isn't left running).
- [ ] For `snapshot` plans: the reference PNG is committed, or you ran once with
      `--update-snapshots` to create it.
- [ ] `autopilot lint <plan>` is clean, and `autopilot doctor` says
      Accessibility: OK.

You can let the tool check most of this for you: **`autopilot lint <plan|dir>`**.
