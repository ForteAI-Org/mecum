# Living memory in CLI and desktop workers

The desktop app and CLI share the rules for learning a verified action and suggesting it
on a later turn. A suggestion is context for the model. It never opens an application,
authorizes a session, supplies saved coordinates or executes an action by itself.

## Ownership

`WorkspaceLaunch` opens one `SQLiteLivingMemoryStore` at
`Knowledge/living-memory.sqlite`, beside the workspace database. It supplies that store
through `TeamModel` to every `WorkerAgentHost` and `BrokeredAutomationSession`. The CLI
uses the same file under its knowledge directory. `MECUM_APP_SUPPORT_DIR` relocates the
app's complete workspace, including its memory, for an isolated test launch.

Each host owns a `TurnCycle`. At the start of a turn it loads candidate experiences and
prepares a delimited memory briefing. Both signed-in command line providers and Mecum's
own model loop receive the briefing. The learning request is the person's new message;
quoted messages remain provider context and are not learned as the request. Compaction
runs outside the learning cycle.

`EngineRuntime.learn` passes captured scenes through `SceneIntake`, which updates the
Brain and durable sightings. Both desktop and CLI sessions use it. Action results reuse
the scene already captured by the engine; learning does not take another screenshot or
repeat input. The desktop dropdown selector uses the production window pipeline and
its separate menu pipeline, like the CLI selector.

## Recall and attribution

Recall ranks all phrase-matching experiences with the available context. It does not
first discard candidates using a global recency limit. A fresh observation reloads
candidates, checks the current scene, and records its new decision for inspection.
The previous turn's scene contributes window identity only, never fresh evidence.

Immediately before an input, the ledger freezes the current suggestion. An observation
returned after that input cannot reassign its result to a different experience. If a
turn's later inputs are associated with different experiences, the single-experience
ledger abstains from assigning a correction to one of them.

Only typed engine evidence and the admission rules can promote or contradict an
experience. The model saying “done” is not proof. Stopping a turn after a desktop effect
keeps that effect but does not promote the interrupted turn or repeat its input.

## Failure and shutdown

A living-memory database that cannot open leaves the workspace available. The app reports
that recall and learning are unavailable; it does not delete or replace the database.
Read failures are distinct from having no relevant memories. A decision or result write
failure is reported separately from the desktop action's outcome.

The host drains in-flight tools before ending its memory cycle. Closing a worker stops
an active turn, including one still preparing recall, and waits for the whole turn's
memory result before releasing its resources. A persistence failure never retries input.
SQLite rechecks database identity and supported schema under the migration write lock.

Workspace schema compatibility is checked using Core Data's public entity-version hashes.
SwiftData supplies the current hashes by creating an empty temporary store once per
process. If hashes cannot be read, opening conservatively takes a backup. This avoids
relying on a non-public SwiftData-to-Core-Data model conversion.

## Synthetic verification

Run the package baseline from the repository root with Swift 6.4:

```sh
swift build --product mecum
make test SWIFT=swift
git diff --check
```

Focused regressions are `TurnMemoryContextTests` and `SQLiteMigrationBoundaryTests`.
The baseline reports live and provider checks as skipped when their opt-ins are absent.

For a real process boundary, build the tests first, then run each phase as a separate
invocation. These phases use the real action engine, turn cycle and SQLite store with
an invented window and scripted tool calls. They do not read or drive the desktop:

```sh
swift test --no-parallel --filter LivingMemoryProcessTests
memory_test_dir="$(mktemp -d /tmp/mecum-memory-restart.XXXXXX)"
for phase in learn correct verify; do
  MECUM_RESTART_DIRECTORY="$memory_test_dir" \
  MECUM_RESTART_PHASE="$phase" \
  swift test --skip-build --no-parallel --filter LivingMemoryProcessTests || break
done
cat "$memory_test_dir"/*.pid
```

Check that each phase reports one passing test and that the three process IDs differ.
The first phase learns a toggle. The second recalls it and records contradictory
readback. The third reads one verified result and one contradiction from disk without
performing input. Logs and the temporary database can be kept for local diagnosis;
they do not belong in version control.

In the Xcode `Mecum` scheme, run `WorkerMemoryTests`, `WorkspaceLaunchMemoryTests`,
`WorkerAgentHostTests`, `ModelToolLoopTests`, `WorkspaceMigrationTests` and
`WorkspaceStoreFileTests`. The app tests verify sharing between workers, quote handling,
interruption, unavailable memory and preservation of existing workspace data. Use
`ReplyQuoteTeamTests` and `QueuedMessageTeamTests` after integrating app changes that
modify how turns are submitted. These tests use temporary stores and stand-in providers.

## Live acceptance and remaining scope

Synthetic tests establish the memory and lifecycle contracts. A live app workflow still
needs an explicit check with a disposable project and the relevant macOS permissions:

1. Ask for one named selection or toggle and inspect its actual visible result.
2. Confirm a verified memory was recorded, then end the conversation and restart Mecum.
3. Ask for the same operation in a new conversation. Confirm recall appears, a fresh
   observation checks the control, and the action is verified again.
4. Repeat with another app or window, a missing or ambiguous target, and an interrupted
   turn. None should silently execute a stale target or claim unsupported learning.

The durable learning unit is still one admitted step. A complete persistent timeline of
all attempts in a multi-step turn is not implemented. Mixed window-and-popup sightings
still abstain when their context cannot be attributed. Watcher events are not connected
to this learning cycle. The app reports memory activity in its tool records; a dedicated
memory inspector UI is separate work.

Keep subsequent app updates on the integration branch until the worker, queue, quote and
migration checks pass together. Preserve the store injection at `WorkspaceLaunch`,
`TeamModel`, the worker host and the broker session when merging changes to those files.

## Verified dialog closure

A click can now carry `ClickEvidence.Effect.windowClosed(title:)`. The engine identifies the
source by its exact title and frame in the pre-delivery visible and complete inventories.
After successful delivery, two complete inventories must agree that its window number is gone,
with at least one unchanged surviving application window and no other ordinary window changes.
The complete inventory includes hidden and minimized windows. Unsupported or failed inventories,
a recreated window, application loss, ambiguous identity, cancellation, or an incompatible expected
effect leave closure unverified. Closing the application's last window is deliberately not learned.

Verification belongs to the same action transaction, including when the source can no longer be
captured. A later `windows` call or the assistant's statement cannot upgrade an uncertain click.
The memory stores a semantic closure effect under `closes`, separately from the existing `opens`
field. Existing opening records keep their format; a record containing both effects is rejected.
Recall checks the requested gesture, target, window context and opening/closure intent again.

The synthetic production-path regression `closedDialogLearned` covers the exact numbered Italian
request, failed post-closure capture, persistence, reopening the store, recall and confirmation.
`WindowClosureTests` and `ambiguousClosureTeachesNothing` cover missing, hidden, replaced and
collaterally changed windows. `WorkerMemoryTests.closureWithoutAnAfterSceneIsLearnedByTheWorker`
covers the desktop worker consuming the same typed evidence without a post-action scene.
