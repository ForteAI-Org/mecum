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
/// so the terminal update of a turn always lands. A selection survives an
/// update that leaves its text where it was, or moves with its text.
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
    @ObservationIgnored private(set) var textSelection: (id: TranscriptItem.ID, range: NSRange)?
    @ObservationIgnored private var focusedAction : (id: TranscriptItem.ID, action: RowAction)?
    @ObservationIgnored private var chain         : Task<Void, Never>?
    @ObservationIgnored private var flush         : Task<Void, Never>?
    @ObservationIgnored private var cadence       = FlushCadence()
    @ObservationIgnored private var isApplying    = false
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
            await apply(fresh, mode: .live)
        } catch {
            problem = "The conversation could not be read again. \(error.localizedDescription)"
        }
    }

    public func scrollToBottom() {
        newActivity = nil
        setVisibleTop(.greatestFiniteMagnitude)
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
        keepSelection(in: result.rows)

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
        lastUpdate = update
        isEmpty    = rows.isEmpty
        scheduleUnsentCheck(window, now: now)
    }

    @concurrent
    private static func project(_ window: TranscriptWindow, expanded: Set<TranscriptItem.ID>, now: Date) async
        -> [TranscriptItem] {
        ConversationProjection.items(messages: window.messages, events: window.events, expanded: expanded,
                                     elidedBefore: window.elidedBefore, now: now)
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

    func loadOlder() {
        enqueue {
            guard let window = self.window, !window.isAtOldest else { return }
            do {
                let older = try await window.loadingOlder(from: self.source)
                await self.apply(older, mode: .paging)
            } catch {
                self.problem = "Earlier messages could not be read. \(error.localizedDescription)"
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

    /// Keeps the selection across an update of its row: where it was when
    /// its text is still there, else on the first place that text now is.
    /// A selection whose text is gone, or whose row is, is cleared.
    private func keepSelection(in fresh: [PreparedRow]) {
        guard let selection = textSelection,
              let before = rows.first(where: { $0.item.id == selection.id })?.text.string as NSString?,
              NSMaxRange(selection.range) <= before.length
        else { return }
        let selected = before.substring(with: selection.range)
        guard let after = fresh.first(where: { $0.item.id == selection.id })?.text.string as NSString? else {
            textSelection = nil
            return
        }
        if NSMaxRange(selection.range) <= after.length, after.substring(with: selection.range) == selected { return }
        let moved = after.range(of: selected)
        textSelection = moved.location == NSNotFound ? nil : (selection.id, moved)
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

    private func configure(_ cell: TranscriptCell, with row: PreparedRow) {
        let id = row.item.id
        cell.rowView.configure(
            row,
            style     : style,
            workerName: workerName,
            avatar    : row.item.authorWorkerID == nil ? nil : avatar,
            selection : textSelection?.id == id ? textSelection?.range : nil
        )
        cell.rowView.focusedAction = focusedAction?.id == id ? focusedAction?.action : nil
        cell.rowView.onSelectText = { [weak self] range in
            self?.textSelection = range.map { (id, $0) }
            self?.focus(id)
        }
        cell.rowView.onActivate = { [weak self] in self?.toggle(id) }
        cell.rowView.onAction   = { [weak self] action in self?.perform(action, in: id) }
    }

    private func reconfigureVisible(_ ids: Set<TranscriptItem.ID>) {
        guard !ids.isEmpty else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() where rows.indices.contains(indexPath.item) {
            let row = rows[indexPath.item]
            guard ids.contains(row.item.id), let cell = collectionView.item(at: indexPath) as? TranscriptCell
            else { continue }
            configure(cell, with: row)
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

    func setVisibleTop(_ top: CGFloat) {
        let clip    = scrollView.contentView
        let maximum = max(0, layout.collectionViewContentSize.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, top), maximum)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func didScroll() {
        guard !isApplying else { return }
        if isAtBottom { newActivity = nil }
        if scrollView.contentView.bounds.minY < 400, window?.isAtOldest == false { loadOlder() }
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
        let arrivedMessage = update.inserted.contains { rows[$0].item.messageID != nil }
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
        let next = min(max(0, (focusedIndex ?? (step > 0 ? -1 : rows.count)) + step), rows.count - 1)
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
    private func copySelection() {
        let text: String
        if let selection = textSelection, let row = rows.first(where: { $0.item.id == selection.id }),
           NSMaxRange(selection.range) <= (row.text.string as NSString).length {
            text = (row.text.string as NSString).substring(with: selection.range)
        } else if let index = focusedIndex, rows.indices.contains(index) {
            text = rows[index].item.copyText
        } else {
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
            configure(cell, with: rows[indexPath.item])
        }
        return item
    }
}
