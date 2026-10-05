//
//  SQLiteBrainRows.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import Foundation
import Memory
import PerceptionCore

/// SQLiteBrainRows is the codec between a `UIBrain` and the rows of its stored projection:
/// `brain_apps` and `brain_app_window_epochs` for the clock, `brain_anchors` with aliases and
/// states, `brain_groups` with members, `brain_transitions` with menu items under the
/// application's scope. `load` rebuilds the active projection (rows with `retired_at_ms` NULL, in
/// `insertion_order`; aliases, members and items in `position`) and refuses every row whose code,
/// shape or number this build cannot read back as the fact that was written. `write` stores the
/// difference between the loaded brain and the brain the pure algorithm produced: new rows take
/// the next `insertion_order` after every row the application ever had, retired or not; changed
/// rows are rewritten; rows the algorithm dropped are retired with the algorithm's own cause, never
/// deleted; nothing outside the projection is touched. Always inside the caller's transaction.
enum SQLiteBrainRows {

    /// Loaded is the active projection with the facts the diff needs beside it: the row id of each
    /// active transition, the next free orders, and the application's scope when it exists.
    struct Loaded {
        var brain: UIBrain
        var transitionIDs: [LearnedTransition.Key: String]
        var nextAnchorOrder: Int64
        var nextGroupOrder: Int64
        var nextTransitionOrder: Int64
        var appScopeID: String?
    }

    /// Positions are shifted here while a list is rewritten, so no final position collides with a
    /// surviving one under the list's UNIQUE constraint.
    private static let repositionOffset: Int64 = 1 << 32

    // MARK: Reading

    static func load(_ handle: some SQLiteQuerying, appID: Int64) throws -> Loaded {
        let clock = try handle.query(
            "SELECT ingest_epoch, last_epoch_advance_ms FROM brain_apps WHERE app_id = ?", [.integer(appID)]
        ) { row in (epoch: Int(row.integer(0) ?? 0), advance: try optionalDate(row.integer(1))) }.first
        guard let clock else {
            throw BrainProjectionError.malformedRow(table: "brain_apps", id: String(appID), malformation: .missingColumn("app_id"))
        }
        let windowEpochs = Dictionary(
            uniqueKeysWithValues: try handle.query(
                "SELECT window_family, epoch FROM brain_app_window_epochs WHERE app_id = ?", [.integer(appID)]
            ) { row in (try row.text(0) ?? "", Int(row.integer(1) ?? 0)) }
        )
        var anchors = try anchorRows(handle, appID: appID)
        let aliases = try handle.query(
            """
            SELECT al.anchor_id, al.alias FROM brain_anchor_aliases al
            JOIN brain_anchors a ON a.anchor_id = al.anchor_id
            WHERE a.app_id = ? AND a.retired_at_ms IS NULL
            ORDER BY al.anchor_id, al.position
            """,
            [.integer(appID)]
        ) { row in (try row.text(0) ?? "", try row.text(1) ?? "") }
        let states = try handle.query(
            """
            SELECT s.anchor_id, s.state, s.seen_count FROM brain_anchor_states s
            JOIN brain_anchors a ON a.anchor_id = s.anchor_id
            WHERE a.app_id = ? AND a.retired_at_ms IS NULL
            """,
            [.integer(appID)]
        ) { row in (try row.text(0) ?? "", try row.text(1) ?? "", Int(row.integer(2) ?? 0)) }
        var indexByKey: [String: Int] = [:]
        for (index, anchor) in anchors.enumerated() { indexByKey[anchor.anchorKey] = index }
        for (anchorID, alias) in aliases {
            if let index = indexByKey[anchorID] { anchors[index].aliases.append(alias) }
        }
        for (anchorID, state, count) in states {
            if let index = indexByKey[anchorID] { anchors[index].statesSeen[state] = count }
        }

        var groups = try groupRows(handle, appID: appID)
        var groupIndexByID: [UUID: Int] = [:]
        for (index, group) in groups.enumerated() { groupIndexByID[group.id] = index }
        // Memberships of active groups toward active anchors: the projection the algorithm left.
        let members = try handle.query(
            """
            SELECT m.group_id, m.anchor_id FROM brain_group_members m
            JOIN brain_groups g ON g.group_id = m.group_id
            JOIN brain_anchors a ON a.anchor_id = m.anchor_id
            WHERE g.app_id = ? AND g.retired_at_ms IS NULL AND a.retired_at_ms IS NULL
            ORDER BY m.group_id, m.position
            """,
            [.integer(appID)]
        ) { row in (try row.text(0) ?? "", try row.text(1) ?? "") }
        for (groupText, anchorID) in members {
            guard let id = UUID(uuidString: groupText), let index = groupIndexByID[id] else { continue }
            groups[index].memberAnchors.append(anchorID)
        }

        let appScopeID = try handle.query(
            "SELECT scene_id FROM brain_scenes WHERE app_id = ? AND scene_kind = 'app'", [.integer(appID)]
        ) { try $0.text(0) ?? "" }.first
        let (transitions, transitionIDs) = try transitionRows(handle, appID: appID, appScopeID: appScopeID)

        return Loaded(
            brain: UIBrain(
                objects         : anchors,
                groups          : groups,
                transitions     : transitions,
                ingestEpoch     : clock.epoch,
                lastEpochAdvance: clock.advance,
                windowEpochs    : windowEpochs
            ),
            transitionIDs      : transitionIDs,
            nextAnchorOrder    : try nextOrder(handle, table: "brain_anchors", appID: appID),
            nextGroupOrder     : try nextOrder(handle, table: "brain_groups", appID: appID),
            nextTransitionOrder: try nextOrder(handle, table: "brain_transitions", appID: appID),
            appScopeID         : appScopeID
        )
    }

    private static func anchorRows(_ handle: some SQLiteQuerying, appID: Int64) throws -> [ObjectAnchor] {
        try handle.query(
            """
            SELECT anchor_id, kind, label, label_source, anchor_scope, typical_x, typical_y, typical_width, typical_height,
                   window_family, first_seen_ms, last_seen_ms, seen_count, last_seen_epoch, current_group_id
            FROM brain_anchors WHERE app_id = ? AND retired_at_ms IS NULL ORDER BY insertion_order
            """,
            [.integer(appID)]
        ) { row in
            let id = try row.text(0) ?? ""
            let kindCode = try row.text(1) ?? ""
            guard let kind = ElementKind(rawValue: kindCode) else { throw BrainProjectionError.unknownElementKind(kindCode) }
            var source: LabelSource?
            if let code = try row.text(3) {
                guard let known = LabelSource(rawValue: code) else { throw BrainProjectionError.unknownLabelSource(code) }
                source = known
            }
            let scope = try row.text(4) ?? ""
            guard scope == "control" else { throw BrainProjectionError.unknownAnchorScope(scope) }
            let bounds = try rect(
                row, from: 5, table: "brain_anchors", id: id,
                columns: ["typical_x", "typical_y", "typical_width", "typical_height"]
            )
            var groupID: UUID?
            if let text = try row.text(14) {
                guard let uuid = UUID(uuidString: text) else {
                    throw BrainProjectionError.malformedRow(table: "brain_anchors", id: id, malformation: .notAUUID("current_group_id"))
                }
                groupID = uuid
            }
            return ObjectAnchor(
                anchorKey    : id,
                kind         : kind,
                label        : try row.text(2) ?? "",
                labelSource  : source,
                aliases      : [],
                boundsTypical: bounds,
                statesSeen   : [:],
                groupID      : groupID,
                seenCount    : Int(row.integer(12) ?? 0),
                firstSeen    : try date(row.integer(10) ?? 0),
                lastSeen     : try date(row.integer(11) ?? 0),
                lastSeenEpoch: row.integer(13).map(Int.init),
                window       : try row.text(9)
            )
        }
    }

    private static func groupRows(_ handle: some SQLiteQuerying, appID: Int64) throws -> [SiblingGroup] {
        try handle.query(
            """
            SELECT group_id, axis, shared_kind, cell_width, cell_height, name, last_seen_ms, seen_count, last_seen_epoch
            FROM brain_groups WHERE app_id = ? AND retired_at_ms IS NULL ORDER BY insertion_order
            """,
            [.integer(appID)]
        ) { row in
            let text = try row.text(0) ?? ""
            guard let id = UUID(uuidString: text) else {
                throw BrainProjectionError.malformedRow(table: "brain_groups", id: text, malformation: .notAUUID("group_id"))
            }
            let axisCode = try row.text(1) ?? ""
            guard let axis = GroupAxis(rawValue: axisCode) else { throw BrainProjectionError.unknownGroupAxis(axisCode) }
            let kindCode = try row.text(2) ?? ""
            guard let kind = ElementKind(rawValue: kindCode) else { throw BrainProjectionError.unknownElementKind(kindCode) }
            let width  = try real(row, 3, table: "brain_groups", id: text, column: "cell_width")
            let height = try real(row, 4, table: "brain_groups", id: text, column: "cell_height")
            return SiblingGroup(
                id           : id,
                axis         : axis,
                memberAnchors: [],
                sharedKind   : kind,
                cellSize     : NormalizedSize(width: width, height: height),
                name         : try row.text(5),
                seenCount    : Int(row.integer(7) ?? 0),
                lastSeen     : try date(row.integer(6) ?? 0),
                lastSeenEpoch: row.integer(8).map(Int.init)
            )
        }
    }

    private static func transitionRows(
        _ handle  : some SQLiteQuerying,
        appID     : Int64,
        appScopeID: String?
    ) throws -> ([LearnedTransition], [LearnedTransition.Key: String]) {
        // The projection owns the transitions `LearnedTransition` represents: from the application's
        // scope, triggered by no scene element and no menu command. Every other transition is a
        // general arc of the brain's graph (`SQLiteBrainGraphRepository`), read and validated by its
        // own contract, never by this one, and never touched by the projection's difference. A row
        // the projection owns is still refused whole when it breaks this contract.
        guard let appScopeID else { return ([], [:]) }
        let owned = "t.app_id = ? AND t.retired_at_ms IS NULL AND t.from_scene_id = ? AND t.scene_element_id IS NULL AND t.menu_command_id IS NULL"
        let items = try handle.query(
            """
            SELECT i.transition_id, i.position, i.title FROM brain_transition_menu_items i
            JOIN brain_transitions t ON t.transition_id = i.transition_id
            WHERE \(owned)
            ORDER BY i.transition_id, i.position
            """,
            [.integer(appID), .text(appScopeID)]
        ) { row in (id: try row.text(0) ?? "", position: row.integer(1) ?? -1, title: try row.text(2) ?? "") }
        var itemsByID: [String: [String]] = [:]
        for item in items {
            let count = itemsByID[item.id, default: []].count
            guard item.position == Int64(count) else {
                throw BrainProjectionError.malformedRow(table: "brain_transitions", id: item.id, malformation: .itemPositionsNotContiguous)
            }
            itemsByID[item.id, default: []].append(item.title)
        }
        var ids: [LearnedTransition.Key: String] = [:]
        let transitions = try handle.query(
            """
            SELECT transition_id, from_scene_id, anchor_id, scene_element_id, menu_command_id, trigger_kind, effect_kind,
                   effect_text, required_target_state, resulting_target_state, last_observed_epoch, status,
                   last_seen_ms, evidence_count
            FROM brain_transitions t WHERE \(owned) ORDER BY insertion_order
            """,
            [.integer(appID), .text(appScopeID)]
        ) { row in
            let id = try row.text(0) ?? ""
            guard let anchorKey = try row.text(2) else {
                throw BrainProjectionError.malformedRow(table: "brain_transitions", id: id, malformation: .missingColumn("anchor_id"))
            }
            let triggerCode = try row.text(5) ?? ""
            guard let trigger = TransitionTrigger(rawValue: triggerCode) else { throw BrainProjectionError.unknownTrigger(triggerCode) }
            let effect = try TransitionEffectRecord(
                kind          : try row.text(6) ?? "",
                text          : try row.text(7),
                requiredState : try row.text(8),
                resultingState: try row.text(9),
                items         : itemsByID[id] ?? []
            )
            let transition = LearnedTransition(
                anchorKey        : anchorKey,
                trigger          : trigger,
                effect           : effect.effect,
                evidence         : Int(row.integer(13) ?? 0),
                lastObserved     : try date(row.integer(12) ?? 0),
                lastObservedEpoch: row.integer(10).map(Int.init)
            )
            let statusCode = try row.text(11) ?? ""
            switch statusCode {
                case "trusted", "candidate":
                    guard statusCode == status(of: transition) else {
                        throw BrainProjectionError.malformedRow(table: "brain_transitions", id: id, malformation: .statusContradictsEvidence)
                    }
                default:
                    throw BrainProjectionError.unknownTransitionStatus(statusCode)
            }
            guard ids[transition.key] == nil else {
                throw BrainProjectionError.malformedRow(table: "brain_transitions", id: id, malformation: .duplicateTransition)
            }
            ids[transition.key] = id
            return transition
        }
        return (transitions, ids)
    }

    private static func nextOrder(_ handle: some SQLiteQuerying, table: String, appID: Int64) throws -> Int64 {
        // Table names are this module's own literals.
        let highest = try handle.query("SELECT max(insertion_order) FROM \(table) WHERE app_id = ?", [.integer(appID)]) { $0.integer(0) }
            .first ?? nil
        return (highest ?? -1) + 1
    }

    // MARK: Writing

    /// Writes the difference from the loaded projection to the brain the algorithm produced, at the
    /// mutation's clock. Groups before anchors (the current group is a foreign key), anchors before
    /// memberships, then transitions under the application's scope, then the retirements with the
    /// causes `retired` reports; a dropped row the report does not explain is refused, and the
    /// transaction with it. Answers the row id of every active transition after the write.
    @discardableResult
    static func write(
        _ transaction    : SQLiteTransaction,
        appID            : Int64,
        from before      : Loaded,
        to after         : UIBrain,
        retired          : DecayReport,
        nowMS            : Int64,
        makeTransitionID : () -> String,
        makeSceneID      : () -> String
    ) throws -> [LearnedTransition.Key: String] {
        let old = before.brain
        var activeTransitionIDs: [LearnedTransition.Key: String] = [:]
        var nextAnchorOrder = before.nextAnchorOrder
        var nextGroupOrder = before.nextGroupOrder
        var nextTransitionOrder = before.nextTransitionOrder
        var appScopeID = before.appScopeID
        let retiredEpoch = Int64(after.ingestEpoch)

        if old.ingestEpoch != after.ingestEpoch || old.lastEpochAdvance != after.lastEpochAdvance {
            try transaction.execute(
                "UPDATE brain_apps SET ingest_epoch = ?, last_epoch_advance_ms = ? WHERE app_id = ?",
                [.integer(Int64(after.ingestEpoch)), try optionalMilliseconds(of: after.lastEpochAdvance).map(SQLiteValue.integer) ?? .null,
                 .integer(appID)]
            )
        }
        for (family, epoch) in after.windowEpochs.sorted(by: { $0.key < $1.key }) where old.windowEpochs[family] != epoch {
            try transaction.execute(
                """
                INSERT INTO brain_app_window_epochs (app_id, window_family, epoch) VALUES (?, ?, ?)
                ON CONFLICT (app_id, window_family) DO UPDATE SET epoch = excluded.epoch
                """,
                [.integer(appID), .text(family), .integer(Int64(epoch))]
            )
        }
        for family in old.windowEpochs.keys.sorted() where after.windowEpochs[family] == nil {
            try transaction.execute(
                "DELETE FROM brain_app_window_epochs WHERE app_id = ? AND window_family = ?",
                [.integer(appID), .text(family)]
            )
        }

        let oldGroups = Dictionary(old.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newGroups = Dictionary(after.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for group in after.groups {
            if let previous = oldGroups[group.id] {
                if !sameScalars(previous, group) {
                    try transaction.execute(
                        """
                        UPDATE brain_groups
                        SET axis = ?, shared_kind = ?, cell_width = ?, cell_height = ?, name = ?, last_seen_ms = ?,
                            seen_count = ?, last_seen_epoch = ?
                        WHERE group_id = ?
                        """,
                        try groupScalars(group) + [.text(group.id.uuidString)]
                    )
                }
            } else {
                try transaction.execute(
                    """
                    INSERT INTO brain_groups
                        (group_id, app_id, insertion_order, axis, shared_kind, cell_width, cell_height, name, last_seen_ms,
                         seen_count, last_seen_epoch)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(group.id.uuidString), .integer(appID), .integer(nextGroupOrder)] + (try groupScalars(group))
                )
                nextGroupOrder += 1
            }
        }

        let oldAnchors = Dictionary(old.objects.map { ($0.anchorKey, $0) }, uniquingKeysWith: { first, _ in first })
        let newAnchors = Dictionary(after.objects.map { ($0.anchorKey, $0) }, uniquingKeysWith: { first, _ in first })
        for anchor in after.objects {
            if let previous = oldAnchors[anchor.anchorKey] {
                if !sameScalars(previous, anchor) {
                    try transaction.execute(
                        """
                        UPDATE brain_anchors
                        SET kind = ?, label = ?, label_source = ?, typical_x = ?, typical_y = ?, typical_width = ?,
                            typical_height = ?, window_family = ?, first_seen_ms = ?, last_seen_ms = ?, seen_count = ?,
                            last_seen_epoch = ?, current_group_id = ?
                        WHERE anchor_id = ?
                        """,
                        try anchorScalars(anchor) + [.text(anchor.anchorKey)]
                    )
                }
                if previous.aliases != anchor.aliases {
                    try rewriteAliases(transaction, anchorID: anchor.anchorKey, from: previous.aliases, to: anchor.aliases)
                }
                if previous.statesSeen != anchor.statesSeen {
                    try rewriteStates(transaction, anchorID: anchor.anchorKey, from: previous.statesSeen, to: anchor.statesSeen)
                }
            } else {
                try transaction.execute(
                    """
                    INSERT INTO brain_anchors
                        (anchor_id, app_id, insertion_order, anchor_scope, kind, label, label_source, typical_x, typical_y,
                         typical_width, typical_height, window_family, first_seen_ms, last_seen_ms, seen_count,
                         last_seen_epoch, current_group_id)
                    VALUES (?, ?, ?, 'control', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(anchor.anchorKey), .integer(appID), .integer(nextAnchorOrder)] + (try anchorScalars(anchor))
                )
                nextAnchorOrder += 1
                try rewriteAliases(transaction, anchorID: anchor.anchorKey, from: [], to: anchor.aliases)
                try rewriteStates(transaction, anchorID: anchor.anchorKey, from: [:], to: anchor.statesSeen)
            }
        }

        for group in after.groups {
            let previous = oldGroups[group.id]?.memberAnchors ?? []
            if previous != group.memberAnchors {
                try rewriteMembers(transaction, appID: appID, groupID: group.id, from: previous, to: group.memberAnchors)
            }
        }

        let oldTransitions = Dictionary(old.transitions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var afterKeys = Set<LearnedTransition.Key>()
        for transition in after.transitions {
            guard afterKeys.insert(transition.key).inserted else {
                throw BrainProjectionError.malformedRow(
                    table: "brain_transitions", id: transition.anchorKey, malformation: .duplicateTransition)
            }
            if let id = before.transitionIDs[transition.key] {
                activeTransitionIDs[transition.key] = id
                if let previous = oldTransitions[transition.key], previous != transition {
                    try transaction.execute(
                        """
                        UPDATE brain_transitions
                        SET evidence_count = ?, last_seen_ms = ?, last_observed_epoch = ?, status = ?
                        WHERE transition_id = ?
                        """,
                        [.integer(Int64(transition.evidence)), .integer(try milliseconds(of: transition.lastObserved)),
                         transition.lastObservedEpoch.map { .integer(Int64($0)) } ?? .null, .text(status(of: transition)),
                         .text(id)]
                    )
                }
            } else {
                let effect = try TransitionEffectRecord(effect: transition.effect)
                let scope: String
                if let appScopeID {
                    scope = appScopeID
                } else {
                    scope = try ensureAppScope(transaction, appID: appID, nowMS: nowMS, makeSceneID: makeSceneID)
                    appScopeID = scope
                }
                let id = makeTransitionID()
                activeTransitionIDs[transition.key] = id
                try transaction.execute(
                    """
                    INSERT INTO brain_transitions
                        (transition_id, app_id, insertion_order, from_scene_id, anchor_id, scene_element_id, menu_command_id,
                         trigger_kind, to_scene_id, effect_kind, effect_text, required_target_state, resulting_target_state,
                         last_observed_epoch, status, first_seen_ms, last_seen_ms, evidence_count)
                    VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(id), .integer(appID), .integer(nextTransitionOrder), .text(scope), .text(transition.anchorKey),
                        .text(transition.trigger.rawValue), .text(effect.kind), effect.text.map(SQLiteValue.text) ?? .null,
                        effect.requiredState.map { .text($0.rawValue) } ?? .null,
                        effect.resultingState.map { .text($0.rawValue) } ?? .null,
                        transition.lastObservedEpoch.map { .integer(Int64($0)) } ?? .null, .text(status(of: transition)),
                        .integer(nowMS), .integer(try milliseconds(of: transition.lastObserved)), .integer(Int64(transition.evidence)),
                    ]
                )
                nextTransitionOrder += 1
                for (position, title) in effect.items.enumerated() {
                    try transaction.execute(
                        "INSERT INTO brain_transition_menu_items (transition_id, position, title) VALUES (?, ?, ?)",
                        [.text(id), .integer(Int64(position)), .text(title)]
                    )
                }
            }
        }
        for (key, id) in before.transitionIDs.sorted(by: { $0.value < $1.value }) where !afterKeys.contains(key) {
            guard let cause = retired.transitions[key] else {
                throw BrainProjectionError.unexplainedRemoval(table: "brain_transitions", id: id)
            }
            try retire(transaction, table: "brain_transitions", keyColumn: "transition_id", id: id,
                       nowMS: nowMS, epoch: retiredEpoch, cause: cause.rawValue)
        }

        for anchor in old.objects where newAnchors[anchor.anchorKey] == nil {
            guard let cause = retired.anchors[anchor.anchorKey] else {
                throw BrainProjectionError.unexplainedRemoval(table: "brain_anchors", id: anchor.anchorKey)
            }
            try retire(transaction, table: "brain_anchors", keyColumn: "anchor_id", id: anchor.anchorKey,
                       nowMS: nowMS, epoch: retiredEpoch, cause: cause.rawValue)
        }
        for group in old.groups where newGroups[group.id] == nil {
            guard let cause = retired.groups[group.id] else {
                throw BrainProjectionError.unexplainedRemoval(table: "brain_groups", id: group.id.uuidString)
            }
            try retire(transaction, table: "brain_groups", keyColumn: "group_id", id: group.id.uuidString,
                       nowMS: nowMS, epoch: retiredEpoch, cause: cause.rawValue)
        }
        return activeTransitionIDs
    }

    /// Mutation is what one synchronous mutation of the projection did: the body's result, the
    /// projection it started from, the brain it left and the row id of every active transition.
    struct Mutation<T> {
        let result: T
        let before: Loaded
        let after: UIBrain
        let transitionIDs: [LearnedTransition.Key: String]
    }

    /// Runs one mutation on a projection already loaded in this transaction: the body on the
    /// brain at `now`, then the difference written at `nowMS`. No await, no other transaction: the
    /// raw repository and the application repository share it, each inside its own `store.write`.
    static func mutate<T>(
        _ transaction    : SQLiteTransaction,
        appID            : Int64,
        loaded           : Loaded,
        now              : Date,
        nowMS            : Int64,
        makeTransitionID : () -> String,
        makeSceneID      : () -> String,
        _ body           : (inout UIBrain, Date) throws -> (T, DecayReport)
    ) throws -> Mutation<T> {
        var brain = loaded.brain
        let (result, retired) = try body(&brain, now)
        let ids = try write(
            transaction, appID: appID, from: loaded, to: brain, retired: retired, nowMS: nowMS,
            makeTransitionID: makeTransitionID, makeSceneID: makeSceneID
        )
        return Mutation(result: result, before: loaded, after: brain, transitionIDs: ids)
    }

    /// The application's scope row (`scene_kind = 'app'`), found or created: the source of every
    /// anchor-to-effect transition of the compatible projection.
    static func ensureAppScope(
        _ transaction: SQLiteTransaction,
        appID        : Int64,
        nowMS        : Int64,
        makeSceneID  : () -> String
    ) throws -> String {
        if let found = try transaction.query(
            "SELECT scene_id FROM brain_scenes WHERE app_id = ? AND scene_kind = 'app'", [.integer(appID)]
        ) { try $0.text(0) ?? "" }.first {
            return found
        }
        let id = makeSceneID()
        try transaction.execute(
            """
            INSERT INTO brain_scenes
                (scene_id, app_id, window_title_pattern, title_bucket, scene_kind, structural_key, first_seen_ms, last_seen_ms,
                 observation_count)
            VALUES (?, ?, NULL, '#app', 'app', NULL, ?, ?, 0)
            """,
            [.text(id), .integer(appID), .integer(nowMS), .integer(nowMS)]
        )
        return id
    }

    // MARK: Lists

    private static func rewriteAliases(_ transaction: SQLiteTransaction, anchorID: String, from old: [String], to new: [String]) throws {
        let kept = Set(new), had = Set(old)
        for alias in old where !kept.contains(alias) {
            try transaction.execute("DELETE FROM brain_anchor_aliases WHERE anchor_id = ? AND alias = ?", [.text(anchorID), .text(alias)])
        }
        if !had.isEmpty {
            try transaction.execute(
                "UPDATE brain_anchor_aliases SET position = position + ? WHERE anchor_id = ?",
                [.integer(repositionOffset), .text(anchorID)]
            )
        }
        for (position, alias) in new.enumerated() {
            if had.contains(alias) {
                try transaction.execute(
                    "UPDATE brain_anchor_aliases SET position = ? WHERE anchor_id = ? AND alias = ?",
                    [.integer(Int64(position)), .text(anchorID), .text(alias)]
                )
            } else {
                try transaction.execute(
                    "INSERT INTO brain_anchor_aliases (anchor_id, alias, position) VALUES (?, ?, ?)",
                    [.text(anchorID), .text(alias), .integer(Int64(position))]
                )
            }
        }
    }

    private static func rewriteStates(_ transaction: SQLiteTransaction, anchorID: String, from old: [String: Int], to new: [String: Int]) throws {
        for (state, count) in new.sorted(by: { $0.key < $1.key }) where old[state] != count {
            try transaction.execute(
                """
                INSERT INTO brain_anchor_states (anchor_id, state, seen_count) VALUES (?, ?, ?)
                ON CONFLICT (anchor_id, state) DO UPDATE SET seen_count = excluded.seen_count
                """,
                [.text(anchorID), .text(state), .integer(Int64(count))]
            )
        }
        for state in old.keys.sorted() where new[state] == nil {
            try transaction.execute("DELETE FROM brain_anchor_states WHERE anchor_id = ? AND state = ?", [.text(anchorID), .text(state)])
        }
    }

    private static func rewriteMembers(
        _ transaction: SQLiteTransaction,
        appID        : Int64,
        groupID      : UUID,
        from old     : [String],
        to new       : [String]
    ) throws {
        let group = groupID.uuidString
        let kept = Set(new), had = Set(old)
        for anchorID in old where !kept.contains(anchorID) {
            try transaction.execute("DELETE FROM brain_group_members WHERE group_id = ? AND anchor_id = ?", [.text(group), .text(anchorID)])
        }
        if !had.isEmpty {
            try transaction.execute(
                "UPDATE brain_group_members SET position = position + ? WHERE group_id = ?",
                [.integer(repositionOffset), .text(group)]
            )
        }
        for (position, anchorID) in new.enumerated() {
            if had.contains(anchorID) {
                try transaction.execute(
                    "UPDATE brain_group_members SET position = ? WHERE group_id = ? AND anchor_id = ?",
                    [.integer(Int64(position)), .text(group), .text(anchorID)]
                )
            } else {
                try transaction.execute(
                    "INSERT INTO brain_group_members (app_id, group_id, anchor_id, position) VALUES (?, ?, ?, ?)",
                    [.integer(appID), .text(group), .text(anchorID), .integer(Int64(position))]
                )
            }
        }
    }

    private static func retire(
        _ transaction: SQLiteTransaction,
        table        : String,
        keyColumn    : String,
        id           : String,
        nowMS        : Int64,
        epoch        : Int64,
        cause        : String
    ) throws {
        // Table and column names are this module's own literals; the cause is a closed vocabulary's raw value.
        try transaction.execute(
            "UPDATE \(table) SET retired_at_ms = ?, retired_epoch = ?, retirement_cause = ? WHERE \(keyColumn) = ?",
            [.integer(nowMS), .integer(epoch), .text(cause), .text(id)]
        )
    }

    // MARK: Scalars

    /// The scalar columns of an anchor, in the order the INSERT and the UPDATE name them. Bounds
    /// that are not finite numbers are refused: they would not read back as themselves.
    private static func anchorScalars(_ anchor: ObjectAnchor) throws -> [SQLiteValue] {
        let bounds = anchor.boundsTypical
        for (column, value) in [("typical_x", bounds.x), ("typical_y", bounds.y),
                                ("typical_width", bounds.width), ("typical_height", bounds.height)] where !value.isFinite {
            throw BrainProjectionError.unrepresentableNumber(table: "brain_anchors", id: anchor.anchorKey, column: column)
        }
        return [
            .text(anchor.kind.rawValue), .text(anchor.label), anchor.labelSource.map { .text($0.rawValue) } ?? .null,
            .real(bounds.x), .real(bounds.y), .real(bounds.width), .real(bounds.height),
            anchor.window.map(SQLiteValue.text) ?? .null,
            .integer(try milliseconds(of: anchor.firstSeen)), .integer(try milliseconds(of: anchor.lastSeen)),
            .integer(Int64(anchor.seenCount)), anchor.lastSeenEpoch.map { .integer(Int64($0)) } ?? .null,
            anchor.groupID.map { .text($0.uuidString) } ?? .null,
        ]
    }

    private static func sameScalars(_ lhs: ObjectAnchor, _ rhs: ObjectAnchor) -> Bool {
        lhs.kind == rhs.kind && lhs.label == rhs.label && lhs.labelSource == rhs.labelSource
            && lhs.boundsTypical == rhs.boundsTypical && lhs.window == rhs.window
            && lhs.firstSeen == rhs.firstSeen && lhs.lastSeen == rhs.lastSeen && lhs.seenCount == rhs.seenCount
            && lhs.lastSeenEpoch == rhs.lastSeenEpoch && lhs.groupID == rhs.groupID
    }

    /// The scalar columns of a group, in the order the INSERT and the UPDATE name them. A cell size
    /// that is not a finite number is refused.
    private static func groupScalars(_ group: SiblingGroup) throws -> [SQLiteValue] {
        for (column, value) in [("cell_width", group.cellSize.width), ("cell_height", group.cellSize.height)] where !value.isFinite {
            throw BrainProjectionError.unrepresentableNumber(table: "brain_groups", id: group.id.uuidString, column: column)
        }
        return [
            .text(group.axis.rawValue), .text(group.sharedKind.rawValue),
            .real(group.cellSize.width), .real(group.cellSize.height), group.name.map(SQLiteValue.text) ?? .null,
            .integer(try milliseconds(of: group.lastSeen)), .integer(Int64(group.seenCount)),
            group.lastSeenEpoch.map { .integer(Int64($0)) } ?? .null,
        ]
    }

    private static func sameScalars(_ lhs: SiblingGroup, _ rhs: SiblingGroup) -> Bool {
        lhs.axis == rhs.axis && lhs.sharedKind == rhs.sharedKind && lhs.cellSize == rhs.cellSize && lhs.name == rhs.name
            && lhs.lastSeen == rhs.lastSeen && lhs.seenCount == rhs.seenCount && lhs.lastSeenEpoch == rhs.lastSeenEpoch
    }

    /// The cached status of a transition: `LearnedTransition.isTrusted` as the file stores it.
    static func status(of transition: LearnedTransition) -> String {
        transition.isTrusted ? "trusted" : "candidate"
    }

    // MARK: Numbers and dates

    private static func rect(
        _ row    : SQLiteStatement.Row,
        from     : Int,
        table    : String,
        id       : String,
        columns  : [String]
    ) throws -> NormalizedRect {
        var values: [Double] = []
        for (offset, column) in columns.enumerated() {
            values.append(try real(row, from + offset, table: table, id: id, column: column))
        }
        return NormalizedRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static func real(_ row: SQLiteStatement.Row, _ index: Int, table: String, id: String, column: String) throws -> Double {
        guard let value = row.real(index) else {
            throw BrainProjectionError.malformedRow(table: table, id: id, malformation: .missingColumn(column))
        }
        guard value.isFinite else {
            throw BrainProjectionError.malformedRow(table: table, id: id, malformation: .nonFiniteNumber(column))
        }
        return value
    }

    static func milliseconds(of date: Date) throws -> Int64 {
        do { return try BrainClock.milliseconds(of: date) } catch let problem as BrainClock.Problem {
            throw BrainProjectionError.clock(problem)
        }
    }

    static func optionalMilliseconds(of date: Date?) throws -> Int64? {
        try date.map { try milliseconds(of: $0) }
    }

    static func date(_ milliseconds: Int64) throws -> Date {
        do { return try BrainClock.date(milliseconds) } catch let problem as BrainClock.Problem {
            throw BrainProjectionError.clock(problem)
        }
    }

    static func optionalDate(_ milliseconds: Int64?) throws -> Date? {
        try milliseconds.map { try date($0) }
    }
}
