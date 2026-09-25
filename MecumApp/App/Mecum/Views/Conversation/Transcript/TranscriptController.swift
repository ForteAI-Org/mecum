//
//  TranscriptController.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import ModelTransports
import Observation

/// TranscriptController owns one conversation's transcript: the window it
/// holds, the rows prepared from it and the recycled collection view that
/// shows them (§12.1, §12.2).
///
/// The pipeline runs in order: a window read through the source, projected
/// and prepared off the main thread, then applied here. Applying compares the
/// new rows with the shown ones by identity and touches only what differs:
/// removals and insertions go through one batch, and a row whose content
/// changed is reconfigured in place. `reloadData` runs once per opened
/// conversation and never for a single change.
///
/// Main actor isolated. Loads, refreshes and relayouts are serialized in one
/// chain, so a refresh never interleaves with a page loading above it, and a
/// result for a conversation that is no longer open is dropped. A read that
/// fails leaves the transcript as it was and is reported in `problem`.
///
/// What the reader looks at stays put: a row captured before an update is put
/// back at the same distance from the viewport's top after it, unless the
/// reader was at the bottom, which is then followed. New rows arriving while
/// the reader is elsewhere raise `newActivity` instead of moving them.
///
/// Refreshes are grouped (§12.3). A burst of `refresh()` calls, one per
/// delta a message receives, becomes one read and one view update per
/// `FlushCadence` tick. The flush does not depend on the view being on
/// screen, and a request that arrives while one is read schedules another,
/// so the terminal update of a turn always lands.
///
/// The selection is a `TranscriptSelection`, in row ids and offsets, never in
/// cells: a drag is hit tested here against the layout, so it can cross rows
/// the recycler reuses while it runs. It survives an update to a row it
/// spans and clamps when one of its rows goes (`TranscriptSelection.kept`).
///
/// Whole messages can be selected as bubbles, Finder style, beside the text
/// selection: a click selects one, Command adds or removes one, Shift takes
/// the range from the anchor. The bubble selection is message ids, so it
/// survives recycling, paging and updates; the two selections never coexist.
///
/// The window pages at both ends as the reader nears one, and drops what is
/// far past the other (`TranscriptWindow.messageLimit`). `reveal(message:)`
/// opens a window around any message without reading the pages between.
@MainActor
@Observable
final class TranscriptController: NSObject {

    /// What arrived below the reader, split so the indicator can say which.
    enum NewActivity: Sendable, Equatable {
        case messages
        case statusChanges
    }

    /// The view to host. It contains the scroll view and the indicator.
    @ObservationIgnored
    let view: NSView

    private(set) var isEmpty = true

    private(set) var newActivity: NewActivity? {
        didSet {
            if newActivity == nil { newMessageCount = 0 }
            showIndicator()
        }
    }

    /// Messages that arrived below the reader since it was last at the end.
    private(set) var newMessageCount = 0

    /// Points at the bottom of the view that something floating covers, such
    /// as the composer. The last row scrolls clear of it, the end counts from
    /// above it and the new activity indicator sits over it. The host sets it.
    var bottomInset: CGFloat = 0 {
        didSet { if bottomInset != oldValue { applyInsets(previousTop: topInset) } }
    }

    /// Points at the top of the view that a floating header covers. The oldest
    /// row scrolls clear of it, and the reading position, the anchor kept
    /// across updates and a revealed message all count from below it.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { applyInsets(previousTop: oldValue) } }
    }

    /// Why the last read did not apply, in a sentence. Nil once one applies.
    private(set) var problem: String?

    /// Called once scrolling rests, with the message the reader is anchored on
    /// and the offset in points from its top to the viewport's top.
    @ObservationIgnored
    var onReadingPositionChange: ((UUID?, Double) -> Void)?

    var style: TranscriptStyle {
        didSet { if style != oldValue { enqueue { await self.relayout() } } }
    }

    /// Evidence for tests: full reloads so far, the last applied difference,
    /// and every pass that changed what the view shows.
    @ObservationIgnored private(set) var reloadCount     = 0
    @ObservationIgnored private(set) var lastUpdate      : TranscriptUpdate?
    @ObservationIgnored private(set) var viewUpdateCount = 0

    /// Shows a menu the keyboard opened at a point in a view; a test records it instead.
    @ObservationIgnored var presentsMenu: (NSMenu, CGPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }

    @ObservationIgnored private let source        : any ConversationWindowSource
    @ObservationIgnored private let pipeline      : any MessageContentPipeline
    @ObservationIgnored private let pasteboard    : NSPasteboard
    @ObservationIgnored private let scrollView    = NSScrollView()
    @ObservationIgnored let collectionView        = TranscriptCollectionView()
    @ObservationIgnored private let layout        = TranscriptLayout()
    @ObservationIgnored let indicator             = NSButton()
    @ObservationIgnored private var indicatorBottom: NSLayoutConstraint?

    @ObservationIgnored private var conversationID: UUID?

    /// True once a conversation has been drawn, so the next one opened comes in as a replacement.
    @ObservationIgnored private var hasShownConversation = false
    @ObservationIgnored private var window        : TranscriptWindow?
    @ObservationIgnored private(set) var rows     : [PreparedRow] = []
    @ObservationIgnored private var expanded      : Set<TranscriptItem.ID> = []
    @ObservationIgnored private var cache         = LayoutMeasurementCache()
    @ObservationIgnored private var preparedWidth : CGFloat = 0
    @ObservationIgnored private var workerName    = ""
    @ObservationIgnored private var workerProvider: ModelProvider?
    @ObservationIgnored private var avatar        : NSImage?
    @ObservationIgnored private(set) var textSelection: TranscriptSelection?
    @ObservationIgnored private(set) var bubbleSelection: Set<UUID> = []
    @ObservationIgnored private var bubbleAnchor  : UUID?
    @ObservationIgnored private var bubbleBase    : Set<UUID> = []
    @ObservationIgnored private var focusedAction : (id: TranscriptItem.ID, action: RowAction)?
    @ObservationIgnored private var chain         : Task<Void, Never>?
    @ObservationIgnored private var flush         : Task<Void, Never>?
    @ObservationIgnored private var cadence       = FlushCadence()
    @ObservationIgnored private var isApplying    = false
    @ObservationIgnored private var isPaging      = false
    @ObservationIgnored private var restingReport : Task<Void, Never>?
    @ObservationIgnored private var unsentCheck   : Task<Void, Never>?
    @ObservationIgnored private var observers     : [any NSObjectProtocol] = []

    /// `pasteboard` receives Copy and Copy block; a test passes its own.
    init(
        source    : any ConversationWindowSource,
        pipeline  : any MessageContentPipeline = MarkdownContent(),
        style     : TranscriptStyle = TranscriptStyle(),
        pasteboard: NSPasteboard = .general
    ) {
        self.source     = source
        self.pipeline   = pipeline
        self.style      = style
        self.pasteboard = pasteboard
        self.view     = NSView()
        super.init()
        assemble()
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Operations

    /// Opens `conversationID` at the remembered position, or at the end when
    /// there is none or its message is gone.
    func open(
        _ conversationID: UUID,
        workerName      : String,
        workerProvider  : ModelProvider? = nil,
        appearance      : WorkerAppearance,
        readingAnchor   : UUID?,
        readingOffset   : Double
    ) {
        self.conversationID = conversationID
        enqueue {
            do {
                let window = try await TranscriptWindow.opening(conversationID, around: readingAnchor,
                                                                from: self.source)
                guard self.conversationID == conversationID else { return }
                self.workerName  = workerName
                self.workerProvider = workerProvider
                self.avatar      = MascotImages.image(for: appearance, size: RowGeometry.avatarSide)
                self.expanded    = []
                self.textSelection = nil
                self.setBubbles([], anchor: nil)
                self.focusedAction = nil
                self.newActivity = nil
                let position = readingAnchor.map { ScrollAnchor(itemID: .message($0), offset: readingOffset) }
                let replaces = self.hasShownConversation
                await self.apply(window, mode: .open(position))
                guard self.conversationID == conversationID else { return }
                self.hasShownConversation = true
                if replaces { self.playOpening() }
            } catch {
                self.problem = "Couldn’t load this conversation.\n\nDetails: \(error.localizedDescription)"
            }
        }
    }

    /// Shows `messageID` of the open conversation at the viewport's top and
    /// focuses it. A loaded message is scrolled to; any other opens the window
    /// around it with one read, not the pages between (§12.5). Search opens
    /// its results through here. A message the conversation no longer has
    /// leaves the transcript as it was and is reported in `problem`.
    func reveal(message messageID: UUID) {
        enqueue {
            let id = TranscriptItem.ID.message(messageID)
            if let frame = self.frameMap()[id] {
                self.setVisibleTop(frame.minY)
                self.focus(id)
                return
            }
            guard let conversationID = self.conversationID else { return }
            do {
                let window = try await TranscriptWindow.opening(conversationID, around: messageID,
                                                                from: self.source)
                guard self.conversationID == conversationID else { return }
                guard window.messages.contains(where: { $0.id == messageID }) else {
                    self.problem = "That message is no longer in this conversation."
                    return
                }
                await self.apply(window, mode: .open(ScrollAnchor(itemID: id, offset: 0)))
                self.focus(id)
            } catch {
                self.problem = "Couldn’t load that message.\n\nDetails: \(error.localizedDescription)"
            }
        }
    }

    /// Reads the live tail again after the store recorded something, at the
    /// next flush: calls before it share one read.
    func refresh() {
        guard flush == nil else { return }
        let wait = cadence.interval
        flush = Task {
            // A cancelled wait still flushes, so a terminal update is never dropped.
            do { try await Task.sleep(for: wait) } catch {}
            self.flush = nil
            self.enqueue { await self.readTail() }
        }
    }

    private func readTail() async {
        guard let window, window.conversationID == conversationID else { return }
        do {
            let fresh = try await window.refreshingTail(from: source)
            guard fresh.conversationID == conversationID else { return }
            guard fresh.isAtNewest else {
                // The newest end is not loaded: nothing to apply, only the indicator to raise.
                self.window = fresh
                let arrived = max(0, fresh.newestSequence - window.newestSequence)
                newMessageCount += arrived
                newActivity = arrived > 0 ? .messages : newActivity ?? .statusChanges
                return
            }
            await apply(fresh, mode: .live)
        } catch {
            problem = "Couldn’t refresh the conversation.\n\nDetails: \(error.localizedDescription)"
        }
    }

    /// Goes to the conversation's end, opening the newest window when the
    /// loaded one stops short of it.
    func scrollToBottom() {
        newActivity = nil
        guard window?.isAtNewest == false, let conversationID else {
            setVisibleTop(.greatestFiniteMagnitude)
            return
        }
        enqueue {
            do {
                let window = try await TranscriptWindow.opening(conversationID, around: nil, from: self.source)
                guard self.conversationID == conversationID else { return }
                await self.apply(window, mode: .open(nil))
            } catch {
                self.problem = "Couldn’t load the latest messages.\n\nDetails: \(error.localizedDescription)"
            }
        }
    }

    /// Waits for the pending flush and every queued load and relayout. Tests
    /// and snapshots use it.
    func settle() async {
        while true {
            if let pending = flush {
                await pending.value
                continue
            }
            guard let pending = chain else { return }
            await pending.value
            if chain == pending, flush == nil { return }
        }
    }

    // MARK: Applying

    private enum Mode: Equatable {
        case open(ScrollAnchor?)
        case live
        case paging
        case relayout

        /// A tool line opened or closed: the rows it moves slide, and an opened one that runs under the composer scrolls up.
        case expansion(TranscriptItem.ID)
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await operation()
        }
    }

    private func apply(_ window: TranscriptWindow, mode: Mode) async {
        let width    = currentWidth
        let expanded = expanded
        let name     = workerName
        let provider = workerProvider
        let style    = style
        let cache    = cache
        let pipeline = pipeline
        let now      = Date()
        let items    = await Self.project(window, expanded: expanded, opensToolSteps: style.opensToolSteps, now: now)
        let result   = await RowPreparation.prepare(items, workerName: name, workerProvider: provider, width: width,
                                                    style: style, cache: cache, pipeline: pipeline)
        guard window.conversationID == conversationID else { return }

        let started = ContinuousClock.now
        self.cache.merge(result.measured)
        let update      = TranscriptUpdate(from: rows.map(\.item), to: result.rows.map(\.item))
        let wasAtBottom = isAtBottom
        let anchor      = captureAnchor()
        let drawnFrames = frameMap()
        let drawnTop    = scrollView.contentView.bounds.minY
        textSelection   = textSelection?.kept(from: rows, in: result.rows)

        isApplying = true
        defer {
            isApplying = false
            cadence.record(applyDuration: ContinuousClock.now - started)
        }
        self.window   = window
        preparedWidth = width
        problem       = nil

        switch mode {
        case .open(let position):
            rows = result.rows
            setHeights()
            collectionView.reloadData()
            reloadCount += 1
            viewUpdateCount += 1
            layoutNow()
            if let position, let top = position.visibleTop(in: frameMap()) {
                setVisibleTop(top)
            } else {
                setVisibleTop(.greatestFiniteMagnitude)
            }

        case .live, .paging, .relayout, .expansion:
            guard !update.isEmpty || mode == .relayout else { break }
            var folding: NSImage?
            if case .expansion(let id) = mode {
                folding = closingCard(
                    of: id,
                    to: result.rows
                )
            }
            rows = result.rows
            viewUpdateCount += 1
            setHeights()
            collectionView.performBatchUpdates({
                collectionView.deleteItems(at: Set(update.removed.map { IndexPath(item: $0, section: 0) }))
                collectionView.insertItems(at: Set(update.inserted.map { IndexPath(item: $0, section: 0) }))
            }, completionHandler: nil)
            let changed = mode == .relayout ? Set(rows.map(\.item.id)) : Set(update.changed)
            reconfigureVisible(changed)
            layout.invalidateLayout()
            layoutNow()

            if mode == .live, wasAtBottom {
                setVisibleTop(.greatestFiniteMagnitude)
            } else if let anchor, let top = anchor.visibleTop(in: frameMap()) {
                setVisibleTop(top)
            }
            if mode == .live {
                noteActivity(update, followed: wasAtBottom)
                playEntrances(update)
            }
            if case .expansion(let id) = mode {
                slideRows(
                    toggled : id,
                    from    : drawnFrames,
                    drawnTop: drawnTop,
                    folding : folding
                )
                reveal(id)
            }
        }
        showSelection()
        lastUpdate = update
        isEmpty    = rows.isEmpty
        scheduleUnsentCheck(window, now: now)
    }

    @concurrent
    private static func project(_ window: TranscriptWindow, expanded: Set<TranscriptItem.ID>, opensToolSteps: Bool,
                                now: Date) async -> [TranscriptItem] {
        ConversationProjection.items(messages: window.messages, events: window.events, expanded: expanded,
                                     opensToolSteps: opensToolSteps, elidedBefore: window.elidedBefore, now: now, calendar: .autoupdatingCurrent,
                                     isAtNewest: window.isAtNewest)
    }

    /// Projects again when the earliest saved message still inside its grace
    /// reaches the end of it, so a message nothing sent gets its badge then.
    private func scheduleUnsentCheck(_ window: TranscriptWindow, now: Date) {
        unsentCheck?.cancel()
        let deadlines = window.messages
            .filter { $0.isFromPerson && $0.delivery == .savedLocally }
            .map { $0.createdAt.addingTimeInterval(DeliveryBadge.unsentGrace) }
            .filter { $0 > now }
        guard let next = deadlines.min() else { return }
        unsentCheck = Task {
            do { try await Task.sleep(for: .seconds(next.timeIntervalSince(now))) } catch { return }
            enqueue { await self.reproject() }
        }
    }

    /// Prepares the same rows again at the current width and style.
    private func relayout() async {
        guard let window else { return }
        await apply(window, mode: .relayout)
    }

    /// Loads one page above the window. A load already queued absorbs the
    /// call, so a burst of scroll notifications reads one page.
    func loadOlder() {
        page("Couldn’t load earlier messages.") { window, source in
            window.isAtOldest ? nil : try await window.loadingOlder(from: source)
        }
    }

    /// Loads one page below the window, when it stops short of the newest.
    func loadNewer() {
        page("Couldn’t load later messages.") { window, source in
            window.isAtNewest ? nil : try await window.loadingNewer(from: source)
        }
    }

    private func page(
        _ failure: String,
        read     : @escaping @MainActor (TranscriptWindow, any ConversationWindowSource) async throws
            -> TranscriptWindow?
    ) {
        guard !isPaging else { return }
        isPaging = true
        enqueue {
            defer { self.isPaging = false }
            guard let window = self.window else { return }
            do {
                guard let paged = try await read(window, self.source) else { return }
                await self.apply(paged, mode: .paging)
            } catch {
                self.problem = "\(failure)\n\nDetails: \(error.localizedDescription)"
            }
        }
    }

    private func toggle(_ id: TranscriptItem.ID) {
        if expanded.remove(id) == nil { expanded.insert(id) }
        enqueue {
            guard let window = self.window else { return }
            await self.apply(window, mode: .expansion(id))
        }
    }

    /// Projects the same window again, for a badge whose time came.
    private func reproject() async {
        guard let window else { return }
        await apply(window, mode: .paging)
    }

    // MARK: Collection view

    private func assemble() {
        collectionView.collectionViewLayout = layout
        collectionView.dataSource           = self
        collectionView.delegate             = self
        collectionView.isSelectable         = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors     = [.clear]
        collectionView.register(TranscriptCell.self, forItemWithIdentifier: TranscriptCell.identifier)
        collectionView.setAccessibilityLabel("Conversation")
        collectionView.onMove     = { [weak self] step in self?.moveFocus(by: step) }
        collectionView.onMoveAction = { [weak self] step in self?.moveActionFocus(by: step) }
        collectionView.onActivate = { [weak self] in self?.activateFocused() }
        collectionView.onCopy     = { [weak self] in self?.copySelection() }
        collectionView.onExtend   = { [weak self] step in self?.extend(by: step) }
        collectionView.onSelectAll     = { [weak self] in self?.selectAll() }
        collectionView.onToggle        = { [weak self] in self?.toggleFocusedBubble() }
        collectionView.onClear         = { [weak self] in self?.clearSelections() }
        collectionView.onKeyboard      = { [weak self] in self?.showFocusRing(true) }
        collectionView.onSelectMessage = { [weak self] in self?.selectFocusedMessage() }
        collectionView.onContextMenu   = { [weak self] in self?.showMenuForFocusedRow() }
        collectionView.onScrollToEnd   = { [weak self] in self?.scrollToBottom() }

        scrollView.documentView          = collectionView
        scrollView.hasVerticalScroller   = true
        scrollView.drawsBackground       = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        indicator.bezelStyle    = .push
        indicator.controlSize   = .large
        indicator.image         = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        indicator.imagePosition = .imageLeading
        indicator.isHidden      = true
        indicator.target        = self
        indicator.action        = #selector(indicatorPressed)
        indicator.toolTip       = "Jump to the latest message."
        indicator.translatesAutoresizingMaskIntoConstraints = false
        let shadow = NSShadow()
        shadow.shadowColor      = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset     = NSSize(width: 0, height: -2)
        indicator.shadow        = shadow

        view.addSubview(scrollView)
        view.addSubview(indicator)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        let indicatorBottom = indicator.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        indicatorBottom.isActive = true
        self.indicatorBottom     = indicatorBottom

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                            object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didScroll() }
        })
        scrollView.contentView.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                            object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didResize() }
        })
    }

    private func setHeights() {
        layout.heights        = rows.map(\.geometry.height)
        layout.continuesGroup = rows.indices.map { index in
            let row = rows[index].item
            guard index > 0, !row.continuesGroup, case .toolRun = rows[index - 1].item.kind else {
                return row.continuesGroup
            }
            // A tool line opens its worker's part of a turn, so the worker's next row sits close under it.
            return row.authorWorkerID != nil && row.authorWorkerID == rows[index - 1].item.authorWorkerID
        }
    }

    private func configure(_ cell: TranscriptCell, at index: Int) {
        let row = rows[index]
        let id  = row.item.id
        cell.rowView.configure(
            row,
            style     : style,
            workerName: workerName,
            avatar    : row.item.authorWorkerID == nil ? nil : avatar,
            selection : selectedRange(ofRow: index)
        )
        cell.rowView.focusedAction = focusedAction?.id == id ? focusedAction?.action : nil
        cell.rowView.showsFocusRing = showsFocusRing
        cell.rowView.isBubbleSelected = row.item.messageID.map(bubbleSelection.contains) ?? false
        cell.rowView.onPointer  = { [weak self] phase, location in self?.pointer(phase, at: location) }
        cell.rowView.onActivate = { [weak self] in self?.toggle(id) }
        cell.rowView.onAction   = { [weak self] action in self?.perform(action, in: id) }
        cell.rowView.onMenu     = { [weak self] block, offset in self?.menu(for: id, block: block, offset: offset) }
    }

    private func reconfigureVisible(_ ids: Set<TranscriptItem.ID>) {
        guard !ids.isEmpty else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() where rows.indices.contains(indexPath.item) {
            let row = rows[indexPath.item]
            guard ids.contains(row.item.id), let cell = collectionView.item(at: indexPath) as? TranscriptCell
            else { continue }
            configure(cell, at: indexPath.item)
        }
    }

    /// Slides each row on screen from where it was drawn to where it now is: a line that grew
    /// opens downwards from its old height as its card fades in, and one that shrank folds
    /// `folding`, the card it lost, up and out. Reduce Motion places them at once.
    private func slideRows(
        toggled id: TranscriptItem.ID,
        from drawn: [TranscriptItem.ID: CGRect],
        drawnTop  : CGFloat,
        folding   : NSImage?
    ) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let top = scrollView.contentView.bounds.minY
        for indexPath in collectionView.indexPathsForVisibleItems()
        where rows.indices.contains(indexPath.item) && layout.frames.indices.contains(indexPath.item) {
            let rowID = rows[indexPath.item].item.id
            guard let old = drawn[rowID], let cell = collectionView.item(at: indexPath) as? TranscriptCell else { continue }
            let new = layout.frames[indexPath.item]
            cell.slide(from: (old.minY - drawnTop) - (new.minY - top), openingFrom: rowID == id ? old.height : nil)
            if rowID == id, let folding { cell.fold(folding) }
        }
    }

    /// What closing the tool line `id` takes off its row, drawn from the cell still showing it
    /// open; nil when the line opens, is off screen, or Reduce Motion is on.
    private func closingCard(
        of id  : TranscriptItem.ID,
        to next: [PreparedRow]
    ) -> NSImage? {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let index  = rows.firstIndex(where: { $0.item.id == id }),
              let height = next.first(where: { $0.item.id == id })?.geometry.height,
              let view   = (collectionView.item(at: IndexPath(item: index, section: 0)) as? TranscriptCell)?.rowView,
              view.bounds.height > height
        else { return nil }
        let lost = CGRect(x: 0, y: height, width: view.bounds.width, height: view.bounds.height - height)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: lost) else { return nil }
        view.cacheDisplay(
            in: lost,
            to: bitmap
        )
        let image = NSImage(size: lost.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Scrolls an opened row that now runs under the composer up into view, never past its own top.
    private func reveal(_ id: TranscriptItem.ID) {
        guard let index = rows.firstIndex(where: { $0.item.id == id }), layout.frames.indices.contains(index)
        else { return }
        let frame  = layout.frames[index]
        let clip   = scrollView.contentView
        let bottom = clip.bounds.maxY - max(0, bottomInset)
        guard frame.maxY > bottom else { return }
        let maximum = max(0, layout.collectionViewContentSize.height - clip.bounds.height)
        let target  = min(maximum, clip.bounds.minY + min(frame.maxY - bottom, frame.minY - visibleTop))
        guard target > clip.bounds.minY else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self.map { $0.scrollView.reflectScrolledClipView($0.scrollView.contentView) } }
        }
    }

    /// Brings in the rows of a conversation that replaced another, each fading and rising on
    /// its own layer. Done in AppKit on purpose: fading the hosted view from SwiftUI made the
    /// title bar above it lose sight of the content and draw itself solid until the fade ended.
    private func playOpening() {
        let reduces = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The scroll to the reading position has just moved the viewport; its cells exist only after a layout.
        collectionView.layoutSubtreeIfNeeded()
        for indexPath in collectionView.indexPathsForVisibleItems() {
            (collectionView.item(at: indexPath) as? TranscriptCell)?
                .playEntrance(reducesMotion: reduces, duration: 0.28)
        }
    }

    /// Plays the entrance on rows that arrived below every row already shown.
    /// A row inserted above one that stays is history, not an arrival, except a
    /// tool line, which arrives above the bubble or reply it opens.
    private func playEntrances(_ update: TranscriptUpdate) {
        let inserted = Set(update.inserted)
        let lastKept = rows.indices.last { !inserted.contains($0) } ?? -1
        let arrivals = update.inserted.filter { index in
            if case .toolRun = rows[index].item.kind { return true }
            return index > lastKept
        }
        guard !arrivals.isEmpty else { return }
        let reduces = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for index in arrivals {
            guard let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? TranscriptCell
            else { continue }
            cell.playEntrance(reducesMotion: reduces)
        }
    }

    // MARK: Scrolling

    private var currentWidth: CGFloat {
        let width = scrollView.contentView.bounds.width
        return width > 0 ? width.rounded() : 600
    }

    var isAtBottom: Bool {
        let clip = scrollView.contentView.bounds
        return layout.collectionViewContentSize.height - clip.maxY < 8
    }

    /// Lays out again for new insets, keeping the end in view or the row read below the header.
    private func applyInsets(previousTop: CGFloat) {
        let wasAtBottom = isAtBottom
        let frames = zip(rows.map(\.item.id), layout.frames).map { (id: $0, frame: $1) }
        let anchor = ScrollAnchor.capture(frames: frames,
                                          visibleTop: scrollView.contentView.bounds.minY + max(0, previousTop))
        layout.topInset           = max(0, topInset)
        layout.bottomInset        = max(0, bottomInset)
        indicatorBottom?.constant = -(max(0, bottomInset) + 12)
        layout.invalidateLayout()
        layoutNow()
        if wasAtBottom {
            setVisibleTop(.greatestFiniteMagnitude)
        } else if let top = anchor?.visibleTop(in: frameMap()) {
            setVisibleTop(top)
        }
    }

    /// The content height, which a snapshot sizes its view to.
    var contentHeight: CGFloat { layout.collectionViewContentSize.height }

    /// Block sizes the measurement cache holds, which a benchmark reports.
    var measuredBlockCount: Int { cache.count }

    private func layoutNow() {
        collectionView.frame.size.width = scrollView.contentView.bounds.width
        layout.prepare()
        collectionView.frame.size.height = layout.collectionViewContentSize.height
        collectionView.layoutSubtreeIfNeeded()
    }

    func frameMap() -> [TranscriptItem.ID: CGRect] {
        Dictionary(zip(rows.map(\.item.id), layout.frames), uniquingKeysWith: { first, _ in first })
    }

    func captureAnchor() -> ScrollAnchor? {
        let frames = zip(rows.map(\.item.id), layout.frames).map { (id: $0, frame: $1) }
        return ScrollAnchor.capture(frames: frames, visibleTop: visibleTop)
    }

    /// The first y the reader sees: the viewport's top, below `topInset`.
    var visibleTop: CGFloat { scrollView.contentView.bounds.minY + max(0, topInset) }

    /// Scrolls so `top` sits just below `topInset`, within the content.
    func setVisibleTop(_ top: CGFloat) {
        let clip    = scrollView.contentView
        let maximum = max(0, layout.collectionViewContentSize.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, top - max(0, topInset)), maximum)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func didScroll() {
        guard !isApplying else { return }
        if isAtBottom { newActivity = nil }
        let clip = scrollView.contentView.bounds
        if clip.minY < 400, window?.isAtOldest == false { loadOlder() }
        if layout.collectionViewContentSize.height - clip.maxY < 400, window?.isAtNewest == false { loadNewer() }
        reportWhenResting()
    }

    private func didResize() {
        guard currentWidth != preparedWidth, window != nil else { return }
        enqueue { await self.relayout() }
    }

    /// Reports the reading position once scrolling has rested for a moment.
    private func reportWhenResting() {
        restingReport?.cancel()
        restingReport = Task {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            let frames = zip(rows.map(\.item.id), layout.frames).map { (id: $0, frame: $1) }
            let anchor = ScrollAnchor.capture(frames: frames, visibleTop: visibleTop) {
                if case .message = $0 { true } else { false }
            }
            guard case .message(let id)? = anchor?.itemID, let anchor else {
                onReadingPositionChange?(nil, 0)
                return
            }
            onReadingPositionChange?(isAtBottom ? nil : id, isAtBottom ? 0 : Double(anchor.offset))
        }
    }

    private func noteActivity(_ update: TranscriptUpdate, followed: Bool) {
        guard !followed else { return }
        let arrived = (update.inserted + update.replaced).count { rows[$0].item.messageID != nil }
        if arrived > 0 {
            newMessageCount += arrived
            newActivity = .messages
        } else if !update.inserted.isEmpty || !update.changed.isEmpty, newActivity == nil {
            newActivity = .statusChanges
        }
    }

    /// The indicator says which kind of activity arrived, and hides with it:
    /// new messages are an accent pill with their count, a change to a row
    /// already seen is a quieter one.
    private func showIndicator() {
        switch newActivity {
        case .messages:
            indicator.title      = newMessageCount == 1 ? "1 new message" : "\(max(1, newMessageCount)) new messages"
            indicator.bezelColor = .controlAccentColor
        case .statusChanges, nil:
            indicator.title      = "New Activity"
            indicator.bezelColor = nil
        }
        indicator.isHidden = newActivity == nil
        indicator.setAccessibilityLabel("\(indicator.title). Jump to latest message")
    }

    @objc
    private func indicatorPressed() {
        scrollToBottom()
    }

    // MARK: Keyboard and copy

    private var focusedIndex: Int? { collectionView.selectionIndexPaths.first?.item }

    /// Whether the focused row is outlined: once a key moves the focus, until the next press.
    @ObservationIgnored private var showsFocusRing = false

    private func showFocusRing(_ shown: Bool) {
        guard shown != showsFocusRing else { return }
        showsFocusRing = shown
        for indexPath in collectionView.indexPathsForVisibleItems() {
            (collectionView.item(at: indexPath) as? TranscriptCell)?.rowView.showsFocusRing = shown
        }
    }

    private func focus(_ id: TranscriptItem.ID) {
        guard let index = rows.firstIndex(where: { $0.item.id == id }) else { return }
        collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
    }

    private func moveFocus(by step: Int) {
        guard !rows.isEmpty else { return }
        var next = min(max(0, (focusedIndex ?? (step > 0 ? -1 : rows.count)) + step), rows.count - 1)
        // A day separator is a heading between rows, not a stop for the keyboard.
        while case .daySeparator = rows[next].item.kind, rows.indices.contains(next + step) { next += step }
        let path = IndexPath(item: next, section: 0)
        setFocusedAction(nil)
        collectionView.selectionIndexPaths = [path]
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        if let cell = collectionView.item(at: path) {
            NSAccessibility.post(element: cell.view, notification: .focusedUIElementChanged)
        }
    }

    /// Moves through the focused row's actions; past either end, back to the row.
    private func moveActionFocus(by step: Int) {
        guard let index = focusedIndex, rows.indices.contains(index) else { return }
        let row     = rows[index]
        let actions = RowAction.actions(in: row.text)
        guard !actions.isEmpty else { return }
        let current = focusedAction?.id == row.item.id
            ? focusedAction.flatMap { focused in actions.firstIndex(of: focused.action) }
            : nil
        let next = (current ?? (step > 0 ? -1 : actions.count)) + step
        setFocusedAction(actions.indices.contains(next) ? (row.item.id, actions[next]) : nil)
    }

    private func setFocusedAction(_ focused: (id: TranscriptItem.ID, action: RowAction)?) {
        let touched = Set([focusedAction?.id, focused?.id].compactMap { $0 })
        focusedAction = focused
        reconfigureVisible(touched)
    }

    private func activateFocused() {
        guard let index = focusedIndex, rows.indices.contains(index) else { return }
        let id = rows[index].item.id
        if let focused = focusedAction, focused.id == id {
            perform(focused.action, in: id)
        } else if case .toolRun = rows[index].item.kind {
            toggle(id)
        }
    }

    /// Runs a row's action, which only ever happens on the reader's request.
    private func perform(_ action: RowAction, in id: TranscriptItem.ID) {
        guard let row = rows.first(where: { $0.item.id == id }) else { return }
        switch action {
        case .copyBlock(let index):
            guard row.text.blocks.indices.contains(index) else { return }
            pasteboard.clearContents()
            pasteboard.setString(row.text.blocks[index].string, forType: .string)
            if let item = rows.firstIndex(where: { $0.item.id == id }),
               let cell = collectionView.item(at: IndexPath(item: item, section: 0)) as? TranscriptCell {
                cell.rowView.showCopied(block: index)
            }
        case .openLink(let destination, _, _):
            guard let url = RowAction.openableURL(destination) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// Copies the selected text, else the selected bubbles' source in reading
    /// order, else the focused row.
    func copySelection() {
        let text: String
        let bubbles = selectedBubbleRows
        if let selection = textSelection, !selection.isEmpty, let span = selection.span(in: rows) {
            text = span.text(in: rows)
        } else if !bubbles.isEmpty {
            text = bubbles.map(\.item.copyText).joined(separator: "\n\n")
        } else if let index = focusedIndex, rows.indices.contains(index) {
            text = rows[index].item.copyText
        } else {
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Selection

    /// The part of the row at `index` the selection covers, as its view draws it.
    func selectedRange(ofRow index: Int) -> NSRange? {
        guard let selection = textSelection, !selection.isEmpty else { return nil }
        return selection.span(in: rows)?.range(ofRow: index, in: rows)
    }

    /// Replaces the text selection and redraws the rows on screen. A text
    /// selection replaces any bubble selection.
    func select(_ selection: TranscriptSelection?) {
        textSelection = selection
        if selection?.isEmpty == false, !bubbleSelection.isEmpty { bubbleSelection = []; bubbleBase = [] }
        showSelection()
    }

    /// Gives every live cell its part of the selection, so a row the recycler
    /// brings back draws what the logical selection says and nothing older.
    private func showSelection() {
        for indexPath in collectionView.indexPathsForVisibleItems() where rows.indices.contains(indexPath.item) {
            guard let cell = collectionView.item(at: indexPath) as? TranscriptCell else { continue }
            cell.rowView.show(selection: selectedRange(ofRow: indexPath.item))
            cell.rowView.isBubbleSelected = rows[indexPath.item].item.messageID.map(bubbleSelection.contains) ?? false
        }
    }

    private func pointer(_ phase: TranscriptRowView.PointerPhase, at windowLocation: NSPoint) {
        let point = collectionView.convert(windowLocation, from: nil)
        switch phase {
        case .press:
            // The row takes the press, so the collection view must take the keyboard or Copy goes elsewhere.
            takeKeyboard()
            showFocusRing(false)
        case .dragStart:
            beginSelection(at: point, clickCount: 1)
        case .drag:
            extendSelection(to: point)
        case .click(let count, _) where count == 2:
            beginSelection(at: point, clickCount: 2)
        case .click(_, let modifiers):
            guard let hit = selectionPoint(at: point) else { return }
            click(hit.itemID, modifiers: modifiers)
        }
    }

    // MARK: Bubbles

    /// The loaded rows whose message is selected as a bubble, in reading order.
    var selectedBubbleRows: [PreparedRow] {
        bubbleSelection.isEmpty ? [] : rows.filter { $0.item.messageID.map(bubbleSelection.contains) ?? false }
    }

    /// A click on the row `id`: alone it selects that message, with Command it
    /// adds or removes it, with Shift it takes the messages from the anchor to
    /// it, replacing the range an earlier Shift click from that anchor took.
    func click(_ id: TranscriptItem.ID, modifiers: NSEvent.ModifierFlags) {
        textSelection = nil
        focus(id)
        guard let index = rows.firstIndex(where: { $0.item.id == id }), let message = rows[index].item.messageID
        else {
            setBubbles([], anchor: nil)
            return
        }
        if modifiers.contains(.shift), let anchor = bubbleAnchor,
           let from = rows.firstIndex(where: { $0.item.messageID == anchor }) {
            let range = rows[min(from, index)...max(from, index)].compactMap(\.item.messageID)
            bubbleSelection = bubbleBase.union(range)
            showSelection()
        } else if modifiers.contains(.command) {
            var chosen = bubbleSelection
            if chosen.remove(message) == nil { chosen.insert(message) }
            setBubbles(chosen, anchor: message)
        } else {
            setBubbles([message], anchor: message)
        }
    }

    /// Replaces the bubble selection and the anchor a Shift click counts from.
    private func setBubbles(_ chosen: Set<UUID>, anchor: UUID?) {
        bubbleSelection = chosen
        bubbleBase      = chosen
        bubbleAnchor    = anchor
        if !chosen.isEmpty { textSelection = nil }
        showSelection()
    }

    /// Space: the focused message joins or leaves the bubble selection; on any
    /// other row, or with one of its actions reached, it runs as Return does.
    private func toggleFocusedBubble() {
        guard let index = focusedIndex, rows.indices.contains(index), focusedAction?.id != rows[index].item.id,
              rows[index].item.messageID != nil
        else { return activateFocused() }
        click(rows[index].item.id, modifiers: .command)
    }

    /// Escape, or a press on empty space: nothing stays selected, and no row keeps the focus outline.
    private func clearSelections() {
        textSelection = nil
        collectionView.selectionIndexPaths = []
        setBubbles([], anchor: nil)
    }

    /// Shift with Up or Down extends a text selection by row when there is
    /// one, and otherwise the bubble selection from the focused message.
    private func extend(by step: Int) {
        guard textSelection?.isEmpty != false else { return extendSelection(byRow: step) }
        let messages = rows.indices.filter { rows[$0].item.messageID != nil }
        guard !messages.isEmpty else { return }
        guard !bubbleSelection.isEmpty, let focused = focusedIndex else {
            let start = focusedIndex.flatMap { index in messages.first { $0 >= index } } ?? messages[messages.count - 1]
            click(rows[start].item.id, modifiers: [])
            reach(start)
            return
        }
        let ahead = step > 0 ? messages.first { $0 > focused } : messages.last { $0 < focused }
        guard let next = ahead else { return }
        click(rows[next].item.id, modifiers: .shift)
        reach(next)
    }

    /// Starts a selection at `point`, in the collection view's coordinates. A
    /// double click selects the row under it whole.
    func beginSelection(at point: CGPoint, clickCount: Int) {
        guard let hit = selectionPoint(at: point),
              let index = rows.firstIndex(where: { $0.item.id == hit.itemID })
        else { return }
        select(clickCount == 2 ? TranscriptSelection(wholeOf: rows[index])
                               : TranscriptSelection(anchor: hit, focus: hit))
        focus(hit.itemID)
    }

    /// Moves the selection's free end to `point`. A point past the viewport
    /// counts as its edge, where a live row always is.
    func extendSelection(to point: CGPoint) {
        guard var selection = textSelection else { return }
        let visible = scrollView.contentView.bounds
        let clamped = CGPoint(x: point.x, y: min(max(point.y, visible.minY), visible.maxY - 1))
        guard let hit = selectionPoint(at: clamped) else { return }
        selection.focus = hit
        select(selection)
    }

    /// The row and character under `point`. Between rows it is the start of
    /// the row below; past the last row, the end of it.
    private func selectionPoint(at point: CGPoint) -> TranscriptSelection.Point? {
        let frames = layout.frames
        guard let last = rows.last, frames.count == rows.count else { return nil }
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].maxY < point.y { low = middle + 1 } else { high = middle }
        }
        guard low < rows.count else { return .init(itemID: last.item.id, offset: last.length) }
        let id = rows[low].item.id
        guard point.y >= frames[low].minY,
              let cell = collectionView.item(at: IndexPath(item: low, section: 0)) as? TranscriptCell
        else { return .init(itemID: id, offset: 0) }
        let local = cell.rowView.convert(point, from: collectionView)
        return .init(itemID: id, offset: cell.rowView.nearestCharacter(to: local))
    }

    /// Command A inside the transcript: every loaded message as a bubble, not
    /// the app. Copying it gives the text a select all of the rows would.
    func selectAll() {
        textSelection = nil
        setBubbles(Set(rows.compactMap(\.item.messageID)), anchor: bubbleAnchor)
    }

    /// Selects the focused row's whole text.
    func selectFocusedMessage() {
        guard let index = focusedIndex, rows.indices.contains(index) else { return }
        select(TranscriptSelection(wholeOf: rows[index]))
    }

    /// Shift with Up or Down: the free end goes to the edge of its row, then
    /// to the far edge of the next message. With nothing selected, the focused
    /// row, or the last one, is selected whole first.
    func extendSelection(byRow step: Int) {
        guard !rows.isEmpty else { return }
        guard let selection = textSelection, !selection.isEmpty,
              let row = rows.firstIndex(where: { $0.item.id == selection.focus.itemID })
        else {
            let index = focusedIndex.flatMap { rows.indices.contains($0) ? $0 : nil } ?? rows.count - 1
            let whole = TranscriptSelection(wholeOf: rows[index])
            select(step > 0 ? whole : TranscriptSelection(anchor: whole.focus, focus: whole.anchor))
            reach(index)
            return
        }
        let edge = step > 0 ? rows[row].length : 0
        var next = selection
        if selection.focus.offset != edge {
            next.focus = .init(itemID: rows[row].item.id, offset: edge)
        } else {
            let ahead  = step > 0 ? Array(rows.indices.suffix(from: row + 1))
                                  : Array(rows.indices.prefix(row).reversed())
            guard let target = ahead.first(where: { rows[$0].item.messageID != nil }) else { return }
            next.focus = .init(itemID: rows[target].item.id, offset: step > 0 ? rows[target].length : 0)
        }
        select(next)
        if let target = rows.firstIndex(where: { $0.item.id == next.focus.itemID }) { reach(target) }
    }

    /// Focuses the row at `index` and scrolls it into view.
    private func reach(_ index: Int) {
        let path = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [path]
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
    }

    private func takeKeyboard() {
        guard let window = collectionView.window, window.firstResponder !== collectionView else { return }
        window.makeFirstResponder(collectionView)
    }

    // MARK: Context menu

    /// The menu for the row `id`: Copy when text is selected, the message's
    /// own items, and Copy Code or the link's items for what lies under the
    /// pointer. A press inside the selection keeps it; one outside drops it.
    /// On a selected bubble the copy takes the whole bubble selection; on any
    /// other row the bubble selection goes. `block` and `offset` are nil when
    /// the keyboard opens the menu.
    func menu(for id: TranscriptItem.ID, block: Int?, offset: Int?) -> NSMenu? {
        guard let index = rows.firstIndex(where: { $0.item.id == id }) else { return nil }
        let row = rows[index]
        takeKeyboard()
        focus(id)
        if let offset, let selected = selectedRange(ofRow: index),
           !(selected.location...NSMaxRange(selected)).contains(offset) {
            select(nil)
        }
        if let message = row.item.messageID, !bubbleSelection.contains(message), !bubbleSelection.isEmpty {
            setBubbles([], anchor: nil)
        }
        let bubbles = selectedBubbleRows

        let menu = NSMenu()
        func add(_ title: String, _ run: @escaping @MainActor () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            item.target            = self
            item.representedObject = MenuAction(run: run)
            menu.addItem(item)
        }
        if textSelection?.isEmpty == false {
            add("Copy") { [weak self] in self?.copySelection() }
        }
        if bubbles.count > 1 {
            add("Copy \(bubbles.count) Messages") { [weak self] in self?.copySelection() }
        } else if row.item.messageID != nil {
            add("Copy Message") { [weak self] in self?.put(row.item.copyText) }
        }
        if row.item.messageID != nil {
            add("Select Message") { [weak self] in self?.click(id, modifiers: []) }
        }
        let actions = RowAction.actions(in: row.text)
        if let block, actions.contains(.copyBlock(index: block)) {
            add("Copy Code") { [weak self] in self?.perform(.copyBlock(index: block), in: id) }
        }
        let link = actions.first { action in
            guard case .openLink(_, let linkBlock, let range) = action, linkBlock == block, let offset
            else { return false }
            return NSLocationInRange(offset - row.text.blockRanges[linkBlock].location, range)
        }
        if let link, case .openLink(let destination, _, _) = link {
            if RowAction.openableURL(destination) != nil {
                add("Open Link") { [weak self] in self?.perform(link, in: id) }
            }
            add("Copy Link") { [weak self] in self?.put(destination) }
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// Shift F10 or the context menu key: the focused row's menu, under its surface.
    private func showMenuForFocusedRow() {
        guard let index = focusedIndex, rows.indices.contains(index),
              let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? TranscriptCell,
              let menu = menu(for: rows[index].item.id, block: nil, offset: nil)
        else { return }
        let surface = rows[index].geometry.surface
        presentsMenu(menu, CGPoint(x: surface.minX, y: surface.maxY + 4), cell.rowView)
    }

    @objc
    private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    private func put(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// MenuAction is what a context menu item runs, carried by the item.
nonisolated private final class MenuAction {
    let run: @MainActor () -> Void
    init(run: @escaping @MainActor () -> Void) { self.run = run }
}

// MARK: - Data source

extension TranscriptController: NSCollectionViewDataSource, NSCollectionViewDelegate {

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(
        _ collectionView           : NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: TranscriptCell.identifier, for: indexPath)
        if let cell = item as? TranscriptCell, rows.indices.contains(indexPath.item) {
            configure(cell, at: indexPath.item)
        }
        return item
    }
}
