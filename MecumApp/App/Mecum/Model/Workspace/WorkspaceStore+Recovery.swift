//
//  WorkspaceStore+Recovery.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import SwiftData

extension WorkspaceStore {

    /// Ends every execution an earlier process started and never ended, and
    /// returns their ids in the order they started (§18.4, §22.2).
    ///
    /// Each gets one `executionFailed` carrying `reason`, and the person's
    /// message it answered, named by its `executionStarted` event, moves to
    /// interrupted. Replies already stored stay as they are. Nothing is run
    /// again: this writes the ending and nothing else (§19.3). A message whose
    /// execution did end, but which still reads sent or responding, is moved
    /// to what that ending implies (`settleMessagesOfEndedExecutions`).
    ///
    /// An execution this instance started is never ended here, and only the
    /// first call on an instance that returns scans. A second launch finds
    /// each execution ended and each message settled and writes nothing, and a
    /// terminal event arriving later
    /// is dropped by `append`'s first arrival rule, so the ending recorded
    /// here is the one that stays.
    ///
    /// `workspace` is used for an execution whose `executionStarted` was never
    /// recorded; such an execution has no message to mark. The scan has no
    /// suspension point, so no other call on the store interleaves with it.
    @discardableResult
    func endExecutionsLeftUnfinished(reason: String, workspace: UUID) throws -> [UUID] {
        guard !hasEndedEarlierExecutions else { return [] }

        let executions = try modelContext.fetch(FetchDescriptor<Execution>(sortBy: [SortDescriptor(\.startedAt)]))
        var ended: [UUID] = []
        for execution in executions where !startedHere.contains(execution.id) {
            let subject = execution.id
            let key     = NewEvent.terminalKey(of: subject)
            guard try first(WorkspaceEvent.self, where: #Predicate { $0.deduplicationKey == key }) == nil else {
                continue
            }

            let started = try events(matching: EventQuery(scope: .subject(subject)))
                .first { $0.type == .executionStarted }
            try append(NewEvent(
                workspaceID   : started?.workspaceID ?? workspace,
                subjectID     : subject,
                conversationID: execution.conversationID,
                workerID      : execution.workerID,
                type          : .executionFailed,
                payload       : Data(reason.utf8),
                correlationID : started?.correlationID
            ))
            if let messageID = started?.correlationID,
               let message = try first(Message.self, where: #Predicate { $0.id == messageID }) {
                message.delivery = .interrupted
                try saveOrRollBack()
            }
            ended.append(subject)
        }
        try settleMessagesOfEndedExecutions()
        // Set only once the scan has finished, so a scan that threw is tried again by the next call.
        hasEndedEarlierExecutions = true
        return ended
    }

    /// Moves a message still sent or responding whose latest execution has
    /// ended to what that ending implies: completed for `executionCompleted`,
    /// interrupted for any other terminal event, including one of a type this
    /// build does not know. It is what a crash between a turn's ending and its
    /// message update leaves. A message whose execution has not ended, or was
    /// started by this instance, is left as it is.
    ///
    /// It reads one message per conversation, the latest the person sent: the
    /// composer sends nothing while a turn runs, so no other can still be
    /// waiting, and the cost follows the conversations rather than their
    /// history. The delivery is compared here and not in the predicate: SwiftData
    /// on some of the macOS versions the app supports refuses an enum value in a
    /// predicate (`unsupportedPredicate`), while the one it is built on accepts
    /// it, so no test here can catch it. No enum column is filtered in a predicate.
    private func settleMessagesOfEndedExecutions() throws {
        var waiting: [Message] = []
        for conversation in try modelContext.fetch(FetchDescriptor<Conversation>()) {
            let id     = conversation.id
            var latest = FetchDescriptor<Message>(
                predicate: #Predicate { $0.conversationID == id && $0.authorWorkerID == nil },
                sortBy   : [SortDescriptor(\.sequence, order: .reverse)]
            )
            latest.fetchLimit = 1
            if let message = try modelContext.fetch(latest).first,
               message.delivery == .sentToBackend || message.delivery == .responding {
                waiting.append(message)
            }
        }
        for message in waiting {
            let messageID  = message.id
            let correlated = try modelContext.fetch(FetchDescriptor<WorkspaceEvent>(
                predicate: #Predicate { $0.correlationID == messageID },
                sortBy   : [SortDescriptor(\.localOrder, order: .reverse)]
            ))
            guard let started = correlated.first(where: { $0.type == .executionStarted }),
                  !startedHere.contains(started.subjectID)
            else { continue }
            let key = NewEvent.terminalKey(of: started.subjectID)
            guard let ending = try first(WorkspaceEvent.self, where: #Predicate { $0.deduplicationKey == key }) else {
                continue
            }
            message.delivery = ending.type == .executionCompleted ? .completed : .interrupted
            try saveOrRollBack()
        }
    }
}
