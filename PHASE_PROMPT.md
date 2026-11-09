# Phase Prompt

Use this prompt to run one implementation phase in two sessions: **A (build)** and **B (verify)**. The usual way is the short prompt: `Read PHASE_PROMPT.md and follow it exactly.` You can add any override after it. See `implementation-plan.md` §2.6 for the workflow.

**No PRs or CI.** Don't open PRs, use `gh`, or wait on CI. At the end of every session (A, B, or a fix round), merge the phase branch into `main` (`--no-ff`) and push `main` straight to `origin` (`git push origin main`), so main always holds the latest work, locally and on GitHub. GitHub may warn that a required status check is expected; that's fine.

**Before you start a session, set the main-thread effort with `/model`** (the model stays Opus):

| Effort | Phases |
|---|---|
| low | 3, 4, 6, 7, 15, 16 |
| medium | 5, 8, 9, 10, 11, 12, 14, 16b, 17 |

Phase 13 (Gemini) is post-MVP and not part of this plan.

Session B can use the same effort as A, or low.

---

Implement the next BookBook phase. Work out which phase and which session (A or B) yourself; don't ask me. If I've written anything after this prompt (a phase to run, hand-check results, a change), treat it as an override.

**Keep the main thread's context small.** Don't read source files yourself with `sed`, `cat` or Read, beyond the few lines an edit needs. Send an Explore subagent instead, and keep only its conclusions. Write contracts from the plan and architecture docs plus those conclusions. Ask every subagent for a short report, about 10 lines.

## 0. Orient (you, the main thread)
1. Read PROGRESS.md, implementation-plan.md (the core: §0–§3) and the phase's own file, `plan/phase-NN-*.md`. CLAUDE.md is already loaded. Don't read other phase files, `plan/done/` or `progress/` unless you need something specific from them. Read only the architecture.md / product-description.md sections that phase cites.
2. Find the current state: PROGRESS.md on main (it's merged after every session, so it's current; `git pull --ff-only` first), plus `git branch --list '*phase-*'`.
3. **Hand checks are deferred to the end of the build (decided 2026-11-08).** Don't ask me about them. A phase's unconfirmed hand checks go into "Deferred hand checks" in PROGRESS.md, and I run them all after the last phase. If a phase is still `awaiting hand checks` (older flow), close it out as below without asking. If I report a failed hand check, fix it on a branch for that, verify again (§4), merge into main and push.
   - Closing a phase: on the phase branch, mark it `done (hand checks deferred)` in PROGRESS.md (status, merge date). Then archive it: move the "Current phase log" entry to `progress/phase-<id>-<slug>.md` and link it from the status table; move its still-open follow-ups into "Open follow-ups" (under their target phase), and drop any follow-ups this phase finished; and `git mv` its spec to `plan/done/`, updating the mapping table in implementation-plan.md. Commit, then merge the phase branch into main (`git checkout main && git merge --no-ff phase-<id>-<slug>`), push main, and confirm main's PROGRESS.md shows the phase as `done`. Never record it only on the next phase's branch. Remove the phase branch (locally and on `origin` if it's there), its lane worktrees and lane branches once you've confirmed their commits are in main.
4. If a phase is `in progress`, resume it from its branch and the **Stage** line in its "Current phase log":
   - `Stage: A` (or no stage line): carry on with Session A (§1–§2).
   - `Stage: B`: this is Session B. Go straight to §4.
5. Otherwise pick the next phase using implementation-plan.md §2.6, and run Session A. Skip phases marked `post-MVP` (Phase 13, Gemini). If no phase is ready (dependencies not met or blocked), say why and stop.
6. Ask any blocking questions in ONE batched AskUserQuestion, with a recommended default for each. Don't ask about anything the plan or architecture already decides. For anything else, use the plan's defaults and record the assumption in PROGRESS.md.

## 1. Session A: plan the phase
- Branch `phase-<id>-<slug>` from an up-to-date main. Mark the phase `in progress` in PROGRESS.md, and start its "Current phase log" with `**Stage:** A`.
- Pick up the follow-ups already filed under this phase in "Open follow-ups".
- Split the phase into work packages. For each one, set the files and targets it owns, the contracts it uses, its tests, and a done check.
- Write the shared contracts yourself and commit them before fanning out: public types, protocols, BookCommand cases, JSON resource schemas.
- Pick a model for each package (below), and decide which packages can run in parallel: no shared files, and respect the hot spots in plan §2.5.

## 2. Session A: delegate to subagents (by default)
You own: contracts, merges and integration, the hot-spot files (CanvasView, BookDocument, ModelCatalog.json, PriceList.json), concurrency / TextKit 2 / rendering design calls, and the final call on quality. Delegate everything else.

Choose the Agent tool's `model`, and set its `effort` to **medium** for every subagent:
- haiku: mechanical, fully specified work. Scaffolding and boilerplate; JSON and resource files from a given schema; renames; fixture tidy-up; updates to docs and PROGRESS.md; running test suites and builds and summarising failures; grep sweeps and secret scans; checking a hand-check list against the code.
- sonnet: well-specified implementation against frozen contracts. A module, adapter, view or test suite; bug fixes with a known cause; tests written from the plan's test list; driving the app for hand checks.
- opus: ambiguous design, refactors across modules, actor and concurrency bugs, AppKit canvas and TextKit 2 work, failures sonnet couldn't fix, and every independent review.

Rules:
- Send independent subagents in a single message so they run in parallel. Give any subagent that edits code `isolation: "worktree"`, and merge its work yourself.
- Subagents load CLAUDE.md automatically, and it holds the key, scope, git and ownership rules. **Don't paste those rules into briefs.** Start every brief with "Follow CLAUDE.md, especially API key hygiene", then give:
  - the goal;
  - the plan and architecture § numbers to read;
  - the files it owns (it must not edit outside them);
  - the contracts it must use unchanged;
  - the tests it must add and its done check;
  - any phase-specific rule (e.g. the one live check it may run).
  Ask for a short report (what changed, the tests run and their results, open issues), not file dumps.
- If a result is wrong or incomplete, re-brief the same agent with SendMessage, or move up one model. Don't quietly redo the work yourself.
- Do a small job yourself if it's only a few tool calls.

**End of Session A:** once every lane is merged into the phase branch and it builds, set the log to `**Stage:** B`, and add a short note: the lanes, what's left, and anything Session B must know. Commit, then merge the phase branch into main (`--no-ff`) and push main. Tell me: "Session A done. Start a new session with the same prompt for Session B." Then stop.

## 3. Rules that always apply
- API keys: follow implementation-plan.md §2.2 exactly. Live calls go only through scripts/live-tests.sh or scripts/record-fixtures.sh, and only for the live checks this phase lists. Never print, log, echo, write to a file or commit a key, and never run `security … -w` outside `$(…)`. Keep the spend total in PROGRESS.md under the $10 cap, and ask me before any live run that would take it past $8. Record what each run spent.
- Scope: build only what this phase lists. Anything else goes under "Open follow-ups" in PROGRESS.md, tagged with its target phase.
- If the architecture is wrong or too vague, make the smallest sound choice, update architecture.md in the same phase, and log it. Product-level changes need my approval first.
- Meet the plan's definition of done (§2.1):
  - every undoable edit goes through a BookCommand;
  - everything sent to a provider is shown in Version details;
  - Swift 6 strict concurrency, with no warnings suppressed.
- Small, logical commits with conventional messages. Never force-push main, never use --no-verify, and never change the repo's git identity.

## 4. Session B: verify before handing back
Delegate the steps; you merge the fixes and make the calls. Don't pull full logs into the main thread.
1. **Build and test:** a haiku subagent builds the app and runs `scripts/test.sh all` (the same steps as CI), and reports only the failures (test name, assertion, file:line). Send fixes to sonnet, or to opus for concurrency/canvas/TextKit failures.
2. **Live checks:** run this phase's planned live checks, if it has any, within the budget.
3. **Hand checks:** a sonnet subagent launches and uses the app (run skill, throwaway library) for as many of the phase's hand checks as it can, and reports a ticked/unticked list with one line per check. Don't drive the app or take screenshots in the main thread.
4. **Review:** a fresh opus subagent reviews the phase diff. Give it the diff range and the phase file, not your conclusions. Ask for **must-fix issues only**, as a short list with file:line and a one-line failure scenario. Should-fix items and nits go straight to "Open follow-ups".
5. **Cap the fix loop at two rounds** (fix → re-test → re-review of only the fixed areas). Anything still open after that goes to "Open follow-ups".
6. Run the secret scan over the whole diff.
7. If a test looks flaky (fails once, passes on a re-run), re-run once and log it as a follow-up. Don't open a PR.

## 5. Session B: hand back and stop
- Update PROGRESS.md on the branch: spend, and finish the "Current phase log" entry (what was built, deviations, docs changed, follow-ups). Keep it concise. Add every hand check not confirmed by the automated pass to "Deferred hand checks" under the phase, one line each, saying what's left to check.
- Close the phase as in §0 step 3 (mark `done (hand checks deferred)`, archive, merge into main, push, remove branches and worktrees).
- Reply with:
  - what was built;
  - the plan's hand checks as a checkbox list, ticking the ones the automated pass confirmed (the rest are deferred);
  - live spend;
  - decisions and deviations I should know about;
  - follow-ups.
  - the next phase and the effort it needs (table above).
- Then stop. Don't start the next phase.
