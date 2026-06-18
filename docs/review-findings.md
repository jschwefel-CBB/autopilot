# Internal Review Findings

**Scope:** issues found by reading AutoPilot's own source with a critical eye —
the class of problem a *usage* report can't surface. Complements the consumer
field report (`medit:docs/autopilot-feedback.md`) and its triage
(`docs/feedback-response.md`). **No code has been changed**; this is a findings
log. Every item cites a verified file:line.

**Reviewed at commit:** `6ccbeea` (post-triage).
**UPDATE: implemented.** A1 (truncation signal), A2 (count short-circuit), A3
(per-plan artifact namespacing), A4 (error/fail semantics), A5 (vision path vs
plan dir) are all built; D1–D5 doc gaps are addressed in `AUTHORING.md`. A6
(sync-only core) remains deferred until parallel execution is a goal.

Severity: **P0** correctness/data-loss · **P1** real but bounded · **P2**
papercut/architectural.

---

## Application findings

### A1 — P0 — Silent truncation when the AX tree exceeds the node cap
**Where:** `Sources/AutopilotCore/Targeting/AXTree.swift:51` (`walk`, default
`maxNodes: 5000`), `:58` (`if count >= maxNodes { return }`), `:65` (`snapshot`,
default `maxNodes: 2000`).
**Problem:** when an app's accessibility tree exceeds the cap, the walk stops
**silently**. `AXResolver.resolveOne` / `count` therefore never see elements
past the cap → a valid target yields a spurious "not found", or a partial walk
changes a `count` result. `dump_axtree` (which uses `snapshot`, cap 2000) can
silently omit nodes — directly undercutting the deterministic-resolution
guarantee the field report praised, on any large app.
**Fix direction:** signal truncation (a `truncated` flag in the result and/or a
logged warning), and make the cap configurable per run. Never truncate silently
— the project's own principle ("no silent caps; log what was dropped").

### A2 — P1 — Full tree walked twice, 4 AX reads/node, no short-circuit
**Where:** `AXResolver.swift:29-39` (`resolveOne` walks the whole tree,
collecting all matches, **never** stopping early), `:45-55` (`count` performs an
independent identical walk). Each node does up to 4 `AXTree.string` calls.
**Problem:** cost is O(nodes × attributes) per resolution, and every polling
`assert`/`waitFor` re-walks the entire tree each `intervalMs` tick. Fine on
medit's ~270 nodes; quadratic-feeling on large apps. **This compounds with the
accepted P0 "poll the property assert" fix** — more polling means more full
walks.
**Fix direction:** short-circuit `resolveOne` after the 2nd match (ambiguity only
needs "≥2"); have `count` stop at the threshold it cares about; cache one
snapshot per poll tick and match against it instead of re-reading AX per node.

### A3 — P1 — Multi-plan runs clobber report.json and artifacts
**Where:** `Sources/AutopilotCore/Report/Reporter.swift:17`
(`directory.appendingPathComponent("report.json")` — fixed name); artifacts named
only by step id, e.g. `PlanRunner.swift:61` (`"\(step.id).png"`).
**Problem:** running several plans into one `--artifacts` dir **overwrites**
`report.json` each time, and two plans sharing a step id (e.g. both end with
`quit`) collide on `quit.png` / `quit.axtree.json`. The medit agent worked around
this with per-plan shell scripting and `pkill`/`sleep`.
**Fix direction:** namespace outputs per plan/run (subdirectory or filename
prefix), or write `report.json` per plan. Relates to the report's request for a
machine-readable multi-plan summary.

### A4 — P1 — `error` vs `fail` is conflated and undefined
**Where:** `PlanRunner.swift:58-65` — any thrown error (element not found, launch
failure, transient AX error) becomes `StepOutcome.error`; an assertion mismatch
is `.fail` (`:124-126`). `Report.finalize` treats both as non-pass.
**Problem:** the enum distinguishes `error`/`fail`/`pass`/`skipped`, but the
*meaning* isn't defined or applied consistently. A `click` on a genuinely-absent
element (a real test failure) is reported as infrastructure `error`, blurring the
signal CI and the triage rely on.
**Fix direction:** define the vocabulary — `error` = harness/infrastructure
problem (launch failed, AX unavailable), `fail` = the app didn't behave as
asserted (mismatch, expected element absent) — and route outcomes to match. Then
document it (see D2).

### A5 — P1 — Vision template path resolves against CWD, not the plan dir
**Where:** `Sources/AutopilotCore/Targeting/Targeting.swift:27`
(`VisionResolver.grayscaleBuffer(pngPath: vision.image)` — uses the literal
string).
**Problem:** `include` paths resolve relative to the **plan file**
(`PlanParser`), but `vision.image` resolves relative to **the current working
directory**. This is the *exact* inconsistency that bit the field-report author
with `include` (`"setups/launch.json"` not found). A plan that references
`templates/icon.png` works from one directory and fails from another.
**Fix direction:** thread the plan's base directory into resolution and resolve
`vision.image` relative to the plan file, matching `include`. Document the rule
alongside the include rule.

### A6 — P2 — Blocking semaphore + Thread.sleep make the core sync-only
**Where:** `Sources/AutopilotCore/Runtime/AppLauncher.swift:40,52`
(`DispatchSemaphore` + `sem.wait()`), `Sources/AutopilotCore/Runtime/Clock.swift:15`
(`Thread.sleep`).
**Problem:** acceptable for a single-shot CLI, but the core blocks the calling
thread throughout a run. It can't be driven from an async context and serializes
everything — a barrier to parallel plan execution, which the report's
`--settle-ms`/back-to-back-runs discussion gestures toward.
**Fix direction:** not urgent. If concurrency becomes a goal, move to async/await
(`NSWorkspace.openApplication` has an async form) and an async sleep; keep the
`Clock` abstraction for deterministic tests.

---

## Documentation findings

### D1 — P1 — The report.json (output) schema is undocumented
`AUTHORING.md` thoroughly documents the **plan** (input) but never the **report**
(output) — the artifact CI actually consumes. There is no documented schema for
`result`, `steps[]` (`id`/`result`/`durationMs`/`expected`/`actual`/`screenshot`/
`axDump`), `durationMs`, or the `permissions` block. Add an "Output & reports"
section: the three surfaces (stdout human summary, `report.json`, failure
artifacts), the exit codes, and a worked example of each (a real pass and a real
fail).

### D2 — P2 — The outcome vocabulary is never defined for the user
`pass` / `fail` / `error` / `skipped` appear in output but are explained nowhere.
Define them in the docs (and make the code consistent — see A4) so authors know
whether `error` means "your app misbehaved" or "the harness hit a problem".

### D3 — P2 — `--keep-going` semantics are subtle and undocumented
The flag continues past a failing step, but it changes the overall result and
which artifacts are produced. One or two sentences in the run section.

### D4 — P2 — `retryIntervalMs` vs `intervalMs` naming
The plan field is `retryIntervalMs` (`Plan.swift:17`); everything internal calls
it `intervalMs`. Harmless, but the doc should state plainly that `retryIntervalMs`
is the **poll cadence** — a meaning that becomes load-bearing once the accepted
P0 assert-polling fix lands.

### D5 — P2 — No troubleshooting / FAQ
The field report's hard-won diagnoses deserve a short "symptom → cause" table in
the docs, e.g.: empty `actual=` on a value assert → propagation race (pre-fix);
`Selector matched N elements` → use an `identifier`; exit 3 → run `autopilot
doctor`; `Included plan not found` → include paths are relative to the plan file.

---

## Cross-references

- A4 ↔ D2 (define the outcome vocabulary, then make code match).
- A5 ↔ the report's `include` base-dir item (same class of CWD-vs-file bug).
- A1/A2 ↔ the accepted P0 "poll the property assert" fix — polling multiplies the
  walk cost (A2) and the truncation exposure (A1), so address them together.
- A3 ↔ the report's "machine-readable multi-plan summary" NICE.

## Suggested handling

All of the above is **docs-or-later**; none blocks current single-plan use. A
sensible bundling when implementation happens:

1. With the P0 assert-polling work: also do A1 (truncation signal) and A2
   (short-circuit + per-tick snapshot cache), since polling makes both matter
   more.
2. A standalone "outputs & robustness" pass: A3 (per-plan artifacts), A4 (outcome
   semantics) + D1/D2 (document outputs & vocabulary).
3. A5 with any other base-dir/path work.
4. A6 only if/when parallel execution becomes a goal.

— end of internal review
