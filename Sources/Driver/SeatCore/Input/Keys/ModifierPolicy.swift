//
//  ModifierPolicy.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

/// ModifierPolicy is how a target is told which modifiers are held, and the two
/// cases differ in whether anything is left inside it.
///
/// `.eventFlags` stamps the modifiers on the key events themselves and posts
/// nothing else. The target reads them off the event it is handling, which is
/// what `performKeyEquivalent:` does and what a page reading `metaKey` on a
/// keydown does. Nothing about a modifier survives the event it was stamped on.
///
/// `.flagsChanged` also posts real modifier transition events, so a target that
/// watches modifiers *change* rather than reading them off a key event sees
/// them. It is the honest simulation of a keyboard and it is the one that can
/// leave a Command key stuck inside somebody's editor if this process dies
/// between the press and the release.
///
/// `.eventFlags` is the default and no platform the kit ships asks for anything
/// else. ADR 0011 has the three arguments; the short version is that the extra
/// fidelity buys nothing measured and the failure mode is worse.
public enum ModifierPolicy: Sendable, Equatable {

    case eventFlags
    case flagsChanged
}
