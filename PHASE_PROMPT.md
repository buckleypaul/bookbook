# Phase Prompt

Use this prompt to run one implementation phase per session. The usual way is the short prompt: `Read PHASE_PROMPT.md and follow it exactly.` You can add any override after it. See `implementation-plan.md` §2.6 for the workflow.

---

Implement the next BookBook phase. Work out which phase yourself; don't ask me. If I've written anything after this prompt (a phase to run, hand-check results, a change), treat it as an override.

## 0. Orient (you, the main thread)
1. Read CLAUDE.md (if present), PROGRESS.md, implementation-plan.md (the core: §0–§3) and the phase's own file, `plan/phase-NN-*.md`. Don't read other phase files, `plan/done/` or `progress/` unless you need something specific from them. Read only the architecture.md / product-description.md sections that phase cites. For wide reading, send an Explore subagent (model: haiku) and keep only its conclusions.
2. Find the current state: PROGRESS.md on main, plus `gh pr list --state open` and `git branch -a --list '*phase-*'`. An open phase PR means that phase is awaiting hand checks; read PROGRESS.md from its branch.
3. If a phase is awaiting hand checks, ask me (AskUserQuestion) whether its hand checks passed, unless I've already said so below.
   - Passed: on the phase branch, mark it `done` in PROGRESS.md (status, merge date, ticked hand checks). Then archive it: move the "Current phase log" entry to `progress/phase-<id>-<slug>.md` and link it from the status table; move its still-open follow-ups into "Open follow-ups" (under their target phase), and drop any follow-ups this phase finished; and `git mv` its spec to `plan/done/`, updating the mapping table in implementation-plan.md. Commit and push, and wait for CI to go green. Then `gh pr merge --squash --delete-branch`, check out and pull main, and confirm main's PROGRESS.md shows the phase as `done`. (Marking it done before merging is what gets the status onto main; never record it only on the next phase's branch.) Then carry on to the next phase, branching from the updated main.
   - Failed: fix what I describe on that branch, verify again (step 4), and stop at `awaiting hand checks` again. Don't start a new phase.
4. If a phase is `in progress` (an unmerged branch with no PR), resume it from its branch and its PROGRESS.md log.
5. Otherwise pick the next phase using implementation-plan.md §2.6. If none is ready (dependencies not met, blocked, or Phase 13 without a Gemini key), say why and stop.
6. Ask any blocking questions in ONE batched AskUserQuestion, with a recommended default for each. Don't ask about anything the plan or architecture already decides. For anything else, use the plan's defaults and record the assumption in PROGRESS.md.

## 1. Plan the phase
- Branch `phase-<id>-<slug>` from an up-to-date main. Mark the phase `in progress` in PROGRESS.md.
- Split the phase into work packages. For each one, set the files and targets it owns, the contracts it uses, its tests, and a done check.
- Write the shared contracts yourself and commit them before fanning out: public types, protocols, BookCommand cases, JSON resource schemas.
- Pick a model for each package (below), and decide which packages can run in parallel: no shared files, and respect the hot spots in plan §2.5.

## 2. Delegate to subagents (by default)
You own: contracts, merges and integration, the hot-spot files (CanvasView, BookDocument, ModelCatalog.json, PriceList.json), concurrency / TextKit 2 / rendering design calls, and the final call on quality. Delegate everything else.

Choose the Agent tool's `model`:
- haiku: mechanical, fully specified work. Scaffolding and boilerplate; JSON and resource files from a given schema; renames; fixture tidy-up; updates to docs and PROGRESS.md; running test suites and summarising failures; grep sweeps and secret scans; checking a hand-check list against the code.
- sonnet: well-specified implementation against frozen contracts. A module, adapter, view or test suite; bug fixes with a known cause; tests written from the plan's test list.
- opus: ambiguous design, refactors across modules, actor and concurrency bugs, AppKit canvas and TextKit 2 work, failures sonnet couldn't fix, and every independent review.

Rules:
- Send independent subagents in a single message so they run in parallel. Give any subagent that edits code `isolation: "worktree"`, and merge its work yourself.
- Every brief stands alone. Include:
  - the goal;
  - the plan and architecture § numbers to read;
  - the files it owns (it must not edit outside them);
  - the contracts it must use unchanged;
  - the tests it must add and its done check;
  - the key rules from §3 below, word for word.
  Ask for a short report (what changed, the tests run and their results, open issues), not file dumps.
- If a result is wrong or incomplete, re-brief the same agent with SendMessage, or move up one model. Don't quietly redo the work yourself.
- Do a small job yourself if it's only a few tool calls.

## 3. Rules that always apply
- API keys: follow implementation-plan.md §2.2 exactly. Live calls go only through scripts/live-tests.sh or scripts/record-fixtures.sh, and only for the live checks this phase lists. Never print, log, echo, write to a file or commit a key, and never run `security … -w` outside `$(…)`. Keep the spend total in PROGRESS.md under the $10 cap, and ask me before any live run that would take it past $8. Record what each run spent.
- Scope: build only what this phase lists. Anything else goes under "Open follow-ups" in PROGRESS.md, tagged with its target phase. At the start, also pick up the follow-ups already filed under this phase.
- If the architecture is wrong or too vague, make the smallest sound choice, update architecture.md in the same PR, and log it. Product-level changes need my approval first.
- Meet the plan's definition of done (§2.1):
  - every undoable edit goes through a BookCommand;
  - everything sent to a provider is shown in Version details;
  - Swift 6 strict concurrency, with no warnings suppressed.
- Small, logical commits with conventional messages. Never force-push main, never use --no-verify, and never change the repo's git identity.

## 4. Verify before handing back
1. Build the app and run the full test suite, the same way CI does. Fix failures until it's green.
2. Run this phase's planned live checks, if it has any, within the budget.
3. Launch and use the app yourself for as many of the phase's hand checks as you can (use the run skill). Note which checks you confirmed and which only I can do.
4. Get an independent review of the phase diff from a fresh opus subagent. Give it the diff range and the phase section, not your conclusions. Fix the issues it finds that you can confirm.
5. Run the secret scan over the whole diff.
6. Push the branch. Open a PR titled "Phase <id>: <name>" with a summary and the hand-check list. Wait for CI to go green, and fix it if it doesn't.

## 5. Hand back and stop
- Update PROGRESS.md on the branch: status `awaiting hand checks`, branch, PR link, spend, and a log entry under "Current phase log" (what was built, deviations, docs changed, follow-ups). Keep it concise: it moves to `progress/` when the phase is done. Commit and push.
- Reply with:
  - what was built;
  - the plan's hand checks as a checkbox list, ticking the ones you confirmed;
  - live spend;
  - decisions and deviations I should know about;
  - follow-ups.
- Then stop. Don't start the next phase.
