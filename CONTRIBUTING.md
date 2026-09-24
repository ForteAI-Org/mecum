# Contributing to Mecum

Every change follows **one issue → one branch → one pull request**:

1. Find or open an issue, including for small documentation fixes. Agree on scope,
   acceptance criteria and required checks before moving it to `Ready`.
2. Follow the [quickstart](QUICKSTART.md). External contributors use a fork and
   substitute its URL when cloning. Start a focused branch from current `main`.
3. Implement the change, update affected tests and docs, and open a draft PR early.
4. Complete the required validation before requesting final review. Record commands,
   results, skipped checks and limitations in the PR.
5. Obtain approval from someone other than the author. A maintainer merges only
   the reviewed change; the issue is `Done` when merged and its criteria are met.

Never push directly to `main`. Changed code requires renewed approval.
These rules also apply to agents; see [AGENTS.md](AGENTS.md). Maintainers
assign reviewers, confirm acceptance criteria and decide release readiness.

Participation follows the [Code of Conduct](CODE_OF_CONDUCT.md). Do not put
suspected vulnerabilities in public issues or pull requests; private reporting
instructions will be added on GitHub.

## Report a problem or request

Search [existing issues](https://github.com/ForteAI-Org/mecum/issues) first, then use:

- [Bug report](https://github.com/ForteAI-Org/mecum/issues/new?template=bug_report.yml):
  incorrect command, tool or library behavior.
- [Feature or improvement](https://github.com/ForteAI-Org/mecum/issues/new?template=feature_request.yml):
  the user's task, current limitation and desired result.
- [Seat compatibility](https://github.com/ForteAI-Org/mecum/issues/new?template=seat_validation.yml):
  an unvalidated macOS build or hardware model, including refusals before adoption.
- [Documentation](https://github.com/ForteAI-Org/mecum/issues/new?template=documentation.yml):
  an unclear, incorrect or missing explanation. No code contribution is required.

New reports enter `Inbox`; reporters need not know the responsible module or reviewer.
Before marking an issue `Ready`, maintainers add scope, acceptance criteria,
required checks, an owner and an independent reviewer.
Discuss API, platform and module-boundary changes before implementation.

## Branches, commits and synchronization

Name branches `<identifier>/<issue-number>-<slug>`; agents use `agent/`.
Keep branches short-lived and limited to the issue.
Use a separate worktree when the checkout contains unrelated changes. Worktrees
do not isolate apps, permissions, ports or the desktop; coordinate GUI tests.

- Keep commits focused on one behavior and its relevant regression tests; each
  commit must build. Use an imperative title, explain why, and use the real author.
- Read `git diff`, stage tracked changes selectively with `git add -p`, and add
  new files by explicit path. Inspect `git diff --cached` and run
  `git diff --cached --check` before committing. Do not stage the whole checkout blindly.
- Never commit secrets, private captures, raw local reports, generated binaries
  or personal editor settings. Keep local investigations in ignored `.scratch/`.
  Reviewed, sanitized compatibility evidence follows the Driver validation procedure.
- Do not add automatic coauthor trailers or invented attribution.
- Fetch the original repository before synchronizing: use `origin/main` for a
  direct clone, or an `upstream` remote pointing to Mecum for a fork. Merge that
  remote's `main` into a published branch; rebase unpublished branches freely.
  Never use `--force`. Use `--force-with-lease` on a published feature branch only
  after notifying everyone using it; never on `main`.
- Resolve conflicts by understanding both changes, never by choosing an entire
  side blindly. Rerun affected checks; record unmerged dependencies in the issue.

## Find and change the code

Use [Package.swift](Package.swift) and the [Engine](Documentation/Engine/README.md),
[Perception](Documentation/Perception/README.md) and
[Driver](Documentation/Driver/README.md) guides to find the responsible layer.
Package.swift defines dependencies, resources and isolation.
Driver work also follows its [local style](Documentation/Driver/CodeStyle.md) and
[domain vocabulary](Documentation/Driver/CONTEXT.md).

Preserve module boundaries and document ownership, cancellation and partial effects.
Never silently replay an unconfirmed action. Tests should exercise the changed
contract; performance and compatibility claims need a named environment and evidence.
Avoid unrelated formatting and cleanup. Record structural decisions in the
relevant layer guide or a [Driver ADR](Documentation/Driver/adr/).

## Run the appropriate checks

For code changes, complete the local baseline below plus every additional tier
required by the issue before final review. Use Swift 6.4, Python 3 and Make:

```sh
swift build --product mecum
make test SWIFT=swift
git diff --check
```

`SWIFT=swift` uses the same compiler as the build. Use a terminal without live-test
opt-ins for local checks. The final `TIER_RESULT` must contain `"status": "passed"`
and `"problems": []`; an exit status alone does not prove completion.
During development, narrow the run with `swift test --filter ActionEngineTests`.

For documentation-only changes, check instructions, links and examples; record
code tests as not applicable unless needed to verify an instruction. Missing
prerequisites or inconclusive results are not passes. A required tier that cannot
run remains outstanding; a targeted run does not replace the full required set.

Never run unreviewed PR code on a machine with secrets, signing credentials or
desktop access. Host/live checks require prior trusted review, an approved
test machine and coordinated exclusive desktop use.

Select additional tiers by the changed behavior:

| Area | Check and prerequisites |
| --- | --- |
| Driver host | `make host-tests SWIFT=swift`; permissions and an awake physical display. |
| Driver live | `AGENTSEAT_FIXTURE_APP=/path/to/fixture make live-tests SWIFT=swift`; consumer-supplied fixture and exclusive desktop use. |
| Performance | `make bench SWIFT=swift`; awake display and required permissions; `stage` also needs the fixture. |
| Perception boundary | `MECUM_LIVE_TESTS=1 swift test --filter PerceptionBoundaryTests`; test-specific app state and permissions. |
| Provider integration | Follow [chat verification](Documentation/Engine/Chat.md#verification); uses signed-in CLIs with synthetic tool data. |

Use the Makefile for Driver host/live tiers: it separates processes and checks
test counts. Update those counts when adding or removing tier tests. See
[Driver testing](Documentation/Driver/README.md#testing-it) for fixture details.

For compatibility work, `make compat-report` creates a draft from the checks.
Ledger promotion is a maintainer decision requiring the full report on named hardware;
one successful Seat operation is insufficient. Follow the
[validation procedure](Documentation/Driver/README.md#validating-a-macos-build).

## Write and submit the change

Keep documentation and comments in English. Put purpose, prerequisites and expected
results first; use short paragraphs and link to existing explanations. Separate
current behavior from proposals and dated experiments. See
[GitHub's writing guidance](https://docs.github.com/en/contributing/writing-for-github-docs/best-practices-for-github-docs).

Keep onboarding in the Quickstart, contributor rules here, and technical
contracts in their layer guides. Link instead
of copying procedures. Use the [PR template](.github/pull_request_template.md) to include:

- The linked issue, problem, resulting behavior and acceptance criteria satisfied.
- Checks run, results, and checks omitted with their reason.
- Changes to public interfaces, permissions, stored data or compatibility.
- For live evidence: revision, macOS build, hardware, app version and research flag.

For perception changes, inspect real inputs and outputs. Performance claims need
fixed inputs, build, machine, cold/warm conditions and measurement boundaries,
not a single run. Distinguish unit coverage from observed desktop behavior.
Share only minimal, sanitized evidence; keep the issue as the source of work status.
