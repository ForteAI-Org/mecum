-- Mecum Brain and living memory: schema 2, the additions to schema 1 (G76, plan D1).
-- Schema 2 is the schema 1 resource, unchanged, followed by this text. A new archive runs both in its
-- bootstrap transaction; an archive at the exact shape of schema 1 runs this one in the transaction
-- that migrates it, after a verified copy. Both end at the same shape, which the store compares at
-- every open. Nothing here alters a table of schema 1: each new fact has a table of its own, and no
-- column of schema 1 is reused with another meaning. The calls, samples, verifications and episodes
-- of schema 1 keep their tables; these tables say what schema 1 could not:
--   - the task an agent communicates, its revisions, attempts (the episodes of memory_task_occurrences),
--     checkpoints, outputs, and the revision each call began under;
--   - what a call really did beside what it asked, and the typed verification of each call, with its
--     condition, method version, limits, target and samples (its verdict row is memory_verifications);
--   - the values withheld from the record and why;
--   - the archives the memory was unified from, and the source of every fact it took from them.
-- Same conventions as schema 1: STRICT tables, no JSON column, no PRAGMA/BEGIN/COMMIT of its own.

-- The schema versions the archive went through: the bootstrap of a new archive (from 0), or a
-- migration with the name of the verified copy taken before it.
CREATE TABLE memory_schema_migrations (
    to_version INTEGER PRIMARY KEY CHECK (to_version > 1),
    from_version INTEGER NOT NULL CHECK (from_version >= 0 AND from_version < to_version),
    migrated_at_ms INTEGER NOT NULL,
    copy_name TEXT,
    CHECK ((from_version = 0) = (copy_name IS NULL))
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Tasks (TaskContext, contract 1). A task belongs to the producer that opened it. Its status is the
-- agent's declaration, moving from open to one closed status once.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_tasks (
    task_id TEXT PRIMARY KEY CHECK (length(task_id) > 0),
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL CHECK (length(source_stream_id) > 0),
    trace_id TEXT,
    opened_at_ms INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('open', 'completed', 'failed', 'abandoned')),
    closed_at_ms INTEGER,
    current_revision INTEGER NOT NULL CHECK (current_revision >= 1),
    CHECK ((status = 'open') = (closed_at_ms IS NULL)),
    CHECK (closed_at_ms IS NULL OR closed_at_ms >= opened_at_ms)
) STRICT;

-- A revision states the whole task as resolved then; a correction is a new revision, never an edit.
CREATE TABLE memory_task_revisions (
    task_id TEXT NOT NULL REFERENCES memory_tasks(task_id),
    revision INTEGER NOT NULL CHECK (revision >= 1),
    recorded_at_ms INTEGER NOT NULL,
    change_kind TEXT NOT NULL CHECK (change_kind IN ('opened', 'revised')),
    reason TEXT,
    goal TEXT NOT NULL CHECK (length(goal) > 0),
    requested_result TEXT,
    PRIMARY KEY (task_id, revision),
    CHECK ((revision = 1) = (change_kind = 'opened'))
) STRICT;

CREATE TABLE memory_task_constraints (
    task_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    constraint_text TEXT NOT NULL CHECK (length(constraint_text) > 0),
    PRIMARY KEY (task_id, revision, position),
    FOREIGN KEY (task_id, revision) REFERENCES memory_task_revisions(task_id, revision)
) STRICT;

-- The messages a revision came from, as the frontend names them: never their text.
CREATE TABLE memory_task_message_refs (
    task_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    message_ref TEXT NOT NULL CHECK (length(message_ref) > 0),
    PRIMARY KEY (task_id, revision, position),
    UNIQUE (task_id, revision, message_ref),
    FOREIGN KEY (task_id, revision) REFERENCES memory_task_revisions(task_id, revision)
) STRICT;

-- An attempt is an episode of memory_task_occurrences: its status and end live there. A resumption
-- is a new attempt that names the one it resumes.
CREATE TABLE memory_task_attempts (
    task_occurrence_id TEXT PRIMARY KEY REFERENCES memory_task_occurrences(task_occurrence_id),
    task_id TEXT NOT NULL REFERENCES memory_tasks(task_id),
    ordinal INTEGER NOT NULL CHECK (ordinal >= 1),
    resumes_task_occurrence_id TEXT REFERENCES memory_task_attempts(task_occurrence_id),
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL CHECK (length(source_stream_id) > 0),
    opened_at_ms INTEGER NOT NULL,
    opened_at_revision INTEGER NOT NULL,
    UNIQUE (task_id, ordinal),
    UNIQUE (task_occurrence_id, task_id),
    CHECK ((ordinal = 1) = (resumes_task_occurrence_id IS NULL)),
    CHECK (resumes_task_occurrence_id IS NULL OR resumes_task_occurrence_id <> task_occurrence_id),
    FOREIGN KEY (task_id, opened_at_revision) REFERENCES memory_task_revisions(task_id, revision)
) STRICT;

-- What the agent declares along an attempt, and its end. At most one end per attempt.
CREATE TABLE memory_task_checkpoints (
    task_occurrence_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    checkpoint_kind TEXT NOT NULL CHECK (checkpoint_kind IN ('checkpoint', 'end')),
    task_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    recorded_at_ms INTEGER NOT NULL,
    declared_status TEXT CHECK (declared_status IS NULL OR declared_status IN ('completed', 'failed', 'abandoned')),
    note TEXT,
    PRIMARY KEY (task_occurrence_id, sequence),
    CHECK ((checkpoint_kind = 'end') = (declared_status IS NOT NULL)),
    FOREIGN KEY (task_occurrence_id, task_id) REFERENCES memory_task_attempts(task_occurrence_id, task_id),
    FOREIGN KEY (task_id, revision) REFERENCES memory_task_revisions(task_id, revision)
) STRICT;

-- A task's named values: the inputs of a revision, or the outputs declared at a checkpoint. A secret
-- keeps its name, role and source, never its text (content 'withheld').
CREATE TABLE memory_task_values (
    value_id INTEGER PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES memory_tasks(task_id),
    revision INTEGER,
    task_occurrence_id TEXT,
    checkpoint_sequence INTEGER,
    position INTEGER NOT NULL CHECK (position >= 0),
    name TEXT NOT NULL CHECK (length(name) > 0),
    role TEXT,
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'file', 'folder', 'reference', 'missing')),
    content TEXT NOT NULL CHECK (content IN ('text', 'missing', 'withheld')),
    text_value TEXT,
    sensitivity TEXT NOT NULL CHECK (sensitivity IN ('ordinary', 'secret')),
    source TEXT NOT NULL CHECK (source IN ('request', 'message', 'observation', 'previous_output', 'derived', 'unknown')),
    source_ref TEXT,
    source_version TEXT,
    CHECK ((revision IS NOT NULL) <> (checkpoint_sequence IS NOT NULL)),
    CHECK ((checkpoint_sequence IS NULL) = (task_occurrence_id IS NULL)),
    CHECK ((content = 'text') = (text_value IS NOT NULL)),
    CHECK ((value_kind = 'missing') = (content = 'missing')),
    CHECK (sensitivity = 'ordinary' OR content <> 'text'),
    CHECK (source <> 'previous_output' OR source_ref IS NOT NULL),
    FOREIGN KEY (task_id, revision) REFERENCES memory_task_revisions(task_id, revision),
    FOREIGN KEY (task_occurrence_id, checkpoint_sequence) REFERENCES memory_task_checkpoints(task_occurrence_id, sequence)
) STRICT;

-- The revision current when each call of an attempt began; the call's place in the episode is its
-- membership in memory_task_events (role 'action', or 'context' for a batch).
CREATE TABLE memory_task_call_revisions (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    task_occurrence_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    FOREIGN KEY (task_occurrence_id, task_id) REFERENCES memory_task_attempts(task_occurrence_id, task_id),
    FOREIGN KEY (task_id, revision) REFERENCES memory_task_revisions(task_id, revision)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Operation facts. What a call really did beside its request, and how each of its conditions was
-- checked. A verification's event is a 'verification' event; its verdict row is memory_verifications
-- (scope 'call'); here are what it judged, the method's version, its limits, target and samples.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_call_effects (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    performed TEXT NOT NULL CHECK (performed IN ('requested', 'substitute', 'none', 'uncertain')),
    substitute TEXT,
    not_sent_reason TEXT,
    target_element_id TEXT,
    target_role TEXT,
    target_label TEXT,
    target_section TEXT,
    checked INTEGER NOT NULL CHECK (checked IN (0, 1)),
    CHECK ((performed = 'substitute') = (substitute IS NOT NULL)),
    CHECK (not_sent_reason IS NULL OR performed = 'none'),
    CHECK ((target_element_id IS NULL) = (target_label IS NULL)),
    CHECK (target_element_id IS NOT NULL OR (target_role IS NULL AND target_section IS NULL))
) STRICT;

CREATE TABLE memory_operation_verifications (
    event_id TEXT PRIMARY KEY REFERENCES memory_verifications(event_id),
    call_event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    condition_kind TEXT NOT NULL CHECK (condition_kind IN ('requested_state_already_present', 'state_after_gesture',
        'value_read_back', 'structural_effect', 'menu_closed_after_choice', 'submenu_opened', 'window_set_changed',
        'recovery_instead_of_request', 'menu_item_chosen', 'none')),
    method_version TEXT NOT NULL CHECK (length(method_version) > 0),
    performed TEXT NOT NULL CHECK (performed IN ('requested', 'substitute', 'none', 'uncertain')),
    substitute TEXT,
    target_element_id TEXT,
    target_role TEXT,
    target_label TEXT,
    target_section TEXT,
    UNIQUE (call_event_id, condition_kind),
    CHECK (event_id <> call_event_id),
    CHECK ((performed = 'substitute') = (substitute IS NOT NULL)),
    CHECK ((target_element_id IS NULL) = (target_label IS NULL)),
    CHECK (target_element_id IS NOT NULL OR (target_role IS NULL AND target_section IS NULL))
) STRICT;

CREATE TABLE memory_operation_verification_limits (
    event_id TEXT NOT NULL REFERENCES memory_operation_verifications(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    limit_kind TEXT NOT NULL CHECK (limit_kind IN ('delivery_uncertain', 'no_after_scene', 'readback_unavailable',
        'previous_value_unknown', 'no_expectation', 'window_wide', 'command_effect_unchecked', 'label_match_only',
        'no_expected_value', 'target_not_resolved', 'unattributed', 'value_withheld')),
    PRIMARY KEY (event_id, position),
    UNIQUE (event_id, limit_kind)
) STRICT;

CREATE TABLE memory_operation_verification_samples (
    event_id TEXT NOT NULL REFERENCES memory_operation_verifications(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    sample_observation_id INTEGER NOT NULL,
    sample_event_id TEXT NOT NULL,
    sample_phase TEXT NOT NULL CHECK (sample_phase IN ('before', 'menu', 'after', 'current')),
    sample_ordinal INTEGER NOT NULL CHECK (sample_ordinal >= 0),
    sample_kind TEXT NOT NULL DEFAULT 'capture' CHECK (sample_kind = 'capture'),
    PRIMARY KEY (event_id, position),
    UNIQUE (event_id, sample_event_id, sample_phase, sample_ordinal),
    FOREIGN KEY (sample_observation_id, sample_event_id, sample_phase, sample_ordinal, sample_kind)
        REFERENCES memory_event_observations(observation_id, event_id, phase, sample_ordinal, observation_kind)
) STRICT;

-- A part of a call's end the archive refused as offered (the contract's refusal, or another fact under
-- the same identity), which the call was concluded without: its state and result are kept. A call with a
-- row here is incomplete evidence: no qualification rests on it, and its missing verification is neither
-- a pass nor an operation without an oracle. The detail is a diagnosis, never a value.
CREATE TABLE memory_call_recording_gaps (
    event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    part TEXT NOT NULL CHECK (part IN ('samples', 'effect', 'verification')),
    reason TEXT NOT NULL CHECK (reason IN ('refused', 'conflict')),
    detail TEXT CHECK (detail IS NULL OR (length(detail) > 0 AND length(CAST(detail AS BLOB)) <= 512)),
    PRIMARY KEY (event_id, part)
) STRICT;

-- A value withheld from an event's facts: where it was and why. Never the value, its length or a digest.
CREATE TABLE memory_value_redactions (
    redaction_id INTEGER PRIMARY KEY,
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    location_kind TEXT NOT NULL CHECK (location_kind IN ('argument', 'result_message', 'verification_expected',
        'verification_observed', 'target_label', 'target_section', 'target_element', 'sample_label',
        'sample_container', 'sample_title', 'observed_effect', 'listing_entry')),
    argument_name TEXT,
    argument_position INTEGER CHECK (argument_position IS NULL OR argument_position >= 0),
    condition_kind TEXT,
    sample_phase TEXT CHECK (sample_phase IS NULL OR sample_phase IN ('before', 'menu', 'after', 'current')),
    sample_ordinal INTEGER CHECK (sample_ordinal IS NULL OR sample_ordinal >= 0),
    element_position INTEGER CHECK (element_position IS NULL OR element_position >= 0),
    reason TEXT NOT NULL CHECK (reason IN ('declared_secret', 'credential_pattern', 'secret_target', 'secure_field')),
    CHECK ((location_kind = 'argument') = (argument_name IS NOT NULL AND argument_position IS NOT NULL)),
    CHECK (location_kind = 'argument' OR (argument_name IS NULL AND argument_position IS NULL)),
    CHECK ((location_kind IN ('verification_expected', 'verification_observed')) = (condition_kind IS NOT NULL)),
    CHECK ((location_kind IN ('sample_label', 'sample_container', 'sample_title'))
        = (sample_phase IS NOT NULL AND sample_ordinal IS NOT NULL)),
    CHECK ((location_kind IN ('sample_label', 'sample_container', 'listing_entry')) = (element_position IS NOT NULL))
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Unification. The archives the memory took facts from (the MCP clients' private archives of schema
-- 1), the state of each transfer, and the source of every event it took: added as it was, found
-- already present with the same content (a proven duplicate, which adds no evidence), or added under
-- a new identity because its own was taken by another fact. An origin some of whose knowledge could
-- not be taken in is `partial`, never `completed`; what it kept is named in its contributions.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_archive_origins (
    origin_id TEXT PRIMARY KEY CHECK (length(origin_id) > 0),
    origin_kind TEXT NOT NULL CHECK (origin_kind IN ('mcp_profile')),
    location TEXT NOT NULL CHECK (length(location) > 0),
    status TEXT NOT NULL CHECK (status IN ('in_progress', 'completed', 'partial', 'refused', 'failed')),
    first_seen_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    source_schema_version INTEGER,
    high_local_order INTEGER CHECK (high_local_order IS NULL OR high_local_order >= 0),
    events_added INTEGER NOT NULL DEFAULT 0 CHECK (events_added >= 0),
    events_duplicate INTEGER NOT NULL DEFAULT 0 CHECK (events_duplicate >= 0),
    events_renamed INTEGER NOT NULL DEFAULT 0 CHECK (events_renamed >= 0),
    applications_added INTEGER NOT NULL DEFAULT 0 CHECK (applications_added >= 0),
    applications_duplicate INTEGER NOT NULL DEFAULT 0 CHECK (applications_duplicate >= 0),
    brains_imported INTEGER NOT NULL DEFAULT 0 CHECK (brains_imported >= 0),
    detail TEXT
) STRICT;

CREATE TABLE memory_origin_events (
    origin_id TEXT NOT NULL REFERENCES memory_archive_origins(origin_id),
    source_event_id TEXT NOT NULL CHECK (length(source_event_id) > 0),
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    disposition TEXT NOT NULL CHECK (disposition IN ('added', 'duplicate', 'renamed')),
    PRIMARY KEY (origin_id, source_event_id),
    UNIQUE (origin_id, event_id),
    CHECK ((disposition = 'renamed') = (event_id <> source_event_id))
) STRICT;

-- What an origin's JSON Brains gave each application's Brain here, element by element: an anchor, a
-- group or a transition added with its origin's counts (its history, never a new confirmation), one
-- already present under the same identity (a proven duplicate, whose counts are not added), or one
-- excluded because it could not be taken in as it was (its identity is another application's here,
-- its anchor is not in the Brain, its group lost members, its effect held a value the admission
-- withholds). `withheld` says the admission withheld a text of it. The excluded stay in the origin's file.
-- An `application` is one of an origin archive's Brain applications that was not learned again.
CREATE TABLE memory_origin_brain_contributions (
    origin_id TEXT NOT NULL REFERENCES memory_archive_origins(origin_id),
    bundle_id TEXT NOT NULL CHECK (length(bundle_id) > 0),
    element_kind TEXT NOT NULL CHECK (element_kind IN ('anchor', 'group', 'transition', 'application')),
    element_key TEXT NOT NULL CHECK (length(element_key) > 0),
    disposition TEXT NOT NULL CHECK (disposition IN ('added', 'present', 'excluded')),
    withheld INTEGER NOT NULL DEFAULT 0 CHECK (withheld IN (0, 1)),
    PRIMARY KEY (origin_id, bundle_id, element_kind, element_key)
) STRICT;

CREATE UNIQUE INDEX memory_task_inputs_by_position ON memory_task_values(task_id, revision, position)
    WHERE revision IS NOT NULL;
CREATE UNIQUE INDEX memory_task_inputs_by_name ON memory_task_values(task_id, revision, name)
    WHERE revision IS NOT NULL;
CREATE UNIQUE INDEX memory_task_outputs_by_position ON memory_task_values(task_occurrence_id, checkpoint_sequence, position)
    WHERE checkpoint_sequence IS NOT NULL;
CREATE UNIQUE INDEX memory_task_outputs_by_name ON memory_task_values(task_occurrence_id, checkpoint_sequence, name)
    WHERE checkpoint_sequence IS NOT NULL;
CREATE UNIQUE INDEX memory_task_checkpoints_one_end ON memory_task_checkpoints(task_occurrence_id)
    WHERE checkpoint_kind = 'end';
CREATE INDEX memory_tasks_by_producer ON memory_tasks(source, source_stream_id, status);
CREATE INDEX memory_task_call_revisions_by_attempt ON memory_task_call_revisions(task_occurrence_id);
CREATE INDEX memory_operation_verifications_by_call ON memory_operation_verifications(call_event_id);
CREATE UNIQUE INDEX memory_value_redactions_by_location ON memory_value_redactions(event_id, location_kind,
    ifnull(argument_name, ''), ifnull(argument_position, -1), ifnull(condition_kind, ''), ifnull(sample_phase, ''),
    ifnull(sample_ordinal, -1), ifnull(element_position, -1));
CREATE INDEX memory_origin_events_by_event ON memory_origin_events(event_id);

-- ---------------------------------------------------------------------------------------------
-- Triggers D (schema 2): facts are never rewritten; a task's status moves once, its revision forward.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_tasks_identity_immutable BEFORE UPDATE OF
    task_id, contract_version, source, source_stream_id, trace_id, opened_at_ms
ON memory_tasks
BEGIN
    SELECT RAISE(ABORT, 'memory_tasks identity is immutable; only the status, its close and the revision move');
END;

CREATE TRIGGER memory_tasks_forward_only BEFORE UPDATE OF status, closed_at_ms, current_revision ON memory_tasks
BEGIN
    SELECT RAISE(ABORT, 'a closed task does not move')
    WHERE OLD.status <> 'open';
    SELECT RAISE(ABORT, 'a task''s current revision only moves forward, to a stored revision')
    WHERE NEW.current_revision < OLD.current_revision
       OR NOT EXISTS (SELECT 1 FROM memory_task_revisions WHERE task_id = NEW.task_id AND revision = NEW.current_revision);
END;

CREATE TRIGGER memory_tasks_kept BEFORE DELETE ON memory_tasks
BEGIN
    SELECT RAISE(ABORT, 'a task is kept');
END;

CREATE TRIGGER memory_task_revisions_immutable BEFORE UPDATE ON memory_task_revisions
BEGIN
    SELECT RAISE(ABORT, 'a task revision is immutable: a correction is a new revision');
END;

CREATE TRIGGER memory_task_revisions_in_order BEFORE INSERT ON memory_task_revisions
BEGIN
    SELECT RAISE(ABORT, 'a task revision follows the last one by one')
    WHERE NEW.revision <> 1 + ifnull((SELECT max(revision) FROM memory_task_revisions WHERE task_id = NEW.task_id), 0);
END;

CREATE TRIGGER memory_task_constraints_immutable BEFORE UPDATE ON memory_task_constraints
BEGIN
    SELECT RAISE(ABORT, 'a task revision''s constraints are immutable');
END;

CREATE TRIGGER memory_task_message_refs_immutable BEFORE UPDATE ON memory_task_message_refs
BEGIN
    SELECT RAISE(ABORT, 'a task revision''s message references are immutable');
END;

CREATE TRIGGER memory_task_values_immutable BEFORE UPDATE ON memory_task_values
BEGIN
    SELECT RAISE(ABORT, 'a task''s values are immutable');
END;

CREATE TRIGGER memory_task_attempts_immutable BEFORE UPDATE ON memory_task_attempts
BEGIN
    SELECT RAISE(ABORT, 'a task attempt is immutable; its status is its episode''s');
END;

CREATE TRIGGER memory_task_attempts_resume_same_task BEFORE INSERT ON memory_task_attempts
WHEN NEW.resumes_task_occurrence_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an attempt resumes an earlier attempt of the same task')
    WHERE (SELECT task_id FROM memory_task_attempts WHERE task_occurrence_id = NEW.resumes_task_occurrence_id)
          IS NOT NEW.task_id;
END;

CREATE TRIGGER memory_task_checkpoints_immutable BEFORE UPDATE ON memory_task_checkpoints
BEGIN
    SELECT RAISE(ABORT, 'a checkpoint is immutable');
END;

CREATE TRIGGER memory_task_checkpoints_in_order BEFORE INSERT ON memory_task_checkpoints
BEGIN
    SELECT RAISE(ABORT, 'a checkpoint follows the attempt''s last one by one, and nothing follows an end')
    WHERE NEW.sequence <> 1 + ifnull((SELECT max(sequence) FROM memory_task_checkpoints
                                      WHERE task_occurrence_id = NEW.task_occurrence_id), 0)
       OR EXISTS (SELECT 1 FROM memory_task_checkpoints
                  WHERE task_occurrence_id = NEW.task_occurrence_id AND checkpoint_kind = 'end');
END;

CREATE TRIGGER memory_task_call_revisions_immutable BEFORE UPDATE ON memory_task_call_revisions
BEGIN
    SELECT RAISE(ABORT, 'a call''s task attribution is immutable');
END;

CREATE TRIGGER memory_call_effects_immutable BEFORE UPDATE ON memory_call_effects
BEGIN
    SELECT RAISE(ABORT, 'a call''s effect is immutable');
END;

CREATE TRIGGER memory_call_effects_concluded_call BEFORE INSERT ON memory_call_effects
BEGIN
    SELECT RAISE(ABORT, 'a call''s effect belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;

CREATE TRIGGER memory_operation_verifications_immutable BEFORE UPDATE ON memory_operation_verifications
BEGIN
    SELECT RAISE(ABORT, 'an operation verification is immutable');
END;

CREATE TRIGGER memory_operation_verifications_call_scope BEFORE INSERT ON memory_operation_verifications
BEGIN
    SELECT RAISE(ABORT, 'an operation verification''s verdict row has scope call')
    WHERE (SELECT scope FROM memory_verifications WHERE event_id = NEW.event_id) IS NOT 'call';
END;

CREATE TRIGGER memory_operation_verification_limits_immutable BEFORE UPDATE ON memory_operation_verification_limits
BEGIN
    SELECT RAISE(ABORT, 'a verification''s limits are immutable');
END;

CREATE TRIGGER memory_operation_verification_samples_immutable BEFORE UPDATE ON memory_operation_verification_samples
BEGIN
    SELECT RAISE(ABORT, 'a verification''s samples are immutable');
END;

CREATE TRIGGER memory_value_redactions_immutable BEFORE UPDATE ON memory_value_redactions
BEGIN
    SELECT RAISE(ABORT, 'a declared gap is immutable');
END;

CREATE TRIGGER memory_value_redactions_kept BEFORE DELETE ON memory_value_redactions
BEGIN
    SELECT RAISE(ABORT, 'a declared gap is kept');
END;

CREATE TRIGGER memory_call_recording_gaps_immutable BEFORE UPDATE ON memory_call_recording_gaps
BEGIN
    SELECT RAISE(ABORT, 'a recording gap is immutable');
END;

CREATE TRIGGER memory_call_recording_gaps_kept BEFORE DELETE ON memory_call_recording_gaps
BEGIN
    SELECT RAISE(ABORT, 'a recording gap is kept');
END;

CREATE TRIGGER memory_call_recording_gaps_concluded_call BEFORE INSERT ON memory_call_recording_gaps
BEGIN
    SELECT RAISE(ABORT, 'a recording gap belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;

CREATE TRIGGER memory_origin_events_immutable BEFORE UPDATE ON memory_origin_events
BEGIN
    SELECT RAISE(ABORT, 'the source of a transferred fact is immutable');
END;

CREATE TRIGGER memory_origin_brain_contributions_immutable BEFORE UPDATE ON memory_origin_brain_contributions
BEGIN
    SELECT RAISE(ABORT, 'what an origin contributed is immutable');
END;

CREATE TRIGGER memory_origin_brain_contributions_kept BEFORE DELETE ON memory_origin_brain_contributions
BEGIN
    SELECT RAISE(ABORT, 'what an origin contributed is kept');
END;
