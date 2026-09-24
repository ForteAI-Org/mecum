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
    /// It reads only the messages in those two states, normally none, so its
    /// cost does not grow with the history.
    private func settleMessagesOfEndedExecutions() throws {
        let sent       = MessageDelivery.sentToBackend
        let responding = MessageDelivery.responding
        let waiting    = try modelContext.fetch(FetchDescriptor<Message>(
            predicate: #Predicate { $0.delivery == sent || $0.delivery == responding }
        ))
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
