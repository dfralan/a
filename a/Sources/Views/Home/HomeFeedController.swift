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

  private var pendingNewer: [FeedItem] = []
  private var visibleIds = Set<String>()
  private var pendingNewerIds = Set<String>()
  private var olderCursor: FeedCursor?
  private var observerID: UUID?
  private var scope: FeedScope = .global
  private var feedGeneration = 0
  private var olderLoadSequence = 0

  let pageSize = 10
  let initialPageSize = 12
  let maximumVisibleItems = 24
  private let relayFetchPageSize = 80
  private let maximumPendingNewerNotes = 100
  private let debugLoggingEnabled = true

  var oldestVisible: Date? {
    visibleItems.last?.createdAt
  }

  var newestVisible: Date? {
    visibleItems.first?.createdAt
  }

  var canLoadOlder: Bool {
    !hasReachedOlderEnd
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
    clearPendingNewer()
    olderCursor = nil
    isLoadingOlder = false
    isLoadingNewer = false
    hasReachedOlderEnd = false
    hasPrunedNewerItems = false
    bootstrap()
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

      pendingNewer.append(item)
      pendingNewerIds.insert(item.id)
    }

    if !visibleHistoricalItems.isEmpty {
      appendVisibleItems(visibleHistoricalItems, pruning: .oldest)
    }

    pendingNewer.sort(by: Self.sortNewestFirst)

    if pendingNewer.count > maximumPendingNewerNotes {
      pendingNewer = Array(pendingNewer.prefix(maximumPendingNewerNotes))
      pendingNewerIds = Set(pendingNewer.map(\.id))
    }

    pendingNewerCount = pendingNewer.count
  }

  @discardableResult
  func refreshToLatest() -> Int {
    guard !isLoadingNewer else { return 0 }

    isLoadingNewer = true
    defer { isLoadingNewer = false }

    let latestItems = fetchCachedItems(through: nil, limit: initialPageSize, excludingVisible: false)
    guard !latestItems.isEmpty else { return 0 }

    feedGeneration += 1
    visibleItems = latestItems
    visibleIds = Set(latestItems.map(\.id))
    hasPrunedNewerItems = false
    olderCursor = latestItems.last.map {
      FeedCursor(until: max(0, $0.createdAtTimestamp - 1))
    }
    clearPendingNewer()
    isLoadingOlder = false
    hasReachedOlderEnd = false

    if let newest = latestItems.first?.createdAt {
      nostrData?.updateLastSeenDate(to: newest)
    }

    return latestItems.count
  }

  func loadOlder(trigger: String = "manual") {
    guard !isLoadingOlder, canLoadOlder else { return }

    isLoadingOlder = true
    olderLoadSequence += 1
    let requestID = olderLoadSequence
    let cursorDate = olderCursor?.date ?? oldestVisible

    let localItems = fetchCachedItems(through: olderCursor?.date ?? oldestVisible, limit: pageSize)
    if !localItems.isEmpty {
      let oldestBefore = oldestVisible
      let appendedCount = appendVisibleItems(localItems, pruning: .newest)
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

    if let cursor = page.cursor {
      olderCursor = cursor
    }

    let oldestBefore = oldestVisible
    let uniqueItems = Self.uniqued(page.items)
    let appendCandidates = uniqueItems.filter { !visibleIds.contains($0.id) }
    let alreadyVisibleCount = uniqueItems.count - appendCandidates.count
    let appendedCount = appendVisibleItems(Array(appendCandidates.prefix(pageSize)), pruning: .newest)

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
    var appendedCount = 0

    for item in items where visibleIds.insert(item.id).inserted {
      visibleItems.append(item)
      appendedCount += 1
    }

    visibleItems.sort(by: Self.sortNewestFirst)
    pruneVisibleItemsIfNeeded(pruning)
    updateOlderCursor()

    return appendedCount
  }

  private func pruneVisibleItemsIfNeeded(_ pruning: VisiblePruning) {
    guard visibleItems.count > maximumVisibleItems else { return }

    let overflow = visibleItems.count - maximumVisibleItems
    let removedItems: [FeedItem]

    switch pruning {
    case .newest:
      removedItems = Array(visibleItems.prefix(overflow))
      visibleItems.removeFirst(overflow)
      hasPrunedNewerItems = true
    case .oldest:
      removedItems = Array(visibleItems.suffix(overflow))
      visibleItems.removeLast(overflow)
    }

    for item in removedItems {
      visibleIds.remove(item.id)
    }
  }

  private func updateOlderCursor() {

    if let oldest = visibleItems.last {
      olderCursor = FeedCursor(until: max(0, oldest.createdAtTimestamp - 1))
    } else {
      olderCursor = nil
    }
  }

  private func clearPendingNewer() {
    pendingNewer.removeAll(keepingCapacity: true)
    pendingNewerIds.removeAll(keepingCapacity: true)
    pendingNewerCount = 0
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

  private enum VisiblePruning {
    case newest
    case oldest
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

  deinit {
    guard let observerID else { return }
    let nostrData = nostrData
    Task { @MainActor in
      nostrData?.removePersistedTextNoteObserver(observerID)
    }
  }
}
