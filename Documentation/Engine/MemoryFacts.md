# Memory facts: tasks, essential writes, verifications and the shared archive

What the living memory records about the work an agent does, with which guarantees, since G76 plan
D1 (October 2026): the task an agent communicates, the essential facts of every operation confirmed in
the archive, the typed check of every operation, the values withheld from the record, schema 2 with its
migration, and the one archive the app, its external MCP clients and the command line share. Status on
2026-10-09, branch `tommaso/brain-memory-facts`, uncommitted until reviewed.

The calls, samples and Brain applications this page builds on are described in
[MemoryContracts](MemoryContracts.md) and [MemorySchema](MemorySchema.md). This page names the new
contracts, the decisions taken with their alternatives, the inventory of every operation and what proves
each part. D2 (procedures and qualification) and D3 (Recall) read these facts; neither is built here.

## The contracts

| Contract | Type (module) | What it keeps | Stored in |
| --- | --- | --- | --- |
| Task | `TaskRecord`, `TaskRevision`, `TaskRevisionContent`, `TaskValue` (Memory) | The task's id, contract version, producer (source and stream) and trace; its declared status (`open`, then `completed`, `failed` or `abandoned` once); each revision whole: the goal as the agent resolved it, the result asked for, constraints, inputs (name, role, kind, value or `missing` or `withheld`, sensitivity, source, source reference and version) and the messages it came from when the frontend names them | `memory_tasks`, `memory_task_revisions`, `memory_task_constraints`, `memory_task_message_refs`, `memory_task_values` |
| Attempt | `TaskAttempt`, `StoredTaskAttempt` | One execution: an episode of `memory_task_occurrences` (its status and end), its ordinal, the attempt it resumes, its producer and the revision it opened at | `memory_task_attempts` with `memory_task_occurrences` |
| Checkpoint and end | `TaskCheckpointDraft`, `TaskCheckpoint` | What the agent declares along an attempt and at its end: the revision then current, a note, the outputs; an end's declared status, which closes the attempt and the task | `memory_task_checkpoints`, `memory_task_values` |
| Call attribution | `TaskCallAttribution` | The attempt a call belongs to and the revision current when it began, written with the call's start, never inferred later | `memory_task_events` (role `action`, or `context` for a batch) and `memory_task_call_revisions` |
| Operation effect | `OperationEffect` | What a call really did beside its request: the gesture performed (`requested`, `substitute` with its name, `none` with the reason, `uncertain`), the element it resolved, whether its path reported a check | `memory_call_effects` |
| Operation verification | `OperationVerification` wrapping `OperationCheck` (EngineCore) | One check of one call: its own `verification` event, the call, the condition judged, the method and its version, the verdict (`passed`, `failed`, `unknown`), the expected and observed texts, the limits of the evidence, the target and the samples | `memory_verifications` (scope `call`), `memory_operation_verifications`, `…_limits`, `…_samples` |
| Recording gap | `OperationRecordingGap` (Memory) | A part of a call's end (`samples`, `effect`, `verification`) the archive refused as offered and the call was concluded without, why (`refused`, `conflict`) and what the archive said, minimized; a call with one is incomplete evidence | `memory_call_recording_gaps` |
| Withheld value | `ValueRedaction`, `ValueMinimization` (Memory) | Where a withheld value was (an argument, the result's message, a verification's text, the target's label, section or identity, a sample's label, container or title, the observed effect, a listing's application) and why (`declared_secret`, `credential_pattern`, `secret_target`, `secure_field`); never the value, its length or a digest | `memory_value_redactions` |
| Origin | `SQLiteArchiveTransfer`, `BrainMerge` (SQLiteMemory) | Each earlier archive or JSON directory the shared archive took knowledge from, the state of its transfer (`partial` when some of it could not be taken in), the source of every event taken (`added`, `duplicate`, `renamed`), and what its JSON Brains gave each application's Brain, element by element (`added`, `present`, `excluded`) | `memory_archive_origins`, `memory_origin_events`, `memory_origin_brain_contributions` |

A task call is not an operation: `memory_task` is never recorded in `memory_agent_actions` and never
becomes a step. A call made with no open task is recorded as before, with no attribution: nothing
attributes it later by time or order.

### The task an agent communicates

`memory_task` is one more tool of `AutomationTools`, so the app's workers, its external MCP clients and
`mecum chat` share it; its description and `MemoryTaskTool.instructions` tell an agent when to call it.

| Operation | Effect | Refusals (a tool error with a code, never a failed action) |
| --- | --- | --- |
| `begin` | Opens a task, revision 1 and attempt 1; later calls are attributed to it | `task_already_open`, `invalid_task` |
| `update` | A new revision after the one the agent read (`revision`, default its last): the fields given replace, inputs merge by name, `remove_inputs` drops | `no_open_task`, `stale_revision` with `current_revision` (also for a revision the task does not have), `task_closed`, `invalid_task` for a revision that is not a whole number from 1 within 64-bit integers |
| `checkpoint` | Declares progress and outputs; the same declaration at the same revision again is the same checkpoint (`already recorded`) | `no_open_task`, `attempt_not_running` |
| `end` | Declares `completed`, `failed` or `abandoned`, with outputs; closes the attempt and the task | as `checkpoint` |
| `resume` | A new attempt of the producer's unfinished task, linked to the last one, which becomes `interrupted`; nothing of it is replayed | `unknown_task`, `foreign_task`, `task_closed` |
| `status` | The open task, and the memory's suspension if any | none |

A task belongs to its producer (`TaskProducer`: source and stream): another producer can neither read it
through this contract nor change it (`foreign_task`). The app gives each turn's message id as the task's
message reference; an external client gives none, and its chat is never asked for.

### Essential writes

`MemoryService.confirm` writes a fact and answers after its commit, or throws an
`EssentialWriteFailure` (`unavailable`, `suspended`, `contention`, `storageFull`, `permission`, `io`,
`conflict`, `refused`, `cancelled`). Contention is waited for within `essentialCycles` lock budgets of the
store (a `TaskLocal` bound on `SQLiteMemoryStore.write`, which otherwise waits until the lock goes);
contention, a full device and an I/O failure are offered again, with the same identity, up to
`essentialAttempts` times. Every essential write is idempotent: the same facts again are
`alreadyApplied`, other content under one identity a typed conflict that writes nothing.

| Moment | Write | When it is not confirmed |
| --- | --- | --- |
| Before a call that may change the app or the Seat (`AgentTool.requiresConfirmedStart`: the operations, `batch`, `menu`, `press`, `open_session`) | The call planned and started, its admitted arguments, its attribution and gaps (`OperationFactStoring.open`), one transaction | The call is refused and nothing is done (`AutomationTools.unconfirmed`); a read-only call (`status`, `windows`, `apps`, `observe`) and `close_session` run anyway, their answer saying they were not recorded |
| A batch step, before it runs | The step started and attributed (`start(step:)`) | The step is not run and is recorded `skipped` with the steps after it; the batch stops |
| An observation | Its event when the call has none, and its `current` sample, before the Brain learns from it | The observation is answered with its record's gap; after an effect, the memory is suspended |
| After the call | Its samples, end with result, effect, verification and gaps, one transaction (`conclude`) | The fact is kept in the service and the memory is **suspended**: no call may start an effect until it is saved, retried first at each start; the answer says the action ran and must not be repeated |

The kept facts are retried by one retry at a time (review F01): every start that finds the memory
suspended waits for the retry in progress instead of offering the same facts again; the retry offers
them oldest first, including those kept while it runs, removes each by its identity once saved, and
lifts the suspension only when none is left. A close during a retry stops it; what was not saved is
counted in the close's summary and stays `started` in the archive.

A conclusion the archive refuses as offered (a contract's refusal or a conflict, which no retry changes)
is saved as its least instead (`Confirmation.least(refused:)`): the end with its state and result, and,
in the same transaction, one `memory_call_recording_gaps` row for each part it leaves out (samples,
effect, verification) with the reason and the archive's answer, minimized (review F06). The answer to
the agent says so, read after the end (`CallRecorder.recordingGap`), and a reopen reads the same gap: a
missing verification is neither a pass nor an operation without an oracle, and D2 qualifies nothing on
such a call. A failure that may pass (contention, a full device, I/O) is never saved as a least: it
suspends, as above, and the end is saved whole once the archive writes again. A sample the contract
refuses is left out before the write and said as a gap, so a perception defect never suspends the
memory. No transaction is open while a gesture is made or a model is waited for. Exactly-once
delivery of a gesture is not promised: a process that ends between a confirmed start and its end leaves
the call `started`, incomplete, and nothing replays it. `flush` says the derived queue drained, never
that a fact was saved; scene associations and the Brain's learning stay in that queue, rebuilt from the
facts if lost.

Measured on this Mac (Debug, `MemoryWiringTests`, free archive): a call confirmed at its start and its
end in p50 1.2 ms, max 22 ms over 40 calls; a start under another holder's lock is refused after one
budget (0.2 s with the test's 0.1 s budget). The defaults are 2 cycles of 2 s and 3 attempts.

### The check each operation reports

`ActOutcome.check` carries the oracle's judgement from the path that made it to the record, so nothing
reinterprets an outcome's sentence. The verdict is about the condition only: a pass on
`structural_effect` says a change was attributed to the gesture, not that the user's goal was reached;
`found_acted`, `completed`, a closed menu or `acted_noop` never become a pass by themselves. A path with
no oracle reports condition `none` and `unknown`; an outcome with no stated check is given one by
`ActOutcome.withStatedCheck` (no gesture for a refusal, a miss or a no-op; `unknown` and `uncertain` for a
claim without a check). D2 reads `OperationVerification` and `OperationEffect` rows, never log strings.

| Condition | Method | Paths |
| --- | --- | --- |
| `requested_state_already_present` | `control_state` | `set_toggle` already in the state: passed, no gesture |
| `state_after_gesture` | `control_state` | `set_toggle` read back: passed, failed, unknown (`readback_unavailable`) |
| `value_read_back` | `control_value`, `scene_text` | `type_text`, `insert_text` with an expected value, a pop-up's keyboard choice, `select` |
| `structural_effect` | `scene_difference` | click verbs, `press_key`, `scroll`, `drag`: window-wide, with `no_expectation` when the Brain had none |
| `menu_closed_after_choice`, `submenu_opened` | `window_census` | a choice in an open pop-up: the menu's closing, never the command's effect |
| `window_set_changed` | `window_signature` | `menu` (press) and `press`: a window opened, closed or retitled passes; no change is unknown, not failed |
| `recovery_instead_of_request` | `window_census` | a click with a pop-up open that is not its target: the pop-up closed by Escape (`substitute`), the click never sent |
| `menu_item_chosen` | `driver_receipt`, `scene_text` | `context_menu`: the row chosen in the Driver's menu (passed) or absent (failed); the command's effect stays unchecked |
| `none` | `none` | `insert_text` without an expected value (`no_expected_value`); refusals and misses |

Limits: `delivery_uncertain`, `no_after_scene`, `readback_unavailable`, `previous_value_unknown`,
`no_expectation`, `window_wide`, `command_effect_unchecked`, `label_match_only`, `no_expected_value`,
`target_not_resolved`, `unattributed`, `value_withheld`.

### Values withheld before anything is kept

`ValueMinimization` runs before a call's start, its samples, its end, its verification, the Brain's
learning, the task's declarations and the tools' transcript lines: a declared secret (a task input or
output marked `secret`, kept in the producer's memory only) wherever it appears and however short (review
F02: a three-digit PIN is withheld from inside a longer text; the length thresholds belong to the
credential heuristics only; the longest secret goes first and markers are never searched); a credential's shape (private keys, `sk-`, `ghp_`,
`github_pat_`, `xox?-`, `AKIA`, `AIza`, JSON web tokens, 32 or more mixed-case alphanumerics); and the
whole text typed into a control whose name says it holds a secret (password, passcode, PIN, token, API
key, one-time or security code, in English and Italian). A value withheld from a call's arguments is
withheld from everything else of the producer after it. A task's secret input keeps its name, role and
source, never its text. A `memory_task` request's secrets are known before any line of it is written,
the transcript's first, and its goal, result, constraints, reason, notes and the texts that describe
its values are minimized with them; an ordinary value that holds a secret is withheld whole, and what
a revision carries over from the one before is minimized again. The marker is `[withheld]`; the gap is
a `memory_value_redactions` row for a call, the marker in place in a task's texts and `withheld` for its
values. A secret declared only after an earlier revision held it in clear does not change that stored
revision.

Since the second review (F02a to F02c) the same rules reach every text a fact or a derived row keeps,
not only arguments, samples' labels and the verification's texts:

- The element a call resolved: its label, section, role and identity (`minimize(target:)`). Perception
  names a labelled element `kind|normalized label`, so its identity is minimized as its label is, in the
  normalized form, and a declared secret is searched for normalized too; one call's effect and
  verification name the element the same way.
- The effect the engine attributed (`minimize(effect:)`): titles and labels, typed, so the family, the
  states and the encoding stay valid. The call keeps it with an `observed_effect` gap, and its
  verification gains the `value_withheld` limit. The Brain learns no transition from an effect with a
  withheld value: a transition to the marker would be a prediction nobody observed, and one without the
  withheld label a false one.
- A sample's container paths (`sample_container`), the texts of every scene element the Brain learns
  from (label, value, container, group, section, what it does, collection path, identity), and a
  listing's application names, versions, locations and window titles (`listing_entry`).
- What comes from before D1, where nothing was minimized: a JSON Brain imported beside a new archive or
  by hand, and one merged from an earlier client directory, are admitted as a live Brain would have
  learned them (`SQLiteBrainRepository.importAdmitted`, `merge`): credential shapes withheld from labels,
  aliases, window families and group names, and a transition whose effect held one left out; the import's
  report counts them, and a merge journals each element with `withheld`. An earlier client archive's
  facts are transferred under the same rules as a live producer's: arguments, samples, results' messages
  and listings and observed effects minimized with their gaps, a text withheld from any argument of the
  origin withheld everywhere in it, and a Brain application learned again only as admitted
  (`minimize(application:)`); one whose effect held a withheld value is journaled `excluded`, and the
  origin is `partial`.

Limits: the perception does not report a field as secure, so a password typed into a field whose label
names no secret, which the task did not declare secret and which has no credential shape, is kept. A
declared secret is searched for in identities in its normalized form, which may withhold the same
letters in another identity. `OperationConclusion.withdrawn` lets a later fact replace an argument
already kept with the marker, for when such a signal exists.

#### Every text kept, and what filters it

The ordinary values of the person's work are kept, as the contract admits; the filter closes the ways a
declared or recognized secret could be kept. A row with no proof named is shown by reading only.

| Destination | Input | Filter | Proof |
| --- | --- | --- | --- |
| `memory_operation_arguments.text_value` of a call | the agent's arguments | `minimize(request)`; texts withheld join the producer's secrets | `FactWiringTests.canariesAreWithheld`, `.declaredSecretCopiesAreWithheld` |
| `memory_operation_arguments` of a Brain application | the acted element and its effect | `admit(record)`: the element minimized; no application when the effect withheld a value | `FactWiringTests.effectTextsAreWithheld` |
| `memory_agent_actions.result_message` | the tool's answer | `minimize(result:)` | `UnificationTests.transferAdmitsAsLive` |
| `memory_agent_action_windows.title`, `memory_agent_action_applications` (name, version, location) | a `windows` or `apps` listing | `minimize(listing:)`, gap `listing_entry` | `FactWiringTests.listingTextsAreWithheld` |
| `memory_agent_actions.observed_effect_text`, `memory_agent_action_effect_labels.label` | the engine's effect | `minimize(effect:)` at the record, gap `observed_effect` | `FactWiringTests.effectTextsAreWithheld`, `UnificationTests.transferAdmitsAsLive` |
| `memory_call_effects.target_*`, `memory_operation_verifications.target_*` | the element the path resolved | `minimize(target:)`, gaps `target_label`, `target_section`, `target_element` | `FactWiringTests.targetTextsAreWithheld`, `FactContractTests.identitiesAndTargets` |
| `memory_verifications.expected_text`, `observed_text` | the oracle's texts | withheld whole (NULL), gaps `verification_*`, limit `value_withheld` | `FactWiringTests.canariesAreWithheld` |
| `memory_event_observations` (label, window title, container path) | the samples | `minimize(sample:)`, gaps `sample_label`, `sample_title`, `sample_container` | `FactWiringTests.canariesAreWithheld`, `FactContractTests.elementsAndContainers` |
| `brain_scene_*`, `memory_event_scenes` | the stored samples | the samples' minimization | the archive scans of the tests above (every table) |
| `brain_anchors` (label, window family), `brain_anchor_aliases`, `brain_groups.name`, `brain_transitions.effect_text`, `brain_transition_menu_items.title` | live: the scene and the record; before D1: JSON Brains and earlier archives' applications | `minimize(scene:)`, `admit(record)`, `minimize(brain:)`, `minimize(application:)` | `FactWiringTests.effectTextsAreWithheld`, `JSONBrainImportTests.credentialWithheldOnImport`, `UnificationTests.jsonMergeAdmitsAsLive`, `FactContractTests.brains`, `.applications` |
| `memory_task_*` texts | a `memory_task` request | its secrets first, then every text | `FactWiringTests.declaredSecretCopiesAreWithheld` |
| `memory_call_recording_gaps.detail` | the archive's answer | minimized | `FactWiringTests.refusedEndIsDeclared` |
| `memory_origin_brain_contributions.element_key` | a merge or a transfer | identities only: anchor and group ids, a transition's minimized effect, an application's event | `UnificationTests.jsonMergeAdmitsAsLive` |
| `memory_value_redactions` | every filter | where and why, never the value, its length or a digest | all of the above |
| `memory_events` identities, `memory_archive_origins.location`, `detail` | Mecum's producers and the transfer | identifiers Mecum draws (UUIDs, stream names, message ids, client folders) and counts | by reading |
| The tools' transcript (the app's events, `mecum chat`) | requests and answers | `AutomationTools.transcribe`: the producer's secrets and credential shapes | `FactWiringTests.canariesAreWithheld`, `.declaredSecretCopiesAreWithheld` |
| Copies (daily backups, migration copy, unification staging) | the archive | copies of what was already minimized; the staging is removed | `FactWiringTests.canariesAreWithheld` (scans the copy) |
| The service's log | write labels and failure kinds | no value: write labels are Mecum's, failures name their kind | by reading |

## Schema 2 and its migration

Schema 2 is the schema 1 resource, unchanged, followed by `brain-living-memory-schema-2.sql`, which only
adds: 18 tables, 27 triggers, 10 indexes (66, 75 and 41 in all). No table of schema 1 is altered and no
column is reused with another meaning, so a new archive (both texts at once) and a migrated one (the
second text) have the same shape, compared exactly at every open. `memory_schema_migrations` records the
bootstrap (`from_version` 0) or the migration with the copy's name.

- A producer's open of an archive at exactly schema 1 first takes a verified copy beside it
  (`memory.sqlite.schema-1-<instant>`: backup API, integrity, foreign keys, exactly schema 1, rollback
  journal), then, in one write transaction, inspects again under the lock, runs the text, sets the
  version, records it and checks the result is exactly schema 2. Any failure rolls the whole migration
  back: the archive stays at schema 1 and the copy stays. Two openers migrate once; the second removes
  its own copy.
- A reader's open (`mecum memory --status`, `existingArchive`) never migrates: `migrationRequired`, and
  the inspection reports `migratable(from: 1)`.
- An earlier development form, an unknown version, a newer one, or another shape are refused untouched,
  as before. A schema 2 archive is refused by a schema 1 build (`future`): going back to such a build
  means restoring the copy and losing what came after it, which no tool does on its own.
- A recovery accepts a copy at schema 1 as sound: the next open migrates it again.

## One archive per user

`KnowledgeLocation` resolves the support folder (`MECUM_APP_SUPPORT_DIR` when set, else
`~/Library/Application Support/Mecum`) and the one Knowledge directory under it, `Knowledge`. The app's
workers, its external MCP clients (no longer `MCP/Knowledge/<profile>`), `mecum` and `mecum chat` use it;
an explicit `--knowledge` or a test's directory is used as given. `mecum` now honours the support override
as the app does. The product decision G57 (knowledge shared by the app and its MCP clients, requirement
R10) supersedes the merge's earlier choice C07 (one private archive per client, see
[MemoryMerge](MemoryMerge.md)): one knowledge per user, with every call's source, stream and task kept, and
tasks private to their producer.

The external clients' earlier directories are inventoried read only (`legacyProfiles`) and unified into
the shared archive when its service opens (`MemoryService.unify`, run beside the producers):

1. Under the origin's lock (see below), a consistent copy of the origin's archive, through the backup API
   in one read transaction, into a directory this attempt alone owns
   (`.unification/<origin>/<origin>-<attempt>/`), marked with a token of the attempt (`application_id`)
   and opened only as the existing file it made (`SQLiteMemoryStore.Opening.existingCopy`: never created,
   an empty file refused, schema 1 migrated in the copy), its token checked once open. The origin is
   only read and keeps its bytes; the copy, which may still hold the origin's values as an earlier build
   wrote them (the minimization applies to what reaches the shared archive, step 3), is removed when the
   attempt ends, whatever its outcome.
2. An origin holding facts the transfer does not carry (Watcher inputs, correlations, verifications,
   tasks, procedures, experiences, menu commands) is refused whole: nothing is half merged. The
   inventory of `f44fb67` (review F04) found no production writer of any of those ten tables (the only
   writers are their repositories, which no app, MCP, `mecum`, Watcher or Recall path creates), so an
   MCP client's archive written by a build before G76 cannot hold them; the refusal guards against an
   archive written outside the product, and leaves it where it is.
3. Every event in the origin's order, with its call planned and started and its samples, one transaction
   each with its `memory_origin_events` row; then every call's end. An identity the shared archive holds
   with the same content is a proven duplicate (mapped, written once, no evidence added); one held with
   other content comes in as `<id>~<origin>`, and its parent, origin, samples and results follow it.
4. The origin's JSON Brains, merged element by element into the Brain the shared archive may already
   hold (`SQLiteBrainRepository.merge`, review F04): an anchor, group or transition under an identity
   the Brain holds is a proven duplicate, kept as it is with its counts not added to; one under a new
   identity is added with its origin's counts, its history, and ages from now, even when its label is
   one already there; one whose identity another application holds here, a transition whose anchor is
   not in the Brain, and a group that lost members are excluded and stay in the origin's file. Each
   element's fate is a `memory_origin_brain_contributions` row, written with the merge. A Brain the
   archive refuses stops the transfer, which resumes on the next open.
5. The origin's Brain applications, applied again in order under the mapped keys through the shared
   archive's own algorithm: a key already applied teaches nothing twice; scene associations likewise.
6. Before the journal says so, a check that the shared archive holds the snapshot under the origin's
   mapping: every event of the copy mapped to an event that exists, with the parent the mapping gives;
   every call with its tool, and with the copy's state when that state is an end; every sample at its
   mapped key with as many elements; every Brain application applied, or journaled excluded. A count
   alone proves nothing; any fact that fails makes the attempt `failed`, to be taken again.

The journal says where each origin stands (`in_progress` with the attempt that holds it, `completed`,
`partial` when some of its Brains' elements were excluded, with the count in its detail, `refused`,
`failed`, with counts). An origin whose archive held no facts completes with the detail "the origin's
archive held no facts", told apart from a copy that was lost, which is `failed`. A stopped transfer
resumes from its mapping. An ended origin is taken again when its archive holds an event the origin's
mapping lacks: one an older build wrote since the snapshot (the end certified the snapshot it read, at
`high_local_order`), or one an end certified without, as the lost staging copy of review F07 did. On this
Mac no SQLite archive existed in the app's folder on 2026-10-09 (JSON Brains only), so the unification
was proved on synthetic archives only.

### Several openers at once (review F07)

Two openers of the shared archive (an app and an MCP host, two services in one process, two processes)
may unify the same origin at once. Before G76 D1 closed, both used one staging directory: the second
removed the first's copy, the first then opened the path as a new empty archive, and the origin was
certified `completed` with no facts. Each part now has one owner:

| Part | Who and how |
| --- | --- |
| Coordination | One transfer of one origin into one archive at a time, across instances and processes: `flock(2)` on `.unification/<origin>.lock` beside the shared archive, never deleted, taken exclusive without blocking (`SQLiteArchiveTransfer.coordinated`). The kernel lets go of a dead holder's lock. A waiter tries again every 50 ms, is cancelled with its caller (a closing service cancels its unification) and gives up after 30 s with `busy`, the origin left to a later open. No SQL transaction is open while it waits or copies. The JSON-only origins take the same lock. |
| Decision | Under the lock the opener looks again whether the origin needs a transfer (`needsTransfer`): the second of two openers finds it done and copies nothing. |
| Staging | Each attempt copies into a directory named for it; under the lock every other attempt's directory of that origin belongs to one that ended (a crash), and is removed. Another origin's directories are never touched; the root goes only when empty (`rmdir(2)`). |
| Opening | The copy is opened as an existing file only (the library's open without the create flag), and must carry the attempt's token; missing, emptied or replaced it is `stagingLost`, never an empty archive. A schema refusal is the source's only while the refused file still carries the token. |
| Journal | `in_progress` names the attempt; the end (`completed`, `partial`, `refused`, `failed`) is written only while the row still names it, so an attempt that was taken over publishes nothing (`superseded`), and only after step 6. |

Limits: the lock coordinates the code that takes it, on a local volume (`flock` is not reliable on a
network volume); a build before this one, or a tool opening the archive itself, is not coordinated. A
waiter past 30 s leaves the origin to the next open, with its line in `status().lastUnification`.

## Inventory of the entry points

Every entry point that acts on an application or records into the memory, on this checkout. "Start
confirmed" means the call's start is an essential write before any effect. What proves each operation is
listed after the table: the engine's oracle (`OperationCheckTests`, on the engine with doubles of its
scenes and actuator) and the record the tools make of it, read back after a reopen
(`FactWiringTests.everyOperationIsRecorded`, over a session double). Neither is a run on a real
application: the live behaviour of these paths is not certified here.

| Entry | Producer (source, stream, trace) | Before and after | Oracle and check | Output | SQL written |
| --- | --- | --- | --- | --- | --- |
| `act` click, double, triple, right click | app `worker-<id>` / message; mcp `mcp-<profile>` / none; cli `chat-<conversation>` / conversation | `before`, `after` samples from the engine | scene difference, pop-up census; pop-up choice by AX press, keyboard (value read back) or type-ahead; recovery when a pop-up is open | outcome and scene | start confirmed; end with samples, effect, verification; Brain record queued |
| `act` set_toggle | same | `before`, `after` (and `before` alone when already on) | state read back or already present | same | same; no-op recorded with no gesture |
| `select` | same | `before`, `menu`, `after` from `SeatDropdownSelector` | value read at the control, or menu choice failed | same | same |
| `type_text` | same | `before`, `after` | focused field's value read back | same | same; typed text withheld by the rules above |
| `insert_text` | same | `before`, `after` | focused value against `expected_value`, else none | same | same |
| `press_key`, `scroll`, `drag` | same | `before`, `after` | scene difference, window-wide | same | same |
| `context_menu` | same | `before`, `menu`, `after` from `SeatContextMenuSelector` | the Driver's receipt of the choice; effect unchecked | same | same |
| `menu` | same | `current` sample after a press | window signature; a listing sends nothing | same | same |
| `press` | same | `current` sample after the press | window signature | same | same |
| `batch` | same; each step a child call | per step | per step; the parent proves nothing | summary | parent and steps confirmed at start; each step started before it runs; each ended; unrun steps skipped |
| `open_session` | same | `current` sample on an observation event whose origin is the call | none | scene | start confirmed; observation confirmed |
| `observe` | same | `current` sample | none | scene | start and observation best effort, with a gap said |
| `status`, `windows`, `apps` | same | none | none | typed rows | best effort, gap said |
| `close_session` | same | none | none | closed | best effort, never refused |
| `memory_task` | same producer | none | none | task state | task tables; never a call |
| Cancellation of a call | as the call | as far as it got | as far as it got | error | end `cancelled`, no result |
| `mecum act`, `mecum select` | cli `mecum-<pid>` / one trace and one session per process (`CommandLineTrace`) | as the tools | as the tools | printed outcome | start confirmed (refused otherwise), end with check; an unsaved end exits non-zero; a gap is printed |
| `mecum batch` | as `act` / `select`; each step a child call of the batch (`CommandLineBatch`) | per step | per step; the batch proves nothing | printed | as the tools' `batch`: batch and planned steps confirmed before the first gesture, each step started before it runs and ended by its command, the steps never run skipped, the batch's end with its summary |
| `mecum scene` | cli | `current` sample | none | scene | event and sample, best effort |
| The app's `/observe` | system `session-none` | `current` sample | none | image and scene | event and sample, best effort |

The Watcher (`mecum watch`) and the SeatBroker planner (`AgentSession.run`) record nothing and have no
production caller of the memory; they are outside D1.

| Operation | The oracle's check (engine) | The record through the tools, read back |
| --- | --- | --- |
| click | `clickVerdicts`: passed, failed, unknown; `popupRecovery` | `everyOperationIsRecorded` (act click) |
| double, triple, right click | `otherClickVerbs` | `everyOperationIsRecorded` (each verb) |
| set_toggle | `toggleAlreadySatisfied`, `toggleReadBack` | `everyOperationIsRecorded`, `twoNoOps` |
| select | by reading (`SeatDropdownSelector`, live path) | `everyOperationIsRecorded` |
| type_text, insert_text | `inputChecks` | `everyOperationIsRecorded`, `canariesAreWithheld` |
| press_key, with modifiers and a count (shortcuts) | `keysAndDrags` | `everyOperationIsRecorded` (cmd+shift+s twice) |
| scroll | `inputSceneDifference` | `everyOperationIsRecorded` |
| drag | `keysAndDrags`; a destructive drop refused with no gesture | `everyOperationIsRecorded` |
| context_menu | by reading (`SeatContextMenuSelector`, live path) | `everyOperationIsRecorded` |
| menu, press | by reading (`MenuBarCommand`, `DialogButtonPress`, live paths) | `everyOperationIsRecorded`; before D1 closed, a call of either could not be read back (below) |
| batch | per step, as above | `partialBatch`, `CommandLineBatchTests`, `ConsumerReadBackTests.everythingReadsBack` |
| a request the contract cannot represent | refused before any effect | `FactWiringTests` (unrepresentable call refused) |

Reading a `menu` or `press` call back failed before D1 closed: the reader admitted an outcome only for a
batch step's tool, while the writer stored one for every operation, so a trace holding either could not
be read (`malformedCall`, result kind `found_acted`). The reader now admits an outcome for every operation
(`AgentTool.isOperation`); `everyOperationIsRecorded` fails without the fix.

## Requirements of plan D1

| Requirement | What implements it | What proves it (beyond the existing suites) |
| --- | --- | --- |
| R02, R03 | Changes limited to the recording boundary, the tools, the engine's reports, the selectors, the schema and the frontends' directory; Driver, Perception and providers unchanged | Full `make test` and the app's tests (see the D1 report) |
| R04, R19 | Facts (calls, samples, verifications, tasks) apart from derived data (associations, Brain applications, which a unification rebuilds by key); history kept, gaps declared | `UnificationTests`, `OperationFactRepositoryTests` |
| R08 | Agent declares (task, outputs, outcome); engine and paths check (`OperationCheck`); store commits; runtime coordinates | `FactWiringTests`, `OperationCheckTests` |
| R09, R15 | `memory_task`, revisions with inputs, sources and previous outputs, attempts, checkpoints | `TaskContextRepositoryTests`, `FactWiringTests.taskLifecycle` |
| R10, R64 | `KnowledgeLocation`, unification with the JSON Brains merged by identity, one transfer of an origin at a time across processes, tasks private to their producer, no attribution by time | `UnificationTests` (`jsonMergeByIdentity`, `jsonExclusionIsPartial`, `jsonMergeResumes`, `twoOpenersUnifyOnce`), `ArchiveTransferCoordinationTests`, `ConsumerReadBackTests.adaptersReadEachOther`, `FactWiringTests.sharedKnowledgeSeparateTasks` |
| R12, R16, R59, R60 | Essential start and end, retry with identity, one retry of the kept facts for every producer, suspension, least fallback with its durable gap | `FactWiringTests.unconfirmedStartActsOnNothing`, `.failedEndSuspends`, `.refusedEndIsDeclared`, `.unwritableEndSuspends`, `PendingRetryTests`, `MemoryWiringTests.busyArchiveHoldsTheStart` |
| R17, R20, R21, R22, R23 | `OperationCheck` on every path, `OperationVerification`, `OperationEffect` | `OperationCheckTests`, `FactWiringTests.everyOperationIsRecorded`, `.twoNoOps`, `.unrelatedChange` |
| R18 | Batch parent as container, steps started and ended one by one, unrun steps skipped, for the tools and `mecum batch` alike | `FactWiringTests.partialBatch`, `UncertainInputTests`, `CommandLineBatchTests` |
| R58 | `resume`: a new attempt linked, the last interrupted, nothing replayed; a started call stays incomplete | `FactWiringTests.ownershipAndResumption`, `.crashLeavesIncomplete`, `AgentCallProcessTests.diedBetweenStartAndEnd` |
| R61 | Identity and content compared on every write; a unification duplicate written once | `OperationFactRepositoryTests.conflictsWriteNothing`, `UnificationTests.duplicatesAndConflicts` |
| R63 | Schema 2 by addition, verified copy, one-transaction migration, readers refuse, recovery accepts schema 1; an earlier archive's copy migrated only as the existing file it is | `SchemaMigrationTests`, `ArchiveTransferCoordinationTests.lostCopyNeverCompletes` |
| R71 | Baseline and inventory in the D1 report and here | The D1 report |
| R39 to R44, R78 (foundations) | Task values with role, kind, source, sensitivity; withheld values and their gaps, declared secrets of any length in every task text; sources of every transferred fact | `FactContractTests`, `FactWiringTests.canariesAreWithheld`, `.declaredSecretCopiesAreWithheld`, `.outOfRangeRevisions` |

## What D2 and D3 can rely on

- A call's operation: `memory_agent_actions` with its request, `memory_call_effects` (what was really
  done) and its verifications by condition; samples by phase; the attempt and revision it belongs to.
- A task: its revisions, inputs with sources, outputs at checkpoints and end, its attempts. No label, no
  procedure, no qualification is derived here.
- The gaps: what was withheld, where and why; and, for a call concluded as its least, which parts of
  its end are missing and why (`recordingGaps(of:)`): such a call is not to be qualified.
- Every transferred fact names its origin, read with `MemoryService.origins(of:)` (`EventOrigin`: the
  origin, its location, the fact's identity there, added, duplicate or renamed), and every element of an
  origin's JSON Brains says whether it was added, already present or excluded.
- All of it is read back through the repositories after a reopen, as written by the tools and not by
  SQL: `ConsumerReadBackTests.everythingReadsBack`.

## Known limits

- Live desktop runs of this recording were not made in D1; every proof is a unit or integration test on
  temporary archives with doubles of the sessions, plus one real killed process.
- A field the perception cannot tell secure (see above).
- An origin with facts the transfer does not carry is refused whole; it stays where it was. No build
  before G76 could write such facts (inventory above).
- An element of an origin's JSON Brain that cannot be taken in as it was (an identity another
  application holds here, a group that lost members) is excluded, named and left in the origin's file:
  the origin is `partial`.
- Two anchors of one object learned apart by two producers stay two anchors under their own identities:
  a label proves no duplicate, and nothing here decides that they are the same.
- The suspension lives in the process: a process that ends while suspended leaves the unsaved end as a
  `started` call, incomplete.
