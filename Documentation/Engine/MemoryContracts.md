# Memory contracts

The contract the living memory offers to the work that follows it, Action Memory and Action Recall: what the
store keeps today, through which API, with which guarantees, and what is left to future policies. Details of
every table and rule are in [MemorySchema.md](MemorySchema.md); this page names the entry points and the
promises, and links the section that proves each one. Status on 2026-10-07, branch `tommaso/merge-memory`.

The resource is schema version 1 (`user_version` 1), 48 tables, 48 triggers and 31 explicit indexes, in
`Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql`. An archive opens only at that exact
shape. Old JSON knowledge is never read at run time and never imported on its own; `mecum memory --import-json
<dir>` imports it by hand.

## Entry points

The app, its external MCP clients, the terminal chat and the command line reach the archive through one
service per Knowledge directory, `MemoryService` (`Sources/Integration/AutomationRuntime/MemoryService.swift`):
one `memory.sqlite` under the directory, opened on first use, shared by every caller of the process through
`MemoryService.shared(for:)`, never closed by a session; the process closes it once at its end, the app at quit
and `mecum` after its command, within one bounded close ([Closing](MemorySchema.md#closing)). The repositories are protocols of the `Memory`
module (`Sources/Engine/Memory/Storage`), all implemented over SQLite by `SQLiteMemoryStore` and the
`SQLite*Repository` types:

| Protocol | What it stores or reads |
| --- | --- |
| `CaptureStoring` | events (`MemoryEventRecord`) and capture samples (`CaptureSample`, `CaptureSampleKey`) |
| `AgentCallStoring` | the agent's calls (`AgentCallRecord`, a batch with its steps) and their moves (`AgentCallTransition`) |
| `MemoryTraceReading` | traces, a trace's entries, the observations a call originated |
| `SceneStoring` | structural scenes of an application and a sample's associations to them |
| `BrainReading`, `BrainStoring`, `BrainGraphStoring` | the Brain's projection, its ingest and its general graph |
| `BrainApplicationStoring` | one application of an observation, an action's record or a naming to the Brain, with its outcome |
| `MenuCommandStoring` | menu commands and their paths |
| `ObservedInputStoring`, `VerificationStoring`, `TaskAttributionStoring` | Watcher inputs and correlations, verifications, task occurrences and memberships |
| `RouteStoring`, `StepOccurrenceStoring`, `ExperienceStoring` | procedures (Routes), step occurrences, experiences and their uses |

`MemoryService` conforms to `BrainReading` and `BrainApplicationStoring` itself; every other write goes
through its queue (`enqueue`), whose body receives the open archive's repositories (`MemoryRepositories`).
The one producer over that queue is `CallRecorder`, made per call by `AutomationTools` or by a runtime
(`EngineRuntime.recorder`); it adds no format of its own. A new producer writes through the same queue and the
same repositories.

In production the Brain is written through `BrainApplicationStoring.apply` only: `CallRecorder` turns an
observation or an action's record into a `BrainApplicationCommand`, applied once per key, so a retried call
teaches nothing twice. The contract's third operation, a naming (`set_name`), has no producer.
`BrainStoring`'s mutations are raw access over the same tables (`SQLiteBrainRepository.ingest` applies a
mutation each time it is asked), kept for tests, fixtures and the manual import (`importProjection`), which
writes a whole Brain only for an application the archive holds none of. `BrainGraphStoring` writes the
elements, arcs and evidence it is given; nothing in production calls its writers.

## What production writes today

Every row below is written through `MemoryService`'s queue by a `CallRecorder`. Its producers: the app's
workers (`TeamModel`, source `app`, stream `worker-<id>`, the message as the trace), the app's external MCP
clients (`ExternalMCPSession`, source `mcp`, stream `mcp-<profile>`, no trace), `mecum chat` (`ChatCommand`,
source `cli`, stream `chat-<conversation>`, the conversation as the trace), and the command line's `scene`
and `act` (source `cli`, stream `mecum-<pid>`, one trace per process). The app's workers learn into the app's
Knowledge directory; each external client into a directory of its own, `MCP/Knowledge/<profile>`, as on main, so
each client has an archive of its own and none reads what the workers or the other clients learned.

| Producer | Role and call | Tables written | Read back by |
| --- | --- | --- | --- |
| `AutomationTools`, for every call it can represent, through `CallRecorder.begin`, `end`, `begin(batch:)`, `startStep`, `skip` | `AgentCallStoring.record`, `record(batch:steps:)`, `advance` | `memory_events` (kind `action`), `memory_agent_actions`, `memory_operation_arguments`, `memory_agent_action_effect_labels` and the five result tables (`status`, listings, applications, windows, observations) | tests (`MemoryService.call`, `calls(inTrace:)`); no screen or command shows them |
| `CallRecorder`, as the engine's observer and the session's observation | `CaptureStoring.record(sample)` for the `current`, `before`, `menu` and `after` samples; `record(event)` for the event of a call that wrote none (the command line, a session's own call) and for a session's own observation, with `origin_event_id` | `memory_event_observations`; `memory_events` (kinds `action` and `observation`); `brain_apps`, `brain_app_contexts` | tests |
| `CallRecorder` | `SceneStoring.associate` for every sample but `menu` | `brain_scenes`, `brain_scene_elements`, `brain_scene_roles`, `brain_scene_labels`, `memory_event_scenes` | structure-v3 inside the next association; tests |
| `CallRecorder` | `BrainApplicationStoring.apply`, once per observed sample and once per action with an effect | `brain_applications` with its arguments, the projection (`brain_app_window_epochs`, `brain_anchors` and its aliases and states, `brain_groups` and members, `brain_transitions` and menu items), `brain_evidence` | `BrainMemory.expectedEffect` and `.enrich` (`BrainReading`) during the next calls; the app's Brain page (`BrainLibrary`, through `overview()` and `brain(of:)`); `mecum memory <app>` |
| `mecum memory --import-json <dir>` | `SQLiteBrainRepository.importProjection` | the projection tables only: no application, no evidence | the same readers |

No producer in this checkout writes the menu commands, the Watcher's inputs and correlations, verifications,
task occurrences and labels, Routes, step occurrences, experiences or the general graph's arcs and anchor
links: their repositories, fixtures and readers exist (`SQLiteMemoryTests`), and `overview()` counts them, but
production leaves them empty. The ported `Route`, `RouteEarning` and `Recall` types of the `Memory` module work
over `AppKnowledge` and are called by tests only.

The first open of a directory creates `memory.sqlite` empty, at schema 1. The JSON files the earlier build kept
in the same directory (`FileKnowledge`, one per application) are left where they are and never read at run
time; a build of this branch starts with an empty Brain unless they are imported. `mecum memory --import-json
<dir>` reads every application file of a directory, skips `allowlist` and quarantined files, and imports a
Brain only for an application with no anchor, group or transition in the archive; the files are not changed.
An imported Brain has no `brain_applications` and no evidence rows: its counts are the file's, and its rows
are stamped at the Brain's own last instant. No source imports `FileKnowledge` any more (the `MecumEngine`
library still vends it). A file of schema 1 bootstrapped by an earlier development form, `memory-model`'s
included, is refused untouched, never migrated: see [The resource](MemorySchema.md#the-resource).

## Types and versions

- **Event.** `MemoryEventRecord`: kind `action`, `input`, `observation`, `verification` or `diagnostic`; source
  `app`, `cli`, `mcp`, `watcher` or `system` with a stream id. It also carries trace, session, parent position,
  application context, the calendar instant and the monotonic one. The archive's `local_order` is its order:
  the order the queue wrote it, not a causal order between producers; the calendar may go back. See
  [Agent calls](MemorySchema.md#agent-calls) and [Identity](MemorySchema.md#identity).
- **Observation.** Contract version 1 (`CaptureSample`), with explicit capture statuses, label origins
  (`title`, `description`, `value`, `column`, `row_content`, `identifier`, or none) and the scene kept in
  structure-v3. See [Observation contract, version 1](MemorySchema.md#observation-contract-version-1).
- **Action.** `AgentCallRecord` with an `AgentCallRequest` of the seventeen signatures, and the states
  `planned`, `started`, `completed`, `failed`, `cancelled`, `interrupted` and `skipped`, moving only forward.
  Production writes `planned`, `started`, `completed`, `failed` and `skipped`. `completed` means the call
  concluded; its outcome (`found_acted`, `acted_unverified`, `honest_miss`, …) keeps its own meaning, and
  neither says that the user's task succeeded. The observed effect is one of six families. See
  [The seventeen signatures](MemorySchema.md#the-seventeen-signatures) and
  [States and results](MemorySchema.md#states-and-results).
- **Provenance and times.** A call's event names its source, stream, trace and session; a batch step names its
  parent and position, a session's own observation the call it was taken for (`origin_event_id`). Three
  clocks stay apart (`MemoryClock`): the calendar of the facts (planned, started and ended instants, kept even
  when the wall clock ran backwards), the Brain's clock (a reference plus monotonic time, the instant a Brain
  application is asked for, read once per call), and the monotonic duration of a call's run, never a
  difference of calendar instants.
- **Verification.** `VerificationRecord`, attributed explicitly to a step occurrence. See
  [Verifications](MemorySchema.md#verifications).
- **Scene.** `SceneDefinition` and the Brain's projection. See [Scenes and structure-v3](MemorySchema.md#scenes-and-structure-v3)
  and [The brain's projection](MemorySchema.md#the-brains-projection).
- **Step and Route.**
  - `RouteDefinition` in `RouteState` `draft`, `active` or `retired`, with steps, checks, operations of any of
    the seventeen tools and `RouteParameter`s (direction `input`, `output` or `inout`, a typed value). A new
    version supersedes the old with new ids. See [Procedures](MemorySchema.md#procedures).
  - Step occurrences: `StepOccurrenceRecord`, assigned once to a task occurrence and a step.
- **Bindings.**
  - A Route call binds the called Route's parameters by direction and type.
  - An experience (`ExperienceRecord`) binds literals of the four types, or a slot named for the request
    (`requestSlot`) or for the current context (`contextSlot`), and records its uses (`ExperienceUse`).

  See [Experiences](MemorySchema.md#experiences).

## Writes

- **One transaction per repository write.** Each write of a repository is committed whole or not at all: one
  event with its rows, one call `planned` with its arguments, one move of its state, one batch with its steps
  (checked whole before anything is written), one sample with its fields and elements, one Brain application
  with its evidence. A tool call's life is several such writes (`planned` and `started`, then its samples and
  the Brain's learning, then its end), queued in that order: a failure or a process that ends between them
  leaves the call at the last state written.
- **No action waits.** Producers enqueue and go on. One task of the service runs the writes in order and waits
  out a busy archive; the queue holds at most 4096 writes, and what arrives beyond them is dropped. The one wait
  for writes on an action's path is an observation's, at most 50 ms, before it enriches the scene from the
  Brain.
- **Idempotency.** The answer is a `MemoryReceipt`:
  - `committed`;
  - or `alreadyApplied` when a fact with the same identity and content is already stored (nothing moves).

  Another content under a stored identity is a typed conflict (`AgentCallError`, `EventFactError`, `RouteError`,
  `MenuCommandError`, `BrainApplicationError`, `ObservationContractError`) that writes nothing.
- **States move forward only.** Retrying the stored state is accepted; a regression, a skipped state or another
  end is refused. Updates of Routes, step and task occurrences and menu commands name the state last read
  (`from expected:`), so another writer's change is never lost.
- **Errors and availability.**
  - The store's own failures are `MemoryStoreError`.
  - The service answers `MemoryUnavailable` to a read while the archive cannot be opened (`degraded`, retried
    after 5 s) or after it closed. A busy lock is ordinary contention: waited for by the service's task, never a
    failure of the task.
  - A fact that could not be written is a gap: a write that failed, saved in part or was dropped at a full
    queue or at the service's close is counted in `MemoryService.status()` (`failed`, `partial`, `dropped`,
    `lastFailure`) and logged, never shown to the agent and never retried. Each write is counted by what it
    committed: `failed` saved nothing, `partial` saved a part, `dropped` never ran, and a write still running
    when the close returned is `unsettled`, its outcome unknown. No gap is recorded as a row: nothing in SQLite
    says that something is missing.

  See [Waiting for a busy lock](MemorySchema.md#waiting-for-a-busy-lock),
  [Failure, cleanup and recovery](MemorySchema.md#failure-cleanup-and-recovery) and
  [Producers](MemorySchema.md#producers).
- **At the end.** A session's close waits up to 3 s for the queue; the process's end closes every service once,
  each close bounded as a whole by 3 s from its first call: nothing is admitted from that call on, the copy is
  cancelled and never published, the queue drains until the last fifth of the bound, the archive closes in a
  task the close does not wait on past the bound, and every write is counted. No effect is replayed. See
  [Closing](MemorySchema.md#closing).
- **Copies.** A verified copy a day beside the archive, the newest three kept; a file the library calls corrupt
  is moved aside and the newest sound copy restored, or the memory starts empty, only while no other process
  holds the archive. A recovery that stopped half way is completed from its record or refused with every file
  kept; no open makes an empty archive in its place. See [Copies and recovery](MemorySchema.md#copies-and-recovery) and
  [The presence lock](MemorySchema.md#the-presence-lock).
- **Diagnosis.** `mecum memory --status` reads the file in one read transaction under the presence lock and
  changes nothing of it; it cannot see another process's write counters. See
  [Diagnosis](MemorySchema.md#diagnosis).

## Reads and paging

- **Absent and error are distinct.** An absent fact reads as `nil` or an empty list; a row the contract does not
  admit is refused with a typed error, and the store goes on.
- **The Brain.** `MemoryService.brain(of:)` keeps each application's projection while the archive's
  `data_version` has not moved. It does not wait for the queue: under contention a read can miss what the last
  action taught until the queue drains.
- **Traces.** `traces(before:limit:)` answers the traces whose last event is below the cursor, most recent last
  event first. A trace with any event at or above the cursor belongs entirely to a newer page and is never
  split. A trace is its id's bytes, as SQLite compares them: two ids that are canonically equivalent Unicode
  but differ in bytes are two traces, and no id is normalized. The page walks events down from the cursor and
  stops after `limit` traces, then counts only those. The walk is not bounded by the page: it reads every event
  it meets, those of traces it leaves out included, so at worst a page reads every event below the cursor.
  Measures are in [the memory schema](MemorySchema.md#measures). `entries(inTrace:after:limit:)` pages one
  trace's events by `local_order`. `observations(originatedBy:)` answers the observations a call originated.
  No production reader calls them yet.
- **Catalogue.** `overview()` counts, per application, the Brain's active projection (anchors, groups,
  transitions the projection owns), the general graph (live arcs it does not own), structural scenes, scene
  elements, menu commands, evidence, events and capture samples; then Routes by status, experiences, task and
  step occurrences, and events with no application. Retired knowledge is not counted in the projection. The
  app's Brain page lists the applications it names.

Readers never write: a read leaves the ledger and the commit count unchanged.

## What the code keeps today, and what is left to policies

| Kept today | Left to a future policy |
| --- | --- |
| Every call of the app's workers, its external clients and the CLI chat that the contract can represent, with its arguments, states, results, samples and Brain application; the command line's observations and actions as events with samples and Brain applications; a failure or a full queue can leave facts unwritten, counted as gaps | Which events become steps or procedures (selection, consolidation) |
| The Brain's projection with its current forgetting rules; the general graph when written explicitly | Inferring task labels; advanced structural consolidation |
| Routes, step and task occurrences, verifications and experiences when written explicitly | Searching and scoring memories (recall), binding them to the current context automatically |
| Watcher inputs and correlations through the API, with fixtures | Connecting the Watcher, its queue and saturation reporting |
| A daily copy, the newest three; recovery of a corrupt archive | Retention, compaction or deletion of history; export and anonymization |

## Known limits

- `select` and `context_menu` record the call and its outcome but no samples: their selectors take their own
  captures and report none to the recorder. The command line's `select` records nothing at all.
- `menu` and `press` act outside the engine: their calls are recorded, with the observation they take after
  acting as the call's `current` sample, but no engine effect.
- A call whose process ends between its start and its end stays `started`; nothing marks it `interrupted` at
  the next open. A cancellation ends a call `failed`; a batch cancelled between steps leaves its later steps
  `planned`. No producer writes `cancelled` or `interrupted`.
- A request the contract cannot represent is not recorded; its session's observations still teach the Brain,
  under a `system` event of the session.
- External clients' calls carry no trace; the command line's carry one trace per process.
- Identifiers (events, traces, sample keys, application keys) are compared as bytes; an unknown application
  version or locale is stored as the empty text.
- History has no retention or deletion API: decay retires anchors, groups and transitions instead of
  deleting them, events, calls and samples are never removed, and the archive only grows.
- The queue is in memory: a crash loses what it held, and a failed or dropped write leaves no row saying so.
- A store that went `failed` after a rollback it could not complete is not reopened by the service: its writes
  are counted failures until the process ends.
- The restore of a corrupt archive does not check whether another process holds the file.
- The 2.17 GB corpus measured on `memory-model` is agent calls with their samples over synthetic applications,
  not Watcher events; nothing here promises the volume of a continuous Watcher.
- The Watcher (`InteractionListener`, `mecum watch`) is not connected to the memory.

## Merge into main

`tommaso/memory-model` (documented at `f163651`) built the living memory on a branch that had also rewritten
the agent turn and the command line. `tommaso/merge-memory` brought the memory onto main (`eff301c`) by
transplant, not merge: the data layer was cherry-picked and the wiring written again on main's code.

| What | Commits | Came over as |
| --- | --- | --- |
| Capture quality, label origin and collection path | `40a4ded` | merged by hand with main's harvest (native static text, `AXTextArea`, web focus, selected ranges); a new `identifier` origin; the placeholder handles carry none; `SceneElement` equality and hashing include `selectedRange` |
| The schema, the store and the repositories | `39846c8` … `5945751` | the data layer and its tests, with `memory-probe` |
| The contract | `4f6f075` | extended to main's seventeen tools (`insert_text`, `menu`, `press`; `observe` with `full`; an empty window title kept), the `textSelectionChanged` effect, the `is_default_browser` column and the `mcp` source |
| The schema check | `1a3e22b` | an archive opens only at the exact shape of the shipped DDL (`differentShape`) |
| The engine's reports | `1c4a537` | `ActionRecord` and `InputRecord` carry the perceptions the engine used (`InputTrail`) |
| The MCP lifecycle test | `2c186af` | `memory-model`'s test, on main's guards |
| The wiring | `0f31c0f` | `MemoryService` per directory with an ordered queue, `CallRecorder`, `ActionContext`, `CallProducer`; the tools, the app, the chat and the command line; the Brain page and `mecum memory` reading SQLite; `--import-json` |
| Copies | `52523ae` | a daily verified copy and the recovery of a corrupt archive |

Adapted rather than carried: the producers write through one queue no action waits for, where `memory-model`
awaited its writes under per-owner finalization budgets; one service per directory per process, never closed by
a session, where `memory-model`'s owners each opened and closed theirs; external MCP clients write into the
app's archive as `mcp`, where main gave each client a Knowledge directory of its own; the command line records
events, samples and Brain learning but no call rows.

Stayed on `memory-model`: its shared agent turn (`AgentTurn`, `AgentTurnHost`, `ModelToolLoop`) and the chat
through the broker (`ChatHost`); the command line's recorded calls and stops (`CLICall`, `StepRunner`,
`VerticalInvocation`) and its `mecum memory` diagnosis (`status`, `traces`, `trace`, `event`,
`MemoryDiagnosis`); the reader's open in the service (`MemoryService.openForReading`, `MemoryReading`,
`BrainCatalog`); the finalization scopes and their trace (`MemoryFinalizationScope`, `FinalizationTrace`); the
shared decoder `ToolRequestDecoder` and its schema changes; and the test suites of that wiring
(`MemoryServiceTests`, `CallRecorderTests`, `FinalizationScopeTests`, the cost and stop measures). The three
data-layer suites that `memory-model` added with its wiring came over with `BrainStoring.record`, which they
use: `BrainProjectionTests`, `BrainGraphTests` and `MemoryTests.BrainApplicationContractTests`.

## Shared fixtures

| Case | Where it is proved today |
| --- | --- |
| A step already satisfied (one check, no operation) | `ProcedureFixtures.oneGoal`, Procedures tests: "a Route of one goal with one check and no operation" |
| A step with several actions (an ordered batch of operations) | Procedures tests: "a Route over two applications and none … an ordered batch and typed references" |
| A partial batch | Calls tests: "a partial batch keeps the first outcome, the second failure and the third step skipped" |
| A Watcher event with no task | `OccurrenceExperienceTests`: "from a Watcher input with no task to an experience and its uses" |
| A parameter from a literal or from a calling parameter | Procedures tests: "a Route call binds the called Route's parameters by direction and type"; experiences' bindings |
| Two conversations over the same structure | `SceneAssociationTests`: "two conversations over one chat structure: different conversations, titles and messages are one scene, and the two events, their samples and their traces stay distinct" |
| A parameter taken from the request against one taken from the context | `OccurrenceExperienceTests`: "one parametric Route, its value given once by the request and once by the current context" |

Both fixtures state their inputs; nothing in them extracts, resolves or ranks. The second shows the limit of what
is stored today: an experience's binding says which kind of slot fills the parameter (`requestSlot` or
`contextSlot`, by name), the call keeps the value it was given in its arguments, and the use links the two; no
column says that a given argument filled a given slot. Action Memory and Action Recall should agree on that before
either writes its own.

## Open items around these contracts

- The proofs of this branch's wiring are unit tests on temporary directories
  (`AutomationRuntimeTests.MemoryWiringTests`) and the store's suites. This page records no live desktop run of
  this wiring. The live run of 2026-10-05 recorded on `memory-model` exercised that branch's chat and wiring,
  not these.
- The indexes measured on copies on `memory-model` (`brain_evidence(app_id)`, `memory_events(origin_event_id)`)
  are left to later work on performance: schema 1 is unchanged for them. A trace page can read every event
  below its cursor.
- `MemoryService.status()` carries the linked library's version, the counts of gaps and the last recovery, and
  no screen or command shows them. Older macOS releases and their SQLite libraries were not checked.
- Before Action Memory and Action Recall write anything of their own, four contracts need one shared answer, so the
  two do not produce incompatible formats: how a stored argument names the slot or the earlier output it came from
  (binding and provenance; see [Shared fixtures](#shared-fixtures)); what a verification proves and who may write
  one (a call's `completed` or an engine outcome is not a verified step); which identity makes a write of theirs
  idempotent; and which producer is responsible for each new row. None of these is decided here.
