//
//  ValueMinimization.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// ValueMinimization decides, before anything reaches the archive, its copies or its log, which values
/// of a call are kept and which are withheld. Ordinary values, private as they may be, are kept: the
/// living memory learns from them locally. A secret is never kept: the task declared it secret, it
/// has the shape of a credential, or the control it went to is named for one. Its place keeps the
/// marker, and a `ValueRedaction` says which value it was and why; nothing of its content (length,
/// digest) is kept.
///
/// The rules are conservative where they can be: every text argument is searched for credential
/// shapes, not only the typed ones, and a secret declared by the task is withheld wherever it
/// appears, inside a longer text too and however short it is (a declared PIN of three digits is
/// withheld from "The PIN is 731", at the cost of the same digits in an ordinary text). The length
/// thresholds belong to the credential heuristics only. The rules cannot see what they are not told:
/// a password typed into a field whose label names no secret, which the task did not declare secret
/// and which has no credential shape, is kept, because the perception does not report a field as
/// secure. That limit is stated, not hidden.
public struct ValueMinimization: Sendable {

    /// The text a withheld value is replaced with.
    public static let marker = "[withheld]"

    /// Secrets the current task declared, in memory only, never stored.
    public let secrets: [String]

    public init(secrets: [String] = []) {
        self.secrets = secrets.filter { !$0.isEmpty }
    }

    // MARK: Requests

    /// The request with every withheld value replaced by the marker, and the redactions it leaves.
    /// `eventID` is the call's event, which the redactions name.
    public func minimize(_ request: AgentCallRequest, eventID: String) -> (AgentCallRequest, [ValueRedaction]) {
        var redactions: [ValueRedaction] = []
        func keep(_ text: String, _ name: String, typedInto target: String? = nil) -> String {
            let (kept, reason) = minimize(text: text, typedInto: target)
            if let reason {
                redactions.append(ValueRedaction(eventID: eventID, location: .argument(name: name, position: 0),
                                                 reason: reason))
            }
            return kept
        }
        func keepOptional(_ text: String?, _ name: String) -> String? { text.map { keep($0, name) } }
        let minimized: AgentCallRequest
        switch request {
            case .status, .batch, .closeSession, .observe:
                minimized = request
            case .windows(let app):
                minimized = .windows(app: keepOptional(app, "app"))
            case .apps(let query):
                minimized = .apps(query: keepOptional(query, "query"))
            case .openSession(let app, let window):
                minimized = .openSession(app: keep(app, "app"), window: keepOptional(window, "window"))
            case .act(let target, let verb, let value, let section):
                minimized = .act(target: keep(target, "target"), verb: verb, value: value,
                                 section: keepOptional(section, "section"))
            case .select(let control, let item):
                minimized = .select(control: keep(control, "control"), item: keep(item, "item", typedInto: control))
            case .typeText(let target, let text, let section, let replace):
                minimized = .typeText(target: keep(target, "target"), text: keep(text, "text", typedInto: target),
                                      section: keepOptional(section, "section"), replace: replace)
            case .insertText(let text, let expectedValue):
                minimized = .insertText(text: keep(text, "text"),
                                        expectedValue: keepOptional(expectedValue, "expected_value"))
            case .pressKey:
                minimized = request
            case .scroll(let direction, let lines, let target, let section):
                minimized = .scroll(direction: direction, lines: lines, target: keepOptional(target, "target"),
                                    section: keepOptional(section, "section"))
            case .drag(let from, let end, let section):
                let kept: AgentDragEnd
                if case .target(let to) = end { kept = .target(keep(to, "to")) } else { kept = end }
                minimized = .drag(from: keep(from, "from"), to: kept, section: keepOptional(section, "section"))
            case .contextMenu(let target, let item, let section):
                minimized = .contextMenu(target: keep(target, "target"), item: keep(item, "item"),
                                         section: keepOptional(section, "section"))
            case .menu(let path):
                minimized = .menu(path: keep(path, "path"))
            case .press(let button):
                minimized = .press(button: keep(button, "button"))
        }
        return (minimized, redactions)
    }

    // MARK: Texts

    /// A text with what must be withheld removed: the whole text when it went to a control named for
    /// a secret, the declared secrets and the credential shapes inside it otherwise. The reason is
    /// the first rule that withheld something, nil when the text is kept as it is.
    public func minimize(text: String, typedInto target: String? = nil) -> (String, WithholdingReason?) {
        if let target, Self.namesSecret(target), !text.isEmpty { return (Self.marker, .secretTarget) }
        let (kept, declared) = withholdingDeclared(text)
        var reason: WithholdingReason? = declared ? .declaredSecret : nil
        let (scrubbed, found) = Self.scrubCredentials(kept)
        if found { reason = reason ?? .credentialPattern }
        return (scrubbed, reason)
    }

    /// The text with every declared secret replaced by the marker wherever it appears, and whether one
    /// was. The longest secret goes first, so one inside another leaves no piece behind, and the
    /// markers already in the text are never searched, so a secret that is part of the marker cannot
    /// break it.
    func withholdingDeclared(_ text: String) -> (String, Bool) {
        guard !secrets.isEmpty else { return (text, false) }
        // nil is a marker; every other segment is text still to be searched.
        var segments: [String?] = []
        for (index, part) in text.components(separatedBy: Self.marker).enumerated() {
            if index > 0 { segments.append(nil) }
            segments.append(part)
        }
        var withheld = false
        for secret in secrets.sorted(by: { $0.utf8.count > $1.utf8.count }) {
            segments = segments.flatMap { segment -> [String?] in
                guard let segment, segment.contains(secret) else { return [segment] }
                withheld = true
                var split: [String?] = []
                for (index, part) in segment.components(separatedBy: secret).enumerated() {
                    if index > 0 { split.append(nil) }
                    split.append(part)
                }
                return split
            }
        }
        return (segments.map { $0 ?? Self.marker }.joined(), withheld)
    }

    /// An optional text minimized the same way, with the same answer for nil.
    public func minimize(optional text: String?) -> (String?, WithholdingReason?) {
        guard let text else { return (nil, nil) }
        let (kept, reason) = minimize(text: text)
        return (kept, reason)
    }

    // MARK: Samples and scenes

    /// The sample with each element's label and its window title minimized, and the gaps it leaves.
    public func minimize(sample: CaptureSample) -> (CaptureSample, [ValueRedaction]) {
        var kept = sample
        var gaps: [ValueRedaction] = []
        let key = sample.key
        if let title = sample.windowTitle {
            let (scrubbed, reason) = minimize(text: title)
            if let reason {
                kept.windowTitle = scrubbed
                gaps.append(ValueRedaction(eventID: key.eventID,
                                           location: .sampleTitle(phase: key.phase, ordinal: key.ordinal),
                                           reason: reason))
            }
        }
        for index in kept.elements.indices {
            let (scrubbed, reason) = minimize(text: kept.elements[index].label)
            if let reason {
                kept.elements[index].label = scrubbed
                gaps.append(ValueRedaction(
                    eventID : key.eventID,
                    location: .sampleLabel(phase: key.phase, ordinal: key.ordinal, element: index),
                    reason  : reason
                ))
            }
            // The container path names the element's ancestors, whose labels may hold what the label does.
            let (path, withheld) = minimize(text: kept.elements[index].containerPath)
            if let withheld {
                kept.elements[index].containerPath = path
                gaps.append(ValueRedaction(
                    eventID : key.eventID,
                    location: .sampleContainer(phase: key.phase, ordinal: key.ordinal, element: index),
                    reason  : withheld
                ))
            }
        }
        return (kept, gaps)
    }

    /// The scene with its title and every text of its elements minimized: what the Brain may learn
    /// from it.
    public func minimize(scene: SceneSnapshot) -> SceneSnapshot {
        var kept = scene
        kept.windowTitle = minimize(text: scene.windowTitle).0
        kept.elements = scene.elements.map { minimize(element: $0).0 }
        return kept
    }

    /// An element as perception read it, every text of it minimized (its label and value, the names of
    /// its container, group, section and collection path, what it does) and its identity as its label
    /// was; with whether anything was withheld.
    public func minimize(element: SceneElement) -> (SceneElement, Bool) {
        var kept = element
        var withheld = false
        func scrub(_ text: String) -> String {
            let (minimized, reason) = minimize(text: text)
            if reason != nil { withheld = true }
            return minimized
        }
        kept.label          = scrub(element.label)
        kept.value          = element.value.map(scrub)
        kept.container      = element.container.map(scrub)
        kept.group          = element.group.map(scrub)
        kept.section        = element.section.map(scrub)
        kept.does           = element.does.map(scrub)
        kept.collectionPath = element.collectionPath.map(scrub)
        let (identity, reason) = minimize(identifier: element.id, label: element.label)
        if reason != nil { withheld = true }
        kept.id = identity
        return (kept, withheld)
    }

    // MARK: Identities, targets, effects and listings

    /// An element's identity minimized as its label is: perception names a labelled element
    /// `kind|normalized label` (`SceneIdentity`), so the withheld part of the label is withheld from the
    /// identity in its normalized form, the same way in every fact that names the element. A declared
    /// secret is withheld as written and normalized; a credential's shape as in any text.
    public func minimize(identifier: String, label: String?) -> (String, WithholdingReason?) {
        var kept = identifier
        var reason: WithholdingReason?
        if let label {
            let (minimized, why) = minimize(text: label)
            let original = LabelText.normalize(label)
            if let why, !original.isEmpty, kept.contains(original) {
                kept   = kept.replacingOccurrences(of: original, with: LabelText.normalize(minimized))
                reason = why
            }
        }
        let normalized = ValueMinimization(secrets: secrets + secrets.map(LabelText.normalize))
        let (declared, found) = normalized.withholdingDeclared(kept)
        if found {
            kept   = declared
            reason = reason ?? .declaredSecret
        }
        let (scrubbed, shaped) = Self.scrubCredentials(kept)
        if shaped { reason = reason ?? .credentialPattern }
        return (scrubbed, reason)
    }

    /// The element a call resolved with its label, section, identity and role minimized, and the
    /// gaps it leaves, one per location.
    public func minimize(target: OperationCheck.Target, eventID: String) -> (OperationCheck.Target, [ValueRedaction]) {
        var gaps: [ValueRedaction] = []
        func note(_ location: ValueRedaction.Location, _ reason: WithholdingReason?) {
            guard let reason, !gaps.contains(where: { $0.location == location }) else { return }
            gaps.append(ValueRedaction(eventID: eventID, location: location, reason: reason))
        }
        let (label, labelReason) = minimize(text: target.label)
        note(.targetLabel, labelReason)
        let section = target.section.map { minimize(text: $0) }
        note(.targetSection, section?.1)
        let (identity, identityReason) = minimize(identifier: target.elementID, label: target.label)
        note(.targetElement, identityReason)
        let role = target.role.map { minimize(text: $0) }
        note(.targetElement, role?.1)
        return (OperationCheck.Target(elementID: identity, role: role?.0, label: label, section: section?.0), gaps)
    }

    /// An effect with its title and labels minimized and its family and states kept, so it is still an
    /// effect of its kind and its encoding still decodes (the marker holds no separator); and the
    /// reason when something was withheld.
    public func minimize(effect: SceneEffect) -> (SceneEffect, WithholdingReason?) {
        func list(_ labels: [String]) -> ([String], WithholdingReason?) {
            var reason: WithholdingReason?
            let kept = labels.map { label -> String in
                let (minimized, why) = minimize(text: label)
                reason = reason ?? why
                return minimized
            }
            return (kept, reason)
        }
        switch effect {
            case .windowTitleChanged(let title):
                let (kept, reason) = minimize(text: title)
                return (.windowTitleChanged(title: kept), reason)
            case .menuOpened(let labels):
                let (kept, reason) = list(labels)
                return (.menuOpened(labels: kept), reason)
            case .elementsAppeared(let labels):
                let (kept, reason) = list(labels)
                return (.elementsAppeared(labels: kept), reason)
            case .elementsDisappeared(let labels):
                let (kept, reason) = list(labels)
                return (.elementsDisappeared(labels: kept), reason)
            case .stateFlip, .textSelectionChanged:
                return (effect, nil)
        }
    }

    /// A listing with every application's name, location and version and every window's title
    /// minimized; one gap per application something was withheld from.
    public func minimize(listing: ListingResult, eventID: String) -> (ListingResult, [ValueRedaction]) {
        var gaps: [ValueRedaction] = []
        let applications = listing.applications.enumerated().map { position, application -> ListedApplication in
            var reason: WithholdingReason?
            func scrub(_ text: String) -> String {
                let (kept, why) = minimize(text: text)
                reason = reason ?? why
                return kept
            }
            let kept = ListedApplication(
                name            : scrub(application.name),
                bundleID        : application.bundleID,
                pid             : application.pid,
                version         : application.version.map(scrub),
                isRunning       : application.isRunning,
                location        : application.location.map(scrub),
                isDefaultBrowser: application.isDefaultBrowser,
                windows         : application.windows.map {
                    ListedWindow(number: $0.number, title: $0.title.map(scrub))
                }
            )
            if let reason {
                gaps.append(ValueRedaction(
                    eventID : eventID,
                    location: .listingEntry(application: position),
                    reason  : reason
                ))
            }
            return kept
        }
        return (ListingResult(kind: listing.kind, applications: applications, hiddenCount: listing.hiddenCount), gaps)
    }

    /// A call's result with its message or listing minimized, and the gaps it leaves.
    public func minimize(result: AgentCallResult?, eventID: String) -> (AgentCallResult?, [ValueRedaction]) {
        func scrub(_ message: String) -> (String, [ValueRedaction]) {
            let (kept, reason) = minimize(text: message)
            return (kept, reason.map { [ValueRedaction(eventID: eventID, location: .resultMessage, reason: $0)] } ?? [])
        }
        switch result {
            case .outcome(let kind, let message)?:
                let (kept, gap) = scrub(message)
                return (.outcome(kind, message: kept), gap)
            case .error(let message)?:
                let (kept, gap) = scrub(message)
                return (.error(message: kept), gap)
            case .closed(let message)?:
                let (kept, gap) = scrub(message)
                return (.closed(message: kept), gap)
            case .listing(let listing)?:
                let (kept, gaps) = minimize(listing: listing, eventID: eventID)
                return (.listing(kept), gaps)
            default:
                return (result, [])
        }
    }

    /// An observed effect with its title and labels minimized, as `minimize(effect:)` does.
    public func minimize(observed: ObservedEffect, eventID: String) -> (ObservedEffect, [ValueRedaction]) {
        let (kept, reason) = minimize(effect: observed.sceneEffect)
        guard let reason else { return (observed, []) }
        return (ObservedEffect(kept), [ValueRedaction(eventID: eventID, location: .observedEffect, reason: reason)])
    }

    // MARK: Brains

    /// A Brain application as an earlier build recorded it, admitted as a live one is made: the window
    /// and every label minimized, a name minimized; nil when its effect held a value this withholds,
    /// since learning it would teach the Brain to predict the marker. The flag says something was
    /// withheld.
    public func minimize(application command: BrainApplicationCommand) throws -> (BrainApplicationCommand?, Bool) {
        var withheld = false
        func scrub(_ text: String) -> String {
            let (kept, reason) = minimize(text: text)
            if reason != nil { withheld = true }
            return kept
        }
        func scrub(_ detection: BrainDetection) -> BrainDetection {
            var kept = detection
            kept.label = scrub(detection.label)
            return kept
        }
        let input: BrainApplicationCommand.Input
        switch command.input {
            case .observe(let window, let detections):
                input = .observe(window: window.map(scrub), detections: detections.map(scrub))
            case .record(let verb, let target, let effect):
                if let effect, ([effect.text].compactMap { $0 } + effect.items).contains(where: {
                    minimize(text: $0).1 != nil
                }) {
                    return (nil, true)
                }
                input = .record(verb: verb, target: scrub(target), effect: effect)
            case .setName(let anchorKey, let name):
                input = .setName(anchorKey: anchorKey, name: scrub(name))
        }
        let kept = try BrainApplicationCommand(key: command.key, bundleID: command.bundleID,
                                               requestedAtMS: command.requestedAtMS, input: input)
        return (kept, withheld)
    }

    /// BrainWithholding is what minimizing a Brain withheld: the anchors and groups whose texts it
    /// changed, by identity, and the transitions it left out, with their effect minimized, because a
    /// transition whose effect held a withheld value would be a prediction of the marker.
    public struct BrainWithholding: Sendable, Equatable {
        public var anchors: Set<String> = []
        public var groups: Set<UUID> = []
        public var transitions: [LearnedTransition] = []

        public init() {}

        public var isEmpty: Bool { anchors.isEmpty && groups.isEmpty && transitions.isEmpty }
    }

    /// A Brain admitted as a live one would have learned it: its anchors' labels, aliases and window
    /// families and its groups' names minimized, and the transitions whose effect held a withheld value
    /// left out; an effect that does not decode is left as it is, for the projection to judge.
    public func minimize(brain: UIBrain) -> (UIBrain, BrainWithholding) {
        var kept = brain
        var withheld = BrainWithholding()
        for index in kept.objects.indices {
            let anchor = kept.objects[index]
            var changed = false
            func scrub(_ text: String) -> String {
                let (minimized, reason) = minimize(text: text)
                if reason != nil { changed = true }
                return minimized
            }
            kept.objects[index].label   = scrub(anchor.label)
            kept.objects[index].aliases = anchor.aliases.map(scrub)
            kept.objects[index].window  = anchor.window.map(scrub)
            if changed { withheld.anchors.insert(anchor.anchorKey) }
        }
        for index in kept.groups.indices {
            guard let name = kept.groups[index].name else { continue }
            let (minimized, reason) = minimize(text: name)
            guard reason != nil else { continue }
            kept.groups[index].name = minimized
            withheld.groups.insert(kept.groups[index].id)
        }
        kept.transitions = brain.transitions.filter { transition in
            guard let effect = SceneEffect(encoded: transition.effect) else { return true }
            let (minimized, reason) = minimize(effect: effect)
            guard reason != nil else { return true }
            var left = transition
            left.effect = minimized.encoded
            withheld.transitions.append(left)
            return false
        }
        return (kept, withheld)
    }

    /// A text with the secrets withheld from earlier arguments added to the declared ones.
    public func adding(secrets more: [String]) -> ValueMinimization {
        ValueMinimization(secrets: secrets + more.filter { !secrets.contains($0) })
    }

    // MARK: Rules

    /// Whether a control's name says it holds a secret: a password, a passcode, a PIN, a token, an
    /// API key, a one-time or security code, a card's verification number, in English or Italian.
    public static func namesSecret(_ label: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let joined = words.joined(separator: " ")
        let single: Set<String> = ["password", "passwd", "passcode", "passphrase", "pin", "token", "secret", "otp",
                                   "cvv", "cvc", "apikey", "totp", "2fa", "mfa"]
        if words.contains(where: single.contains) { return true }
        let phrases = ["api key", "access key", "secret key", "private key", "security code", "verification code",
                       "one time code", "auth code", "parola d ordine", "codice segreto", "codice di sicurezza",
                       "codice di verifica", "chiave api", "chiave segreta"]
        return phrases.contains { joined.contains($0) }
    }

    /// The text with every credential shape replaced by the marker, and whether any was found: private
    /// keys, well-known token prefixes (`sk-`, `ghp_`, `github_pat_`, `xox?-`, `AKIA`, `AIza`), JSON
    /// web tokens, and long mixed-case alphanumeric strings that read as generated keys.
    public static func scrubCredentials(_ text: String) -> (String, Bool) {
        // The shortest shape searched for is a Slack token's 15 characters: a shorter text holds none.
        guard text.utf8.count >= 15 else { return (text, false) }
        var kept  = text
        var found = false
        for pattern in credentialPatterns {
            let range = NSRange(kept.startIndex..., in: kept)
            guard pattern.firstMatch(in: kept, range: range) != nil else { continue }
            kept  = pattern.stringByReplacingMatches(in: kept, range: range, withTemplate: marker)
            found = true
        }
        var tokens: [String] = []
        var changed = false
        for token in kept.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            if looksGenerated(token) { tokens.append(marker); changed = true } else { tokens.append(token) }
        }
        if changed { kept = tokens.joined(separator: " "); found = true }
        return (kept, found)
    }

    /// Whether a text has a credential's shape anywhere in it.
    public static func hasCredentialShape(_ text: String) -> Bool { scrubCredentials(text).1 }

    /// A word of 32 or more characters drawn from a key's alphabet, with upper case, lower case and
    /// digits all present: how generated keys look, and how file names, paths and hashes do not.
    static func looksGenerated(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:()[]{}<>"))
        guard trimmed.count >= 32, trimmed != marker else { return false }
        let alphabet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-"))
        guard trimmed.unicodeScalars.allSatisfy({ alphabet.contains($0) && $0.isASCII }) else { return false }
        let upper = trimmed.contains { $0.isUppercase }, lower = trimmed.contains { $0.isLowercase }
        let digit = trimmed.contains { $0.isNumber }
        return upper && lower && digit
    }

    private static let credentialPatterns: [NSRegularExpression] = [
        "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)",
        "\\bsk-(ant-)?[A-Za-z0-9_-]{16,}",
        "\\bgh[pousr]_[A-Za-z0-9]{30,}",
        "\\bgithub_pat_[A-Za-z0-9_]{20,}",
        "\\bxox[abposr]-[A-Za-z0-9-]{10,}",
        "\\bAKIA[0-9A-Z]{16}\\b",
        "\\bAIza[0-9A-Za-z_-]{35}\\b",
        "\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}",
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}
