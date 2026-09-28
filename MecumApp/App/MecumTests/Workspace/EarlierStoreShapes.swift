//
//  EarlierStoreShapes.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import Foundation
import ModelTransports
import SwiftData
@testable import Mecum

/// StoreShapeV4 is the workspace as the app stored it before replies: the
/// shape of a store written by the last commit before them, as its versioned
/// schema v4. Its `Conversation` and `Message` are frozen here as that store
/// holds them, with the app's entity names, so a test can write such a store
/// and open it with the app's one schema. The other models have not changed
/// since, and are the app's own.
enum StoreShapeV4: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Worker.self,
            WorkerConfiguration.self,
            Execution.self,
            Conversation.self,
            Message.self,
            WorkspaceEvent.self,
        ]
    }

    @Model
    final class Conversation {

        #Unique<Conversation>([\.id])

        var id                     : UUID
        var kind                   : ConversationKind
        var title                  : String?
        var participantIDs         : [UUID]
        var draft                  : String
        var readingAnchorMessageID : UUID?
        var readingOffset          : Double
        var createdAt              : Date
        var providerSessionProvider: ModelProvider?
        var providerSessionID      : String?
        var readUpToSequence       : Int = 0
        var readUpToEventOrder     : Int = 0

        init(
            id            : UUID,
            participantIDs: [UUID],
            draft         : String
        ) {
            self.id                      = id
            self.kind                    = .direct
            self.title                   = nil
            self.participantIDs          = participantIDs
            self.draft                   = draft
            self.readingAnchorMessageID  = nil
            self.readingOffset           = 0
            self.createdAt               = Date()
            self.providerSessionProvider = .claudeCode
            self.providerSessionID       = "session-4"
        }
    }

    @Model
    final class Message {

        #Unique<Message>([\.id])
        #Index<Message>([\.conversationID, \.sequence])

        var id            : UUID
        var conversationID: UUID
        var authorWorkerID: UUID?
        var text          : String
        var createdAt     : Date
        var sequence      : Int
        var delivery      : MessageDelivery

        init(
            conversationID: UUID,
            authorWorkerID: UUID? = nil,
            text          : String,
            sequence      : Int
        ) {
            self.id             = UUID()
            self.conversationID = conversationID
            self.authorWorkerID = authorWorkerID
            self.text           = text
            self.createdAt      = Date()
            self.sequence       = sequence
            self.delivery       = .completed
        }
    }
}

/// StoreShapeV5 is the workspace as the app stored it with replies and before
/// the queue: what the reply build wrote, as its versioned schema v5. Its
/// `Conversation` keeps the draft's quote and its `Message` the quote it
/// replies to, frozen here as that store holds them; the other models are the
/// app's own.
enum StoreShapeV5: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Worker.self,
            WorkerConfiguration.self,
            Execution.self,
            Conversation.self,
            Message.self,
            WorkspaceEvent.self,
        ]
    }

    @Model
    final class Conversation {

        #Unique<Conversation>([\.id])

        var id                      : UUID
        var kind                    : ConversationKind
        var title                   : String?
        var participantIDs          : [UUID]
        var draft                   : String
        var readingAnchorMessageID  : UUID?
        var readingOffset           : Double
        var createdAt               : Date
        var providerSessionProvider : ModelProvider?
        var providerSessionID       : String?
        var readUpToSequence        : Int = 0
        var readUpToEventOrder      : Int = 0
        var draftQuoteMessageID     : UUID?
        var draftQuoteAuthorWorkerID: UUID?
        var draftQuoteText          : String?

        init(
            id            : UUID,
            participantIDs: [UUID],
            draft         : String,
            draftQuote    : MessageQuote
        ) {
            self.id                       = id
            self.kind                     = .direct
            self.title                    = nil
            self.participantIDs           = participantIDs
            self.draft                    = draft
            self.readingAnchorMessageID   = nil
            self.readingOffset            = 0
            self.createdAt                = Date()
            self.providerSessionProvider  = nil
            self.providerSessionID        = nil
            self.draftQuoteMessageID      = draftQuote.messageID
            self.draftQuoteAuthorWorkerID = draftQuote.authorWorkerID
            self.draftQuoteText           = draftQuote.text
        }
    }

    @Model
    final class Message {

        #Unique<Message>([\.id])
        #Index<Message>([\.conversationID, \.sequence])

        var id                  : UUID
        var conversationID      : UUID
        var authorWorkerID      : UUID?
        var text                : String
        var createdAt           : Date
        var sequence            : Int
        var delivery            : MessageDelivery
        var quotedMessageID     : UUID?
        var quotedAuthorWorkerID: UUID?
        var quotedText          : String?

        init(
            id            : UUID          = UUID(),
            conversationID: UUID,
            authorWorkerID: UUID?         = nil,
            text          : String,
            sequence      : Int,
            quote         : MessageQuote? = nil
        ) {
            self.id                   = id
            self.conversationID       = conversationID
            self.authorWorkerID       = authorWorkerID
            self.text                 = text
            self.createdAt            = Date()
            self.sequence             = sequence
            self.delivery             = .completed
            self.quotedMessageID      = quote?.messageID
            self.quotedAuthorWorkerID = quote?.authorWorkerID
            self.quotedText           = quote?.text
        }
    }
}

/// The plan an earlier app opened its store with, reduced to the one shape a
/// test writes, so the store is made the way that app made it.
enum WritingPlan<Shape: VersionedSchema>: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] { [Shape.self] }

    static var stages: [MigrationStage] { [] }
}

/// Writes a store at `directory` in an earlier shape, with what `fill` puts
/// in it, and closes it, as the app that wrote it would have left it.
func writeStore<Shape: VersionedSchema>(
    in directory: URL,
    as shape    : Shape.Type,
    _ fill      : (ModelContext) throws -> Void
) throws {
    try FileManager.default.createDirectory(
        at                         : directory,
        withIntermediateDirectories: true
    )
    let schema    = Schema(versionedSchema: shape)
    let container = try ModelContainer(
        for           : schema,
        migrationPlan : WritingPlan<Shape>.self,
        configurations: ModelConfiguration(
            schema: schema,
            url   : directory.appending(path: WorkspaceStoreFile.storeName)
        )
    )
    let context = ModelContext(container)
    try fill(context)
    try context.save()
}
