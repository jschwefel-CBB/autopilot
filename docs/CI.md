# CI & Distribution

## Continuous integration
`.github/workflows/ci.yml` builds and tests on a `macos-14` runner.

The **unit tests run headless**; the **AX-driven integration tests self-skip**
when `AXIsProcessTrusted()` is false (which it is on a stock GitHub runner), so
the suite stays green without an Accessibility grant. To actually exercise the
integration tests, you need a self-hosted runner with Accessibility granted to
the test process — stock GitHub macOS runners cannot grant TCC permissions
non-interactively.

## Releases
`scripts/release.sh <version>` produces a release build + a tarball under
`dist/`. It deliberately stops short of publishing (tagging / `gh release
create`) so nothing irreversible runs automatically — the printed next steps
show the manual publish commands and how to compute the sha256 for a Homebrew
formula.

## Plan schema
`schema/plan.schema.json` (JSON Schema draft-07) describes the plan format.
Point your editor at it for autocomplete + validation, e.g. in VS Code:

```jsonc
// .vscode/settings.json
{ "json.schemas": [
  { "fileMatch": ["**/uitests/**/*.json", "**/testplans/**/*.json"],
    "url": "./schema/plan.schema.json" } ] }
```
