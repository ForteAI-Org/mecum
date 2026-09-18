# The imitation misfire corpus

<!-- Generated in the Locator repository (scripts/misfire-corpus-doc.py) from misfire-corpus.json, which sits
     beside this file. Edit the JSON and regenerate; do not hand-edit this file. -->

The recall path's real failure history, as a fixture. Data: `misfire-corpus.json` beside this file.
Loader + guards: `Tests/Engine/MemoryTests/Support/MisfireCorpus.swift`, `Tests/Engine/MemoryTests/Recall/MisfireCorpusTests.swift`.
Ticket: `.scratch/honest-learning/issues/03-misfire-corpus.md`. Vocabulary: `CONTEXT.md`.

**What it is for.** Every imitation misfire the engine has ever made lived in session transcripts —
the phrase Ron said, what fired, and whether it was right. Nothing could be tested against that.
This corpus is those cases, each one input phrase against one remembered **Experience**, so a test
built on it asserts recall *policy* and never candidate ranking or which internal branch ran.

**Three verdicts, three contracts.**

| verdict | what a test may assert |
|---|---|
| `wrong` | recall must **not** fire. Firing is the bug. |
| `correct` | recall **must** fire, with exactly those arguments. Refusing is over-abstention. |
| `watch` | recall misses today and must never fire *wrong*; firing correctly is an improvement (lemmatisation, ticket 05), never a regression. |

**`today` versus `expected`.** Each case records both the decision recall *should* reach and the one
it *does* reach, measured against `LocatorMemory.imitate` on 2026-08-22. `MisfireCorpusTests`
replays every `today` against the live implementation, so the baseline cannot rot quietly: change
recall without updating this file and the suite goes red. That is deliberate — the ticket that fixes
recall is the ticket that owns re-measuring the corpus.

## Wrong — substitutions that must abstain (8)

| id | input | generalised from | fires today | outcome then | why it is wrong |
|---|---|---|---|---|---|
| `deictic-it-en` | “can you open it” | “caN you open premiere” | *abstains today* | `honest_miss` | "it" is a pronoun standing in for the note just created; it names no app, so the slot was filled with the referring word instead of the referent. |
| `junk-continue-en` | “continue” | “in master” | *abstains today* | `honest_miss` | "continue" is a conversational continuation token — the user answering the engine's own "ask a follow-up to continue" — and it named nothing on screen; it became a click target because it was simply the one token that differed. |
| `verb-as-app-check-en` | “can you check premiere” | “caN you open premiere” | *abstains today* | `honest_miss` | "check" is the input's VERB. It was taken for an app-graph token because two installed bundle ids contain the substring "check", and the cross-app-hop branch's evidence gate is skipped when the remembered args carry no slot other than `app`. |
| `deictic-it-bare-en` | “open it” | “open premiere” | *abstains today* | — | Same defect as deictic-it-en with the filler stripped: one content token in, one content token out, and the token is a pronoun. |
| `deictic-that-en` | “open that” | “open premiere” | *abstains today* | — | "that" is a determiner, not a pronoun, so a Pronoun-only part-of-speech check leaks it — and it still names no app. |
| `deictic-clitic-aprilo-it` | “aprilo” | “open premiere” | *abstains today* | — | Italian "aprilo" = "open it": the pronoun is enclitic, fused into the verb, so the whole word survives tokenisation as one content token and lands in the app slot. |
| `antonym-chiudilo-it` | “chiudilo” | “open premiere” | *abstains today* | — | "chiudilo" = "close it": wrong twice over — a deictic in the slot AND the opposite verb to the remembered one, yet it reduces to a single differing token like any legitimate swap. |
| `antonym-close-premiere-en` | “close premiere” | “open premiere” | *abstains today* | — | The user asked to CLOSE an app; launching it is the opposite action on a perfectly valid app name, which is far harder to notice downstream than a nonsense one. |

## Correct — substitutions that must keep firing (8)

| id | input | generalised from | must fire | outcome then | why it is right |
|---|---|---|---|---|---|
| `entity-swap-huddle-simone` | “huddle with simone” | “huddle with michele” | `start_call(app: slack, person: simone)` | — | "simone" is a person the engine has actually SIGHTED in Slack, so the swapped slot value names a concrete known entity — the substitution the feature exists for. |
| `app-swap-open-resolve` | “open resolve” | “open premiere” | `launch_app(app: resolve)` | — | "resolve" resolves to an app that exists — DaVinci Resolve — so the slot is filled with a concrete known entity, through the identical code path as the pronoun bug. |
| `exact-replay-go-to-finder` | “go to finder” | “go to finder” | `open(app: finder)` | `found_acted` | Same phrase, same tokens, nothing substituted — the zero-model replay in its simplest and safest form. |
| `app-swap-go-to-premiere` | “go to premiere” | “go to finder” | `open(app: premiere)` | `found_acted` | "premiere" names an installed, sighted app, so retargeting the remembered `open` at it is exactly right. |
| `exact-replay-can-you-open-premiere` | “can you open premiere” | “can you open premiere” | `launch_app(app: premiere)` | `found_acted` | The memory behind the worst misfire in the store is itself a good memory: asked again verbatim, it is the right answer with no substitution at all. |
| `exact-replay-reveal-downloads` | “reveal the downloads folder in finder” | “reveal the downloads folder in finder” | `open(app: finder, place: Downloads)` | `acted_noop` | A multi-slot replay that must keep both slots intact, and whose honest outcome was `acted_noop` — nothing moved because it was already right. |
| `token-match-open-davinci-now` | “open davinci now” | “in davinci now” | `open(app: davinci)` | `found_acted` | Different surface phrasing, identical content tokens ("open" and "in" are both stopwords), so nothing is substituted — a paraphrase the deterministic matcher already handles for free. |
| `exact-replay-go-to-documents` | “in finder go to my Documents folder and then my Desktop folder” | “in finder go to my Documents folder and then my Desktop folder” | `go_to_folder(app: finder, path: ~/Documents)` | — | A long phrase replays verbatim from its own row — correct as recorded, and the case that shows an Experience holds ONE verb even when the sentence asked for two. |

## Watch — legitimate paraphrases that miss today (2)

Recorded, not required. They are the accuracy work (ticket 05), and they are here so that work has a
before/after instead of an anecdote.

| id | input | remembered | what firing should look like | why it misses |
|---|---|---|---|---|
| `paraphrase-apri-premiere-it` | “apri premiere” | “caN you open premiere” | `launch_app(app: premiere)` | Italian for "open premiere", asking for exactly what the memory holds; it misses today because the remembered phrase carries English filler ("can", "you") that the Italian phrasing has no counterpart for. |
| `paraphrase-launch-premiere-please-en` | “launch premiere please” | “caN you open premiere” | `launch_app(app: premiere)` | A plain English synonym of the remembered request that shares its only content word, yet misses because "launch"/"please" and "can"/"you" leave two residual tokens on each side. |

## Provenance

- **session** — A Claude Code session transcript under ~/.claude/projects/-Users-ronaldozefi-proj-test-fflow/. `ref` is the session id, `when` the message timestamp, `quote` the engine's own line verbatim from the gemini frontend block pasted there. These are field observations: the misfire happened to Ron, in a real session, on a deployed engine.
- **live-store** — A row in the operator's live experience table (~/Library/Application Support/Locator/locator.db), read 2026-08-22. `ref` is the phrase, which is that table's identity.
- **measurement** — A reproduction against the two pure functions, recorded in docs/codex/2026-08-22-apple-native-semantic-recall.md. Not a field sighting — the phrase was never said in production — but the mechanism is the same code path as its field siblings.
- **derived** — Constructed for coverage of a class the field has not hit yet (Italian enclitics, antonyms). Its `today` is measured here like every other case; only the INPUT is ours.

| id | source | ref | when |
|---|---|---|---|
| `deictic-it-en` | session | `7c1f7a9b-baff-4bce-8ce1-3045d559ad74` | 2026-08-17T21:24:06Z |
| `deictic-it-en` | live-store | `can you open it` | 2026-08-17T21:19:24Z |
| `junk-continue-en` | session | `7c1f7a9b-baff-4bce-8ce1-3045d559ad74` | 2026-08-12T17:04:27Z |
| `verb-as-app-check-en` | session | `7c1f7a9b-baff-4bce-8ce1-3045d559ad74` | 2026-08-17T20:26:11Z |
| `verb-as-app-check-en` | live-store | `can you check premiere` | 2026-08-17T20:18:38Z |
| `deictic-it-bare-en` | measurement | docs/codex/2026-08-22-apple-native-semantic-recall.md §5 | 2026-08-22 |
| `deictic-that-en` | measurement | docs/codex/2026-08-22-apple-native-semantic-recall.md §5 | 2026-08-22 |
| `deictic-that-en` | measurement | docs/codex/2026-08-22-apple-native-semantic-recall.md §2 | 2026-08-22 |
| `deictic-clitic-aprilo-it` | measurement | docs/codex/2026-08-22-apple-native-semantic-recall.md §5 | 2026-08-22 |
| `deictic-clitic-aprilo-it` | measurement | docs/codex/2026-08-22-apple-native-semantic-recall.md §2 | 2026-08-22 |
| `antonym-chiudilo-it` | derived | docs/codex/2026-08-22-apple-native-semantic-recall.md §2 | 2026-08-22 |
| `antonym-close-premiere-en` | measurement | docs/codex/2026-08-22-apple-native-semantic-recall.md §1 | 2026-08-22 |
| `entity-swap-huddle-simone` | session | `7c1f7a9b-baff-4bce-8ce1-3045d559ad74` | 2026-07-12T03:20:59Z |
| `entity-swap-huddle-simone` | live-store | `huddle with simone` | 2026-07-12T03:20:56Z |
| `app-swap-open-resolve` | measurement | docs/codex/2026-08-22-apple-native-semantic-recall.md §5 | 2026-08-22 |
| `app-swap-open-resolve` | live-store | `open davinci now` | 2026-08-17T20:20:06Z |
| `exact-replay-go-to-finder` | session | `7c1f7a9b-baff-4bce-8ce1-3045d559ad74` | 2026-08-11T20:39:22Z |
| `exact-replay-go-to-finder` | live-store | `go to finder` | 2026-08-11T20:39:46Z |
| `app-swap-go-to-premiere` | session | `7c1f7a9b-baff-4bce-8ce1-3045d559ad74` | 2026-08-11T20:39:51Z |
| `app-swap-go-to-premiere` | live-store | `go to premiere` | 2026-08-11T20:39:42Z |
| `exact-replay-can-you-open-premiere` | session | `7c1f7a9b-baff-4bce-8ce1-3045d559ad74` | 2026-08-14T13:53:25Z |
| `exact-replay-can-you-open-premiere` | live-store | `can you open premiere` | 2026-08-18T14:44:07Z |
| `exact-replay-reveal-downloads` | session | `7c1f7a9b-baff-4bce-8ce1-3045d559ad74` | 2026-08-17T17:48:18Z |
| `exact-replay-reveal-downloads` | live-store | `reveal the downloads folder in finder` | 2026-08-17T17:48:18Z |
| `token-match-open-davinci-now` | session | `7c1f7a9b-baff-4bce-8ce1-3045d559ad74` | 2026-08-17T20:26:11Z |
| `token-match-open-davinci-now` | live-store | `open davinci now` | 2026-08-17T20:20:06Z |
| `exact-replay-go-to-documents` | session | `7c1f7a9b-baff-4bce-8ce1-3045d559ad74` | 2026-08-12T09:33:46Z |
| `paraphrase-apri-premiere-it` | measurement | docs/codex/2026-08-22-apple-native-semantic-recall.md §1 | 2026-08-22 |
| `paraphrase-launch-premiere-please-en` | measurement | docs/codex/2026-08-22-apple-native-semantic-recall.md §1 | 2026-08-22 |

### The quotes themselves

The engine's own words, so a disputed case can be re-checked without re-reading a transcript.

**`deictic-it-en`** — “can you open it”

> [session · 7c1f7a9b-baff-4bce-8ce1-3045d559ad74 · 2026-08-17T21:24:06Z] you› can you open it / ⚡ memory: generalized from "caN you open premiere" ✓×3: premiere → it / ⚡ launch_app(app: it) — no model round / → honest_miss: it matches several open apps (com.apple.AccessibilityInspector, com.apple.TextEdit) — pass the exact bundle id

> [live-store · can you open it · 2026-08-17T21:19:24Z] can you open it | launch_app | {"app":"com.apple.Notes"} | ok=1 fail=1 — the model's repair after the misfire is what the store now holds

The swap note is the oneSwap form (": premiere → it"), which is itself evidence that "it" matched no bundle in the live graph — the cross-app-hop branch would have printed "· → it". The memory it generalised from is the single most-reused row in the whole store (✓×3 then, ✓×4 now): repetition was read as confidence, and this is what it bought.

**`junk-continue-en`** — “continue”

> [session · 7c1f7a9b-baff-4bce-8ce1-3045d559ad74 · 2026-08-12T17:04:27Z] (tool budget hit — answered from gathered context; ask a follow-up to continue) / you› continue / ⚡ memory: generalized from "in master" ✓×1: master → continue / ⚡ act(app: com.blackmagic-design.DaVinciResolve, section: sidebar (Master), target: continue, verb: click) — no model round / → honest_miss: no element 'continue' in DaVinci Resolve

Shows the misfire class is not about pronouns: a bare discourse word is enough. It also shows the swap is value-scoped — "sidebar (Master)" survived because its core is "sidebarmaster", not "master".

**`verb-as-app-check-en`** — “can you check premiere”

> [session · 7c1f7a9b-baff-4bce-8ce1-3045d559ad74 · 2026-08-17T20:26:11Z] you› can you check premiere / ⚡ memory: generalized from "caN you open premiere" ✓×3 · → check / ⚡ launch_app(app: check) — no model round / → honest_miss: 'check' matches several installed apps: AAF Checker 2 [hylo.AAF-Checker], AAF Checker by Forte AI [com.forte-ai.aafchecker] — pass the exact bundle id

> [live-store · can you check premiere · 2026-08-17T20:18:38Z] can you check premiere | launch_app | {"app":"check"} | ok=0 fail=1

The load-bearing case for the gate's SHAPE: the hop branch is the one whose comment claims evidence, and it still fired, because `entities` was empty and the guard is written `if !entities.isEmpty`. Substring-of-a-bundle-id is not entity evidence — it is why an English verb resolved to an app. Compare app-swap-go-to-premiere, which is the same branch answering correctly.

**`deictic-it-bare-en`** — “open it”

> [measurement · docs/codex/2026-08-22-apple-native-semantic-recall.md §5 · 2026-08-22] open it  tokens=["it"]  onlyMem=["premiere"] onlyIn=["it"]  oneSwap=YES => launch_app(app: "it")

The minimal form of the bug — kept because it is the one a fix is easiest to reason about, and because "open" being a stopword while "it" is not is the whole mechanism in two tokens.

**`deictic-that-en`** — “open that”

> [measurement · docs/codex/2026-08-22-apple-native-semantic-recall.md §5 · 2026-08-22] open that  tokens=["that"]  onlyMem=["premiere"] onlyIn=["that"]  oneSwap=YES => launch_app(app: "that")

> [measurement · docs/codex/2026-08-22-apple-native-semantic-recall.md §2 · 2026-08-22] "open that" -> [("open","Verb"), ("that","Determiner")]   <-- not Pronoun

Guards the early-out against being written as `== Pronoun`.

**`deictic-clitic-aprilo-it`** — “aprilo”

> [measurement · docs/codex/2026-08-22-apple-native-semantic-recall.md §5 · 2026-08-22] aprilo  tokens=["aprilo"]  onlyMem=["premiere"] onlyIn=["aprilo"]  oneSwap=YES => launch_app(app: "aprilo")

> [measurement · docs/codex/2026-08-22-apple-native-semantic-recall.md §2 · 2026-08-22] "aprilo"   (it) -> [("aprilo","Noun")]      <-- "open it": the pronoun is FUSED into the verb

THE Italian trap named in the spec: a clitic verb tags as a Noun, so the part-of-speech early-out is blind here and only the entity gate can refuse it. Ron speaks both languages, so this is a production phrasing, not an exotic one — note that bare "apri" is already a stopword in Route.stopwords while "aprilo" is not.

**`antonym-chiudilo-it`** — “chiudilo”

> [derived · docs/codex/2026-08-22-apple-native-semantic-recall.md §2 · 2026-08-22] "chiudilo" (it) -> [("chiudilo","Verb")]

Covers the class the research doc warned a similarity threshold would ADMIT (topic without polarity). Here it is worse than the English antonym, because the clitic also hides a pronoun.

**`antonym-close-premiere-en`** — “close premiere”

> [measurement · docs/codex/2026-08-22-apple-native-semantic-recall.md §1 · 2026-08-22] 0.6397  SHOULD-ABSTAIN  close premiere      <-- WRONG VERB, ranked above two valid paraphrases

A guard, not a bug report: today's deterministic matcher already abstains here ("close" is an extra token, not a swap). It is in the corpus because the tightest embedding threshold that keeps the legitimate paraphrases admits exactly this — so any future retrieval change must be shown against it. Per ADR 0002 this stays a red line, not a target.

**`entity-swap-huddle-simone`** — “huddle with simone”

> [session · 7c1f7a9b-baff-4bce-8ce1-3045d559ad74 · 2026-07-12T03:20:59Z] === retest: 'huddle with simone' should IMITATE from the michele memory (⚡, zero model) === / you› ⚡ memory: generalized from "huddle with michele" ✓×1: michele → simone / ⚡ start_call(app: slack, person: simone) — no model round / → call panel is OPEN for simone

> [live-store · huddle with simone · 2026-07-12T03:20:56Z] huddle with simone | start_call | {"app":"slack","person":"simone"} | ok=1 fail=0

The oldest case in the store and the reason the one-token swap was built. If a fix breaks this, the fix is wrong. The transcript's result line carries no outcome token, so none is recorded here; the harness line immediately after it read "huddle with simone → start_call ok=1", which is the store's own verdict that it worked.

**`app-swap-open-resolve`** — “open resolve”

> [measurement · docs/codex/2026-08-22-apple-native-semantic-recall.md §5 · 2026-08-22] open resolve  tokens=["resolve"] onlyMem=["premiere"] onlyIn=["resolve"] oneSwap=YES => launch_app(app: "resolve")

> [live-store · open davinci now · 2026-08-17T20:20:06Z] the app-name swap is not hypothetical in production: open davinci now | open | {"app":"davinci"} | ok=2 fail=0

Named in the spec as the substitution that MUST keep working ("a corpus of only failures would push the next fix into refusing everything"). Its twin is deictic-it-bare-en: same memory, same branch, one differing token each — the only thing that separates them is whether the token names something real.

**`exact-replay-go-to-finder`** — “go to finder”

> [session · 7c1f7a9b-baff-4bce-8ce1-3045d559ad74 · 2026-08-11T20:39:22Z] == TEST 1: exact replay ('go to finder' — recorded earlier) == / you› ⚡ memory: remembered: "go to finder" ✓×1 / ⚡ open(app: finder) — no model round / → found_acted: Finder is now frontmost

> [live-store · go to finder · 2026-08-11T20:39:46Z] go to finder | open | {"app":"finder"} | ok=3 fail=0 — one of only four rows ever reused

No substitution happens, so no gate may touch it. It is here so that a fix aimed at substitution cannot accidentally cost the engine its cheapest correct answer.

**`app-swap-go-to-premiere`** — “go to premiere”

> [session · 7c1f7a9b-baff-4bce-8ce1-3045d559ad74 · 2026-08-11T20:39:51Z] == TEST 2: one-token variant ('go to premiere' — never recorded) == / you› ⚡ memory: generalized from "go to finder" ✓×2 · → premiere / ⚡ open(app: premiere) — no model round / → found_acted: Adobe Premiere is now frontmost

> [live-store · go to premiere · 2026-08-11T20:39:42Z] go to premiere | open | {"app":"premiere"} | ok=1 fail=0 — the variant was then recorded as its own row

The right answer from the SAME branch that got verb-as-app-check-en wrong (both print the "· → x" hop note). Read the two together: today the engine cannot tell an app name from an English verb that happens to be a substring of some bundle id, and both slip through on an empty `entities` list.

**`exact-replay-can-you-open-premiere`** — “can you open premiere”

> [session · 7c1f7a9b-baff-4bce-8ce1-3045d559ad74 · 2026-08-14T13:53:25Z] you› can you open premiere / ⚡ memory: remembered: "can you open premiere" ✓×1 / ⚡ launch_app(app: premiere) — no model round / → found_acted: Adobe Premiere was already running — brought frontmost

> [live-store · can you open premiere · 2026-08-18T14:44:07Z] can you open premiere | launch_app | {"app":"premiere"} | ok=4 fail=0 — the most-reused row in the store

Keeps the fix honest about WHAT to retract: the Experience is not poison, its unguarded generalisation was. A fix that stops this from firing has thrown away a Belief that earned itself four times.

**`exact-replay-reveal-downloads`** — “reveal the downloads folder in finder”

> [session · 7c1f7a9b-baff-4bce-8ce1-3045d559ad74 · 2026-08-17T17:48:18Z] you› ⚡ memory: remembered: "reveal the downloads folder in finder" ✓×1 / ⚡ open(app: finder, place: Downloads) — no model round / → acted_noop: already there — the window is "Downloads", which satisfies 'Downloads'

> [live-store · reveal the downloads folder in finder · 2026-08-17T17:48:18Z] reveal the downloads folder in finder | open | {"app":"finder","place":"Downloads"} | ok=2 fail=0

The outcome matters beyond this ticket: `acted_noop` here is not a Contradiction (the memory was right; the world was already in the wanted state), and the store agrees — the row went to ok=2.

**`token-match-open-davinci-now`** — “open davinci now”

> [session · 7c1f7a9b-baff-4bce-8ce1-3045d559ad74 · 2026-08-17T20:26:11Z] you› open davinci now / ⚡ memory: remembered: "in davinci now" ✓×1 / ⚡ open(app: davinci) — no model round / → found_acted: DaVinci Resolve is now frontmost

> [live-store · open davinci now · 2026-08-17T20:20:06Z] open davinci now | open | {"app":"davinci"} | ok=2 fail=0 — the upsert is keyed on tokens, so the row's PHRASE was rewritten to the newer wording and the count accumulated

The cheap half of what lemmatisation would extend: stopword-stripping already absorbs some paraphrase. Also documents that the store's `phrase` column is the LATEST wording for a token set, not the first — which is why a corpus case must carry the phrase the transcript showed.

**`exact-replay-go-to-documents`** — “in finder go to my Documents folder and then my Desktop folder”

> [session · 7c1f7a9b-baff-4bce-8ce1-3045d559ad74 · 2026-08-12T09:33:46Z] you› ⚡ memory: remembered: "in finder go to my Documents folder and then my Desktop folder" ✓×1 / ⚡ go_to_folder(app: finder, path: ~/Documents) — no model round / === finder routes now === / []

Honest limit, recorded rather than hidden: the Desktop half of the request is not in the memory, so imitation answers the first verb only. That is a Route-vs-Experience question and explicitly out of this spec's scope; it is here so nobody reads the corpus as claiming the replay was COMPLETE. The transcript shows the call but no outcome line — the block it was pasted from cuts to the route listing — so no outcome is claimed for it.

**`paraphrase-apri-premiere-it`** — “apri premiere”

> [measurement · docs/codex/2026-08-22-apple-native-semantic-recall.md §1 · 2026-08-22] 0.5600  SHOULD-FIRE     apri premiere

Ticket 05's recorded miss. Note the asymmetry the corpus makes visible: against the shorter memory "open premiere" this fires already ("apri" is a stopword, so both reduce to {premiere}) — it is the English chat filler in the remembered phrase, not the Italian, that breaks it. A fix here must not be bought by loosening the swap rule.

**`paraphrase-launch-premiere-please-en`** — “launch premiere please”

> [measurement · docs/codex/2026-08-22-apple-native-semantic-recall.md §1 · 2026-08-22] 0.8061  SHOULD-FIRE     launch premiere please

The English twin of the Italian miss, so a future accuracy fix can be shown to be about phrasing generally and not about one language. Firing is a win; firing with any other app is a regression.

## Two pairs worth reading side by side

**`deictic-it-bare-en` and `app-swap-open-resolve`** — the same memory (“open premiere”), the same
branch, one differing token each. `it` names nothing; `resolve` names DaVinci Resolve. Nothing in the
engine currently tells them apart, and that difference is the whole fix.

**`verb-as-app-check-en` and `app-swap-go-to-premiere`** — both take the *cross-app-hop* branch, the
one whose own comment promises evidence (“never guessed”). `premiere` is an app; `check` is an English
verb that happens to be a substring of two installed bundle ids. Both slipped through, because the
gate is written `if !entities.isEmpty` and a remembered call with only an `app` slot has no entities
to check. Substring-of-a-bundle-id is not entity evidence.

## What the corpus does not claim

- It is **not** a sample of everything recall does. It is the failures we can attribute plus the
  successes worth protecting — 18 cases against a 200-row live store.
- `exact-replay-go-to-documents` replays only the first of two requested folders. That is recorded as
  a limit of one-verb Experiences, not as a claim that the replay was complete.
- The `measurement` and `derived` cases were never said in production. Their mechanism is the same
  code path as their field siblings, and the corpus says which is which so nobody has to guess.
- Where a transcript line carried no outcome token, none is recorded. Two cases
  (`entity-swap-huddle-simone`, `exact-replay-go-to-documents`) show a call with no outcome for exactly
  that reason.
