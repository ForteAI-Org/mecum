# Memory contracts

The contract the living memory offers to the work that follows it, Action Memory and Action Recall: what the
store keeps today, through which API, with which guarantees, and what is left to future policies. Details of
every table and rule are in [MemorySchema.md](MemorySchema.md); this page names the entry points and the
promises, and links the section that proves each one.

The resource is schema version 1 (`user_version` 1), 48 tables, 48 triggers and 31 explicit indexes, in
`Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql`. Old JSON knowledge is never imported.

## Entry points

The app, the terminal chat and the vertical commands reach the archive through one service,
`MemoryService` (`Sources/Integration/AutomationRuntime/MemoryService.swift`): one `memory.sqlite` under a
Knowledge directory, opened on first use, closed by its owner. The repositories are protocols of the `Memory`
module (`Sources/Engine/Memory/Storage`), all implemented over SQLite by `SQLiteMemoryStore` and the
`SQLite*Repository` types; the service conforms to the ones production uses
([What production writes today](#what-production-writes-today)):

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

Writers outside these protocols (the tools' `AutomationTools`, the Brain's `CallRecorder`) are producers over the
same service; they add no format of their own.

In production the Brain is written only through `BrainApplicationStoring.apply`: `BrainMemory` turns an
observation or an action's record into a `BrainApplicationCommand`, applied once per key, so a retried call
teaches nothing twice. The contract's third operation, a naming (`set_name`), has no producer yet.
`MemoryService` hands out that role and `BrainReading`, never `BrainStoring` or `BrainGraphStoring`. Those two are
raw access over the same tables (`SQLiteBrainRepository.ingest` applies a mutation each time it is asked;
`SQLiteBrainGraphRepository` writes the elements, arcs and evidence it is given), kept for tests, fixtures and
low-level tools; a new producer does not use them.

## What production writes today

Three owners open a `MemoryService` over their Knowledge directory: the app's `AppModel` (shared with `TeamModel`'s
workers and the Brain library), `mecum chat` (`ChatCommand`) and each vertical command (`CLIMemory`). Every row below
is written by a producer of the app, the chat or the vertical commands, through the roles `MemoryService` conforms
to (`BrainReading`, `BrainApplicationStoring`, `CaptureStoring`, `SceneStoring`, `AgentCallStoring`,
`MemoryTraceReading`, `MemoryReading`):

| Producer | Role and call | Tables written | Read back by |
| --- | --- | --- | --- |
| `AutomationTools` (the app's workers and the chat, through `AgentTurnHost`), `CLICall` (the vertical commands) | `AgentCallStoring.record`, `record(batch:steps:)`, `advance` | `memory_events` (kind `action`), `memory_agent_actions`, `memory_operation_arguments`, `memory_agent_action_effect_labels` and the five result tables (`status`, listings, applications, windows, observations) | `mecum memory trace`/`event` through `MemoryReading`; tests |
| `CallRecorder`, one per call | `CaptureStoring.record(sample)` for the `current`, `before`, `menu` and `after` samples; `record(event)` for a session's own observation, with `origin_event_id` | `memory_event_observations`; `memory_events` (kind `observation`); `brain_apps`, `brain_app_contexts` | `mecum memory event`; tests |
| `CallRecorder` | `SceneStoring.associate` for every sample but `menu` | `brain_scenes`, `brain_scene_elements`, `brain_scene_roles`, `brain_scene_labels`, `memory_event_scenes` | `mecum memory event` (associations); structure-v3 inside the next association |
| `CallRecorder` through `BrainMemory.observe` and `.record` | `BrainApplicationStoring.apply`, once per sample or call | `brain_applications` with its arguments, the projection (`brain_app_window_epochs`, `brain_anchors` and its aliases and states, `brain_groups` and members, `brain_transitions` and menu items), `brain_evidence` | `BrainMemory.expectedEffect` and `.enrich` (`BrainReading`) during the next call; the app's Brain library (`BrainLibrary`, `BrainCatalog`); `mecum memory <app>` |

No producer in this checkout writes the menu commands, the Watcher's inputs and correlations, verifications, task
occurrences and labels, Routes, step occurrences, experiences or the general graph's arcs and anchor links: their
repositories, fixtures and readers exist (`SQLiteMemoryTests`), and `overview()` counts them, but production leaves
them empty; `mecum memory <app>` ends by saying that menu commands and routes are not recorded. The ported
`Route`, `RouteEarning` and `Recall` types of the `Memory` module work over `AppKnowledge` and are called by tests
only.

The first open of a directory creates `memory.sqlite` empty, at schema 1. The JSON files the earlier build kept in
the same directory (`FileKnowledge`, one per application) are left where they are, never read and never imported;
no executable or composition root of the package links `FileKnowledge` any more (the `MecumEngine` library still
vends it). A file of schema 1 bootstrapped by an earlier development form lacks a table or a column
(`SQLiteMemorySchema.requiredColumns`) and is refused untouched, never migrated: see
[The resource](MemorySchema.md#the-resource).

## Types and versions

- **Event.** `MemoryEventRecord`: kind `action`, `input`, `observation`, `verification` or `diagnostic`; source
  `app`, `cli`, `watcher` or `system` with a stream id. It also carries trace, session, parent position, application
  context, the calendar instant and the monotonic one. The archive's `local_order` is its order; the calendar may go
  back. See [Agent calls](MemorySchema.md#agent-calls) and [Identity](MemorySchema.md#identity).
- **Observation.** Contract version 1 (`CaptureSample`), with explicit capture statuses and the scene kept in
  structure-v3. See [Observation contract, version 1](MemorySchema.md#observation-contract-version-1).
- **Action.** `AgentCallRecord` with an `AgentCallRequest` of the fourteen signatures, and the states `planned`,
  `started`, `completed`, `failed`, `cancelled`, `interrupted` and `skipped`, moving only forward. `completed` means
  the call concluded; its outcome (`found_acted`, `acted_unverified`, `honest_miss`, …) keeps its own meaning, and
  neither says that the user's task succeeded. See
  [The fourteen signatures](MemorySchema.md#the-fourteen-signatures) and
  [States and results](MemorySchema.md#states-and-results).
- **Provenance and times.** A call's event names its source (`app` for the app's workers, `cli` for the chat and
  the vertical commands), stream, trace and session; a batch step names its parent and position, a session's own
  observation the call it was taken for (`origin_event_id`). Three clocks stay apart (`MemoryClock`): the calendar of
  the facts (planned, started and ended instants, kept even when the wall clock ran backwards), the Brain's clock
  (a reference plus monotonic time, the instant a Brain application is asked for), and the monotonic duration of a
  call's run, never a difference of calendar instants.
- **Verification.** `VerificationRecord`, attributed explicitly to a step occurrence. See
  [Verifications](MemorySchema.md#verifications).
- **Scene.** `SceneDefinition` and the Brain's projection. See [Scenes and structure-v3](MemorySchema.md#scenes-and-structure-v3)
  and [The brain's projection](MemorySchema.md#the-brains-projection).
- **Step and Route.**
  - `RouteDefinition` in `RouteState` `draft`, `active` or `retired`, with steps, checks, operations and
    `RouteParameter`s (direction `input`, `output` or `inout`, a typed value). A new version supersedes the old with new
    ids. See [Procedures](MemorySchema.md#procedures).
  - Step occurrences: `StepOccurrenceRecord`, assigned once to a task occurrence and a step.
- **Bindings.**
  - A Route call binds the called Route's parameters by direction and type.
  - An experience (`ExperienceRecord`) binds literals of the four types, or a slot named for the request
    (`requestSlot`) or for the current context (`contextSlot`), and records its uses (`ExperienceUse`).

  See [Experiences](MemorySchema.md#experiences).

## Writes

- **One transaction per repository write.** Each write of a repository is committed whole or not at all: one event
  with its rows, one call `planned` with its arguments, one move of its state, one batch with its steps (checked
  whole before anything is written), one Brain application with its evidence. A tool call's life is several such
  writes (`planned`, then `started`, then its end, with its samples and the Brain's learning between), not one
  transaction: a stop, a failure or a process that dies between them leaves the call at the last state written.
- **Idempotency.** The answer is a `MemoryReceipt`:
  - `committed`;
  - or `alreadyApplied` when a fact with the same identity and content is already stored (nothing moves).

  Another content under a stored identity is a typed conflict (`AgentCallError`, `EventFactError`, `RouteError`,
  `MenuCommandError`, `BrainApplicationError`, `ObservationContractError`) that writes nothing.
- **States move forward only.** Retrying the stored state is accepted; a regression, a skipped state or another end
  is refused. Updates of Routes, step and task occurrences and menu commands name the state last read
  (`from expected:`), so another writer's change is never lost.
- **Errors and availability.**
  - The store's own failures are `MemoryStoreError`.
  - The service answers `MemoryUnavailable` while the archive cannot be used, and a write that is not confirmed is
    reported as such. A busy lock is ordinary contention: waited for, never a failure of the task.
  - A fact that could not be written is a gap said to the consumer: a note in the call's report, a `← memory …`
    record line in the transcript, the call left at its last written state. It is not promised as a row: when the
    store cannot write, nothing in SQLite records that something is missing.

  See [Waiting for a busy lock](MemorySchema.md#waiting-for-a-busy-lock) and
  [Failure, cleanup and recovery](MemorySchema.md#failure-cleanup-and-recovery).
- **After a stop.** Ordinary work has no global deadline. Once the owner of a call or turn
  (`MemoryFinalizationScope`) stops, all its remaining finalizations share one budget
  (`MemoryService.Configuration.finalizationBudget`, 3 s by default) from that stop. What is not written by then is an
  explicit gap; no effect is replayed and no other owner is cut. The budget bounds the memory's wait, not the whole
  stop of a turn. An opt-in trace (`MECUM_MEMORY_FINALIZATION_TRACE`) says each step of it on two monotonic clocks,
  for a proof from outside the process; it changes nothing it observes.

## Reads and paging

- **Absent and error are distinct.** An absent fact reads as `nil` or an empty list; a row the contract does not
  admit is refused with a typed error, and the store goes on.
- **Traces.** `traces(before:limit:)` answers the traces whose last event is below the cursor, most recent last event
  first. A trace with any event at or above the cursor belongs entirely to a newer page and is never split. A trace
  is its id's bytes, as SQLite compares them: two ids that are canonically equivalent Unicode but differ in bytes
  are two traces, and no id is normalized. The page walks events down from the cursor and stops after `limit`
  traces, then counts only those. The walk is not bounded by the page: it reads every event it meets, those of
  traces it leaves out included, so at worst a page reads every event below the cursor (many events of
  straddling traces, or the end of the pagination). Measures are in [the memory schema](MemorySchema.md#measures).
  `entries(inTrace:after:limit:)` pages one trace's events by `local_order`. `observations(originatedBy:)` answers
  the observations a call originated.
- **Catalogue.** `overview()` counts, per application, the Brain's active projection (anchors, groups, transitions
  the projection owns), the general graph (live arcs it does not own), structural scenes, scene elements, menu
  commands, evidence, events and capture samples; then Routes by status, experiences, task and step occurrences, and
  events with no application. Retired knowledge is not counted in the projection.

Readers never write: a read leaves the ledger and the commit count unchanged.

## What the code keeps today, and what is left to policies

| Kept today | Left to a future policy |
| --- | --- |
| Every call of the app, chat and vertical commands, with its arguments, states, results, samples and Brain application, in normal operation; a stop or a failure can leave facts unconfirmed, said as gaps | Which events become steps or procedures (selection, consolidation) |
| The Brain's projection with its current forgetting rules; the general graph when written explicitly | Inferring task labels; advanced structural consolidation |
| Routes, step and task occurrences, verifications and experiences when written explicitly | Searching and scoring memories (recall), binding them to the current context automatically |
| Watcher inputs and correlations through the API, with fixtures | The Watcher's continuous capture, its queue and saturation reporting |
| Gaps after a stop, said and kept as gaps | Retention, compaction or cleanup of history; export and anonymization |

## Compared with 524eb7f

What this branch changes, against the merge `524eb7f` it started from (state of 2026-10-05, not yet committed):

| Area | At 524eb7f | Now |
| --- | --- | --- |
| Brain | One JSON file per application (`FileKnowledgeStore` in `EngineRuntime`); `BrainMemory` mutated it through `KnowledgeStoring`, and a store error dropped the record silently | `memory.sqlite` through `MemoryService`; `BrainMemory` reads `BrainReading` and applies once per key through `BrainApplicationStoring`; a failed write is a note the producer reports. Same learning rules and forgetting |
| Calls, samples, scenes | Not recorded | Every tool call of the app, the chat and the vertical commands, its arguments, states, result, samples, scene associations and Brain application ([What production writes today](#what-production-writes-today)) |
| Old knowledge | Read by the app's Brain library and `mecum memory <app>` (window states, menu commands, routes) | Left in place, neither read nor imported; both readers use the archive through `MemoryReading` |
| Turn | The app's `WorkerAgentHost`; the chat its own tools over a foreground `AutomationSession` | One turn core, `AgentTurnHost`, for both; the chat over the broker's `BrokeredAutomationSession`, as the app; differences of configuration in [CLI chat](Chat.md#configuring-a-turn-the-app-and-the-chat) |
| Vertical commands | `act`, `select`, `batch` | The seven step tools as direct commands and `batch` steps, read by `ToolRequestDecoder`, recorded by `CLICall`; Ctrl+C and SIGTERM stop the invocation (`VerticalInvocation`) |
| Diagnosis | `mecum memory <app>` over the JSON file | `mecum memory` `status`, `traces`, `trace`, `event`, `<app>`, with no application open, on an existing archive only (`MemoryService.openForReading`) |
| Busy, failed or stopped memory | A directory lock, backups and quarantine of the JSON files | Contention waited out; a true failure degrades the service and the task goes on; after a stop one shared budget, then gaps; nothing replayed |

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

- The live proof of the shared core and the memory is incomplete. On 2026-10-05 one request from the terminal chat
  ("open Calculator and press 8", Claude Code) ran once on the desktop: its calls, samples and Brain were recorded in
  a new archive (3 events, 2 calls, 3 samples, 29 anchors and 34 evidence rows), integrity and foreign keys held,
  two `mecum memory` readings were identical after reopening, and the cleanup closed Calculator and left no process
  behind. The independent reading of the result did not distinguish the click: Calculator's display already showed
  8 when its window appeared and in every one of the 75 readings, so the run does not show the transition the click
  caused and does not exclude a repeated effect. Mecum's own perception (`act` concluded `found_acted` with
  `elementsAppeared`, the key AC becoming C) attests a structural change; it is not the independent reading. The
  criterion was left as written and the case was not repeated. A later proof needs an oracle that reads the state
  before and after the action. The run does not exercise the app, `TeamModel` or the XCTest host: the desktop test
  through the broker (`WorkerDesktopThroughBrokerTests`) has not passed, and the broker's queue is covered by local
  tests only (`SeatQueueTests`, `ChatHostTests`).
- The same day a stop under a real SQLite lock measured the memory's budget from the stop to the cut at 3004.7 ms;
  the chat took 3688 ms from the signal to its exit, which also includes the provider, the drain and the release.
  The unfinished facts ended as gaps said in the transcript (`open_session` stayed `started`, no sample), with no row
  recording them.
- The indexes measured on copies (`brain_evidence(app_id)`, `memory_events(origin_event_id)`) are left to later work
  on performance: schema 1 is unchanged. The synthetic corpus of 100,000 events took 2.17 GB and a trace page can
  read every event below its cursor; nothing here promises the volume of a continuous Watcher.
- Three Driver defects seen on a Qt application stay open and belong to separate Driver work: a dropdown selection
  that misses its item and says so (an honest miss, no false success), the application crashing as its dropdown opens
  from the vertical commands, and a dialog reported `returned` after the release that is neither on screen nor in
  accessibility. None corrupts the memory; who owns them and in what order is not decided yet.
- Before Action Memory and Action Recall write anything of their own, four contracts need one shared answer, so the
  two do not produce incompatible formats: how a stored argument names the slot or the earlier output it came from
  (binding and provenance; see [Shared fixtures](#shared-fixtures)); what a verification proves and who may write
  one (a call's `completed` or an engine outcome is not a verified step); which identity makes a write of theirs
  idempotent; and which producer is responsible for each new row. None of these is decided here.
