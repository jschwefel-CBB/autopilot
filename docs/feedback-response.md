# Response to the medit Field Report

**Source report:** `medit` repo, `docs/autopilot-feedback.md` — a real-consumer
report from authoring and running an 18-plan GUI suite against AutoPilot at commit
`3d7b5cb`.

**Status of this document:** triage / disposition. Rounds 1–3 are **implemented**;
**Round 4 (at the very bottom) is triaged but NOT yet implemented** — it contains
an open **P0** (`dump_axtree` reports a phantom window). Every accepted item from
rounds 1–3 has been built (see git history and
`AUTHORING.md`): both P0s (poll asserts, activate app), press/menu actions,
full key map, ambiguous-match listing, unsupported-key error, summary line,
`dump_axtree` filter, plus the new capabilities from the coverage report
(menu-mark read, type commit/clear, drag, pixel-color assertion). Every claim
was re-verified against source before being accepted; the report was accurate
on every point checked.

**Verification note:** all file:line references in the report were confirmed
against the current source. Notably, P0 #1 independently rediscovers the exact
flakiness this project hit while writing the AUTHORING.md example (a property
assert reading `Col 12` on one run and `Ln 2, Col 1` on another) — same root
cause. The report is trusted.

---

## Disposition summary

| # | Item | Severity | Verified | Decision |
|---|---|---|---|---|
| 1 | Property asserts are one-shot; only presence polls | P0 | ✅ true (`PlanRunner.swift:119-126`) | **FIX — accept** |
| 5 | No app activation / key-window wait before input | P0 | ✅ true (no `activate()` anywhere) | **FIX — accept** |
| 2 | `click` can't drive menus; no `AXPress`/menu action | P0 | ✅ true (`ActionEngine.swift:56-64`) | **FIX — accept (new action)** |
| 3 | Key map missing punctuation (`Cmd-,` etc.) | P1 | ✅ true (`ActionEngine.swift:11-20`) | **FIX — accept** |
| 4 / inc | `include` base-dir under-documented | P1 | ✅ true (`main.swift:31`) | **DOC — accept** |
| sel | Ambiguous-match error should list matches | P1 | ✅ true (`TargetingError.swift:11`) | **FIX — accept** |
| akx | Document AppKit→AX roles & non-observables | P1 | ✅ true (behavioral) | **DOC — accept** |
| sv | `setValue` fires no action — document sharp edge | P2 | ✅ true (`ActionEngine.swift:71`) | **DOC now; `confirm` option later** |
| tf | `type` re-click can break focus — document/`focus:false` | P2 | ✅ true (`ActionEngine.swift:67`) | **DOC now; arg later** |
| race | `terminate`→relaunch races; want `--settle-ms` | P2 | plausible | **CONSIDER** |
| `+` | Chord split can't express the `+` key | P2 | ✅ true (`ActionEngine.swift:23`) | **DEFER (note in docs)** |
| err | Chord parse errors are exit-2 `decode` errors | NICE | ✅ true (`:39`) | **FIX — cheap, accept** |
| sum | One-line machine summary on stdout | NICE | n/a | **ACCEPT (cheap win)** |
| dax | `dump_axtree` raw/pretty mode + filters | P1/NICE | ✅ true (`MCPServer.swift:93`) | **ACCEPT raw mode; filters later** |
| inc2 | Include-not-found should show resolved path | NICE | ✅ true | **FIX — cheap, accept** |

---

## What we will fix (prioritized)

### Tier 1 — the two P0 reliability fixes (do first, together)

These are the report's headline: fixing only these takes suite reliability from
~85% to ~100% with zero plan changes. Both are low-risk and well-scoped.

1. **Poll the property comparison, not just element presence.**
   `runAssert` (`PlanRunner.swift:119-126`) must wrap `readProperty` + `evaluate`
   in the same `intervalMs`/`timeoutMs` poll loop already used for presence —
   succeed the instant it matches, fail only at timeout, and capture the failure
   artifact bundle only *after* the loop expires (keep the bundle; it's praised).
   This is the single highest-ROI change in the report and removes every manual
   `wait` settle.

2. **Activate the app and wait for key-window before the first input step.**
   After launch (`AppLauncher.swift`), `activate()` the `NSRunningApplication`
   and poll until `isActive` / the target window is key, before `PlanRunner`
   runs input steps. Kills the dropped-keystroke race (~15% of back-to-back runs).

### Tier 2 — capability gaps

3. **A press/menu action.** Add a first-class action performing `kAXPressAction`
   on the resolved element (works for buttons *and* menu items), and/or a `menu`
   action that walks `Menu Bar → submenu → item`. Optionally make `click` prefer
   `AXPress` when supported. Without this, menu commands lacking a key equivalent
   are undrivable.

4. **Extend the key map to the full ANSI keyboard** — punctuation first
   (`, . / ; ' [ ] \ \` - =`), plus `home/end/pageup/pagedown/forwarddelete` and
   `f1–f12`. `Cmd-,` (Preferences) is the most common macOS shortcut and is
   currently unsendable.

5. **List the matches on an ambiguous selector.** `TargetingError.ambiguous`
   should include each match's role, frame, and a value snippet — not just the
   count — so authors can disambiguate from the error alone. (A `nth`/`within`
   disambiguator is a possible follow-up, not committed here.)

### Tier 3 — cheap wins

6. **Distinct error/exit for unsupported keys.** `unknown key` currently surfaces
   as a `PlanError.decode` → exit 2, identical to malformed JSON. Give it its own
   error type (and consider a distinct exit) for triage.
7. **One-line machine-readable summary** on stdout (`PASS 17/18 (1 failed: …)`)
   so shell loops don't parse for `=> PASS`.
8. **Include-not-found prints the resolved absolute path**, making the base-dir
   rule obvious from the error.
9. **`dump_axtree` raw mode** — emit the plain tree array (not the escaped
   JSON-RPC envelope), via a CLI subcommand or a `--raw` flag. This is what sent
   the report author briefly down a wrong path. (Tree filters are a later nice.)

---

## What we will document now (no code)

These belong in `AUTHORING.md` and cost nothing but writing:

- **Include base-dir rule** (P1 #4): *"include paths resolve relative to the
  directory of the file that declares them"* + a nested-plan example showing
  `"../setups/launch.json"`.
- **AppKit→AX cheat sheet:** `NSTextView`→`AXTextArea`, `NSOutlineView`→
  `AXOutline`, `NSTableView` rows→`AXRow`/`AXCell`, `NSRulerView`→(not
  addressable), `NSButton`→`AXButton`/`AXCheckBox`, `NSPopUpButton`→
  `AXPopUpButton`/`AXMenuButton`.
- **A "what is NOT observable" box:** menu checkmarks, syntax/coloring (layout
  manager temporary attributes), ruler views — don't try to assert these; assert
  the side effect.
- **`setValue` vs `type` semantics:** `setValue` updates the AX value only and
  fires no target/action or end-editing; use `type` where *commit* matters.
- **`type` re-clicks to focus:** don't pre-click a field you're about to `type`
  into; let `type`'s own click focus it. (Until a `focus:false` arg exists.)
- **Clean-state recipe for document-based apps:** app-side `--reset-state` wiping
  defaults is not enough on macOS — window/state restoration and `NSDocument`
  autosave reopen content from outside the prefs domain. Note that a test flag
  should also disable `NSQuitAlwaysKeepsWindows`, clear saved state, and delete
  autosaved docs.
- **Escaping example:** show a plan with `\n` and one with `\t` so authors know
  normal JSON escaping works.
- Cross-reference: the existing "label/path selectors are non-functional" note
  already in `AUTHORING.md` pairs with the report's "prefer `identifier`" point.

---

## What we will defer (and why)

- **`+`-key in chords** (P2): real but rare; documenting the limitation is enough
  for now. Revisit if a real plan needs `Cmd-+`.
- **`--settle-ms` / wait-for-prior-PID-exit on relaunch** (P2): once app
  activation (#5) lands, evaluate whether the relaunch race still occurs before
  adding a flag. May be obviated.
- **`nth`/`within` selector disambiguators** (P1 idea): worthwhile, but list the
  matches first (#5 above) and see whether `identifier`-first authoring plus a
  better error closes the gap before adding selector surface area.
- **`confirm`/`AXConfirm` for `setValue`, `focus:false` for `type`** (P2 asks):
  document the sharp edges now; add the args if document-app commit-flows remain
  a recurring need.
- **`dump_axtree` tree filters** (NICE): do raw mode first; add filters if the
  tree size remains a real friction.

---

## What's confirmed good — keep, don't touch

The report's "keep it" list matches our intent and is accepted wholesale:

- The clean, learnable JSON schema.
- `identifier`-first selectors as the primary mechanism.
- Deterministic single-match resolution (throw on zero/ambiguous) — keep; just
  improve the *message* (#5), never weaken the behavior.
- The failure artifact bundle (AX dump + screenshot) — keep; gate it behind the
  retry loop once #1 lands.
- `doctor` + exit code 3 for missing Accessibility.
- Exit-code discipline (`0/1/2/3`).
- `--reset-state` as a convention.
- `include` composition.
- The polled (not-sleep) AX-tree wait at launch — extend the same philosophy to
  value asserts (#1) and activation (#5).

---

## Suggested implementation order (when we do code)

1. P0 #1 (poll asserts) + P0 #5 (activate) — one focused session, TDD against the
   TestHostApp fixture; biggest reliability return.
2. Doc-only additions to `AUTHORING.md` (no risk, immediate value to authors).
3. Cheap wins: unsupported-key error/exit, summary line, include-not-found path,
   `dump_axtree --raw`.
4. Capability gaps: press/menu action, key-map punctuation, ambiguous-match
   listing.
5. Re-evaluate the deferred items against real usage.

— end of response

---

## Round 2 (post-retest) — disposition

After the fixes above, the medit agent re-ran the full suite (18/18) and filed a
Round 2 addendum. Both code-level findings were re-verified against source and
fixed:

| Finding | Severity | Verified | Decision |
|---|---|---|---|
| `type`'s focus-click drops focus on already-focused fields (search/rename) | P0 | ✅ `ActionEngine.swift` (unconditional focus click) | **FIXED** — added `type` `focus:false` |
| Checkbox `AXValue` (NSNumber) unreadable via `value` (`string()` returns nil) | P1 | ✅ `AXTree.string` did `value as? String` | **FIXED** — `AXTree.valueString` coerces numeric values |
| `marked` reads `false` until the menu is opened/validated | P2 | plausible (AppKit validates lazily) | **DOC** — documented; prefer asserting the side effect |
| Back-to-back re-toggle of the same menu item is unreliable | P2 | plausible | **DOC/DEFER** — note the limitation; revisit if needed |
| `assertPixel` too fragile for thin anti-aliased glyphs (bracket colors) | — | confirmed (by design) | **DOC** — documented as a limitation; reliable for solid fills only |

Corroborated finding: **`press` (AX press) is more robust than a coordinate
`click`** for small controls — our own checkbox integration test had to switch
from `click` to `press` to reliably toggle the box. This matches the agent's
report and is documented in the troubleshooting table.

---

## Round 3 (post-Round-2-retest) — disposition

The medit Round-2 retest confirmed both fixes and left **one residue**, now also
fixed:

| Finding | Severity | Verified | Decision |
|---|---|---|---|
| `type focus:false` lands nothing in an `NSSearchField` | P2 | ✅ confirmed — `type` used `keyboardSetUnicodeString`, which the search field's child field editor ignores | **FIXED** — `type` now sends printable characters as virtual-key events (shared `KeyMap`), falling back to unicode-string only for non-ANSI chars. Verified: `type focus:false` into an `NSSearchField` lands text. |

Net result through Round 3: every code-level finding the medit consumer filed in
rounds 1–3 has been verified against source and fixed; the remaining round-1–3
items are documented limitations (assertPixel on thin glyphs; `marked` needs the
menu opened; file drag-drop unsupported; non-ANSI characters via fallback).
**Round 4 (below) adds a new open P0** — see its disposition.

---

## Round 4 (medit v2 retest) — disposition — **IMPLEMENTED**

> medit labels this "Round 3" in its own doc, but it is chronologically the
> *fourth* report (after the NSSearchField Round 3 above) — filed against
> AutoPilot commit `76e3261` while building medit's Markdown v2 features.
> **This is a triage/disposition only; no code has been changed yet.**

Both findings were **re-verified against AutoPilot source** and are accurate.

| # | Finding | Severity | Verified | Decision |
|---|---|---|---|---|
| R4-1 | `dump_axtree` (and `find`/`suggest`) reports a phantom window — it does not attach to the running instance | **P0** | ✅ confirmed in source | **FIXED** — inspection commands now attach (by frontmost bundleId or `--pid`/`{pid}`), never launch/terminate; clear "no running instance" error; output includes pid + appName |
| R4-2 | `run` with `path` + `launchFiles` opened the file in the OS default handler, not the target app | P1 | confirmed (launch+route race) | **FIXED** — launch the app first, then open files into that instance (targeted by bundle URL), removing the LaunchServices routing race |

### R4-1 (P0) — root cause confirmed (worse than the report inferred)

The report's hypothesis ("resolves to a fresh/launched context rather than
attaching") is exactly right, and the mechanism is concrete:

- `MCPServer.dumpAXTree` (`MCPServer.swift:87`) calls `AppLauncher().launch(target)`.
- `AppLauncher.launch` (`AppLauncher.swift:39`) **first kills any already-running
  instance** (`waitForExistingInstancesToExit`, added in Milestone A to make
  back-to-back *test* runs reliable) and then launches a **fresh** one.

So `dump_axtree` against the consumer's running medit:
1. **terminated** their instance (the one with `sb-test.md` open) — which is why
   the AppleScript window list went momentarily empty;
2. launched a **fresh** instance (`Untitled`, no toolbar);
3. reported *that* tree.

The process count stayed at 1 because kill + relaunch nets to one — exactly the
confusing symptom reported. **There is no attach-to-running path anywhere in the
codebase today**; `launch()` is the only way to obtain a pid. The kill-first
behavior is correct for `run` (a *test* wants a clean instance) but is wrong for
every *inspection* command (`dump_axtree`, `find`, `suggest`), which must observe
the app as it is.

**Planned fix (when implemented):**
1. Add an **attach** path: resolve a `bundleId` to the **frontmost running
   instance** (`NSWorkspace.runningApplications` → its pid) and snapshot *that*
   AX tree, **without launching or terminating** anything.
2. Make `dump_axtree` / `find` / `suggest` **attach by default**; only launch when
   explicitly asked (or when nothing is running — and then say so).
3. **Self-check:** if no running instance matches the bundle id, return a clear
   "no running instance" error, never a blank/default tree that looks like data.
4. Add **dump by pid** (`{"pid": 81256}`) as the unambiguous escape hatch, and
   surface `windowTitle`/`pid` to disambiguate multiple windows/instances.
5. Leave `run`'s launch-fresh semantics intact (tests want isolation), but
   document the distinction (inspect = attach, run = launch).

This is the highest-priority open item: an inspection tool that disagrees with
the running app manufactures false negatives, as the report demonstrates.

### R4-2 (P1) — launchFiles routing

`AppLauncher.launch` uses `NSWorkspace.open(fileURLs, withApplicationAt:url,…)`
(`AppLauncher.swift:61`), which is *supposed* to open the files in the app at
`url`. The report saw the `.md` open elsewhere. To investigate: confirm whether
the OpenConfiguration / file-type handler is being overridden, and whether
`CFBundleDocumentTypes` on the target matters. Deferred behind R4-1.

### Net
Until R4-1 lands, AutoPilot can drive an app it launches (the `run` path is
sound — the medit suite passes), but its **state-inspection** commands cannot be
trusted against a separately-running instance. Fixing R4-1 restores AutoPilot as
a trustworthy verifier.

---

## Screenshot field report — medit doc-capture session (SC findings)

From medit doc-capture session using `screenshot` / `captureTarget`.

| ID | Priority | Finding | Status |
|---|---|---|---|
| SC-1 | P1 | `screenshot` with `target` fails silently — `message: null`, no PNG, no reason | **FIXED** — `captureElement` now returns `String?` (nil = success, non-nil = reason); runner surfaces the reason in `message` and falls back to full display |
| SC-2 | P2 | `run` always terminates+relaunches — no way to drive an app already in a specific state | **FIXED** — added `target.attach: true`; uses `AppLauncher.attach()` to connect to the frontmost running instance without terminating it; fails clearly if no match |
| SC-3 | P3 | Element-scoped crops of thin/1-line elements capture surrounding content | **DOCUMENTED** — §12a now explains the AX-frame-is-the-region behavior and recommends the parent container or absolute-region mode for thin elements |
| SC-4 | P2 | No reliable drive-to-transient-state-then-capture flow | **Addressed by SC-1 + SC-2** — SC-1 fix means `screenshot` after `menu` no longer silently fails; SC-2 (attach mode) means the caller can arrange the app first; remaining gap (holding a menu open across a capture) is an inherent timing constraint |
| SC-5 | P1 | Screenshots fail for windows at negative X (secondary display to the left) | **FIXED** — removed main-display clamp in `captureElement`; ScreenCaptureKit already handles negative origins via `SCShareableContent.displays.first(where: displayContains)` |
