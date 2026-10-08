# Memory schema

The SQLite schema of the living memory: what the `SQLiteMemory` module ships, how its store treats a
file, the observation contract its repositories write and read, the stored projection of the brain,
the agent calls, how production writes all of it, and how the shipped resource differs from the
candidate it was copied from. Status on 2026-10-07, branch `tommaso/merge-memory`: schema 1, 48
tables, 48 triggers, 31 explicit indexes, resource sha256
`9df535abc689f7f2610a023ed6be483d408896f7356e88b015b72c2b4324b9e4`.

The store and its repositories were built on `tommaso/memory-model` and documented there at
`f163651`. This branch transplanted that data layer onto main, extended the contract to main's
tools, effects and sources (`4f6f075`), made an archive open only at the exact shape of the shipped
DDL (`1a3e22b`), and wrote the producers again on main's own code (`0f31c0f`, `52523ae`): see
[Producers](#producers) and, for the merge as a whole, [the memory contracts](MemoryContracts.md#merge-into-main).
The resource's history, as `tommaso/memory-model` recorded it and as this branch moved it:

| Step | sha256 of the resource | What changed |
|---|---|---|
| S0 closing candidate v5 | `f3e651892c6af2ff87d48109666b0d4727485605add37b6eddd51e23d2e55d86` | the base; logical model approved at v3 |
| S2 base | `e0bc757bd8b6ef1d43c6e87f265787ae87a4143a8a742e0937ba938adb260b84` | the four S1 triggers, English comments, no `PRAGMA`/`BEGIN`/`COMMIT` |
| S2, second increment | `94140d64ba3988bd4e17902cd400f8d1e283eb9cac9934269d440a6a8e15e6cf` | `brain_anchors.current_group_id` with its foreign key |
| S2, increment 3a | `1e1f079c8f6e6fcdba70fd84551e1abe22ae4ecefc58d43cd9006c5228c42cc4` | the register of the brain's applications |
| S3-d | `c67650dc…` | `memory_agent_actions.started_at_ms` with four CHECKs |
| S3-d correction (`memory-model`, `f163651`) | `b99be960b3247d8bf2aa23d0622102686b73ad8d95a85a31eb11c8762c528ae4` | monotone `duration_ms`, typed observed effects, the structured results of the listing and scene tools, `memory_events.origin_event_id` |
| merge into main (`4f6f075`) | `4c39eed0c6729673eb077b9a2450b63aa2814e3f9e7d7720c4baf60641cd533b` | the `identifier` label origin, the `mcp` source, the `textSelectionChanged` effect, `is_default_browser` |
| merge into main, docs | `9df535abc689f7f2610a023ed6be483d408896f7356e88b015b72c2b4324b9e4` | the correlation triggers' error message names `mcp` too |

Only the last two hashes were recomputed for this page; the others are as `memory-model` recorded
them. Every step stayed at schema 1. Which tables production writes, and which have only an API and
fixtures, is in [the memory contracts](MemoryContracts.md#what-production-writes-today). The
contract items listed at the end were carried into S2 as they stand.

## The resource

`Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql`, copied into the module's
resource bundle and read by `SQLiteMemorySchema` at every open. Its base is the S0 closing candidate
v5, whose logical model was approved at v3. The resource differs from that base in the changes
listed in [Differences from the archived v5 candidate](#differences-from-the-archived-v5-candidate),
in its comments (English) and in carrying no `PRAGMA`, `BEGIN` or `COMMIT` of its own: the store owns
those boundaries.

Shape: 48 tables, all `STRICT`; 48 triggers; 31 explicit indexes; no JSON column. The JSON files
`FileKnowledge` wrote are never read at run time; `mecum memory --import-json <dir>` copies their
Brains by hand ([The brain's projection](#the-brains-projection)). The resource has no version of
its own: the bootstrap sets `user_version = 1` in the same transaction that creates the tables. No
`application_id` is set or checked: a file is recognized by its version and its shape.

A file at version 1 must carry every table of the resource; every column this build writes that an
earlier development form lacked (`SQLiteMemorySchema.requiredColumns`: `brain_anchors.current_group_id`,
`memory_operation_arguments.brain_application_id`, `memory_agent_actions.started_at_ms`,
`memory_agent_actions.duration_ms`, `memory_agent_actions.observed_state_before` and
`memory_events.origin_event_id`); and exactly the tables, indexes and triggers the resource creates,
compared with a scratch bootstrap of the shipped DDL in memory. A difference is
`schema(.differentShape)`, naming each object as `type name`. The archives `tommaso/memory-model`'s
builds created are at version 1 with every table and required column, and their CHECKs and triggers
differ from this resource's, so they are refused by that comparison, untouched. Against the resource of
`f163651` eight objects differ: the tables `brain_scene_elements`, `memory_agent_action_applications`,
`memory_agent_actions`, `memory_event_observations` and `memory_events`, and the triggers
`memory_action_correlations_roles_insert`, `memory_action_correlations_roles_update` and
`memory_agent_action_applications_insert_guard`
(`SQLiteMemoryStoreTests`: "a version 1 file of an earlier development form whose columns match but
whose constraints differ is refused untouched"). Nothing migrates, resets or imports them; a person
moves them aside by hand.

Requirements the store checks on the linked library before opening anything: 3.37.0 for `STRICT`,
and 3.51.3 (or the backports 3.44.6 and 3.50.7) for the concurrent-WAL correction. A library below
either answers `unavailable(.library)`. The `sqlite3` command and Python's module prove nothing
about the library the binary links; `SQLiteLibrary.version` and `.sourceID` do, and
`MemoryService.status()` reports them while the archive is open.

## How the store treats a file

| The file at `open` | What the store does |
|---|---|
| Does not exist, directory writable | Creates it, puts it in WAL, creates schema 1 under the write lock, sets `user_version = 1` |
| `user_version` 0, no tables (a file `sqlite3` created and left empty) | Same as above |
| `user_version` 1, all 48 tables, every required column, and every table, index and trigger written exactly as the resource writes it | Verifies and opens; `bootstrappedNow` is false |
| `user_version` 1, the 42 tables of the S3-d build | Refuses with `schema(.missingTables)`, file untouched: the person moves it aside, nothing migrates |
| `user_version` 0 with tables of its own | Refuses with `schema(.unknownTables)`, file untouched (journal mode included) |
| `user_version` 1 with a table missing, the form before `brain_applications` included | Refuses with `schema(.missingTables)`, file untouched |
| `user_version` 1, every table, a required column missing (the form before `current_group_id`) | Refuses with `schema(.missingColumns(["brain_anchors.current_group_id"]))`, file untouched (journal mode included); never migrated or reset |
| `user_version` 1, every table and required column, but a table, index or trigger missing, extra or written differently (an archive `tommaso/memory-model`'s builds created, whose CHECKs and triggers differ) | Refuses with `schema(.differentShape(["table memory_events", …]))`, the objects named `type name`, file untouched; never migrated or reset |
| `user_version` above 1 | Refuses with `schema(.future)`: no downgrade, no reset, and no reading either, since a typed reader of an unknown layout would be a guess |
| Not a database, or corrupt | `open` error with the library's code (`SQLITE_NOTADB` 26, `SQLITE_CORRUPT` 11), file untouched by the store; `MemoryService` then moves it aside ([Copies and recovery](#copies-and-recovery)) |
| Directory missing or unwritable | `open` error (`SQLITE_CANTOPEN` 14 or `SQLITE_READONLY` 8), nothing created |

The table is the producer's open (`SQLiteMemoryStore.open(.producer)`, the default), the only one
production uses: `MemoryService` opens as a producer for writers and readers alike. A reader's open
(`open(.existingArchive)`, kept in the store and its tests, called by no production path on this
branch) differs in two rows and nowhere else: a file that does not exist is `open` error `SQLITE_CANTOPEN`, never created
(the connection is opened without `SQLITE_OPEN_CREATE`, so a file gone after it was seen is not
replaced), and a file with `user_version` 0 and no tables, of zero bytes or a SQLite database with
nothing in it, is refused with `schema(.uninitialized(fileIsEmpty:))`, untouched: the reader inspects
in a read transaction, since the library writes a header into a zero-byte file at the end of any
write transaction. A valid archive is opened the same way by both, with nothing written.

The shape check compares the file's `sqlite_schema` (type, name and the statement as SQLite keeps
it, the library's own `sqlite_%` objects left out) with the objects a scratch database in memory
holds after running the resource (`SQLiteMemorySchema.objects(of:)`). The statement is compared as
text, so any change inside it, a comment included, is a different shape. The same comparison
checks a snapshot's copy before it is handed over.

Two openers of one fresh file both succeed: the inspection and the creation run under
`BEGIN IMMEDIATE`, and the second opener re-inspects after the first commits. This holds across
processes: `SQLiteProcessTests` opens one fresh file from two `memory-probe` processes held on the
lock at the same time, and exactly one of them creates the schema.

Lifecycle of one instance: `notOpened`, `opening`, `open`, `failed`, `closed`. A second `open` on
an instance that is opening joins the open in flight and shares its answer. A `close` prevails over
an open still waiting for the lock: it ends that open, which answers `unavailable(.closed)` and lets
go of the connection it had, and a closed store stays closed. An open that never succeeded leaves
the store `notOpened` with no connection held, so the same instance may be tried again, whatever
step refused it: the library's version, the schema resource, the first connection (a missing file
for `existingArchive`, a directory not made yet), the inspection or the journal
(`SQLiteOpeningRetryTests`). The store counts the connections it holds (`liveHandles`): two while
open, zero after close, whatever an open or a write was doing when the close arrived; a write
waiting for a lock finds the store closed after its pause and answers the same. Nothing is written
after `close` returns. `close` is not a flush: work still waiting ends with `unavailable(.closed)`,
so a producer awaits the writes it means to keep before closing.

Per connection: `foreign_keys = ON`, verified; `synchronous = FULL`; the reader also `query_only`.
Every open asks for `journal_mode = WAL` on the writer after the inspection (nothing on a file
already in WAL; a restored copy, which is in rollback journal mode, returns to WAL there); every
connection verifies that the file answers `wal`.
The busy timeout of the library is zero: every wait is the store's own, between attempts, outside
any transaction, and ends with the caller's cancellation.

Transactions: a write runs `BEGIN IMMEDIATE`, the body, `COMMIT`, with no `await` in between; a read
runs the body inside one deferred transaction on the reader, so its queries share one snapshot and
never wait for a writer. Every statement is prepared, bound by value and finalized inside the call
that ran it. A body that throws rolls back and its error is answered unchanged. A busy answer at the
begin, inside the body or at the commit rolls back and runs the body again after a pause, so a body
must derive everything it writes from its inputs and from rows it reads inside the transaction.

Values cross the binding boundary whole. Text is bound and read by its UTF-8 byte length, never by
a terminating zero, so a NUL inside a text is content; an empty text stays a text and NULL stays
NULL; a blob keeps its zero bytes. A statement is given exactly as many values as it has
parameters: fewer or more is a contract error (`SQLITE_RANGE`), since the library would otherwise
bind NULL for what was not offered; NULL is only ever a value a caller offers. A text or blob longer
than the connection's length limit is refused by the library whole (`SQLITE_TOOBIG`, a contract
error), never cut.

Reading text is strict. A text column whose bytes are not valid UTF-8 is not decoded: `Row.text`
throws, the transaction it was read in ends, and the store answers `malformedText(MemoryTextFault)`
with the column, the byte count and the offset of the first invalid sequence, never the bytes. No
replacement character, no empty text, no NULL stands in for it; `Row.bytes` still reads the column
as stored. `STRICT` checks a value's storage class, not its encoding: `CAST(X'61FF62' AS TEXT)` is
accepted into a `TEXT` column of a `STRICT` table, which is why the check is the store's. The
module binds only valid UTF-8, so such a row can only come from another writer or from damage.

## Waiting for a busy lock

The lock budget is one cycle of waiting: pauses of 5 ms doubling to 100 ms, until another pause
would take the cycle's pauses past the budget. The budget bounds the pauses, not the wall clock, so
a cycle always holds at least its first pause. `attemptWrite` runs one cycle and answers
`contention` when it is spent, with nothing written, for a caller that classifies a spent budget
itself. The ordinary `write` holds the work instead: it runs cycle after cycle with the same body
and the same identifiers until the commit, the caller's cancellation, the store's close or a
failure that is not contention. The work is the body and its inputs, owned by the caller's task; it
lives nowhere else, so nothing is queued, nothing is dropped, and nothing is reported as saved
before it is. Order is the caller's: its next write is offered after this one's answer, which keeps
one event's planned, started, sample and terminal writes in sequence; there is no order between
producers. A spent budget is not a failure of the task the caller is doing; it is a diagnostic
(`exhaustedCycles`), like the writes waiting right now (`retainedWrites`) and the pauses taken
(`busyRetries`, `waited`). No UI action is repeated by any of this: a retried body writes the same
fact again, it does not redo what produced it.

`Configuration` is refused at `open` (`unavailable(.misconfigured)`) when it would let a cycle end
without a pause: `retryPause` must be above zero, `maximumRetryPause` must not be shorter than it,
`lockBudget` must cover at least one `retryPause`, and `snapshotPagesPerStep` must be above zero.
`Configuration.problem` names the rule broken. The smallest accepted budget, equal to the pause,
still pauses once in every cycle: `SQLiteConfigurationTests` counts the pauses between spent
budgets. The rule is `SQLiteMemoryStore.WaitingCycle`, a value the store gives what each pause
really lasted; its own test gives it chosen lengths and checks the schedule (5, 10, 20, 20 … ms in a
150 ms budget, nine attempts when every pause is punctual) and that a pause the scheduler stretched
ends the cycle sooner. How many attempts fit in a budget on a real lock belongs to the system's
wake-ups (one 5 ms pause lasted 469 ms in a full test run), so the tests on a real lock assert what
the rule promises whatever the wake-ups: at least one pause, one announced pause after every busy
attempt but the last, a cycle that ended only when the next pause would overrun the budget, and,
with a second write offered on the same connection during the wait, no transaction left open across
a pause. The defaults (2 s, 5 ms, 100 ms, 256 pages) are what the tests run with; they are not a
guarantee of availability, and the measures below say what they cost.

If a producer must go on while its write waits, the write runs in a task of its own; that task is
the holder of the work, visible in `retainedWrites`. No store-side queue was adopted. The queue
production uses is `MemoryService`'s, above the store: one task of the service runs the queued
writes one after another, each through an ordinary `write`, so a busy archive is waited out by that
task while every producer goes on ([Producers](#producers)). That queue is in memory only: what it
holds when the process ends is lost, and what it drops when full is counted, not kept.

`open` itself waits within one budget only: a second process opening a file whose lock is held
past the budget answers `contention` and may open again. It does not hold work, since it has none.

## Failure, cleanup and recovery

After a failure of the device or the file inside a transaction (`SQLITE_FULL`, `SQLITE_IOERR` and
the rest of the `failed` row below), the store does not assume the library rolled back. It reads
`autocommit`, rolls back what is still open, reads it again, and reports what it found in the
fault: `cleanup` is `alreadyRolledBack` when the library had already ended the transaction (what
`SQLITE_FULL` from a page limit and `SQLITE_IOERR_WRITE` from a file size limit both do, measured),
`rolledBack` when the store's own `ROLLBACK` ended it (what a constraint failure needs, since the
library leaves that transaction open), `notNeeded` outside a transaction, and `failed(code,
message)` when the rollback was refused or the connection stayed inside a transaction. The primary
failure is always the one answered; the cleanup is diagnostic beside it, never in its place.

A cleanup that failed makes the connection untrusted. The store then lets go of both connections
(`liveHandles` 0) and enters `failed`: every later `write`, `read`, `diagnostics`, `checkpoint`,
`snapshot` or `open` on that instance answers `unavailable(.failed(fault))` with the fault that
caused it, never an empty result, and so does a call that was already waiting for the lock when the
connections were let go. `close` is definitive as always. Recovery on the same path is a
new instance, `SQLiteMemoryStore.open(at:)` on the same URL, once the cause is removed: the library
recovers the log on open, the inspection checks the schema, and the rows committed before the
failure are there. No reset, no other file, no automatic retry of the write whose outcome the
failure left known as "not written": the caller offers that fact again by its identity if it wants
to, as `SQLiteRecoveryTests` does after a full database and `SQLiteProcessTests` after a killed
process. The decision is tested on its own (`cleanupDecision`) and the whole path through an
internal seam (`refuseNextRollback`, `package`, never public, reached by the package's tests): a
real failure of the
library inside a transaction, a rollback the seam answers as refused, then the release of both
connections and of the lock, the answers to later and already waiting calls, the close and a new
instance on the same file (`SQLiteFailedLifecycleTests`). No real fault reproduced a refused
rollback on this library, so the transition to `failed` is not proven by a real failure, and the
seam is not one. A transaction that ended cleanly leaves the
store open and usable, which is what every real failure produced so far did.

`MemoryService` does not watch for that state: it degrades only when an open fails. A store that
became `failed` while the service was open keeps the service `open`, and every later write is a
counted failure (`status().failed`, `lastFailure`) until the process ends; nothing makes the new
instance the recovery above requires. No test covers that path on this branch.

Real failures the tests produce, without a fault injection in the library: a full database through
`PRAGMA max_page_count` in the store's own process (`SQLITE_FULL` 13 at the statement, cleanup
already done by the library, nothing written, the same write refused again, a new instance without
the limit writes), and a real disk I/O error in another process through `RLIMIT_FSIZE` on the
`memory-probe` helper (`SQLITE_IOERR_WRITE` 10/778 at the commit, cleanup already done, nothing
partial, the store goes on, the same write commits once the limit is lifted, the file reopens
whole).

## Checkpoints

The policy is the library's own: after a commit on the writer that leaves the write-ahead log above
`wal_autocheckpoint` frames (1000, the library's default, read back in `autoCheckpointFrames`), the
library runs a passive checkpoint on that connection. `SQLiteCheckpointTests` writes 2500 pages in
ten commits and finds the log bounded well below their size. An explicit `checkpoint()` runs one
passive checkpoint on the writer and answers `Checkpoint`: the log's frames, how many reached the
file, the outcome (`complete`, `partial` when a reader in this or another process still needs the
rest, `busy` when another connection was checkpointing) and the duration. Neither `partial` nor
`busy` is an error, a reset or a loss: the rest of the log waits for the next checkpoint, and the
store writes on. `TRUNCATE` and `RESTART` are not used, since they would wait on or assume the
absence of other processes on the file. `Diagnostics` counts the explicit checkpoints and keeps the
last report.

## Snapshots

`snapshot(to:)` copies the file through the library's backup API and answers `Snapshot` once the
copy is verified and in place. Copying the main file alone is not a snapshot: in WAL the rows, and
after a bootstrap even the tables, are in the log until a checkpoint, and `SQLiteSnapshotTests`
shows a byte copy of the main file without its tables beside a snapshot with every row.

- The copy is consistent as of one read transaction, opened on a connection of the snapshot's own
  and held through every step; commits by this or another process during the copy neither appear
  in it nor restart it, and the writer is not stopped. A writer in another process holding the
  lock throughout is proven not to block the copy and not to get into it.
- The destination must not be the store's file or one of its journals
  (`snapshot(.destinationIsTheSource)`) and must not exist (`snapshot(.destinationExists)`):
  nothing is overwritten. A destination that cannot be created answers
  `snapshot(.destinationUnavailable(fault))` with the library's code for that path.
- The copy is built at a temporary path beside the destination that only this call names, stepped
  `snapshotPagesPerStep` pages at a time with a yield and a cancellation check between steps;
  a busy step is paused on within one budget like any other step. The finished copy is checked
  (`integrity_check`, `foreign_key_check`, schema 1 at the resource's exact shape), put in rollback journal
  mode so it is one self-contained file, and renamed into place with `renamex_np(RENAME_EXCL)`,
  which refuses to replace anything that appeared meanwhile. A snapshot reopens with the store as
  a file at schema 1.
- Any refusal, failure, cancellation between steps or close of the store during the copy removes
  the temporary files this call created, lets go of both connections, and leaves no copy: an
  interrupted copy is never handed over. Nothing is ever restored from a copy on the store's own
  initiative.

`MemoryService` uses `snapshot(to:)` for its daily copy and restores one only when its own open
finds the file corrupt ([Copies and recovery](#copies-and-recovery)). Nothing in that restore
checks whether another process holds the file.

## What the store answers

| Condition | `MemoryStoreError` | Retry |
|---|---|---|
| `SQLITE_BUSY` (5) past one budget, from `attemptWrite`, `read`, `open` or a snapshot step | `contention(fault, attempts:, waited:)` | `write` does it: another cycle with the same body and identifiers |
| `SQLITE_LOCKED` (6) | `locked` | No: a statement left open on the table, a store defect |
| `SQLITE_CONSTRAINT` (19), `SQLITE_ERROR`, `SQLITE_MISUSE`, `SQLITE_RANGE`, `SQLITE_MISMATCH`, `SQLITE_TOOBIG`, `SQLITE_SCHEMA` | `contract` | No |
| `SQLITE_FULL` (13), `SQLITE_IOERR`, `SQLITE_READONLY`, `SQLITE_CORRUPT`, `SQLITE_NOTADB`, `SQLITE_CANTOPEN`, `SQLITE_PERM`, `SQLITE_NOMEM` | `open` while opening, `failed` afterwards, with `cleanup` | No; the caller knows the fact was not written |
| A text column that is not valid UTF-8 | `malformedText(MemoryTextFault)` | No; read the column as bytes |
| Destination or copy of a snapshot refused | `snapshot(MemorySnapshotRefusal)` | With another destination |
| `SQLITE_INTERRUPT`, or the caller's task cancelled during a pause or between snapshot steps | `cancelled(phase)` | The caller decides; nothing was written, no copy left |
| Store never opened, closed, closed while opening or waiting, library too old, resource missing, configuration refused, a cleanup that failed | `unavailable` | No; after `.failed`, a new instance on the same path |
| Same identity, different content | `identity(conflict)` | No: the stored fact stays |
| A file at another version, with tables of its own, missing tables or columns, or another shape | `schema(MemorySchemaMismatch)` | No: the file is left as found |
| Any code not named above | `failed` | No: an unknown condition is not retried |

`MemoryReceipt` is `committed` or `alreadyApplied`, and only after a commit. Idempotency is decided
inside the transaction by whoever writes the fact: read the row by its identity, compare the typed
content exactly, answer `alreadyApplied` when equal, throw `identity` when not, insert otherwise.
The store itself maps a `UNIQUE` violation to `contract`, because it cannot know whether the
content was the same. `SQLiteMemoryTests` and the `memory-probe` helper show the pattern on
`memory_events`, in one process and across two; the typed repositories own it.

## Observation contract, version 1

What `SQLiteCaptureRepository` writes into `memory_events` and `memory_event_observations`, what
`SQLiteSceneRepository` writes into `brain_scenes`, `brain_scene_roles`, `brain_scene_labels`,
`brain_scene_elements` and `memory_event_scenes`, and what both read back. The Swift types are
`Memory`'s (`Sources/Engine/Memory/Observation`); the SQL stays in the adapter. Every rule below is
refused on the way in and on the way out: a stored row that breaks it is `ObservationContractError`,
never a lesser row, and no unknown code is mapped to a known one.

### Kinds, versions and statuses

`observation_kind` is a closed, versioned registry (`ObservationKind`). This build writes and reads
`observation_contract_version` 1 of three kinds; another code is `unknownObservationKind`, another
version `unsupportedContractVersion`. A later kind or version is an explicit extension of the
registry with its own decoder.

| Kind | Identity and parent | `status` vocabulary | Required | Forbidden (must be NULL) |
|---|---|---|---|---|
| `capture` | one per (`event_id`, `phase`, `sample_ordinal`), no parent; ordinal 0 is the perception the engine used | the capture's completeness: `complete`, `partial`, `failed`, `unknown` (`CaptureQuality.Completeness`) | `surface_kind`; `window_title` and `session_revision` optional | `field_name`, every value column, `observation_group`, `parent_observation_id`, `candidate_rank`, `label`, `label_origin`, `container_path`, `role`, `element_kind`, `old_state`, `new_state`, bounds, `scene_age_ms`, `name_resolution`, `label_source` |
| `capture_field` | child of its sample, same `event_id`, `phase` and `sample_ordinal`; one row per field of `CaptureField`, all eight written for every sample | `observed` with exactly one value in the field's storage class, or `not_observed` with none (`ObservationStatus`) | `field_name` in the vocabulary | every capture and element column; `real_value` |
| `element` | child of its sample, same key; one row per role-bearing element, in scene order | `observed` | `role`, `label`, `element_kind` (`ElementKind`), `container_path` (the empty text is the root), four bounds; `label_origin`, `new_state` (the state the sample saw) and `observation_group` optional | `field_name`, every value column, `surface_kind`, `window_title`, `session_revision`, `candidate_rank`, `old_state`, `scene_age_ms`, `name_resolution`, `label_source` |

A sample's `status` must equal the completeness its fields add up to (`statusContradictsFields`);
a field twice is `duplicateField`, a field missing is `missingColumn`; a child under another child
is `nestedUnderChild`, a child with no parent `orphanChild`, a child of another phase or ordinal
`parentMismatch`. `label_origin` is `title`, `description`, `value`, `column`, `row_content` or
`identifier` (`LabelOrigin`, the DDL's CHECK on the element rows and on `brain_scene_elements`), or
NULL for a label read from nowhere: a pixel element, or the `Text area` and `Text field` handles
Perception gives an unnamed editor. The eight fields: `walk_completed`, `window_found`, `grant_available` (boolean in
`boolean_value`), `stopped_by` (`deadline`, `element_limit`, `table_limit`, `depth_limit`),
`window_role`, `window_subrole` (text in `text_value`), `nodes_visited`, `elements_emitted` (integer
in `integer_value`). Completeness is derived, never stored beside the facts: a false grant or a
missing window (`window_found` false) is `failed`; a stopped walk is `partial`; a finished walk
(`walk_completed` true, no `stopped_by`) of a found window (`window_found` true) is `complete`;
anything else is `unknown`, a finished walk of a window nobody confirmed included. A grant nobody
observed stays `nil` and does not fail the read: `nil` is not false. Completeness is never inferred
from the element count. Facts that contradict each other, a finished walk that names a stop reason
or a negative count, are an `inconsistentQuality` refusal on the way in (`invalidRecord`) and on
the way out (`malformedObservation`): nothing is repaired or defaulted. Elements inside a
collection share one `observation_group` per collection path, a number per collection in order of
first appearance (two collections in one capture are two groups), NULL outside any collection;
rows of one group that disagree on `container_path` are `collectionGroupInconsistent`. An element's
four bounds must be finite numbers: NaN or an infinity is `nonFiniteBounds`, refused before the
commit and again on a row another hand wrote (the file would keep NULL for NaN and an infinity for
an infinity, and neither rebuilds a rectangle); no finite coordinate is bounded further. A
pixel-only element has no role and is not a sample row.

The event's `capture_status` is the worst completeness among its samples (`failed`, then `partial`,
then `unknown`, then `complete`; `not_applicable` with none), rewritten after each sample: the one
column of an event that moves. A record is refused before any transaction when it has no identity,
no stream, no bundle id, a negative ordinal, an element with no role or label, or a parent without a
position (`invalidRecord`).

### Identity and idempotency

An event is applied once by `event_id` and once by (`source`, `source_stream_id`, `source_key`).
Whether two offers carry the same content is decided by the typed, exact comparison of every
immutable field (`MemoryEventRecord.hasSameImmutableContent(as:)`): NULL is not empty text, a
separator inside a value is content, and only `capture_status`, the one column allowed to move, is
left out. The one declared exception is the app context's unknown marker: the store keeps an
unknown version or locale as the empty text, so an empty version and a `nil` one are the same
stored row (`AppContextIdentity.stored`); the marker belongs to those two columns alone. The same
content is `alreadyApplied` and moves nothing; other content is `identity(conflict)`, nothing
written, the stored fact stays. The two digests in the conflict (`contentDigest`, `fingerprint`)
are diagnostics, length-prefixed and NULL-marked so they rarely collide, and they never decide: two
equal digests would still be a conflict when the typed content differs. The application and the
context are found or created in the same transaction (`brain_apps` by bundle id,
`brain_app_contexts` by version and locale). A sample is applied once by (`event_id`, `phase`,
`sample_ordinal`) on `CaptureSample ==`, the exact comparison of every persisted field, every text
byte for byte, every element with its metadata in order and every bound as the number it is (`-0.0`
and `0.0` are one bound; not the scene element's legacy
equality, which leaves the metadata out), and only for an event the store holds
(`missingEvent`): no event is invented for a sample. A sample, its fields and its elements are one
transaction: a file that refuses part of them leaves no row of them (`CaptureRepositoryTests.rollback`,
a full database). A decision of the scene matcher that wrote no row (a refusal) leaves no durable
marker: a later call evaluates the sample again; a decision that wrote rows is answered as stored.

### Producer, column, reader

| Producer | Fact | Column | Reader |
|---|---|---|---|
| `AccessibilityAugmentation.harvest` (walk) | `SceneElement.labelOrigin` (`identifier` for a text area named by its accessibility identifier; nil for the placeholder handles) | `memory_event_observations.label_origin`; a scene's `brain_scene_elements.label_origin` | `CaptureElement`; `SceneSkeleton` (captions only from title and description on a caption role, so an identifier is never a caption) |
| same | `SceneElement.collectionPath` | `container_path` of the element row (the collection's path) with `observation_group`; a scene's `collection` and `item_template` rows | `CaptureElement.isUnderCollection`; `SceneSkeleton.collections` |
| same | `container` outside a collection | `container_path` (root is the empty text); a scene's `container` rows | `SceneSkeleton.rolesByPath`, `captionsByPath` |
| same | `CaptureQuality.walkCompleted`, `stoppedBy`, `nodesVisited`, `elementsEmitted`, `windowRole`, `windowSubrole` | the `capture_field` rows; `status` of the sample | `CaptureQuality(fields:)`; `isComplete` gates every structural decision |
| `AccessibilityAugmenter` (live) | `windowFound`, `isGrantAvailable` | `window_found`, `grant_available` | same |
| `ScenePipeline.capture` | the quality beside the scene (`SceneCapture`) | through `PerceivedWindow.capture` | `CaptureSample(key:of:)` |
| `ActionEngine` | the perceptions an action or an input used (`ActionRecord`, `InputRecord`: `before`, `menu`, `after`) | samples of phase `before`, `menu`, `after`, written by `CallRecorder` | `CaptureStoring.sample(_:)` |
| `LiveSceneProvider`, `SeatSceneProvider` | `PerceivedWindow.surface` (`popup_union` with a pop-up open, else from role and subrole, else `unknown`) | `surface_kind`; a new scene's `scene_kind` | `SceneStructureMatcher` (no association on a union, no new scene on unknown) |
| a scene's elements | `SceneElement.state` | `new_state` of the element row (the state seen; `old_state` NULL) | `CaptureElement.state`; not identity |
| the scene | `windowTitle` | `window_title` of the sample; `title_bucket` (`LabelText.letters`) of a new scene, `window_title_pattern` NULL | a hint, never identity |
| `SceneSkeleton.structuralKey` | FNV-1a of the canonical skeleton | `brain_scenes.structural_key` | a search hint, not UNIQUE, not identity |
| `SceneStructureMatcher` | the decision | `memory_event_scenes` rows with `matched_by = 'structure'`, `matcher_version = 'v3'`, `confidence` NULL; `observation_count` and `last_seen_ms` of a confirmed scene | `SceneAssociation`, `SceneAssociationOutcome` |

Not persisted: an element's `value`, `selectedRange`, `isEnabled`, `section`, `group`, `does` and
pixel-only elements; `brain_scene_elements.source`, `bounds` and `anchor_id`; a scene's
`window_title_pattern`. The dropdown and contextual menu selectors (`select`, `context_menu`) take
their own captures and report none of them, so those calls have no sample.

### Scenes and structure-v3

`SQLiteSceneRepository.associate` reads the stored sample, rebuilds its skeleton, reads the scenes
of the sample's application (`scene_kind <> 'app'`, the app scope is never a candidate), runs
`SceneStructureMatcher` and writes the decision, all in one `BEGIN IMMEDIATE` transaction: two
complete captures of one skeleton from two stores on one file make one scene, and
`structural_key` stays a hint without a unique index (`SceneAssociationTests.concurrentWriters`).
A sample already decided answers its stored rows as `alreadyApplied`; a menu-phase sample, a
pop-up union, an incomplete capture, an unknown surface or an empty skeleton writes no row and says
why. A confirmed association counts one observation of its scene; a candidate counts nothing. A new
scene is written from the sample's own elements: `brain_scenes` with the title as a bucket hint and
the digest as a search hint, `brain_scene_roles` as presence (`count_bucket` NULL),
`brain_scene_labels` as the normalized captions, and `brain_scene_elements` as a tree keyed
`container|<path>`, `control|<path>|<role>|<normalized caption or nothing>`, `collection|<path>`,
`item_template|<path>` (role `AXRow`). A control whose label was content keeps its origin and no
label, so nobody's name enters the structure. The skeleton rebuilt from these rows after reopening
equals the produced one, structural key included (`SceneAssociationTests.f15RoundTrip`).

The skeleton's authority is `brain_scene_elements`: the matcher, `scenes(of:)` and the graph's
`elements(ofScene:)` rebuild everything from those rows. `brain_scene_roles` (the skeleton's role
set, presence only, `count_bucket` NULL) and `brain_scene_labels` (its non-empty caption labels)
are projections derived from the same skeleton and written once, with the scene; a later
observation of the scene does not rewrite them, and no reader of this build consumes them.
`SceneAssociationTests.derivedRolesAndLabels` proves that what is written equals what the elements
rebuild, byte for byte, and that rows and values never enter them. They stay written hints for a
later index; matching does not read them and no count is added to it.

Declared limits of structure-v3, as the S0 specification states them: two dialogs with one skeleton
are one scene; captions that are names and containers titled after content stay uncertain and
never create a scene; without an accessibility read there is no scene; a partial capture certifies
no absence and keeps every candidate; promoting a candidate is a later policy, not this one.

## The brain's projection

What `SQLiteBrainRepository` (`BrainStoring`, the role in `Memory`) keeps of a `UIBrain` and how it
mutates it. Production reads it through `MemoryService.brain(of:)` (cached per application, see
[Producers](#producers)) and changes it only through the applications register below and the
manual import.

### Mutations

Every mutation is one `store.write`, one `BEGIN IMMEDIATE`: find or create the application row,
load the active projection (`SQLiteBrainRows.load`), run the unchanged pure algorithm on it
(`BrainUpdater.ingest`, `recordTransition`, `setName`, `decay`), write the difference
(`SQLiteBrainRows.write`), commit. No `await`, no perception and no I/O between the load and the
commit; no brain is cached across calls; every read is one snapshot (`store.read`). The operations:

| Operation | Behavior kept from the pure brain |
|---|---|
| `observe(scene, now:)` | as an observation's application: every element of the scene, pixel-only and unlabeled included, as `BrainDetection`; the window is `LabelText.letters(windowTitle)`, the empty family is no scope. Accessibility completeness is not a condition: it governs structural scenes only. |
| `ingest(detections, into:, now:, window:)` | `BrainUpdater.ingest` with the same window scope. |
| `setName(name, anchorKey:, in:, now:)` | `BrainUpdater.setName`: source `llm`, the old label appended as an alias. |
| `decay(in:, now:, maxObjects:, retention:)` | `BrainUpdater.decay` with the same retention; explicit for tests, since an ingest that ticks the clock decays on its own. |
| `record(record, now:)` | `BrainMemory.record`'s rules on the raw projection: no effect teaches nothing, an element with no unique anchor teaches nothing except a menu reveal, which first ingests the element alone. It moves the counters on every call: a retry of the same action counts twice. For tests and low-level tools only. |
| `importProjection(brain, into:, now:)` | no algorithm: writes a whole `UIBrain` read from an earlier JSON file as the application's projection, for `mecum memory --import-json`, and answers false, changing nothing, when the application already has an anchor, a group or a transition. The mutation runs at the Brain's own last instant (`now` only for a Brain that saw nothing), so no row is stamped later than the file saw it. No application or evidence row is written: the imported counts are the file's. |

A producer never calls these: an action's record reaches the projection through the applications
register (`BrainApplicationStoring.apply`), keyed by the call's event, which applies one action once
whatever the retries, with the same rules. The raw `record`, `ingest`, `observe`, `setName` and
`decay` exist for the repository's own tests and for low-level tools; a new producer that used them
would count a retried fact twice. A retry of the same logical operation reuses its key (its event);
an action intentionally made again is a new call with a new event, so a new key.

The clock is a value: the repository quantizes it once to its canonical millisecond
(`BrainClock.canonical`, nearest millisecond, ties away from zero) and runs the algorithm on that
`Date`, so every stored instant converts back exactly. The tick of 600 s and the 365-day backstop
move by at most half a millisecond against an unquantized clock; no threshold changes. An instant
outside +/-2^50 ms or not finite is `BrainProjectionError.clock`, never clamped. No round trip is
claimed for an arbitrary sub-millisecond `Date`.

A mutation of this raw projection is applied every time it is asked for. The serialized load
means two writers, in one process or two, never lose an update; it does not recognize the retry of
one event: a second identical call is a new evaluation and moves the counters again. A producer
applies through the application register below, which binds each application to its event or
sample and concludes it once; production calls none of `SQLiteBrainRepository`'s mutations but
the import, and shares its read, `brain(of:)`.

### Writing the difference

- Identities are the algorithm's: `anchorKey` is `anchor_id`, `SiblingGroup.id` is `group_id`
  (its `uuidString`), and a transition, which has no identity in the brain, gets a technical
  `transition_id` when its row is created, found again by its (anchor, trigger, effect) triple
  among the active rows. `BrainKeys` (default random UUIDs, as before) names what an ingest
  creates; tests inject deterministic keys.
- Orders: a new anchor, group or transition takes `max(insertion_order) + 1` over every row of the
  application, retired ones included, so a retired position is never reused. Aliases, members and
  menu items keep `position`; a reordered list is first shifted past every final position and then
  renumbered, so `UNIQUE(position)` holds at every statement.
- Order of statements: application clock and window clocks; groups (inserted or changed); anchors
  (inserted or changed, with aliases and states), whose `current_group_id` names a group already
  written; memberships; transitions under the application's scope; retirements last. Foreign keys
  stay on throughout.
- Only what changed is written. Nothing is deleted except an alias, a state, a membership or a
  window clock the algorithm itself removed. Rows outside the projection (scenes, observations,
  events, evidence, Routes) are never touched.
- Removal is retirement: `retired_at_ms` (the mutation's clock), `retired_epoch` (the brain's
  `ingestEpoch` after the mutation) and `retirement_cause` together, from `DecayReport`, which
  `decay` fills as it evaluates its rules, so a row that breaks several is reported by the first
  rule the algorithm checks: an anchor `backstop`, then `stale`, then `transient`, then `cap`; a
  group `members` (fewer than three left), then `stale`, then `backstop`; a transition `anchor`
  (its anchor went), then `backstop`, then `stale`, then `coincidence`. A dropped row without a
  reported cause is
  `BrainProjectionError.unexplainedRemoval` and the mutation is rolled back. A retired row keeps its
  aliases, states, memberships and every reference to it; a dissolved group keeps its last
  membership as history. A row that reappears is a new identity with the state it shows now.
- `status` of a transition is a cache of `LearnedTransition.isTrusted` (`trusted` at evidence two or
  for a menu reveal, else `candidate`), rewritten with the evidence; retirement is separate from it.
  `evidence_count` is the projection's counter, not a count of `brain_evidence` links.

### Field by field

| Swift field | Column or derivation | Null and order |
|---|---|---|
| `UIBrain.objects`, `.groups`, `.transitions` | active rows of `brain_anchors`, `brain_groups`, `brain_transitions` | `ORDER BY insertion_order`, retired rows excluded |
| `UIBrain.ingestEpoch` | `brain_apps.ingest_epoch` | not null |
| `UIBrain.lastEpochAdvance` | `brain_apps.last_epoch_advance_ms` | NULL is nil |
| `UIBrain.windowEpochs` | `brain_app_window_epochs`, one row per family | a dictionary: no order |
| `ObjectAnchor.anchorKey` | `brain_anchors.anchor_id` | the same text |
| `.kind` | `kind` (`ElementKind` raw value) | unknown code refused |
| `.label` | `label` | empty text is a label never given, not NULL |
| `.labelSource` | `label_source` | NULL is nil |
| `.aliases` | `brain_anchor_aliases(alias, position)` | `position` 0, 1, ... |
| `.boundsTypical` | `typical_x`, `typical_y`, `typical_width`, `typical_height` | four finite REALs, written and read as the same `Double`; NaN or infinity refused both ways |
| `.statesSeen` | `brain_anchor_states(state, seen_count)` | a dictionary |
| `.groupID` | `current_group_id` (FK per app to `brain_groups`) | NULL is nil; not derived from `brain_group_members` |
| `.seenCount`, `.lastSeenEpoch`, `.window` | `seen_count`, `last_seen_epoch`, `window_family` | epoch NULL is nil; window NULL is nil, empty text is the empty family |
| `.firstSeen`, `.lastSeen` | `first_seen_ms`, `last_seen_ms` | canonical milliseconds |
| (none) | `anchor_scope` | always `control`; another value is refused on read |
| `SiblingGroup.id` | `brain_groups.group_id` | `uuidString`, refused if not a UUID |
| `.axis`, `.sharedKind`, `.name` | `axis`, `shared_kind`, `name` | name NULL is nil |
| `.cellSize` | `cell_width`, `cell_height` | finite REALs |
| `.memberAnchors` | `brain_group_members(anchor_id, position)` | `position` 0, 1, ...; only active anchors of an active group are read |
| `.seenCount`, `.lastSeen`, `.lastSeenEpoch` | `seen_count`, `last_seen_ms`, `last_seen_epoch` | |
| `LearnedTransition.anchorKey`, `.trigger` | `anchor_id`, `trigger_kind` | `scene_element_id` and `menu_command_id` NULL |
| `.effect` | `effect_kind` and `effect_text`, `required_target_state`, `resulting_target_state`, `brain_transition_menu_items(position, title)` | see below; the string is never stored |
| `.evidence` | `evidence_count` | |
| `.lastObserved`, `.lastObservedEpoch` | `last_seen_ms`, `last_observed_epoch` | epoch NULL is nil |
| (none) | `transition_id`, `first_seen_ms`, `status` | technical id; the instant the row was created, never moved; cache of trust |
| (none) | `from_scene_id`, `to_scene_id` | the application's scope (`scene_kind = 'app'`, created with the first transition); destination NULL, unknown |

Effects (`TransitionEffectRecord`, six families): `windowTitleChanged` keeps the title in
`effect_text`; `stateFlip` keeps the direction in `required_target_state` and
`resulting_target_state`; `menuOpened`, `elementsAppeared` and `elementsDisappeared` keep their
labels as ordered item rows, none for an empty list; `textSelectionChanged` is its family alone, with
no text, state or item. `brain_transitions.effect_kind` has no CHECK of its own: the vocabulary is
`TransitionEffectRecord.kinds`, checked on the way in and out. The string `LearnedTransition.effect` holds is rebuilt in memory with
`SceneEffect.encoded`. An effect string the vocabulary cannot decode, or one that would not rebuild
to itself (an empty label beside others, which the separator loses), is
`BrainProjectionError.unrepresentableEffect`, refused before the commit with everything else the
mutation did. A label containing `|` is already split by the string the brain stores today; the
projection keeps what the brain has. On read, a family the vocabulary does not know, a value in a
column the family leaves NULL, a missing title or state, items under a scalar family,
non-contiguous positions, a `status` that contradicts the derived trust, a source other than the
application's scope and two active rows with one triple are all refused.

The app scope and structural scenes stay apart: the scope is the one `scene_kind = 'app'` row of
the application, never read by `SQLiteSceneRepository` as a candidate, never given elements, roles,
labels, associations or evidence (the triggers above); the structural scenes and associations of the
observation contract are untouched by every brain mutation. The brain learns from the scene's
elements, not from its sample: a scene without an accessibility read still teaches its anchors, and
no brain mutation creates a scene, a sample or an event. (In production `CallRecorder` writes the
sample beside the mutation, with the quality the capture measured, which is not complete, so it
creates no structural scene.)

Limits declared: a clock that runs backwards against stored rows (a `lastSeen` earlier than a
`firstSeen`, a retirement earlier than a last sighting) is refused by the file's `CHECK`s as a
contract error, where the JSON brain would have stored it; a NaN or infinite bound or cell size is
refused, where the JSON brain would have stored it; a mutation whose body is retried after a busy
lock draws fresh keys, which only a test's deterministic sequence can observe. `menu_command_id`,
`scene_element_id`, structural `from_scene_id` and `brain_evidence` links stay unwritten by this
projection.

## The brain's applications

`SQLiteBrainApplicationRepository` (`BrainApplicationStoring`, the role in `Memory`) applies an
observation, a record or a naming to the projection once per key, durably, and is the path
production uses: `CallRecorder` queues an observation's and an action's commands. The naming
(`set_name`) has no producer. `BrainApplicationCommand` is the call normalized once: key, bundle id, the
requested instant as a canonical millisecond, and every input the current algorithm reads.

### Keys and versions

| Operation | Key | Built from |
|---|---|---|
| `observe` | event + `observe` + phase + sample ordinal of a real capture row | `BrainApplicationCommand.observe(scene, sample:, requestedAt:)`: every element as `BrainDetection` (pixel-only and unlabeled included), window `LabelText.letters(title)`, empty family nil, as `BrainMemory.observe` |
| `record` | event of the action + `record` | `.record(actionRecord, eventID:, requestedAt:)`: verb, the target's detection, the effect as `TransitionEffectRecord` or none |
| `set_name` | event of the naming call + `set_name` | `.setName(name, anchorKey:, in:, eventID:, requestedAt:)`: the name as given, the key as a literal |

Two samples of one event (before and after, two ordinals) are two applications; the same key
offered again is the same one. Two keys are one only when their event ids are the same bytes and
their operation, phase and ordinal match: `BrainApplicationKey`'s equality and hashing read the
id's UTF-8, as the file's binary TEXT keys do, so two canonically equivalent ids (`café`, composed
and decomposed) are two keys and two applications; no id is normalized. Nothing in the key is content, a digest, a clock or an identifier
drawn at retry. Each application records `contract_version` (the arguments' contract, 1) and
`algorithm_version` (`brain-updater-1`); neither is in the key, so a new algorithm does not re-apply a
concluded event: offering it under another version is a conflict, the version compared as bytes like every text of
the contract. Decay is no operation: it runs
inside the ingest that ticks. `BrainStoring.decay` stays for low-level tests.

### One transaction

Inside one `store.write`: the event must exist, belong to the command's application and, for a
record or a naming, be an action (`BrainApplicationError`); the key is looked up; a concluded
application is compared exactly (key and bundle id as bytes, requested instant, versions, every argument with
texts byte for byte, numbers as IEEE values, lists in order; `hasSameInput(as:)`) and answers its
stored outcome as `alreadyApplied`, or `MemoryStoreError.identity` with nothing changed; a new one
needs its sample's capture row, loads the projection under the same lock, fixes the effective
instant, runs `BrainUpdater` through the same synchronous body the raw repository uses
(`SQLiteBrainRows.mutate`), and writes the difference, the evidence, the arguments and last the
application row. An application that changed nothing (no effect, no anchor, an empty ingest, an
unknown anchor named) is concluded the same way. A failure rolls everything back: no application,
argument, evidence or difference remains, and the same command applies once later. Digests
(`inputDigest`) only fill the conflict report.

### Register, arguments and outcome

`brain_applications` holds one row per concluded application: `application_id`, `app_id`,
`event_id` (FK per app to `memory_events`), `operation`, and for an observation `phase`,
`sample_ordinal`, `sample_observation_id` and `sample_kind = 'capture'`, together a composite key to
`memory_event_observations(observation_id, event_id, phase, sample_ordinal, observation_kind)`, so
the sample must be the capture row of that event, phase and ordinal (another event, another phase
or a field row is refused, and the referenced row can neither move nor go); the versions;
`requested_at_ms` and `effective_at_ms`; and the outcome. Uniqueness is two partial indexes with no
NULL column: (event, phase, ordinal) for observations, (event, operation) for the others. A trigger
requires a record's or a naming's event to be an action and a recorded transition to be the
recorded anchor's.

| Outcome (`outcome`) | Operation | Required | Forbidden |
|---|---|---|---|
| `observed(created:, updated:, skippedAmbiguous:)` | observe | `created_count`, `updated_count`, `skipped_ambiguous_count` | `anchor_id`, `transition_id`, `evidence_count` |
| `noEffect` (`no_effect`), `noAnchor` (`no_anchor`) | record | — | every outcome column |
| `recorded(anchorKey:, transitionID:, evidence:)` | record | `anchor_id` and `transition_id` (FKs per app), `evidence_count` ≥ 1 | counts |
| `named(anchorKey:)` | set_name | `anchor_id` (FK) | counts, `transition_id`, `evidence_count` |
| `notNamed` (`not_named`) | set_name | — | every outcome column |

The decay an ingest ran is not part of the outcome: its `DecayReport` belongs to the raw projection
and its tests.

The input is stored in `memory_operation_arguments` under a third owner, `brain_application_id`:
exactly one of `operation_id`, `event_id` and `brain_application_id` per row; for this owner
`app_id` is required, `route_id`, `parameter_id`, `anchor_id` and `menu_command_id` are forbidden
and values are text, integer, real or boolean; `(app_id, brain_application_id)` is a composite key
to the application deferred to the commit; `(brain_application_id, argument_name, position)` is
unique. The contract (`BrainApplicationContract`, version 1), checked on the way in and on the way
out:

| Operation | Argument | Type | Rows |
|---|---|---|---|
| observe | `detection_count` | integer | one |
| | `window` | text | at most one; absent is nil, empty text is the empty family |
| | `detection_kind`, `detection_label` | text | one per detection, positions 0 ..< count; the empty label is a label |
| | `detection_x`, `detection_y`, `detection_width`, `detection_height` | real | one per detection, finite |
| | `detection_state` | text | at most one per detection; absent is nil |
| record | `verb` | text (`ActionVerb`) | one |
| | `target_kind`, `target_label`, `target_x` … `target_height` | text, real | one each |
| | `target_state` | text | at most one |
| | `effect_kind` | text | at most one; absent is no effect |
| | `effect_text`, `effect_required_state`, `effect_resulting_state` | text | at most one each, only with a kind |
| | `effect_item` | text | a list at positions 0, 1, ...; only with a kind |
| set_name | `anchor_key` | text | one; a literal, which need not name a stored anchor |
| | `name` | text | one, as given |

Sealing: the arguments are written first and the application row seals them: its insert requires
them, and an argument for an application already written is refused; header and arguments are
never updated or deleted. No row is pending after a commit. A REAL `-0.0` comes back from SQLite as
`0.0` (its integer storage of whole reals); the comparison of numbers is IEEE, so the two are the
same input: a choice of numeric equality for the geometric arguments, apart from texts, which stay
byte for byte. On the way out `detection_count` is a stored value, not a size: it must equal the
detections the rows hold before anything is allocated or iterated for it, so a count no row supports
is `malformedApplication(.detectionCount(declared:found:))` whatever its magnitude (`Int64.max`
with no row included), and the reader and the store go on.

### The application's clock

`effective_at_ms` = the latest of the requested instant, the application's last `effective_at_ms`,
and every instant the active projection holds: anchors' `first_seen_ms` and `last_seen_ms`, groups'
`last_seen_ms`, transitions' `last_seen_ms` (their `first_seen_ms` is never later), and
`last_epoch_advance_ms`. The algorithm runs at it, so no `CHECK` on time is broken by a late
command, a command after another process's or a projection a raw fixture wrote later; no
millisecond is added, so the same instant is no new tick. `memory_events.occurred_at_ms` and
`monotonic_ns` stay as recorded; the register keeps both instants; a retry answers the stored ones
and recomputes nothing. A requested instant outside the clock's range or not finite is refused when
the command is built. Production asks at the Brain's clock (`MemoryClock.brainNow()`, a reference
plus monotonic time), read once when the call's recorder is made, so every application of one call
carries the same requested instant.

### Evidence

In the same transaction, one `brain_evidence` `supports` link per row the algorithm's own counters
justify, unless the event already supports it: an observation supports the anchors it created or
whose `seen_count` it raised and the groups it created or merged; a record supports the transition
whose `evidence_count` it created or raised and the anchor a menu reveal created for it. Nothing
else: a refresh of ambiguous candidates (their dates only), a menu revealer's epoch, a naming, a
record without effect or anchor, a tool error. No `contradicts` is inferred. `assessed_by` is
`brain.<operation>`, `assessment_version` the algorithm version, `assessed_at_ms` the effective
instant. A row created and dropped in one mutation has no row and no link. Two samples of one event
move the counters as the algorithm does and leave one link per target. Counters are never
recomputed from links.

## Producers

Production reaches the archive through `MemoryService` (`Sources/Integration/AutomationRuntime`),
which conforms to `BrainReading` and `BrainApplicationStoring` and hands its queued writes the
repositories of the open archive (`MemoryRepositories`: captures, scenes, calls, brains,
applications, graph, traces). This section is what the service and its recorders do on this
branch; the tables they fill are listed in
[the memory contracts](MemoryContracts.md#what-production-writes-today).

### One service per directory

`MemoryService.shared(for:)` hands every runtime, session, tool and command of the process the same
service for the same Knowledge directory (the path standardized with its symbolic links resolved):
one `memory.sqlite`, opened on first use as a producer, so the process has one writer per archive.
No session and no command closes it. A session's close waits, within 3 s, for what is queued
(`EngineRuntime.finish()`, `flush(within:)`); the process closes every service once at its end: the app
at quit (`SeatReleasingDelegate`, `MemoryService.closeAll()`, the step bounded at 4 s) and `mecum` after
its command (`main.swift`). Two processes on one directory are two services and two writers on one
file, which the store's lock keeps apart.

### Closing

`MemoryService.close()` closes once, whoever asks and however often; a second call waits for the
first one's end. `closingBudget` (3 s) bounds the whole close, from the first call to its return, on
the monotonic clock:

1. **Admission ends at the first call**, before it gives the actor back: a write offered from then
   on is refused and counted as dropped; `ready()` and every read or open that goes through it
   (`brain(of:)`, `apply`, `overview()`, …) throw `MemoryUnavailable("the memory is closing")`; no
   copy and no recovery start. Only the writes already accepted run on, and the drain may still open
   the archive for them.
2. **The copy in progress is cancelled.** The store sees the cancellation between two steps, and once
   more after the verification and before the rename, so a copy is handed over only by a snapshot
   nobody stopped; the partial file is removed, and the next open takes the day's copy again.
3. **The queue drains until the last fifth of the bound** (at most 500 ms of it, so 2.5 s of 3 s), a
   busy archive waited out meanwhile. What is still queued then never ran and is counted as dropped;
   the running write is cancelled, which a lock wait and a cooperative body see at once.
4. **The archive is closed by a task of its own**, and the close waits, until the deadline, for it, for
   the running write to end and for the copy to let go of its connections.
5. **At the deadline the close returns, whatever is left.** It never waits past it: an operation that
   holds the store's actor synchronously (a long transaction body, a copy's step or verification, the
   checkpoint the library runs when its last connection closes) finishes after the return, the archive
   closes when it ends, and the presence lock is let go then, or by the kernel with the process.

Each write is counted once, by what it committed: the store counts the commits of the task that runs
it (`SQLiteMemoryStore.CommitTally`). `written` ended without an error; `failed` ended with an error
before any commit, so the archive holds none of it; `partial` ended with an error after a commit (a
queued write may hold two transactions, a call's `planned` and its `started`), so the archive holds a
part; `dropped` never ran. A write still running at the deadline is `unsettled`: it may still commit,
so its outcome is unknown when the close returns; if it ends later in the process it leaves
`unsettled` for the count it ended in. `status().lastClose` says how long the close took, the counts,
what the deadline left (writes queued, the write running with the commits it had made, the copy, an
archive still closing), and the log says it too, as an error when anything was left.

`MemoryClosingTests` measures each case against a 1 s bound with 150 ms of tolerance for the polling
and the actor hops, and prints each measure (`MEMORY-CLOSE`). In an ordinary close every write is
saved: two hundred in under 0.1 s. A write held by a lock past the bound is cancelled and failed, the
rest dropped; a write suspended before its commit is failed, after it partial, and its row is in the
archive; a transaction that holds the store for 1.6 s leaves the close at the bound, the write
unsettled, then written once it commits, and the presence lock held until the store closed. The
writes are in the process's memory only: those a lock keeps past the bound are gone with the process,
counted; a durable queue would be another design.

The app takes the bounded path of Quit whenever `MemoryService.hasUnfinishedWork` says a service still
holds writes not committed or a copy in progress, even with no worker, draft or client to wait for: it
does not wait for the actor, so Quit decides without blocking.

The app's workers and its Brain page share the app's Knowledge directory (`Knowledge` under
`WorkspaceLaunch.directory`, by default `~/Library/Application Support/Mecum`). Each external MCP client
has a directory of its own, as on main: `MCP/Knowledge/<profile>` under the same support directory
(`AppModel.knowledgeDirectory(of:under:)`), so each client writes and learns into its own
`memory.sqlite`, apart from the workers' and the other clients'
(`MemoryWiringTests.privateArchivesPerClient`). `mecum` and `mecum chat` default to the workers'
`~/Library/Application Support/Mecum/Knowledge` and take `--knowledge <dir>`, so a running app and a
`mecum` process are, by default, two writers on one file.

### The queue

A producer `enqueue`s a write and goes on: the call returns once the write is in the queue, never
after it ran. One task of the service runs the queued writes one after another, in the order they
were enqueued, so a sample follows its event and a call's end its start; there is no other order
between producers. Each queued write may hold several repository transactions (a call's `planned`
and `started` are two). A busy archive is waited out by that task alone, through the store's
ordinary `write`. A write that fails (the archive cannot open, a constraint, a conflict, a record
the contract refuses) is counted and logged with a sentence that carries no content of the agent's,
never retried and never thrown at the producer: it is a gap, visible in `status()` as `failed` and
`lastFailure`. A queue that already holds `queueLimit` writes (4096) drops what arrives and counts
it as `dropped`. The queue is in memory: a process that ends without its closing flush loses what
it held, with nothing in the archive to say so.

`status()` reports the path, the state (`notOpened`, `open`, `degraded` with its reason, `closed`),
the linked library's version and source id, and the writes pending, in flight, written, failed,
partial, dropped and unsettled since the service was made ([Closing](#closing)), with the last failure,
the newest copy, the last recovery and the last close. These counts live in the process: another
process, `mecum memory --status` among them, cannot read them ([Diagnosis](#diagnosis)).

### Degraded

An open that fails (a schema this build refuses, a library too old, a path that cannot be created)
degrades the service with its reason; the next open is tried only after `reopenInterval` (5 s), and
meanwhile reads throw `MemoryUnavailable` and queued writes fail as counted gaps. Nothing resets or
replaces a refused file (`MemoryWiringTests.refusedArchiveDegrades` checks it byte for byte). Only an
open degrades the service: a write that fails leaves it `open`, and so does a store that went
`failed` after a cleanup it could not complete ([Failure, cleanup and recovery](#failure-cleanup-and-recovery)).

### Reading the Brain

`brain(of:)` reads an application's projection and keeps it, per application, while the reader's
`PRAGMA data_version` has not moved; any commit by this process's writer or by another process moves
it, and the next read loads the projection again. `BrainMemory` reads through it for the engine's
expectations and for enrichment; a read that fails answers no opinion, so neither can fail an
action. A read does not wait for the queue: under contention it can miss what the last action
taught until the queue drains.

### Observation

`CallRecorder.observe` queues the `current` sample and the Brain's ingest of it, then waits for the
queue to empty, at most `CallRecorder.observationBudget` (50 ms), before it enriches the scene from
the Brain. Past the budget the enrichment is one observation behind; the call is never held longer.

### Copies and recovery

From `52523ae` the archive keeps itself recoverable. Once a `backupInterval` (one day), checked when
the archive opens and whenever the queue empties, the service takes a verified copy through
`snapshot(to:)` beside the archive, `memory.sqlite.backup-<UTC instant>`, and keeps the newest
`keptBackups` (3). The copy runs beside the writes and never holds them up; a close cancels one in
progress ([Closing](#closing)). A copy taken at the open is the archive as it was opened.

An open that fails because the library calls the file corrupt (`SQLITE_CORRUPT`, 11) or not a
database (`SQLITE_NOTADB`, 26) asks `SQLiteMemoryRecovery` to recover it, which does so only under the
archive's presence lock taken exclusive ([The presence lock](#the-presence-lock)):

1. While anybody else holds the archive, the recovery is refused at once (`inUse`): nothing is read,
   moved or copied, the service stays `degraded` ("the recovery was refused and nothing was moved")
   and tries again after `reopenInterval`.
2. Under the lock the archive is read again, as the open reads it. Another process may have recovered
   it since the error that led here: a file that now reads, or fails for another reason, is left as it
   is (`notCorrupt`) and opened as it is.
3. The newest copy that passes `quick_check` and has this build's schema is chosen before anything
   moves, and the recovery writes its record, `memory.sqlite.recovering`: the name the files move to
   and the copy chosen, or none. The record is synced and renamed into place, and the directory synced,
   before anything moves.
4. The `-wal` and `-shm`, then the file, are moved aside as `memory.sqlite.corrupt-<UTC instant>`, never
   deleted; the chosen copy is cloned beside the archive's place and renamed into it without
   clobbering, then read once more. With no sound copy the memory starts empty.
5. The record is removed: only then is the recovery complete. The lock is let go and the store opens as
   any opener does, taking the lock shared. Whoever took it in between finds a sound archive and leaves
   it.

A recovery that stops half way (a process killed, a copy that cannot be read or put in place) leaves
its record. While the record is there no store opens the archive and none makes an empty one: every
open answers `MemoryStoreError.unavailable(.interruptedRecovery)`, with what the record holds. The next
recovery, which the service asks for on that answer, completes it from the record alone, never
choosing another copy: a file at the archive's place that is the recorded copy byte for byte was
published and only the record is left to remove; a file that is not the copy and does not read is the
original, moved aside as recorded; a file that reads as an archive and is not the copy is not one the
recovery made, so it refuses. A recorded copy that is gone or does not read, or a destination already
taken, is refused too: the service stays `degraded` saying why ("cannot be completed", "every file is
kept") and tries again after `reopenInterval`; nothing is guessed and nothing is deleted. A recovery
with no copy completes as one that starts the memory empty and says so: only then does an open make
the empty archive. A directory that never had an archive has no record, and its first open makes the
archive as before.

`status().lastRecovery` says which happened, a completed interruption included. `MemoryWiringTests`
proves the daily copy, the restore, the empty start, the refusal while held, and a stopped recovery
that the service first refuses (its copy unreadable) and then completes. `SQLiteRecoveryCoordinationTests`
proves, with real processes, the refusal while another process holds the archive open (its later
writes land in the same file), two recoveries that both saw the old error (one recovers, the other is
refused while it works and then leaves the recovered archive as it is, while an open waits and a
diagnosis reads nothing), a killed holder leaving no lock, and a copy that still holds the archive
after its store closed. `SQLiteRecoveryInterruptionTests` (T13b) kills a real recovering process after
its record, after the files moved and after the copy was published, makes the copy unreadable once
the files moved, and restarts two processes at once: in every case the opens refuse or wait, none
makes an empty archive, and the next recovery completes with the copy's event, sample and Brain; a
new directory still makes its archive, and a corruption with no copy starts empty saying so.
Restoring the rest of the app (its workspace, its conversations) is outside the memory.

### The presence lock

Every participant that holds the archive's files open takes `flock(2)` on `memory.sqlite.lock`
beside it (`SQLiteMemoryPresence`), made on first use and never moved or deleted:

- **A store** takes it shared before its first connection and lets it go once its last connection
  closed, those of a copy still in flight included, and only when it is no longer open or opening. An
  open that finds it held exclusive waits within one lock budget, as for a busy lock, then answers
  `contention` at the open ("a recovery … holds its presence lock"). A reader of an archive that is not
  there makes no lock file.
- **A diagnosis** takes it shared for the time of its reading ([Diagnosis](#diagnosis)).
- **A recovery** takes it exclusive without waiting, and is refused while anybody holds it.

The lock belongs to the open file, not to the process, so two holders in one process exclude each other
as two processes do; the kernel lets go of the lock of a process that ended. It coordinates only the
code that takes it: a build before it, or a tool that opens the file itself (`sqlite3`), is not
coordinated, and `flock` is not reliable on a network volume. The lock file holds no data.

### Diagnosis

`mecum memory --status [--knowledge <dir>]` (`SQLiteMemoryInspection`) says what the archive file is
without opening a memory service: whether it is there, its size and its log's, its `user_version`,
what this build's open would make of it, and, when the open would take it, a few row counts; then the
copies and the files a recovery moved aside. It reads with a read-only connection and the library's
locks, all in one read transaction, so version, shape and counts are one committed state even while
another process commits (`SQLiteMemoryInspectionTests.oneCommittedState`); it never opens a file as
`immutable`. It takes the presence lock shared first, so it never reads while a recovery moves the
files, and says so instead.

| What it finds | What it prints |
|---|---|
| no file | no archive at this path; Mecum's memory would create it. No lock file is made. |
| a database with no schema | Mecum's memory would create its schema in it; a reader refuses it |
| this build's version and exactly its shape | it opens it, with the counts |
| a newer version | refused and left as it is: schema N is newer than this build's; its shape is not compared |
| another shape, tables missing, columns missing, somebody else's tables | refused and left as it is, with the objects named |
| not a database | not readable, with the library's reason |
| a recovery holding the archive | not read: a recovery holds it |
| a WAL file whose `-wal` and `-shm` are not beside it | not read: a read-only reader cannot make them without changing the directory |
| the record of a recovery that stopped | not read: what the record holds; the memory opens nothing until a recovery completes it |

It never creates the archive, bootstraps, migrates, recovers or copies. The only file it may make is the
empty lock file beside an archive that a build with the lock never opened. The library may update the
`-shm` index while reading, as for any reader; it holds no data. The counters of writes live in each
process: this command has its own and shows none; the app shows its own on Settings > Brain.

### Recorders

A `CallRecorder` writes one call: the call itself when a producer begins and ends it, the
perceptions the engine reports as samples, and the Brain's learning. It is the engine's
`ActionObserving` for the call (`EngineRuntime.engine(recorder:…)`), and `CallRecorder.current`, a
task-local value, carries it to a session without a parameter. Every write goes through the queue.

| What the recorder is given | What it queues |
|---|---|
| `begin(request, app:)` | the call's `action` event and its request, `planned`, then `started` at the calendar instant |
| `begin(batch:app:)` | the batch with its steps, `planned` together, then the batch `started` |
| `startStep()`, `skip()` | a step's `started`, or `skipped` for a step that never ran |
| `end(status, result:, tool:)` | the call's end with the tool's result, the monotonic duration since its start and, for a completed `act`, `select` or input, the effect the engine attributed |
| an `ActionRecord` | the event when no call wrote one, the `before` and `after` samples with their scene associations, and, when the action had an effect, the Brain's `record` application |
| an `InputRecord` | the event when needed, and the `before`, `menu` and `after` samples; an input teaches the Brain nothing |
| `observe(window)` | the `current` sample under the call's event, or under an `observation` event of the scene's application whose `origin_event_id` is the call when the call's event names another application or none (`open_session`), and the Brain's `observe` application |

The Brain's applications are asked for at the instant the recorder was made
(`MemoryClock.brainNow()`), so the same facts offered again are the same command.

| Producer | Source | Stream | Trace | Records the call |
|---|---|---|---|---|
| The app's worker (`TeamModel`, `WorkerAgentHost`) | `app` | `worker-<worker id>` | the message the turn answers | yes, through `AutomationTools` |
| An external MCP client served by the app (`ExternalMCPSession`) | `mcp` | `mcp-<profile id>` | none | yes, through `AutomationTools` |
| `mecum chat` (`ChatCommand`) | `cli` | `chat-<conversation id>` | the conversation | yes, through `AutomationTools` |
| `mecum scene`, `act`, and a `batch`'s `act` steps (`commandLineRecorder`) | `cli` | `mecum-<pid>` | one per process | no: an `action` event, its samples and the Brain's learning |
| A session's call outside a recorded tool call | `system` | `session-<session id>` | none | no: an `action` event, its samples and the Brain's learning |

The last row is the fallback `AutomationSession` and `BrokeredAutomationSession` use when no
`CallRecorder.current` is set, for example during a tool call the contract could not represent. The
command line's `select`, alone or in a batch, writes nothing.

## Agent calls

`SQLiteAgentCallRepository` (`AgentCallStoring`, the role in `Memory`, `Memory/Calls`) keeps the
agent's tool calls: the event in `memory_events`, the call in `memory_agent_actions`, its arguments in
`memory_operation_arguments` under the event as their owner. It keeps facts only: it runs no tool,
replays nothing and does not decide on its own to skip or interrupt a call.

In production `AutomationTools.dispatch` records every call it answers when its session names a
memory directory (`AutomationSessionOperating.memoryDirectory`) and its arguments make an
`AgentCallRequest` (`AutomationTools.callRequest`, built from the arguments `answer` decodes the same
way). It makes a `CallRecorder` under its `CallProducer` and the session's id, queues the call
`planned` and `started` before the tool runs, runs the tool with the recorder as
`CallRecorder.current`, and queues the end: `completed` with the result the tool represents, or
`failed` with the error it threw. A refusal the tool raises after decoding (a stale session id, a
refused permission) is a recorded `failed` call; a request the contract cannot represent is not
recorded at all, and the call runs as it would without memory. A batch is recorded with its steps
([States and results](#states-and-results)). No producer writes `cancelled` or `interrupted`: a
cancellation that reaches the tool ends the call `failed` with its error, a batch cancelled between
steps ends `failed` with its later steps still `planned`, and a call whose process ends between its
start and its end stays `started`; nothing sweeps it later. None of these writes is awaited by the
tool, and a write that fails is a counted gap, not an error of the call.

A call of any of the seventeen tools is an `action` event, the six input tools included; an `input`
event is a gesture the Watcher saw. The session a tool names is the event's `session_id`, required
for every tool but `status`, `windows`, `apps` and `open_session`; it is not an argument. A call that
takes a session but has none (no open session) cannot be recorded and is a counted failure. The
event's application is the session's application when the call began (`memoryApplication`), unknown
before an open; nothing resolved later rewrites the event.

### The seventeen signatures

The signatures are main's (`AutomationTools.definitions`, unchanged by the merge); the contract's
form of each is `AgentCallArguments.specs(of:)`. Defaults are written once, as the tool fills them,
and never recomputed; an absent optional is no row; a list is one row per item at positions 0, 1, …;
codes are the tools' tokens, compared as bytes.

| Tool | Arguments as decoded (default) | Rows (`argument_name` kind, rows) | Reader | Tests |
|---|---|---|---|---|
| `status` | none | none | `call`, `calls(inTrace:)` | `AgentCallContractTests`, `AgentCallRepositoryTests.signaturesRoundTrip` |
| `windows` | `app` optional | `app` text, 0..1 | same | same |
| `apps` | `query` optional | `query` text, 0..1 | same | same |
| `open_session` | `app`, `window` optional (an empty title is kept as the empty text) | `app` text 1; `window` text 0..1 | same | same |
| `observe` | session, `full` (false) | `full` boolean 1, written even when it defaulted | same | same |
| `act` | `target`, `verb` (`click`), `value` on/off only and always with `set_toggle`, `section` optional | `target` text 1; `verb` text 1; `value` text 0..1; `section` text 0..1 | same | five verbs, `set_toggle` on and off |
| `select` | `control`, `item` | `control`, `item` text 1 | same | same |
| `type_text` | `target`, `text`, `section` optional, `replace` (true) | `target`, `text` text 1; `section` text 0..1; `replace` boolean 1 | same | Unicode, NUL, `replace` false and default |
| `insert_text` | `text`, `expected_value` optional | `text` text 1; `expected_value` text 0..1 | same | same |
| `press_key` | `key` (lowercased), `modifiers` optional, `count` (1) | `key` text 1 (a `KeyChord.Name` word); `modifiers` text list; `count` integer 1 | same | ordered modifiers, default count |
| `scroll` | `direction`, `lines` (3), `target`, `section` optional | `direction` text 1; `lines` integer 1; `target`, `section` text 0..1 | same | up/down, default lines, target |
| `drag` | `from`, then `to` or `dx`/`dy` (a missing axis 0), `section` optional | `from` text 1; `to` text 0..1 or `dx` and `dy` real 1 each; `section` text 0..1 | same | target end, offset end with −0.0 |
| `context_menu` | `target`, `item`, `section` optional | `target`, `item` text 1; `section` text 0..1 | same | same |
| `batch` | session, `steps` | none: each step is a child call (`parent_event_id`, `parent_position`), `requested_count` the number of steps | `steps(ofBatch:)` | the eight step variants |
| `menu` | `path` (a menu bar path such as `File > Save As...`) | `path` text 1 | `call` | same |
| `press` | `button` (a dialog button's title) | `button` text 1 | `call` | same |
| `close_session` | session only | none | `call` | same |

A batch's steps are `act`, `select` and the six inputs (`type_text`, `insert_text`, `press_key`,
`scroll`, `drag`, `context_menu`): `AgentTool.isBatchStep`. `AgentCallRequest.input(_:section:)`
maps the engine's `InputRequest.Input` once: a scroll's signed lines become `direction` and `lines`,
a chord's modifiers their tokens in the definition's order (`cmd`, `shift`, `opt`, `ctrl`), a key its
word. The store keeps the tools' shapes, not their upper limits (20 presses, 50 lines, 5000 points,
20 steps): those are the product's. It refuses a `value` without `set_toggle` and the reverse, a
value other than on/off, a modifier twice, a count or lines below one, an offset that is not finite,
and on the way out a name, kind, position, gap, code or alternative version 1 does not admit
(`AgentCallError.malformedCall`). Texts are kept and compared byte for byte; NULL is not empty text,
false or zero; `-0.0` and `0.0` are one offset.

`tommaso/memory-model` decoded calls through a `ToolRequestDecoder` it shared with its command line
and tightened six points of the tools' schemas against it. That decoder and those schema changes
did not come over: on this branch the tools' definitions and their decoding are main's, and the
request the memory keeps is built from the same arguments by `AutomationTools.callRequest`.

### States and results

`execution_status` moves: `planned` → `started`, `skipped` or `cancelled`; `started` → `completed`,
`failed`, `cancelled` or `interrupted`. The stored state offered again is a retry; a terminal state
offered again with another result or instant, or another terminal state, is
`AgentCallError.conflictingEnd`; a regression or a skipped state is `invalidTransition`.
`advance` applies a list of moves in one transaction, all or none. `completed` means the call
concluded, not that a task or a step succeeded. Production writes `planned`, `started`,
`completed`, `failed` and `skipped`; the contract's `cancelled` and `interrupted` have no producer.

| State | `started_at_ms`, `completed_at_ms`, `duration_ms` | Result (`result_kind`, `result_message`, counts, rows) |
|---|---|---|
| `planned` | all NULL | none |
| `started` | `started_at_ms` the calendar instant the recorder began the call (`AgentCallProgress.started(atMS:)`), kept through every later state | none |
| `completed` by `act`, `select`, an input, `menu` or `press` | the calendar end; `duration_ms` the recorder's monotonic measure from its start | `ActOutcomeKind` code and message: `honest_miss`, `ambiguous`, `acted_unverified`, `acted_noop` keep their meaning; the observed effect beside it, for `act`, `select` and the inputs only |
| `completed` by `batch` | the end, the duration | `completed` or `stopped`, `attempted_count`, `verified_count`; `requested_count` from the start |
| `completed` by `close_session` | the end, the duration | `closed` and the message |
| `completed` by `status` | the end, the duration | `status`: one row of `memory_agent_action_status` (the session or NULL, the three permissions) |
| `completed` by `windows`, `apps` | the end, the duration | `listing`: one row of `memory_agent_action_listings` (the kind, the count left out), the applications in order (`memory_agent_action_applications`: name, bundle id; a windows row with its pid, an apps row with `is_running`, `app_version`, `location` and `is_default_browser`, NULL where not known) and, for `windows`, each application's windows in order (`memory_agent_action_windows`: number, title or NULL) |
| `completed` by `open_session`, `observe` | the end, the duration | `observation`: one row of `memory_agent_action_observations` (the session, its revision, the calendar instant of the answer, and the real `current` sample the scene text was rendered from, by foreign key: the call's own event for `observe`, the session's own observation event for `open_session`); none when the recorder offered no sample, an explicit gap |
| `failed` | the end, the duration when it had started | `error` and the message |
| `cancelled`, `interrupted` | the end, the duration when it had started | none |
| `skipped` | the end | none |

Times: the calendar instants are the chronology, kept as the wall said them even when it ran backwards
between the start and the end (no CHECK orders them); `duration_ms` is the recorder's monotonic
measure from `begin` (or a step's `startStep`) to `end`, never a difference of calendar instants. No
write is awaited in between, so the queue's waits are not in it. The Brain's applications are asked
for at the Brain's clock, read once per call (`MemoryClock`), which is neither of these.

`observed_effect_kind` is the family of the effect the engine attributed to a `completed` action or
input (`ObservedEffect`, built from the engine's `SceneEffect` without passing through its text), one
of six: `observed_effect_text` is the title of `windowTitleChanged`, `observed_state_before` and
`observed_state_after` the two states of `stateFlip`, the labels of `menuOpened`,
`elementsAppeared` and `elementsDisappeared` are rows of `memory_agent_action_effect_labels`, in the
engine's order, an empty label a row, zero rows an empty list, and `textSelectionChanged` is its
family alone, with no title, state or label. Two menus whose labels differ only in where a separator
falls are two effects, as they are in Perception, and labels keep their bytes. NULL when the engine
attributed none, and always for `select` and `context_menu`, whose selectors report nothing to the
recorder, and for `menu` and `press`, which act outside the engine and are no batch step
(`effectForbidden`). The DDL requires each part exactly where its family has it and only on
`completed`, the labels only under a list family; the reader refuses a part off its family
(`resultShape("observed_effect: …")`) and a gap in the labels' positions. The brain's transition rows
keep their effect in `TransitionEffectRecord`'s own columns; the call store never reads them. The
start is not part of the progress a move is compared on: `AgentCall.startedAtMS` carries it, the
duration and the effect are (`AgentCallProgress.isExactly`), and a terminal move never repeats the
start (`AgentCallProgress.validate`: `startForbidden`, `durationForbidden`, `durationNegative`,
`effectForbidden`, `effectShape`, `listingShape`, `observationShape`).

A batch's steps are created with it, `planned`, after the whole group is checked (each a batch step,
a child at its position, with the batch's source, stream, trace, session and application). A step
starts only once its batch has. A batch concludes with a result only when the result is the summary
its steps allow under the current producer (`AutomationTools`, its `batch`): in position order a step
is accepted when it completed with `found_acted`, or with `acted_noop` for `act` with `set_toggle`
(not `ActOutcome.isSuccess`, which leaves that noop out); the first step that completed with any
other outcome, or failed, stops the batch, every later step is `skipped` and none is skipped before
it. `stopped` is whether a step stopped it, `attempted_count` the steps that completed or failed,
`verified_count` the accepted ones; a cancelled, interrupted or open step admits no summary. A
summary its steps contradict is refused with nothing written (`batchNotSettled`), and a stored one is
refused by the reader (`malformedCall`, `resultShape("batch summary")`), never shown as a trace. The
batch's `stopped` is its result, apart from its `completed` status; a cancelled or interrupted batch
carries no summary. The rule is the producer's, not a verdict on a step's or a task's result.

### Identity

A call is its event. The same event with the same request is `alreadyApplied` whatever state the call
reached; other arguments, tool or event content are `MemoryStoreError.identity` with nothing written;
another event under the same source key is a conflict too. An event a capture stored first is
compared and completed with the call, never rewritten: its `capture_status` and samples stay. The
events' decision lives once, in `SQLiteEventRows.record`, which `SQLiteCaptureRepository` and this
repository share. Event content is compared byte for byte (`MemoryEventRecord.ImmutableContent`), as
are sample keys (`CaptureSampleKey`) and sample content (`CaptureSample ==`, `CaptureElement ==`
and its hashing): canonically equivalent ids are two events and two samples, and a stored sample
offered again with a title, a role, a label, a path or a window role or subrole that differs only
in its bytes is a conflict. `CaptureQuality`'s own equality, Perception's, is not used for it.

Arguments of an event have no trigger of their own that seals them; they are immutable because no
API writes them after the call. Reading a trace orders calls by `local_order`, the order this store
wrote them, with `parent_position` inside a batch: not a causal order between producers. Each call of
a trace is read with its own queries; the cost is not measured.

## Menu commands

`SQLiteMenuCommandRepository` (`MenuCommandStoring`, the role in `Memory`) keeps the menu commands
a read-only enumeration found, as data: `MenuCommandRecord` in `brain_menu_commands`, its path as
ordered rows of `brain_menu_path_segments`. It runs no command, merges nothing by path, scores
nothing and chooses no command for a query; `AppKnowledge.observeMenus`, `bestMenuCommand` and
`menuSuggestion` stay as they are, and no menu recall is implemented. Nothing in production calls
it: the `menu` tool records its call with the path as text, and writes no menu command.

| `MenuCommand` field | Column or rows | Producer | Reader | Tests |
|---|---|---|---|---|
| (identity) | `menu_command_id`, chosen by the producer; `app_id` from the bundle | `MenuCommandRecord(menuCommandID:bundleID:command:)` | `menuCommand(_:)`, `menuCommands(of:pathKey:)` | `MenuCommandRepositoryTests` |
| `path` | `brain_menu_path_segments` (`position` 0 ..< n, `title`), at least one | the record's `path`, in order | the segments by position, contiguous | `roundTrip`, `collidingKeys`, `malformedRows` |
| `key` | `path_key` = the path joined with `/`, written by the store | derived (`pathKey`) | must equal the joined path; a hint for `menuCommands(of:pathKey:)` | `collidingKeys`, `malformedRows` |
| `topLevelTitle` | `top_level_title` | as given | text | `roundTrip` |
| `identifier` | `accessibility_identifier`, NULL when absent | as given; never an identity | text or NULL | `roundTrip`, `collidingKeys` |
| `hasSubmenu` | `has_submenu` 0/1 | as given | flag | `roundTrip`, `oldConsumers` |
| `enabled` | `last_observed_enabled` 0/1 | as given | flag | `roundTrip` |
| `markChar`, `cmdChar` | `mark_char`, `cmd_char`, NULL when absent | as given | text or NULL | `roundTrip`, `recordIdempotency` |
| `firstSeen`, `lastSeen` | `first_seen_ms`, `last_seen_ms` | `BrainClock.milliseconds(of:)`, once | `BrainClock` range checked, then the canonical `Date` | `roundTrip`, `MenuCommandRecordTests` |

The identity is the id. `MenuCommand.key` joins the path with `/`, so `["A/B", "C"]` and
`["A", "B/C"]` share a key: the previous model's merge keeps one of them, and stays as it is; the
store keeps two records, both found by the key as a hint. An accessibility identifier is not
evidence of identity: an application may give one identifier to many items. Texts are kept and
compared byte for byte, an absent optional apart from an empty text, the path in order; nothing
is normalized, and no digest decides.

Sightings are canonical milliseconds: a `Date` is rounded once to the nearest millisecond, ties
away from zero, within `BrainClock.range` (±2^50 ms); a date that is not finite or is out of range
is `MenuCommandError.invalidRecord(.clock(_))`, never clamped, and a stored value out of range is a
malformed row, refused before any conversion. `last_seen_ms` is never before `first_seen_ms`.

`record` writes a command and its segments in one transaction, with its application found or
created: the same id and content is `alreadyApplied`; other content under the id, another
application included, is `MemoryStoreError.identity`, nothing written. `update(from:to:)` is the
deliberate change of the observed fields (title, identifier, submenu and enabled flags, mark,
shortcut, a last sighting no earlier than the stored one) against the record the caller last
read: the stored record must be `expected` exactly, else `staleExpectation`; the stored record
already equal to `updated` is `alreadyApplied`, the retry of that update. The id, the application,
the path and the first sighting never change (`immutableField`); a later last sighting may not go
back (`lastSeenBackwards`). Two callers updating from one read: one commits, the other is stale and
must read again, so no update is lost and no older data comes back. Nothing deletes a command, so
transitions, evidence and arguments that name it stay valid; the schema has no trigger that freezes
a command's id or application, which only the API keeps.

`menuCommands(of:pathKey:)` orders by path, segment by segment as UTF-8 bytes (a parent before its
children), then by id, apart from the order of the segments inside a path; it reads every command
of the application with its own queries, a cost not measured. A row the contract does not admit (no
segment, a gap, a `path_key` other than the joined path, a sighting out of range, invalid UTF-8) is
a typed error, never a truncated or empty path. `MenuCommandRecord.command` rebuilds the previous
model's `MenuCommand` with every field its consumers read. Per-event deduplication of a menu
observation is not offered: the schema has no register for it, and none is invented here. The
brain's projection does not read or write these tables: a mutation of `UIBrain` leaves them as
they are.

## Observed inputs, verifications and explicit attributions

Three repositories keep facts and the attributions a caller states, all on existing tables, with
no producer in production: `SQLiteObservedInputRepository` (`ObservedInputStoring`: Watcher inputs
and correlations), `SQLiteVerificationRepository` (`VerificationStoring`) and `SQLiteTaskRepository`
(`TaskAttributionStoring`: episodes, memberships, labels). They observe, correlate, judge, segment
and label nothing on their own. **The Watcher is not connected to the memory**: main's passive
listener (`InteractionListener`, `mecum watch`) reports a person's input and writes nothing here, so
every vocabulary below is this contract's proposal, proven by fixtures, not a parity with a live
report.
The schema has no contract-version column on these tables: version 1 is this build's, stated here,
not stored per row.

### Watcher inputs

An input is a `memory_events` row of source `watcher` and kind `input` (written through
`SQLiteEventRows.record`, so an event a capture stored first is compared and completed, its samples
and `capture_status` untouched) and its `memory_input_events` row, in one transaction. The same
event and detail is `alreadyApplied`; other content is `MemoryStoreError.identity`; the source key,
when present, keeps its deduplication, and without one the event id is the key.

| Column | `ObservedInput` field | Rule | Reader | Tests |
|---|---|---|---|---|
| `input_kind` | `kind` | `click`, `scroll`, `hover`, `focus`, `gap` | code as bytes | `ObservedInputRepositoryTests.kindsRoundTrip`, `.malformedRows` |
| `sequence_number` | `sequenceNumber` | ≥ 0, NULL when not numbered | integer or NULL | `kindsRoundTrip`, `EventAttributionContractTests` |
| `target_pid`, `source_pid` | `targetPID`, `sourcePID` | 1 ... `Int32.max`; facts, not identities | range checked | `ranges`, `malformedRows` |
| `window_number` | `windowNumber` | 0 ... `UInt32.max`; a hint | range checked | `ranges` |
| `window_title` | `windowTitle` | bytes, NULL apart from empty | text or NULL | `kindsRoundTrip`, `idempotency` |
| `window_x`, `window_y`, `window_width`, `window_height` | `windowFrame` | global display points, all four or none, finite, size ≥ 0 | whole or refused | `malformedRows` |
| `point_x`, `point_y` | `point` | global display points (top-left origin), finite; required for click, scroll, hover; forbidden for focus and gap | pair or refused | `shapes`, `malformedRows` |
| `delta_x`, `delta_y` | `scrollDelta` | points, `dy` positive upward; scroll only | pair or refused | `shapes` |
| `started_at_ns`, `ended_at_ns` | `startedAtNS`, `endedAtNS` | the event's monotonic clock, end ≥ start | integers | `ranges` |
| `preceding_revision`, `revision` | `precedingRevision`, `revision` | the producer's scene revisions, revision ≥ preceding | integers | `ranges` |
| `gap_first_sequence`, `gap_last_sequence` | `gap` | gap only, both, first ≤ last | pair or refused | `shapes`, `malformedRows` |
| `lost_critical`, `lost_coalescible` | `lostCritical`, `lostCoalescible` | gap only, ≥ 0; counts, never a size | integers | `ranges` (`Int64.max`) |
| `before_status`, `after_status` | `beforeStatus`, `afterStatus` | `CaptureQuality.Completeness` codes, NULL when no capture was taken; not for a gap | code or NULL | `besideCaptures`, `malformedRows` |
| `difference_status` | `difference` | `changed`, `unchanged`, `unknown`; only with both statuses | code or NULL | `shapes` |

A gap is never a gesture: it carries no window, point, delta or capture status. An absent measure
is NULL, never zero; no before is rebuilt from a later capture. Not representable in this schema,
and not packed into any text: a producer's own event type beyond the five kinds, button or modifier
details, a display identifier, the units a producer might use other than points, and per-input
capture identities beyond the samples of the event itself.

### Correlations

`memory_action_correlations`, one per Watcher input (`watcher_event_id` is the key): `agent_event_id`,
`basis_kind` (`reported`: the input's producer reported the call; `assigned`: a person or a fixture
assigned it), `time_offset_ms` (the input's time minus the call's, positive when the input came
later; NULL unknown; finite) and `explanation` (text). Both events must exist, the first a `watcher`
`input`, the second an `app`, `cli` or `mcp` `action` (the schema's triggers, checked first for a typed
`EventFactError`), and their applications must agree when both are known (`appMismatch`); an unknown
application is no contradiction and nothing is adjusted. The same correlation is `alreadyApplied`;
another attribution of the input is a conflict, never an overwrite. A correlation confirms nothing,
proves no effect and moves no count, evidence or application. No algorithm or time threshold
infers one. `correlations(ofAgentEvent:)` orders by the Watcher events' `local_order`. Both readers
check what the writer checks: a row written by hand that links events of two different known
applications, which the constraints admit, is `malformedRow(.invalid(.appContradiction))`, never a
valid trace; an unknown application stays valid.

### Verifications

A verification is a `verification` event and its `memory_verifications` row, in one transaction:
`scope` (`call`, `step`, `task`), `method` (`scene_text`, `control_value`, `control_state`, `person`),
`verdict` (`passed`, `failed`, `unknown`), `expected_text` and `observed_text` (one text each, NULL
apart from empty). These codes are proposals; no verifier in production writes them. `unknown`
stays unknown: a completed call, a correlation or a label changes nothing. The fact is compared
without `step_occurrence_id`, the attribution, which `attribute(verification:toStepOccurrence:)`
sets once (NULL to an occurrence the store holds; the same again `alreadyApplied`, another
`alreadyAttributed`), so an attribution never fails the fact's retry and never rewrites it. The
schema's triggers keep it agreeing with a `verification` membership in `memory_step_events`. No
step occurrence is created here: the tests write them by hand.

### Episodes, memberships and labels

| Table | Value | Rules |
|---|---|---|
| `memory_task_occurrences` | `TaskOccurrenceRecord`: id, `trace_id`, `started_at_ms`, `ended_at_ms`, `status` | ms within `BrainClock.range`, end ≥ start, NULL end while not known (never "now"); recorded once; `update(from:to:)` changes end and status against the record last read (`staleExpectation`), never id, trace or start (`immutableField`) |
| `memory_task_events` | `TaskMembership`: episode, event, `position`, `role` | once by (episode, event, role); the same key at another position a conflict; a position another attribution holds `positionTaken`; the role is the attribution's, not the event's kind; events of several applications or sessions allowed; read by position |
| `memory_task_labels` | `TaskLabelRecord`: id, episode, `label`, `assigned_by`, `confidence`, `status`, `assigned_at_ms` | label and author non-empty, bytes kept; confidence NULL or finite in [0, 1]; once by id; several labels side by side, none chosen; read by instant, then id |

`attribute(_:)` writes an episode, its memberships and its labels in one transaction: a last
membership that cannot be written leaves none of them. No status machine is derived from the
tools, and no label proves a success. Attribution order is not causality.

Every reader validates as the writer does and refuses with `EventFactError.malformedRow(table:id:
malformation:)` a code it does not know, a shape its kind does not have, a number out of range or
not finite, an instant out of range.

## Procedures

`SQLiteRouteRepository` (`RouteStoring`, `Memory/Procedures`) keeps procedures as definitions: a
`RouteDefinition` (its id, a name that is no identity, the definition it supersedes, its creation
instant, its parameters and its ordered `ProcedureStep`s) and its `RouteState`. It runs no Route,
resolves no target and replays nothing; publication is a structural check, not proof of
reliability. Nothing in production calls it, and no legacy `Route`/`RouteStep` is imported:
those types stay the previous model's, compared with, not copied.

| Value | Table and columns | Rule | Reader | Tests |
|---|---|---|---|---|
| `RouteDefinition` | `memory_routes` (`route_id`, `name`, `supersedes_route_id`, `created_at_ms`) | immutable; the same definition again is `alreadyApplied` whatever its state became, another under the id a conflict | `route(_:)` | `RouteRepositoryTests` |
| `RouteState` | `memory_routes` (`status`, `last_used_ms`, `demoted_at_ms`, `demotion_cause`) | `update(_:from:to:)` against the state last read (`staleExpectation`); draft → active (publication checked again), draft → retired, active → retired; last use never earlier; demotion instant and cause together | same | `publicationAndState` |
| `RouteParameter` | `memory_route_parameters` | id per file, name unique in the Route, direction `input`/`output`/`inout`, type `text`/`integer`/`real`/`boolean`, required; no order of its own (read by id) | same | `composition`, `ProcedureContractTests` |
| `ProcedureStep` | `memory_route_steps` | positions 0 ..< n; `goal` or `route_call` (callee, bindings, no operations); goal text describes the result, also for a call; application optional | same | `multiStepRoundTrip` |
| `StepCheck` | `memory_step_checks` | `scene` (a structural scene of the step's application), `anchor` (an anchor, optionally a known state), `text` (a text or text parameter, `equals`/`contains`, optionally in an anchor), `value` (an anchor's value equals a typed literal or a parameter); positions 0 ..< n; at most one expectation | same | `ProcedureContractTests.definitions`, `malformedRows` |
| `StepOperation` | `memory_step_operations` | one of the seventeen tools under `AgentCallContract` version 1, the step's application; a `batch` holds ordered children, each a batch step, none of them a batch; positions 0 ..< n at each level | same | `literalSignatures`, `multiStepRoundTrip` |
| `OperationArgument` | `memory_operation_arguments`, owner `operation_id` with `route_id` | the call contract's names, types and rows; a literal (all literals: decoded by `AgentCallRequest` itself), a parameter of the Route of the argument's type that the operation can read (`input`/`inout`), an anchor of the step's application for `target`, `control`, `from`, `to`, a menu command of it for `item` | same | `parametricOperations` |
| `RouteCallBinding` | `memory_route_call_bindings` | see the composition rules | same | `composition` |

Publication (`active`): at least one step; every goal has at least one check (it may have no
operation when its result already holds); every batch has a step; every called Route is active and
every required parameter it reads is bound. A `draft` may be incomplete in exactly these ways and
no other: references, types, positions and arguments are checked whatever the status. A definition
with references is a shape: the values its parameters, anchors and menu commands will have are
revalidated when they are given, by a resolver nothing in this build provides. Literal codes,
counts and the alternatives of `drag` and `set_toggle` are checked now by presence.

Composition rules of a Route call: a called `input` takes a literal of its type or a calling
parameter of its type the caller can read (`input` or `inout`); a called `output` gives its value
to a calling `output` or `inout` of its type, never to a literal; a called `inout` is bound to a
calling `inout` of its type, both ways. A Route may not call itself (`selfCall`; the schema's
trigger refuses longer cycles, which a definition cannot close since a callee must exist first).
Parameter, step, check and operation ids are identities of the file: one another definition holds
is `repeatedID` before any row. Changing a published definition is a new `route_id` with
`supersedes_route_id` and new child ids; the old definition and its evidence stay.

The reader applies the same relations to the rows it reads (`SQLiteRouteRows.checkCallRelations`):
every binding names a parameter of the called Route and agrees with it in direction and type, and a
definition stored `active` binds every required parameter it reads; a row changed by hand that
breaks one is `malformedRow(table: "memory_route_call_bindings", id: <step>, …)` with the
`binding` or `missingBinding` cause. The called Route's status is not read: a callee retired later
leaves the caller's definition readable, and only publication asks for an active callee. Only the
callee's parameters are read, in the same snapshot, so composed Routes are read without recursion.
A draft keeps its declared incompleteness when read.

The check kinds and comparisons are the initial persistence contract: they state what a step
expects, and nothing in this build evaluates them.

## Occurrences and evidence

`SQLiteStepOccurrenceRepository` (`StepOccurrenceStoring`) keeps a step occurrence as a fact
(`StepOccurrenceRecord`: id, start, end when known, status), its assignment apart (task and step
each once, by one author: `alreadyAssigned` otherwise, never a silent reassignment), its
memberships (`StepMembership`: an existing event, a position no other membership holds, the attempt
number when known, the role) and the evidence a caller gives (`DefinitionEvidence`: a task
occurrence for a Route, a step occurrence for the step it is assigned to, `supports` or
`contradicts`, author and instant, once by its key). `attribute(verification:to:)` sets
`memory_verifications.step_occurrence_id` and writes the `verification` membership in one
transaction; a `verification` membership needs that attribution first. A fact retried after its
assignments is `alreadyApplied`. Nothing infers a goal, a success or useful attempts.

What `assign` does, as the schema's one `assigned_by` column allows: the task and the step are each
set at most once and never changed; an assignment may be partial (a step now, the task later); the
first author who assigns anything is the provenance of the whole assignment, so only that author may
complete it, and another author is `alreadyAssigned` even when completing an empty field or
repeating the same values, while the stored assignment and its author stay as they were. This is
the limit of the current API, not a policy for attributions by several agents or people, which is
still to be designed; labels of episodes keep their own authors side by side.

## Experiences

`SQLiteExperienceRepository` (`ExperienceStoring`) keeps an `ExperienceRecord` (an id, the phrase as
given, a Route or one of its steps, the creation instant) with its bindings in one transaction:
`literal` (a typed value of the parameter's type), `request_slot` or `context_slot` (a slot name,
not a phrase to interpret), binding contract version 1, for parameters the binding may fill
(`input`, `inout`); every required one is bound. Uses (`ExperienceUse`: an event, `passed`,
`failed` or `unknown`) are recorded once by experience and event; counts are derived from them
(`useCounts(of:)`), never stored apart. Reading by id, by Route and by exact phrase (bytes) is all
there is: no ranking, fuzzy match, token index, slot parsing or recall. Legacy `argsJSON` does not
reach the store. Every read (by id, by Route, by phrase, and the read a retry or a use makes) checks
the stored bindings as the writer does: a binding the Route's parameters do not admit, or a
required parameter left without one, is `malformedRow(table: "memory_experience_bindings", …)`,
never an experience given back.

## The brain's general graph

`SQLiteBrainGraphRepository` (`BrainGraphStoring`) keeps what the brain knows beyond the compatible
projection, all of it given, none learned:

- the elements of structural scenes (`SceneElementRecord`, every column typed; written by the scene
  association, read here) and their link to an anchor of the same application, set once;
- general arcs (`BrainArc`) in `brain_transitions` and `brain_transition_menu_items`: from a scene
  (structural, or the application's scope for a menu command), triggered by an anchor of a
  structural scene, a scene element of the source or a menu command (`trigger_kind = 'menu'`, this
  contract's proposal), to a structural scene or an unknown destination (NULL), with the effect in
  `TransitionEffectRecord`'s columns and rows; status and count of supports as their writer states
  them, no threshold or promotion; changed against the arc last read;
- evidence rows (`BrainEvidenceRecord`) with exactly one of the six targets (scene, anchor, scene
  element, group, menu command, transition), of the event's application, never the scope; when the
  target has a structural source (a scene, an element's scene, an arc's source scene) the event must
  have a sample confirmed in it (`memory_event_scenes`);
- an `overview()` per application and overall, read without an open application: the projection's
  anchors, groups and transitions apart from the scenes, elements and general arcs, menu commands,
  evidence, events and samples, and the procedures, experiences and occurrences.

The projection owns the transitions `LearnedTransition` represents: from the application's scope,
with no scene element and no menu command. `SQLiteBrainRows.transitionRows` reads only those, and
still refuses one of them that breaks its contract (no anchor, an unknown trigger or effect); every
other transition is a general arc, read and validated by its own contract and never classified as
corruption. The projection's difference and retirement touch only the rows it loaded; both writers
take the application's next `insertion_order` under the write lock. A general arc has no
retirement API here.

`evidence(ofEvent:)` checks every row as the writer does (`SQLiteGraphRows.checkEvidence`): one
target of the event's application, never the scope, and a structural source the event has a
confirmed association with. Evidence on the projection's anchors, groups and transitions from the
scope, as the applications register writes it, has no structural source and is read as written. A
row written by hand without the association is `malformedRow(table: "brain_evidence", …)`.

`trigger_kind = 'menu'` is the activation code of an arc from a menu command, distinct from the
gestures an observer reports. `MemoryOverview` is a diagnostic value that keeps facts, projection,
graph and procedures apart; it is no screen and no export format. `BrainProjectionError.sourceIsNotTheAppScope`
stays in the public type and is no longer produced.

## Coverage of the 48 tables

The writers below are the public roles the tests call; a test that inserts a row by hand proves a
reader's refusal, not a writer, and a table named in a query is not a reader unless a role gives its
rows back. 46 tables are contract data with a typed writer and reader; 2 are derived projections
written and not read. Production writes the events, the calls with their arguments and results, the
samples, the scene associations and the Brain's applications with their evidence and projection
rows ([Producers](#producers)); menu commands, Watcher inputs, verifications, tasks, Routes,
occurrences, experiences and the general graph have writers and readers and no producer. Tests are
`SQLiteMemoryTests` suites unless another module is named.

| Table | Kind | Writer (role → repository) | Reader | Tests | Reserved, not produced or not supported |
|---|---|---|---|---|---|
| `brain_apps` | contract data | every repository, through `SQLiteIdentityRows` | bundle of every read; `overview()` | `CaptureRepositoryTests`, `PlanTwoPathTests` | — |
| `brain_app_contexts` | contract data | `CaptureStoring.record(event)` | `CaptureStoring.event(_:)` (version, locale) | `CaptureRepositoryTests` | — |
| `brain_app_window_epochs`, `brain_anchors`, `brain_anchor_aliases`, `brain_anchor_states`, `brain_groups`, `brain_group_members` | contract data (projection) | `BrainStoring` (with `importProjection`), `BrainApplicationStoring` | `BrainStoring.brain(of:)` | `BrainProjectionGuardTests`, `BrainProjectionBoundaryTests`, `BrainApplicationTests`, `BrainImportTests`; `AutomationRuntimeTests.MemoryWiringTests` | — |
| `brain_scenes` | contract data | `SceneStoring.associate`; the scope by the projection | `SceneStoring.scenes(of:)` | `SceneAssociationTests` | `window_title_pattern` written NULL |
| `brain_scene_roles`, `brain_scene_labels` | derived projection of the skeleton | `SceneStoring.associate`, once per new scene | none: the skeleton is rebuilt from `brain_scene_elements` | `SceneAssociationTests.derivedRolesAndLabels` | `count_bucket` NULL (presence only); not consumed by matching |
| `brain_scene_elements` | contract data (the skeleton's authority) | `SceneStoring.associate`; the anchor link by `BrainGraphStoring.link` | `SceneStoring.scenes(of:)`, `BrainGraphStoring.elements(ofScene:)` | `SceneAssociationTests`, `PlanTwoPathTests` | `edge_hash`, `cursor_affordance`, `source`, bounds: read, no writer fills them |
| `memory_event_scenes` | contract data | `SceneStoring.associate` | `SceneStoring.associations(of:)` | `SceneAssociationTests`, `CaptureContractCorrectionTests` | — |
| `brain_menu_commands`, `brain_menu_path_segments` | contract data | `MenuCommandStoring` | `MenuCommandStoring` | `MenuCommandRepositoryTests` | no producer |
| `brain_transitions`, `brain_transition_menu_items` | contract data, two owners | the projection's rows by `BrainStoring`/`BrainApplicationStoring`, general arcs by `BrainGraphStoring` | `BrainStoring.brain(of:)` for its own rows, `BrainGraphStoring.arc`/`arcs` for the others | `BrainProjectionGuardTests`, `BrainApplicationTests`, `PlanTwoPathTests` | no retirement of a general arc; no producer of general arcs |
| `brain_applications` | contract data | `BrainApplicationStoring.apply` | `BrainApplicationStoring` | `BrainApplicationTests`, `BrainApplicationCorrectionTests`, `BrainApplicationProcessTests` | — |
| `brain_evidence` | contract data | `BrainApplicationStoring.apply` (anchors, groups, transitions), `BrainGraphStoring.record` (six targets) | `BrainGraphStoring.evidence(ofEvent:)` | `BrainApplicationTests`, `PlanTwoPathTests` | — |
| `memory_events` | contract data | `CaptureStoring`, `AgentCallStoring`, `ObservedInputStoring`, `VerificationStoring` | `CaptureStoring.event(_:)`, each role's reads, and `MemoryTraceReading` (traces, a trace's entries, observations by origin; read only) | `CaptureRepositoryTests`, `AgentCallRepositoryTests`, `ObservedInputRepositoryTests`, `TraceReadingTests`, `TraceIdentityTests`; `MemoryWiringTests` | source `watcher`: no producer |
| `memory_event_observations` | contract data | `CaptureStoring.record(sample)`: kinds `capture`, `capture_field`, `element` | `CaptureStoring.sample(_:)` | `CaptureRepositoryTests`, `CaptureSampleContentBytesTests`; `MemoryWiringTests` | `old_state`, `scene_age_ms`, `name_resolution`, `label_source`, `candidate_rank`: no kind uses them |
| `memory_agent_actions` | contract data | `AgentCallStoring` | `AgentCallStoring` | `AgentCallRepositoryTests`, `AgentCallBatchSummaryTests`, `AgentCallProcessTests`, `AgentCallTimingTests`, `AgentCallResultTests`; `MemoryWiringTests` | states `cancelled`, `interrupted`: no producer |
| `memory_agent_action_effect_labels` | contract data | `AgentCallStoring.advance` (a completed action or input with a list effect) | `AgentCallStoring.call` | `AgentCallTimingTests` | — |
| `memory_agent_action_status`, `memory_agent_action_listings`, `memory_agent_action_applications`, `memory_agent_action_windows`, `memory_agent_action_observations` | contract data | `AgentCallStoring.advance` (the completed listing and scene tools' results) | `AgentCallStoring.call`, `calls(inTrace:)`, `steps(ofBatch:)` | `AgentCallResultTests`; `MemoryWiringTests.toolsRecordCalls` | — |
| `memory_operation_arguments` | contract data, three owners | `AgentCallStoring`, `BrainApplicationStoring`, `RouteStoring` | the same roles | `AgentCallRepositoryTests`, `BrainApplicationTests`, `RouteRepositoryTests` | the Route owner: no producer |
| `memory_input_events`, `memory_action_correlations` | contract data | `ObservedInputStoring` | `ObservedInputStoring` | `ObservedInputRepositoryTests`, `CorrelationReadTests`, `EventAttributionPathTests` | no producer: the Watcher is not connected |
| `memory_verifications` | contract data | `VerificationStoring`; the attribution also by `StepOccurrenceStoring.attribute(verification:to:)` | `VerificationStoring.verification(_:)` | `TaskAttributionRepositoryTests`, `PlanTwoPathTests` | no producer |
| `memory_task_occurrences`, `memory_task_events`, `memory_task_labels` | contract data | `TaskAttributionStoring` | `TaskAttributionStoring` | `TaskAttributionRepositoryTests`, `EventAttributionPathTests` | no producer |
| `memory_routes`, `memory_route_parameters`, `memory_route_steps`, `memory_step_checks`, `memory_step_operations`, `memory_route_call_bindings` | contract data | `RouteStoring` | `RouteStoring.route(_:)` | `RouteRepositoryTests`, `RelationReadTests`, `PlanTwoPathTests` | no producer |
| `memory_step_occurrences`, `memory_step_events`, `memory_route_evidence`, `memory_step_evidence` | contract data | `StepOccurrenceStoring` | `StepOccurrenceStoring` | `OccurrenceExperienceTests`, `PlanTwoPathTests` | no producer |
| `memory_experiences`, `memory_experience_bindings`, `memory_experience_uses` | contract data | `ExperienceStoring` | `ExperienceStoring` | `OccurrenceExperienceTests`, `RelationReadTests`, `PlanTwoPathTests` | no producer |

Forms the schema admits and this build does not support: a `count_bucket` value (structure-v3
keeps presence only), a scene of surface `popupUnion` or `unknown` (never created, refused by the
scenes reader), observation kinds other than the three above, a non-NULL `window_title_pattern`.

`BrainProjectionTests` proves the projection equal to a pure brain run on the same sequence, after
every step and after reopening; `BrainGraphTests` the general graph's arcs, links, evidence of the six
targets and the overview, beside the projection; and, in `MemoryTests`, `BrainApplicationContractTests`
the application commands. They reach the raw projection through `BrainStoring.record`, which this
build keeps for them and for low-level tools; producers apply through `BrainApplicationStoring`.

## Two processes and interruptions

`Tools/Engine/memory-probe` is a second real process on one file, driven by lines on its standard
input (`Probe.usage` lists them) and answering one line per command, so the tests decide every
order of events on a line with a deadline, never on a sleep. It is a package executable, built by
`swift test` beside the test bundles, wired nowhere and bundled nowhere; its raw idempotent writer is
a fixture, and its Brain application and agent call commands go through the typed repositories. `SQLiteProcessTests` proves: two processes bootstrapping
one fresh file at once (both held on the lock, one creates the schema, the same fact then applied
once across them, different content refused); three processes doing read-modify-write on one
stream with no lost update; a process killed after its changes and before its commit (nothing
partial, integrity `ok`, the store writes on); a process killed after it confirmed its commit (the
fact is there, found by its identity); a process that died after its commit and before answering
(the caller asks by the same identity and gets `alreadyApplied`, it does not act again).
`BrainApplicationProcessTests` and `AgentCallProcessTests` prove the same for an application and for
a call: a helper that dies after its commit and before answering, and two processes offering one key
at once, store it once. These are process crashes, not a device blackout.

## Measures

Three sets of measures, each with the build and the code it describes. None is a product claim or a
validation of several agents.

The store's writes, measured by `Tools/Engine/Scripts/measure-memory-store.sh [processes] [writes]
[bytes] [hold-ms] [budget-ms]`, which runs the helper on temporary files and prints hardware, OS, the
linked library, the configuration and the corpus with every figure. On 2026-09-30, on
`tommaso/memory-model`, Mac16,1 (Apple M4, 10 cores, 16 GiB), macOS 27.0, APFS, SQLite 3.54.0, a
debug build of the helper, 3 processes x 200 writes of one `memory_events` row with a 256-byte key,
store defaults. The store's write path is the same on this branch; its open now also compares the
schema, which these figures do not include. They were not run again here.

| Scenario | Per process | Waits |
|---|---|---|
| Three writers at once | p50 104 to 114 us, p95 145 to 370 us, max 1.3 to 3.1 ms; 200 commits each in about 30 ms | 3 to 4 pauses, 50 to 100 ms waited, no spent budget |
| One writer, same corpus | p50 97 to 122 us, p95 126 to 145 us | none |
| Checkpoint by one process with two others open | 188 frames, all checkpointed, 4.3 ms | |
| One process holds the lock 1.5 s; three already-open writers, 100 ms budget, 20 writes each | p50 99 to 265 us, max 827 to 850 ms (the hold); all 20 commits each, 20 distinct values on each stream | 39 to 41 pauses, about 800 ms waited, 9 spent budgets each, no lost write |

The two slow reads of S4, measured on 2026-10-04 on `tommaso/memory-model`, same machine, debug
build, on copies of a seeded synthetic corpus, the median of 30 warm reads through that branch's
`MemoryService`. The harness (`StoreCostMeasures`, `MECUM_COST_*`) did not come over; the code it
measured, `SQLiteTraceRepository` and `SQLiteBrainGraphRepository.overview()`, is the same here.

| Read, 100,000 events (2.17 GB, 1,557 traces) | Before | After |
|---|---|---|
| A page of 20 traces | 35.3 ms (363 ms first after an open) | 1.2 ms (6.5 ms first) |
| The whole pagination, 20 at a time | 2.76 s | 0.42 s |
| The catalogue (`overview()`) | 279 ms (2.12 s first) | 121 ms (1.95 s first) |

The page walks events down from the cursor and counts only the traces it answers; the catalogue
counts `brain_evidence` once for every application instead of scanning it once per application. Both
answer what the earlier queries answered, as `memory-model` checked by digests on the 10,000 and
100,000 corpora and by `TraceIdentityTests`, which keeps the former query as its oracle and compares
trace ids by their bytes. The walk is not bounded by the page: it reads every event it meets below
the cursor, those of traces it leaves out included, so a page under many events of straddling traces,
or the end of the pagination, can read every event below the cursor. On the 10,000-event corpus the
whole pagination went from 23 ms to 41 ms. An index on `brain_evidence(app_id)` would take the
catalogue's evidence count from about 90 ms to about 10 ms on a copy, but it changes the resource and
is left to a decision. The corpus is agent calls with their samples over synthetic applications,
written through `MemoryService`, `BrainMemory` and `CallRecorder`: it says nothing of the volume of
Watcher events, which nothing writes.

What the memory adds to an action on this branch, from `AutomationRuntimeTests.MemoryWiringTests`
on 2026-10-07, debug build, the same Mac, macOS 27.0, SQLite 3.54.0. Each test prints a
`MEMORY-LATENCY` line; the figures are from two runs.

| Measure | Value |
|---|---|
| Offering one call's writes, archive free (`begin`, an action's record with two samples, `end`), 40 calls | p50 8 µs, max 37 to 53 µs |
| Offering ten such calls while another connection holds the write lock | 0.12 to 0.15 ms in all; nothing written until the lock goes, then all ten |
| The Brain read an action makes before acting, 300 anchors, first after a change and cached | about 0.3 ms each |

These time the producer's side, which is all an action waits for: the writes themselves run after,
on the service's task. The tests assert the agreed budget of 50 ms per action, not these figures.

## Differences from the archived v5 candidate

The S0 closing review reproduced three writes the v5 candidate still admitted. The four S1 changes
are triggers; no table, column, index or vocabulary changed for them, and no cleanup runs on the
store's own initiative. Each is a refusal. The second S2 increment added the one column below,
increment 3a the register of applications.

| Change | Why | Proof |
|---|---|---|
| `brain_scene_roles_not_app_scope_update`, new: `BEFORE UPDATE OF scene_id` refuses a destination whose `scene_kind` is `app` | v5 covered the INSERT only; an UPDATE could move a role onto the app scope, which has no structure | `SchemaResourceTests.rolesAndLabelsStayOffTheAppScope`, `.appScopeRulesAreSymmetric` |
| `brain_scene_labels_not_app_scope_update`, new, same rule for labels | Same asymmetry | Same tests |
| `memory_event_observations_capture_identity_guard`, new: `BEFORE UPDATE OF event_id, observation_kind, phase, sample_ordinal` refuses a change when any `memory_event_scenes` row names the sample (event, phase, ordinal) | v5 guarded phase and ordinal for confirmed samples only; `event_id` could still move, and a candidate association could lose its sample too. An association requires its sample whatever its status (the `require_capture` triggers), so the identity is protected for every referenced sample | `SchemaResourceTests.referencedSampleKeepsItsEvent` |
| `memory_event_observations_capture_status_guard`, narrowed to `BEFORE UPDATE OF status`: a confirmed sample keeps `complete` | Its identity part moved to the guard above; the status rule is unchanged, and an unconfirmed sample may still be corrected | `SchemaResourceTests.statusCorrections` |
| `memory_event_observations_capture_delete_guard`, new: `BEFORE DELETE` refuses a capture row that any association names | v5 let the association survive without its sample. A child row (`capture_field`, element) and an unreferenced sample stay deletable: this is a refusal, not a retention policy | `SchemaResourceTests.referencedSampleCannotBeDeleted` |
| `brain_anchors.current_group_id TEXT` nullable, with `FOREIGN KEY (app_id, current_group_id) REFERENCES brain_groups(app_id, group_id)` (S2, second increment) | `ObjectAnchor.groupID` is the group the algorithm last assigned; one anchor can be a member of two groups (`brain_group_members` keeps both, ordered) while `groupID` names one, and it switches between them with no change of membership, so it cannot be derived. No constraint limits an anchor to one group | `BrainProjectionGuardTests.currentGroupForeignKey`, `.oldFormRefused`; six SQL checks in `verify-memory-schema.py` |

"Referenced" means any `memory_event_scenes` row, not only a confirmed one: a candidate association
needs its sample as much as a confirmed one does, and the INSERT rule of the relation already says
so.

Increment 3a: `brain_applications` (one table); in `memory_operation_arguments` the column
`brain_application_id`, the third owner in its CHECKs, a value-kind CHECK and the deferred composite
key; in `memory_event_observations` the table constraint `UNIQUE (observation_id, event_id, phase,
sample_ordinal, observation_kind)`, the parent key of a sample reference; four indexes
(`memory_arguments_brain_application`, `brain_applications_observation_key`,
`brain_applications_call_key`, `brain_applications_by_app_clock`); six triggers
(`brain_applications_insert_guard`, `_immutable`, `_kept`, `memory_operation_arguments_application_sealed`,
`_immutable`, `_kept`). Proved by `BrainApplicationTests`, `BrainApplicationProcessTests` and 30 SQL
checks. This reading was confirmed in review; it is not a change of the model.

Increment 3b changed nothing in the resource: the agent calls use `memory_events`,
`memory_agent_actions` and `memory_operation_arguments` as they are. Neither did 3c: the menus use
`brain_menu_commands` and `brain_menu_path_segments` as they are; nor 3d, on `memory_input_events`,
`memory_action_correlations`, `memory_verifications` and the three task tables; nor the S2 completion.

S3-d, on `memory-model`, added to `memory_agent_actions` the column `started_at_ms INTEGER` with
CHECKs (no start while `planned`, an effect only on `completed`); its correction changed the table and
added to the resource, each on the concrete flow its supervision reproduced or its original prompt
required. The producer and proof columns name what writes and proves each change on this branch:

| Change | Producer → column or relation → reader | Why | Proof |
|---|---|---|---|
| `memory_agent_actions.duration_ms INTEGER`, CHECKs ≥ 0 and only on a state reached from `started`; the CHECK `completed_at_ms >= started_at_ms` removed | `CallRecorder` measures the run on the monotonic clock → `duration_ms` → `AgentCall.durationMS` | the calendar may run backwards between the two instants; a duration is not their difference, and a clock change must not refuse a valid record or invent a time | `AgentCallTimingTests`, 3 SQL checks |
| the effect as typed parts: `observed_effect_kind` with its family CHECK (five families then, six since the merge), `observed_effect_text` as the title of `windowTitleChanged` alone, `observed_state_before`/`observed_state_after` for `stateFlip`, and the table `memory_agent_action_effect_labels` (event, position, label) with an insert guard | the engine's `SceneEffect` → `ObservedEffect` → the columns and the label rows → `ObservedEffect.sceneEffect` | `encoded` joined labels with `|` and lost which label held the separator (`menuOpened(["A|B","C"])` and `menuOpened(["A","B|C"])` read back alike); an effect is data, not a string | `AgentCallResultContractTests`, `AgentCallTimingTests.effectsRoundTripThroughTheFile`, 7 SQL checks |
| `memory_agent_action_status`, `memory_agent_action_listings`, `memory_agent_action_applications`, `memory_agent_action_windows`, `memory_agent_action_observations`, with insert guards tying each row to a completed call of its tool and each application row to its listing's shape; `result_kind` gains `status`, `listing`, `observation` | `AutomationTools.answer` → `AgentCallResult.status/.listing/.observation` → `CallRecorder.end` → the rows → `AgentCallStoring.call` | the original S3-d requirement: the structured data the five tools produce, in typed rows with order, absence and truncation kept, the observation tied to its real sample | `AgentCallResultTests`, `MemoryWiringTests.toolsRecordCalls`, 11 SQL checks |
| `memory_events.origin_event_id TEXT REFERENCES memory_events(event_id)`, CHECKs: only on an `observation`, never itself; in the identity trigger | the session's own observation after `open_session` (`CallRecorder.observe`, `ActionContext.another`) → `origin_event_id` → `MemoryEventRecord.originEventID` | the call could not name its application when planned and never rewrites its event; a trace may hold many openings, so stream and trace do not say which call an observation served; a batch's parent is not that relation | `AgentCallResultContractTests.origins`, `MemoryWiringTests.openSessionObservation`, 5 SQL checks |

`SQLiteMemorySchema.requiredColumns` gains `duration_ms`, `observed_state_before` and
`origin_event_id`, and the table set gains six names: a file of schema 1 without them, the files the
S3-d build created included, is refused untouched, never migrated, reset or imported. `user_version`
stays 1: this experimental form is not distributed, and its earlier files are refused by shape, not
by version. The resource's SHA-256 moved from `c67650dc…` to `b99be960…`.

The merge into main (`4f6f075`) changed the resource for main's tools, effects and sources: three
widened CHECKs, two triggers that accept the new source, one nullable column and the guard that
keeps it off a `windows` row. No table, index or trigger was added or removed:

| Change | Producer → column → reader | Why | Proof |
|---|---|---|---|
| `label_origin` admits `identifier`, on `memory_event_observations` and `brain_scene_elements` | `AccessibilityAugmentation.harvest` → `label_origin` → `CaptureElement.labelOrigin` | main's harvest names a text area that has no title by its accessibility identifier | 1 SQL check |
| `memory_events.source` admits `mcp`; the two triggers of `memory_action_correlations` accept an `app`, `cli` or `mcp` action | `AutomationTools` under an external client's `CallProducer` → `source` → `MemoryEventRecord.source` | the original transplant used the workers' archive; the current candidate retains source `mcp` in a private archive per profile, as on main | 2 SQL checks |
| `memory_agent_actions.observed_effect_kind` admits `textSelectionChanged`, a family with no title, state or label | the engine's `SceneEffect` → `ObservedEffect` → the columns → `ObservedEffect.sceneEffect` | main's perception reports a selection change in a text field | 4 SQL checks |
| `memory_agent_action_applications.is_default_browser INTEGER` (0, 1 or NULL), and the insert guard keeps it off a `windows` row | the `apps` tool's candidates → `ListedApplication.isDefaultBrowser` → the column → `AgentCallStoring.call` | main's `apps` listing says which application opens web links | 3 SQL checks |

`SQLiteMemorySchema.requiredColumns` did not change, and `user_version` stays 1. The exact shape check
of `1a3e22b` is what refuses the archives `memory-model`'s builds created ([The resource](#the-resource)).
The resource's SHA-256 moved from `b99be960…` to `4c39eed0…`, then to `9df535ab…` when the correlation
triggers' error message came to read "an app, cli or mcp action event".

Every other difference from the archived v5 is textual, as `memory-model` recorded it: the header, the
comments translated to English, and the removed `PRAGMA foreign_keys = ON;`, `BEGIN;` and `COMMIT;`
lines. The v5 file is not in this repository, so that comparison was not repeated here.

## Verification

Counts from `swift test list` and the scripts on 2026-10-07, this branch.

- `Tools/Engine/Scripts/verify-memory-schema.py`, run by `make test` before the unit tier: 242 SQL
  checks (194 negative) on the shipped resource, with `PRAGMA foreign_keys = ON` executed first as
  the store does, through Python's sqlite3: the 232 `memory-model` had (the 166 of the S0 review, six
  of the current group, 30 of the applications register, 30 of a call's start, duration, typed effect,
  structured results and an observation's origin) and ten of the merge (the `identifier` origin, the
  `mcp` source, the selection effect, the default browser flag). They prove the shape of the schema,
  and they stay SQL on purpose. Pass another DDL path as the first argument to check a copy.
- `swift test --filter SQLiteMemoryTests`: 227 tests in 43 suites, on temporary files, through the
  store, on the resource in the module's bundle, with `memory-probe` for the proofs that need a
  second process:
  - the store's foundation, 74 tests in 13 suites: bootstrap and reopen, an empty archive apart from
    an unreadable file, refused schemas left untouched (the earlier form whose constraints differ
    included), rollback, visibility, idempotency, contention and a wait that holds no transaction,
    `locked`, a full database, a snapshot read (`SQLiteMemoryStoreTests`); the lifecycle and retained
    writes (`SQLiteLifecycleTests`, `SQLiteOpeningRetryTests`, `OpeningFailureRetrySupervisionTests`);
    bindings and strict text (`SQLiteBindingTests`, `SQLiteTextTests`); the waiting policy
    (`SQLiteConfigurationTests`); snapshots, checkpoints, failure and recovery (`SQLiteSnapshotTests`,
    `SQLiteCheckpointTests`, `SQLiteRecoveryTests`, `SQLiteFailedLifecycleTests`); two real processes
    (`SQLiteProcessTests`); and the shipped resource (`SchemaResourceTests`);
  - the observation contract, 57 tests in 7 suites: `ObservationContractTests`,
    `CaptureRepositoryTests`, `SceneAssociationTests` (the fifteen structure-v3 fixtures through the
    real producer), `CaptureContractCorrectionTests`, `CaptureContractCorrectionDetailTests`,
    `CaptureIdentityBytesTests`, `CaptureSampleContentBytesTests`;
  - the brain, 29 tests in 7 suites: the canonical clock (`BrainClockTests`), refusals and the
    earlier form of schema 1 (`BrainProjectionGuardTests`), the boundaries with structural scenes,
    clocks and bounds (`BrainProjectionBoundaryTests`), the applications register and its correction
    (`BrainApplicationTests`, `BrainApplicationCorrectionTests`), a helper process that dies after its
    commit or applies the same key at once (`BrainApplicationProcessTests`), and the import of a JSON
    Brain (`BrainImportTests`);
  - the agent calls and traces, 29 tests in 7 suites: the seventeen signatures and a batch read back
    exactly, idempotency and conflicts, the moves of a state, malformed rows (`AgentCallRepositoryTests`),
    a helper process (`AgentCallProcessTests`), the batch summary (`AgentCallBatchSummaryTests`), the
    start, the monotone duration and the six effects (`AgentCallTimingTests`), the structured results
    with the default browser flag (`AgentCallResultTests`), and the trace readers
    (`TraceReadingTests`, `TraceIdentityTests`);
  - the menu commands, 10 tests (`MenuCommandRepositoryTests`);
  - the observed inputs and attributions, 13 tests in 4 suites (`ObservedInputRepositoryTests`,
    `TaskAttributionRepositoryTests`, `EventAttributionPathTests`, `CorrelationReadTests`);
  - the procedures, occurrences, experiences and the general graph, 15 tests in 4 suites
    (`RouteRepositoryTests`, `OccurrenceExperienceTests`, `RelationReadTests`, and `PlanTwoPathTests`,
    one fixture through every repository of plan 2, reopened and retried).

  The first test prints the linked library's version and source id; on the machine of 2026-09-30 it
  was 3.54.0, `2026-04-09 12:25:13 8fa8248e…aapl`, from `/usr/lib/libsqlite3.dylib`.
- `MemoryTests` (162 tests in 19 suites) proves the pure contracts on their own:
  `AgentCallContractTests`, `AgentCallResultContractTests`, `CaptureSampleKeyTests`,
  `CaptureSampleContentTests`, `MenuCommandRecordTests`, `EventAttributionContractTests`,
  `ProcedureContractTests`, `SceneStructureMatcherTests`, `BrainUpdaterSeamTests` and `BrainMemoryTests`
  (the seam over a stored Brain), beside the brain's own suites.
- `AutomationRuntimeTests.MemoryWiringTests` (15 tests) proves the producers on temporary
  directories: the queue's order, its limit and its count of dropped writes; an archive this build
  refuses, degraded and left as found; the daily copy and its pruning; a corrupt archive moved aside
  and restored from the newest copy, or started empty; a call recorded through its recorder, planned,
  started, sampled, taught to the Brain and completed with its result and effect, then expected back
  by the engine from SQLite; the open's own observation event with its origin; a call outside the
  tools; a batch's steps, run and skipped; the Brain cache moving with the archive; the tools'
  calls under an `mcp` producer and its trace, a refused call recorded `failed`; and the three
  latency measures above.
- `Tools/Engine/Scripts/measure-memory-store.sh`: the store measures above, repeatable.

Not on this branch: `memory-model`'s producer suites (`MemoryServiceTests`,
`MemoryServiceFailureTests`, `CallRecorderTests`, `FinalizationScopeTests`, `ReaderOpeningTests`, the
cost and stop measures, `ChatTests.AutomationToolsMemoryTests`, `MecumCLITests.ChatHostTests`), which
tested its own wiring.

## Contract items carried into S2

The v4 to v5 diff changed five things of the approved model, and the resource carries them as the
candidate did: the `scene_kind = 'app'` row with its fixed shape and one per app; the closed
`scene_kind` vocabulary; `sample_ordinal` in the key of `memory_event_scenes`; `container` in
`element_scope` and the `label_origin` column of `brain_scene_elements`; and a dialog's title as a
hint, never a scene's identity. The S2 start accepted the resource as its fixed base with these
items as they stand; the observation contract above writes against them. The resource is not yet
distributed in a release; development builds of this branch's app and command line open it.
