//
//  ApplicationActivating.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation

/// ApplicationActivating raises an application before a foreground gesture and says which one is in
/// front. A background seat does not fill this role at all: its windows are never in front and its
/// gestures need no raising, which is why the engine treats the role as optional.
public protocol ApplicationActivating: Sendable {

    func frontmostProcessID() async -> pid_t?
    func activate(_ processID: pid_t) async
}
