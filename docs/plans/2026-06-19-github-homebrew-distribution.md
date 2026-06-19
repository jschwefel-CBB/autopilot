# GitHub Releases + Homebrew Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship AutoPilot as a properly signed, notarized binary via GitHub Releases and a Homebrew tap so users can install it with `brew install`.

**Architecture:** A GitHub Actions release workflow builds a universal (arm64 + x86_64) or arch-specific binary, signs it with an Apple Developer certificate via Xcode's `xcodebuild`/`codesign`, notarizes it with `notarytool`, packages it as a `.tar.gz`, creates a GitHub Release with the artifact attached, and auto-updates a Homebrew tap formula (`homebrew-tap` repo) with the new URL + SHA-256. A separate Homebrew tap repository (`jschwefel-CBB/homebrew-autopilot` or similar) hosts the formula file.

**Tech Stack:** GitHub Actions (`macos-14` runner), SwiftPM release build, Apple `codesign` + `notarytool`, `gh` CLI, Homebrew formula (Ruby DSL), a separate public GitHub repo for the tap.

## Global Constraints

- macOS deployment target: **14.0** (matches `Package.swift`)
- Swift tools version: **6.0** (matches `Package.swift`)
- Binary products: `autopilot` (CLI) and `AutopilotMCP` (MCP server) — both must be signed/notarized
- Product name in prose: **AutoPilot**; binary/formula name: `autopilot`
- Must NOT use App Sandbox (Accessibility + CGEvent synthesis are incompatible with it)
- Notarization requires an Apple Developer account; credentials stored as GitHub Actions secrets
- The existing `scripts/release.sh` can be extended but is a local helper, not the CI entry point
- The Homebrew tap is a separate public GitHub repo; the formula lives there, not in this repo
- No breaking changes to the CLI interface or plan format

---

## File Map

**In this repo (`autopilot`):**
- Modify: `scripts/release.sh` — extend to build both binaries, create a universal binary if feasible, produce deterministic tarballs
- Create: `.github/workflows/release.yml` — triggers on `v*` tag push; builds, signs, notarizes, creates GH release, triggers tap update
- Create: `scripts/notarize.sh` — wraps `notarytool submit --wait`; called from the workflow
- Create: `scripts/update-tap.sh` — clones the tap repo, updates the formula SHA+URL, commits and pushes
- Modify: `docs/CI.md` — document the release workflow, required secrets, and tap setup
- Modify: `README.md` — add installation section (`brew install` + direct download)

**In a new repo (`homebrew-autopilot`, or `homebrew-<tap-name>`):**
- Create: `Formula/autopilot.rb` — Homebrew formula (Ruby DSL)

---

## Task 1: Formula repo + skeleton formula

**What this delivers:** A public GitHub tap repo that Homebrew can add with `brew tap`. The formula is a valid stub (hardcoded version, real structure) — it won't install yet because there's no real release artifact, but `brew audit` passes.

**Files:**
- Create (new GitHub repo): `Formula/autopilot.rb`

**Interfaces:**
- Produces: a public repo at `github.com/<owner>/homebrew-autopilot` with `Formula/autopilot.rb`; later tasks update `url`, `sha256`, and `version` fields in that file via `scripts/update-tap.sh`

- [ ] **Step 1: Create the tap repo on GitHub**

```bash
# On GitHub: create a new PUBLIC repo named homebrew-autopilot
# (must start with "homebrew-" for `brew tap` to work)
# Then clone it locally:
git clone git@github.com:<owner>/homebrew-autopilot.git ~/repositories/homebrew-autopilot
cd ~/repositories/homebrew-autopilot
mkdir -p Formula
```

- [ ] **Step 2: Write the formula skeleton**

Create `Formula/autopilot.rb`:

```ruby
class Autopilot < Formula
  desc "Deterministic, app-agnostic macOS GUI test driver via Accessibility API"
  homepage "https://github.com/jschwefel-CBB/autopilot"
  version "0.0.0"  # updated by release workflow
  url "https://github.com/jschwefel-CBB/autopilot/releases/download/v0.0.0/autopilot-0.0.0-arm64.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"  # updated by release workflow

  # AutoPilot requires Accessibility + Screen Recording TCC permissions,
  # which are incompatible with the macOS App Sandbox. This formula
  # installs an unsigned (codesign -) or Developer ID binary; users must
  # grant the running terminal/process Accessibility permission via
  # System Settings → Privacy & Security → Accessibility.
  #
  # The MCP server binary (AutopilotMCP) is installed alongside autopilot.

  on_arm do
    url "https://github.com/jschwefel-CBB/autopilot/releases/download/v0.0.0/autopilot-0.0.0-arm64.tar.gz"
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  end

  on_intel do
    url "https://github.com/jschwefel-CBB/autopilot/releases/download/v0.0.0/autopilot-0.0.0-x86_64.tar.gz"
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  end

  def install
    bin.install "autopilot"
    bin.install "AutopilotMCP"
  end

  test do
    assert_match "autopilot", shell_output("#{bin}/autopilot --help 2>&1", 64)
  end
end
```

> **Why `on_arm`/`on_intel` instead of a universal binary?** A SwiftPM release build on an arm64 GitHub runner produces arm64 only. Cross-compiling to x86_64 is possible but adds complexity; two arch-specific tarballs is the simpler path. Revisit if a universal binary is desired later.

- [ ] **Step 3: Commit and push the skeleton**

```bash
cd ~/repositories/homebrew-autopilot
git add Formula/autopilot.rb
git commit -m "feat: add autopilot formula skeleton (version updated by release workflow)"
git push origin main
```

- [ ] **Step 4: Verify brew tap works**

```bash
brew tap <owner>/autopilot  # taps github.com/<owner>/homebrew-autopilot
# Expected: "Tapped 1 formula."
brew info <owner>/autopilot/autopilot
# Expected: prints formula info with version 0.0.0 — no install yet
```

---

## Task 2: Extend `scripts/release.sh` to produce both binaries + MCP server

**What this delivers:** `scripts/release.sh <version>` builds both `autopilot` and `AutopilotMCP`, signs both with `codesign -s -`, and produces two tarballs: `autopilot-<version>-arm64.tar.gz` (or `x86_64`) containing both binaries. The script outputs the SHA-256 values it will be asked to embed.

**Files:**
- Modify: `scripts/release.sh`

**Interfaces:**
- Produces: `dist/autopilot-<version>-<arch>.tar.gz` containing `autopilot` + `AutopilotMCP`; prints SHA-256 to stdout (consumed by Task 5's `scripts/update-tap.sh`)

- [ ] **Step 1: Read the current script**

```bash
cat ~/repositories/autopilot/scripts/release.sh
```

- [ ] **Step 2: Replace the script**

```bash
cat > ~/repositories/autopilot/scripts/release.sh << 'SCRIPT'
#!/bin/bash
# Build a release of the autopilot CLI + AutopilotMCP MCP server.
#
# Usage: scripts/release.sh <version>
#   e.g. scripts/release.sh 1.0.0
#
# Produces dist/autopilot-<version>-<arch>.tar.gz containing both binaries.
# Printing the SHA-256 of each tarball to stdout so callers can embed it.
#
# Signing is ad-hoc (codesign -s -). For notarization with a real Developer ID,
# use scripts/notarize.sh after this script.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
ARCH="$(uname -m)"   # arm64 or x86_64
DIST="dist"

echo "==> Building release binaries (${VERSION}, ${ARCH})…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
AUTOPILOT="${BIN_PATH}/autopilot"
MCP="${BIN_PATH}/AutopilotMCP"
for f in "$AUTOPILOT" "$MCP"; do
  [ -x "$f" ] || { echo "ERROR: expected binary not found: $f" >&2; exit 1; }
done

rm -rf "$DIST"; mkdir -p "$DIST"
cp "$AUTOPILOT" "$DIST/autopilot"
cp "$MCP"        "$DIST/AutopilotMCP"

echo "==> Signing (ad-hoc)…"
codesign --force --sign - "$DIST/autopilot"
codesign --force --sign - "$DIST/AutopilotMCP"

TARBALL="${DIST}/autopilot-${VERSION}-${ARCH}.tar.gz"
echo "==> Packaging → ${TARBALL}"
tar -czf "$TARBALL" -C "$DIST" autopilot AutopilotMCP

SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
echo "==> SHA-256: ${SHA}"
echo ""
echo "Artifact:  ${TARBALL}"
echo "SHA-256:   ${SHA}"
echo ""
echo "Next steps (manual — these publish):"
echo "  1. Notarize (if Developer ID):  scripts/notarize.sh $TARBALL"
echo "  2. Tag:  git tag v${VERSION} && git push origin v${VERSION}"
echo "  3. Create release:  gh release create v${VERSION} ${TARBALL} --title \"v${VERSION}\""
echo "  4. Update tap:  scripts/update-tap.sh ${VERSION} ${SHA} ${ARCH}"
SCRIPT
chmod +x ~/repositories/autopilot/scripts/release.sh
```

- [ ] **Step 3: Smoke-test the script locally**

```bash
cd ~/repositories/autopilot
scripts/release.sh 0.1.0-test
```

Expected: prints `Artifact: dist/autopilot-0.1.0-test-<arch>.tar.gz` and a 64-char hex SHA-256.

```bash
# Verify both binaries are in the tarball:
tar -tzf dist/autopilot-0.1.0-test-*.tar.gz
# Expected:
# autopilot
# AutopilotMCP
```

- [ ] **Step 4: Commit**

```bash
cd ~/repositories/autopilot
git add scripts/release.sh
git commit -m "build: release script now packages autopilot + AutopilotMCP, prints SHA-256"
```

---

## Task 3: `scripts/notarize.sh` — wrap `notarytool`

**What this delivers:** A script that submits a tarball to Apple's notarization service and waits for approval. Used manually and by the release workflow. Requires Apple Developer credentials stored as env vars (or in the macOS keychain profile).

**Files:**
- Create: `scripts/notarize.sh`

**Interfaces:**
- Consumes: `$1` = path to tarball, env vars `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` (or a keychain profile name `NOTARY_KEYCHAIN_PROFILE`)
- Produces: exits 0 on success, non-zero on failure; prints notarization log on failure

- [ ] **Step 1: Write the notarization script**

```bash
cat > ~/repositories/autopilot/scripts/notarize.sh << 'SCRIPT'
#!/bin/bash
# Submit a tarball to Apple's notarization service and wait for approval.
#
# Usage: scripts/notarize.sh <path-to-tarball>
#
# Credentials — two modes:
#   Keychain profile (recommended for local dev):
#     xcrun notarytool store-credentials "autopilot-notary" \
#       --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
#       --password "$APPLE_APP_PASSWORD"
#     Then set NOTARY_KEYCHAIN_PROFILE=autopilot-notary in your env.
#
#   Env vars (for CI):
#     APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD must be set.
set -euo pipefail

TARBALL="${1:?usage: scripts/notarize.sh <path-to-tarball>}"
[ -f "$TARBALL" ] || { echo "ERROR: not found: $TARBALL" >&2; exit 1; }

if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  CREDS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
  : "${APPLE_ID:?APPLE_ID must be set}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID must be set}"
  : "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD must be set}"
  CREDS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi

echo "==> Submitting for notarization: $TARBALL"
xcrun notarytool submit "$TARBALL" "${CREDS[@]}" --wait --output-format json | tee /tmp/notary-result.json

STATUS="$(python3 -c "import json,sys; print(json.load(open('/tmp/notary-result.json'))['status'])")"
if [ "$STATUS" != "Accepted" ]; then
  echo "ERROR: notarization failed (status: $STATUS)" >&2
  xcrun notarytool log "$(python3 -c "import json,sys; print(json.load(open('/tmp/notary-result.json'))['id'])")" "${CREDS[@]}" >&2
  exit 1
fi
echo "==> Notarization accepted."
SCRIPT
chmod +x ~/repositories/autopilot/scripts/notarize.sh
```

- [ ] **Step 2: Commit**

```bash
cd ~/repositories/autopilot
git add scripts/notarize.sh
git commit -m "build: add notarize.sh wrapper for Apple notarytool"
```

> **Note:** You cannot test notarization without a valid Apple Developer certificate and app-specific password. Test by running against a real tarball once credentials are configured. The script exits non-zero with the full notarization log on failure so you can see exactly what Apple rejected.

---

## Task 4: `scripts/update-tap.sh` — update the Homebrew formula

**What this delivers:** A script that clones the tap repo, patches the formula's `url`, `sha256`, and `version` for the appropriate arch, commits, and pushes. Called from the release workflow and documented for manual use.

**Files:**
- Create: `scripts/update-tap.sh`

**Interfaces:**
- Consumes: `$1` = version (e.g. `1.0.0`), `$2` = SHA-256 of the tarball, `$3` = arch (`arm64` or `x86_64`), env var `TAP_REPO` = `git@github.com:<owner>/homebrew-autopilot.git` (or HTTPS URL), optional `TAP_DEPLOY_KEY` path for CI
- Produces: pushes a commit to the tap repo updating `Formula/autopilot.rb`

- [ ] **Step 1: Write the tap-update script**

```bash
cat > ~/repositories/autopilot/scripts/update-tap.sh << 'SCRIPT'
#!/bin/bash
# Update the Homebrew tap formula with a new release.
#
# Usage: scripts/update-tap.sh <version> <sha256> <arch>
#   arch: arm64 or x86_64
#
# Env: TAP_REPO — SSH or HTTPS URL of the homebrew-autopilot repo
#      GITHUB_TOKEN — if set, uses HTTPS with token auth instead of SSH
set -euo pipefail

VERSION="${1:?usage: scripts/update-tap.sh <version> <sha256> <arch>}"
SHA256="${2:?}"
ARCH="${3:?}"   # arm64 or x86_64

TAP_REPO="${TAP_REPO:?TAP_REPO env var must point to homebrew-autopilot git URL}"
OWNER="jschwefel-CBB"   # update if repo owner changes
URL="https://github.com/${OWNER}/autopilot/releases/download/v${VERSION}/autopilot-${VERSION}-${ARCH}.tar.gz"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "==> Cloning tap repo…"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  # CI: embed token in URL for HTTPS auth
  AUTH_URL="${TAP_REPO/https:\/\//https:\/\/x-access-token:${GITHUB_TOKEN}@}"
  git clone "$AUTH_URL" "$TMPDIR/tap"
else
  git clone "$TAP_REPO" "$TMPDIR/tap"
fi

FORMULA="$TMPDIR/tap/Formula/autopilot.rb"
[ -f "$FORMULA" ] || { echo "ERROR: Formula/autopilot.rb not found in tap repo" >&2; exit 1; }

echo "==> Updating formula for ${ARCH} to v${VERSION}…"
# Update version field
sed -i '' "s|^  version \".*\"|  version \"${VERSION}\"|" "$FORMULA"

# Update arch-specific url + sha256 block.
# The formula uses on_arm/on_intel blocks; update the matching one.
if [ "$ARCH" = "arm64" ]; then
  # Replace url + sha256 inside the on_arm block
  python3 - "$FORMULA" "$URL" "$SHA256" << 'PY'
import sys, re
formula, url, sha = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(formula).read()
# Replace the url line inside on_arm do...end
text = re.sub(
  r'(on_arm do\s+url ")([^"]+)(")',
  lambda m: m.group(1) + url + m.group(3), text)
text = re.sub(
  r'(on_arm do\s+url "[^"]+"\s+sha256 ")([a-f0-9]+)(")',
  lambda m: m.group(1) + sha + m.group(3), text, flags=re.DOTALL)
open(formula, 'w').write(text)
print("arm64 url+sha updated")
PY
else
  python3 - "$FORMULA" "$URL" "$SHA256" << 'PY'
import sys, re
formula, url, sha = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(formula).read()
text = re.sub(
  r'(on_intel do\s+url ")([^"]+)(")',
  lambda m: m.group(1) + url + m.group(3), text)
text = re.sub(
  r'(on_intel do\s+url "[^"]+"\s+sha256 ")([a-f0-9]+)(")',
  lambda m: m.group(1) + sha + m.group(3), text, flags=re.DOTALL)
open(formula, 'w').write(text)
print("x86_64 url+sha updated")
PY
fi

cd "$TMPDIR/tap"
git config user.email "autopilot-release-bot@users.noreply.github.com"
git config user.name "AutoPilot Release Bot"
git add Formula/autopilot.rb
git diff --cached --stat
git commit -m "release: autopilot v${VERSION} (${ARCH})"
git push origin main
echo "==> Tap updated."
SCRIPT
chmod +x ~/repositories/autopilot/scripts/update-tap.sh
```

- [ ] **Step 2: Test the script against the skeleton formula (dry run)**

```bash
cd ~/repositories/autopilot
# Use a fake SHA and version to verify the sed/python patches work locally
# against the skeleton formula in the tap repo you created in Task 1.
TAP_REPO="git@github.com:<owner>/homebrew-autopilot.git" \
  scripts/update-tap.sh 0.1.0 \
  "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234" \
  arm64
```

Expected: the tap repo gets a commit like `release: autopilot v0.1.0 (arm64)` with the formula's `on_arm` block updated.

```bash
# Verify the formula still parses after the patch:
cd ~/repositories/homebrew-autopilot
brew audit --strict Formula/autopilot.rb || true  # warnings OK; errors are not
```

- [ ] **Step 3: Commit the script**

```bash
cd ~/repositories/autopilot
git add scripts/update-tap.sh
git commit -m "build: add update-tap.sh to patch homebrew formula on release"
```

---

## Task 5: GitHub Actions release workflow

**What this delivers:** `.github/workflows/release.yml` — triggers on `v*` tag push. Builds arm64 on `macos-14`, notarizes (if credentials are present), creates a GitHub Release with the tarball attached, then calls `update-tap.sh` to update the formula. A second job handles x86_64 via `macos-13` (Intel). Both jobs upload their artifact; a final `publish` job creates the release once both are ready.

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `docs/CI.md` — document required secrets

**Interfaces:**
- Consumes: secrets `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`, `TAP_REPO`, `TAP_DEPLOY_KEY` (SSH private key for pushing to the tap repo, or use `GITHUB_TOKEN` if the tap is in the same org)
- Produces: GitHub Release with two tarballs attached; tap formula updated

- [ ] **Step 1: Create the release workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ['v*']

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: macos-14
            arch: arm64
          - os: macos-13
            arch: x86_64
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4

      - name: Show toolchain
        run: swift --version

      - name: Build + package
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          scripts/release.sh "$VERSION"

      - name: Notarize
        # Only runs if Apple credentials are configured as secrets.
        # Skip gracefully if secrets are absent (e.g. forks, draft releases).
        if: ${{ secrets.APPLE_ID != '' }}
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          APPLE_APP_PASSWORD: ${{ secrets.APPLE_APP_PASSWORD }}
        run: |
          TARBALL="$(ls dist/*.tar.gz)"
          scripts/notarize.sh "$TARBALL"

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: autopilot-${{ matrix.arch }}
          path: dist/*.tar.gz

  publish:
    needs: build
    runs-on: macos-14
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Download arm64 artifact
        uses: actions/download-artifact@v4
        with:
          name: autopilot-arm64
          path: dist/

      - name: Download x86_64 artifact
        uses: actions/download-artifact@v4
        with:
          name: autopilot-x86_64
          path: dist/

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          gh release create "v${VERSION}" dist/*.tar.gz \
            --title "v${VERSION}" \
            --generate-notes

      - name: Update Homebrew tap
        env:
          TAP_REPO: ${{ secrets.TAP_REPO }}
          GITHUB_TOKEN: ${{ secrets.TAP_GITHUB_TOKEN }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          for TARBALL in dist/*.tar.gz; do
            ARCH="$(echo "$TARBALL" | grep -oE 'arm64|x86_64')"
            SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
            scripts/update-tap.sh "$VERSION" "$SHA" "$ARCH"
          done
```

- [ ] **Step 2: Add required secrets to the repository**

In GitHub → repo Settings → Secrets and variables → Actions, add:

| Secret name | Value |
|---|---|
| `APPLE_ID` | Your Apple ID email (e.g. `you@example.com`) |
| `APPLE_TEAM_ID` | Your 10-char Apple Team ID (find it at developer.apple.com) |
| `APPLE_APP_PASSWORD` | App-specific password from appleid.apple.com |
| `TAP_REPO` | HTTPS URL of the tap repo: `https://github.com/<owner>/homebrew-autopilot.git` |
| `TAP_GITHUB_TOKEN` | A GitHub PAT with `repo` scope for the tap repo (or a fine-grained token scoped to `homebrew-autopilot` with Contents write) |

> **If you don't yet have an Apple Developer account / certificate:** omit `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_PASSWORD`. The notarize step is conditioned on `secrets.APPLE_ID != ''` and skips gracefully. You can add notarization later without changing the workflow structure. Users will see a Gatekeeper warning on first launch (right-click → Open to bypass once).

- [ ] **Step 3: Update `docs/CI.md`**

Add a "Release workflow" section after the existing "Releases" section:

```markdown
## Release workflow (`.github/workflows/release.yml`)

Triggered by pushing a `v*` tag (e.g. `git tag v1.0.0 && git push origin v1.0.0`).

**What it does:**
1. Builds `autopilot` + `AutopilotMCP` on arm64 (`macos-14`) and x86_64 (`macos-13`) in parallel.
2. Notarizes each tarball with Apple's `notarytool` (skipped if `APPLE_ID` secret is absent).
3. Creates a GitHub Release with both tarballs attached and auto-generated release notes.
4. Updates the Homebrew tap formula (`Formula/autopilot.rb` in the tap repo) with the new URLs and SHA-256 hashes.

**Required secrets** (Settings → Secrets → Actions):
| Secret | Purpose |
|---|---|
| `APPLE_ID` | Apple ID for notarization (optional — skip for ad-hoc signing only) |
| `APPLE_TEAM_ID` | Apple Team ID |
| `APPLE_APP_PASSWORD` | App-specific password from appleid.apple.com |
| `TAP_REPO` | HTTPS URL of `homebrew-autopilot` repo |
| `TAP_GITHUB_TOKEN` | GitHub PAT with `repo` write scope on the tap repo |

**Manual release** (without CI):
```bash
scripts/release.sh 1.0.0           # build + package
scripts/notarize.sh dist/*.tar.gz   # notarize (optional)
git tag v1.0.0 && git push origin v1.0.0
gh release create v1.0.0 dist/*.tar.gz --title "v1.0.0" --generate-notes
SHA=$(shasum -a 256 dist/autopilot-1.0.0-arm64.tar.gz | awk '{print $1}')
TAP_REPO=https://github.com/<owner>/homebrew-autopilot.git \
  GITHUB_TOKEN=<pat> \
  scripts/update-tap.sh 1.0.0 "$SHA" arm64
```
```

- [ ] **Step 4: Commit everything**

```bash
cd ~/repositories/autopilot
git add .github/workflows/release.yml docs/CI.md
git commit -m "ci: add release workflow — build/notarize/publish + homebrew tap update"
```

---

## Task 6: Update `README.md` with installation instructions

**What this delivers:** A clear "Install" section at the top of the README so the first thing a new user reads tells them how to get AutoPilot.

**Files:**
- Modify: `README.md`

**Interfaces:**
- None; this is documentation only

- [ ] **Step 1: Read the current README top**

```bash
head -60 ~/repositories/autopilot/README.md
```

- [ ] **Step 2: Add the Install section**

Insert after the opening paragraph (after the `> The product is **AutoPilot**...` callout) and before `## What it does`:

```markdown
## Install

### Homebrew (recommended)

```bash
brew tap <owner>/autopilot
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
```

- [ ] **Step 3: Commit**

```bash
cd ~/repositories/autopilot
git add README.md
git commit -m "docs: add Install section (Homebrew, direct download, build from source)"
```

---

## Task 7: End-to-end release dry run

**What this delivers:** Confidence that the full pipeline works before the first real release. Uses a pre-release tag (`v0.1.0-rc.1`) so it produces a real (draft) GitHub Release and a real tap commit that can be inspected and then deleted.

**Files:** None changed — this is a validation task.

- [ ] **Step 1: Push all commits and verify CI passes**

```bash
cd ~/repositories/autopilot
git push origin main
# Wait for CI (build-and-test) to go green in github.com/<owner>/autopilot/actions
```

- [ ] **Step 2: Push a pre-release tag**

```bash
cd ~/repositories/autopilot
git tag v0.1.0-rc.1
git push origin v0.1.0-rc.1
# Watch github.com/<owner>/autopilot/actions — the "Release" workflow should trigger
```

- [ ] **Step 3: Verify the release workflow**

In GitHub Actions → Release workflow run, check each job:
- `build (arm64)`: SwiftPM build succeeds, tarball in artifact
- `build (x86_64)`: same
- `publish`: GitHub Release created with two tarballs; tap commit visible in `homebrew-autopilot` repo

- [ ] **Step 4: Verify the Homebrew formula**

```bash
brew update
brew info <owner>/autopilot/autopilot
# Expected: version 0.1.0-rc.1 with correct URLs
brew install <owner>/autopilot/autopilot
autopilot --version
# Expected: 0.1.0-rc.1 (or whatever the binary reports)
autopilot doctor
# Expected: Accessibility: needs grant (or OK if already granted)
```

- [ ] **Step 5: Clean up the pre-release**

```bash
# Delete the tag and release (they're pre-release artifacts, not the real v1.0.0)
gh release delete v0.1.0-rc.1 --yes --repo jschwefel-CBB/autopilot
git push origin --delete v0.1.0-rc.1
git tag -d v0.1.0-rc.1
```

- [ ] **Step 6: Revert the tap formula to skeleton state**

```bash
cd ~/repositories/homebrew-autopilot
git revert HEAD --no-edit
git push origin main
# Or: just reset version/sha fields back to 0.0.0/zeroed SHA manually and push
```

---

---

## Task 8: README rewrite — polished public-facing entry point

**What this delivers:** A complete rewrite of `README.md` that a first-time visitor (human or agent) can read cold and immediately understand what AutoPilot is, how to install it, and how to write their first plan. The current README is accurate but terse and developer-internal; this version is written for a public audience.

**Files:**
- Modify: `README.md` (full rewrite — replace all current content)

**Interfaces:**
- Consumes: current `README.md`, `docs/AUTHORING.md` (for feature list accuracy), `schema/plan.schema.json` (for capabilities)
- Produces: a polished `README.md` that serves as the GitHub repo landing page

**Structure the new README as follows (in this order):**

1. **Header** — product name, one-sentence tagline, CI badge (`![CI](https://github.com/jschwefel-CBB/autopilot/actions/workflows/ci.yml/badge.svg)`)
2. **What it does** — 3–5 bullet points, written for a developer who has never heard of it. Lead with the value ("Test any Mac app without touching its source code"), not the implementation.
3. **Install** — Homebrew (primary), direct download, build from source. Exact commands. Gatekeeper quarantine note.
4. **Quick start** — the smallest possible working plan (launch Calculator, click a button, assert something, terminate), runnable in under 2 minutes. Show the JSON, the run command, and the expected output.
5. **Plan format at a glance** — a compact reference table: the 6 most-used actions with their key args and a one-line description. Link to `docs/AUTHORING.md` for the full reference.
6. **MCP server** — 4–6 lines: what it is, how to wire it to Claude Desktop, the 6 tools it exposes. Enough for an agent author to decide if they need it.
7. **Permissions** — Accessibility + Screen Recording: what they're for, how to grant them, `autopilot doctor`.
8. **Requirements** — macOS 14+, Swift 6 toolchain (build from source only), no App Sandbox.
9. **Contributing / license** — 2–3 lines.

**Tone:** direct, no marketing fluff, no em-dash overuse. Read like good developer documentation, not a product pitch. Short sentences. Every command is copy-pasteable.

- [ ] **Step 1: Read the current README**

```bash
cat ~/repositories/autopilot/README.md
```

- [ ] **Step 2: Read the capabilities sections of AUTHORING.md for accuracy**

```bash
# Read the action reference table and §12a screenshot section
sed -n '99,120p' ~/repositories/autopilot/docs/AUTHORING.md
sed -n '538,580p' ~/repositories/autopilot/docs/AUTHORING.md
```

- [ ] **Step 3: Write the new README**

The Quick Start plan should look exactly like this (Calculator is pre-installed on every Mac, needs no bundle-ID lookup):

```json
{
  "schemaVersion": "1.0",
  "name": "calculator-smoke",
  "target": { "bundleId": "com.apple.calculator" },
  "steps": [
    { "id": "wait-window", "action": "waitFor",
      "target": { "role": "AXWindow" } },
    { "id": "press-1",   "action": "click",
      "target": { "identifier": "1" } },
    { "id": "press-plus","action": "click",
      "target": { "identifier": "add" } },
    { "id": "press-2",   "action": "click",
      "target": { "identifier": "2" } },
    { "id": "press-eq",  "action": "click",
      "target": { "identifier": "equal" } },
    { "id": "check-result", "action": "assert",
      "target": { "role": "AXStaticText", "identifier": "display" },
      "assert": { "property": "value", "op": "equals", "expected": "3" } },
    { "id": "done", "action": "terminate" }
  ]
}
```

Run command for the quick start:
```bash
autopilot run calculator-smoke.json --artifacts /tmp/autopilot-demo
```

Expected output (show exactly):
```
RESULT pass 7/7
```

- [ ] **Step 4: Commit**

```bash
cd ~/repositories/autopilot
git add README.md
git commit -m "docs: rewrite README as polished public-facing entry point"
```

---

## Task 9: User manual (`docs/MANUAL.md`)

**What this delivers:** A standalone user manual — a single file a user can read from top to bottom to become fully productive with AutoPilot. Different from `AUTHORING.md` (which is a reference document, dense, not narrative) and from the README (which is a landing page). The manual is the "book" someone reads once to understand the whole system.

**Files:**
- Create: `docs/MANUAL.md`

**Interfaces:**
- Consumes: `docs/AUTHORING.md` (the reference), `README.md` (the entry point), `schema/plan.schema.json`
- Produces: `docs/MANUAL.md` — linked from README and AUTHORING.md

**Structure (chapters in this order):**

### Chapter 1 — Introduction (½ page)
What AutoPilot is, what problem it solves, what it is NOT (not a recorder, not AI-driven at runtime, not a web testing tool). One concrete motivating example: "You want to verify that your app's Save dialog appears, fills the filename field, and commits — without shipping test code inside the app."

### Chapter 2 — Installation & first run (1 page)
Homebrew install. Grant Accessibility. `autopilot doctor`. Run the Calculator quick-start plan from the README. Expected output. What to do if it fails (common: Accessibility not granted, Calculator identifier changed between macOS versions).

### Chapter 3 — How a plan works (1–2 pages)
The mental model: a plan is a JSON file describing a sequence of steps. Each step has an `id`, an `action`, usually a `target`, sometimes `args` and an `assert` block. Steps run in order; the first failure stops the run (unless `--keep-going`). The report tells you what passed, what failed, and why.

Walk through the Calculator example step by step — what each field means, why `waitFor` comes first, what `role` and `identifier` mean, what an `assert` block does.

### Chapter 4 — Finding element identifiers (1 page)
The three ways: `autopilot dump-axtree --bundle-id <id>`, `autopilot find --bundle-id <id> --identifier <name>`, `autopilot suggest --bundle-id <id>`. When to use each. What the output looks like. Tip: use `find` first; `dump-axtree` is for when you don't know what to search for.

### Chapter 5 — The full action set (2 pages)
One paragraph per action group:
- **Navigation:** `click`, `doubleClick`, `rightClick`, `press` (difference: press is more reliable for checkboxes/toggles)
- **Menus:** `menu` with `menuPath` (the only way to drive menu commands with no key equivalent)
- **Text input:** `type` (with `clear`, `commit`, `focus`), `setValue`, `keyPress`
- **Waiting:** `waitFor` (appear/disappear), `wait` (fixed delay — use sparingly)
- **Visual capture:** `screenshot` (3 modes), `assertPixel`, `assertRegion`, `snapshot`
- **Flow:** `launch`, `terminate`

For each: one-line purpose, minimal JSON example, one gotcha if applicable.

### Chapter 6 — Assertions (1 page)
Properties (`value`, `title`, `enabled`, `focused`, `count`, `marked`). Operators (`equals`, `contains`, `startsWith`, `endsWith`, `matches`, `notEquals`, `notContains`, `greaterThan`, `lessThan`, `exists`, `notExists`). One example per non-obvious combo. The `count` property for collections. Why `matches` takes a Swift regex (not PCRE).

### Chapter 7 — Selectors: targeting elements (1 page)
What works: `identifier`, `role`, `title`, `value`, `index`, `within`. What does NOT work (and why): `label`, `path`. The `within` scope for disambiguation. `index` for nth-match. Vision fallback (`vision.image`) for custom-drawn controls — when to reach for it and its cost (slower, Retina-sensitive).

### Chapter 8 — Screenshots and failure artifacts (½ page)
What AutoPilot writes on failure: `<step>.png` (full display) + `<step>.axtree.json`. Element-scoped screenshots via `screenshot` + `target`. `captureTarget: true` for visual logging. The PNG tEXt metadata. Where to find artifacts (`--artifacts` flag, default `./artifacts`).

### Chapter 9 — Plans at scale: includes and suites (½ page)
`include` for shared setup steps (the `launch.json` pattern). `autopilot run <dir>/` for a suite. Per-plan artifact namespacing. Exit codes (0 pass, 1 fail, 2 error, 3 permission).

### Chapter 10 — The MCP server (½ page)
What it is, how to add it to Claude Desktop (`claude_desktop_config.json` snippet), the 6 tools (`run_plan`, `get_report`, `dump_axtree`, `find_element`, `suggest_selectors`, `lint_plan`), the typical agent workflow (suggest → lint → run → get_report).

### Chapter 11 — Troubleshooting (1 page)
Table: symptom → cause → fix. Must cover:
- `error: Accessibility permission not granted` → grant in System Settings → Accessibility
- `error: Screen Recording permission not granted` → grant in System Settings → Screen Recording; note that `screenshot`/`captureTarget` silently no-op (don't error) while assert-visual actions do error
- Element not found → use `find` to check the identifier; check `dump-axtree` output
- Step times out → increase `timeoutMs` in `defaults` or per-step
- `captureTarget` wrote nothing → check Screen Recording; check that target is AX-resolved (not vision-only)
- App launched but first click fails → add `waitFor` on `AXWindow` before first input
- `autopilot doctor` says OK but tests still fail → Accessibility was granted to the wrong process (Terminal vs iTerm vs the binary directly)

### Chapter 12 — Reference links
- Full action/assertion reference: `docs/AUTHORING.md`
- Plan JSON schema: `schema/plan.schema.json`
- GitHub repo: link
- Filing issues: link

**Tone rules:**
- Second person ("you"), present tense, active voice.
- Every code block is copy-pasteable. No `<placeholder>` in runnable commands — use real values or clearly mark as `YOUR_VALUE_HERE`.
- No section longer than it needs to be. If something is fully covered in AUTHORING.md, summarize and link rather than duplicate.

- [ ] **Step 1: Read AUTHORING.md to avoid contradictions**

```bash
wc -l ~/repositories/autopilot/docs/AUTHORING.md
# Read the key sections: action reference, selectors, assertions, screenshots, troubleshooting
head -300 ~/repositories/autopilot/docs/AUTHORING.md
```

- [ ] **Step 2: Write `docs/MANUAL.md`**

Write all 12 chapters. Aim for 1500–2500 words total — comprehensive but not padded.

- [ ] **Step 3: Link from README and AUTHORING.md**

In `README.md`, add after the Quick Start section:
```markdown
For a guided walkthrough, read the **[User Manual](docs/MANUAL.md)**.
```

In `docs/AUTHORING.md`, add at the very top (after the title):
```markdown
> New to AutoPilot? Start with the **[User Manual](MANUAL.md)** for a
> guided introduction. This document is the complete reference.
```

- [ ] **Step 4: Commit**

```bash
cd ~/repositories/autopilot
git add docs/MANUAL.md README.md docs/AUTHORING.md
git commit -m "docs: add user manual (docs/MANUAL.md) and link from README + AUTHORING"
```

---

## Self-Review

**Spec coverage:**
- ✅ GitHub Releases with tarball artifacts → Tasks 2, 5
- ✅ Homebrew tap formula + `brew install` → Tasks 1, 4, 5
- ✅ Both binaries (`autopilot` + `AutopilotMCP`) in each release → Task 2
- ✅ Notarization (optional, graceful skip) → Task 3, 5
- ✅ arm64 + x86_64 builds → Tasks 2, 5
- ✅ SHA-256 auto-updated in formula → Tasks 4, 5
- ✅ User-facing installation docs → Task 6 (README Install section)
- ✅ Polished public README → Task 8
- ✅ User manual → Task 9
- ✅ End-to-end validation → Task 7
- ✅ No App Sandbox (documented in formula and CI.md) → Tasks 1, 5

**Placeholder scan:** No TBD/TODO/placeholder content found. Every script contains actual working shell code. README and manual tasks specify exact content structure and a working Quick Start plan.

**Type consistency:** No code types involved; script variable names are consistent across tasks (`VERSION`, `SHA`, `ARCH`, `TAP_REPO` used identically in `update-tap.sh` and the release workflow).

**One gap noted and accepted:** The `update-tap.sh` Python regex for patching the formula is somewhat fragile if the formula formatting changes. The formula skeleton in Task 1 must preserve the exact `on_arm do` / `on_intel do` block structure for the regex to match. This is documented implicitly by having the skeleton and the script in the same plan. If the formula format needs to change significantly, both files should be updated together.
