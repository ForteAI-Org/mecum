//
//  FactContractTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import CoreGraphics
import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// The G76 D1 contracts on their own: the task an agent communicates, the operation facts and their
/// verification, and what is withheld before anything is kept. The secrets here are synthetic canaries.
@Suite("Task, operation fact and minimization contracts")
struct FactContractTests {

    static let canaryToken    = "sk-test-CANARY0123456789abcdefXYZ"
    static let canaryPassword = "Canary-Pass-7419"

    // MARK: TaskContext

    @Test("a task's revision refuses an empty goal, a duplicate input, a secret with its text, a previous output with no source")
    func revisionRefusals() throws {
        #expect(throws: TaskContextError.invalid(.emptyText(field: "goal"))) { _ = try TaskRevisionContent(goal: "  ") }
        let input = try TaskValue(name: "file", kind: .text, content: .text("foto.png"), source: .request)
        #expect(throws: TaskContextError.invalid(.duplicate(field: "inputs"))) {
            _ = try TaskRevisionContent(goal: "export", inputs: [input, input])
        }
        #expect(throws: TaskContextError.invalid(.secretKept(name: "pin"))) {
            _ = try TaskValue(name: "pin", kind: .text, content: .text("1234"), sensitivity: .secret, source: .request)
        }
        #expect(throws: TaskContextError.invalid(.previousOutputWithoutReference(name: "doc"))) {
            _ = try TaskValue(name: "doc", kind: .file, content: .text("/tmp/a"), source: .previousOutput)
        }
        #expect(throws: TaskContextError.invalid(.missingMismatch(name: "format"))) {
            _ = try TaskValue(name: "format", kind: .text, content: .missing, source: .request)
        }
        let missing = try TaskValue(name: "format", kind: .missing, content: .missing, source: .unknown)
        #expect(try TaskRevisionContent(goal: "export", inputs: [missing]).inputs.first?.content == .missing)
        #expect(throws: TaskContextError.invalid(.tooLong(field: "goal"))) {
            _ = try TaskRevisionContent(goal: String(repeating: "a", count: TaskContextContract.maximumTextBytes + 1))
        }
    }

    @Test("a revision, an attempt and an end keep their order: revision 1 opens, a resumption names what it resumes, an end declares a closed status")
    func lifecycleShapes() throws {
        let content = try TaskRevisionContent(goal: "export")
        #expect(throws: TaskContextError.invalid(.revisionChangeMismatch)) {
            _ = try TaskRevision(taskID: "t", revision: 2, recordedAtMS: 0, change: .opened, content: content)
        }
        let producer = try TaskProducer(source: .mcp, streamID: "mcp-1")
        #expect(throws: TaskContextError.invalid(.resumptionMismatch)) {
            _ = try TaskAttempt(
                attemptID: "a2",
                taskID: "t",
                ordinal: 2,
                resumes: nil,
                producer: producer,
                openedAtMS: 0,
                openedAtRevision: 1
            )
        }
        #expect(throws: TaskContextError.invalid(.declarationMismatch)) { _ = try TaskCheckpointDraft(kind: .end) }
        #expect(throws: TaskContextError.invalid(.declarationMismatch)) {
            _ = try TaskCheckpointDraft(kind: .end, declared: .open)
        }
        #expect(throws: TaskContextError.invalid(.declarationMismatch)) {
            _ = try TaskCheckpointDraft(kind: .checkpoint, declared: .completed)
        }
        let output = try TaskValue(name: "out", kind: .missing, content: .missing, source: .derived)
        #expect(throws: TaskContextError.invalid(.missingOutput)) {
            _ = try TaskCheckpointDraft(kind: .checkpoint, outputs: [output])
        }
    }

    // MARK: Operation facts

    @Test("a verification has its own event of kind verification, a call other than itself, distinct samples; its identity follows call and condition")
    func verificationShape() throws {
        let check = OperationCheck(condition: .valueReadBack, method: .controlValue, verdict: .passed, expected: "a",
                                   observed: "a", performed: .requested)
        let call  = "call-1"
        let id    = OperationVerification.eventID(call: call, condition: .valueReadBack)
        #expect(id == "call-1/verification/value_read_back")
        let action = MemoryEventRecord(eventID: id, source: .app, streamID: "w", kind: .action, occurredAtMS: 0)
        #expect(throws: OperationFactError.invalid(.notAVerification)) {
            _ = try OperationVerification(event: action, callEventID: call, check: check, samples: [])
        }
        var event = action
        event.kind = .verification
        #expect(throws: OperationFactError.invalid(.emptyText(field: "call"))) {
            _ = try OperationVerification(event: event, callEventID: id, check: check, samples: [])
        }
        let key = CaptureSampleKey(eventID: call, phase: .after)
        #expect(throws: OperationFactError.invalid(.duplicateSample)) {
            _ = try OperationVerification(event: event, callEventID: call, check: check, samples: [key, key])
        }
        let verification = try OperationVerification(event: event, callEventID: call, check: check, samples: [key])
        let record = try verification.record()
        #expect(record.scope == .call && record.method == .controlValue && record.verdict == .passed)
    }

    @Test("the verdict is the oracle's: a scene difference that changed nothing structural is unknown, an identical scene failed, another family failed")
    func sceneDifferenceVerdicts() {
        let target = OperationCheck.Target(elementID: "e", role: "AXButton", label: "Export", section: nil)
        let unknown = OperationCheck.sceneDifference(.unattributable, expected: nil, target: target)
        #expect(unknown.verdict == .unknown && unknown.limits == [.noExpectation, .unattributed])
        let ghost = OperationCheck.sceneDifference(.ghost, expected: .menuOpened(labels: ["A"]), target: target)
        #expect(ghost.verdict == .failed && ghost.observed == "unchanged" && ghost.limits.isEmpty)
        let other = OperationCheck.sceneDifference(.landed(.elementsAppeared(labels: ["X"]), matchesExpectation: false),
                                                   expected: .menuOpened(labels: ["A"]), target: target)
        #expect(other.verdict == .failed && other.expected == "menuOpened" && other.observed == "elementsAppeared")
        let landed = OperationCheck.sceneDifference(.landed(.menuOpened(labels: ["A"]), matchesExpectation: true),
                                                    expected: nil, target: target, limits: [.windowWide])
        #expect(landed.verdict == .passed && landed.limits == [.windowWide, .noExpectation])
    }

    @Test("an outcome with no stated check says no gesture went out for a refusal, a miss or a no-op, and unknown for a claim without a check")
    func statedChecks() {
        #expect(ActOutcome(.honestMiss, "no").withStatedCheck.check == .unchecked(
            performed: .none,
            limits: [.targetNotResolved]
        ))
        #expect(ActOutcome(.refused, "no").withStatedCheck.check?.performed == OperationCheck.Performed.none)
        #expect(ActOutcome(.actedNoop, "listing").withStatedCheck.check?.verdict == .unknown)
        let claimed = ActOutcome(.foundActed, "done").withStatedCheck.check
        #expect(claimed?.verdict == .unknown && claimed?.performed == .uncertain,
                "a success with no check is never a pass")
        let stated = OperationCheck(
            condition: .stateAfterGesture,
            method: .controlState,
            verdict: .passed,
            performed: .requested
        )
        #expect(ActOutcome(.foundActed, "set", check: stated).withStatedCheck.check == stated)
    }

    @Test("an effect names a substitute only when one went out and a reason only when none did")
    func effectShape() throws {
        #expect(throws: OperationFactError.invalid(.substituteMismatch)) {
            _ = try OperationEffect(callEventID: "c", performed: .substitute, checked: true)
        }
        #expect(throws: OperationFactError.invalid(.reasonWithGesture)) {
            _ = try OperationEffect(
                callEventID: "c",
                performed: .requested,
                notSentReason: "honest_miss",
                checked: true
            )
        }
        #expect(try OperationEffect(
            callEventID: "c",
            performed: .substitute,
            substitute: "escape",
            checked: true
        ).substitute == "escape")
    }

    // MARK: Minimization

    @Test("credential shapes are withheld from any text: a token prefix, a private key, a JWT, a generated key; ordinary texts stay")
    func credentialShapes() {
        let minimization = ValueMinimization()
        for secret in [Self.canaryToken, "ghp_" + String(repeating: "A1b2", count: 9), "AKIAABCDEFGHIJKLMNOP",
                       "xoxb-123456789012-abcdef",
                       "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N",
                       "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----",
                       "Qx7Lm2Np9Rs4Tv6Wy8Zb1Cd3Fg5Hj7Kk9M"] {
            let (kept, reason) = minimization.minimize(text: "key: \(secret) end")
            #expect(reason == .credentialPattern && !kept.contains(secret), "\(secret.prefix(8))…")
        }
        for ordinary in ["foto_web.jpg", "Export as PNG", "/Users/me/Pictures/IMG_20260101_123456.jpg",
                         "3f2a9b1c4d5e6f708192a3b4c5d6e7f8091a2b3c", "5D0C2F2E-0000-4000-8000-000000000001"] {
            #expect(minimization.minimize(text: ordinary) == (ordinary, nil), "\(ordinary)")
        }
    }

    @Test("a text typed into a control named for a secret is withheld whole; a declared secret is withheld wherever it appears")
    func secretTargetsAndDeclaredSecrets() {
        let minimization = ValueMinimization(secrets: [Self.canaryPassword])
        let (request, gaps) = minimization.minimize(
            .typeText(target: "Password", text: "anything typed", section: nil, replace: true),
            eventID: "c1"
        )
        if case .typeText(_, let text, _, _) = request {
            #expect(text == ValueMinimization.marker)
        } else {
            Issue.record("shape")
        }
        #expect(gaps == [ValueRedaction(
            eventID: "c1",
            location: .argument(name: "text", position: 0),
            reason: .secretTarget
        )])
        for label in ["Password", "Parola d'ordine", "API key", "Codice di verifica", "PIN", "One-time code"] {
            #expect(ValueMinimization.namesSecret(label), "\(label)")
        }
        for label in ["Name", "Pinned items", "Spinner", "File name", "Opinion"] {
            #expect(!ValueMinimization.namesSecret(label), "\(label)")
        }
        let (message, reason) = minimization.minimize(text: "the field reads '\(Self.canaryPassword)'")
        #expect(reason == .declaredSecret && !message.contains(Self.canaryPassword))
        let (inserted, insertGaps) = minimization.minimize(
            .insertText(text: Self.canaryPassword, expectedValue: Self.canaryPassword),
            eventID: "c2"
        )
        if case .insertText(let text, let expected) = inserted {
            #expect(text == ValueMinimization.marker && expected == ValueMinimization.marker)
        }
        #expect(insertGaps.count == 2)
    }

    @Test("a declared secret is withheld however short, inside a longer text, longest first, and never from inside a marker")
    func declaredSecretsOfAnyLength() {
        let pin = ValueMinimization(secrets: ["731"]).minimize(text: "The PIN is 731")
        #expect(pin.0 == "The PIN is [withheld]" && pin.1 == .declaredSecret)
        let nested = ValueMinimization(secrets: ["abc", "abcdef"]).minimize(text: "use abcdef, then abc")
        #expect(nested.0 == "use [withheld], then [withheld]", "the longer secret leaves no piece of itself")
        let insideMarker = ValueMinimization(secrets: ["731", "held"]).minimize(text: "731 and 731")
        #expect(insideMarker.0 == "[withheld] and [withheld]", "a secret that is part of the marker leaves it whole")
        #expect(ValueMinimization(secrets: ["731"]).minimize(text: "nothing here").1 == nil)
    }

    @Test("review F02a: an identity is minimized as its label is, normalized; a target's label, section, identity and role each leave their own gap")
    func identitiesAndTargets() {
        let secret = "Review-Target-Canary-7319"
        let minimization = ValueMinimization(secrets: [secret])
        let label = "Key \(Self.canaryToken)"
        let identity = SceneIdentity.key(kind: .control, label: label,
                                         bounds: NormalizedRect(x: 0, y: 0, width: 0, height: 0), isUnlabeled: false)
        let (kept, reason) = minimization.minimize(identifier: identity, label: label)
        #expect(reason == .credentialPattern)
        #expect(kept == SceneIdentity.key(kind: .control, label: minimization.minimize(text: label).0,
                                          bounds: NormalizedRect(x: 0, y: 0, width: 0, height: 0), isUnlabeled: false),
                "the identity perception would give the minimized label")
        let normalized = minimization.minimize(identifier: "row|\(LabelText.normalize(secret))", label: nil)
        #expect(normalized.1 == .declaredSecret && !normalized.0.contains(LabelText.normalize(secret)))
        #expect(minimization.minimize(identifier: "control|save", label: "Save") == ("control|save", nil))
        let (target, gaps) = minimization.minimize(
            target: OperationCheck.Target(elementID: "control|save", role: "AXButton", label: "Save",
                                          section: "Settings for \(secret)"),
            eventID: "c1"
        )
        #expect(target.label == "Save" && target.section == "Settings for [withheld]"
                && target.elementID == "control|save")
        #expect(gaps == [ValueRedaction(eventID: "c1", location: .targetSection, reason: .declaredSecret)])
    }

    @Test("review F02b: an effect keeps its family and states with its titles and labels minimized, and its encoding still decodes")
    func effects() {
        let minimization = ValueMinimization(secrets: [Self.canaryPassword])
        let menu = minimization.minimize(effect: .menuOpened(labels: ["Use \(Self.canaryPassword)", "Cancel"]))
        #expect(menu.0 == .menuOpened(labels: ["Use [withheld]", "Cancel"]) && menu.1 == .declaredSecret)
        #expect(SceneEffect(encoded: menu.0.encoded) == menu.0)
        let title = minimization.minimize(effect: .windowTitleChanged(title: "Token \(Self.canaryToken)"))
        #expect(title.0 == .windowTitleChanged(title: "Token [withheld]") && title.1 == .credentialPattern)
        #expect(minimization.minimize(effect: .stateFlip(from: .off, to: .on))
                == (.stateFlip(from: .off, to: .on), nil))
        #expect(minimization.minimize(effect: .elementsAppeared(labels: ["Open"])).1 == nil)
    }

    @Test("every text of a scene element is minimized and its identity follows its label; a sample's container path leaves its own gap")
    func elementsAndContainers() throws {
        let minimization = ValueMinimization(secrets: [Self.canaryPassword])
        var element = SceneElement(id: "control|open", kind: .control, label: "Open",
                                   bounds: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1), role: "AXButton")
        element.container = "Vault \(Self.canaryPassword)"
        element.section   = "Section \(Self.canaryPassword)"
        element.value     = Self.canaryPassword
        let (kept, withheld) = minimization.minimize(element: element)
        #expect(withheld && kept.label == "Open" && kept.id == "control|open")
        #expect([kept.container, kept.section, kept.value].allSatisfy { !($0 ?? "").contains(Self.canaryPassword) })
        let sample = CaptureSample(
            key: CaptureSampleKey(eventID: "e1", phase: .after),
            windowTitle: "Doc", sessionRevision: nil, surface: .window,
            quality: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true,
                                    windowRole: "AXWindow", nodesVisited: 2, elementsEmitted: 1),
            elements: [CaptureElement(kind: .control, role: "AXButton", label: "Open", labelOrigin: .title,
                                      containerPath: "AXWindow/AXGroup:Vault \(Self.canaryPassword)",
                                      isUnderCollection: false, state: nil,
                                      bounds: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1))]
        )
        let (minimized, gaps) = minimization.minimize(sample: sample)
        #expect(!minimized.elements[0].containerPath.contains(Self.canaryPassword))
        #expect(gaps == [ValueRedaction(
            eventID: "e1",
            location: .sampleContainer(phase: .after, ordinal: 0, element: 0),
            reason: .declaredSecret
        )])
    }

    @Test("review F02c: a Brain is admitted as a live one would have learned it: credential shapes withheld from labels, aliases, windows and group names, a transition whose effect held one left out")
    func brains() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        var shaped = ObjectAnchor(kind: .control, label: "Key \(Self.canaryToken)",
                                  boundsTypical: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                  firstSeen: now, lastSeen: now)
        shaped.aliases = ["Old \(Self.canaryToken)"]
        let plain = ObjectAnchor(kind: .control, label: "Open",
                                 boundsTypical: NormalizedRect(x: 0.2, y: 0, width: 0.1, height: 0.1),
                                 firstSeen: now, lastSeen: now)
        let leaking = LearnedTransition(anchorKey: plain.anchorKey, trigger: .click,
                                        effect: SceneEffect.menuOpened(labels: ["Paste \(Self.canaryToken)"]).encoded,
                                        evidence: 3, lastObserved: now)
        let kept = LearnedTransition(anchorKey: plain.anchorKey, trigger: .click,
                                     effect: SceneEffect.menuOpened(labels: ["New", "Recent"]).encoded,
                                     evidence: 2, lastObserved: now)
        let (admitted, withheld) = ValueMinimization().minimize(
            brain: UIBrain(objects: [shaped, plain], transitions: [leaking, kept])
        )
        #expect(admitted.objects.map(\.label) == ["Key [withheld]", "Open"]
                && admitted.objects[0].aliases == ["Old [withheld]"])
        #expect(admitted.transitions == [kept])
        #expect(withheld.anchors == [shaped.anchorKey] && withheld.transitions.count == 1)
        #expect(!withheld.transitions[0].effect.contains(Self.canaryToken), "what is journaled of it is minimized too")
    }

    @Test("a Brain application of an earlier build is admitted as a live one is made: labels minimized, one whose effect held a withheld value refused")
    func applications() throws {
        let rules = ValueMinimization()
        let detection = BrainDetection(kind: .control, label: "Key \(Self.canaryToken)",
                                       bounds: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1))
        let observe = try BrainApplicationCommand(
            key: .observe(CaptureSampleKey(eventID: "e1", phase: .current)), bundleID: "test.app", requestedAtMS: 1,
            input: .observe(window: "Doc", detections: [detection])
        )
        let (admitted, withheld) = try rules.minimize(application: observe)
        guard case .observe(_, let detections)? = admitted?.input else {
            Issue.record("the observation was not admitted")
            return
        }
        #expect(withheld && detections.map(\.label) == ["Key [withheld]"])
        let record = try BrainApplicationCommand(
            key: .record(eventID: "e2"), bundleID: "test.app", requestedAtMS: 1,
            input: .record(
                verb: .click,
                target: BrainDetection(kind: .control, label: "Open", bounds: detection.bounds),
                effect: try TransitionEffectRecord(
                    effect: SceneEffect.menuOpened(labels: ["Paste \(Self.canaryToken)"]).encoded
                )
            )
        )
        let refused = try rules.minimize(application: record)
        #expect(refused.0 == nil && refused.1)
    }

    @Test("the number after a revision or an attempt is refused past the largest integer, never wrapped or trapped")
    func successorAtTheLimit() throws {
        #expect(try TaskContextContract.successor(of: 1, field: "revision") == 2)
        #expect(throws: TaskContextError.invalid(.outOfRange(field: "revision"))) {
            _ = try TaskContextContract.successor(of: Int.max, field: "revision")
        }
    }

    @Test("a sample's labels and title are minimized with their gaps declared by position; the rest of the sample is kept")
    func sampleMinimization() throws {
        let minimization = ValueMinimization(secrets: [Self.canaryPassword])
        let window = PerceivedWindow(
            scene: SceneSnapshot(
                bundleID: "test.app",
                appName: "App",
                windowTitle: "Login \(Self.canaryToken)",
                viewportPixelSize: ViewportPixelSize(width: 100, height: 100),
                elements: [
                    SceneElement(
                        id: "a",
                        kind: .control,
                        label: "Sign in",
                        bounds: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1),
                        role: "AXButton"
                    ),
                    SceneElement(
                        id: "b",
                        kind: .control,
                        label: Self.canaryPassword,
                        bounds: NormalizedRect(x: 0.2, y: 0, width: 0.1, height: 0.1),
                        role: "AXTextField",
                        labelOrigin: .value
                    )
                ]
            ),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            capture: CaptureQuality(
                walkCompleted: true,
                windowFound: true,
                isGrantAvailable: true,
                windowRole: "AXWindow",
                nodesVisited: 3,
                elementsEmitted: 2
            ),
            surface: .window
        )
        let sample = CaptureSample(key: CaptureSampleKey(eventID: "e", phase: .after), of: window, sessionRevision: nil)
        let (kept, gaps) = minimization.minimize(sample: sample)
        #expect(kept.windowTitle?.contains(Self.canaryToken) == false)
        #expect(kept.elements.allSatisfy { !$0.label.contains(Self.canaryPassword) })
        #expect(kept.elements.contains { $0.label == "Sign in" })
        #expect(gaps.contains(ValueRedaction(
            eventID: "e",
            location: .sampleTitle(phase: .after, ordinal: 0),
            reason: .credentialPattern
        )))
        #expect(gaps.contains {
            if case .sampleLabel(.after, 0, _) = $0.location { $0.reason == .declaredSecret } else { false }
        })
        let scene = minimization.minimize(scene: window.scene)
        #expect(!scene.windowTitle.contains(Self.canaryToken)
                && scene.elements.allSatisfy { !$0.label.contains(Self.canaryPassword) })
    }
}
