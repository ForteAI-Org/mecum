-- Mecum Brain and living memory: the schema resource of the SQLiteMemory module.
-- Base: the S0 closing candidate v5 (41 tables, 32 triggers, 27 explicit indexes; sha256
-- f3e651892c6af2ff87d48109666b0d4727485605add37b6eddd51e23d2e55d86), whose logical model Ron
-- approved at v3. This resource is a CANDIDATE: the contract items of the v4->v5 diff are still to
-- be reconciled before it is frozen. Documentation/Engine/MemorySchema.md lists every difference
-- from the archived v5 with its reason and its test.
-- S1 corrections to v5: a structural role or label cannot be moved onto the app scope (UPDATE);
-- a capture sample that a scene association references keeps its whole identity, event_id
-- included (UPDATE), and cannot be deleted. Four triggers added, one narrowed: 36 triggers.
-- S2 (second increment, the brain's projection): brain_anchors.current_group_id, nullable, with a
-- per-app foreign key to brain_groups: ObjectAnchor.groupID is the one group the algorithm last
-- assigned, a datum distinct from the ordered membership (an anchor may be a member of two
-- groups). No table, trigger or index added; still schema 1.
-- S2 (increment 3a, the brain's applications): brain_applications, the register of every concluded
-- application of an observation, a record or a naming to the projection, changes or not; its
-- complete input in memory_operation_arguments under a third owner, brain_application_id; the
-- capture key memory_event_observations needs as the parent of a sample reference; two partial
-- unique keys, a lookup index, and the triggers that seal and keep an application. 42 tables,
-- 42 triggers, 31 explicit indexes; still schema 1.
-- What v5 changed against v4, all motivated in the S0 diff:
--   A. app scope (decision 14): scene_kind is a closed vocabulary, the 'app' row has a fixed
--      shape, one per app, no element/role/label/association/evidence on the scope, no
--      transition into the scope; scene_kind is immutable.
--   B. observable orders: alias position; insertion_order of anchors, groups and transitions.
--   C. null-safe constraints and vocabularies of plan 1, section 3: IS / IS NOT triggers on the
--      derived app_id, immutable event identity, verification <-> membership, Watcher
--      correlations, Route and operation cycles; CHECK on the closed domains.
--   D. samples with quality (S0 part 3, section 3): identity event+phase+ordinal, typed capture
--      row, label origin, structural path, surface; the event-scene relation carries the ordinal;
--      confirmation only from a complete capture.
-- 41 tables, no JSON column, no import, no new retention or recall policy.
-- SQLite >= 3.37 (STRICT); >= 3.51.3 for concurrent WAL (plan 1). foreign_keys on EVERY connection.
-- This file carries no PRAGMA, BEGIN or COMMIT of its own: the store's bootstrap runs it inside
-- one write transaction, enables foreign keys per connection and sets user_version = 1 in that
-- same transaction.

-- Canonical knowledge per application. No import of the previous JSON files.
CREATE TABLE brain_apps (
    app_id INTEGER PRIMARY KEY,
    bundle_id TEXT NOT NULL UNIQUE,
    ingest_epoch INTEGER NOT NULL DEFAULT 0,
    last_epoch_advance_ms INTEGER
) STRICT;

-- Clock of the window families: UIBrain.windowEpochs, one row per family.
CREATE TABLE brain_app_window_epochs (
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    window_family TEXT NOT NULL,
    epoch INTEGER NOT NULL CHECK (epoch >= 0),
    PRIMARY KEY (app_id, window_family)
) STRICT;

-- Observed version and locale; the empty string means unknown.
CREATE TABLE brain_app_contexts (
    context_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    app_version TEXT NOT NULL DEFAULT '',
    app_locale TEXT NOT NULL DEFAULT '',
    UNIQUE (app_id, app_version, app_locale),
    UNIQUE (app_id, context_id)
) STRICT;

-- A structural scene, or (scene_kind='app') the SCOPE of the current per-application knowledge.
-- The app scope is not a perceived surface: no element, role, label or fingerprint;
-- observation_count=0; title_bucket = '#app' (a marker: LabelText.letters never produces '#').
-- Title and fingerprint of a structural scene are NOT its identity and are NOT UNIQUE.
CREATE TABLE brain_scenes (
    scene_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    window_title_pattern TEXT,
    title_bucket TEXT NOT NULL,
    scene_kind TEXT NOT NULL DEFAULT 'window'
        CHECK (scene_kind IN ('window', 'dialog', 'sheet', 'app')),
    structural_key TEXT,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    observation_count INTEGER NOT NULL DEFAULT 1 CHECK (observation_count >= 0),
    UNIQUE (app_id, scene_id),
    CHECK (last_seen_ms >= first_seen_ms),
    CHECK (scene_kind <> 'app' OR (structural_key IS NULL AND window_title_pattern IS NULL
                                    AND title_bucket = '#app' AND observation_count = 0)),
    CHECK (scene_kind = 'app' OR title_bucket <> '#app')
) STRICT;

-- The global set of AX roles of a scene. count_bucket NULL = presence only (structure-v2 uses no
-- counts); a value is allowed for compatibility with v3.
CREATE TABLE brain_scene_roles (
    scene_id TEXT NOT NULL REFERENCES brain_scenes(scene_id),
    role TEXT NOT NULL,
    count_bucket INTEGER CHECK (count_bucket IS NULL OR count_bucket >= 0),
    PRIMARY KEY (scene_id, role)
) STRICT;

CREATE TABLE brain_scene_labels (
    scene_id TEXT NOT NULL REFERENCES brain_scenes(scene_id),
    label_token TEXT NOT NULL,
    PRIMARY KEY (scene_id, label_token)
) STRICT;

-- insertion_order reproduces the order of the UIBrain.objects array (observable: the cap on
-- ties, the index, Equatable). Aliases have a position (UIBrain uses aliases.first and prefix(3)).
-- current_group_id is ObjectAnchor.groupID: the group the algorithm last assigned, or NULL; it is
-- not derived from brain_group_members, which keeps every ordered membership, and nothing limits
-- an anchor to one group. A retired group keeps the reference valid.
CREATE TABLE brain_anchors (
    anchor_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    insertion_order INTEGER NOT NULL CHECK (insertion_order >= 0),
    kind TEXT NOT NULL,
    label TEXT NOT NULL,
    label_source TEXT CHECK (label_source IS NULL OR label_source IN ('observed', 'llm', 'user')),
    anchor_scope TEXT NOT NULL DEFAULT 'control'
        CHECK (anchor_scope IN ('control', 'collection', 'item_template')),
    typical_x REAL,
    typical_y REAL,
    typical_width REAL,
    typical_height REAL,
    window_family TEXT,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    seen_count INTEGER NOT NULL DEFAULT 1 CHECK (seen_count >= 0),
    last_seen_epoch INTEGER,
    current_group_id TEXT,
    retired_at_ms INTEGER,
    retired_epoch INTEGER CHECK (retired_epoch IS NULL OR retired_epoch >= 0),
    retirement_cause TEXT CHECK (retirement_cause IS NULL OR retirement_cause IN ('transient', 'stale', 'backstop', 'cap')),
    UNIQUE (app_id, anchor_id),
    UNIQUE (app_id, insertion_order),
    FOREIGN KEY (app_id, current_group_id) REFERENCES brain_groups(app_id, group_id),
    CHECK (last_seen_ms >= first_seen_ms),
    CHECK ((retired_at_ms IS NULL) = (retired_epoch IS NULL)),
    CHECK ((retired_at_ms IS NULL) = (retirement_cause IS NULL)),
    CHECK (retired_at_ms IS NULL OR retired_at_ms >= last_seen_ms)
) STRICT;

CREATE TABLE brain_anchor_aliases (
    anchor_id TEXT NOT NULL REFERENCES brain_anchors(anchor_id),
    alias TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    PRIMARY KEY (anchor_id, alias),
    UNIQUE (anchor_id, position)
) STRICT;

CREATE TABLE brain_anchor_states (
    anchor_id TEXT NOT NULL REFERENCES brain_anchors(anchor_id),
    state TEXT NOT NULL,
    seen_count INTEGER NOT NULL CHECK (seen_count >= 0),
    PRIMARY KEY (anchor_id, state)
) STRICT;

-- The structural skeleton of a scene: containers (a tree), controls with a caption, collections
-- and row templates. Real people and files stay in the events.
-- label_origin: the AX attribute the label came from; it does not prove a stable caption.
CREATE TABLE brain_scene_elements (
    scene_element_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL,
    scene_id TEXT NOT NULL,
    element_key TEXT NOT NULL,
    element_scope TEXT NOT NULL DEFAULT 'control'
        CHECK (element_scope IN ('container', 'control', 'collection', 'item_template')),
    parent_element_id TEXT,
    edge_hash TEXT,
    cursor_affordance TEXT,
    anchor_id TEXT,
    label TEXT,
    label_origin TEXT CHECK (label_origin IS NULL OR label_origin IN ('title', 'description', 'value', 'column', 'row_content')),
    role TEXT,
    kind TEXT,
    source TEXT,
    bounds_x REAL,
    bounds_y REAL,
    bounds_width REAL,
    bounds_height REAL,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    observation_count INTEGER NOT NULL DEFAULT 1 CHECK (observation_count >= 0),
    UNIQUE (scene_id, element_key),
    UNIQUE (app_id, scene_element_id),
    UNIQUE (scene_id, scene_element_id),
    UNIQUE (app_id, scene_id, scene_element_id),
    CHECK (parent_element_id IS NULL OR parent_element_id <> scene_element_id),
    FOREIGN KEY (scene_id, parent_element_id) REFERENCES brain_scene_elements(scene_id, scene_element_id),
    FOREIGN KEY (app_id, scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    CHECK (last_seen_ms >= first_seen_ms)
) STRICT;

CREATE TABLE brain_groups (
    group_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    insertion_order INTEGER NOT NULL CHECK (insertion_order >= 0),
    axis TEXT NOT NULL,
    shared_kind TEXT NOT NULL,
    cell_width REAL,
    cell_height REAL,
    name TEXT,
    last_seen_ms INTEGER NOT NULL,
    seen_count INTEGER NOT NULL DEFAULT 1 CHECK (seen_count >= 0),
    last_seen_epoch INTEGER,
    retired_at_ms INTEGER,
    retired_epoch INTEGER CHECK (retired_epoch IS NULL OR retired_epoch >= 0),
    retirement_cause TEXT CHECK (retirement_cause IS NULL OR retirement_cause IN ('members', 'stale', 'backstop')),
    UNIQUE (app_id, group_id),
    UNIQUE (app_id, insertion_order),
    CHECK ((retired_at_ms IS NULL) = (retired_epoch IS NULL)),
    CHECK ((retired_at_ms IS NULL) = (retirement_cause IS NULL)),
    CHECK (retired_at_ms IS NULL OR retired_at_ms >= last_seen_ms)
) STRICT;

-- Membership is the projection of SiblingGroup.memberAnchors (ordered along the axis):
-- position is rewritten at every merge; a row is deleted when the member leaves.
CREATE TABLE brain_group_members (
    app_id INTEGER NOT NULL,
    group_id TEXT NOT NULL,
    anchor_id TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    PRIMARY KEY (group_id, anchor_id),
    UNIQUE (group_id, position),
    FOREIGN KEY (app_id, group_id) REFERENCES brain_groups(app_id, group_id),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id)
) STRICT;

CREATE TABLE brain_menu_commands (
    menu_command_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    path_key TEXT NOT NULL,
    top_level_title TEXT NOT NULL,
    accessibility_identifier TEXT,
    has_submenu INTEGER NOT NULL CHECK (has_submenu IN (0, 1)),
    last_observed_enabled INTEGER NOT NULL CHECK (last_observed_enabled IN (0, 1)),
    mark_char TEXT,
    cmd_char TEXT,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    UNIQUE (app_id, menu_command_id),
    CHECK (last_seen_ms >= first_seen_ms)
) STRICT;

CREATE TABLE brain_menu_path_segments (
    menu_command_id TEXT NOT NULL REFERENCES brain_menu_commands(menu_command_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    title TEXT NOT NULL,
    PRIMARY KEY (menu_command_id, position)
) STRICT;

-- Graphs inside one application. from_scene_id may be the app scope (current anchor->effect
-- knowledge); to_scene_id NULL = unknown, never the app scope.
-- insertion_order reproduces UIBrain.transitions (observable: does/expectedEffect/revealers on ties).
CREATE TABLE brain_transitions (
    transition_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    insertion_order INTEGER NOT NULL CHECK (insertion_order >= 0),
    from_scene_id TEXT NOT NULL,
    anchor_id TEXT,
    scene_element_id TEXT,
    menu_command_id TEXT,
    trigger_kind TEXT NOT NULL,
    to_scene_id TEXT,
    effect_kind TEXT NOT NULL,
    effect_text TEXT,
    required_target_state TEXT,
    resulting_target_state TEXT,
    last_observed_epoch INTEGER,
    status TEXT NOT NULL CHECK (status IN ('candidate', 'trusted', 'rejected')),
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    evidence_count INTEGER NOT NULL DEFAULT 0 CHECK (evidence_count >= 0),
    retired_at_ms INTEGER,
    retired_epoch INTEGER CHECK (retired_epoch IS NULL OR retired_epoch >= 0),
    retirement_cause TEXT CHECK (retirement_cause IS NULL OR retirement_cause IN ('anchor', 'stale', 'coincidence', 'backstop')),
    FOREIGN KEY (app_id, from_scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, to_scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    FOREIGN KEY (app_id, menu_command_id) REFERENCES brain_menu_commands(app_id, menu_command_id),
    UNIQUE (app_id, transition_id),
    UNIQUE (app_id, insertion_order),
    CHECK ((anchor_id IS NOT NULL) + (scene_element_id IS NOT NULL) + (menu_command_id IS NOT NULL) <= 1),
    FOREIGN KEY (app_id, from_scene_id, scene_element_id)
        REFERENCES brain_scene_elements(app_id, scene_id, scene_element_id),
    CHECK (last_seen_ms >= first_seen_ms),
    CHECK ((retired_at_ms IS NULL) = (retired_epoch IS NULL)),
    CHECK ((retired_at_ms IS NULL) = (retirement_cause IS NULL)),
    CHECK (retired_at_ms IS NULL OR retired_at_ms >= last_seen_ms)
) STRICT;

CREATE TABLE brain_transition_menu_items (
    transition_id TEXT NOT NULL REFERENCES brain_transitions(transition_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    title TEXT NOT NULL,
    PRIMARY KEY (transition_id, position)
) STRICT;

-- Local write order, distinct from the source's time and order.
-- capture_status: the event's summary; per-sample quality lives in the capture row.
-- Identity and context are immutable after creation (trigger); only capture_status changes.
CREATE TABLE memory_events (
    local_order INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL,
    source_key TEXT,
    trace_id TEXT,
    session_id TEXT,
    parent_event_id TEXT REFERENCES memory_events(event_id),
    parent_position INTEGER CHECK (parent_position IS NULL OR parent_position >= 0),
    event_kind TEXT NOT NULL CHECK (event_kind IN ('action', 'input', 'observation', 'verification', 'diagnostic')),
    app_id INTEGER REFERENCES brain_apps(app_id),
    context_id INTEGER,
    occurred_at_ms INTEGER NOT NULL,
    monotonic_ns INTEGER,
    capture_status TEXT NOT NULL
        CHECK (capture_status IN ('not_applicable', 'complete', 'partial', 'failed', 'unknown')),
    -- S3-d correction: the call an observation was taken for, when a session observed on its own
    -- right after a call that could not name its application when planned (open_session). A
    -- durable reference apart from a batch's parent: an observation is no step.
    origin_event_id TEXT REFERENCES memory_events(event_id),
    UNIQUE (source, source_stream_id, source_key),
    UNIQUE (parent_event_id, parent_position),
    UNIQUE (app_id, event_id),
    UNIQUE (event_kind, event_id),
    CHECK ((parent_event_id IS NULL) = (parent_position IS NULL)),
    CHECK (parent_event_id IS NULL OR parent_event_id <> event_id),
    CHECK (context_id IS NULL OR app_id IS NOT NULL),
    CHECK (origin_event_id IS NULL OR event_kind = 'observation'),
    CHECK (origin_event_id IS NULL OR origin_event_id <> event_id),
    FOREIGN KEY (app_id, context_id) REFERENCES brain_app_contexts(app_id, context_id)
) STRICT;

CREATE TABLE memory_input_events (
    event_id TEXT PRIMARY KEY REFERENCES memory_events(event_id),
    event_kind TEXT NOT NULL DEFAULT 'input' CHECK (event_kind = 'input'),
    input_kind TEXT NOT NULL,
    sequence_number INTEGER,
    target_pid INTEGER,
    source_pid INTEGER,
    window_number INTEGER,
    window_title TEXT,
    window_x REAL,
    window_y REAL,
    window_width REAL,
    window_height REAL,
    point_x REAL,
    point_y REAL,
    delta_x REAL,
    delta_y REAL,
    started_at_ns INTEGER,
    ended_at_ns INTEGER,
    preceding_revision INTEGER,
    revision INTEGER,
    gap_first_sequence INTEGER,
    gap_last_sequence INTEGER,
    lost_critical INTEGER,
    lost_coalescible INTEGER,
    before_status TEXT,
    after_status TEXT,
    difference_status TEXT,
    FOREIGN KEY (event_kind, event_id) REFERENCES memory_events(event_kind, event_id)
) STRICT;

-- Signatures from the app's AutomationTools. Arguments have one place: memory_operation_arguments.
-- app_id is derived from the event (null-safe trigger): equal, or both NULL.
CREATE TABLE memory_agent_actions (
    event_id TEXT PRIMARY KEY REFERENCES memory_events(event_id),
    event_kind TEXT NOT NULL DEFAULT 'action' CHECK (event_kind = 'action'),
    app_id INTEGER,
    tool_kind TEXT NOT NULL,
    contract_version INTEGER NOT NULL DEFAULT 1 CHECK (contract_version > 0),
    execution_status TEXT NOT NULL CHECK (execution_status IN
        ('planned', 'started', 'completed', 'failed', 'cancelled', 'interrupted', 'skipped')),
    -- The calendar instant the tool was about to run (S3-d): NULL while planned, set at started and
    -- kept. completed_at_ms is the calendar instant of the end. Calendar instants are the chronology
    -- and may run backwards between them (a clock change): they are never subtracted.
    started_at_ms INTEGER,
    completed_at_ms INTEGER,
    -- How long the tool ran, measured by the producer on its own monotonic clock from started to the
    -- end (S3-d correction); only for a state reached from started.
    duration_ms INTEGER CHECK (duration_ms IS NULL OR duration_ms >= 0),
    result_kind TEXT,
    result_message TEXT,
    -- The effect the engine attributed to a completed action or input, typed by family (S3-d
    -- correction): observed_effect_text is the title of windowTitleChanged, the two states belong to
    -- stateFlip, and the labels of the three list families are rows of
    -- memory_agent_action_effect_labels, in order. No encoded text, no separators.
    observed_effect_kind TEXT CHECK (observed_effect_kind IS NULL OR observed_effect_kind IN
        ('windowTitleChanged', 'stateFlip', 'menuOpened', 'elementsAppeared', 'elementsDisappeared')),
    observed_effect_text TEXT,
    observed_state_before TEXT CHECK (observed_state_before IS NULL OR observed_state_before IN ('on', 'off', 'mixed', 'unknown')),
    observed_state_after TEXT CHECK (observed_state_after IS NULL OR observed_state_after IN ('on', 'off', 'mixed', 'unknown')),
    requested_count INTEGER CHECK (requested_count IS NULL OR requested_count >= 0),
    attempted_count INTEGER CHECK (attempted_count IS NULL OR attempted_count >= 0),
    verified_count INTEGER CHECK (verified_count IS NULL OR verified_count >= 0),
    UNIQUE (app_id, event_id),
    CHECK (started_at_ms IS NULL OR execution_status <> 'planned'),
    CHECK (duration_ms IS NULL OR execution_status IN ('completed', 'failed', 'cancelled', 'interrupted')),
    CHECK ((observed_effect_kind IS 'windowTitleChanged') = (observed_effect_text IS NOT NULL)),
    CHECK ((observed_effect_kind IS 'stateFlip') = (observed_state_before IS NOT NULL AND observed_state_after IS NOT NULL)),
    CHECK (observed_effect_kind IS 'stateFlip' OR (observed_state_before IS NULL AND observed_state_after IS NULL)),
    CHECK (observed_effect_kind IS NULL OR execution_status = 'completed'),
    CHECK (attempted_count IS NULL OR requested_count IS NULL OR attempted_count <= requested_count),
    CHECK (verified_count IS NULL OR attempted_count IS NULL OR verified_count <= attempted_count),
    FOREIGN KEY (event_kind, event_id) REFERENCES memory_events(event_kind, event_id),
    FOREIGN KEY (app_id, event_id) REFERENCES memory_events(app_id, event_id)
) STRICT;

-- S3-d correction: the labels of a list effect (menuOpened, elementsAppeared, elementsDisappeared),
-- one row per label in the engine's order; an empty label is a label; zero rows is an empty list.
CREATE TABLE memory_agent_action_effect_labels (
    event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    label TEXT NOT NULL,
    PRIMARY KEY (event_id, position)
) STRICT;

-- S3-d correction: the structured results of the listing and scene tools, one table per shape.
-- status: the session the host held and the three permissions as preflighted.
CREATE TABLE memory_agent_action_status (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    session_id TEXT,
    screen_recording INTEGER NOT NULL CHECK (screen_recording IN (0, 1)),
    accessibility INTEGER NOT NULL CHECK (accessibility IN (0, 1)),
    post_event INTEGER NOT NULL CHECK (post_event IN (0, 1))
) STRICT;

-- windows and apps: the listing's kind and how many candidates the answer left out.
CREATE TABLE memory_agent_action_listings (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    listing_kind TEXT NOT NULL CHECK (listing_kind IN ('windows', 'apps')),
    hidden_count INTEGER NOT NULL DEFAULT 0 CHECK (hidden_count >= 0)
) STRICT;

-- The applications a listing answered, in the order shown. A windows row carries the pid and no
-- apps field; an apps row carries is_running and no pid (trigger). NULL is a field the producer
-- did not know; the empty text is a text.
CREATE TABLE memory_agent_action_applications (
    event_id TEXT NOT NULL REFERENCES memory_agent_action_listings(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    name TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    pid INTEGER,
    app_version TEXT,
    is_running INTEGER CHECK (is_running IS NULL OR is_running IN (0, 1)),
    location TEXT,
    PRIMARY KEY (event_id, position),
    CHECK (length(name) > 0 OR length(bundle_id) > 0)
) STRICT;

-- The windows of one listed application, in the order listed; a title the window server did not
-- report is NULL.
CREATE TABLE memory_agent_action_windows (
    event_id TEXT NOT NULL,
    application_position INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    window_number INTEGER NOT NULL,
    title TEXT,
    PRIMARY KEY (event_id, application_position, position),
    FOREIGN KEY (event_id, application_position) REFERENCES memory_agent_action_applications(event_id, position)
) STRICT;

-- open_session and observe: the session and its revision the scene was taken at, the calendar
-- instant the answer carried, and the real sample (current, primary) the scene text was rendered
-- from: the call's own event for observe, the session's own observation event for open_session.
CREATE TABLE memory_agent_action_observations (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    session_id TEXT NOT NULL CHECK (length(session_id) > 0),
    session_revision INTEGER NOT NULL CHECK (session_revision >= 0),
    observed_at_ms INTEGER NOT NULL,
    sample_event_id TEXT NOT NULL,
    sample_phase TEXT NOT NULL DEFAULT 'current' CHECK (sample_phase = 'current'),
    sample_ordinal INTEGER NOT NULL DEFAULT 0 CHECK (sample_ordinal >= 0),
    sample_observation_id INTEGER NOT NULL,
    sample_kind TEXT NOT NULL DEFAULT 'capture' CHECK (sample_kind = 'capture'),
    FOREIGN KEY (sample_observation_id, sample_event_id, sample_phase, sample_ordinal, sample_kind)
        REFERENCES memory_event_observations(observation_id, event_id, phase, sample_ordinal, observation_kind)
) STRICT;

-- Samples, elements, differences and typed diagnostic values. No serialized dump.
-- A SAMPLE is a row with observation_kind='capture' identified by (event, phase, ordinal):
-- status = the capture's quality; window_title, session_revision (the producer's ordinal),
-- surface_kind; the quality fields (walk_completed, stopped_by, window_found, grant_available,
-- window_subrole, nodes_visited, elements_emitted) are 'capture_field' child rows.
-- The sample's elements are child rows with role, label_origin and container_path
-- (structural path truncated at the collection: never row names).
-- Ordinal 0 = the primary sample: the perception the engine actually used in that phase.
CREATE TABLE memory_event_observations (
    observation_id INTEGER PRIMARY KEY,
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    phase TEXT NOT NULL CHECK (phase IN ('before', 'menu', 'after', 'current')),
    sample_ordinal INTEGER NOT NULL DEFAULT 0 CHECK (sample_ordinal >= 0),
    observation_kind TEXT NOT NULL,
    observation_contract_version INTEGER NOT NULL DEFAULT 1 CHECK (observation_contract_version > 0),
    field_name TEXT,
    text_value TEXT,
    integer_value INTEGER,
    real_value REAL,
    boolean_value INTEGER CHECK (boolean_value IN (0, 1)),
    observation_group INTEGER,
    parent_observation_id INTEGER,
    window_title TEXT,
    session_revision INTEGER,
    surface_kind TEXT CHECK (surface_kind IS NULL OR surface_kind IN ('window', 'dialog', 'sheet', 'popup_union', 'unknown')),
    status TEXT NOT NULL,
    candidate_rank INTEGER,
    label TEXT,
    label_origin TEXT CHECK (label_origin IS NULL OR label_origin IN ('title', 'description', 'value', 'column', 'row_content')),
    container_path TEXT,
    role TEXT,
    element_kind TEXT,
    old_state TEXT,
    new_state TEXT,
    bounds_x REAL,
    bounds_y REAL,
    bounds_width REAL,
    bounds_height REAL,
    scene_age_ms REAL,
    name_resolution TEXT,
    label_source TEXT,
    UNIQUE (event_id, observation_id),
    CHECK ((text_value IS NOT NULL) + (integer_value IS NOT NULL) +
           (real_value IS NOT NULL) + (boolean_value IS NOT NULL) <= 1),
    CHECK (parent_observation_id IS NULL OR parent_observation_id <> observation_id),
    CHECK (observation_kind <> 'capture'
           OR (parent_observation_id IS NULL AND status IN ('complete', 'partial', 'failed', 'unknown'))),
    -- S2 3a: the parent key of a brain application's sample: the row, its event, phase, ordinal and kind.
    UNIQUE (observation_id, event_id, phase, sample_ordinal, observation_kind),
    FOREIGN KEY (event_id, parent_observation_id) REFERENCES memory_event_observations(event_id, observation_id)
) STRICT;

-- Zero rows = no candidate scene. At most one confirmed match per sample (event, phase, ordinal).
-- A sample exists as a capture row; it confirms only when complete. Never toward the app scope
-- (trigger).
CREATE TABLE memory_event_scenes (
    event_id TEXT NOT NULL,
    app_id INTEGER NOT NULL,
    phase TEXT NOT NULL CHECK (phase IN ('before', 'after', 'current')),
    sample_ordinal INTEGER NOT NULL DEFAULT 0 CHECK (sample_ordinal >= 0),
    scene_id TEXT NOT NULL,
    match_status TEXT NOT NULL CHECK (match_status IN ('candidate', 'confirmed', 'rejected')),
    matched_by TEXT NOT NULL,
    matcher_version TEXT NOT NULL,
    confidence REAL CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    PRIMARY KEY (event_id, phase, sample_ordinal, scene_id),
    FOREIGN KEY (app_id, event_id) REFERENCES memory_events(app_id, event_id),
    FOREIGN KEY (app_id, scene_id) REFERENCES brain_scenes(app_id, scene_id)
) STRICT;

CREATE TABLE memory_verifications (
    event_id TEXT PRIMARY KEY REFERENCES memory_events(event_id),
    event_kind TEXT NOT NULL DEFAULT 'verification' CHECK (event_kind = 'verification'),
    step_occurrence_id TEXT REFERENCES memory_step_occurrences(step_occurrence_id),
    scope TEXT NOT NULL,
    method TEXT NOT NULL,
    verdict TEXT NOT NULL CHECK (verdict IN ('passed', 'failed', 'unknown')),
    expected_text TEXT,
    observed_text TEXT,
    FOREIGN KEY (event_kind, event_id) REFERENCES memory_events(event_kind, event_id)
) STRICT;

-- First event: watcher source, input kind. Second: an action of app or cli (trigger).
CREATE TABLE memory_action_correlations (
    watcher_event_id TEXT PRIMARY KEY REFERENCES memory_events(event_id),
    agent_event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    basis_kind TEXT NOT NULL,
    time_offset_ms REAL,
    explanation TEXT,
    CHECK (watcher_event_id <> agent_event_id)
) STRICT;

-- S2 3a. A brain application is one concluded decision of the current algorithm about one fact: an
-- observation by (event, phase, ordinal) of a real capture sample, a record or a naming by the
-- event of its action. Written once, in the transaction that applied it, after its arguments
-- (which its insert seals) and never changed or removed: a later offer of the same key answers the
-- stored outcome. requested_at_ms is the instant asked for, effective_at_ms the application's
-- clock, never earlier than any instant the application's brain already holds. The outcome's
-- columns are required or forbidden by its code. Not an evidence: brain_evidence links knowledge.
CREATE TABLE brain_applications (
    application_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    event_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('observe', 'record', 'set_name')),
    phase TEXT CHECK (phase IS NULL OR phase IN ('before', 'menu', 'after', 'current')),
    sample_ordinal INTEGER CHECK (sample_ordinal IS NULL OR sample_ordinal >= 0),
    sample_observation_id INTEGER,
    sample_kind TEXT CHECK (sample_kind IS NULL OR sample_kind = 'capture'),
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    algorithm_version TEXT NOT NULL CHECK (length(algorithm_version) > 0),
    requested_at_ms INTEGER NOT NULL,
    effective_at_ms INTEGER NOT NULL,
    outcome TEXT NOT NULL
        CHECK (outcome IN ('observed', 'no_effect', 'no_anchor', 'recorded', 'named', 'not_named')),
    created_count INTEGER CHECK (created_count IS NULL OR created_count >= 0),
    updated_count INTEGER CHECK (updated_count IS NULL OR updated_count >= 0),
    skipped_ambiguous_count INTEGER CHECK (skipped_ambiguous_count IS NULL OR skipped_ambiguous_count >= 0),
    anchor_id TEXT,
    transition_id TEXT,
    evidence_count INTEGER CHECK (evidence_count IS NULL OR evidence_count >= 1),
    UNIQUE (app_id, application_id),
    CHECK (effective_at_ms >= requested_at_ms),
    CHECK ((operation = 'observe') = (phase IS NOT NULL)),
    CHECK ((phase IS NULL) = (sample_ordinal IS NULL)),
    CHECK ((phase IS NULL) = (sample_observation_id IS NULL)),
    CHECK ((phase IS NULL) = (sample_kind IS NULL)),
    CHECK ((operation = 'observe' AND outcome = 'observed')
        OR (operation = 'record' AND outcome IN ('no_effect', 'no_anchor', 'recorded'))
        OR (operation = 'set_name' AND outcome IN ('named', 'not_named'))),
    CHECK ((outcome = 'observed')
           = (created_count IS NOT NULL AND updated_count IS NOT NULL AND skipped_ambiguous_count IS NOT NULL)),
    CHECK (outcome = 'observed' OR (created_count IS NULL AND updated_count IS NULL AND skipped_ambiguous_count IS NULL)),
    CHECK ((outcome IN ('recorded', 'named')) = (anchor_id IS NOT NULL)),
    CHECK ((outcome = 'recorded') = (transition_id IS NOT NULL)),
    CHECK ((outcome = 'recorded') = (evidence_count IS NOT NULL)),
    FOREIGN KEY (app_id, event_id) REFERENCES memory_events(app_id, event_id),
    FOREIGN KEY (sample_observation_id, event_id, phase, sample_ordinal, sample_kind)
        REFERENCES memory_event_observations(observation_id, event_id, phase, sample_ordinal, observation_kind),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    FOREIGN KEY (app_id, transition_id) REFERENCES brain_transitions(app_id, transition_id)
) STRICT;

-- One evidence relation with six real FKs and exactly one target.
-- Links are not independent confirmations; never toward the app scope (trigger).
CREATE TABLE brain_evidence (
    evidence_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL,
    event_id TEXT NOT NULL,
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    assessed_by TEXT NOT NULL,
    assessment_version TEXT NOT NULL,
    assessed_at_ms INTEGER NOT NULL,
    scene_id TEXT,
    anchor_id TEXT,
    scene_element_id TEXT,
    group_id TEXT,
    menu_command_id TEXT,
    transition_id TEXT,
    CHECK ((scene_id IS NOT NULL) + (anchor_id IS NOT NULL) + (scene_element_id IS NOT NULL)
         + (group_id IS NOT NULL) + (menu_command_id IS NOT NULL) + (transition_id IS NOT NULL) = 1),
    FOREIGN KEY (app_id, event_id) REFERENCES memory_events(app_id, event_id),
    FOREIGN KEY (app_id, scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    FOREIGN KEY (app_id, scene_element_id) REFERENCES brain_scene_elements(app_id, scene_element_id),
    FOREIGN KEY (app_id, group_id) REFERENCES brain_groups(app_id, group_id),
    FOREIGN KEY (app_id, menu_command_id) REFERENCES brain_menu_commands(app_id, menu_command_id),
    FOREIGN KEY (app_id, transition_id) REFERENCES brain_transitions(app_id, transition_id)
) STRICT;

CREATE TABLE memory_task_occurrences (
    task_occurrence_id TEXT PRIMARY KEY,
    trace_id TEXT,
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER,
    status TEXT NOT NULL
        CHECK (status IN ('observed', 'in_progress', 'completed', 'failed', 'cancelled', 'interrupted', 'unknown')),
    CHECK (ended_at_ms IS NULL OR ended_at_ms >= started_at_ms)
) STRICT;

CREATE TABLE memory_task_events (
    task_occurrence_id TEXT NOT NULL REFERENCES memory_task_occurrences(task_occurrence_id),
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    role TEXT NOT NULL CHECK (role IN ('observation', 'action', 'verification', 'context')),
    PRIMARY KEY (task_occurrence_id, event_id, role),
    UNIQUE (task_occurrence_id, position)
) STRICT;

CREATE TABLE memory_task_labels (
    label_id TEXT PRIMARY KEY,
    task_occurrence_id TEXT NOT NULL REFERENCES memory_task_occurrences(task_occurrence_id),
    label TEXT NOT NULL,
    assigned_by TEXT NOT NULL,
    confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    status TEXT NOT NULL CHECK (status IN ('candidate', 'confirmed', 'rejected')),
    assigned_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_routes (
    route_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('draft', 'active', 'retired')),
    supersedes_route_id TEXT REFERENCES memory_routes(route_id),
    created_at_ms INTEGER NOT NULL,
    last_used_ms INTEGER,
    demoted_at_ms INTEGER,
    demotion_cause TEXT,
    CHECK (supersedes_route_id IS NULL OR supersedes_route_id <> route_id)
) STRICT;

CREATE TABLE memory_route_parameters (
    parameter_id TEXT PRIMARY KEY,
    route_id TEXT NOT NULL REFERENCES memory_routes(route_id),
    name TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('input', 'output', 'inout')),
    value_type TEXT NOT NULL CHECK (value_type IN ('text', 'integer', 'real', 'boolean')),
    is_required INTEGER NOT NULL CHECK (is_required IN (0, 1)),
    UNIQUE (route_id, name),
    UNIQUE (route_id, parameter_id),
    UNIQUE (route_id, parameter_id, value_type)
) STRICT;

-- Step = a verifiable result. A published Route has at least one step; the store checks that.
-- No recursive call between Routes, direct or indirect (trigger). A step is immutable in its app,
-- Route, kind and called Route: a change creates a new version of the Route.
CREATE TABLE memory_route_steps (
    step_id TEXT PRIMARY KEY,
    route_id TEXT NOT NULL REFERENCES memory_routes(route_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    step_kind TEXT NOT NULL CHECK (step_kind IN ('goal', 'route_call')),
    goal_text TEXT NOT NULL,
    app_id INTEGER REFERENCES brain_apps(app_id),
    called_route_id TEXT REFERENCES memory_routes(route_id),
    UNIQUE (route_id, position),
    UNIQUE (route_id, step_id),
    UNIQUE (app_id, step_id),
    UNIQUE (route_id, step_id, called_route_id),
    CHECK (called_route_id IS NULL OR called_route_id <> route_id),
    CHECK ((step_kind = 'goal' AND called_route_id IS NULL)
        OR (step_kind = 'route_call' AND called_route_id IS NOT NULL))
) STRICT;

-- app_id derived from the step (null-safe trigger).
CREATE TABLE memory_step_checks (
    check_id TEXT PRIMARY KEY,
    route_id TEXT NOT NULL,
    step_id TEXT NOT NULL,
    app_id INTEGER REFERENCES brain_apps(app_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    check_kind TEXT NOT NULL,
    expected_scene_id TEXT,
    expected_anchor_id TEXT,
    expected_state TEXT,
    expected_text TEXT,
    expected_integer INTEGER,
    expected_real REAL,
    expected_bool INTEGER CHECK (expected_bool IN (0, 1)),
    expected_parameter_id TEXT,
    comparison TEXT,
    UNIQUE (step_id, position),
    CHECK ((expected_state IS NOT NULL) + (expected_text IS NOT NULL) + (expected_integer IS NOT NULL)
         + (expected_real IS NOT NULL) + (expected_bool IS NOT NULL) + (expected_parameter_id IS NOT NULL) <= 1),
    CHECK ((expected_scene_id IS NULL AND expected_anchor_id IS NULL) OR app_id IS NOT NULL),
    FOREIGN KEY (route_id, step_id) REFERENCES memory_route_steps(route_id, step_id),
    FOREIGN KEY (app_id, step_id) REFERENCES memory_route_steps(app_id, step_id),
    FOREIGN KEY (app_id, expected_scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, expected_anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    FOREIGN KEY (route_id, expected_parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id)
) STRICT;

-- Reproducible definitions. A batch holds child operations within the same step.
-- app_id derived from the step (null-safe trigger); no parent/child cycle (trigger).
CREATE TABLE memory_step_operations (
    operation_id TEXT PRIMARY KEY,
    route_id TEXT NOT NULL,
    step_id TEXT NOT NULL,
    parent_operation_id TEXT,
    position INTEGER NOT NULL CHECK (position >= 0),
    tool_kind TEXT NOT NULL,
    contract_version INTEGER NOT NULL DEFAULT 1 CHECK (contract_version > 0),
    app_id INTEGER REFERENCES brain_apps(app_id),
    UNIQUE (route_id, operation_id),
    UNIQUE (step_id, operation_id),
    UNIQUE (app_id, operation_id),
    CHECK (parent_operation_id IS NULL OR parent_operation_id <> operation_id),
    FOREIGN KEY (route_id, step_id) REFERENCES memory_route_steps(route_id, step_id),
    FOREIGN KEY (app_id, step_id) REFERENCES memory_route_steps(app_id, step_id),
    FOREIGN KEY (step_id, parent_operation_id) REFERENCES memory_step_operations(step_id, operation_id)
) STRICT;

-- A typed argument belongs to a Route operation OR to an observed call OR (S2 3a) to a brain
-- application, exactly one of them.
-- app_id derived from the owner (null-safe trigger): omitting it is no way around the rule. A brain
-- application's arguments name its app and are checked against it by a composite key deferred to
-- the commit, since they are written before the application row that seals them; they are plain
-- values, never a parameter, an anchor or a menu reference.
-- Names, cardinality, defaults and tool-specific constraints are validated by the shared contract.
CREATE TABLE memory_operation_arguments (
    argument_id INTEGER PRIMARY KEY,
    operation_id TEXT REFERENCES memory_step_operations(operation_id),
    event_id TEXT REFERENCES memory_agent_actions(event_id),
    brain_application_id INTEGER,
    route_id TEXT,
    app_id INTEGER REFERENCES brain_apps(app_id),
    argument_name TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'integer', 'real', 'boolean', 'parameter', 'anchor', 'menu')),
    text_value TEXT,
    integer_value INTEGER,
    real_value REAL,
    boolean_value INTEGER CHECK (boolean_value IN (0, 1)),
    parameter_id TEXT,
    anchor_id TEXT,
    menu_command_id TEXT,
    CHECK ((operation_id IS NOT NULL) + (event_id IS NOT NULL) + (brain_application_id IS NOT NULL) = 1),
    CHECK ((operation_id IS NOT NULL AND route_id IS NOT NULL) OR
           (event_id IS NOT NULL AND route_id IS NULL AND parameter_id IS NULL) OR
           (brain_application_id IS NOT NULL AND route_id IS NULL AND parameter_id IS NULL AND app_id IS NOT NULL
            AND anchor_id IS NULL AND menu_command_id IS NULL)),
    CHECK (brain_application_id IS NULL OR value_kind IN ('text', 'integer', 'real', 'boolean')),
    CHECK ((anchor_id IS NULL AND menu_command_id IS NULL) OR app_id IS NOT NULL),
    CHECK ((text_value IS NOT NULL) + (integer_value IS NOT NULL) + (real_value IS NOT NULL)
         + (boolean_value IS NOT NULL) + (parameter_id IS NOT NULL) + (anchor_id IS NOT NULL)
         + (menu_command_id IS NOT NULL) = 1),
    CHECK ((value_kind = 'text' AND text_value IS NOT NULL)
        OR (value_kind = 'integer' AND integer_value IS NOT NULL)
        OR (value_kind = 'real' AND real_value IS NOT NULL)
        OR (value_kind = 'boolean' AND boolean_value IS NOT NULL)
        OR (value_kind = 'parameter' AND parameter_id IS NOT NULL)
        OR (value_kind = 'anchor' AND anchor_id IS NOT NULL)
        OR (value_kind = 'menu' AND menu_command_id IS NOT NULL)),
    FOREIGN KEY (route_id, operation_id) REFERENCES memory_step_operations(route_id, operation_id),
    FOREIGN KEY (route_id, parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id),
    FOREIGN KEY (app_id, operation_id) REFERENCES memory_step_operations(app_id, operation_id),
    FOREIGN KEY (app_id, event_id) REFERENCES memory_agent_actions(app_id, event_id),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    FOREIGN KEY (app_id, menu_command_id) REFERENCES brain_menu_commands(app_id, menu_command_id),
    FOREIGN KEY (app_id, brain_application_id) REFERENCES brain_applications(app_id, application_id)
        DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE TABLE memory_route_call_bindings (
    step_id TEXT NOT NULL,
    route_id TEXT NOT NULL,
    called_route_id TEXT NOT NULL,
    called_parameter_id TEXT NOT NULL REFERENCES memory_route_parameters(parameter_id),
    source_parameter_id TEXT REFERENCES memory_route_parameters(parameter_id),
    literal_text TEXT,
    literal_integer INTEGER,
    literal_real REAL,
    literal_bool INTEGER CHECK (literal_bool IN (0, 1)),
    PRIMARY KEY (step_id, called_parameter_id),
    CHECK ((source_parameter_id IS NOT NULL) + (literal_text IS NOT NULL)
         + (literal_integer IS NOT NULL) + (literal_real IS NOT NULL)
         + (literal_bool IS NOT NULL) = 1),
    FOREIGN KEY (route_id, step_id, called_route_id) REFERENCES memory_route_steps(route_id, step_id, called_route_id),
    FOREIGN KEY (called_route_id, called_parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id),
    FOREIGN KEY (route_id, source_parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id)
) STRICT;

-- An occurrence observed even without a known definition. Assigning task/step certifies no success.
CREATE TABLE memory_step_occurrences (
    step_occurrence_id TEXT PRIMARY KEY,
    task_occurrence_id TEXT REFERENCES memory_task_occurrences(task_occurrence_id),
    step_id TEXT REFERENCES memory_route_steps(step_id),
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER,
    status TEXT NOT NULL
        CHECK (status IN ('observed', 'in_progress', 'completed', 'failed', 'cancelled', 'interrupted', 'unknown')),
    assigned_by TEXT,
    UNIQUE (step_occurrence_id, step_id),
    CHECK (ended_at_ms IS NULL OR ended_at_ms >= started_at_ms)
) STRICT;

-- Membership of events in a step. The 'verification' role is not a second attribution: it must
-- point at the same occurrence as memory_verifications.step_occurrence_id (trigger).
CREATE TABLE memory_step_events (
    step_occurrence_id TEXT NOT NULL REFERENCES memory_step_occurrences(step_occurrence_id),
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    attempt_number INTEGER,
    role TEXT NOT NULL CHECK (role IN ('observation', 'action', 'verification', 'context')),
    PRIMARY KEY (step_occurrence_id, event_id, role),
    UNIQUE (step_occurrence_id, position)
) STRICT;

CREATE TABLE memory_route_evidence (
    route_id TEXT NOT NULL REFERENCES memory_routes(route_id),
    task_occurrence_id TEXT NOT NULL REFERENCES memory_task_occurrences(task_occurrence_id),
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    assessed_by TEXT NOT NULL,
    assessed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (route_id, task_occurrence_id, relation)
) STRICT;

CREATE TABLE memory_step_evidence (
    step_id TEXT NOT NULL REFERENCES memory_route_steps(step_id),
    step_occurrence_id TEXT NOT NULL,
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    assessed_by TEXT NOT NULL,
    assessed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (step_id, step_occurrence_id, relation),
    FOREIGN KEY (step_occurrence_id, step_id)
        REFERENCES memory_step_occurrences(step_occurrence_id, step_id)
) STRICT;

CREATE TABLE memory_experiences (
    experience_id TEXT PRIMARY KEY,
    phrase TEXT NOT NULL,
    route_id TEXT NOT NULL REFERENCES memory_routes(route_id),
    step_id TEXT,
    created_at_ms INTEGER NOT NULL,
    UNIQUE (route_id, experience_id),
    FOREIGN KEY (route_id, step_id) REFERENCES memory_route_steps(route_id, step_id)
) STRICT;

-- A memory says where its parameters come from; it never reuses ephemeral UI references.
CREATE TABLE memory_experience_bindings (
    experience_id TEXT NOT NULL,
    route_id TEXT NOT NULL,
    parameter_id TEXT NOT NULL,
    value_type TEXT NOT NULL CHECK (value_type IN ('text', 'integer', 'real', 'boolean')),
    binding_kind TEXT NOT NULL CHECK (binding_kind IN ('literal', 'request_slot', 'context_slot')),
    binding_contract_version INTEGER NOT NULL DEFAULT 1 CHECK (binding_contract_version > 0),
    slot_name TEXT,
    literal_text TEXT,
    literal_integer INTEGER,
    literal_real REAL,
    literal_boolean INTEGER CHECK (literal_boolean IN (0, 1)),
    PRIMARY KEY (experience_id, parameter_id),
    FOREIGN KEY (route_id, experience_id) REFERENCES memory_experiences(route_id, experience_id),
    FOREIGN KEY (route_id, parameter_id, value_type)
        REFERENCES memory_route_parameters(route_id, parameter_id, value_type),
    CHECK (
        (binding_kind = 'literal' AND slot_name IS NULL
         AND ((literal_text IS NOT NULL) + (literal_integer IS NOT NULL)
            + (literal_real IS NOT NULL) + (literal_boolean IS NOT NULL) = 1)
         AND ((value_type = 'text' AND literal_text IS NOT NULL)
           OR (value_type = 'integer' AND literal_integer IS NOT NULL)
           OR (value_type = 'real' AND literal_real IS NOT NULL)
           OR (value_type = 'boolean' AND literal_boolean IS NOT NULL)))
        OR
        (binding_kind IN ('request_slot', 'context_slot')
         AND slot_name IS NOT NULL AND length(trim(slot_name)) > 0
         AND literal_text IS NULL AND literal_integer IS NULL
         AND literal_real IS NULL AND literal_boolean IS NULL)
    )
) STRICT;

CREATE TABLE memory_experience_uses (
    experience_id TEXT NOT NULL REFERENCES memory_experiences(experience_id),
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    verdict TEXT NOT NULL CHECK (verdict IN ('passed', 'failed', 'unknown')),
    PRIMARY KEY (experience_id, event_id)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------------------------

-- Operational reads: retired knowledge stays available to diagnostics.
CREATE INDEX brain_anchors_active_by_kind ON brain_anchors(app_id, kind) WHERE retired_at_ms IS NULL;
CREATE INDEX brain_groups_active_by_app ON brain_groups(app_id) WHERE retired_at_ms IS NULL;
CREATE INDEX brain_transitions_active_by_anchor ON brain_transitions(app_id, anchor_id, trigger_kind) WHERE retired_at_ms IS NULL;

-- One scope row per app.
CREATE UNIQUE INDEX brain_scenes_one_app_scope ON brain_scenes(app_id) WHERE scene_kind = 'app';

CREATE UNIQUE INDEX brain_evidence_scene_id ON brain_evidence(scene_id, event_id, relation) WHERE scene_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_anchor_id ON brain_evidence(anchor_id, event_id, relation) WHERE anchor_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_scene_element_id ON brain_evidence(scene_element_id, event_id, relation) WHERE scene_element_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_group_id ON brain_evidence(group_id, event_id, relation) WHERE group_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_menu_command_id ON brain_evidence(menu_command_id, event_id, relation) WHERE menu_command_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_transition_id ON brain_evidence(transition_id, event_id, relation) WHERE transition_id IS NOT NULL;

-- One sample (capture row) per event, phase and ordinal; one confirmed match per sample.
CREATE UNIQUE INDEX memory_observation_captures ON memory_event_observations(event_id, phase, sample_ordinal) WHERE observation_kind = 'capture';
CREATE UNIQUE INDEX memory_event_scenes_confirmed ON memory_event_scenes(event_id, phase, sample_ordinal) WHERE match_status = 'confirmed';
CREATE UNIQUE INDEX memory_operations_roots ON memory_step_operations(step_id, position) WHERE parent_operation_id IS NULL;
CREATE UNIQUE INDEX memory_operations_children ON memory_step_operations(parent_operation_id, position) WHERE parent_operation_id IS NOT NULL;
CREATE UNIQUE INDEX memory_arguments_definition ON memory_operation_arguments(operation_id, argument_name, position) WHERE operation_id IS NOT NULL;
CREATE UNIQUE INDEX memory_arguments_event ON memory_operation_arguments(event_id, argument_name, position) WHERE event_id IS NOT NULL;
-- S2 3a: one argument per name and position of an application; one application per key, with no
-- NULL column in either key (an observation's phase and ordinal are required by its CHECK).
CREATE UNIQUE INDEX memory_arguments_brain_application ON memory_operation_arguments(brain_application_id, argument_name, position) WHERE brain_application_id IS NOT NULL;
CREATE UNIQUE INDEX brain_applications_observation_key ON brain_applications(event_id, phase, sample_ordinal) WHERE operation = 'observe';
CREATE UNIQUE INDEX brain_applications_call_key ON brain_applications(event_id, operation) WHERE operation <> 'observe';
CREATE INDEX brain_applications_by_app_clock ON brain_applications(app_id, effective_at_ms);
CREATE INDEX memory_events_by_context_time ON memory_events(context_id, occurred_at_ms);
CREATE INDEX memory_events_by_trace ON memory_events(trace_id, local_order);
CREATE INDEX memory_events_by_source_order ON memory_events(source, source_stream_id, local_order);
CREATE INDEX memory_task_labels_by_occurrence ON memory_task_labels(task_occurrence_id, status);
CREATE INDEX memory_step_occurrences_by_task ON memory_step_occurrences(task_occurrence_id, started_at_ms);
CREATE INDEX brain_transitions_by_source ON brain_transitions(app_id, from_scene_id, trigger_kind);
CREATE INDEX brain_transitions_by_destination ON brain_transitions(app_id, to_scene_id);
CREATE INDEX brain_menu_by_path_hint ON brain_menu_commands(app_id, path_key);
CREATE INDEX brain_evidence_by_event ON brain_evidence(event_id);
CREATE INDEX memory_task_events_by_event ON memory_task_events(event_id);
CREATE INDEX memory_step_events_by_event ON memory_step_events(event_id);

-- ---------------------------------------------------------------------------------------------
-- Triggers A: the app scope is a scope, not a surface. IS / IS NOT semantics: null-safe.
-- Every rule below covers INSERT and the UPDATE that could move a row onto the scope.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER brain_scenes_kind_immutable BEFORE UPDATE OF scene_kind ON brain_scenes
BEGIN
    SELECT RAISE(ABORT, 'brain_scenes.scene_kind is immutable');
END;

CREATE TRIGGER brain_scene_elements_not_app_scope_insert BEFORE INSERT ON brain_scene_elements
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no structural elements')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_scene_elements_not_app_scope_update BEFORE UPDATE OF scene_id ON brain_scene_elements
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no structural elements')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_scene_roles_not_app_scope_insert BEFORE INSERT ON brain_scene_roles
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no roles')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

-- S1: v5 covered the INSERT only; an UPDATE of scene_id could move a role onto the scope.
CREATE TRIGGER brain_scene_roles_not_app_scope_update BEFORE UPDATE OF scene_id ON brain_scene_roles
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no roles')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_scene_labels_not_app_scope_insert BEFORE INSERT ON brain_scene_labels
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no labels')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

-- S1: same symmetry for labels.
CREATE TRIGGER brain_scene_labels_not_app_scope_update BEFORE UPDATE OF scene_id ON brain_scene_labels
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no labels')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER memory_event_scenes_not_app_scope_insert BEFORE INSERT ON memory_event_scenes
BEGIN
    SELECT RAISE(ABORT, 'an observation is never associated with the app scope')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER memory_event_scenes_not_app_scope_update BEFORE UPDATE OF scene_id ON memory_event_scenes
BEGIN
    SELECT RAISE(ABORT, 'an observation is never associated with the app scope')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_evidence_not_app_scope_insert BEFORE INSERT ON brain_evidence
BEGIN
    SELECT RAISE(ABORT, 'evidence never targets the app scope itself')
    WHERE NEW.scene_id IS NOT NULL
      AND (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_evidence_not_app_scope_update BEFORE UPDATE OF scene_id ON brain_evidence
BEGIN
    SELECT RAISE(ABORT, 'evidence never targets the app scope itself')
    WHERE NEW.scene_id IS NOT NULL
      AND (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_transitions_to_not_app_scope_insert BEFORE INSERT ON brain_transitions
BEGIN
    SELECT RAISE(ABORT, 'an unknown destination stays NULL; the app scope is never a destination')
    WHERE NEW.to_scene_id IS NOT NULL
      AND (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.to_scene_id) = 'app';
END;

CREATE TRIGGER brain_transitions_to_not_app_scope_update BEFORE UPDATE OF to_scene_id ON brain_transitions
BEGIN
    SELECT RAISE(ABORT, 'an unknown destination stays NULL; the app scope is never a destination')
    WHERE NEW.to_scene_id IS NOT NULL
      AND (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.to_scene_id) = 'app';
END;

-- ---------------------------------------------------------------------------------------------
-- Triggers C: app_id derived from the parent, immutable identity, verification/membership,
-- correlations, cycles. An unknown context (NULL) is never rewritten as if it had been known.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_events_identity_immutable BEFORE UPDATE OF
    event_id, source, source_stream_id, source_key, trace_id, session_id, parent_event_id,
    parent_position, event_kind, app_id, context_id, occurred_at_ms, monotonic_ns, origin_event_id
ON memory_events
BEGIN
    SELECT RAISE(ABORT, 'memory_events identity and context are immutable; only capture_status may change');
END;

CREATE TRIGGER memory_agent_actions_app_from_event_insert BEFORE INSERT ON memory_agent_actions
BEGIN
    SELECT RAISE(ABORT, 'memory_agent_actions.app_id must equal its event''s app_id (both may be NULL)')
    WHERE (SELECT app_id FROM memory_events WHERE event_id = NEW.event_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_agent_actions_identity_immutable BEFORE UPDATE OF
    event_id, event_kind, app_id, tool_kind, contract_version
ON memory_agent_actions
BEGIN
    SELECT RAISE(ABORT, 'memory_agent_actions identity is immutable; execution fields have dedicated updates');
END;

-- S3-d correction: the shape guards of a call's effect labels and structured results. Each row
-- belongs to a completed call of the tool that produces it; a label belongs to a list effect.
CREATE TRIGGER memory_agent_action_effect_labels_insert_guard BEFORE INSERT ON memory_agent_action_effect_labels
BEGIN
    SELECT RAISE(ABORT, 'an effect label belongs to a completed call whose effect is a list')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_actions a WHERE a.event_id = NEW.event_id AND a.execution_status = 'completed'
            AND a.observed_effect_kind IN ('menuOpened', 'elementsAppeared', 'elementsDisappeared'));
END;

CREATE TRIGGER memory_agent_action_status_insert_guard BEFORE INSERT ON memory_agent_action_status
BEGIN
    SELECT RAISE(ABORT, 'a status result belongs to a completed status call')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_actions a WHERE a.event_id = NEW.event_id AND a.execution_status = 'completed'
            AND a.tool_kind = 'status' AND a.result_kind = 'status');
END;

CREATE TRIGGER memory_agent_action_listings_insert_guard BEFORE INSERT ON memory_agent_action_listings
BEGIN
    SELECT RAISE(ABORT, 'a listing result belongs to a completed windows or apps call of its kind')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_actions a WHERE a.event_id = NEW.event_id AND a.execution_status = 'completed'
            AND a.tool_kind = NEW.listing_kind AND a.result_kind = 'listing');
END;

CREATE TRIGGER memory_agent_action_applications_insert_guard BEFORE INSERT ON memory_agent_action_applications
BEGIN
    SELECT RAISE(ABORT, 'a windows row carries a pid and no apps field; an apps row carries is_running and no pid')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_action_listings l WHERE l.event_id = NEW.event_id
            AND ((l.listing_kind = 'windows' AND NEW.pid IS NOT NULL AND NEW.is_running IS NULL
                  AND NEW.app_version IS NULL AND NEW.location IS NULL)
              OR (l.listing_kind = 'apps' AND NEW.pid IS NULL AND NEW.is_running IS NOT NULL)));
END;

CREATE TRIGGER memory_agent_action_windows_insert_guard BEFORE INSERT ON memory_agent_action_windows
BEGIN
    SELECT RAISE(ABORT, 'a listed window belongs to a windows listing')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_action_listings l WHERE l.event_id = NEW.event_id AND l.listing_kind = 'windows');
END;

CREATE TRIGGER memory_agent_action_observations_insert_guard BEFORE INSERT ON memory_agent_action_observations
BEGIN
    SELECT RAISE(ABORT, 'an observation result belongs to a completed open_session or observe call')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_actions a WHERE a.event_id = NEW.event_id AND a.execution_status = 'completed'
            AND a.tool_kind IN ('open_session', 'observe') AND a.result_kind = 'observation');
END;

CREATE TRIGGER memory_route_steps_identity_immutable BEFORE UPDATE OF
    step_id, route_id, step_kind, app_id, called_route_id
ON memory_route_steps
BEGIN
    SELECT RAISE(ABORT, 'a step''s Route, kind, app and callee are immutable; publish a new Route version');
END;

CREATE TRIGGER memory_step_operations_app_from_step_insert BEFORE INSERT ON memory_step_operations
BEGIN
    SELECT RAISE(ABORT, 'memory_step_operations.app_id must equal its step''s app_id (both may be NULL)')
    WHERE (SELECT app_id FROM memory_route_steps WHERE step_id = NEW.step_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_step_operations_app_from_step_update BEFORE UPDATE OF app_id, step_id ON memory_step_operations
BEGIN
    SELECT RAISE(ABORT, 'memory_step_operations.app_id must equal its step''s app_id (both may be NULL)')
    WHERE (SELECT app_id FROM memory_route_steps WHERE step_id = NEW.step_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_step_checks_app_from_step_insert BEFORE INSERT ON memory_step_checks
BEGIN
    SELECT RAISE(ABORT, 'memory_step_checks.app_id must equal its step''s app_id (both may be NULL)')
    WHERE (SELECT app_id FROM memory_route_steps WHERE step_id = NEW.step_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_step_checks_app_from_step_update BEFORE UPDATE OF app_id, step_id ON memory_step_checks
BEGIN
    SELECT RAISE(ABORT, 'memory_step_checks.app_id must equal its step''s app_id (both may be NULL)')
    WHERE (SELECT app_id FROM memory_route_steps WHERE step_id = NEW.step_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_operation_arguments_app_from_owner_insert BEFORE INSERT ON memory_operation_arguments
BEGIN
    SELECT RAISE(ABORT, 'an argument''s app_id must equal its operation''s app_id (both may be NULL)')
    WHERE NEW.operation_id IS NOT NULL
      AND (SELECT app_id FROM memory_step_operations WHERE operation_id = NEW.operation_id) IS NOT NEW.app_id;
    SELECT RAISE(ABORT, 'an argument''s app_id must equal its action''s app_id (both may be NULL)')
    WHERE NEW.event_id IS NOT NULL
      AND (SELECT app_id FROM memory_agent_actions WHERE event_id = NEW.event_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_operation_arguments_app_from_owner_update BEFORE UPDATE OF
    app_id, operation_id, event_id
ON memory_operation_arguments
BEGIN
    SELECT RAISE(ABORT, 'an argument''s app_id must equal its operation''s app_id (both may be NULL)')
    WHERE NEW.operation_id IS NOT NULL
      AND (SELECT app_id FROM memory_step_operations WHERE operation_id = NEW.operation_id) IS NOT NEW.app_id;
    SELECT RAISE(ABORT, 'an argument''s app_id must equal its action''s app_id (both may be NULL)')
    WHERE NEW.event_id IS NOT NULL
      AND (SELECT app_id FROM memory_agent_actions WHERE event_id = NEW.event_id) IS NOT NEW.app_id;
END;

-- memory_verifications.step_occurrence_id is the one authoritative attribution. A membership with
-- the 'verification' role must point at the same occurrence, in either write order.
CREATE TRIGGER memory_step_events_verification_role_insert BEFORE INSERT ON memory_step_events
BEGIN
    SELECT RAISE(ABORT, 'a verification membership must name a verification event attributed to the same step occurrence')
    WHERE NEW.role = 'verification'
      AND (SELECT step_occurrence_id FROM memory_verifications WHERE event_id = NEW.event_id) IS NOT NEW.step_occurrence_id;
END;

CREATE TRIGGER memory_step_events_verification_role_update BEFORE UPDATE OF
    role, event_id, step_occurrence_id
ON memory_step_events
BEGIN
    SELECT RAISE(ABORT, 'a verification membership must name a verification event attributed to the same step occurrence')
    WHERE NEW.role = 'verification'
      AND (SELECT step_occurrence_id FROM memory_verifications WHERE event_id = NEW.event_id) IS NOT NEW.step_occurrence_id;
END;

CREATE TRIGGER memory_verifications_matches_membership_insert BEFORE INSERT ON memory_verifications
BEGIN
    SELECT RAISE(ABORT, 'a verification cannot be attributed to a step occurrence other than its membership''s')
    WHERE EXISTS (SELECT 1 FROM memory_step_events
                  WHERE event_id = NEW.event_id AND role = 'verification'
                    AND step_occurrence_id IS NOT NEW.step_occurrence_id);
END;

CREATE TRIGGER memory_verifications_matches_membership_update BEFORE UPDATE OF step_occurrence_id ON memory_verifications
BEGIN
    SELECT RAISE(ABORT, 'a verification cannot be attributed to a step occurrence other than its membership''s')
    WHERE EXISTS (SELECT 1 FROM memory_step_events
                  WHERE event_id = NEW.event_id AND role = 'verification'
                    AND step_occurrence_id IS NOT NEW.step_occurrence_id);
END;

CREATE TRIGGER memory_action_correlations_roles_insert BEFORE INSERT ON memory_action_correlations
BEGIN
    SELECT RAISE(ABORT, 'watcher_event_id must be a watcher input event')
    WHERE NOT EXISTS (SELECT 1 FROM memory_events
                      WHERE event_id = NEW.watcher_event_id AND source = 'watcher' AND event_kind = 'input');
    SELECT RAISE(ABORT, 'agent_event_id must be an app or cli action event')
    WHERE NOT EXISTS (SELECT 1 FROM memory_events
                      WHERE event_id = NEW.agent_event_id AND source IN ('app', 'cli') AND event_kind = 'action');
END;

CREATE TRIGGER memory_action_correlations_roles_update BEFORE UPDATE OF
    watcher_event_id, agent_event_id
ON memory_action_correlations
BEGIN
    SELECT RAISE(ABORT, 'watcher_event_id must be a watcher input event')
    WHERE NOT EXISTS (SELECT 1 FROM memory_events
                      WHERE event_id = NEW.watcher_event_id AND source = 'watcher' AND event_kind = 'input');
    SELECT RAISE(ABORT, 'agent_event_id must be an app or cli action event')
    WHERE NOT EXISTS (SELECT 1 FROM memory_events
                      WHERE event_id = NEW.agent_event_id AND source IN ('app', 'cli') AND event_kind = 'action');
END;

-- No recursive call between Routes: A -> B -> A is refused at the insert of the step that closes the cycle.
CREATE TRIGGER memory_route_steps_no_recursive_calls BEFORE INSERT ON memory_route_steps
WHEN NEW.called_route_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a Route may not call itself, directly or through other Routes')
    WHERE NEW.route_id IN (
        WITH RECURSIVE reach(route_id) AS (
            SELECT NEW.called_route_id
            UNION
            SELECT s.called_route_id FROM memory_route_steps s JOIN reach ON s.route_id = reach.route_id
            WHERE s.called_route_id IS NOT NULL
        )
        SELECT route_id FROM reach
    );
END;

-- No parent/child cycle between operations (possible only through an UPDATE of the parent).
CREATE TRIGGER memory_step_operations_no_parent_cycle BEFORE UPDATE OF parent_operation_id ON memory_step_operations
WHEN NEW.parent_operation_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an operation cannot be its own ancestor')
    WHERE NEW.operation_id IN (
        WITH RECURSIVE up(operation_id) AS (
            SELECT NEW.parent_operation_id
            UNION
            SELECT o.parent_operation_id FROM memory_step_operations o JOIN up ON o.operation_id = up.operation_id
            WHERE o.parent_operation_id IS NOT NULL
        )
        SELECT operation_id FROM up
    );
END;

-- ---------------------------------------------------------------------------------------------
-- Triggers D: samples. An association needs its own sample; confirmation only when complete.
-- A referenced sample keeps its identity and cannot be removed; a confirmed one keeps its
-- complete status as well.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_event_scenes_require_capture_insert BEFORE INSERT ON memory_event_scenes
BEGIN
    SELECT RAISE(ABORT, 'a scene association needs its capture sample (event, phase, ordinal)')
    WHERE NOT EXISTS (SELECT 1 FROM memory_event_observations
                      WHERE event_id = NEW.event_id AND phase = NEW.phase
                        AND sample_ordinal = NEW.sample_ordinal AND observation_kind = 'capture');
    SELECT RAISE(ABORT, 'only a complete capture can confirm a scene')
    WHERE NEW.match_status = 'confirmed'
      AND (SELECT status FROM memory_event_observations
           WHERE event_id = NEW.event_id AND phase = NEW.phase
             AND sample_ordinal = NEW.sample_ordinal AND observation_kind = 'capture') <> 'complete';
END;

CREATE TRIGGER memory_event_scenes_require_capture_update BEFORE UPDATE OF
    match_status, event_id, phase, sample_ordinal
ON memory_event_scenes
BEGIN
    SELECT RAISE(ABORT, 'a scene association needs its capture sample (event, phase, ordinal)')
    WHERE NOT EXISTS (SELECT 1 FROM memory_event_observations
                      WHERE event_id = NEW.event_id AND phase = NEW.phase
                        AND sample_ordinal = NEW.sample_ordinal AND observation_kind = 'capture');
    SELECT RAISE(ABORT, 'only a complete capture can confirm a scene')
    WHERE NEW.match_status = 'confirmed'
      AND (SELECT status FROM memory_event_observations
           WHERE event_id = NEW.event_id AND phase = NEW.phase
             AND sample_ordinal = NEW.sample_ordinal AND observation_kind = 'capture') <> 'complete';
END;

-- S1: a capture row that any scene association references keeps the identity the association
-- names (event, phase, ordinal) and stays a capture. v5 guarded phase and ordinal for confirmed
-- samples only; event_id could still move, leaving the association without its sample.
CREATE TRIGGER memory_event_observations_capture_identity_guard BEFORE UPDATE OF
    event_id, observation_kind, phase, sample_ordinal
ON memory_event_observations
WHEN OLD.observation_kind = 'capture'
BEGIN
    SELECT RAISE(ABORT, 'a referenced sample keeps its identity (event, phase, ordinal, capture)')
    WHERE EXISTS (SELECT 1 FROM memory_event_scenes
                  WHERE event_id = OLD.event_id AND phase = OLD.phase
                    AND sample_ordinal = OLD.sample_ordinal)
      AND (NEW.event_id <> OLD.event_id OR NEW.observation_kind <> 'capture'
           OR NEW.phase <> OLD.phase OR NEW.sample_ordinal <> OLD.sample_ordinal);
END;

-- A capture row does not lose its complete status after a scene was confirmed on it. An
-- unconfirmed sample may still be corrected.
CREATE TRIGGER memory_event_observations_capture_status_guard BEFORE UPDATE OF status
ON memory_event_observations
WHEN OLD.observation_kind = 'capture'
BEGIN
    SELECT RAISE(ABORT, 'a confirmed sample keeps its complete status')
    WHERE NEW.status <> 'complete'
      AND EXISTS (SELECT 1 FROM memory_event_scenes
                  WHERE event_id = OLD.event_id AND phase = OLD.phase
                    AND sample_ordinal = OLD.sample_ordinal AND match_status = 'confirmed');
END;

-- S1: a capture row that any scene association references cannot be deleted; v5 let the
-- association survive without its sample. This is a refusal, not a cleanup: nothing is deleted
-- on the store's own initiative.
CREATE TRIGGER memory_event_observations_capture_delete_guard BEFORE DELETE ON memory_event_observations
WHEN OLD.observation_kind = 'capture'
BEGIN
    SELECT RAISE(ABORT, 'a referenced sample cannot be deleted')
    WHERE EXISTS (SELECT 1 FROM memory_event_scenes
                  WHERE event_id = OLD.event_id AND phase = OLD.phase
                    AND sample_ordinal = OLD.sample_ordinal);
END;

-- ---------------------------------------------------------------------------------------------
-- Triggers E (S2 3a): a brain application is sealed by its own row and kept as written.
-- ---------------------------------------------------------------------------------------------

-- The row is the seal: it needs the arguments written before it, a record or a naming names an
-- action event, and a recorded transition is the recorded anchor's.
CREATE TRIGGER brain_applications_insert_guard BEFORE INSERT ON brain_applications
BEGIN
    SELECT RAISE(ABORT, 'a brain application is written after its arguments, which it seals')
    WHERE NOT EXISTS (SELECT 1 FROM memory_operation_arguments WHERE brain_application_id = NEW.application_id);
    SELECT RAISE(ABORT, 'a record or a naming is applied for an action event')
    WHERE NEW.operation IN ('record', 'set_name')
      AND (SELECT event_kind FROM memory_events WHERE event_id = NEW.event_id) IS NOT 'action';
    SELECT RAISE(ABORT, 'a recorded transition belongs to the recorded anchor')
    WHERE NEW.transition_id IS NOT NULL
      AND (SELECT anchor_id FROM brain_transitions WHERE transition_id = NEW.transition_id) IS NOT NEW.anchor_id;
END;

CREATE TRIGGER brain_applications_immutable BEFORE UPDATE ON brain_applications
BEGIN
    SELECT RAISE(ABORT, 'a concluded brain application is immutable');
END;

CREATE TRIGGER brain_applications_kept BEFORE DELETE ON brain_applications
BEGIN
    SELECT RAISE(ABORT, 'a concluded brain application is kept: it is what makes a retry a retry');
END;

CREATE TRIGGER memory_operation_arguments_application_sealed BEFORE INSERT ON memory_operation_arguments
WHEN NEW.brain_application_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a concluded brain application''s input is sealed')
    WHERE EXISTS (SELECT 1 FROM brain_applications WHERE application_id = NEW.brain_application_id);
END;

CREATE TRIGGER memory_operation_arguments_application_immutable BEFORE UPDATE ON memory_operation_arguments
WHEN OLD.brain_application_id IS NOT NULL OR NEW.brain_application_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a brain application''s input is immutable');
END;

CREATE TRIGGER memory_operation_arguments_application_kept BEFORE DELETE ON memory_operation_arguments
WHEN OLD.brain_application_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a brain application''s input is kept with it');
END;
