//
//  CompactSceneTextTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/10/2026.
//

import Foundation
@testable import PerceptionCore
import Testing

/// The compact scene text a model reads: what it leaves out, and that it leaves out nothing a target
/// is resolved by. The resolver is the oracle: a target read back from the printed text finds the
/// same element as the label or id the scene printed before.
@Suite("Compact scene text")
struct CompactSceneTextTests {

    private static func rect(_ x: Double, _ y: Double, _ w: Double = 0.1, _ h: Double = 0.03) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    private static func control(
        _ label    : String,
        _ x        : Double,
        _ y        : Double,
        container  : String? = nil,
        section    : String? = "content"
    ) -> SceneElement {
        SceneElement(
            id       : "control|" + label.lowercased().filter { !$0.isWhitespace },
            kind     : .control,
            label    : label,
            bounds   : rect(x, y),
            container: container,
            section  : section
        )
    }

    private static func icon(
        _ x       : Double,
        _ y       : Double,
        section   : String? = "content",
        state     : ControlState? = nil
    ) -> SceneElement {
        let bounds = rect(x, y, 0.02, 0.02)
        return SceneElement(
            id         : SceneIdentity.key(kind: .icon, label: "", bounds: bounds, isUnlabeled: true),
            kind       : .icon,
            label      : "(unlabeled)",
            bounds     : bounds,
            state      : state,
            isUnlabeled: true,
            section    : section
        )
    }

    private static func scene(_ elements: [SceneElement], sections: [String] = ["content"]) -> SceneSnapshot {
        SceneSnapshot(
            bundleID         : "com.example.app",
            appName          : "Example",
            windowTitle      : "Doc",
            viewportPixelSize: ViewportPixelSize(width: 1000, height: 800),
            elements         : elements,
            sections         : sections.map { SceneSection(name: $0, bounds: rect(0, 0, 1, 1)) }
        )
    }

    @Test("a position prints as the whole percent its two-decimal print showed")
    func percentsMatchTheTwoDecimalPrint() {
        let edges: [(Double, Int)] = [(0, 0), (0.125, 12), (0.135, 14), (0.005, 1), (0.995, 99), (1, 100), (-0.001, 0)]
        for (value, percent) in edges {
            #expect(SceneSnapshot.percent(value) == percent, "\(value)")
        }
        var value = 0.0
        while value <= 1 {
            #expect(String(format: "%.2f", Double(SceneSnapshot.percent(value)) / 100) == String(format: "%.2f", value))
            value += 0.0037
        }
        #expect(SceneSnapshot.percent(.nan) == 0)
    }

    @Test("the header is one line and a section line carries its place and size in percent")
    func headerAndSectionLines() {
        var scene = Self.scene([Self.control("Save", 0.123, 0.456)])
        scene.sections[0].bounds = Self.rect(0.0449, 0.5, 0.3, 0.255)
        scene.sections[0].verticalScrollNote = "scrolls ↓"
        #expect(scene.text() == """
            Example (com.example.app) "Doc" 1000x800, 1 elements
            ## content @4,50 30x26 · scrolls ↓
            [control] Save @12,46

            """)
    }

    @Test("a container prints where it changes in a section, and {} where it returns to none")
    func containerPrintsOnChange() {
        let scene = Self.scene([
            Self.control("A1", 0.1, 0.10, container: "Left"),
            Self.control("A2", 0.1, 0.20, container: "Left"),
            Self.control("B1", 0.1, 0.30, container: "Right"),
            Self.control("C1", 0.1, 0.40),
            Self.control("C2", 0.1, 0.50),
            Self.control("D1", 0.1, 0.60, container: "Right"),
        ], sections: ["content", "other"])
        let lines = scene.text().split(separator: "\n").map(String.init)
        #expect(lines.dropFirst(2) == [
            "[control] A1 {Left} @10,10",
            "[control] A2 @10,20",
            "[control] B1 {Right} @10,30",
            "[control] C1 {} @10,40",
            "[control] C2 @10,50",
            "[control] D1 {Right} @10,60",
            "## other @0,0 100x100",
        ])
        // Each section starts from none.
        var second = scene
        second.elements[5].section = "other"
        #expect(second.text().contains("## other @0,0 100x100\n[control] D1 {Right} @10,60"))
    }

    @Test("a label owned by two containers prints its container on every line, so a copied line still resolves")
    func sharedLabelsKeepTheirContainer() {
        let scene = Self.scene([
            Self.control("Solo", 0.1, 0.10, container: "Track 1"),
            Self.control("Mute", 0.1, 0.20, container: "Track 1"),
            Self.control("Mute", 0.1, 0.30, container: "Track 2"),
        ])
        let body = scene.text().split(separator: "\n").dropFirst(2).map(String.init)
        #expect(body == [
            "[control] Solo {Track 1} @10,10",
            "[control] Mute {Track 1} @10,20",
            "[control] Mute {Track 2} @10,30",
        ])
        #expect(scene.resolve(target: "Mute {Track 1}") == .found(scene.elements[1]))
        #expect(scene.resolve(target: "Mute") == .ambiguous(2))
    }

    @Test("plain unlabeled icons share one line: a unique id keeps its place, a shared id keeps its count")
    func unlabeledIconsShareALine() {
        let scene = Self.scene([
            Self.icon(0.09, 0.01), Self.icon(0.12, 0.01), Self.icon(0.15, 0.01), Self.icon(0.31, 0.02),
            Self.icon(0.31, 0.50, state: .off),
            Self.control("Save", 0.5, 0.5),
        ])
        let lines = scene.text().split(separator: "\n").dropFirst(2).map(String.init)
        // ?|@1,0 is shared by 0.09 and 0.12 (cells round to a tenth); the stateful icon keeps its own line.
        #expect(lines == [
            "[icon?] id:'?|@3,5' [off] @31,50",
            "[control] Save @50,50",
            "icons: ?|@1,0×2 ?|@2,0@15,1 ?|@3,0@31,2",
        ])
        #expect(!scene.text().contains("(unlabeled)"))
    }

    @Test("a text line that could read as a tag or another line keeps its tag")
    func ambiguousTextKeepsItsTag() {
        let texts = ["[Draft] title", "## heading", "icons: none", "commands today", "plain"].enumerated().map {
            SceneElement(id: "text|\($0.offset)", kind: .text, label: $0.element,
                         bounds: Self.rect(0.1, 0.1 * Double($0.offset)), section: "content")
        }
        let lines = Self.scene(texts).text().split(separator: "\n").dropFirst(2).map(String.init)
        #expect(lines == [
            "[text] [Draft] title @10,0", "[text] ## heading @10,10", "[text] icons: none @10,20",
            "[text] commands today @10,30", "plain @10,40",
        ])
    }

    @Test("every element of a synthetic scene resolves by the target its printed line gives, as before")
    func resolvesByWhatIsPrinted() throws {
        let scene = Self.scene([
            Self.control("Save", 0.1, 0.1, container: "Doc"),
            Self.control("Export", 0.1, 0.2, container: "Doc"),
            SceneElement(id: "control|name", kind: .control, label: "Name", bounds: Self.rect(0.4, 0.1),
                         role: "AXTextField", value: "Untitled", section: "content"),
            SceneElement(id: "text|hello", kind: .text, label: "Hello there", bounds: Self.rect(0.4, 0.3),
                         section: "content"),
            Self.icon(0.60, 0.05), Self.icon(0.65, 0.05), Self.icon(0.66, 0.05), Self.icon(0.90, 0.90),
            Self.control("Mute", 0.7, 0.4, container: "Track 1", section: "other"),
            Self.control("Mute", 0.7, 0.5, container: "Track 2", section: "other"),
        ], sections: ["content", "other"])
        let report = try Self.resolutionReport(of: scene)
        #expect(report.mismatches.isEmpty, "\(report.mismatches)")
        #expect(report.checked == scene.elements.count)
    }

    /// With `MECUM_SCENE_SAMPLES` naming a folder of scene JSON files, each is checked the same way.
    @Test(
        "every element of each scene in MECUM_SCENE_SAMPLES resolves by the target its printed line gives",
        .enabled(if: ProcessInfo.processInfo.environment["MECUM_SCENE_SAMPLES"] != nil)
    )
    func resolvesSavedScenes() throws {
        let folder = try #require(ProcessInfo.processInfo.environment["MECUM_SCENE_SAMPLES"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".json") }.sorted()
        #expect(!files.isEmpty)
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: folder + "/" + file))
            let scene = try JSONDecoder().decode(SceneSnapshot.self, from: data)
            let report = try Self.resolutionReport(of: scene)
            print("SCENE-SAMPLE \(file): \(report.checked) of \(scene.elements.count) elements checked, \(report.mismatches.count) mismatches")
            #expect(report.mismatches.isEmpty, "\(file): \(report.mismatches)")
            #expect(report.checked == scene.elements.count, "\(file)")
        }
    }

    // MARK: Reading the text back

    fileprivate struct Report {
        var checked = 0
        var mismatches: [String] = []
    }

    /// How a target resolved, reduced to what the model would act on.
    fileprivate static func outcome(_ resolution: SceneSnapshot.Resolution) -> String {
        switch resolution {
            case .found(let element): "found \(element.id) \(element.bounds.x),\(element.bounds.y)"
            case .ambiguous(let count): "ambiguous \(count)"
            case .none: "none"
        }
    }

    /// Reads the printed text back and gives every element exactly one thing it was printed as: a line
    /// holding its label or id and place, an `icons:` entry with its own id and place, or one of the
    /// `id×n` it shares. Then the target a model would copy from it, its id when the line prints one,
    /// else its label with the container the line prints, is resolved and compared with what the label
    /// or id and container the scene always printed resolved to. A shared icon id is counted, not
    /// resolved: it never named one icon. Whatever the text prints that no element accounts for is a
    /// mismatch too.
    private static func resolutionReport(of scene: SceneSnapshot) throws -> Report {
        var report = Report()
        var section: String?
        var lines: [(section: String?, place: String, body: String)] = []
        var icons: [(section: String?, id: String, place: String)] = []
        var shared: [(section: String?, id: String, count: Int)] = []
        let placed = try Regex(#" (@-?\d+,-?\d+)$"#)
        for line in scene.text().split(separator: "\n").dropFirst().map(String.init) {
            if line.hasPrefix("## ") {
                let name = String(line.dropFirst(3))
                section = name == SceneSnapshot.unsectioned ? nil
                    : String(name[..<(name.range(of: " @", options: .backwards)?.lowerBound ?? name.endIndex)])
            } else if line.hasPrefix("commands (") {
                continue
            } else if line.hasPrefix("icons: ") {
                for token in line.dropFirst(7).split(separator: " ") {
                    if let times = token.range(of: "×") {
                        shared.append((section, String(token[..<times.lowerBound]), Int(token[times.upperBound...]) ?? 0))
                    } else if let at = token.range(of: "@", options: .backwards) {
                        icons.append((section, String(token[..<at.lowerBound]), String(token[at.lowerBound...])))
                    }
                }
            } else if let match = line.firstMatch(of: placed), let place = match.output[1].substring {
                lines.append((section, String(place), String(line[..<match.range.lowerBound])))
            }
        }
        for element in scene.elements {
            let field = AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "")
            let place = SceneSnapshot.place(element.bounds)
            if let index = icons.firstIndex(where: { $0.section == element.section && $0.id == element.id && $0.place == place }) {
                icons.remove(at: index)
                report.checked += 1
                report.compare(scene, element.id, against: element.id, in: element.section)
            } else if let index = shared.firstIndex(where: { $0.section == element.section && $0.id == element.id && $0.count > 0 }) {
                shared[index].count -= 1
                report.checked += 1
            } else if let index = lines.firstIndex(where: {
                $0.section == element.section && $0.place == place
                    && $0.body.contains(element.isUnlabeled || field ? "id:'\(element.id)'" : element.label)
            }) {
                let body = lines.remove(at: index).body
                report.checked += 1
                let owner = element.container.map { " {\($0)}" } ?? ""
                let copied = element.isUnlabeled || field ? element.id
                    : element.label + (body.contains(owner) ? owner : "")
                // The old line carried the container on every element, and a model copied it whole.
                report.compare(
                    scene,
                    copied,
                    against: element.isUnlabeled || field ? element.id : element.label + owner,
                    in     : element.section
                )
            } else {
                report.mismatches.append("\(element.label) \(element.id) \(place) is not printed")
            }
        }
        report.mismatches += lines.map { "unaccounted line \($0.body)" }
        report.mismatches += icons.map { "unaccounted icon \($0.id)" }
        report.mismatches += shared.filter { $0.count != 0 }.map { "unaccounted shared id \($0.id)" }
        return report
    }
}

extension CompactSceneTextTests.Report {

    /// Records a mismatch when `target` resolves to something other than what `old` did.
    fileprivate mutating func compare(_ scene: SceneSnapshot, _ target: String, against old: String, in section: String?) {
        let now = CompactSceneTextTests.outcome(scene.resolve(target: target, section: section))
        let before = CompactSceneTextTests.outcome(scene.resolve(target: old, section: section))
        if now != before { mismatches.append("\(target): \(now) instead of \(before)") }
    }
}
