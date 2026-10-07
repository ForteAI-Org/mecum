"""SQL checks on the living memory's schema resource, the one file SQLiteMemory ships.

They prove the shape of the schema (constraints, triggers, round trips) on the resource included
in the module, through Python's sqlite3: not the Swift store, not the Brain's retention, not the
desktop. `make test` runs them; pass another DDL path as the first argument to check a copy.
The library used is Python's, and it says nothing about the one the Swift binary links.
"""
import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DDL = Path(sys.argv[1]) if len(sys.argv) > 1 else \
    ROOT / "Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql"
db = sqlite3.connect(":memory:")
# The resource carries no PRAGMA of its own: foreign keys are enabled per connection, as the store does.
db.executescript("PRAGMA foreign_keys = ON;\n" + DDL.read_text())
passed = []
LIB = db.execute("SELECT sqlite_version(), sqlite_source_id()").fetchone()


def ok(label):
    passed.append(label)


def insert(table, **row):
    keys = list(row)
    db.execute(f"INSERT INTO {table} ({','.join(keys)}) VALUES ({','.join('?' for _ in keys)})",
               [row[k] for k in keys])


def rejects(label, operation):
    db.execute("SAVEPOINT invalid_case")
    try:
        operation()
    except sqlite3.IntegrityError:
        passed.append("rejects: " + label)
    else:
        raise AssertionError(f"Invalid row accepted: {label}")
    finally:
        db.execute("ROLLBACK TO invalid_case")
        db.execute("RELEASE invalid_case")


def event(eid, app=1, kind="action", source="app", **extra):
    insert("memory_events", event_id=eid, source=source, source_stream_id="stream",
           source_key=eid, event_kind=kind, app_id=app, occurred_at_ms=100,
           capture_status="complete", **extra)


def capture(eid, phase="after", ordinal=0, status="complete", surface="window", **extra):
    insert("memory_event_observations", event_id=eid, phase=phase, sample_ordinal=ordinal,
           observation_kind="capture", status=status, surface_kind=surface, **extra)
    return db.execute("SELECT last_insert_rowid()").fetchone()[0]


def argument(name, value, position=0, **owner):
    kind = "boolean" if isinstance(value, bool) else "integer" if isinstance(value, int) else "real" if isinstance(value, float) else "text"
    insert("memory_operation_arguments", argument_name=name, position=position,
           value_kind=kind, **{f"{kind}_value": int(value) if kind == "boolean" else value}, **owner)


# ------------------------------------------------------------------ base fixtures (from v4)
for app in (1, 2):
    insert("brain_apps", app_id=app, bundle_id=f"test.app{app}")
    insert("brain_app_contexts", context_id=app, app_id=app, app_version="1", app_locale="it")
    insert("brain_scenes", scene_id=f"scene{app}", app_id=app, title_bucket="Chat",
           first_seen_ms=0, last_seen_ms=100)
    insert("brain_anchors", anchor_id=f"anchor{app}", app_id=app, insertion_order=0, kind="button", label="Invia",
           first_seen_ms=0, last_seen_ms=100)
    insert("memory_routes", route_id=f"route{app}", name="Invia", status="draft", created_at_ms=0)
    insert("memory_route_steps", step_id=f"step{app}", route_id=f"route{app}", position=0,
           step_kind="goal", goal_text="Messaggio presente", app_id=app)
    insert("memory_route_parameters", parameter_id=f"param{app}", route_id=f"route{app}",
           name="text", direction="input", value_type="text", is_required=1)
    insert("memory_step_operations", operation_id=f"op{app}", route_id=f"route{app}",
           step_id=f"step{app}", app_id=app, position=0, tool_kind="type_text")

insert("brain_scene_elements", scene_element_id="list", app_id=1, scene_id="scene1",
       element_key="conversation_list", element_scope="collection", first_seen_ms=0, last_seen_ms=100)
insert("brain_scene_elements", scene_element_id="row", app_id=1, scene_id="scene1",
       element_key="conversation_row", element_scope="item_template", parent_element_id="list",
       first_seen_ms=0, last_seen_ms=100)
for i, person in enumerate(("Persona A", "Persona B")):
    eid = f"watch{i}"
    event(eid, kind="input", source="watcher", context_id=1)
    insert("memory_input_events", event_id=eid, input_kind="click")
    cap = capture(eid, phase="after")
    insert("memory_event_observations", event_id=eid, phase="after", observation_kind="element",
           status="observed", label=person, parent_observation_id=cap)
    insert("memory_event_scenes", event_id=eid, app_id=1, phase="after", scene_id="scene1",
           match_status="confirmed", matched_by="rules", matcher_version="test")
assert db.execute("SELECT count(*) FROM brain_scenes WHERE app_id=1").fetchone()[0] == 1
ok("two chat observations share one structural scene")

insert("brain_transitions", transition_id="transition1", app_id=1, insertion_order=0, from_scene_id="scene1",
       to_scene_id="scene1", scene_element_id="row", trigger_kind="click", effect_kind="conversation_opened",
       status="candidate", first_seen_ms=0, last_seen_ms=100)
insert("brain_evidence", app_id=1, event_id="watch0", transition_id="transition1", relation="supports",
       assessed_by="rules", assessment_version="test", assessed_at_ms=100)
insert("memory_task_occurrences", task_occurrence_id="task", started_at_ms=0, status="observed")
insert("memory_task_events", task_occurrence_id="task", event_id="watch0", position=0, role="observation")
insert("memory_task_labels", label_id="label", task_occurrence_id="task", label="Apri conversazione",
       assigned_by="test", confidence=0.5, status="candidate", assigned_at_ms=100)
insert("memory_step_occurrences", step_occurrence_id="occurrence", task_occurrence_id="task",
       step_id="step1", started_at_ms=0, status="observed")
insert("memory_step_events", step_occurrence_id="occurrence", event_id="watch0", position=0, role="observation")
insert("memory_step_evidence", step_id="step1", step_occurrence_id="occurrence", relation="supports",
       assessed_by="test", assessed_at_ms=100)
insert("memory_step_checks", check_id="check", route_id="route1", step_id="step1", app_id=1,
       position=0, check_kind="state", expected_anchor_id="anchor1", expected_state="on")
insert("memory_operation_arguments", operation_id="op1", route_id="route1", app_id=1, argument_name="text",
       value_kind="parameter", parameter_id="param1")
ok("one-step Route, Watcher attribution, state check and parameter reference")

fixtures = {
    "status": {}, "windows": {"app": "test.app1"}, "apps": {"query": "chat"},
    "open_session": {"app": "test.app1", "window": "Chat"}, "observe": {},
    "act": {"target": "Invia", "verb": "set_toggle", "value": "on", "section": "Chat"},
    "select": {"control": "Formato", "item": "Mono"},
    "type_text": {"target": "Messaggio", "text": "Ciao\nseconda riga", "replace": False, "section": "Chat"},
    "press_key": {"key": "return", "modifiers": ["shift", "cmd"], "count": 2},
    "scroll": {"direction": "down", "lines": 3, "target": "Conversazioni", "section": "Sidebar"},
    "drag": {"from": "Elemento", "dx": 2.5, "dy": -1.0, "section": "Canvas"},
    "context_menu": {"target": "Messaggio", "item": "Copy", "section": "Chat"},
    "batch": {}, "close_session": {},
}
for tool, args in fixtures.items():
    eid = f"tool_{tool}"
    event(eid, session_id="ephemeral-session", trace_id="trace")
    insert("memory_agent_actions", event_id=eid, app_id=1, tool_kind=tool, execution_status="completed")
    for name, value in args.items():
        for pos, item in enumerate(value if isinstance(value, list) else [value]):
            argument(name, item, pos, event_id=eid, app_id=1)
    rows = db.execute("SELECT argument_name,position,value_kind,text_value,integer_value,real_value,boolean_value FROM memory_operation_arguments WHERE event_id=? ORDER BY argument_name,position", (eid,)).fetchall()
    actual = {}
    for name, pos, kind, *values in rows:
        value = next(v for v in values if v is not None)
        if kind == "boolean": value = bool(value)
        if isinstance(args[name], list): actual.setdefault(name, []).append(value)
        else: actual[name] = value
    assert actual == args, (tool, actual, args)
ok("14 app tool envelopes and scalar/list argument round-trips")
event("drag_target")
insert("memory_agent_actions", event_id="drag_target", app_id=1, tool_kind="drag", execution_status="planned")
argument("from", "File", event_id="drag_target", app_id=1)
argument("to", "Cartella", event_id="drag_target", app_id=1)
for pos, state in enumerate(("completed", "failed", "skipped")):
    eid = f"batch_{pos}"
    event(eid, parent_event_id="tool_batch", parent_position=pos)
    insert("memory_agent_actions", event_id=eid, app_id=1, tool_kind="act", execution_status=state)
    argument("target", f"Button {pos}", event_id=eid, app_id=1)
assert db.execute("SELECT count(*) FROM memory_events WHERE parent_event_id='tool_batch'").fetchone()[0] == 3
ok("batch preserves executed, failed and unattempted requests")

insert("memory_route_steps", step_id="call", route_id="route1", position=1, step_kind="route_call",
       goal_text="Sottoprocedura", called_route_id="route2")
insert("memory_route_call_bindings", step_id="call", route_id="route1", called_route_id="route2",
       called_parameter_id="param2", source_parameter_id="param1")

rejects("cross-app event context", lambda: event("bad_context", context_id=2))
rejects("source retry duplicate", lambda: db.execute("INSERT INTO memory_events(event_id,source,source_stream_id,source_key,event_kind,occurred_at_ms,capture_status) VALUES ('duplicate','app','stream','tool_act','action',100,'complete')"))
rejects("input detail attached to action", lambda: insert("memory_input_events", event_id="tool_act", input_kind="click"))
rejects("cross-app event scene", lambda: insert("memory_event_scenes", event_id="watch0", app_id=1, phase="before", scene_id="scene2", match_status="confirmed", matched_by="test", matcher_version="test"))
insert("brain_scenes", scene_id="other_scene1", app_id=1, title_bucket="Other", first_seen_ms=0, last_seen_ms=100)
rejects("two confirmed scenes for one sample", lambda: insert("memory_event_scenes", event_id="watch0", app_id=1, phase="after", scene_id="other_scene1", match_status="confirmed", matched_by="test", matcher_version="test"))
ev = dict(app_id=1, event_id="watch1", relation="supports", assessed_by="test", assessment_version="test", assessed_at_ms=100)
rejects("evidence without target", lambda: insert("brain_evidence", **ev))
rejects("evidence with two targets", lambda: insert("brain_evidence", scene_id="scene1", anchor_id="anchor1", **ev))
rejects("evidence cross-app target", lambda: insert("brain_evidence", anchor_id="anchor2", **ev))
rejects("cross-app transition", lambda: insert("brain_transitions", transition_id="bad", app_id=1, insertion_order=9, from_scene_id="scene1", to_scene_id="scene2", trigger_kind="click", effect_kind="changed", status="candidate", first_seen_ms=0, last_seen_ms=100))
rejects("step evidence refers to another step", lambda: insert("memory_step_evidence", step_id="step2", step_occurrence_id="occurrence", relation="supports", assessed_by="test", assessed_at_ms=100))
rejects("operation refers to another Route step", lambda: insert("memory_step_operations", operation_id="bad", route_id="route1", step_id="step2", position=3, tool_kind="act"))
rejects("argument parameter belongs to another Route", lambda: insert("memory_operation_arguments", operation_id="op1", route_id="route1", app_id=1, argument_name="wrong", value_kind="parameter", parameter_id="param2"))
rejects("argument anchor belongs to another app", lambda: insert("memory_operation_arguments", event_id="tool_act", app_id=1, argument_name="wrong", value_kind="anchor", anchor_id="anchor2"))
rejects("argument with two owners", lambda: insert("memory_operation_arguments", operation_id="op1", event_id="tool_act", route_id="route1", app_id=1, argument_name="wrong", value_kind="text", text_value="x"))
rejects("argument wrong typed column", lambda: insert("memory_operation_arguments", event_id="tool_act", app_id=1, argument_name="wrong", value_kind="boolean", text_value="true"))
rejects("argument two values", lambda: insert("memory_operation_arguments", event_id="tool_act", app_id=1, argument_name="wrong", value_kind="text", text_value="x", integer_value=1))
rejects("boolean outside domain", lambda: insert("memory_operation_arguments", event_id="tool_act", app_id=1, argument_name="wrong", value_kind="boolean", boolean_value=2))
rejects("nonconvertible integer rejected by STRICT", lambda: insert("memory_operation_arguments", event_id="tool_act", app_id=1, argument_name="wrong", value_kind="integer", integer_value="abc"))
rejects("duplicate scalar argument", lambda: argument("target", "Again", event_id="tool_act", app_id=1))
rejects("Route call uses wrong callee parameter", lambda: insert("memory_route_call_bindings", step_id="call", route_id="route1", called_route_id="route2", called_parameter_id="param1", literal_text="x"))
rejects("Route call uses wrong caller parameter", lambda: db.execute("UPDATE memory_route_call_bindings SET source_parameter_id='param2' WHERE step_id='call'"))
rejects("check uses another Route parameter", lambda: insert("memory_step_checks", check_id="bad", route_id="route1", step_id="step1", app_id=1, position=1, check_kind="value", expected_parameter_id="param2"))
rejects("batch child crosses steps", lambda: insert("memory_step_operations", operation_id="bad_child", route_id="route1", step_id="step1", app_id=1, parent_operation_id="op2", position=0, tool_kind="act"))
rejects("event parent is itself", lambda: event("self", parent_event_id="self", parent_position=0))

for suffix, mode, payload in [
    ("literal", "literal", {"literal_text": "Input 1"}),
    ("request", "request_slot", {"slot_name": "requested_input"}),
    ("context", "context_slot", {"slot_name": "active_document"}),
]:
    insert("memory_experiences", experience_id=f"experience_{suffix}", phrase="Attiva ingresso",
           route_id="route1", step_id="step1", created_at_ms=0)
    insert("memory_experience_bindings", experience_id=f"experience_{suffix}", route_id="route1",
           parameter_id="param1", value_type="text", binding_kind=mode, **payload)
ok("Experience binds a literal, a request slot or a current context slot")
for kind, value in [("integer", 3), ("real", 0.5), ("boolean", 1)]:
    insert("memory_route_parameters", parameter_id=f"binding_{kind}", route_id="route1",
           name=kind, direction="input", value_type=kind, is_required=1)
    insert("memory_experience_bindings", experience_id="experience_literal", route_id="route1",
           parameter_id=f"binding_{kind}", value_type=kind, binding_kind="literal", **{f"literal_{kind}": value})
ok("Experience literals support text, integer, real and boolean")
binding = dict(experience_id="experience_request", route_id="route1", parameter_id="param1",
               value_type="text", binding_kind="literal", literal_text="Input 2")
rejects("duplicate Experience binding", lambda: insert("memory_experience_bindings", **binding))
rejects("binding references another Route parameter", lambda: insert("memory_experience_bindings", **(binding | {"parameter_id": "param2"})))
rejects("binding references another Route Experience", lambda: insert("memory_experience_bindings", **(binding | {"route_id": "route2", "parameter_id": "param2"})))
rejects("binding type differs from parameter type", lambda: db.execute("UPDATE memory_experience_bindings SET value_type='integer' WHERE experience_id='experience_request'"))
rejects("binding slot cannot be empty", lambda: db.execute("UPDATE memory_experience_bindings SET slot_name='' WHERE experience_id='experience_request'"))
rejects("binding slot is mandatory", lambda: db.execute("UPDATE memory_experience_bindings SET slot_name=NULL WHERE experience_id='experience_context'"))
rejects("slot and literal cannot coexist", lambda: db.execute("UPDATE memory_experience_bindings SET literal_text='stale value' WHERE experience_id='experience_context'"))
rejects("binding literal cannot be empty of values", lambda: db.execute("UPDATE memory_experience_bindings SET literal_text=NULL WHERE experience_id='experience_literal' AND parameter_id='param1'"))
rejects("binding literal rejects wrong value column", lambda: db.execute("UPDATE memory_experience_bindings SET literal_text=NULL,literal_integer=3 WHERE experience_id='experience_literal' AND parameter_id='param1'"))
rejects("binding rejects unknown resolution mode", lambda: db.execute("UPDATE memory_experience_bindings SET binding_kind='anything' WHERE experience_id='experience_request'"))

db.commit()
try:
    with db:
        event("rollback")
        insert("brain_evidence", app_id=1, event_id="rollback", anchor_id="missing", relation="supports",
               assessed_by="test", assessment_version="test", assessed_at_ms=100)
except sqlite3.IntegrityError:
    pass
assert db.execute("SELECT count(*) FROM memory_events WHERE event_id='rollback'").fetchone()[0] == 0
ok("transaction rolls back event and invalid evidence together")

# ------------------------------------------------------------------ D2 retirement (from v4)
insert("brain_app_window_epochs", app_id=1, window_family="Chat", epoch=3)
insert("brain_app_window_epochs", app_id=1, window_family="Settings", epoch=1)
db.execute("INSERT INTO brain_app_window_epochs VALUES (1, 'Chat', 4) "
           "ON CONFLICT(app_id, window_family) DO UPDATE SET epoch=excluded.epoch")
assert db.execute("SELECT window_family,epoch FROM brain_app_window_epochs WHERE app_id=1 ORDER BY window_family").fetchall() == [("Chat", 4), ("Settings", 1)]
ok("window clocks round-trip independently and support an atomic upsert")
rejects("window clock requires an existing app", lambda: insert("brain_app_window_epochs", app_id=99, window_family="Chat", epoch=1))
rejects("window clock cannot be negative", lambda: db.execute("UPDATE brain_app_window_epochs SET epoch=-1 WHERE app_id=1"))
rejects("window clock is unique per app and family", lambda: insert("brain_app_window_epochs", app_id=1, window_family="Chat", epoch=0))

insert("brain_groups", group_id="group1", app_id=1, insertion_order=0, axis="vertical", shared_kind="button", last_seen_ms=100)
insert("brain_group_members", app_id=1, group_id="group1", anchor_id="anchor1", position=0)
# ---- S2 increment 2: ObjectAnchor.groupID is an explicit nullable column, distinct from the ordered membership.
assert "current_group_id" in [column[1] for column in db.execute("PRAGMA table_info(brain_anchors)")]
insert("brain_groups", group_id="group1b", app_id=1, insertion_order=1, axis="horizontal", shared_kind="button", last_seen_ms=100)
insert("brain_groups", group_id="group2", app_id=2, insertion_order=0, axis="vertical", shared_kind="button", last_seen_ms=100)
insert("brain_group_members", app_id=1, group_id="group1b", anchor_id="anchor1", position=0)
db.execute("UPDATE brain_anchors SET current_group_id='group1' WHERE anchor_id='anchor1'")
assert db.execute("SELECT current_group_id FROM brain_anchors WHERE anchor_id='anchor1'").fetchone()[0] == "group1"
assert db.execute("SELECT count(*) FROM brain_group_members WHERE anchor_id='anchor1'").fetchone()[0] == 2
ok("D2: the anchor's current group is an explicit nullable column with a per-app FK, while the anchor stays a member of two groups")
rejects("D2: current group must be an existing group", lambda: db.execute("UPDATE brain_anchors SET current_group_id='nowhere' WHERE anchor_id='anchor1'"))
rejects("D2: current group of another app", lambda: db.execute("UPDATE brain_anchors SET current_group_id='group2' WHERE anchor_id='anchor1'"))
rejects("D2: current group of another app on insert", lambda: insert("brain_anchors", anchor_id="cross", app_id=2, insertion_order=7, kind="button", label="X", first_seen_ms=0, last_seen_ms=0, current_group_id="group1"))
db.execute("UPDATE brain_anchors SET current_group_id=NULL WHERE anchor_id='anchor1'")
db.execute("UPDATE brain_anchors SET current_group_id='group1' WHERE anchor_id='anchor1'")
ok("D2: the current group may be NULL (the algorithm's nil) and be set again")
insert("brain_evidence", app_id=1, event_id="tool_act", anchor_id="anchor1", relation="supports",
       assessed_by="test", assessment_version="test", assessed_at_ms=100)
insert("brain_evidence", app_id=1, event_id="tool_act", group_id="group1", relation="supports",
       assessed_by="test", assessment_version="test", assessed_at_ms=100)
for table, key, value in [("brain_anchors", "anchor_id", "anchor1"),
                          ("brain_groups", "group_id", "group1"),
                          ("brain_transitions", "transition_id", "transition1")]:
    def update_retirement(assignments, parameters=()):
        db.execute(f"UPDATE {table} SET {assignments} WHERE {key}=?", (*parameters, value))
    rejects(f"{table}: retirement requires epoch and cause", lambda: update_retirement("retired_at_ms=200"))
    rejects(f"{table}: epoch alone is not retirement", lambda: update_retirement("retired_epoch=1"))
    rejects(f"{table}: cause alone is not retirement", lambda: update_retirement("retirement_cause='stale'"))
    rejects(f"{table}: negative retirement epoch", lambda: update_retirement("retired_at_ms=200, retired_epoch=-1, retirement_cause='stale'"))
    rejects(f"{table}: retirement before last observation", lambda: update_retirement("retired_at_ms=50, retired_epoch=1, retirement_cause='stale'"))
    rejects(f"{table}: unknown retirement cause", lambda: update_retirement("retired_at_ms=200, retired_epoch=1, retirement_cause='unknown'"))
rejects("anchor label source is a known protection category", lambda: db.execute("UPDATE brain_anchors SET label_source='anything' WHERE anchor_id='anchor1'"))
rejects("transition retirement is independent of confidence status", lambda: db.execute("UPDATE brain_transitions SET status='retired' WHERE transition_id='transition1'"))
db.execute("UPDATE brain_transitions SET status='trusted' WHERE transition_id='transition1'")
for table, key, value in [("brain_anchors", "anchor_id", "anchor1"),
                          ("brain_groups", "group_id", "group1"),
                          ("brain_transitions", "transition_id", "transition1")]:
    db.execute(f"UPDATE {table} SET retired_at_ms=200,retired_epoch=4,retirement_cause='stale' WHERE {key}=?", (value,))
    assert db.execute(f"SELECT count(*) FROM {table} WHERE {key}=? AND retired_at_ms IS NULL", (value,)).fetchone()[0] == 0
    assert db.execute(f"SELECT count(*) FROM {table} WHERE {key}=?", (value,)).fetchone()[0] == 1
assert db.execute("SELECT count(*) FROM brain_evidence WHERE anchor_id='anchor1' OR group_id='group1' OR transition_id='transition1'").fetchone()[0] == 3
assert db.execute("SELECT status FROM brain_transitions WHERE transition_id='transition1'").fetchone()[0] == "trusted"
assert db.execute("SELECT expected_anchor_id FROM memory_step_checks WHERE check_id='check'").fetchone()[0] == "anchor1"
ok("retired knowledge is excluded by active queries while evidence, checks and confidence survive")
assert db.execute("SELECT current_group_id FROM brain_anchors WHERE anchor_id='anchor1'").fetchone()[0] == "group1"
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("D2: retiring a group keeps the anchors' current_group_id references valid")
rejects("referenced retired anchor cannot be physically deleted", lambda: db.execute("DELETE FROM brain_anchors WHERE anchor_id='anchor1'"))
insert("brain_anchors", anchor_id="anchor1_return", app_id=1, insertion_order=1, kind="button", label="Invia",
       label_source="observed", first_seen_ms=300, last_seen_ms=300, last_seen_epoch=5)
insert("brain_anchor_states", anchor_id="anchor1_return", state="on", seen_count=1)
assert db.execute("SELECT anchor_id FROM brain_anchors WHERE app_id=1 AND label='Invia' AND retired_at_ms IS NULL").fetchall() == [("anchor1_return",)]
assert db.execute("SELECT count(*) FROM brain_evidence WHERE anchor_id='anchor1_return'").fetchone()[0] == 0
ok("reappearance can have a new active identity and current state without inherited evidence")

# ================================================================== A. app scope
insert("brain_scenes", scene_id="app_scope1", app_id=1, title_bucket="#app", scene_kind="app",
       first_seen_ms=0, last_seen_ms=0, observation_count=0)
ok("A: one app-scope row per app is representable (scene_kind='app', title_bucket='#app', no structure)")
rejects("A: second app scope for the same app", lambda: insert("brain_scenes", scene_id="app_scope1b", app_id=1, title_bucket="#app", scene_kind="app", first_seen_ms=0, last_seen_ms=0, observation_count=0))
rejects("A: app scope with a structural key", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="#app", scene_kind="app", structural_key="k", first_seen_ms=0, last_seen_ms=0, observation_count=0))
rejects("A: app scope with observation_count > 0", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="#app", scene_kind="app", first_seen_ms=0, last_seen_ms=0, observation_count=1))
rejects("A: app scope with a title pattern", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="#app", scene_kind="app", window_title_pattern="Chat", first_seen_ms=0, last_seen_ms=0, observation_count=0))
rejects("A: app scope without the marker bucket", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="Chat", scene_kind="app", first_seen_ms=0, last_seen_ms=0, observation_count=0))
rejects("A: structural scene using the marker bucket", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="#app", scene_kind="window", first_seen_ms=0, last_seen_ms=0))
rejects("A: unknown scene_kind", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="Chat", scene_kind="unknown", first_seen_ms=0, last_seen_ms=0))
rejects("A: scene_kind is immutable", lambda: db.execute("UPDATE brain_scenes SET scene_kind='window', title_bucket='Chat' WHERE scene_id='app_scope1'"))
rejects("A: structural element on the app scope", lambda: insert("brain_scene_elements", scene_element_id="x", app_id=1, scene_id="app_scope1", element_key="k", first_seen_ms=0, last_seen_ms=0))
rejects("A: element moved onto the app scope", lambda: db.execute("UPDATE brain_scene_elements SET scene_id='app_scope1' WHERE scene_element_id='row'"))
rejects("A: role on the app scope", lambda: insert("brain_scene_roles", scene_id="app_scope1", role="AXButton"))
rejects("A: label on the app scope", lambda: insert("brain_scene_labels", scene_id="app_scope1", label_token="invia"))
rejects("A: observation associated with the app scope", lambda: insert("memory_event_scenes", event_id="watch1", app_id=1, phase="after", scene_id="app_scope1", match_status="candidate", matched_by="structure", matcher_version="v2"))
rejects("A: association moved onto the app scope", lambda: db.execute("UPDATE memory_event_scenes SET scene_id='app_scope1' WHERE event_id='watch0'"))
rejects("A: evidence targeting the app scope", lambda: insert("brain_evidence", app_id=1, event_id="watch1", scene_id="app_scope1", relation="supports", assessed_by="t", assessment_version="t", assessed_at_ms=1))
rejects("A: transition towards the app scope", lambda: insert("brain_transitions", transition_id="x", app_id=1, insertion_order=9, from_scene_id="scene1", to_scene_id="app_scope1", anchor_id="anchor1_return", trigger_kind="click", effect_kind="stateFlip", status="candidate", first_seen_ms=0, last_seen_ms=0))
rejects("A: transition from the app scope with a structural element", lambda: insert("brain_transitions", transition_id="x", app_id=1, insertion_order=9, from_scene_id="app_scope1", scene_element_id="row", trigger_kind="click", effect_kind="stateFlip", status="candidate", first_seen_ms=0, last_seen_ms=0))
insert("brain_transitions", transition_id="scope_transition", app_id=1, insertion_order=1, from_scene_id="app_scope1",
       anchor_id="anchor1_return", trigger_kind="click", effect_kind="stateFlip", effect_text="off>on",
       required_target_state="off", resulting_target_state="on", status="candidate", first_seen_ms=300, last_seen_ms=300)
insert("brain_evidence", app_id=1, event_id="tool_act", transition_id="scope_transition", relation="supports",
       assessed_by="brain", assessment_version="1", assessed_at_ms=300)
rejects("A: the same event cannot support the same transition twice", lambda: insert("brain_evidence", app_id=1, event_id="tool_act", transition_id="scope_transition", relation="supports", assessed_by="brain", assessment_version="1", assessed_at_ms=301))
ok("A: anchor->effect knowledge lives on the app scope with anchor, states and one evidence per event")
db.execute("UPDATE brain_transitions SET to_scene_id=NULL WHERE transition_id='scope_transition'")
rejects("A: destination moved onto the app scope", lambda: db.execute("UPDATE brain_transitions SET to_scene_id='app_scope1' WHERE transition_id='scope_transition'"))

# ================================================================== B. observable orders
insert("brain_anchor_aliases", anchor_id="anchor1_return", alias="Send", position=0)
insert("brain_anchor_aliases", anchor_id="anchor1_return", alias="Invia ora", position=1)
assert [r[0] for r in db.execute("SELECT alias FROM brain_anchor_aliases WHERE anchor_id='anchor1_return' ORDER BY position")] == ["Send", "Invia ora"]
ok("B: alias order is persisted and reproduced (aliases.first, prefix(3))")
rejects("B: two aliases at one position", lambda: insert("brain_anchor_aliases", anchor_id="anchor1_return", alias="Third", position=1))
rejects("B: alias without position", lambda: db.execute("INSERT INTO brain_anchor_aliases(anchor_id, alias) VALUES ('anchor1_return', 'Fourth')"))
rejects("B: duplicate alias text", lambda: insert("brain_anchor_aliases", anchor_id="anchor1_return", alias="Send", position=7))
for order in (2, 3):
    insert("brain_anchors", anchor_id=f"a{order}", app_id=1, insertion_order=order, kind="button", label="X", first_seen_ms=0, last_seen_ms=0)
assert [r[0] for r in db.execute("SELECT anchor_id FROM brain_anchors WHERE app_id=1 AND retired_at_ms IS NULL ORDER BY insertion_order")] == ["anchor1_return", "a2", "a3"]
ok("B: active anchors load in UIBrain.objects order (insertion_order), retired rows excluded")
rejects("B: duplicate anchor insertion_order within an app", lambda: insert("brain_anchors", anchor_id="dup", app_id=1, insertion_order=2, kind="button", label="X", first_seen_ms=0, last_seen_ms=0))
insert("brain_anchors", anchor_id="b2", app_id=2, insertion_order=2, kind="button", label="X", first_seen_ms=0, last_seen_ms=0)
ok("B: insertion_order is scoped per app")
rejects("B: duplicate group insertion_order", lambda: insert("brain_groups", group_id="g", app_id=1, insertion_order=0, axis="vertical", shared_kind="button", last_seen_ms=0))
rejects("B: duplicate transition insertion_order", lambda: insert("brain_transitions", transition_id="t", app_id=1, insertion_order=1, from_scene_id="scene1", anchor_id="a2", trigger_kind="click", effect_kind="x", status="candidate", first_seen_ms=0, last_seen_ms=0))
rejects("B: anchor without insertion_order", lambda: db.execute("INSERT INTO brain_anchors(anchor_id, app_id, kind, label, first_seen_ms, last_seen_ms) VALUES ('noorder', 1, 'button', 'X', 0, 0)"))
insert("brain_group_members", app_id=1, group_id="group1", anchor_id="a3", position=1)
insert("brain_group_members", app_id=1, group_id="group1", anchor_id="a2", position=2)
db.execute("UPDATE brain_group_members SET position = position + 100 WHERE group_id='group1'")
db.execute("UPDATE brain_group_members SET position = 0 WHERE group_id='group1' AND anchor_id='a2'")
db.execute("UPDATE brain_group_members SET position = 1 WHERE group_id='group1' AND anchor_id='a3'")
db.execute("DELETE FROM brain_group_members WHERE group_id='group1' AND anchor_id='anchor1'")
assert [r[0] for r in db.execute("SELECT anchor_id FROM brain_group_members WHERE group_id='group1' ORDER BY position")] == ["a2", "a3"]
ok("B: group membership can be reordered atomically and a departed member is removed (SiblingGroup.memberAnchors)")

# ================================================================== C. null-safe constraints and vocabularies
event("global_call", app=None)
insert("memory_agent_actions", event_id="global_call", app_id=None, tool_kind="status", execution_status="completed")
ok("C: event and action without a single app (both NULL) are accepted")
event("app_call")
rejects("C: event with app A and action with app NULL", lambda: insert("memory_agent_actions", event_id="app_call", app_id=None, tool_kind="act", execution_status="planned"))
rejects("C: event with app A and action with app B", lambda: insert("memory_agent_actions", event_id="app_call", app_id=2, tool_kind="act", execution_status="planned"))
rejects("C: global event with an action claiming app A", lambda: insert("memory_agent_actions", event_id="global_call", app_id=1, tool_kind="act", execution_status="planned"))
rejects("C: event app_id cannot be rewritten afterwards", lambda: db.execute("UPDATE memory_events SET app_id=2 WHERE event_id='app_call'"))
rejects("C: event identity cannot be rewritten afterwards", lambda: db.execute("UPDATE memory_events SET occurred_at_ms=1 WHERE event_id='app_call'"))
db.execute("UPDATE memory_events SET capture_status='partial' WHERE event_id='app_call'")
ok("C: capture_status is the one mutable field of an event")
rejects("C: action identity cannot be rewritten", lambda: db.execute("UPDATE memory_agent_actions SET app_id=NULL WHERE event_id='tool_act'"))
db.execute("UPDATE memory_agent_actions SET execution_status='started' WHERE event_id='drag_target'")
ok("C: execution status has its own updates")
db.execute("UPDATE memory_agent_actions SET started_at_ms=10 WHERE event_id='drag_target'")
rejects("C: a label before the effect is a list", lambda: insert("memory_agent_action_effect_labels", event_id="drag_target", position=0, label="Cartella"))
db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=12, duration_ms=7, result_kind='found_acted', result_message='dragged', observed_effect_kind='elementsAppeared' WHERE event_id='drag_target'")
# S3-d correction: a list effect is rows, in order; a label with a separator stays one label.
for position, label in enumerate(["A|B", "C", ""]):
    insert("memory_agent_action_effect_labels", event_id="drag_target", position=position, label=label)
assert db.execute("SELECT started_at_ms, completed_at_ms, duration_ms FROM memory_agent_actions WHERE event_id='drag_target'").fetchone() == (10, 12, 7)
assert [r[0] for r in db.execute("SELECT label FROM memory_agent_action_effect_labels WHERE event_id='drag_target' ORDER BY position")] == ["A|B", "C", ""]
ok("C: a call keeps the instant it started, its end, its monotonic duration and a list effect as ordered label rows (S3-d)")
event("timed_call")
rejects("C: a planned call has no start", lambda: insert("memory_agent_actions", event_id="timed_call", app_id=1, tool_kind="act", execution_status="planned", started_at_ms=5))
rejects("C: a planned call has no duration", lambda: insert("memory_agent_actions", event_id="timed_call", app_id=1, tool_kind="act", execution_status="planned", duration_ms=5))
rejects("C: a negative duration", lambda: insert("memory_agent_actions", event_id="timed_call", app_id=1, tool_kind="act", execution_status="completed", completed_at_ms=1, duration_ms=-1))
insert("memory_agent_actions", event_id="timed_call", app_id=1, tool_kind="act", execution_status="started", started_at_ms=10)
rejects("C: a title under a list family", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='menuOpened', observed_effect_text='x' WHERE event_id='timed_call'"))
rejects("C: a flip without its states", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='stateFlip' WHERE event_id='timed_call'"))
rejects("C: states without a flip", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='windowTitleChanged', observed_effect_text='Saved', observed_state_before='off', observed_state_after='on' WHERE event_id='timed_call'"))
rejects("C: a title family without its title", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='windowTitleChanged' WHERE event_id='timed_call'"))
rejects("C: an unknown effect family", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='rowsMoved' WHERE event_id='timed_call'"))
rejects("C: an observed effect on a failed call", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='failed', completed_at_ms=11, observed_effect_kind='stateFlip', observed_state_before='off', observed_state_after='on' WHERE event_id='timed_call'"))
# The calendar may run backwards between the start and the end: the chronology is kept as it was, the duration is monotone.
db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=9, duration_ms=3, result_kind='found_acted', result_message='set', observed_effect_kind='stateFlip', observed_state_before='off', observed_state_after='on' WHERE event_id='timed_call'")
assert db.execute("SELECT started_at_ms, completed_at_ms, duration_ms, observed_state_before, observed_state_after FROM memory_agent_actions WHERE event_id='timed_call'").fetchone() == (10, 9, 3, "off", "on")
ok("C: an end earlier than the start on the calendar is a valid record with its monotone duration; a flip keeps both states (S3-d)")
rejects("C: a label under a scalar family", lambda: insert("memory_agent_action_effect_labels", event_id="timed_call", position=0, label="x"))
# merge-memory: main's perception reports a selection change, a family with no title, states or labels.
event("selection_call")
insert("memory_agent_actions", event_id="selection_call", app_id=1, tool_kind="insert_text", execution_status="started", started_at_ms=10)
rejects("C: a selection change with a title", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='textSelectionChanged', observed_effect_text='x' WHERE event_id='selection_call'"))
rejects("C: a selection change with states", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='textSelectionChanged', observed_state_before='off', observed_state_after='on' WHERE event_id='selection_call'"))
db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, duration_ms=1, result_kind='acted_unverified', result_message='inserted', observed_effect_kind='textSelectionChanged' WHERE event_id='selection_call'")
rejects("C: a label under a selection change", lambda: insert("memory_agent_action_effect_labels", event_id="selection_call", position=0, label="x"))
ok("C: a selection change is an observed effect of its family alone (merge-memory)")
event("mcp_call", source="mcp")
ok("C: an external MCP client is an event source of its own (merge-memory)")
rejects("C: an unknown event source", lambda: event("bridge_call", source="bridge"))
# S3-d correction: the structured results of the listing and scene tools.
event("status_call", app=None)
insert("memory_agent_actions", event_id="status_call", app_id=None, tool_kind="status", execution_status="completed", completed_at_ms=1, result_kind="status")
insert("memory_agent_action_status", event_id="status_call", session_id=None, screen_recording=1, accessibility=0, post_event=1)
rejects("C: a status row for a call that is not status", lambda: insert("memory_agent_action_status", event_id="timed_call", screen_recording=1, accessibility=1, post_event=1))
event("windows_call", app=None)
insert("memory_agent_actions", event_id="windows_call", app_id=None, tool_kind="windows", execution_status="completed", completed_at_ms=1, result_kind="listing")
rejects("C: a listing of another kind than the tool", lambda: insert("memory_agent_action_listings", event_id="windows_call", listing_kind="apps"))
insert("memory_agent_action_listings", event_id="windows_call", listing_kind="windows", hidden_count=0)
insert("memory_agent_action_applications", event_id="windows_call", position=0, name="Mail", bundle_id="com.apple.mail", pid=404)
rejects("C: a windows row without its pid", lambda: insert("memory_agent_action_applications", event_id="windows_call", position=1, name="Notes", bundle_id="com.apple.Notes"))
rejects("C: a windows row carrying apps fields", lambda: insert("memory_agent_action_applications", event_id="windows_call", position=1, name="Notes", bundle_id="com.apple.Notes", pid=5, is_running=1))
rejects("C: a windows row carrying the default browser flag", lambda: insert("memory_agent_action_applications", event_id="windows_call", position=1, name="Safari", bundle_id="com.apple.Safari", pid=6, is_default_browser=1))
insert("memory_agent_action_windows", event_id="windows_call", application_position=0, position=0, window_number=77, title="Inbox")
insert("memory_agent_action_windows", event_id="windows_call", application_position=0, position=1, window_number=78, title=None)
assert [r for r in db.execute("SELECT window_number, title FROM memory_agent_action_windows WHERE event_id='windows_call' ORDER BY position")] == [(77, "Inbox"), (78, None)]
event("apps_call", app=None)
insert("memory_agent_actions", event_id="apps_call", app_id=None, tool_kind="apps", execution_status="completed", completed_at_ms=1, result_kind="listing")
insert("memory_agent_action_listings", event_id="apps_call", listing_kind="apps", hidden_count=3)
insert("memory_agent_action_applications", event_id="apps_call", position=0, name="Pro Tools", bundle_id="com.avid.ProTools", app_version="26.4", is_running=0, location="~/Applications")
rejects("C: an apps row carrying a pid", lambda: insert("memory_agent_action_applications", event_id="apps_call", position=1, name="X", bundle_id="x", pid=1, is_running=1))
rejects("C: an apps row without its running flag", lambda: insert("memory_agent_action_applications", event_id="apps_call", position=1, name="X", bundle_id="x"))
insert("memory_agent_action_applications", event_id="apps_call", position=1, name="Safari", bundle_id="com.apple.Safari", is_running=1, is_default_browser=1)
rejects("C: a default browser flag that is not a boolean", lambda: insert("memory_agent_action_applications", event_id="apps_call", position=2, name="Y", bundle_id="y", is_running=0, is_default_browser=2))
ok("C: an apps row says whether it is the default browser (merge-memory)")
rejects("C: a window under an apps listing", lambda: insert("memory_agent_action_windows", event_id="apps_call", application_position=0, position=0, window_number=1, title="x"))
rejects("C: a negative hidden count", lambda: insert("memory_agent_action_listings", event_id="timed_call", listing_kind="apps", hidden_count=-1))
ok("C: status, windows and apps keep typed rows in order, NULL apart from empty text, with the count left out (S3-d)")
event("observe_call", session_id="ephemeral-session")
insert("memory_agent_actions", event_id="observe_call", app_id=1, tool_kind="observe", execution_status="completed", completed_at_ms=1, result_kind="observation")
rejects("C: an observation result without its sample", lambda: insert("memory_agent_action_observations", event_id="observe_call", session_id="ephemeral-session", session_revision=1, observed_at_ms=1, sample_event_id="observe_call", sample_observation_id=999999))
current = capture("observe_call", phase="current", ordinal=0, status="complete", surface="window", window_title="Chat")
insert("memory_agent_action_observations", event_id="observe_call", session_id="ephemeral-session", session_revision=1, observed_at_ms=1, sample_event_id="observe_call", sample_observation_id=current)
rejects("C: an observation result for a call that is not observe or open_session", lambda: insert("memory_agent_action_observations", event_id="timed_call", session_id="s", session_revision=1, observed_at_ms=1, sample_event_id="observe_call", sample_observation_id=current))
ok("C: an observation result points to its real current sample (S3-d)")
# S3-d correction: the origin of a session's own observation is the call it was taken for.
event("opening_call", app=None, session_id=None)
insert("memory_agent_actions", event_id="opening_call", app_id=None, tool_kind="open_session", execution_status="completed", completed_at_ms=1)
event("opening_observation", kind="observation", session_id="opened", origin_event_id="opening_call")
assert db.execute("SELECT origin_event_id FROM memory_events WHERE event_id='opening_observation'").fetchone() == ("opening_call",)
rejects("C: an origin on an action", lambda: event("origin_action", origin_event_id="opening_call"))
rejects("C: an origin that is the event itself", lambda: event("origin_self", kind="observation", origin_event_id="origin_self"))
rejects("C: an origin the store does not hold", lambda: event("origin_missing", kind="observation", origin_event_id="nowhere"))
rejects("C: the origin is part of the event's identity", lambda: db.execute("UPDATE memory_events SET origin_event_id=NULL WHERE event_id='opening_observation'"))
ok("C: a session's own observation keeps the call it was taken for (S3-d)")
rejects("C: step with app A and operation with app NULL", lambda: insert("memory_step_operations", operation_id="x", route_id="route1", step_id="step1", position=5, tool_kind="act"))
rejects("C: step with app A and operation with app B", lambda: insert("memory_step_operations", operation_id="x", route_id="route1", step_id="step1", app_id=2, position=5, tool_kind="act"))
rejects("C: step with app A and check with app NULL", lambda: insert("memory_step_checks", check_id="x", route_id="route1", step_id="step1", position=5, check_kind="text", expected_text="x"))
insert("memory_route_steps", step_id="step_global", route_id="route1", position=2, step_kind="goal", goal_text="Senza app")
insert("memory_step_operations", operation_id="op_global", route_id="route1", step_id="step_global", position=0, tool_kind="status")
ok("C: a step without app and its operation without app are accepted")
rejects("C: operation claiming an app under a step without app", lambda: insert("memory_step_operations", operation_id="x", route_id="route1", step_id="step_global", app_id=1, position=1, tool_kind="act"))
rejects("C: argument omitting app_id under an app operation", lambda: insert("memory_operation_arguments", operation_id="op1", route_id="route1", argument_name="omit", value_kind="text", text_value="x"))
rejects("C: argument omitting app_id under an app action", lambda: insert("memory_operation_arguments", event_id="tool_act", argument_name="omit", value_kind="text", text_value="x"))
rejects("C: argument claiming an app under a global action", lambda: insert("memory_operation_arguments", event_id="global_call", app_id=1, argument_name="omit", value_kind="text", text_value="x"))
rejects("C: step app is immutable", lambda: db.execute("UPDATE memory_route_steps SET app_id=2 WHERE step_id='step1'"))
db.execute("UPDATE memory_route_steps SET goal_text='Messaggio visibile' WHERE step_id='step1'")
ok("C: a step's goal text may still be edited in a draft")

insert("memory_step_occurrences", step_occurrence_id="occurrence_b", task_occurrence_id="task", step_id="step1", started_at_ms=5, status="observed")
event("verify_a", kind="verification")
insert("memory_verifications", event_id="verify_a", step_occurrence_id="occurrence", scope="step", method="scene", verdict="passed")
rejects("C: verification of A added as verification membership of B", lambda: insert("memory_step_events", step_occurrence_id="occurrence_b", event_id="verify_a", position=9, role="verification"))
insert("memory_step_events", step_occurrence_id="occurrence", event_id="verify_a", position=1, role="verification")
rejects("C: reverse order, verification re-attributed to B while membership says A", lambda: db.execute("UPDATE memory_verifications SET step_occurrence_id='occurrence_b' WHERE event_id='verify_a'"))
rejects("C: an action event cannot play the verification role", lambda: insert("memory_step_events", step_occurrence_id="occurrence", event_id="tool_act", position=9, role="verification"))
event("verify_none", kind="verification")
rejects("C: an unattributed verification cannot be a verification member", lambda: insert("memory_step_events", step_occurrence_id="occurrence", event_id="verify_none", position=9, role="verification"))
insert("memory_step_events", step_occurrence_id="occurrence", event_id="tool_act", position=2, role="action")
ok("C: verification attribution is single and consistent in both write orders")
rejects("C: unknown verdict", lambda: insert("memory_verifications", event_id="verify_none", scope="step", method="scene", verdict="maybe"))
event("cli_act", source="cli")
insert("memory_action_correlations", watcher_event_id="watch1", agent_event_id="cli_act", basis_kind="time")
ok("C: a watcher input correlated with a cli action is accepted")
rejects("C: two agent events are not a Watcher correlation", lambda: insert("memory_action_correlations", watcher_event_id="tool_observe", agent_event_id="tool_act", basis_kind="time"))
event("sys_obs", source="system", kind="observation")
rejects("C: a system observation is not a watcher input", lambda: insert("memory_action_correlations", watcher_event_id="sys_obs", agent_event_id="tool_act", basis_kind="time"))
rejects("C: a watcher input cannot be correlated with a verification", lambda: insert("memory_action_correlations", watcher_event_id="watch0", agent_event_id="verify_a", basis_kind="time"))
rejects("C: direct Route recursion A->A", lambda: insert("memory_route_steps", step_id="x", route_id="route1", position=9, step_kind="route_call", goal_text="x", called_route_id="route1"))
rejects("C: indirect Route recursion A->B->A", lambda: insert("memory_route_steps", step_id="x", route_id="route2", position=9, step_kind="route_call", goal_text="x", called_route_id="route1"))
insert("memory_routes", route_id="route3", name="Terza", status="draft", created_at_ms=0)
insert("memory_route_steps", step_id="step3", route_id="route3", position=0, step_kind="route_call", goal_text="Chiama la seconda", called_route_id="route2")
rejects("C: indirect Route recursion through three Routes", lambda: insert("memory_route_steps", step_id="x", route_id="route2", position=9, step_kind="route_call", goal_text="x", called_route_id="route3"))
ok("C: a non-recursive call chain is accepted")
insert("memory_step_operations", operation_id="op1_child", route_id="route1", step_id="step1", app_id=1, parent_operation_id="op1", position=0, tool_kind="act")
rejects("C: operation parent cycle A->B->A", lambda: db.execute("UPDATE memory_step_operations SET parent_operation_id='op1_child' WHERE operation_id='op1'"))
rejects("C: unknown capture_status", lambda: event("x", capture_status="weird") if False else db.execute("INSERT INTO memory_events(event_id,source,source_stream_id,event_kind,occurred_at_ms,capture_status) VALUES ('x','app','s','action',1,'weird')"))
rejects("C: unknown task status", lambda: insert("memory_task_occurrences", task_occurrence_id="x", started_at_ms=0, status="weird"))
rejects("C: unknown step occurrence status", lambda: insert("memory_step_occurrences", step_occurrence_id="x", started_at_ms=0, status="done"))
rejects("C: unknown Route status", lambda: insert("memory_routes", route_id="x", name="x", status="published", created_at_ms=0))
rejects("C: unknown label status", lambda: insert("memory_task_labels", label_id="x", task_occurrence_id="task", label="x", assigned_by="t", status="maybe", assigned_at_ms=0))
rejects("C: unknown Route evidence relation", lambda: insert("memory_route_evidence", route_id="route1", task_occurrence_id="task", relation="refutes", assessed_by="t", assessed_at_ms=0))
rejects("C: unknown step evidence relation", lambda: insert("memory_step_evidence", step_id="step1", step_occurrence_id="occurrence", relation="refutes", assessed_by="t", assessed_at_ms=0))
rejects("C: unknown membership role", lambda: insert("memory_step_events", step_occurrence_id="occurrence", event_id="watch1", position=9, role="helper"))
rejects("C: unknown task membership role", lambda: insert("memory_task_events", task_occurrence_id="task", event_id="watch1", position=9, role="helper"))
rejects("C: unknown Experience use verdict", lambda: insert("memory_experience_uses", experience_id="experience_literal", event_id="tool_act", verdict="ok"))
rejects("C: unknown observation phase", lambda: insert("memory_event_observations", event_id="tool_act", phase="during", observation_kind="element", status="observed"))

# ================================================================== D. samples with quality
event("act_click")
insert("memory_agent_actions", event_id="act_click", app_id=1, tool_kind="act", execution_status="completed")
before = capture("act_click", phase="before", ordinal=0, status="complete", surface="window", window_title="Chat", session_revision=7)
after = capture("act_click", phase="after", ordinal=0, status="partial", surface="window", window_title="Chat", session_revision=8)
menu = capture("act_click", phase="menu", ordinal=0, status="complete", surface="popup_union")
for name, value in (("walk_completed", 1), ("nodes_visited", 120), ("elements_emitted", 33)):
    insert("memory_event_observations", event_id="act_click", phase="before", observation_kind="capture_field",
           field_name=name, integer_value=value, status="observed", parent_observation_id=before)
insert("memory_event_observations", event_id="act_click", phase="before", observation_kind="capture_field",
       field_name="stopped_by", text_value="deadline", status="observed", parent_observation_id=after)
insert("memory_event_observations", event_id="act_click", phase="before", observation_kind="element",
       status="observed", label="Invia", role="AXButton", label_origin="title", container_path="Composer",
       parent_observation_id=before)
ok("D: a sample is a typed capture row with quality fields and element children")
rejects("D: two captures for one (event, phase, ordinal)", lambda: capture("act_click", phase="before", ordinal=0))
second = capture("act_click", phase="after", ordinal=1, status="complete")
ok("D: a second real capture in the same phase takes the next ordinal")
rejects("D: capture with a non-quality status", lambda: capture("act_click", phase="current", ordinal=0, status="observed"))
rejects("D: capture nested under another observation", lambda: insert("memory_event_observations", event_id="act_click", phase="before", sample_ordinal=3, observation_kind="capture", status="complete", parent_observation_id=before))
rejects("D: unknown label_origin", lambda: insert("memory_event_observations", event_id="act_click", phase="before", observation_kind="element", status="observed", label_origin="guess", parent_observation_id=before))
insert("memory_event_observations", event_id="act_click", phase="before", observation_kind="element",
       status="observed", label="notes-editor", role="AXTextArea", label_origin="identifier", parent_observation_id=before)
ok("D: a label read from the accessibility identifier keeps that origin (merge-memory)")
rejects("D: unknown surface_kind", lambda: capture("act_click", phase="current", ordinal=0, surface="menu"))
rejects("D: association without its capture sample", lambda: insert("memory_event_scenes", event_id="act_click", app_id=1, phase="current", scene_id="scene1", match_status="candidate", matched_by="structure", matcher_version="v2"))
rejects("D: a partial capture cannot confirm a scene", lambda: insert("memory_event_scenes", event_id="act_click", app_id=1, phase="after", sample_ordinal=0, scene_id="scene1", match_status="confirmed", matched_by="structure", matcher_version="v2"))
insert("memory_event_scenes", event_id="act_click", app_id=1, phase="after", sample_ordinal=0, scene_id="scene1", match_status="candidate", matched_by="structure", matcher_version="v2")
insert("memory_event_scenes", event_id="act_click", app_id=1, phase="after", sample_ordinal=0, scene_id="other_scene1", match_status="candidate", matched_by="structure", matcher_version="v2")
ok("D: a partial capture keeps several candidates and confirms none")
rejects("D: promoting a candidate on a partial capture", lambda: db.execute("UPDATE memory_event_scenes SET match_status='confirmed' WHERE event_id='act_click' AND phase='after' AND sample_ordinal=0 AND scene_id='scene1'"))
insert("memory_event_scenes", event_id="act_click", app_id=1, phase="before", sample_ordinal=0, scene_id="scene1", match_status="confirmed", matched_by="structure", matcher_version="v2")
insert("memory_event_scenes", event_id="act_click", app_id=1, phase="after", sample_ordinal=1, scene_id="scene1", match_status="confirmed", matched_by="structure", matcher_version="v2")
ok("D: complete samples confirm at most one scene each; ordinals are distinct samples")
rejects("D: second confirmed scene for the same sample", lambda: insert("memory_event_scenes", event_id="act_click", app_id=1, phase="before", sample_ordinal=0, scene_id="other_scene1", match_status="confirmed", matched_by="structure", matcher_version="v2"))
rejects("D: a confirmed sample cannot be downgraded to partial", lambda: db.execute("UPDATE memory_event_observations SET status='partial' WHERE observation_id=?", (before,)))
rejects("D: a confirmed sample cannot change identity", lambda: db.execute("UPDATE memory_event_observations SET sample_ordinal=5 WHERE observation_id=?", (before,)))
db.execute("UPDATE memory_event_observations SET status='complete' WHERE observation_id=?", (after,))
ok("D: an unconfirmed sample may be corrected")
rejects("D: unknown element scope", lambda: insert("brain_scene_elements", scene_element_id="x", app_id=1, scene_id="scene1", element_key="x", element_scope="panel", first_seen_ms=0, last_seen_ms=0))
insert("brain_scene_roles", scene_id="scene1", role="AXButton")
ok("D: a role may be recorded as presence only (count_bucket NULL)")

# ---- signature round trip: container tree, controls with caption origin, collection, template
insert("brain_scenes", scene_id="sig", app_id=2, title_bucket="Settings", scene_kind="dialog", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="c_root", app_id=2, scene_id="sig", element_key="General", element_scope="container", role="AXGroup", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="c_sub", app_id=2, scene_id="sig", element_key="General / Privacy", element_scope="container", parent_element_id="c_root", role="AXGroup", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="b_ok", app_id=2, scene_id="sig", element_key="AXButton|ok", element_scope="control", parent_element_id="c_root", role="AXButton", label="OK", label_origin="title", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="cb_track", app_id=2, scene_id="sig", element_key="AXCheckBox|track", element_scope="control", parent_element_id="c_sub", role="AXCheckBox", label="Track", label_origin="description", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="f_name", app_id=2, scene_id="sig", element_key="AXTextField|@0", element_scope="control", parent_element_id="c_sub", role="AXTextField", label="Mario", label_origin="value", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="coll", app_id=2, scene_id="sig", element_key="General / People", element_scope="collection", parent_element_id="c_root", role="AXTable", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="tpl", app_id=2, scene_id="sig", element_key="AXRow", element_scope="item_template", parent_element_id="coll", role="AXRow", first_seen_ms=0, last_seen_ms=0)


def skeleton(scene_id):
    rows = db.execute("SELECT scene_element_id, parent_element_id, element_scope, role, label, label_origin, element_key "
                      "FROM brain_scene_elements WHERE scene_id=?", (scene_id,)).fetchall()
    by_id = {r[0]: r for r in rows}

    def path(eid):
        chain = []
        while eid is not None:
            r = by_id[eid]
            if r[2] == "container": chain.append(r[6])
            eid = r[1]
        return " / ".join(reversed(chain)) or "<root>"
    roles, captions, collections = {}, {}, set()
    for r in rows:
        if r[2] == "container": continue
        p = path(r[1])
        if r[2] == "collection": collections.add(p); continue
        if r[2] == "item_template": continue
        roles.setdefault(p, set()).add(r[3])
        if r[5] in ("title", "description"): captions.setdefault(p, set()).add((r[3], (r[4] or "").lower()))
    kind, bucket = db.execute("SELECT scene_kind, title_bucket FROM brain_scenes WHERE scene_id=?", (scene_id,)).fetchone()
    # The title bucket is a search hint for people and ordering, never part of the identity (a dialog
    # titled after a file must not become one scene per file).
    return {"surface": kind, "title_hint": bucket,
            "roles": roles, "captions": captions, "collections": collections}


# A nested container's element_key is its own segment; the path is rebuilt from the parent chain.
db.execute("UPDATE brain_scene_elements SET element_key='Privacy' WHERE scene_element_id='c_sub'")
expected = {"surface": "dialog", "title_hint": "Settings",
            "roles": {"General": {"AXButton"}, "General / Privacy": {"AXCheckBox", "AXTextField"}},
            "captions": {"General": {("AXButton", "ok")}, "General / Privacy": {("AXCheckBox", "track")}},
            "collections": {"General"}}
assert skeleton("sig") == expected, skeleton("sig")
ok("D: structure-v2 skeleton (surface, role sets and captions per path, collections; title only a hint) rebuilds from SQL; a value-origin label is not a caption")

# ================================================================== E. brain applications (S2 3a)
def application_argument(app_id, name, position=0, app=1, **value):
    kind, column = next((k, c) for k, c in (("text", "text_value"), ("integer", "integer_value"), ("real", "real_value"), ("boolean", "boolean_value")) if c in value)
    insert("memory_operation_arguments", brain_application_id=app_id, app_id=app, argument_name=name, position=position,
           value_kind=kind, **{column: value[column]})


def application(app_id, event_id, operation="observe", app=1, outcome=None, **extra):
    row = dict(application_id=app_id, app_id=app, event_id=event_id, operation=operation, contract_version=1,
               algorithm_version="brain-updater-1", requested_at_ms=100, effective_at_ms=100)
    if operation == "observe":
        row.update(outcome=outcome or "observed", created_count=0, updated_count=0, skipped_ambiguous_count=0)
    elif operation == "record":
        row.update(outcome=outcome or "no_effect")
    else:
        row.update(outcome=outcome or "not_named")
    row.update(extra)
    insert("brain_applications", **{k: v for k, v in row.items() if v is not None})


act_before = db.execute("SELECT observation_id FROM memory_event_observations WHERE event_id='act_click' AND phase='before' AND sample_ordinal=0 AND observation_kind='capture'").fetchone()[0]
act_after1 = db.execute("SELECT observation_id FROM memory_event_observations WHERE event_id='act_click' AND phase='after' AND sample_ordinal=1 AND observation_kind='capture'").fetchone()[0]
insert("memory_event_observations", event_id="act_click", phase="before", sample_ordinal=0, observation_kind="capture_field",
       field_name="window_role", text_value="AXWindow", status="observed", parent_observation_id=act_before)
act_field = db.execute("SELECT last_insert_rowid()").fetchone()[0]
sample = dict(phase="before", sample_ordinal=0, sample_observation_id=act_before, sample_kind="capture")
application_argument(1, "detection_count", integer_value=0)
application(1, "act_click", **sample)
application_argument(2, "detection_count", integer_value=0)
application(2, "act_click", phase="after", sample_ordinal=1, sample_observation_id=act_after1, sample_kind="capture")
application_argument(3, "verb", text_value="click")
application(3, "tool_act", operation="record")
application_argument(4, "anchor_key", text_value="no-such-anchor")
application_argument(4, "name", text_value="")
application(4, "tool_act", operation="set_name")
assert db.execute("SELECT count(*) FROM brain_applications").fetchone()[0] == 4
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("E: observations of two samples of one event, a record and a failed naming of a literal key are four concluded applications")
rejects("E: the same observation key twice", lambda: (application_argument(9, "detection_count", integer_value=0), application(9, "act_click", **sample)))
rejects("E: the same record key twice, NULL phase and ordinal do not bypass the key", lambda: (application_argument(9, "verb", text_value="click"), application(9, "tool_act", operation="record")))
rejects("E: the same naming key twice", lambda: (application_argument(9, "name", text_value="x"), application(9, "tool_act", operation="set_name")))
rejects("E: an application without its arguments", lambda: application(9, "act_click", phase="after", sample_ordinal=0, sample_observation_id=after, sample_kind="capture"))
rejects("E: an observation's sample must be the capture row of its event, phase and ordinal (a field row)", lambda: (application_argument(9, "detection_count", integer_value=0), application(9, "act_click", phase="before", sample_ordinal=0, sample_observation_id=act_field, sample_kind="capture")))
rejects("E: an observation's sample of another phase", lambda: (application_argument(9, "detection_count", integer_value=0), application(9, "act_click", phase="current", sample_ordinal=0, sample_observation_id=act_before, sample_kind="capture")))
rejects("E: an observation's sample of another event", lambda: (application_argument(9, "detection_count", integer_value=0), application(9, "tool_act", phase="before", sample_ordinal=0, sample_observation_id=act_before, sample_kind="capture")))
rejects("E: an observation without its sample", lambda: (application_argument(9, "detection_count", integer_value=0), application(9, "act_click")))
rejects("E: a record with a phase", lambda: (application_argument(9, "verb", text_value="click"), application(9, "act_click", operation="record", phase="after")))
rejects("E: an application of another application's event", lambda: (application_argument(9, "verb", text_value="click", app=2), application(9, "tool_act", operation="record", app=2)))
rejects("E: a record of an event that is not an action", lambda: (application_argument(9, "verb", text_value="click"), application(9, "watch1", operation="record")))
rejects("E: an operation's outcome must be one of its own", lambda: (application_argument(9, "verb", text_value="click"), application(9, "cli_act", operation="record", outcome="named", anchor_id="anchor1_return")))
rejects("E: a recorded outcome needs its transition and evidence", lambda: (application_argument(9, "verb", text_value="click"), application(9, "cli_act", operation="record", outcome="recorded", anchor_id="anchor1_return")))
rejects("E: an outcome without counts carries none", lambda: (application_argument(9, "verb", text_value="click"), application(9, "cli_act", operation="record", created_count=1)))
rejects("E: an effective instant earlier than the requested one", lambda: (application_argument(9, "verb", text_value="click"), application(9, "cli_act", operation="record", effective_at_ms=99)))
rejects("E: an unknown operation", lambda: (application_argument(9, "verb", text_value="click"), application(9, "cli_act", operation="forget")))
rejects("E: a concluded application is immutable", lambda: db.execute("UPDATE brain_applications SET effective_at_ms = 500 WHERE application_id = 3"))
rejects("E: a concluded application is kept", lambda: db.execute("DELETE FROM brain_applications WHERE application_id = 3"))
rejects("E: a concluded application's input is sealed", lambda: application_argument(3, "target_kind", text_value="control"))
rejects("E: an application's input is immutable", lambda: db.execute("UPDATE memory_operation_arguments SET text_value = 'double_click' WHERE brain_application_id = 3"))
rejects("E: an application's input is kept", lambda: db.execute("DELETE FROM memory_operation_arguments WHERE brain_application_id = 3"))
rejects("E: an argument with an application and an action as owners", lambda: insert("memory_operation_arguments", brain_application_id=3, event_id="tool_act", app_id=1, argument_name="x", value_kind="text", text_value="x"))
rejects("E: an application's argument names no Route", lambda: insert("memory_operation_arguments", brain_application_id=3, route_id="route1", app_id=1, argument_name="x", value_kind="text", text_value="x"))
rejects("E: an application's argument is a plain value, never an anchor reference", lambda: insert("memory_operation_arguments", brain_application_id=3, app_id=1, argument_name="x", value_kind="anchor", anchor_id="anchor1_return"))
rejects("E: an application's argument names its app", lambda: insert("memory_operation_arguments", brain_application_id=3, argument_name="x", value_kind="text", text_value="x"))
rejects("E: a sample an application references keeps its identity", lambda: db.execute("UPDATE memory_event_observations SET phase = 'current' WHERE observation_id = ?", (act_after1,)))
rejects("E: a sample an application references cannot be deleted", lambda: db.execute("DELETE FROM memory_event_observations WHERE observation_id = ?", (act_after1,)))
db.execute("SAVEPOINT deferred_case")
application_argument(77, "verb", text_value="click")
orphans = db.execute("PRAGMA foreign_key_check(memory_operation_arguments)").fetchall()
db.execute("ROLLBACK TO deferred_case")
db.execute("RELEASE deferred_case")
assert len(orphans) == 1 and orphans[0][2] == "brain_applications", orphans
ok("E: an argument whose application never arrives breaks the deferred key to brain_applications")
db.execute("SAVEPOINT deferred_case")
application_argument(78, "verb", text_value="click", app=2)
insert("brain_applications", application_id=78, app_id=1, event_id="cli_act", operation="record", contract_version=1, algorithm_version="v", requested_at_ms=1, effective_at_ms=1, outcome="no_effect")
cross = db.execute("PRAGMA foreign_key_check(memory_operation_arguments)").fetchall()
db.execute("ROLLBACK TO deferred_case")
db.execute("RELEASE deferred_case")
assert len(cross) == 1, cross
ok("E: an argument of another application's app breaks the composite key to its application")
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
assert db.execute("SELECT count(*) FROM memory_operation_arguments WHERE brain_application_id IS NOT NULL").fetchone()[0] == 5

# ================================================================== integrity, file reopen
tables = db.execute("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'").fetchall()
assert len(tables) == 48, len(tables)
triggers = db.execute("SELECT count(*) FROM sqlite_schema WHERE type='trigger'").fetchone()[0]
indexes = db.execute("SELECT count(*) FROM sqlite_schema WHERE type='index' AND sql IS NOT NULL").fetchone()[0]
for (name,) in tables:
    db.execute(f"EXPLAIN DELETE FROM {name} WHERE 0")
    assert all("json" not in column[1].lower() for column in db.execute(f"PRAGMA table_info({name})"))
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
assert db.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
ok(f"48 tables, {triggers} triggers, {indexes} explicit indexes, all foreign keys prepared, no JSON columns, integrity checks")

db.commit()
with tempfile.TemporaryDirectory(prefix="mecum-ddl-v5-") as folder:
    path = Path(folder) / "memory.sqlite"
    with sqlite3.connect(path) as saved:
        db.backup(saved)
    with sqlite3.connect(path) as reopened:
        reopened.execute("PRAGMA foreign_keys=ON")
        assert reopened.execute("PRAGMA foreign_keys").fetchone()[0] == 1
        assert reopened.execute("SELECT epoch FROM brain_app_window_epochs WHERE app_id=1 AND window_family='Chat'").fetchone()[0] == 4
        assert reopened.execute("SELECT retired_epoch,retirement_cause FROM brain_anchors WHERE anchor_id='anchor1'").fetchone() == (4, "stale")
        assert reopened.execute("SELECT count(*) FROM brain_evidence WHERE anchor_id='anchor1'").fetchone()[0] == 1
        assert [r[0] for r in reopened.execute("SELECT alias FROM brain_anchor_aliases WHERE anchor_id='anchor1_return' ORDER BY position")] == ["Send", "Invia ora"]
        assert [r[0] for r in reopened.execute("SELECT anchor_id FROM brain_anchors WHERE app_id=1 AND retired_at_ms IS NULL ORDER BY insertion_order")] == ["anchor1_return", "a2", "a3"]
        assert reopened.execute("SELECT count(*) FROM brain_scenes WHERE scene_kind='app'").fetchone()[0] == 1
        assert reopened.execute("SELECT count(*) FROM sqlite_schema WHERE type='trigger'").fetchone()[0] == triggers
        assert reopened.execute("PRAGMA foreign_key_check").fetchall() == []
        # journal mode is a property of the file: set once at bootstrap, verified on reopen (piano 1).
        assert reopened.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    with sqlite3.connect(path) as again:
        assert again.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
ok("orders, app scope, triggers, retired identities and evidence persist after file reopen; WAL persists in the file")

rejected = sum(1 for p in passed if p.startswith("rejects: "))
print(f"PASS: {len(passed)} DDL checks ({rejected} negative) on SQLite {LIB[0]} [{LIB[1]}] via Python {sys.version.split()[0]} sqlite3 module {sqlite3.sqlite_version}")
print("48 tables; triggers:", triggers, "; explicit indexes:", indexes)
for p in passed:
    print(" -", p)
