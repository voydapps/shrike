//
//  ViewerWindow+Culling.swift
//  ShrikeUI
//
//  Rating and flag in the viewer and the pill marks that
//  show them. Records for the whole list are read in one batched
//  `records(for:)` call when the list changes, never per image.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension ViewerWindow {

    // MARK: Actions

    /// Sets the displayed item's rating. Pressing the current rating
    /// again keeps it; `0` clears.
    func rateDisplayed(_ stars: Int) {
        guard let item = displayedItem else { return }
        reviewDecisionSerial &+= 1
        let serial = reviewDecisionSerial
        let sourceSequence = list.groups.map(\.primary)
        let originalIndex = item.listIndex
        let listGeneration = list.generation
        let decision = ReviewDecision()
        let advance = Prefs.reviewControlsVisible && Prefs.advanceAfterRating && stars > 0
        let urls = Culling.imageURLs(of: item.group)
        CullingUndo.perform(
            .rating, urls: urls, store: services.metadataStore, undoManager: windowUndoManager,
            compute: { Culling.ratingValues(stars, urls: urls, previous: $0) },
            onChange: { [weak self] values in self?.cullingDidChange(values) },
            onFailure: { [weak self] error in self?.contentRoot.toast(CullingUndo.failureMessage(.rating, error: error)) },
            onCommit: { [weak self] result, kind in
                guard let self, !self.didTearDown, self.reviewDecisionSerial == serial,
                      !self.contentRoot.isEditModeActive, self.list.generation == listGeneration else { return }
                if kind == .forward {
                    guard advance, self.services.metadataStore.persistenceStatus.isPersistent,
                          self.displayedItem?.group.primary == item.group.primary,
                          result.previous.contains(where: { result.new[$0.key]?.rating != $0.value.rating }) else { return }
                    let surviving = Set(self.list.groups.map(\.primary))
                    guard let next = sourceSequence.dropFirst(originalIndex + 1).first(where: { surviving.contains($0) }),
                          let index = self.list.groups.firstIndex(where: { $0.primary == next }) else {
                        self.contentRoot.toast("Review reached the last photo"); return
                    }
                    decision.didAdvance = true
                    self.reviewAutomaticMove = true
                    self.reviewJump(to: index)
                    self.reviewAutomaticMove = false
                } else if kind == .undo, decision.didAdvance,
                          let index = self.list.groups.firstIndex(where: { $0.primary == item.group.primary }) {
                    self.reviewDecisionSerial &+= 1
                    self.reviewAutomaticMove = true; self.reviewJump(to: index); self.reviewAutomaticMove = false
                }
            }, suppressing: watcherScope)
    }

    /// Q / \ : flags or unflags the displayed item.
    func toggleFlagDisplayed() {
        guard let item = displayedItem else { return }
        reviewDecisionSerial &+= 1
        let urls = Culling.imageURLs(of: item.group)
        let leaders = [item.group.primary]
        CullingUndo.perform(
            .flag, urls: urls, store: services.metadataStore, undoManager: windowUndoManager,
            compute: { Culling.toggledFlagValues(urls: urls, leaders: leaders, previous: $0) },
            onChange: { [weak self] values in self?.cullingDidChange(values) },
            onFailure: { [weak self] error in self?.contentRoot.toast(CullingUndo.failureMessage(.flag, error: error)) }, suppressing: watcherScope)
    }

    /// Saved values landed (also after undo / redo): update the pill,
    /// flash it if it is auto-hidden, and keep a paired Browser in step.
    func cullingDidChange(_ values: [URL: FileRecord]) {
        applyCullingValues(values, flash: true)
        pairedBrowser?.applyCullingValues(values)
    }

    /// Updates the cached records (no forwarding).
    func applyCullingValues(_ values: [URL: FileRecord], flash: Bool = false) {
        for (url, record) in values { cullingRecords[url] = record }
        cullingReadGuard.noteWrite(values.keys)
        refreshPositionMarks(flash: flash)
        contentRoot.refreshFilmstripMarks()
        refreshReviewRecord()
    }

    // MARK: Records

    /// One batched read for every group in the list.
    func loadCullingRecords() {
        // A closed window reads nothing (its first navigation can finish
        // after close, and its store may be going away).
        guard !didTearDown else { return }
        let urls = list.groups.map(\.primary)
        let generation = list.generation
        let store = services.metadataStore
        let backups = services.backupStore
        contentRoot.filmstripMarks = { [weak self] index in
            guard let self, let group = self.list[index],
                  let record = self.cullingRecords[group.primary] else { return (0, false) }
            return (record.rating, record.flagged)
        }
        // Values written while the read is in flight are newer than what
        // it returns: they are kept. The records land
        // as soon as they are read; the slower badge read lands after.
        let recordsToken = cullingReadGuard.begin()
        let badgesToken = badgeReadGuard.begin()
        Task { @MainActor [weak self] in
            guard self?.didTearDown == false else { return }
            let records = await store.records(for: urls)
            if let gate = self?.cullingReadGateForTesting { await gate() }
            guard let readBadges = self?.applyRecordsRead(
                records, urls: urls, backups: backups, generation: generation, token: recordsToken
            ) else { return }
            let extras = await readBadges()
            self?.applyBadgesRead(extras, generation: generation, token: badgesToken)
        }
    }

    /// First half of the batched read: ratings and flags. Returns the
    /// badge read to run next, or nil when the list changed meanwhile.
    private func applyRecordsRead(
        _ records: [URL: FileRecord], urls: [URL], backups: BackupStore?, generation: UInt64, token: Int
    ) -> (@Sendable () async -> [URL: FileBadgeExtras])? {
        guard !didTearDown, list.generation == generation else { return nil }
        cullingRecords = cullingReadGuard.merge(read: records, current: cullingRecords, since: token)
        refreshPositionMarks(flash: false)
        contentRoot.refreshFilmstripMarks()
        if let reader = badgeExtrasReaderForTesting { return { await reader(urls) } }
        return { await Self.readBadgeExtras(urls, backups: backups) }
    }

    /// Second half: Finder tags and edit marks (slower, xattr reads).
    private func applyBadgesRead(_ extras: [URL: FileBadgeExtras], generation: UInt64, token: Int) {
        guard !didTearDown, list.generation == generation else { return }
        fileBadges = badgeReadGuard.merge(read: extras, current: fileBadges, since: token)
        refreshPositionMarks(flash: false)
        contentRoot.refreshFilmstripMarks()
    }

    /// Finder tags (xattr reads) and backup states, off the main actor.
    nonisolated static func readBadgeExtras(_ urls: [URL], backups: BackupStore?) async -> [URL: FileBadgeExtras] {
        let tags = await Task.detached(priority: .utility) {
            var out: [URL: [FinderTag]] = [:]
            for url in urls { out[url] = FinderTags.readWithColors(url) }
            return out
        }.value
        let states = await backups?.states(for: urls) ?? [:]
        var out: [URL: FileBadgeExtras] = [:]
        for url in urls {
            out[url] = FileBadgeExtras(tags: tags[url] ?? [], edited: states[url] == .edited)
        }
        return out
    }

    /// Re-reads one file's tags (after a tag edit or a watcher event).
    func refreshTags(for urls: [URL]) {
        for url in urls {
            var extras = fileBadges[url] ?? FileBadgeExtras()
            extras.tags = FinderTags.readWithColors(url)
            fileBadges[url] = extras
        }
        badgeReadGuard.noteWrite(urls)
        refreshPositionMarks(flash: true)
    }

    // MARK: Pill marks

    func positionMarks(for index: Int) -> PillMarks {
        guard let group = list[index] else { return PillMarks() }
        let record = cullingRecords[group.primary]
        let extras = fileBadges[group.primary]
        // A pair (primary + RAW companion) gets the two-part chip; which
        // part is lit follows the source that is (about to be) shown.
        let isPair = !group.primaryIsRAW && group.rawURL != nil
        var rawShown = false
        if isPair, let file = intent.sourceAt(index) as? FileImageSource, let raw = group.rawURL {
            rawShown = GroupList.canonical(file.url) == GroupList.canonical(raw)
        }
        return PillMarks(
            rating: record?.rating ?? 0,
            flagged: record?.flagged ?? false,
            hasRAW: group.hasRAW,
            tags: extras?.tags ?? [],
            edited: extras?.edited ?? false,
            pairKind: isPair ? Self.chipKindName(of: group.primary) : nil,
            rawShown: rawShown
        )
    }

    // MARK: Inspector rows

    /// The inspector's Culling and Edits rows act like the menu commands.
    func wireInspectorActions() {
        let panel = contentRoot.inspectorPanel
        panel.onRate = { [weak self] stars in self?.rateDisplayed(stars) }
        panel.onToggleFlag = { [weak self] in self?.toggleFlagDisplayed() }
        panel.onRemoveTag = { [weak self] name in self?.removeTagFromDisplayed(name) }
        panel.onAddTag = { [weak self] anchor in self?.showTagEditor(anchor: anchor) }
        panel.onRevert = { [weak self] in self?.revertDisplayedToOriginal() }
    }

    /// The "Also:" line and the Edits row of the displayed file.
    func refreshInspectorFileState() {
        let panel = contentRoot.inspectorPanel
        panel.updateAlsoLine(displayedItem.flatMap { PairCopy.alsoLine(for: $0.group, shownURL: $0.shownURL) })
        guard let url = displayedItem?.group.primary,
              let store = services.backupStore else {
            panel.updateOriginalDate(nil, backupExpected: false)
            return
        }
        Task { [weak self] in
            let availability = await store.availability(for: url)
            let original = availability.canRevert ? availability.originalDate : nil
            guard let self, self.displayedItem?.group.primary == url else { return }
            // latestDate is set once any edit was saved; without it there
            // is nothing to back up, so the panel stays quiet.
            self.contentRoot.inspectorPanel.updateOriginalDate(original, backupExpected: availability.latestDate != nil)
        }
    }

    func refreshPositionMarks(flash: Bool) {
        let index = displayedItem?.listIndex ?? intent.currentIndex
        contentRoot.setPositionMarks(positionMarks(for: index), flash: flash)
        refreshInspectorFileState()
    }

    /// Menu check marks: Image ▸ Rating ▸ and Flag.
    func cullingMenuState(for command: ShrikeCommand) -> NSControl.StateValue {
        guard let primary = displayedItem?.group.primary else { return .off }
        let record = cullingRecords[primary] ?? FileRecord()
        switch command {
        case .rate0: return record.rating == 0 ? .on : .off
        case .rate1: return record.rating == 1 ? .on : .off
        case .rate2: return record.rating == 2 ? .on : .off
        case .rate3: return record.rating == 3 ? .on : .off
        case .rate4: return record.rating == 4 ? .on : .off
        case .rate5: return record.rating == 5 ? .on : .off
        case .toggleFlag: return record.flagged ? .on : .off
        default: return .off
        }
    }
}

@MainActor
private final class ReviewDecision { var didAdvance = false }
