# Coding agents

Follow [CONTRIBUTING.md](CONTRIBUTING.md) for the shared workflow and
[CodeStyle.md](CodeStyle.md) for code changes. These instructions add agent-specific
constraints; they do not authorize commits, pushes or remote changes. Respect
explicit task limits, including requests to leave work uncommitted.

## Work ownership

- Use `agent/<issue-number>-<slug>` for an agent's branch and a separate worktree
  for each agent. Preserve unrelated changes; do not share a working branch.
- Follow the linked issue's scope and acceptance criteria. Record dependencies
  and blockers there; local notes in `.scratch/` are not a work tracker or a backup.
- Every agent-generated PR needs a named human responsible for reading the full
  diff, understanding it and explaining the change. That responsibility does not
  replace approval from a reviewer other than the author.
- Never push to `main` or merge a PR. Do not add automatic coauthor trailers or
  invented attribution. Read the diff before any selective staging.

## Verification and handoff

- Coordinate GUI, Seat, host and live tests across worktrees. They share apps,
  permissions and the desktop. Apply the trusted-review requirement in
  [contributor checks](CONTRIBUTING.md#run-the-appropriate-checks).
- Run the required checks for the change. Report exact commands and outcomes;
  distinguish pass, failure, skipped and inconclusive results. An agent's success
  message is not evidence of application behavior.
- Include inspected outputs for perception changes and measured evidence for
  performance claims. Do not claim live coverage from unit tests.
- In the handoff, state changed behavior, verification, remaining limits and any
  required human action. Do not present pending repository settings as active.

Use [Package.swift](Package.swift) and the [Engine](Documentation/Engine/README.md),
[Perception](Documentation/Perception/README.md) and
[Driver](Documentation/Driver/README.md) guides to locate code. Driver work
also follows its [local conventions](Documentation/Driver/CodeStyle.md) and
[vocabulary](Documentation/Driver/CONTEXT.md). Record structural decisions
in the relevant layer guide or a [Driver ADR](Documentation/Driver/adr/).
