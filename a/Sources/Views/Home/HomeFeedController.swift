// a

import Combine
import Foundation
import SwiftData

@MainActor
final class HomeFeedController: ObservableObject {
  private(set) var modelContainer: ModelContainer?
  private(set) weak var nostrData: NostrData?

  @Published private(set) var visibleItems: [FeedItem] = []
  @Published private(set) var pendingNewerCount = 0
  @Published private(set) var isLoadingOlder = false
  @Published private(set) var isLoadingNewer = false
  @Published private(set) var hasReachedOlderEnd = false
  @Published private(set) var hasPrunedNewerItems = false
  @Published private(set) var liveCollectionState: HomeLiveCollectionState =
    .inactive(needsRebase: false)

  private var visibleIds = Set<String>()
  private var pendingNewerIds = Set<String>()
  private var admissionPendingCount = 0
  private var olderCursor: FeedCursor?
  private var olderBuffer: [FeedItem] = []
  private var olderBufferSource = "none"
  private var observerID: UUID?
  private var homeLiveObserverID: UUID?
  private var scope: FeedScope = .global
  private var feedGeneration = 0
  private var olderLoadSequence = 0
  private var lastVisibleItemID: String?
  private var lastViewportIDs: [String] = []
  private var latestScrollOffsetPoints = 0

  let pageSize = 1
  let initialPageSize = 12
  let maximumVisibleItems = 16
  private let memoryWarningVisibleItemLimit = 8
  private let olderPrefetchPageSize = 20
  private let relayFetchPageSize = 20
  private let latestRelayFetchPageSize = 24
  private let maximumPendingNewerNotes = 100
  private let debugLoggingEnabled = true

  var oldestVisible: Date? {
    visibleItems.last?.createdAt
  }

  var newestVisible: Date? {
    visibleItems.first?.createdAt
  }

  var canLoadOlder: Bool {
    !olderBuffer.isEmpty || !hasReachedOlderEnd
  }

  var needsLatestRebase: Bool {
    switch liveCollectionState {
    case .inactive(needsRebase: true), .saturated, .refreshFailed:
      return true
    case .inactive, .collecting, .refreshing:
      return false
    }
  }

  func configure(modelContainer: ModelContainer, nostrData: NostrData) {
    guard self.modelContainer == nil else { return }

    self.modelContainer = modelContainer
    self.nostrData = nostrData
    observerID = nostrData.observePersistedTextNotes { [weak self] summaries in
      Task { @MainActor in
        self?.receivePersistedTextNotes(summaries)
      }
    }
    homeLiveObserverID = nostrData.observeHomeLiveCollection { [weak self] snapshot in
      Task { @MainActor in
        self?.receiveHomeLiveSnapshot(snapshot)
      }
    }
    _ = nostrData.activateHomeLiveCollection()
  }

  func setScope(_ scope: FeedScope) {
    guard self.scope != scope else { return }

    self.scope = scope
    reset()
  }

  func bootstrap() {
    guard visibleItems.isEmpty, !isLoadingOlder else { return }

    let initialItems = fetchCachedItems(through: nil, limit: initialPageSize)
    appendVisibleItems(initialItems, pruning: .oldest)
    hasPrunedNewerItems = false
    hasReachedOlderEnd = false

    if initialItems.isEmpty {
      loadOlder()
    }
  }

  func reset() {
    feedGeneration += 1
    visibleItems.removeAll()
    visibleIds.removeAll()
    lastVisibleItemID = nil
    lastViewportIDs.removeAll()
    clearPendingNewer()
    olderCursor = nil
    clearOlderBuffer()
    isLoadingOlder = false
    isLoadingNewer = false
    hasReachedOlderEnd = false
    hasPrunedNewerItems = false
    nostrData?.resetHomeLiveCollection(collecting: true)
    bootstrap()
  }

  func resetForIdentityChange() {
    reset()
  }

  func recordVisibleItems(_ eventIDs: [String]) {
    let currentIDs = eventIDs.filter(visibleIds.contains)
    guard currentIDs != lastViewportIDs else { return }

    lastViewportIDs = currentIDs
    if let firstVisibleID = currentIDs.first {
      lastVisibleItemID = firstVisibleID
    }
    logDebug(
      "viewport offset~\(latestScrollOffsetPoints)pt first=\(Self.shortID(currentIDs.first)) last=\(Self.shortID(currentIDs.last)) onscreen=\(currentIDs.count) rendered=\(visibleItems.count) buffer=\(olderBuffer.count)"
    )
  }

  func recordScrollOffset(points: Int) {
    latestScrollOffsetPoints = points
  }

  func recordOlderBoundaryVisibility(_ isVisible: Bool) {
    logDebug(
      "boundary visible=\(isVisible) offset~\(latestScrollOffsetPoints)pt rendered=\(visibleItems.count) buffer=\(olderBuffer.count) loading=\(isLoadingOlder) exhausted=\(hasReachedOlderEnd)"
    )
  }

  @discardableResult
  func setActive(_ isActive: Bool) -> Bool {
    guard let nostrData else { return false }
    if isActive {
      return nostrData.activateHomeLiveCollection()
    }

    nostrData.deactivateHomeLiveCollection()
    return false
  }

  func receivePersistedTextNotes(_ summaries: [PersistedTextNoteSummary]) {
    let now = Date()
    let matchingItems = summaries
      .map { ($0, FeedItem(summary: $0)) }
      .filter {
        scope.textNoteFeedScope.matches($0.1)
          && TextNoteFeedPolicy.accepts(createdAt: $0.1.createdAt, now: now)
      }
    guard !matchingItems.isEmpty else { return }

    if visibleItems.isEmpty {
      bootstrap()
      return
    }

    var visibleHistoricalItems: [FeedItem] = []

    for (summary, item) in matchingItems {
      guard !visibleIds.contains(item.id),
        !pendingNewerIds.contains(item.id)
      else {
        continue
      }

      if let newestVisible,
        item.createdAt <= newestVisible
      {
        if summary.origin == .historicalRelay,
          let oldestVisible,
          item.createdAt >= oldestVisible
        {
          visibleHistoricalItems.append(item)
        }
        continue
      }

      guard summary.origin != .historicalRelay else { continue }
      guard case .collecting = liveCollectionState else { continue }
      pendingNewerIds.insert(item.id)
    }

    if !visibleHistoricalItems.isEmpty {
      appendVisibleItems(visibleHistoricalItems, pruning: .oldest)
    }

    if pendingNewerIds.count > maximumPendingNewerNotes {
      pendingNewerIds = Set(pendingNewerIds.prefix(maximumPendingNewerNotes))
    }
    updatePendingNewerCount()
  }

  @discardableResult
  func refreshToLatest() async -> Int {
    guard !isLoadingNewer else { return 0 }
    guard let nostrData else { return 0 }

    isLoadingNewer = true
    defer { isLoadingNewer = false }
    let generation = feedGeneration
    nostrData.beginHomeLatestRefresh()

    let page = await nostrData.fetchLatestFeedPage(
      scope: scope,
      limit: latestRelayFetchPageSize
    )

    guard generation == feedGeneration else { return 0 }

    guard !page.items.isEmpty else {
      nostrData.failHomeLatestRefresh()
      return 0
    }

    let committedItems = nostrData.completeHomeLatestRefresh(pageItems: page.items)
    let latestItems = Array(committedItems.prefix(initialPageSize))
    guard !latestItems.isEmpty else {
      nostrData.failHomeLatestRefresh()
      return 0
    }

    feedGeneration += 1
    visibleItems = latestItems
    visibleIds = Set(latestItems.map(\.id))
    lastVisibleItemID = latestItems.first?.id
    lastViewportIDs.removeAll()
    hasPrunedNewerItems = false
    olderCursor = latestItems.last.map {
      FeedCursor(until: max(0, $0.createdAtTimestamp - 1))
    }
    clearPendingNewer()
    clearOlderBuffer()
    isLoadingOlder = false
    hasReachedOlderEnd = false

    if let newest = latestItems.first?.createdAt {
      nostrData.updateLastSeenDate(to: newest)
    }

    return latestItems.count
  }

  func loadOlder(trigger: String = "manual") {
    logDebug(
      "older demand trigger=\(trigger) offset~\(latestScrollOffsetPoints)pt rendered=\(visibleItems.count) buffer=\(olderBuffer.count) loading=\(isLoadingOlder) exhausted=\(hasReachedOlderEnd) cursor=\(Self.debugDate(olderCursor?.date ?? oldestVisible))"
    )

    guard !isLoadingOlder else {
      logDebug("older demand ignored reason=in-flight trigger=\(trigger)")
      return
    }
    guard canLoadOlder else {
      logDebug("older demand ignored reason=exhausted trigger=\(trigger)")
      return
    }

    if consumeNextBufferedOlderItem(trigger: trigger) > 0 {
      return
    }

    isLoadingOlder = true
    olderLoadSequence += 1
    let requestID = olderLoadSequence
    let cursorDate = olderCursor?.date ?? oldestVisible

    let localItems = fetchCachedItems(
      through: olderCursor?.date ?? oldestVisible,
      limit: olderPrefetchPageSize
    )
    if !localItems.isEmpty {
      let oldestBefore = oldestVisible
      prepareOlderBuffer(localItems, source: "cache")
      let appendedCount = consumeNextBufferedOlderItem(trigger: trigger)
      logOlderPage(
        requestID: requestID,
        trigger: trigger,
        source: "cache",
        receivedCount: localItems.count,
        uniqueCount: localItems.count,
        alreadyVisibleCount: 0,
        appendedCount: appendedCount,
        oldestBefore: oldestBefore,
        oldestAfter: oldestVisible
      )
      isLoadingOlder = false
      return
    }

    guard let nostrData else {
      hasReachedOlderEnd = true
      isLoadingOlder = false
      return
    }

    let generation = feedGeneration
    let requestedScope = scope
    let requestedCursor = olderCursor ?? oldestVisible.map(FeedCursor.init(date:))

    logDebug(
      "older request#\(requestID) trigger=\(trigger) source=relay scope=\(requestedScope.debugDescription) cursor=\(Self.debugDate(cursorDate)) pageLimit=\(pageSize) relayLimit=\(relayFetchPageSize) visible=\(visibleItems.count)"
    )

    Task {
      let page = await nostrData.fetchOlderFeedPage(
        scope: requestedScope,
        cursor: requestedCursor,
        limit: relayFetchPageSize
      )

      await MainActor.run {
        finishOlderLoad(
          page: page,
          generation: generation,
          requestID: requestID,
          trigger: trigger
        )
      }
    }
  }

  private func finishOlderLoad(
    page: FeedPage<FeedItem>,
    generation: Int,
    requestID: Int,
    trigger: String
  ) {
    guard generation == feedGeneration else { return }

    let oldestBefore = oldestVisible
    let uniqueItems = Self.uniqued(page.items)
    let bufferedIDs = Set(olderBuffer.map(\.id))
    let appendCandidates = uniqueItems.filter {
      !visibleIds.contains($0.id) && !bufferedIDs.contains($0.id)
    }
    let alreadyVisibleCount = uniqueItems.count - appendCandidates.count
    if let cursor = page.cursor {
      olderCursor = cursor
    }
    prepareOlderBuffer(appendCandidates, source: "relay", updateCursor: false)
    let appendedCount = consumeNextBufferedOlderItem(trigger: trigger)

    logOlderPage(
      requestID: requestID,
      trigger: trigger,
      source: "relay",
      receivedCount: page.items.count,
      uniqueCount: uniqueItems.count,
      alreadyVisibleCount: alreadyVisibleCount,
      appendedCount: appendedCount,
      oldestBefore: oldestBefore,
      oldestAfter: oldestVisible
    )

    if appendedCount > 0 {
      isLoadingOlder = false
      return
    }

    if page.exhausted {
      hasReachedOlderEnd = true
      isLoadingOlder = false
      logDebug("older eof request#\(requestID) scope=\(scope.debugDescription)")
      return
    }

    logDebug(
      "older boundary advance request#\(requestID) received=\(page.items.count) unique=\(uniqueItems.count) visible=0 scope=\(scope.debugDescription)"
    )
    isLoadingOlder = false
    loadOlder(trigger: "boundary-advance")
  }

  @discardableResult
  private func appendVisibleItems(_ items: [FeedItem], pruning: VisiblePruning) -> Int {
    var updatedItems = visibleItems
    var updatedIDs = visibleIds
    var appendedCount = 0

    for item in items where updatedIDs.insert(item.id).inserted {
      updatedItems.append(item)
      appendedCount += 1
    }

    guard appendedCount > 0 else { return 0 }

    updatedItems.sort(by: Self.sortNewestFirst)

    if updatedItems.count > maximumVisibleItems {
      let overflow = updatedItems.count - maximumVisibleItems
      let removedItems: [FeedItem]

      switch pruning {
      case .newest:
        removedItems = Array(updatedItems.prefix(overflow))
        updatedItems.removeFirst(overflow)
        hasPrunedNewerItems = true
      case .oldest:
        removedItems = Array(updatedItems.suffix(overflow))
        updatedItems.removeLast(overflow)
      case .none:
        removedItems = []
      }

      for item in removedItems {
        updatedIDs.remove(item.id)
      }
    }

    visibleIds = updatedIDs
    visibleItems = updatedItems

    if pruning != .none {
      updateOlderCursor()
    }

    return appendedCount
  }

  private func prepareOlderBuffer(
    _ items: [FeedItem],
    source: String,
    updateCursor: Bool = true
  ) {
    let uniqueItems = Self.uniqued(items)
      .filter { !visibleIds.contains($0.id) }
      .sorted(by: Self.sortNewestFirst)
    olderBuffer = Array(uniqueItems.prefix(olderPrefetchPageSize))
    olderBufferSource = source

    if updateCursor, let oldestBufferedItem = olderBuffer.last {
      olderCursor = FeedCursor(until: max(0, oldestBufferedItem.createdAtTimestamp - 1))
    }

    logDebug(
      "older buffer prepared source=\(source) count=\(olderBuffer.count) cursor=\(Self.debugDate(olderCursor?.date)) first=\(Self.shortID(olderBuffer.first?.id)) last=\(Self.shortID(olderBuffer.last?.id))"
    )
  }

  @discardableResult
  private func consumeNextBufferedOlderItem(trigger: String) -> Int {
    while !olderBuffer.isEmpty {
      let source = olderBufferSource
      let item = olderBuffer.removeFirst()
      let renderedBefore = visibleItems.count
      let appendedCount = appendVisibleItems([item], pruning: .none)
      guard appendedCount > 0 else { continue }

      logDebug(
        "older append-one trigger=\(trigger) source=\(source) id=\(Self.shortID(item.id)) rendered=\(renderedBefore)->\(visibleItems.count) bufferRemaining=\(olderBuffer.count) offset~\(latestScrollOffsetPoints)pt"
      )
      return appendedCount
    }

    olderBufferSource = "none"
    return 0
  }

  private func clearOlderBuffer() {
    olderBuffer.removeAll(keepingCapacity: false)
    olderBufferSource = "none"
  }

  private func updateOlderCursor() {

    if let oldest = visibleItems.last {
      olderCursor = FeedCursor(until: max(0, oldest.createdAtTimestamp - 1))
    } else {
      olderCursor = nil
    }
  }

  private func clearPendingNewer() {
    pendingNewerIds.removeAll(keepingCapacity: true)
    admissionPendingCount = 0
    pendingNewerCount = 0
  }

  private func receiveHomeLiveSnapshot(_ snapshot: HomeLiveAdmissionSnapshot) {
    let previousState = liveCollectionState
    liveCollectionState = snapshot.state
    admissionPendingCount = min(snapshot.pendingCount, maximumPendingNewerNotes)
    updatePendingNewerCount()

    if case .inactive(needsRebase: true) = snapshot.state,
      previousState != snapshot.state
    {
      applyMemoryPressureReset()
    }
  }

  private func applyMemoryPressureReset() {
    feedGeneration += 1
    isLoadingOlder = false
    isLoadingNewer = false
    hasReachedOlderEnd = false
    pendingNewerIds.removeAll(keepingCapacity: false)
    clearOlderBuffer()
    lastViewportIDs.removeAll()
    admissionPendingCount = 0
    pendingNewerCount = 0

    guard visibleItems.count > memoryWarningVisibleItemLimit else {
      visibleIds = Set(visibleItems.map(\.id))
      updateOlderCursor()
      return
    }

    let anchorIndex = lastVisibleItemID
      .flatMap { eventID in visibleItems.firstIndex { $0.id == eventID } }
      ?? 0
    let preferredItemsBeforeAnchor = memoryWarningVisibleItemLimit / 2
    let maximumStartIndex = visibleItems.count - memoryWarningVisibleItemLimit
    let startIndex = min(
      max(0, anchorIndex - preferredItemsBeforeAnchor),
      maximumStartIndex
    )
    let endIndex = startIndex + memoryWarningVisibleItemLimit
    let retainedItems = Array(visibleItems[startIndex..<endIndex])

    if startIndex > 0 {
      hasPrunedNewerItems = true
    }
    visibleItems = retainedItems
    visibleIds = Set(retainedItems.map(\.id))
    lastVisibleItemID = retainedItems.contains { $0.id == lastVisibleItemID }
      ? lastVisibleItemID
      : retainedItems.first?.id
    updateOlderCursor()
  }

  private func updatePendingNewerCount() {
    pendingNewerCount = min(
      max(pendingNewerIds.count, admissionPendingCount),
      maximumPendingNewerNotes
    )
  }

  private func fetchCachedItems(
    through date: Date?,
    limit: Int,
    excludingVisible: Bool = true
  ) -> [FeedItem] {
    guard let modelContainer else { return [] }

    let context = ModelContext(modelContainer)
    let futureCutoff = Date().addingTimeInterval(TextNoteFeedPolicy.maximumFutureSkew)
    let cutoff = date.map { min($0, futureCutoff) } ?? futureCutoff
    var noteDescriptor = FetchDescriptor<RTextNote>(
      predicate: #Predicate { $0.createdAt <= cutoff },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )

    noteDescriptor.fetchLimit = fetchLimit(forPageSize: limit)

    var repostDescriptor = FetchDescriptor<RRepost>(
      predicate: #Predicate { $0.createdAt <= cutoff },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    repostDescriptor.fetchLimit = fetchLimit(forPageSize: limit)

    let notes = (try? context.fetch(noteDescriptor)) ?? []
    let reposts = (try? context.fetch(repostDescriptor)) ?? []
    return
      (notes.map(FeedItem.init(textNote:)) + reposts.compactMap(FeedItem.init(repost:)))
      .sorted(by: Self.sortNewestFirst)
      .filter { !excludingVisible || !visibleIds.contains($0.id) }
      .filter { scope.textNoteFeedScope.matches($0) }
      .prefix(limit)
      .map { $0 }
  }

  private func fetchLimit(forPageSize limit: Int) -> Int {
    scope == .global ? limit * 8 : max(limit * 24, 240)
  }

  private static func sortNewestFirst(_ lhs: FeedItem, _ rhs: FeedItem) -> Bool {
    if lhs.createdAtTimestamp == rhs.createdAtTimestamp {
      return lhs.id < rhs.id
    }

    return lhs.createdAtTimestamp > rhs.createdAtTimestamp
  }

  private static func uniqued(_ items: [FeedItem]) -> [FeedItem] {
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
  }

  private enum VisiblePruning: Equatable {
    case newest
    case oldest
    case none
  }

  private func logDebug(_ message: String) {
    guard debugLoggingEnabled else { return }
    print("HomeFeedController: \(message)")
  }

  private func logOlderPage(
    requestID: Int,
    trigger: String,
    source: String,
    receivedCount: Int,
    uniqueCount: Int,
    alreadyVisibleCount: Int,
    appendedCount: Int,
    oldestBefore: Date?,
    oldestAfter: Date?
  ) {
    logDebug(
      "older page#\(requestID) trigger=\(trigger) source=\(source) scope=\(scope.debugDescription) received=\(receivedCount) unique=\(uniqueCount) alreadyVisible=\(alreadyVisibleCount) pageLimit=\(pageSize) appended=\(appendedCount) oldestBefore=\(Self.debugDate(oldestBefore)) oldestAfter=\(Self.debugDate(oldestAfter))"
    )
  }

  private static func debugDate(_ date: Date?) -> String {
    guard let date else { return "nil" }
    return "\(Int64(date.timeIntervalSince1970))"
  }

  private static func shortID(_ id: String?) -> String {
    guard let id else { return "nil" }
    return String(id.prefix(8))
  }

  deinit {
    let nostrData = nostrData
    let observerID = observerID
    let homeLiveObserverID = homeLiveObserverID
    Task { @MainActor in
      if let observerID {
        nostrData?.removePersistedTextNoteObserver(observerID)
      }
      if let homeLiveObserverID {
        nostrData?.removeHomeLiveCollectionObserver(homeLiveObserverID)
      }
    }
  }
}
