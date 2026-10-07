# Merging the SQLite memory into main

The living memory of `tommaso/memory-model` reached main's code on `tommaso/merge-memory`, on
7 October 2026. This page records how: what came over, what was adapted, what stayed behind, the
decisions taken, the verification run and what is left. The memory itself is described in
[MemorySchema](MemorySchema.md) and [MemoryContracts](MemoryContracts.md).

| Revision | Commit |
|---|---|
| main at the start | `eff301c` |
| `tommaso/memory-model` | `f163651` |
| Their merge base | `524eb7f` |

## Method

The memory was transplanted, not merged. A `git merge` of `memory-model` gave 30 files in conflict
and would have brought in its rewrite of the agent turn (`AgentTurn`, the chat through the broker,
the vertical command line), which main had moved past. Only the data layer was cherry-picked; the
wiring was written again on main's own code.

| Step | Commits | What |
|---|---|---|
| Perception | `40a4ded` | Capture quality and label origin, merged by hand with main's harvest |
| Data layer | `39846c8`…`5945751` | The schema, the store and the repositories, ten commits |
| Contract | `4f6f075` | Main's seventeen tools, the selection effect, the `identifier` origin, the `mcp` source |
| Schema check | `1a3e22b` | An archive opens only at the exact shape of the shipped DDL |
| Engine | `1c4a537` | The engine reports what an action and an input perceived |
| MCP | `2c186af` | memory-model's MCP lifecycle test, on main's guards |
| Wiring | `0f31c0f` | The memory service, the call recorder, the tools, the app and the command line |
| Copies | `52523ae` | Daily copies and recovery of a corrupt archive |
| Tests | `4f6c49e` | memory-model's projection, graph and application suites, with the raw `BrainStoring.record` |
| Schema message | `a9a7f8c` | The correlation guard's message names the `mcp` source |
| Documentation | this commit | MemorySchema, MemoryContracts, this page, and the Engine, Perception and LocalMCP pages |

Left on `memory-model`: `23ca39b` (shared agent turn and broker chat), `8b1f948` (its Brain library
page), `7482d38` (its finalization scopes), `6abd290` (dropdown diagnostics), `83ede4b` (QtProbe),
the source change of `036deb4`, and `Documentation/Engine/Chat.md`'s description of its chat.

## Decisions

Decisions were taken by Tommaso Mazzarini on 7 October 2026.

| # | Question | Decision |
|---|---|---|
| D1 | Merge or transplant | Transplant |
| D2 | Earlier JSON Brains | Not imported automatically; `mecum memory --import-json <dir>` imports them by hand |
| D3 | External MCP clients | First one archive shared with the app's workers; reversed after the live checks (C07): each client keeps a private archive, as on main, source `mcp` |
| D4 | Concurrent access | Common practice without needless complexity: one writer, an ordered queue, actions never wait |
| D5 | Latency budget | 50 ms added per action at most, to be lowered later if needed |
| D6 | Schema version | Left to the implementer: version 1 with an exact shape check |
| D7 | Recovery | A daily copy, quarantine of a corrupt archive, restore from the copy |
| D8 | Deleting history | Not in this merge; documented as a limit |
| D9 | GitHub issue | Not opened, at Tommaso's request |
| D10 | App tests | Run unsigned; the signed build is made in Xcode |
| D11 | Live checks | Run by Codex from a written guide |

## Behaviour that changed on purpose

- **The Brain is in SQLite.** Main's JSON Brains are neither read nor written at run time. A build of
  this branch starts with an empty Brain unless the JSON files are imported (D2). Main's builds keep
  reading the JSON files, which this branch never changes, so going back loses nothing older.
- **External clients keep a Brain of their own, now in SQLite.** As on main, each client's directory is
  `MCP/Knowledge/<profile>`, and its archive is the `memory.sqlite` there, apart from the workers' and
  the other clients' (D3, C07). Like the workers' Brain, a client's starts empty unless its JSON files
  are imported: `mecum memory --import-json <dir> --knowledge <dir>` with the client's directory as both.
- **A memory failure no longer fails an observation.** Main's `observe` threw when the JSON store
  could not save. Writes are now queued, and a failed write is a counted gap (D4).
- **The command line's `scene` reports the Brain's counts after its write.** It prints "not
  recorded" with the reason when the memory could not take the observation.

## The 33 points of the mandate

Status: **resolved** (done and verified), **limit** (documented, not needed by the current paths),
**open** (needs work or a check that has not run).

### A. Main's modules and functions

| Point | Status | Outcome |
|---|---|---|
| 1 Tools | resolved | The contract has main's seventeen tools, `observe(full)`, an empty window title and the default browser. Round trips in `AgentCallContractTests` and `AgentCallRepositoryTests`; the tools record calls in `MemoryWiringTests`. |
| 2 Effects | resolved | `textSelectionChanged` is a sixth family in the Brain, the calls and the DDL, decoded by name. Tests in `AgentCallResultContractTests`, `AgentCallTimingTests` and the schema verifier. |
| 3 Outcomes and perception | resolved | Main's engine outcomes are untouched: the engine only reports more to its observer. Perception keeps main's window identity, native text and selections, and adds quality, label origin and collection path. The `==` of `SceneElement` includes the selection. |
| 9 Scope | resolved | Main's worker host, team model, queued messages, replies and slash commands are unchanged. App tests: 325, the same two failures as main's baseline. |
| 10 Package and resource | resolved | Main's dependencies kept; the DDL resource is inside the built `Mecum.app`. Only an unsigned Debug build was checked. |
| 12 Public API | resolved | `EngineRuntime(knowledgeDirectory:seat:)` is kept. `engine(recorder:…)` needs the call's recorder; every consumer passes one. The session protocol gained two members with defaults, so test doubles are unchanged. |
| 13 MCP | resolved | Main already guarded the connection's start; memory-model's test was ported. |
| 14 Runner | resolved, live open | Main's runner plus the schema verifier, 28 runs. The independent live check is in the Codex guide and has not run. |

### B. The archive, the service and the runtime

| Point | Status | Outcome |
|---|---|---|
| 4 Shared service | resolved | One `MemoryService` per Knowledge directory per process. No session closes it; the process closes all at its end. External clients write as `mcp`. |
| 5 Versions and data | resolved | A file at version 1 must match the shipped DDL exactly (`differentShape` otherwise), untouched. JSON import tested on copies of six real Brains: counts equal, originals unchanged. |
| 11 SQLite library | open | The store refuses a library below its requirements. On this Mac: 3.54.0. The version and source ID are in `MemoryService.status()` but no screen shows them, and older macOS releases were not checked. |
| 28 Writers | resolved | Every production write goes through the repositories, in the queue; the import goes through the Brain repository, never raw SQL. Foreign keys are on for every connection. |
| 29 Retention | limit | Nothing deletes history; decay retires projection rows. A policy is a later decision (D8). |
| 30 Copies and restore | resolved | A verified copy a day, three kept; a corrupt archive moved aside and the newest copy restored, or an empty start. Tested. Restoring the whole app (workspace, conversations) is outside the memory. |
| 31 Contention and latency | resolved | Writes are offered to a queue and never awaited by an action. Measured below. Under contention a read may miss the last action's learning until the queue drains. |
| 33 Read failures | limit | A memory that cannot open is `degraded`, shown on the Brain page and in the status. A single read that fails while the archive is open still answers no expectation, as main did. |

### C. Events and preprocessing

| Point | Status | Outcome |
|---|---|---|
| 7 Call lifecycle | limit | A call is offered as planned and started, then ended. A crash leaves `started`; nothing marks it interrupted at the next open. Failed writes are counted. |
| 8 Watcher | limit | The Watcher is not connected to the memory, as on main. The 2.17 GB measure is agent calls with samples, not Watcher events. |
| 15 Capture facts | limit | Samples keep role, label, origin, path, state and bounds, not values or selections. `select` and `context_menu` record the call but no samples. |
| 16 Identities | limit | Worker calls trace to the message, chat calls to the conversation, command line calls to the process. External clients' calls have no trace. |
| 17 Order and clocks | limit | `local_order` is write order; calendar, Brain and monotonic times stay apart. |
| 18 Attributions | limit | Unchanged from memory-model; no producer attributes steps yet. |
| 19 Route executions | limit | Unchanged; no producer of route evidence. |
| 27 Correlations | limit | The schema holds them; nothing produces them. |
| 32 Exact text | limit | Identifiers compare as bytes; unknown version and locale are stored as empty text. |

### D. The Brain

| Point | Status | Outcome |
|---|---|---|
| 23 Gestures | limit | Click, double, triple and set_toggle share the click trigger, as on main. |
| 24 Projection and graph | resolved | The engine reads the projection; learning goes through Brain applications, once per event. Nothing writes the general graph. |
| 25 Reprocessing | limit | Applications are keyed per event; an imported Brain has no applications or evidence. |
| 26 Structure and context | limit | One structure, one scene, as designed. |

### E. Procedures and recall

| Point | Status | Outcome |
|---|---|---|
| 6 Base and future | resolved | Today the memory takes calls, samples, scene associations and Brain applications. Routes, steps and experiences have repositories and no producer. |
| 20 Outputs | limit | Scalar parameters only. |
| 21 Branches | limit | Ordered steps only. |
| 22 Route versions | limit | As designed on memory-model; nothing executes routes. |

## Problems found beyond the 33 points

- `menu` and `press` act outside the engine: their calls are recorded, with the observation after
  them, but no engine effect.
- The first copy of the day is the archive as it was opened, like the JSON store's copy before the
  day's first save.
- Two of main's app tests fail on this Mac before and after the merge: one reads the installed
  Claude Code model list, the other launches the unsigned bridge.
- No signing identity is installed on this Mac, so the app's signed build and its tests were not run
  here.
- An incremental build after the memory service's stored properties changed left `SeatBrokerTests`
  linked against the old layout, and the bundle crashed with a bus error. Recompiling the dependents
  fixed it; the result above is from a clean build. After pulling this branch, build clean once.

## Verification

Environment: macOS 27.0 (26A428), Swift 6.4, SQLite 3.54.0, Debug builds.

| Check | Result |
|---|---|
| `swift build --product mecum` | passed |
| `make test SWIFT=swift` on the final code, after `swift package clean` | passed: 2791 executed, 94 skipped, 28 runs, no problems |
| Main's baseline, same command at `eff301c` | passed: 2458 executed, 94 skipped, 26 runs |
| App tests, unsigned (`CODE_SIGNING_ALLOWED=NO`) | 325 tests, the same two environment failures as main |
| DDL resource in the built app | present |
| Schema verifier | passed, including the merge's new rules |
| JSON import, copies of six real Brains | 6 of 6, counts equal, originals unchanged, integrity `ok` |
| Live checks (Codex guide) | not run |

Measures, from `MemoryWiringTests`, Debug build on this Mac:

| Measure | Value |
|---|---|
| Offering one call's writes, archive free | p50 8 µs, max 53 µs |
| Offering ten calls while another connection holds the write lock | 0.15 ms in all |
| The Brain read before an action, 300 anchors | 0.3 ms |

The agreed budget is 50 ms per action (D5).

## Corrections after the live checks

Codex's live checks of 7 October and the corrective plan that followed them raised nine points, and
Codex's review of `f7d31bd` six more remarks on the first fixes (R1–R6). This branch fixes the points
that needed no desktop; the rest wait for a decision on data or for a desktop run.

| Point | Status | What |
|---|---|---|
| C05 Closing | fixed, `8bf80d2`, completed after R2–R3 | `closingBudget` bounds the whole close: admission ends at the first call, the copy is cancelled and never published after it, the queue drains until the last fifth of the bound, and the archive closes in a task the close does not wait on past the bound. Each write is counted by what it committed: written, failed (nothing), partial (a part), dropped (never ran) or unsettled (still running at the bound, counted again when it ends). The copy is held between two steps by a test gate and cancelled there. Before the fix, `f7d31bd` counted as failed a write whose row was in the archive. See [Closing](MemorySchema.md#closing). |
| C08 Diagnosis | fixed, `f55a0bc`, corrected after R1 and R6 | `mecum memory --status` no longer opens a file as `immutable` because no `-wal` or `-shm` is beside it: it reads with the library's locks, in one read transaction, under the presence lock, and says when it cannot read the file as it lies. It reports the version apart from what this build's open would do, so a newer version is refused as newer. See [Diagnosis](MemorySchema.md#diagnosis). |
| C07 Raw `record` | fixed, `1233097` | The documentation says what the raw record is for; a test proves a retried learning applies once. |
| C07 MCP isolation | fixed | As on main, each external client's memory is `MCP/Knowledge/<profile>`, now an SQL archive of its own. Nothing was moved: no archive inventoried holds `mcp` events. A test has two clients and a worker write and learn apart. |
| C09 Recovery with several processes | fixed | A presence lock beside the archive, taken shared by every store, its copies and the diagnosis, and exclusive by a recovery, which is refused while anybody holds it and reads the archive again once it holds it. Proved with real processes. See [Copies and recovery](MemorySchema.md#copies-and-recovery). |
| C06 Earlier archives | inventoried | No SQLite archive in the app's own folder; 23 test archives, unchanged. Any change to the DDL's text, even a trigger's message, makes earlier archives a different shape. |
| C01–C03 Calculator | not touched | Permissions and verification unchanged; Codex compares with main on the desktop. |
| C04 External MCP | not run | Waits for the desktop. |

The unsigned app tests fail the same two tests on main (`eff301c`, 325 tests) and on this branch, at
the same lines. `SlashCommandTeamTests` "/model and /effort" asks the installed Claude Code for its
catalogue, which does not offer `claude-opus-5`, so `/model claude-opus-5` is refused and stays in the
draft: it depends on the machine. `ToolBridgeTests` writes a request to the bundled bridge and closes
its input at once; since `7346f8b` (6 October, on main) the bridge closes its connection when its
input ends, before the answer arrives, so the test reads nothing: a test that main's own change left
behind, not a matter of signing.

## Rollback

Main's build reads the JSON Brains, which this branch never writes. Going back to main loses only
what was learned in SQLite since; `memory.sqlite` and its copies stay beside the JSON files.
