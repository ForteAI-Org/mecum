//
//  TranscriptBenchmarks.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Mecum

/// The transcript measured against the synthetic dataset (§20.1, §20.2).
/// Gated by MECUM_BENCH=1, apart from the functional tests, and run in order.
///
/// Every row has a control that isolates what it measures: a short
/// conversation for opening, the store read alone for paging, an idle main
/// thread for the streams and an unmoved frame for scrolling. The numbers
/// are initial project targets checked on the machine the header names, not
/// claims about other Macs; nothing here fails on a missed target.
///
/// The transcript draws in a borderless window that is never ordered in, so
/// the collection view tiles and recycles as on screen and the screen is not
/// touched. Typing latency hosts the composer under it in the same window.
@Suite("Transcript benchmarks", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MECUM_BENCH"] == "1"))
@MainActor
struct TranscriptBenchmarks {

    private static let dataset = SyntheticDataset()
    private static let size    = CGSize(width: 900, height: 700)

    private func prepared() async throws -> WorkspaceStore {
        try await ensureDataset()
        return try WorkspaceStore.opening(in: Self.dataset.directory)
    }

    /// Writes the dataset when no complete one is kept, and prints the header.
    private func ensureDataset() async throws {
        let started = ContinuousClock.now
        let digest  = try await Self.dataset.prepare { BenchmarkRecord.line("generating: \($0)") }
        let spent   = ContinuousClock.now - started
        BenchmarkRecord.header(dataset: "seed \(Self.dataset.seed) v\(SyntheticDataset.version), digest \(digest), "
            + "10,000 messages in one conversation, 50,000 events, teams of 1, 20 and 100, "
            + "ready in \(Int(BenchmarkRecord.milliseconds(spent))) ms, at \(Self.dataset.directory.path)")
    }

    private func host(_ controller: TranscriptController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func timeOpen(
        _ source      : any ConversationWindowSource,
        _ conversation: UUID,
        anchor        : UUID?
    ) async -> (TranscriptController, NSWindow, Double) {
        let controller = TranscriptController(source: source)
        let window     = host(controller)
        let started    = ContinuousClock.now
        controller.open(conversation, workerName: "Worker", appearance: WorkerAppearance(seed: 1, palette: "tide"),
                        readingAnchor: anchor, readingOffset: 0)
        await controller.settle()
        window.displayIfNeeded()
        return (controller, window, BenchmarkRecord.milliseconds(ContinuousClock.now - started))
    }

    @Test("Opening the 10,000 message conversation at the bottom and at a distant message")
    func opening() async throws {
        let store = try await prepared()
        var bottom: [Double] = [], distant: [Double] = [], control: [Double] = []
        for round in 0..<15 {
            let (_, first, atBottom) = await timeOpen(store, Self.dataset.solo, anchor: nil)
            first.close()
            let target = Self.dataset.soloMessageID(sequence: 501 + round * 600)
            let (landed, second, atDistant) = await timeOpen(store, Self.dataset.solo, anchor: target)
            #expect(landed.captureAnchor()?.itemID == .message(target))
            second.close()
            let (_, third, short) = await timeOpen(store, Self.dataset.team20, anchor: nil)
            third.close()
            bottom.append(atBottom); distant.append(atDistant); control.append(short)
        }
        BenchmarkRecord.row("open at bottom, 10,000 messages", .init(bottom), unit: "ms")
        BenchmarkRecord.row("open at a distant message, 10,000 messages", .init(distant), unit: "ms")
        BenchmarkRecord.row("control: open at bottom, 500 message room", .init(control), unit: "ms")
    }

    @Test("Paging a window up through the history, with its store read alone as the control")
    func paging() async throws {
        let store = try await prepared()
        let (controller, window, _) = await timeOpen(store, Self.dataset.solo, anchor: nil)
        defer { window.close() }
        var pages: [Double] = [], rows: [Int] = [], footprints: [Double] = [], heaps: [Double] = []
        var cached: [Int] = []
        for _ in 0..<150 {
            let started = ContinuousClock.now
            controller.setVisibleTop(0)
            controller.loadOlder()
            await controller.settle()
            window.displayIfNeeded()
            pages.append(BenchmarkRecord.milliseconds(ContinuousClock.now - started))
            rows.append(controller.rows.count)
            footprints.append(BenchmarkRecord.footprintMB() ?? .nan)
            heaps.append(BenchmarkRecord.liveHeapMB())
            cached.append(controller.measuredBlockCount)
        }
        BenchmarkRecord.relieveAllocator()
        let relieved = BenchmarkRecord.footprintMB() ?? .nan

        // The store read alone, through a store opened for it, is also where the live heap once grew.
        let readOnly  = try WorkspaceStore.opening(in: Self.dataset.directory)
        var reads: [Double] = []
        var alone     = try await TranscriptWindow.opening(Self.dataset.solo, around: nil, from: readOnly)
        let heapStart = BenchmarkRecord.liveHeapMB()
        for _ in 0..<150 {
            let started = ContinuousClock.now
            alone = try await alone.loadingOlder(from: readOnly)
            reads.append(BenchmarkRecord.milliseconds(ContinuousClock.now - started))
        }
        let heapEnd = BenchmarkRecord.liveHeapMB()
        BenchmarkRecord.row("page one window up, read to drawn", .init(pages), unit: "ms")
        BenchmarkRecord.row("control: the store read of one page alone", .init(reads), unit: "ms")
        BenchmarkRecord.line("paging rows held: first \(rows.first ?? 0), max \(rows.max() ?? 0), "
            + "last \(rows.last ?? 0); "
            + String(format: "footprint MB after page 1 %.1f, 40 %.1f, 80 %.1f, 120 %.1f, 150 %.1f",
                     footprints[0], footprints[39], footprints[79], footprints[119], footprints[149]))
        BenchmarkRecord.line(String(format: "live heap MB after page 1 %.1f, 40 %.1f, 80 %.1f, 120 %.1f, 150 %.1f; "
                                    + "footprint after the allocator returns its free pages %.1f",
                                    heaps[0], heaps[39], heaps[79], heaps[119], heaps[149], relieved)
            + "; measured blocks cached at pages 1, 40, 80, 120, 150: "
            + "\([0, 39, 79, 119, 149].map { cached[$0] }), cache capacity \(LayoutMeasurementCache.capacity)")
        BenchmarkRecord.line(String(format: "control: live heap MB over 150 store reads alone %.1f -> %.1f",
                                    heapStart, heapEnd))
    }

    @Test("The main thread's longest block while four streams run and the reader stays back in the history")
    func fourStreams() async throws {
        try await ensureDataset()
        let copy = URL.temporaryDirectory.appending(path: "MecumTranscriptStreams-\(UUID().uuidString)",
                                                    directoryHint: .isDirectory)
        try Self.dataset.copy(to: copy)
        defer { discard(copy) }
        let store  = try WorkspaceStore.opening(in: copy)
        let source = StreamingSource(store: store)

        var streams: [(message: UUID, turn: UUID, conversation: UUID)] = []
        let start = SyntheticDataset.origin.addingTimeInterval(10_000_000)
        for (offset, conversation) in [Self.dataset.solo, Self.dataset.solo, Self.dataset.team20,
                                       Self.dataset.team100].enumerated() {
            let turn    = UUID()
            let at      = start.addingTimeInterval(Double(offset))
            try await store.append(NewEvent(workspaceID: SyntheticDataset.workspaceID, subjectID: turn,
                                            conversationID: conversation, timestamp: at, type: .executionStarted))
            let message = try await store.appendMessage(to: conversation, author: UUID(), text: "",
                                                        at: at.addingTimeInterval(0.5), delivery: .responding)
            streams.append((message.id, turn, conversation))
        }
        let (reader, window, _) = await timeOpen(source, Self.dataset.solo, anchor: nil)
        defer { window.close() }
        let (team20, _, _)  = await timeOpen(source, Self.dataset.team20, anchor: nil)
        let (team100, _, _) = await timeOpen(source, Self.dataset.team100, anchor: nil)
        let controllers = [reader, reader, team20, team100]

        // The reader goes back up the window and selects inside a code block.
        reader.setVisibleTop(reader.contentHeight / 4)
        window.displayIfNeeded()
        let anchor = reader.captureAnchor()
        var selection: TranscriptSelection?
        if let index = reader.rows.firstIndex(where: { $0.text.blocks.contains(where: \.isCompleteCode) }),
           let frame = reader.frameMap()[reader.rows[index].item.id],
           let block = reader.rows[index].text.blocks.firstIndex(where: \.isCompleteCode) {
            let text = reader.rows[index].geometry.blockTexts[block]
            reader.setVisibleTop(frame.minY + text.minY - 40)
            window.displayIfNeeded()
            reader.beginSelection(at: CGPoint(x: frame.minX + text.minX + 2, y: frame.minY + text.minY + 4),
                                  clickCount: 1)
            reader.extendSelection(to: CGPoint(x: frame.minX + text.minX + 200, y: frame.minY + text.minY + 40))
            selection = reader.textSelection
        }
        let readerAnchor = reader.captureAnchor() ?? anchor

        let control = MainThreadProbe()
        control.start()
        for _ in 0..<375 { try await Task.sleep(for: .milliseconds(8)) }
        let idle = control.stop()

        let probe   = MainThreadProbe()
        let updates = controllers.map(\.viewUpdateCount)
        probe.start()
        for round in 0..<375 {
            for (index, stream) in streams.enumerated() {
                let delta = round == 0 ? "Working on it.\n\n```swift\n"
                    : round % 6 == 0 ? "\n    let step\(round) = try await run(\(index))" : " // \(round)"
                await source.append(delta, to: stream.message)
                controllers[index].refresh()
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        for stream in streams {
            await source.append("\n```\nDone.", to: stream.message)
            try await store.update(message: stream.message, delivery: .completed)
            try await store.append(NewEvent(workspaceID: SyntheticDataset.workspaceID, subjectID: stream.turn,
                                            conversationID: stream.conversation,
                                            timestamp: start.addingTimeInterval(60), type: .executionCompleted))
        }
        controllers.forEach { $0.refresh() }
        for controller in [reader, team20, team100] { await controller.settle() }
        let busy = probe.stop()

        let texts  = await source.texts
        let landed = streams.enumerated().allSatisfy { index, stream in
            let rows = controllers[index].rows
            return rows.first { $0.item.id == .message(stream.message) }?.item.copyText == texts[stream.message]
                && !rows.contains { $0.item.kind == .thinking }
        }
        let applied = zip(controllers, updates).map { $0.viewUpdateCount - $1 }
        BenchmarkRecord.row("main thread lateness, four streams", busy, unit: "ms", target: "longest < 100 ms",
                            note: busy.maximum < 100 ? "met" : "missed")
        BenchmarkRecord.row("control: main thread lateness, idle", idle, unit: "ms")
        BenchmarkRecord.line("four streams: reader moved \(reader.captureAnchor() != readerAnchor), "
            + "selection kept \(selection != nil && reader.textSelection == selection), terminal updates landed "
            + "\(landed), view updates per controller \(applied), stream length \(texts.values.first?.count ?? 0)")
        #expect(landed)
    }

    @Test("Typing latency in the composer, key event to laid out character, with four streams in the open conversation")
    func typing() async throws {
        try await ensureDataset()
        let copy = URL.temporaryDirectory.appending(path: "MecumComposerTyping-\(UUID().uuidString)",
                                                    directoryHint: .isDirectory)
        try Self.dataset.copy(to: copy)
        defer { discard(copy) }
        let store  = try WorkspaceStore.opening(in: copy)
        let source = StreamingSource(store: store)

        var streams: [UUID] = []
        let start = SyntheticDataset.origin.addingTimeInterval(10_000_000)
        for offset in 0..<4 {
            let at = start.addingTimeInterval(Double(offset))
            try await store.append(NewEvent(workspaceID: SyntheticDataset.workspaceID, subjectID: UUID(),
                                            conversationID: Self.dataset.solo, timestamp: at, type: .executionStarted))
            let message = try await store.appendMessage(to: Self.dataset.solo, author: UUID(), text: "",
                                                        at: at.addingTimeInterval(0.5), delivery: .responding)
            streams.append(message.id)
        }
        let (reader, window, _) = await timeOpen(source, Self.dataset.solo, anchor: nil)
        defer { window.close() }

        // The conversation view's layout: the transcript above, the composer along the bottom.
        let composerHeight: CGFloat = 120
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        reader.view.frame = NSRect(x: 0, y: composerHeight, width: Self.size.width,
                                   height: Self.size.height - composerHeight)
        container.addSubview(reader.view)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        await reader.settle()

        // A fresh composer per run; its first keys pay for text system and SwiftUI warm up, reported apart.
        let keys = 300, warmUp = 20, interval = Duration.milliseconds(50)
        func typeKeys() async throws -> (BenchmarkRecord.Samples, first: Double, landed: Int) {
            let composer = TypingComposer(in: container, height: composerHeight)
            #expect(composer.isReady)
            let probe = MainThreadProbe()
            probe.start(interval: interval) { composer.typeNextKey() }
            while probe.lateness.count < warmUp + keys { try await Task.sleep(for: .milliseconds(20)) }
            _ = probe.stop()
            let timed = Array(probe.lateness.dropFirst(warmUp).prefix(keys))
            return (BenchmarkRecord.Samples(timed), probe.lateness.first ?? .nan, composer.landed)
        }

        let (idle, idleFirst, idleLanded) = try await typeKeys()

        // Each round appends to the four replies and refreshes the transcript; every other round draws it.
        let bitmap    = try #require(reader.view.bitmapImageRepForCachingDisplay(in: reader.view.bounds))
        let streaming = Task { @MainActor in
            var round = 0
            while !Task.isCancelled {
                for (index, stream) in streams.enumerated() {
                    let delta = round == 0 ? "Working on it.\n\n```swift\n"
                        : round % 6 == 0 ? "\n    let step\(round) = try await run(\(index))" : " // \(round)"
                    await source.append(delta, to: stream)
                    reader.refresh()
                }
                if round % 2 == 0 { reader.view.cacheDisplay(in: reader.view.bounds, to: bitmap) }
                round += 1
                do { try await Task.sleep(for: .milliseconds(8)) } catch { break }
            }
            return round
        }
        let (loaded, loadedFirst, loadedLanded) = try await typeKeys()
        streaming.cancel()
        let rounds = await streaming.value
        let texts  = await source.texts

        BenchmarkRecord.row("typing, key event to laid out character, four streams", loaded, unit: "ms",
                            target: "p95 < 50 ms", note: loaded.p95 < 50 ? "met" : "missed")
        BenchmarkRecord.row("control: typing, no stream", idle, unit: "ms")
        BenchmarkRecord.line(String(format: "typing: a key every %d ms, %d timed keys per run after %d warm up keys; "
                                    + "first key of a fresh composer %.2f ms with streams, %.2f ms without",
                                    Int(BenchmarkRecord.milliseconds(interval)), keys, warmUp, loadedFirst, idleFirst)
            + "; landed \(loadedLanded) and \(idleLanded) of \(warmUp + keys); \(rounds) stream rounds, "
            + "reply length \(texts.values.first?.count ?? 0), transcript rows \(reader.rows.count)")
    }

    @Test("Layout and draw time per frame while scrolling up through the history, paging as it goes")
    func scrolling() async throws {
        let store = try await prepared()
        let (controller, window, _) = await timeOpen(store, Self.dataset.solo, anchor: nil)
        defer { window.close() }
        let budget = 1000.0 / 60
        let view   = controller.view
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))

        // A window that is not on screen may skip its display pass, so each frame draws into a bitmap.
        func frame(movingBy step: CGFloat) -> Double {
            let started = ContinuousClock.now
            controller.setVisibleTop(controller.visibleTop - step)
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return BenchmarkRecord.milliseconds(ContinuousClock.now - started)
        }

        var still: [Double] = []
        for _ in 0..<120 {
            still.append(frame(movingBy: 0))
            await Task.yield()
        }

        let probe = MainThreadProbe()
        probe.start()
        var frames: [Double] = []
        for _ in 0..<900 {
            frames.append(frame(movingBy: 60))
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        await controller.settle()
        let busy = probe.stop()
        let slow = frames.filter { $0 > budget }.count
        BenchmarkRecord.row("scroll frame, 60 pt up, layout and draw", .init(frames), unit: "ms",
                            target: "about 16.7 ms", note: "\(slow) of \(frames.count) frames over budget")
        BenchmarkRecord.row("control: the same frame drawn without movement", .init(still), unit: "ms")
        BenchmarkRecord.row("main thread lateness while scrolling and paging", busy, unit: "ms",
                            target: "longest < 100 ms", note: busy.maximum < 100 ? "met" : "missed")
        BenchmarkRecord.line("scrolling ended with \(controller.rows.count) rows held")
    }

    @Test("Memory before and after repeated open and close, each open going to the bottom and a distant message")
    func memory() async throws {
        let store  = try await prepared()
        let before = BenchmarkRecord.footprintMB() ?? .nan
        var after: [Double] = []
        for round in 0..<20 {
            try await openAndClose(store, distant: 101 + round * 450)
            after.append(BenchmarkRecord.footprintMB() ?? .nan)
        }
        BenchmarkRecord.row("footprint after each open and close", .init(after), unit: "MB")
        BenchmarkRecord.line(String(format: "footprint MB: before %.1f, after cycle 1 %.1f, cycle 10 %.1f, "
                                    + "cycle 20 %.1f", before, after[0], after[9], after[19]))
    }

    /// One open at the bottom, a jump to `distant`, and a close. The wait lets
    /// the controller's resting report finish, so nothing keeps it alive.
    private func openAndClose(_ store: WorkspaceStore, distant: Int) async throws {
        let (controller, window, _) = await timeOpen(store, Self.dataset.solo, anchor: nil)
        controller.reveal(message: Self.dataset.soloMessageID(sequence: distant))
        await controller.settle()
        window.displayIfNeeded()
        window.close()
        try await Task.sleep(for: .milliseconds(450))
    }

    /// Removes a copied store. A failure leaves a folder in the temporary
    /// directory and must not fail the measurement it cleans up after.
    private func discard(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) } catch { }
    }
}
