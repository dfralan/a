// a

import SwiftData
import SwiftUI

// MARK: - Notifications View

struct NotificationsView: View {
  @EnvironmentObject var nostrData: NostrData
  @EnvironmentObject var keyManager: KeyManager

  @Query private var profiles: [RUserProfile]

  @State private var filter: ActivityNotificationFilter = .all
  @StateObject private var activityController = ActivityController()

  init() {
    var profileDescriptor = FetchDescriptor<RUserProfile>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    profileDescriptor.fetchLimit = 500
    _profiles = Query(profileDescriptor)
  }

  var body: some View {
    Group {
      if activePublicKey == nil {
        noKeyView
      } else {
        activityList
      }
    }
    .navigationTitle("Activity")
    .navigationBarTitleDisplayMode(.large)
    .task(id: activityTaskID) {
      guard let activePublicKey else { return }
      activityController.configure(modelContainer: nostrData.modelContainer, nostrData: nostrData)
      activityController.setScope(
        ActivityScope(publicKey: activePublicKey, kinds: filter.activityKinds)
      )
      activityController.bootstrap()
      activityController.fetchLatest(force: false)
    }
  }

  private var activePublicKey: String? {
    keyManager.publicKeyHex(for: keyManager.selectedKey)
  }

  private var activityTaskID: String {
    "\(activePublicKey ?? "none"):\(filter.rawValue)"
  }

  private var profilesByPublicKey: [String: RUserProfile] {
    Dictionary(profiles.map { ($0.publicKey, $0) }, uniquingKeysWith: { first, _ in first })
  }

  private var activityList: some View {
    List {
      Section {
        Picker("Filter", selection: $filter) {
          ForEach(ActivityNotificationFilter.allCases) { filter in
            Text(filter.title).tag(filter)
          }
        }
        .pickerStyle(.segmented)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
      }

      if activityController.visibleItems.isEmpty {
        Section {
          ActivityEmptyState(filter: filter, isLoading: activityController.isLoadingOlder)
        }
        .listRowBackground(Color.clear)
      } else {
        ForEach(ActivityTimeSection.sections(for: activityController.visibleItems)) { section in
          Section(section.title) {
            ForEach(section.items) { item in
              NavigationLink(value: navigationRoute(for: item)) {
                ActivityNotificationRow(
                  item: item,
                  actorProfile: profilesByPublicKey[item.actorPublicKey]
                )
              }
            }
          }
        }
      }

      if activityController.isLoadingOlder {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("Loading more")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
      } else if activityController.canLoadOlder {
        Color.clear
          .frame(height: 20)
          .onAppear {
            activityController.loadOlder()
          }
      } else if !activityController.visibleItems.isEmpty {
        Text("No earlier activity")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      }
    }
    .listStyle(.insetGrouped)
    .refreshable {
      await activityController.refresh()
    }
  }

  private var noKeyView: some View {
    ContentUnavailableView(
      "Select a Key",
      systemImage: "bell.badge",
      description: Text("Activity is shown for the active key.")
    )
  }

  private func navigationRoute(for item: ActivityItem) -> AppNavigation.Route {
    switch item.route {
    case .profile(let publicKey):
      return .profile(publicKey: publicKey)
    case .event(let reference):
      return .event(reference: reference)
    }
  }

}

@MainActor
private final class ActivityController: ObservableObject {
  @Published private(set) var visibleItems: [ActivityItem] = []
  @Published private(set) var isLoadingOlder = false
  @Published private(set) var hasReachedOlderEnd = false

  private weak var nostrData: NostrData?
  private var modelContainer: ModelContainer?
  private var observerID: UUID?
  private var scope: ActivityScope?
  private var visibleIDs = Set<String>()
  private var olderCursor: ActivityCursor?
  private var generation = 0

  private let pageSize = 25
  private let relayFetchPageSize = 80

  var canLoadOlder: Bool {
    scope != nil && !hasReachedOlderEnd
  }

  func configure(modelContainer: ModelContainer, nostrData: NostrData) {
    guard self.modelContainer == nil else { return }

    self.modelContainer = modelContainer
    self.nostrData = nostrData
    observerID = nostrData.observePersistedActivityItems { [weak self] items in
      Task { @MainActor in
        self?.receivePersistedActivityItems(items)
      }
    }
  }

  func setScope(_ scope: ActivityScope) {
    guard self.scope != scope else { return }

    self.scope = scope
    reset()
  }

  func bootstrap() {
    guard visibleItems.isEmpty, !isLoadingOlder else { return }

    let cachedItems = fetchCachedItems(through: nil, limit: pageSize)
    append(cachedItems)
    hasReachedOlderEnd = false

    if cachedItems.isEmpty {
      loadOlder()
    }
  }

  func fetchLatest(force: Bool) {
    guard let scope else { return }

    NostrData.shared.storedRelays.ensureDefaultRelays()
    nostrData?.fetchActivity(forPublicKey: scope.publicKey, force: force)
  }

  func refresh() async {
    reset()
    fetchLatest(force: true)
  }

  func loadOlder() {
    guard !isLoadingOlder, canLoadOlder, let scope else { return }

    isLoadingOlder = true

    let localItems = fetchCachedItems(through: olderCursor?.date ?? oldestVisible, limit: pageSize)
    if !localItems.isEmpty {
      append(localItems)
      isLoadingOlder = false
      return
    }

    guard let nostrData else {
      hasReachedOlderEnd = true
      isLoadingOlder = false
      return
    }

    let requestedScope = scope
    let requestedCursor = olderCursor ?? oldestVisible.map(ActivityCursor.init(date:))
    let requestedGeneration = generation

    Task {
      let page = await nostrData.fetchOlderActivityPage(
        scope: requestedScope,
        cursor: requestedCursor,
        limit: relayFetchPageSize
      )

      await MainActor.run {
        finishOlderLoad(page: page, generation: requestedGeneration)
      }
    }
  }

  private var oldestVisible: Date? {
    visibleItems.last?.createdAt
  }

  private var newestVisible: Date? {
    visibleItems.first?.createdAt
  }

  private func reset() {
    generation += 1
    visibleItems.removeAll()
    visibleIDs.removeAll()
    olderCursor = nil
    isLoadingOlder = false
    hasReachedOlderEnd = false
    bootstrap()
  }

  private func receivePersistedActivityItems(_ items: [ActivityItem]) {
    guard let scope else { return }

    let ownEventIDs = fetchOwnEventIDs()
    let matchingItems = items
      .filter { scope.matches($0, ownEventIDs: ownEventIDs) }
      .filter { $0.actorPublicKey != scope.publicKey }

    guard !matchingItems.isEmpty else { return }

    if visibleItems.isEmpty {
      append(Array(matchingItems.prefix(pageSize)))
      return
    }

    let newerItems = matchingItems.filter { item in
      guard let newestVisible else { return true }
      return item.createdAt > newestVisible
    }

    prepend(newerItems)
  }

  private func finishOlderLoad(
    page: ActivityPage<ActivityItem>,
    generation: Int
  ) {
    guard generation == self.generation else { return }

    if let cursor = page.cursor {
      olderCursor = cursor
    }

    let appendedCount = append(Array(page.items.prefix(pageSize)))
    if appendedCount > 0 {
      isLoadingOlder = false
      return
    }

    if page.exhausted {
      hasReachedOlderEnd = true
      isLoadingOlder = false
      return
    }

    isLoadingOlder = false
    loadOlder()
  }

  @discardableResult
  private func append(_ items: [ActivityItem]) -> Int {
    var appendedCount = 0

    for item in items where visibleIDs.insert(item.id).inserted {
      visibleItems.append(item)
      appendedCount += 1
    }

    visibleItems.sort(by: Self.sortNewestFirst)
    updateOlderCursor()
    return appendedCount
  }

  private func prepend(_ items: [ActivityItem]) {
    guard !items.isEmpty else { return }

    for item in items where visibleIDs.insert(item.id).inserted {
      visibleItems.append(item)
    }

    visibleItems.sort(by: Self.sortNewestFirst)
    updateOlderCursor()
  }

  private func updateOlderCursor() {
    olderCursor = visibleItems.last.map {
      ActivityCursor(until: max(0, $0.createdAtTimestamp - 1))
    }
  }

  private func fetchCachedItems(
    through date: Date?,
    limit: Int
  ) -> [ActivityItem] {
    guard let modelContainer, let scope else { return [] }

    let context = ModelContext(modelContainer)
    let cutoff = date ?? Date()
    let fetchLimit = max(limit * 8, 120)
    let ownEventIDs = fetchOwnEventIDs(in: context, scope: scope)
    var actorPublicKeys = Set<String>()
    var items: [ActivityItem] = []

    if scope.includesReactions {
      var descriptor = FetchDescriptor<RReaction>(
        predicate: #Predicate { $0.createdAt <= cutoff },
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = fetchLimit
      let reactions = (try? context.fetch(descriptor)) ?? []
      actorPublicKeys.formUnion(reactions.map(\.reactorPublicKey))
      let profilesByPublicKey = profiles(for: actorPublicKeys, in: context)

      items.append(
        contentsOf: reactions.map {
          ActivityItem(
            reaction: $0,
            actorProfile: profilesByPublicKey[$0.reactorPublicKey]
          )
        }
      )
    }

    if scope.includesFollows {
      var descriptor = FetchDescriptor<RFollowNotification>(
        predicate: #Predicate { $0.createdAt <= cutoff },
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = fetchLimit
      let notifications = (try? context.fetch(descriptor)) ?? []
      actorPublicKeys.formUnion(notifications.map(\.followerPublicKey))
      let profilesByPublicKey = profiles(for: actorPublicKeys, in: context)

      items.append(
        contentsOf: notifications.map {
          ActivityItem(
            followNotification: $0,
            actorProfile: profilesByPublicKey[$0.followerPublicKey]
          )
        }
      )
    }

    if scope.includesThreadActivity {
      var descriptor = FetchDescriptor<RThreadEvent>(
        predicate: #Predicate { $0.createdAt <= cutoff },
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = fetchLimit
      let threadItems = ((try? context.fetch(descriptor)) ?? [])
        .compactMap { $0.threadItem() }
      actorPublicKeys.formUnion(threadItems.map(\.publicKey))
      let profilesByPublicKey = profiles(for: actorPublicKeys, in: context)

      items.append(
        contentsOf: threadItems.compactMap {
          ActivityItem(
            threadItem: $0,
            targetPublicKey: scope.publicKey,
            actorProfile: profilesByPublicKey[$0.publicKey]
          )
        }
      )
    }

    return items
      .filter { !visibleIDs.contains($0.id) }
      .filter { $0.actorPublicKey != scope.publicKey }
      .filter { scope.matches($0, ownEventIDs: ownEventIDs) }
      .sorted(by: Self.sortNewestFirst)
      .prefix(limit)
      .map { $0 }
  }

  private func fetchOwnEventIDs() -> Set<String> {
    guard let modelContainer, let scope else { return [] }

    return fetchOwnEventIDs(in: ModelContext(modelContainer), scope: scope)
  }

  private func fetchOwnEventIDs(in context: ModelContext, scope: ActivityScope) -> Set<String> {
    guard scope.includesReactions else { return [] }

    let publicKey = scope.publicKey
    var descriptor = FetchDescriptor<RTextNote>(
      predicate: #Predicate { $0.publicKey == publicKey },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = 1_000

    return Set(((try? context.fetch(descriptor)) ?? []).map(\.eventId))
  }

  private func profiles(
    for publicKeys: Set<String>,
    in context: ModelContext
  ) -> [String: RUserProfile] {
    guard !publicKeys.isEmpty else { return [:] }

    var descriptor = FetchDescriptor<RUserProfile>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = 800

    let profiles = (try? context.fetch(descriptor)) ?? []
    return Dictionary(
      profiles
        .filter { publicKeys.contains($0.publicKey) }
        .map { ($0.publicKey, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private static func sortNewestFirst(_ lhs: ActivityItem, _ rhs: ActivityItem) -> Bool {
    if lhs.createdAtTimestamp == rhs.createdAtTimestamp {
      return lhs.id < rhs.id
    }

    return lhs.createdAtTimestamp > rhs.createdAtTimestamp
  }

  deinit {
    guard let observerID else { return }
    let nostrData = nostrData
    Task { @MainActor in
      nostrData?.removePersistedActivityObserver(observerID)
    }
  }
}

private enum ActivityNotificationFilter: String, CaseIterable, Identifiable {
  case all
  case reactions
  case conversations
  case follows

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "All"
    case .reactions: return "Likes"
    case .conversations: return "Replies"
    case .follows: return "Follows"
    }
  }

  var activityKinds: Set<ActivityKind> {
    switch self {
    case .all: return [.reaction, .follow, .reply, .mention]
    case .reactions: return [.reaction]
    case .conversations: return [.reply, .mention]
    case .follows: return [.follow]
    }
  }
}

private struct ActivityTimeSection: Identifiable {
  let id: String
  let title: String
  let items: [ActivityItem]

  static func sections(for items: [ActivityItem]) -> [ActivityTimeSection] {
    let now = Date()
    let calendar = Calendar.current
    let last7Days = calendar.date(byAdding: .day, value: -7, to: now) ?? now
    let last30Days = calendar.date(byAdding: .day, value: -30, to: now) ?? now

    let recent = items.filter { $0.createdAt >= last7Days }
    let monthly = items.filter { $0.createdAt < last7Days && $0.createdAt >= last30Days }
    let earlier = items.filter { $0.createdAt < last30Days }

    return [
      ActivityTimeSection(id: "7", title: "Last 7 Days", items: recent),
      ActivityTimeSection(id: "30", title: "Last 30 Days", items: monthly),
      ActivityTimeSection(id: "earlier", title: "Earlier", items: earlier),
    ]
    .filter { !$0.items.isEmpty }
  }
}

private struct ActivityEmptyState: View {
  let filter: ActivityNotificationFilter
  let isLoading: Bool

  var body: some View {
    VStack(spacing: 12) {
      if isLoading {
        ProgressView()
          .controlSize(.regular)
      } else {
        Image(systemName: systemImage)
          .font(.system(size: 34, weight: .regular))
          .foregroundStyle(.secondary)
      }

      Text(title)
        .font(.headline)

      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 300)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
  }

  private var systemImage: String {
    switch filter {
    case .all: return "bell"
    case .reactions: return "heart"
    case .conversations: return "bubble.left.and.bubble.right"
    case .follows: return "person.2"
    }
  }

  private var title: String {
    if isLoading {
      return "Loading Activity"
    }

    switch filter {
    case .all: return "No Activity"
    case .reactions: return "No Likes"
    case .conversations: return "No Replies"
    case .follows: return "No Follows"
    }
  }

  private var message: String {
    switch filter {
    case .all:
      return "Likes, replies, mentions, and follows for the active key will appear here."
    case .reactions:
      return "Likes on your posts will appear here."
    case .conversations:
      return "Replies and mentions for the active key will appear here."
    case .follows:
      return "New followers for the active key will appear here."
    }
  }
}

private struct ActivityNotificationRow: View {
  let item: ActivityItem
  let actorProfile: RUserProfile?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack(alignment: .bottomTrailing) {
        AvatarView(publicKey: item.actorPublicKey, url: avatarURL, size: 48)

        Image(systemName: badgeImage)
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 18, height: 18)
          .background(badgeColor, in: Circle())
          .overlay {
            Circle()
              .stroke(Color(.systemGroupedBackground), lineWidth: 2)
          }
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(displayName)
            .font(.body.weight(.semibold))
            .lineLimit(1)

          Text(dateLabel)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Text(item.context)
          .font(.subheadline)
          .foregroundStyle(.secondary)

        if let detail = item.detail, !detail.isEmpty {
          Text(detail)
            .font(.body)
            .lineLimit(2)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private var displayName: String {
    if let name = actorProfile?.name, name.isValidName() {
      return name
    }

    if item.actorName.isValidName() {
      return item.actorName
    }

    return (bech32_pubkey(item.actorPublicKey) ?? item.actorPublicKey).accordionString(index: 10)
  }

  private var avatarURL: URL? {
    if let avatarURL = actorProfile?.avatarUrl {
      return avatarURL
    }

    let trimmedPicture = item.actorPicture.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPicture.isEmpty, let url = URL(string: trimmedPicture), url.scheme != nil else {
      return nil
    }

    return url
  }

  private var badgeImage: String {
    switch item.kind {
    case .reaction: return "heart.fill"
    case .follow: return "person.fill"
    case .reply: return "bubble.left.fill"
    case .mention: return "at"
    }
  }

  private var badgeColor: Color {
    switch item.kind {
    case .reaction: return .red
    case .follow: return .accentColor
    case .reply, .mention: return .accentColor
    }
  }

  private var dateLabel: String {
    if Calendar.current.isDateInToday(item.createdAt) {
      return Self.timeFormatter.string(from: item.createdAt)
    }

    if Calendar.current.isDateInYesterday(item.createdAt) {
      return "Yesterday"
    }

    return Self.dateFormatter.string(from: item.createdAt)
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()
}

struct NotificationsView_Previews: PreviewProvider {
  static var previews: some View {
    NavigationStack {
      NotificationsView()
    }
    .environmentObject(NostrData.shared)
    .environmentObject(KeyManager())
    .modelContainer(NostrData.shared.modelContainer)
  }
}
