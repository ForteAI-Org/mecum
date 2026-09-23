//
//  TranscriptController.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Mascots
import Observation
import Workspace

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
/// The window pages at both ends as the reader nears one, and drops what is
/// far past the other (`TranscriptWindow.messageLimit`). `reveal(message:)`
/// opens a window around any message without reading the pages between.
@MainActor
@Observable
public final class TranscriptController: NSObject {

    /// What arrived below the reader, split so the indicator can say which.
    public enum NewActivity: Sendable, Equatable {
        case messages
        case statusChanges
    }

    /// The view to host. It contains the scroll view and the indicator.
    @ObservationIgnored
    public let view: NSView

    public private(set) var isEmpty = true
    public private(set) var newActivity: NewActivity? {
        didSet { showIndicator() }
    }

    /// Why the last read did not apply, in a sentence. Nil once one applies.
    public private(set) var problem: String?

    /// Called once scrolling rests, with the message the reader is anchored on
    /// and the offset in points from its top to the viewport's top.
    @ObservationIgnored
    public var onReadingPositionChange: ((UUID?, Double) -> Void)?

    public var style: TranscriptStyle {
        didSet { if style != oldValue { enqueue { await self.relayout() } } }
    }

    /// Evidence for tests: full reloads so far, the last applied difference,
    /// and every pass that changed what the view shows.
    @ObservationIgnored public private(set) var reloadCount     = 0
    @ObservationIgnored public private(set) var lastUpdate      : TranscriptUpdate?
    @ObservationIgnored public private(set) var viewUpdateCount = 0

    @ObservationIgnored private let source        : any ConversationWindowSource
    @ObservationIgnored private let pipeline      : any MessageContentPipeline
    @ObservationIgnored private let pasteboard    : NSPasteboard
    @ObservationIgnored private let scrollView    = NSScrollView()
    @ObservationIgnored let collectionView        = TranscriptCollectionView()
    @ObservationIgnored private let layout        = TranscriptLayout()
    @ObservationIgnored private let indicator     = NSButton()

    @ObservationIgnored private var conversationID: UUID?
    @ObservationIgnored private var window        : TranscriptWindow?
    @ObservationIgnored private(set) var rows     : [PreparedRow] = []
    @ObservationIgnored private var expanded      : Set<TranscriptItem.ID> = []
    @ObservationIgnored private var cache         = LayoutMeasurementCache()
    @ObservationIgnored private var preparedWidth : CGFloat = 0
    @ObservationIgnored private var workerName    = ""
    @ObservationIgnored private var avatar        : NSImage?
    @ObservationIgnored private(set) var textSelection: TranscriptSelection?
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
    public init(
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
    public func open(
        _ conversationID: UUID,
        workerName      : String,
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
                self.avatar      = MascotImages.image(for: appearance, size: RowGeometry.avatarSide)
                self.expanded    = []
                self.textSelection = nil
                self.focusedAction = nil
                self.newActivity = nil
                let position = readingAnchor.map { ScrollAnchor(itemID: .message($0), offset: readingOffset) }
                await self.apply(window, mode: .open(position))
            } catch {
                self.problem = "This conversation could not be read. \(error.localizedDescription)"
            }
        }
    }

    /// Shows `messageID` of the open conversation at the viewport's top and
    /// focuses it. A loaded message is scrolled to; any other opens the window
    /// around it with one read, not the pages between (§12.5). Search opens
    /// its results through here. A message the conversation no longer has
    /// leaves the transcript as it was and is reported in `problem`.
    public func reveal(message messageID: UUID) {
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
                self.problem = "That message could not be read. \(error.localizedDescription)"
            }
        }
    }

    /// Reads the live tail again after the store recorded something, at the
    /// next flush: calls before it share one read.
    public func refresh() {
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
                let arrived = fresh.newestSequence > window.newestSequence
                newActivity = arrived ? .messages : newActivity ?? .statusChanges
                return
            }
            await apply(fresh, mode: .live)
        } catch {
            problem = "The conversation could not be read again. \(error.localizedDescription)"
        }
    }

    /// Goes to the conversation's end, opening the newest window when the
    /// loaded one stops short of it.
    public func scrollToBottom() {
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
                self.problem = "The end of this conversation could not be read. \(error.localizedDescription)"
            }
        }
    }

    /// Waits for the pending flush and every queued load and relayout. Tests
    /// and snapshots use it.
    public func settle() async {
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
        let style    = style
        let cache    = cache
        let pipeline = pipeline
        let now      = Date()
        let items    = await Self.project(window, expanded: expanded, now: now)
        let result   = await RowPreparation.prepare(items, workerName: name, width: width, style: style,
                                                    cache: cache, pipeline: pipeline)
        guard window.conversationID == conversationID else { return }

        let started = ContinuousClock.now
        self.cache.merge(result.measured)
        let update      = TranscriptUpdate(from: rows.map(\.item), to: result.rows.map(\.item))
        let wasAtBottom = isAtBottom
        let anchor      = captureAnchor()
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

        case .live, .paging, .relayout:
            guard !update.isEmpty || mode == .relayout else { break }
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
        }
        showSelection()
        lastUpdate = update
        isEmpty    = rows.isEmpty
        scheduleUnsentCheck(window, now: now)
    }

    @concurrent
    private static func project(_ window: TranscriptWindow, expanded: Set<TranscriptItem.ID>, now: Date) async
        -> [TranscriptItem] {
        ConversationProjection.items(messages: window.messages, events: window.events, expanded: expanded,
                                     elidedBefore: window.elidedBefore, now: now, calendar: .autoupdatingCurrent,
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
        page("Earlier messages could not be read.") { window, source in
            window.isAtOldest ? nil : try await window.loadingOlder(from: source)
        }
    }

    /// Loads one page below the window, when it stops short of the newest.
    func loadNewer() {
        page("Later messages could not be read.") { window, source in
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
                self.problem = "\(failure) \(error.localizedDescription)"
            }
        }
    }

    private func toggle(_ id: TranscriptItem.ID) {
        if expanded.remove(id) == nil { expanded.insert(id) }
        enqueue { await self.reproject() }
    }

    /// Projects the same window again: an expansion, or a badge whose time came.
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
        collectionView.onExtend   = { [weak self] step in self?.extendSelection(byRow: step) }
        collectionView.onSelectAll     = { [weak self] in self?.selectAll() }
        collectionView.onSelectMessage = { [weak self] in self?.selectFocusedMessage() }

        scrollView.documentView          = collectionView
        scrollView.hasVerticalScroller   = true
        scrollView.drawsBackground       = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        indicator.bezelStyle = .push
        indicator.isHidden   = true
        indicator.target     = self
        indicator.action     = #selector(indicatorPressed)
        indicator.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        view.addSubview(indicator)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])

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
        layout.continuesGroup = rows.map(\.item.continuesGroup)
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
        cell.rowView.onPointer  = { [weak self] phase, location in self?.pointer(phase, at: location) }
        cell.rowView.onActivate = { [weak self] in self?.toggle(id) }
        cell.rowView.onAction   = { [weak self] action in self?.perform(action, in: id) }
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

    private func playEntrances(_ update: TranscriptUpdate) {
        let reduces = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for index in update.inserted {
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
        return ScrollAnchor.capture(frames: frames, visibleTop: scrollView.contentView.bounds.minY)
    }

    var visibleTop: CGFloat { scrollView.contentView.bounds.minY }

    func setVisibleTop(_ top: CGFloat) {
        let clip    = scrollView.contentView
        let maximum = max(0, layout.collectionViewContentSize.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, top), maximum)))
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
            let anchor = ScrollAnchor.capture(frames: frames, visibleTop: scrollView.contentView.bounds.minY) {
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
        let arrivedMessage = (update.inserted + update.replaced).contains { rows[$0].item.messageID != nil }
        if arrivedMessage {
            newActivity = .messages
        } else if !update.inserted.isEmpty || !update.changed.isEmpty, newActivity == nil {
            newActivity = .statusChanges
        }
    }

    /// The indicator says which kind of activity arrived, and hides with it.
    private func showIndicator() {
        indicator.title    = newActivity == .messages ? "New messages" : "Status changed"
        indicator.isHidden = newActivity == nil
        indicator.setAccessibilityLabel("New activity: \(indicator.title). Go to the end")
    }

    @objc
    private func indicatorPressed() {
        scrollToBottom()
    }

    // MARK: Keyboard and copy

    private var focusedIndex: Int? { collectionView.selectionIndexPaths.first?.item }

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
        case .openLink(let destination, _, _):
            guard let url = RowAction.openableURL(destination) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// Copies the selected text, or the focused row when nothing is selected.
    func copySelection() {
        let text: String
        if let selection = textSelection, !selection.isEmpty, let span = selection.span(in: rows) {
            text = span.text(in: rows)
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

    /// Replaces the selection and redraws the rows on screen.
    func select(_ selection: TranscriptSelection?) {
        textSelection = selection
        showSelection()
    }

    /// Gives every live cell its part of the selection, so a row the recycler
    /// brings back draws what the logical selection says and nothing older.
    private func showSelection() {
        for indexPath in collectionView.indexPathsForVisibleItems() where rows.indices.contains(indexPath.item) {
            guard let cell = collectionView.item(at: indexPath) as? TranscriptCell else { continue }
            cell.rowView.show(selection: selectedRange(ofRow: indexPath.item))
        }
    }

    private func pointer(_ phase: TranscriptRowView.PointerPhase, at windowLocation: NSPoint) {
        let point = collectionView.convert(windowLocation, from: nil)
        switch phase {
        case .down(let clicks): beginSelection(at: point, clickCount: clicks)
        case .drag:             extendSelection(to: point)
        }
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

    /// Command A inside the transcript: every loaded row, not the app.
    func selectAll() {
        guard let first = rows.first, let last = rows.last else { return }
        select(TranscriptSelection(anchor: .init(itemID: first.item.id, offset: 0),
                                   focus : .init(itemID: last.item.id, offset: last.length)))
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
}

// MARK: - Data source

extension TranscriptController: NSCollectionViewDataSource, NSCollectionViewDelegate {

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    public func collectionView(
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
