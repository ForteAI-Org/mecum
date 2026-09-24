//
//  ConnectionState+Symbol.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import ModelTransports

extension ConnectionState {

    /// The symbol that stands for a connection that does not work, nil for one that does: a
    /// working connection says nothing, and a broken one is a symbol whose words are its help.
    var troubleSymbol: String? {
        switch self {
        case .ready             : nil
        case .credentialMissing : "key"
        case .credentialRejected: "key.slash"
        case .unreachable       : "network.slash"
        case .usageLimited      : "hourglass"
        case .modelRemoved      : "questionmark.circle"
        case .refused           : "hand.raised"
        }
    }
}
