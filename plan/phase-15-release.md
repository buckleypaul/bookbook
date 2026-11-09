# Phase 15 — Release pipeline (M) · completes **M4**

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** a tag push produces a signed, notarized build that installs with brew.

**Scope:** A §13 in full (with the macOS 27 and `xcode-27` changes). Repos: this repo, plus a new public `buckleypaul/homebrew-tap`.

**Deliverables**
- `.github/workflows/release.yml` on `xcode-27`, triggered by `v*`: a temporary keychain with the Developer ID certificate from secrets; archive and export with hardened runtime; `ditto` zip; `notarytool submit --wait` with an App Store Connect API key (fetching the log on failure); staple; re-zip; `shasum`; create the GitHub Release with notes; bump the cask in the tap with a fine-grained PAT; delete the keychain (`if: always()`).
- `Casks/bookbook.rb` per A §13.3, with `depends_on macos:` using **the bare-symbol form for macOS 27** (look up the symbol in current Homebrew at this point), `livecheck`, and a zap list that leaves out `Library/`.
- A `RELEASING.md` runbook, including how to rotate secrets.
- `MARKETING_VERSION` from the tag, and the build number from the run number.
- A `brew audit --cask --strict` step in the tap's CI.

**Acceptance (by hand)**
- Push `v0.1.0`. CI publishes a release. Then `brew tap buckleypaul/tap && brew install --cask bookbook` installs it, and it opens with no Gatekeeper warning. `spctl -a -vv /Applications/BookBook.app` shows "Notarized Developer ID".
- Push `v0.1.1`. `brew upgrade --cask bookbook` updates it, and your books are untouched.
- `brew uninstall --zap --cask bookbook` leaves the library folder in place.

**Tests added:** a workflow dry-run job (build and sign with an ad-hoc identity on PRs; skip notarization) so release breakage shows up before a tag.

**Looked up 2026-11-08:** Homebrew 7.0 maps macOS 27 to `:golden_gate` (`macos_version.rb` SYMBOLS: `golden_gate: "27"`, `tahoe: "26"`), so use `depends_on macos: :golden_gate`.

**Risks:** certificate and secrets setup (you'll need to add: the Developer ID .p12 and its password, the App Store Connect API key .p8 with key ID and issuer, the tap PAT, and the team ID). Notarization delays.
