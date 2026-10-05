//
//  TurnModel.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import ChatCore
import Foundation
import ModelTransports

/// TurnModel is the provider, model and effort one turn runs with, as both entries name them: the
/// app's `ModelSelection`, which always chooses a model and an effort, and the chat's command line,
/// which chooses neither and leaves both to the command line's own defaults. A nil model or effort is
/// that default and is never filled in here; the one authority for which efforts exist stays
/// `ModelSelection.supportedEfforts`, so what reaches the provider is decided the same way for both.
struct TurnModel: Sendable, Hashable {

    let provider: ModelProvider

    /// The model as the entry named it, nil for the provider's default.
    let model   : String?

    /// The effort as the entry chose it, nil for the provider's default.
    let effort  : ReasoningEffort?

    /// The app's selection: its model when it names one, and its effort.
    init(_ selection: ModelSelection) {
        provider = selection.provider
        model    = selection.model.isEmpty ? nil : selection.model
        effort   = selection.effort
    }

    /// The chat's command line: its provider, the model when the conversation names one, and the effort
    /// when the invocation chose one; none of them is filled in here.
    init(commandLine: ChatProvider, model: String?, effort: ReasoningEffort? = nil) {
        provider    = ModelProvider(commandLine)
        self.model  = model.flatMap { $0.isEmpty ? nil : $0 }
        self.effort = effort
    }

    /// The effort the provider is sent: the one chosen, when the model offers it, else none.
    var offeredEffort: String? {
        guard let effort,
              ModelSelection.supportedEfforts(provider: provider, model: model ?? "").contains(effort)
        else { return nil }
        return effort.rawValue
    }
}

extension ModelProvider {

    /// The provider a signed-in command line answers for, the inverse of `AgentTurnHost.agent(for:)`.
    init(_ commandLine: ChatProvider) {
        switch commandLine {
        case .claude: self = .claudeCode
        case .codex : self = .codex
        }
    }
}
