/*
 The `NostrRelay` class manages WebSocket communication with Nostr relays and uses **SwiftData** for local persistence.

 1. **Connection Lifecycle**
    - `connect()`: Opens a WebSocket connection and begins listening for messages.
    - `disconnect()`: Stops pinging, cancels the connection, and marks it as disconnected.
    - `retryConnect()`: Attempts to reconnect if the connection is lost (with retry limits).
    - `startPing()`: Sends periodic pings every 30 seconds to keep the session alive.

 2. **Subscriptions**
    - `subscribeProfiles()` and `unsubscribeProfiles()`: Manage subscriptions for user metadata (`setMetadata` events).
    - `subscribeTextNotes()` and `unsubscribeTextNotes()`: Handle subscriptions for text note events.
    - `subscribeContactList(forPublicKey:)`: Subscribes to contact lists (following/followedBy).
    - `unsubscribeContactList(withId:)` and `unsubscribeContactListForAll()`: Remove contact list subscriptions.
    - `subscribe()` / `unsubscribe()`: Convenience methods to manage all subscriptions at once.

 3. **Message Handling**
    - `receiveMessage()`: Listens continuously for incoming WebSocket messages and forwards them to `parse()`.
    - `parse(_:)`: Processes messages based on type (event, notice, EOSE).
      Creates, updates, or links local records (`RUserProfile`, `RTextNote`, `RContactList`) using **SwiftData**.
      Temporary in-memory storage is used before the initial data bootstrap completes.
      Incoming profile and text-note events are deduped, buffered, and saved in small batches.

 4. **Bootstrap Logic**
    - Flushes buffered profiles and notes after the first EOSE (“End of Stored Events”) signal.
    - After bootstrap, new events continue through the same bounded write buffer.

 5. **Integration**
    - Conforms to `URLSessionWebSocketDelegate` to manage WebSocket lifecycle callbacks.
    - Works together with `NostrData` to manage relay connections and persisted data.

 In short, `NostrRelay` handles the live connection to Nostr relays, syncing network events into SwiftData models for offline and real-time use.
 */

import Foundation
import NostrKit
import SwiftData

private final class NostrEventIngestionGate {
  static let shared = NostrEventIngestionGate()

  private let lock = NSLock()
  private var eventIDs = Set<String>()
  private var eventIDQueue: [String] = []
  private let maxEventIDs = 2_000

  func claim(_ eventID: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    guard !eventIDs.contains(eventID) else { return false }

    eventIDs.insert(eventID)
    eventIDQueue.append(eventID)

    while eventIDQueue.count > maxEventIDs {
      let removedID = eventIDQueue.removeFirst()
      eventIDs.remove(removedID)
    }

    return true
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }

    eventIDs.removeAll()
    eventIDQueue.removeAll()
  }
}

struct RelayPersistenceEvent: Sendable {
  let encodedEvent: Data
  let origin: PersistedTextNoteSummary.Origin
}

struct RelayFollowPersistenceEvent: Sendable {
  let encodedEvent: Data
  let targetPublicKey: String
}

struct RelayActivityPersistenceEvent: Sendable {
  let encodedEvent: Data
  let targetPublicKey: String
}

struct RelayPersistenceBatch: Sendable {
  let profileEvents: [Data]
  let textNoteEvents: [RelayPersistenceEvent]
  let repostEvents: [RelayPersistenceEvent]
  let reactionEvents: [Data]
  let followEvents: [RelayFollowPersistenceEvent]
  let threadActivityEvents: [RelayActivityPersistenceEvent]
  let profileFetchedTextNoteIDs: Set<String>

  var isEmpty: Bool {
    profileEvents.isEmpty
      && textNoteEvents.isEmpty
      && repostEvents.isEmpty
      && reactionEvents.isEmpty
      && followEvents.isEmpty
      && threadActivityEvents.isEmpty
      && profileFetchedTextNoteIDs.isEmpty
  }
}

struct RelayPersistenceResult: Sendable {
  let textNoteSummaries: [PersistedTextNoteSummary]
  let activityItems: [ActivityItem]
  let shouldRefreshProfiles: Bool
  let errorDescription: String?
}

@ModelActor
actor RelayPersistenceActor {
  private static let maxStoredActivityItems = 1_000
  private static let pruneBatchSize = 150

  func ingest(_ batch: RelayPersistenceBatch) -> RelayPersistenceResult {
    guard !batch.isEmpty else {
      return RelayPersistenceResult(
        textNoteSummaries: [],
        activityItems: [],
        shouldRefreshProfiles: false,
        errorDescription: nil
      )
    }

    let decoder = JSONDecoder()
    var profileCache: [String: RUserProfile] = [:]
    var textNoteSummaries: [PersistedTextNoteSummary] = []
    var activityItems: [ActivityItem] = []

    for data in batch.profileEvents {
      guard let event = try? decoder.decode(Event.self, from: data) else { continue }
      upsertProfileEvent(event, profileCache: &profileCache)
    }

    for pendingEvent in batch.textNoteEvents {
      guard let event = try? decoder.decode(Event.self, from: pendingEvent.encodedEvent) else {
        continue
      }
      if let summary = insertTextNoteEvent(
        event,
        origin: pendingEvent.origin,
        profileCache: &profileCache
      ) {
        textNoteSummaries.append(summary)
      }
    }

    for pendingEvent in batch.repostEvents {
      guard let event = try? decoder.decode(Event.self, from: pendingEvent.encodedEvent) else {
        continue
      }
      if let summary = insertRepostEvent(
        event,
        origin: pendingEvent.origin,
        profileCache: &profileCache
      ) {
        textNoteSummaries.append(summary)
      }
    }

    markProfileFetchedTextNotes(batch.profileFetchedTextNoteIDs)

    for data in batch.reactionEvents {
      guard let event = try? decoder.decode(Event.self, from: data),
        let reaction = insertReactionEvent(event),
        let activityItem = ActivityItem(
          event: event,
          targetPublicKey: reaction.targetPublicKey,
          actorProfile: profileForPublicKey(event.publicKey, profileCache: &profileCache)
        )
      else {
        continue
      }
      activityItems.append(activityItem)
    }

    var processedFollowIDs = Set<String>()
    for pendingEvent in batch.followEvents {
      guard let event = try? decoder.decode(Event.self, from: pendingEvent.encodedEvent),
        processedFollowIDs.insert(event.id).inserted,
        let notification = insertFollowNotificationEvent(
          event,
          targetPublicKey: pendingEvent.targetPublicKey,
          profileCache: &profileCache
        )
      else {
        continue
      }
      activityItems.append(
        ActivityItem(
          followNotification: notification,
          actorProfile: notification.followerProfile
        )
      )
    }

    for pendingEvent in batch.threadActivityEvents {
      guard let event = try? decoder.decode(Event.self, from: pendingEvent.encodedEvent),
        let item = insertThreadActivityEvent(
          event,
          targetPublicKey: pendingEvent.targetPublicKey,
          profileCache: &profileCache
        )
      else {
        continue
      }
      activityItems.append(item)
    }

    do {
      try modelContext.save()
      if !batch.reactionEvents.isEmpty {
        pruneStoredReactions()
      }
      if !batch.followEvents.isEmpty {
        pruneStoredFollowNotifications()
      }
      if !batch.threadActivityEvents.isEmpty {
        pruneStoredThreadActivityEvents()
      }
      return RelayPersistenceResult(
        textNoteSummaries: textNoteSummaries,
        activityItems: activityItems,
        shouldRefreshProfiles: !batch.profileEvents.isEmpty
          || !batch.textNoteEvents.isEmpty
          || !batch.repostEvents.isEmpty
          || !batch.reactionEvents.isEmpty
          || !batch.followEvents.isEmpty
          || !batch.threadActivityEvents.isEmpty,
        errorDescription: nil
      )
    } catch {
      modelContext.rollback()
      return RelayPersistenceResult(
        textNoteSummaries: [],
        activityItems: [],
        shouldRefreshProfiles: false,
        errorDescription: error.localizedDescription
      )
    }
  }

  private func upsertProfileEvent(
    _ event: Event,
    profileCache: inout [String: RUserProfile]
  ) {
    guard let data = event.content.data(using: .utf8),
      let metadata = try? JSONDecoder().decode(NostrProfileMetadata.self, from: data)
    else {
      return
    }

    let profile = profileForPublicKey(event.publicKey, profileCache: &profileCache)
    let eventDate = Date(timeIntervalSince1970: Double(event.createdAt.timestamp))
    let hasMetadata =
      !profile.name.isEmpty || !profile.about.isEmpty || !profile.picture.isEmpty || !profile.nip05.isEmpty
    guard !hasMetadata || eventDate >= profile.createdAt else { return }

    let nextNIP05 = metadata.normalizedNIP05
    let shouldResetNIP05 = profile.nip05 != nextNIP05

    profile.name = metadata.preferredName
    profile.about = metadata.about ?? ""
    profile.picture = metadata.picture ?? ""
    profile.nip05 = nextNIP05
    if shouldResetNIP05 {
      profile.resetNIP05Verification()
    }
    profile.createdAt = eventDate
  }

  private func insertTextNoteEvent(
    _ event: Event,
    origin: PersistedTextNoteSummary.Origin,
    profileCache: inout [String: RUserProfile]
  ) -> PersistedTextNoteSummary? {
    guard textNote(eventID: event.id) == nil else { return nil }

    let textNote = RTextNote.create(with: event)
    textNote.userProfile = profileForPublicKey(event.publicKey, profileCache: &profileCache)
    modelContext.insert(textNote)
    return PersistedTextNoteSummary(
      eventId: textNote.eventId,
      publicKey: textNote.publicKey,
      content: textNote.content,
      createdAt: textNote.createdAt,
      hashtags: textNote.taggedHashtags,
      isSensitiveContent: textNote.isSensitiveContent,
      sensitiveContentReason: textNote.sensitiveContentReason,
      origin: origin
    )
  }

  private func insertRepostEvent(
    _ event: Event,
    origin: PersistedTextNoteSummary.Origin,
    profileCache: inout [String: RUserProfile]
  ) -> PersistedTextNoteSummary? {
    guard !exists(RRepost.self, eventID: event.id) else { return nil }

    let targetTextNote: RTextNote?
    if let embeddedEvent = RRepost.embeddedTextNoteEvent(from: event) {
      targetTextNote = upsertEmbeddedTextNoteEvent(embeddedEvent, profileCache: &profileCache)
    } else if let targetEventID = RRepost.targetEventID(from: event) {
      targetTextNote = textNote(eventID: targetEventID)
    } else {
      targetTextNote = nil
    }

    guard let targetTextNote,
      let repost = RRepost.create(with: event, targetTextNote: targetTextNote)
    else {
      return nil
    }

    repost.userProfile = profileForPublicKey(event.publicKey, profileCache: &profileCache)
    modelContext.insert(repost)
    return PersistedTextNoteSummary(
      id: repost.eventId,
      eventId: targetTextNote.eventId,
      publicKey: targetTextNote.publicKey,
      content: targetTextNote.content,
      createdAt: repost.createdAt,
      eventCreatedAt: targetTextNote.createdAt,
      hashtags: targetTextNote.taggedHashtags,
      isSensitiveContent: targetTextNote.isSensitiveContent,
      sensitiveContentReason: targetTextNote.sensitiveContentReason,
      origin: origin,
      repost: FeedRepost(repost: repost)
    )
  }

  private func upsertEmbeddedTextNoteEvent(
    _ event: Event,
    profileCache: inout [String: RUserProfile]
  ) -> RTextNote {
    if let existing = textNote(eventID: event.id) {
      return existing
    }

    let textNote = RTextNote.create(with: event)
    textNote.userProfile = profileForPublicKey(event.publicKey, profileCache: &profileCache)
    modelContext.insert(textNote)
    return textNote
  }

  private func markProfileFetchedTextNotes(_ eventIDs: Set<String>) {
    guard !eventIDs.isEmpty else { return }
    let fetchDate = Date()
    for eventID in eventIDs {
      textNote(eventID: eventID)?.lastProfileFetchDate = fetchDate
    }
  }

  private func insertReactionEvent(_ event: Event) -> RReaction? {
    guard !exists(RReaction.self, eventID: event.id),
      let reaction = RReaction.create(with: event)
    else {
      return nil
    }
    modelContext.insert(reaction)
    return reaction
  }

  private func insertFollowNotificationEvent(
    _ event: Event,
    targetPublicKey: String,
    profileCache: inout [String: RUserProfile]
  ) -> RFollowNotification? {
    guard !exists(RFollowNotification.self, eventID: event.id) else { return nil }

    let notification = RFollowNotification.create(with: event, targetPublicKey: targetPublicKey)
    notification.followerProfile = profileForPublicKey(event.publicKey, profileCache: &profileCache)
    modelContext.insert(notification)
    return notification
  }

  private func insertThreadActivityEvent(
    _ event: Event,
    targetPublicKey: String,
    profileCache: inout [String: RUserProfile]
  ) -> ActivityItem? {
    guard let threadItem = ThreadItem(event: event),
      let activityItem = ActivityItem(
        threadItem: threadItem,
        targetPublicKey: targetPublicKey,
        actorProfile: profileForPublicKey(event.publicKey, profileCache: &profileCache)
      )
    else {
      return nil
    }

    if !exists(RThreadEvent.self, eventID: event.id),
      let storedEvent = RThreadEvent(item: threadItem)
    {
      modelContext.insert(storedEvent)
    }
    return activityItem
  }

  private func textNote(eventID: String) -> RTextNote? {
    let targetEventID = eventID
    var descriptor = FetchDescriptor<RTextNote>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    descriptor.fetchLimit = 1
    return try? modelContext.fetch(descriptor).first
  }

  private func exists<Model: PersistentModel>(_ type: Model.Type, eventID: String) -> Bool {
    if type == RRepost.self {
      let targetEventID = eventID
      var descriptor = FetchDescriptor<RRepost>(
        predicate: #Predicate { $0.eventId == targetEventID }
      )
      descriptor.fetchLimit = 1
      return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }
    if type == RReaction.self {
      let targetEventID = eventID
      var descriptor = FetchDescriptor<RReaction>(
        predicate: #Predicate { $0.eventId == targetEventID }
      )
      descriptor.fetchLimit = 1
      return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }
    if type == RFollowNotification.self {
      let targetEventID = eventID
      var descriptor = FetchDescriptor<RFollowNotification>(
        predicate: #Predicate { $0.eventId == targetEventID }
      )
      descriptor.fetchLimit = 1
      return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }
    if type == RThreadEvent.self {
      let targetEventID = eventID
      var descriptor = FetchDescriptor<RThreadEvent>(
        predicate: #Predicate { $0.eventId == targetEventID }
      )
      descriptor.fetchLimit = 1
      return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }
    return false
  }

  private func profileForPublicKey(
    _ publicKey: String,
    profileCache: inout [String: RUserProfile]
  ) -> RUserProfile {
    if let cached = profileCache[publicKey] {
      return cached
    }

    let targetPublicKey = publicKey
    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == targetPublicKey }
    )
    descriptor.fetchLimit = 1
    if let existing = try? modelContext.fetch(descriptor).first {
      profileCache[publicKey] = existing
      return existing
    }

    let profile = RUserProfile.createEmpty(withPublicKey: publicKey)
    modelContext.insert(profile)
    profileCache[publicKey] = profile
    return profile
  }

  private func pruneStoredReactions() {
    var descriptor = FetchDescriptor<RReaction>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = Self.maxStoredActivityItems + Self.pruneBatchSize
    guard let reactions = try? modelContext.fetch(descriptor),
      reactions.count > Self.maxStoredActivityItems
    else {
      return
    }
    for reaction in reactions.dropFirst(Self.maxStoredActivityItems) {
      modelContext.delete(reaction)
    }
    try? modelContext.save()
  }

  private func pruneStoredFollowNotifications() {
    var descriptor = FetchDescriptor<RFollowNotification>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = Self.maxStoredActivityItems + Self.pruneBatchSize
    guard let notifications = try? modelContext.fetch(descriptor),
      notifications.count > Self.maxStoredActivityItems
    else {
      return
    }
    for notification in notifications.dropFirst(Self.maxStoredActivityItems) {
      modelContext.delete(notification)
    }
    try? modelContext.save()
  }

  private func pruneStoredThreadActivityEvents() {
    var descriptor = FetchDescriptor<RThreadEvent>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = Self.maxStoredActivityItems + Self.pruneBatchSize
    guard let events = try? modelContext.fetch(descriptor),
      events.count > Self.maxStoredActivityItems
    else {
      return
    }
    for event in events.dropFirst(Self.maxStoredActivityItems) {
      modelContext.delete(event)
    }
    try? modelContext.save()
  }
}

final class NostrRelay: NSObject, @unchecked Sendable {

  private static let textNoteSubscriptionLimit = 80
  private static let feedEventKinds: [EventKind] = [.textNote, .custom(6)]
  private static let rawFeedEventKinds = [1, 6]
  private static let reactionHistoryWindow: TimeInterval = -6 * 60 * 60
  private static let reactionSubscriptionLimit = 500
  private static let maxBufferedTextNotes = 120
  private static let maxBufferedProfiles = 180
  private static let maxBufferedReactions = 200
  private static let writeBatchSize = 24
  private static let writeBatchDelay: TimeInterval = 0.35
  private static let maxProfileSubscriptionAuthors = 160
  private static let profileSubscriptionLimit = 160
  private static let activitySubscriptionLimit = 100
  private static let maxActivitySubscriptions = 4
  private static let activityPageTimeout: TimeInterval = 10
  private static let profileTextNoteSubscriptionLimit = 80
  private static let maxProfileTextNoteSubscriptions = 8
  private static let profileTextNoteSubscriptionTimeout: TimeInterval = 12
  private static let eventLookupSubscriptionTimeout: TimeInterval = 8
  private static let maxActiveRepostLookups = 4
  private static let maxQueuedRepostLookups = 80
  private static let repostLookupSubscriptionTimeout: TimeInterval = 8
  private static let olderTextNotePageTimeout: TimeInterval = 10
  private static let threadPageTimeout: TimeInterval = 10
  private static let profileSearchTimeout: TimeInterval = 4
  private static let profileRefreshDelay: TimeInterval = 1.5
  private static let contactListFollowingLimit = 1
  private static let contactListFollowedByLimit = 100
  private static let maxContactListProfiles = 300

  let urlString: String
  let modelContainer: ModelContainer
  private let persistenceActor: RelayPersistenceActor
  private let homeLiveAdmission: (String, Int64, FeedItem?) -> HomeLiveAdmissionResult
  var onTextNotesPersisted: (([PersistedTextNoteSummary]) -> Void)?
  var onActivityItemsPersisted: (([ActivityItem]) -> Void)?
  var onProfilesPersisted: (() -> Void)?

  var webSocketTask: URLSessionWebSocketTask?
  var connected = false
  var isConnecting = false
  var shouldReconnect = false
  var pingTimer: Timer?
  var retryCount = 0
  var maxRetries = 5
  private var connectionID = UUID().uuidString

  var subs: Int = 0

  var authors: Set<String> = []

  var homeLiveCursor: Timestamp?
  var bootstrapedProfiles = false
  var bootstrapedTextNotes = false
  var bootstrapedReactions = false

  var textNoteSub: Subscription?
  var profileSub: Subscription?
  var reactionSub: Subscription?

  var contactListSubs: [ContactListSub] = []
  var activitySubs: [ActivitySub] = []
  var profileTextNoteSubs: [ProfileTextNoteSub] = []
  private var textNotePageSubs: [TextNotePageSub] = []
  private var activityPageSubs: [ActivityPageSub] = []
  private var eventLookupSubs: [EventLookupSub] = []
  private var threadPageSubs: [ThreadPageSub] = []
  private var threadEventLookupSubs: [ThreadEventLookupSub] = []
  private var profileSearchSubs: [ProfileSearchSub] = []
  private var repostLookupSubs: [RepostLookupSub] = []
  private var repostLookupQueue: [String] = []
  private var pendingRepostLookupsByTargetID: [String: [PendingRepostEvent]] = [:]
  private var activeRepostLookupTargetIDs = Set<String>()
  private var textNoteFeedScope: TextNoteFeedScope = .global
  private var pendingTextNoteEvents: [PendingTextNoteEvent] = []
  private var pendingRepostEvents: [PendingRepostEvent] = []
  private var pendingProfileEvents: [Event] = []
  private var pendingReactionEvents: [Event] = []
  private var pendingFollowNotificationEvents: [FollowNotificationEvent] = []
  private var pendingThreadActivityEvents: [PendingThreadActivityEvent] = []
  private var profileFetchedTextNoteIDs = Set<String>()
  private var flushWorkItem: DispatchWorkItem?
  private var profileRefreshWorkItem: DispatchWorkItem?
  private var persistenceTask: Task<Void, Never>?

  init(
    urlString: String,
    modelContainer: ModelContainer,
    persistenceActor: RelayPersistenceActor,
    homeLiveAdmission: @escaping (String, Int64, FeedItem?) -> HomeLiveAdmissionResult
  ) {
    self.urlString = urlString
    self.modelContainer = modelContainer
    self.persistenceActor = persistenceActor
    self.homeLiveAdmission = homeLiveAdmission
  }

  private var shortConnectionID: String {
    String(connectionID.prefix(8))
  }

  private func logRelay(_ message: String) {
    print("[\(urlString)] connection=\(shortConnectionID) \(message)")
  }

  static func resetIngestionGate() {
    NostrEventIngestionGate.shared.reset()
  }

  func setTextNoteFeedScope(_ scope: TextNoteFeedScope) {
    guard textNoteFeedScope != scope else { return }

    textNoteFeedScope = scope
    homeLiveCursor = nil
    bootstrapedTextNotes = false

    guard connected else { return }
    subscribeTextNotes()
  }

  func advanceHomeLiveCursor(to timestamp: Int64) {
    let nextCursor = Timestamp(timestamp: Int(timestamp))
    if let homeLiveCursor, homeLiveCursor.timestamp >= nextCursor.timestamp {
      return
    }
    homeLiveCursor = nextCursor
  }

  func connect() {
    guard !connected, !isConnecting else { return }
    guard let url = URL(string: urlString), url.scheme == "wss", url.host != nil else {
      print("Skipping invalid relay URL: \(urlString)")
      return
    }

    shouldReconnect = true
    isConnecting = true
    connectionID = UUID().uuidString
    logRelay("CONNECT")

    let request = URLRequest(url: url)
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    self.webSocketTask = session.webSocketTask(with: request)
    self.webSocketTask?.resume()
    self.receiveMessage()
  }

  func needsProfileSub(for nextAuthors: Set<String>) -> Bool {
    guard !nextAuthors.isEmpty else { return false }
    let currentAuthors = Set(profileSub?.filters.first?.authors ?? [])
    return currentAuthors != nextAuthors
  }

  func subscribeProfiles() {
    let context = ModelContext(modelContainer)
    var descriptor = FetchDescriptor<RUserProfile>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = Self.maxProfileSubscriptionAuthors

    do {
      let profiles = try context.fetch(descriptor)
      let nextAuthors = Set(profiles.map { $0.publicKey })
      guard needsProfileSub(for: nextAuthors) else { return }

      self.authors = nextAuthors
    } catch {
      print("Error fetching profiles: \(error)")
      self.authors = Set()
    }

    if !authors.isEmpty {
      if profileSub != nil {
        unsubscribeProfiles()
      }
      self.profileSub = Subscription(filters: [
        .init(
          authors: Array(authors.prefix(Self.maxProfileSubscriptionAuthors)),
          eventKinds: [.setMetadata],
          limit: Self.profileSubscriptionLimit
        )
      ])
      if let profileSub {
        if let cm = try? ClientMessage.subscribe(profileSub).string() {
          self.webSocketTask?.send(
            .string(cm),
            completionHandler: { error in
              if let error = error {
                print(error)
              }
            })
        }
      }
    }
  }

  func unsubscribeProfiles() {
    if let profileSub = profileSub, connected {
      if let cm = try? ClientMessage.unsubscribe(profileSub.id).string() {
        self.webSocketTask?.send(
          .string(cm),
          completionHandler: { error in
            if let error {
              print(error)
            }
          })
      }
    }
    self.profileSub = nil
  }

  func subscribeTextNotes() {
    if textNoteSub != nil {
      unsubscribeTextNotes()
    }

    let now = Date()
    let lastSeenDate = homeLiveCursor.map {
      Date(timeIntervalSince1970: Double($0.timestamp))
    }
    let hasValidCursor = lastSeenDate.map {
      TextNoteFeedPolicy.accepts(createdAt: $0, now: now)
    } ?? false
    let since = hasValidCursor ? homeLiveCursor : nil

    if !hasValidCursor {
      homeLiveCursor = nil
    }

    if let filters = standardTextNoteFilters(
      scope: textNoteFeedScope,
      since: since,
      until: nil,
      limit: Self.textNoteSubscriptionLimit
    ) {
      guard !filters.isEmpty else { return }

      self.textNoteSub = Subscription(filters: filters)
      if let textNoteSub {
        sendSubscribe(textNoteSub)
      }
      return
    }

    let rawFilters = rawTextNoteFilters(
      scope: textNoteFeedScope,
      since: since,
      until: nil,
      limit: Self.textNoteSubscriptionLimit
    )
    guard !rawFilters.isEmpty else { return }

    self.textNoteSub = Subscription(filters: [], id: UUID().uuidString)
    if let textNoteSub {
      sendRawSubscribe(id: textNoteSub.id, filters: rawFilters)
    }
  }

  func unsubscribeTextNotes() {
    if let textNoteSub = textNoteSub, connected {
      if let cm = try? ClientMessage.unsubscribe(textNoteSub.id).string() {
        self.webSocketTask?.send(
          .string(cm),
          completionHandler: { error in
            if let error {
              print(error)
            }
          })
      }
    }
    self.textNoteSub = nil
  }

  func subscribeOlderTextNotes(
    until date: Date,
    limit: Int,
    scope: TextNoteFeedScope = .global,
    completion: @escaping ([PersistedTextNoteSummary]) -> Void
  ) {
    let until = Timestamp(date: date)
    let subscriptionID = UUID().uuidString
    let standardFilters = standardTextNoteFilters(
      scope: scope,
      since: nil,
      until: until,
      limit: limit
    )
    let rawFilters =
      standardFilters == nil
      ? rawTextNoteFilters(scope: scope, since: nil, until: until, limit: limit)
      : nil

    guard standardFilters?.isEmpty == false || rawFilters?.isEmpty == false else {
      completion([])
      return
    }

    let subscription = Subscription(filters: standardFilters ?? [], id: subscriptionID)

    let pageSub = TextNotePageSub(
      subscription: subscription,
      rawFilters: rawFilters,
      scope: scope,
      purpose: .older,
      receivedEvents: [],
      summaryCompletion: completion,
      feedItemCompletion: nil
    )
    textNotePageSubs.append(pageSub)
    sendTextNotePageSubscribe(pageSub)
    scheduleOlderTextNotePageTimeout(subscriptionID: subscription.id)
  }

  func subscribeOlderFeedItems(
    until date: Date,
    limit: Int,
    scope: TextNoteFeedScope = .global,
    completion: @escaping ([FeedItem]) -> Void
  ) {
    let until = Timestamp(date: date)
    let subscriptionID = UUID().uuidString
    let standardFilters = standardTextNoteFilters(
      scope: scope,
      since: nil,
      until: until,
      limit: limit
    )
    let rawFilters =
      standardFilters == nil
      ? rawTextNoteFilters(scope: scope, since: nil, until: until, limit: limit)
      : nil

    guard standardFilters?.isEmpty == false || rawFilters?.isEmpty == false else {
      completion([])
      return
    }

    let subscription = Subscription(filters: standardFilters ?? [], id: subscriptionID)

    let pageSub = TextNotePageSub(
      subscription: subscription,
      rawFilters: rawFilters,
      scope: scope,
      purpose: .older,
      receivedEvents: [],
      summaryCompletion: nil,
      feedItemCompletion: completion
    )
    textNotePageSubs.append(pageSub)
    logRelay(
      "REQ purpose=older-text-notes sub=\(subscriptionID) scope=\(scope.debugDescription) until=\(Int64(date.timeIntervalSince1970)) limit=\(limit)"
    )
    sendTextNotePageSubscribe(pageSub)
    scheduleOlderTextNotePageTimeout(subscriptionID: subscription.id)
  }

  func subscribeLatestFeedItems(
    limit: Int,
    scope: TextNoteFeedScope = .global,
    completion: @escaping ([FeedItem]) -> Void
  ) {
    let subscriptionID = UUID().uuidString
    let standardFilters = standardTextNoteFilters(
      scope: scope,
      since: nil,
      until: nil,
      limit: limit
    )
    let rawFilters =
      standardFilters == nil
      ? rawTextNoteFilters(scope: scope, since: nil, until: nil, limit: limit)
      : nil

    guard standardFilters?.isEmpty == false || rawFilters?.isEmpty == false else {
      completion([])
      return
    }

    let subscription = Subscription(filters: standardFilters ?? [], id: subscriptionID)
    let pageSub = TextNotePageSub(
      subscription: subscription,
      rawFilters: rawFilters,
      scope: scope,
      purpose: .latest,
      receivedEvents: [],
      summaryCompletion: nil,
      feedItemCompletion: completion
    )
    textNotePageSubs.append(pageSub)
    logRelay(
      "REQ purpose=latest-text-notes sub=\(subscriptionID) scope=\(scope.debugDescription) limit=\(limit)"
    )
    sendTextNotePageSubscribe(pageSub)
    scheduleOlderTextNotePageTimeout(subscriptionID: subscription.id)
  }

  private func scheduleOlderTextNotePageTimeout(subscriptionID: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.olderTextNotePageTimeout) { [weak self] in
      self?.completeOlderTextNotePage(withId: subscriptionID, reason: "timeout")
    }
  }

  private func completeOlderTextNotePage(withId subscriptionID: String, reason: String = "timeout") {
    guard let index = textNotePageSubs.firstIndex(where: { $0.subscription.id == subscriptionID })
    else {
      return
    }

    let sub = textNotePageSubs.remove(at: index)
    unsubscribe(subscriptionID: sub.subscription.id)
    flushPendingEvents()

    let sortedEvents = sub.receivedEvents
      .sorted {
        if $0.createdAt.timestamp == $1.createdAt.timestamp {
          return $0.id < $1.id
        }

        return $0.createdAt.timestamp > $1.createdAt.timestamp
      }

    let feedItems = sortedEvents.compactMap(FeedItem.init(networkEvent:))
    logRelay(
      "PAGE-END purpose=\(sub.purpose.logValue) reason=\(reason) sub=\(subscriptionID) scope=\(sub.scope.debugDescription) receivedEvents=\(sortedEvents.count) feedItems=\(feedItems.count)"
    )
    let summaries = feedItems
      .map {
        PersistedTextNoteSummary(
          id: $0.id,
          eventId: $0.eventId,
          publicKey: $0.pubkey,
          content: $0.content,
          createdAt: $0.createdAt,
          eventCreatedAt: $0.eventCreatedAt,
          hashtags: $0.hashtags,
          isSensitiveContent: $0.isSensitiveContent,
          sensitiveContentReason: $0.sensitiveContentReason,
          repost: $0.repost
        )
      }

    sub.summaryCompletion?(summaries)
    sub.feedItemCompletion?(feedItems)
  }

  private func unsubscribeOlderTextNotePagesForAll() {
    let subs = textNotePageSubs
    textNotePageSubs.removeAll()

    for sub in subs {
      unsubscribe(subscriptionID: sub.subscription.id)
      sub.summaryCompletion?([])
      sub.feedItemCompletion?([])
    }
  }

  struct ActivitySub {
    let subscription: Subscription
    var publicKey: String
  }

  private struct ActivityPageSub {
    let subscription: Subscription
    let scope: ActivityScope
    var receivedEvents: [Event]
    let completion: ([ActivityItem]) -> Void
  }

  func subscribeActivity(forPublicKey publicKey: String) {
    unsubscribeActivityForAll()

    let subscription = Subscription(filters: [
      .init(
        eventKinds: [.custom(7)],
        pubKeyTags: [publicKey],
        limit: Self.activitySubscriptionLimit
      ),
      .init(
        eventKinds: [.custom(3)],
        pubKeyTags: [publicKey],
        limit: Self.activitySubscriptionLimit
      ),
      .init(
        eventKinds: [.textNote, .custom(1111)],
        pubKeyTags: [publicKey],
        limit: Self.activitySubscriptionLimit
      ),
    ])

    let activitySub = ActivitySub(subscription: subscription, publicKey: publicKey)
    activitySubs.append(activitySub)

    while activitySubs.count > Self.maxActivitySubscriptions {
      let expiredSub = activitySubs.removeFirst()
      unsubscribe(subscriptionID: expiredSub.subscription.id)
    }

    sendSubscribe(subscription)
  }

  func subscribeOlderActivityItems(
    scope: ActivityScope,
    until date: Date,
    limit: Int,
    completion: @escaping ([ActivityItem]) -> Void
  ) {
    let until = Timestamp(date: date)
    var filters: [EventFilter] = []

    if scope.includesReactions {
      filters.append(
        .init(
          eventKinds: [.custom(7)],
          pubKeyTags: [scope.publicKey],
          until: until,
          limit: limit
        )
      )
    }

    if scope.includesFollows {
      filters.append(
        .init(
          eventKinds: [.custom(3)],
          pubKeyTags: [scope.publicKey],
          until: until,
          limit: limit
        )
      )
    }

    if scope.includesThreadActivity {
      filters.append(
        .init(
          eventKinds: [.textNote, .custom(1111)],
          pubKeyTags: [scope.publicKey],
          until: until,
          limit: limit
        )
      )
    }

    guard !filters.isEmpty else {
      completion([])
      return
    }

    let subscription = Subscription(filters: filters, id: UUID().uuidString)
    let pageSub = ActivityPageSub(
      subscription: subscription,
      scope: scope,
      receivedEvents: [],
      completion: completion
    )

    activityPageSubs.append(pageSub)
    sendSubscribe(subscription)
    scheduleActivityPageTimeout(subscriptionID: subscription.id)
  }

  private func scheduleActivityPageTimeout(subscriptionID: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.activityPageTimeout) { [weak self] in
      self?.completeActivityPage(withId: subscriptionID)
    }
  }

  private func completeActivityPage(withId subscriptionID: String) {
    guard let index = activityPageSubs.firstIndex(where: { $0.subscription.id == subscriptionID })
    else {
      return
    }

    let sub = activityPageSubs.remove(at: index)
    unsubscribe(subscriptionID: sub.subscription.id)
    flushPendingEvents()

    let items = sub.receivedEvents
      .compactMap { ActivityItem(event: $0, targetPublicKey: sub.scope.publicKey) }
      .filter { sub.scope.matches($0) }
      .sorted {
        if $0.createdAtTimestamp == $1.createdAtTimestamp {
          return $0.id < $1.id
        }

        return $0.createdAtTimestamp > $1.createdAtTimestamp
      }

    sub.completion(items)
  }

  private func activityTargetPublicKey(for subscriptionID: String, event: Event) -> String? {
    guard let activitySub = activitySubs.first(where: { $0.subscription.id == subscriptionID }),
      event.tags.contains(where: {
        $0.id == "p" && $0.otherInformation.first == activitySub.publicKey
      })
    else {
      return nil
    }

    return activitySub.publicKey
  }

  private func activityPageTargetPublicKey(for subscriptionID: String, event: Event) -> String? {
    guard let activityPageSub = activityPageSubs.first(where: { $0.subscription.id == subscriptionID }),
      event.tags.contains(where: {
        $0.id == "p" && $0.otherInformation.first == activityPageSub.scope.publicKey
      })
    else {
      return nil
    }

    return activityPageSub.scope.publicKey
  }

  private func unsubscribeActivityForAll() {
    let subs = activitySubs
    activitySubs.removeAll()

    for sub in subs {
      unsubscribe(subscriptionID: sub.subscription.id)
    }
  }

  private func unsubscribeActivityPagesForAll() {
    let subs = activityPageSubs
    activityPageSubs.removeAll()

    for sub in subs {
      unsubscribe(subscriptionID: sub.subscription.id)
      sub.completion([])
    }
  }

  struct ProfileTextNoteSub {
    let subscription: Subscription
    var publicKey: String
  }

  private struct RawTextNoteFilter: Encodable {
    let kinds: [Int]
    let authors: [String]?
    let eventReferences: [String]?
    let hashtags: [String]?
    let search: String?
    let since: Int?
    let until: Int?
    let limit: Int?

    enum CodingKeys: String, CodingKey {
      case kinds
      case authors
      case eventReferences = "#e"
      case hashtags = "#t"
      case search
      case since
      case until
      case limit
    }
  }

  private struct RawThreadFilter: Encodable {
    let kind: Int
    let indexedTag: String
    let indexedValue: String
    let until: Int64?
    let limit: Int

    private struct DynamicCodingKey: CodingKey {
      let stringValue: String
      let intValue: Int? = nil

      init(_ stringValue: String) {
        self.stringValue = stringValue
      }

      init?(stringValue: String) {
        self.init(stringValue)
      }

      init?(intValue: Int) {
        return nil
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: DynamicCodingKey.self)
      try container.encode([kind], forKey: DynamicCodingKey("kinds"))
      try container.encode(
        [indexedValue],
        forKey: DynamicCodingKey("#\(indexedTag)")
      )
      try container.encodeIfPresent(until, forKey: DynamicCodingKey("until"))
      try container.encode(limit, forKey: DynamicCodingKey("limit"))
    }
  }

  private struct RawProfileSearchFilter: Encodable {
    let kinds: [Int]
    let authors: [String]?
    let search: String?
    let limit: Int
  }

  private enum TextNotePagePurpose {
    case latest
    case older

    var logValue: String {
      switch self {
      case .latest: return "latest-text-notes"
      case .older: return "older-text-notes"
      }
    }
  }

  private struct TextNotePageSub {
    let subscription: Subscription
    let rawFilters: [RawTextNoteFilter]?
    let scope: TextNoteFeedScope
    let purpose: TextNotePagePurpose
    var receivedEvents: [Event]
    let summaryCompletion: (([PersistedTextNoteSummary]) -> Void)?
    let feedItemCompletion: (([FeedItem]) -> Void)?
  }

  private struct EventLookupSub {
    let subscription: Subscription
    let eventID: String
    var receivedEvents: [Event]
    let completion: ([FeedItem]) -> Void
  }

  private struct ThreadPageSub {
    let subscriptionID: String
    let query: ThreadRelayQuery
    var receivedEvents: [Event]
    let completion: ([Event]) -> Void
  }

  private struct ThreadEventLookupSub {
    let subscription: Subscription
    let eventID: String
    let eventKind: Int?
    var receivedEvents: [Event]
    let completion: ([Event]) -> Void
  }

  private struct ProfileSearchSub {
    let subscriptionID: String
    let query: ProfileSearchRelayQuery
    var receivedEvents: [Event]
    let completion: ([Event]) -> Void
  }

  @discardableResult
  func subscribeProfileSearch(
    query: ProfileSearchRelayQuery,
    completion: @escaping ([Event]) -> Void
  ) -> String {
    let subscriptionID = UUID().uuidString
    let sub = ProfileSearchSub(
      subscriptionID: subscriptionID,
      query: query,
      receivedEvents: [],
      completion: completion
    )
    profileSearchSubs.append(sub)
    sendProfileSearchSubscribe(sub)
    let mode = query.mode.isExactPublicKey ? "exact-key" : "nip50-text"
    logRelay(
      "REQ purpose=profile-search sub=\(subscriptionID) mode=\(mode) limit=\(query.limit)"
    )
    scheduleProfileSearchTimeout(subscriptionID: subscriptionID)
    return subscriptionID
  }

  func cancelProfileSearch(subscriptionID: String) {
    guard let index = profileSearchSubs.firstIndex(where: {
      $0.subscriptionID == subscriptionID
    }) else { return }

    let sub = profileSearchSubs.remove(at: index)
    unsubscribe(subscriptionID: subscriptionID)
    sub.completion([])
  }

  private func unsubscribeProfileSearchesForAll() {
    let subs = profileSearchSubs
    profileSearchSubs.removeAll()
    for sub in subs {
      unsubscribe(subscriptionID: sub.subscriptionID)
      sub.completion([])
    }
  }

  @discardableResult
  func subscribeThreadPage(
    query: ThreadRelayQuery,
    completion: @escaping ([Event]) -> Void
  ) -> String {
    let subscriptionID = UUID().uuidString
    let sub = ThreadPageSub(
      subscriptionID: subscriptionID,
      query: query,
      receivedEvents: [],
      completion: completion
    )
    threadPageSubs.append(sub)
    sendThreadPageSubscribe(sub)
    let untilDescription = query.until.map(String.init) ?? "latest"
    logRelay(
      "REQ purpose=thread-replies sub=\(subscriptionID) kind=\(query.eventKind) #\(query.indexedTag)=\(query.indexedValue) until=\(untilDescription) limit=\(query.limit)"
    )
    scheduleThreadPageTimeout(subscriptionID: subscriptionID)
    return subscriptionID
  }

  @discardableResult
  func subscribeThreadEvent(
    eventID: String,
    eventKind: Int?,
    completion: @escaping ([Event]) -> Void
  ) -> String {
    let eventKinds = eventKind.map { [Self.eventKind($0)] }
    let subscription = Subscription(
      filters: [
        .init(ids: [eventID], eventKinds: eventKinds, limit: 1)
      ],
      id: UUID().uuidString
    )
    let sub = ThreadEventLookupSub(
      subscription: subscription,
      eventID: eventID,
      eventKind: eventKind,
      receivedEvents: [],
      completion: completion
    )
    threadEventLookupSubs.append(sub)
    sendSubscribe(subscription)
    let kindDescription = eventKind.map(String.init) ?? "any"
    logRelay(
      "REQ purpose=thread-event sub=\(subscription.id) event=\(eventID) kind=\(kindDescription)"
    )
    scheduleThreadEventLookupTimeout(subscriptionID: subscription.id)
    return subscription.id
  }

  func cancelThreadRequest(subscriptionID: String) {
    if let index = threadPageSubs.firstIndex(where: { $0.subscriptionID == subscriptionID }) {
      let sub = threadPageSubs.remove(at: index)
      unsubscribe(subscriptionID: subscriptionID)
      sub.completion([])
      return
    }

    if let index = threadEventLookupSubs.firstIndex(where: {
      $0.subscription.id == subscriptionID
    }) {
      let sub = threadEventLookupSubs.remove(at: index)
      unsubscribe(subscriptionID: subscriptionID)
      sub.completion([])
    }
  }

  private func unsubscribeThreadRequestsForAll() {
    let pageSubs = threadPageSubs
    let lookupSubs = threadEventLookupSubs
    threadPageSubs.removeAll()
    threadEventLookupSubs.removeAll()

    for sub in pageSubs {
      unsubscribe(subscriptionID: sub.subscriptionID)
      sub.completion([])
    }
    for sub in lookupSubs {
      unsubscribe(subscriptionID: sub.subscription.id)
      sub.completion([])
    }
  }

  private static func eventKind(_ value: Int) -> EventKind {
    switch value {
    case 0: return .setMetadata
    case 1: return .textNote
    case 2: return .recommentServer
    default: return .custom(value)
    }
  }

  private func scheduleThreadPageTimeout(subscriptionID: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.threadPageTimeout) { [weak self] in
      self?.completeThreadPage(subscriptionID: subscriptionID, reason: "timeout")
    }
  }

  private func scheduleProfileSearchTimeout(subscriptionID: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.profileSearchTimeout) { [weak self] in
      self?.completeProfileSearch(subscriptionID: subscriptionID, reason: "timeout")
    }
  }

  private func completeProfileSearch(subscriptionID: String, reason: String) {
    guard let index = profileSearchSubs.firstIndex(where: {
      $0.subscriptionID == subscriptionID
    }) else { return }

    let sub = profileSearchSubs.remove(at: index)
    unsubscribe(subscriptionID: subscriptionID)
    let events = sub.receivedEvents.sorted(by: Self.newestEventFirst)
    logRelay(
      "PAGE-END purpose=profile-search reason=\(reason) sub=\(subscriptionID) raw=\(events.count)"
    )
    sub.completion(events)
  }

  private func scheduleThreadEventLookupTimeout(subscriptionID: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.threadPageTimeout) { [weak self] in
      self?.completeThreadEventLookup(subscriptionID: subscriptionID, reason: "timeout")
    }
  }

  private func completeThreadPage(subscriptionID: String, reason: String) {
    guard let index = threadPageSubs.firstIndex(where: { $0.subscriptionID == subscriptionID })
    else { return }

    let sub = threadPageSubs.remove(at: index)
    unsubscribe(subscriptionID: subscriptionID)
    let events = sub.receivedEvents.sorted(by: Self.newestEventFirst)
    logRelay(
      "PAGE-END purpose=thread-replies reason=\(reason) sub=\(subscriptionID) raw=\(events.count)"
    )
    sub.completion(events)
  }

  private func completeThreadEventLookup(subscriptionID: String, reason: String) {
    guard let index = threadEventLookupSubs.firstIndex(where: {
      $0.subscription.id == subscriptionID
    }) else { return }

    let sub = threadEventLookupSubs.remove(at: index)
    unsubscribe(subscriptionID: subscriptionID)
    let events = sub.receivedEvents
      .filter { $0.id == sub.eventID }
      .sorted(by: Self.newestEventFirst)
    logRelay(
      "PAGE-END purpose=thread-event reason=\(reason) sub=\(subscriptionID) raw=\(events.count)"
    )
    sub.completion(events)
  }

  private static func newestEventFirst(_ lhs: Event, _ rhs: Event) -> Bool {
    if lhs.createdAt.timestamp == rhs.createdAt.timestamp {
      return lhs.id < rhs.id
    }
    return lhs.createdAt.timestamp > rhs.createdAt.timestamp
  }

  private struct RepostLookupSub {
    let subscription: Subscription
    let targetEventID: String
    var receivedEvents: [Event]
  }

  func subscribeTextNoteEvent(
    eventID: String,
    completion: @escaping ([FeedItem]) -> Void
  ) {
    let subscription = Subscription(
      filters: [
        .init(
          ids: [eventID],
          eventKinds: [.textNote],
          limit: 1
        )
      ],
      id: UUID().uuidString
    )
    let lookupSub = EventLookupSub(
      subscription: subscription,
      eventID: eventID,
      receivedEvents: [],
      completion: completion
    )

    eventLookupSubs.append(lookupSub)
    sendSubscribe(subscription)
    scheduleEventLookupTimeout(subscriptionID: subscription.id)
  }

  private func scheduleEventLookupTimeout(subscriptionID: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.eventLookupSubscriptionTimeout) {
      [weak self] in
      self?.completeEventLookup(withId: subscriptionID)
    }
  }

  private func completeEventLookup(withId subscriptionID: String) {
    guard let index = eventLookupSubs.firstIndex(where: { $0.subscription.id == subscriptionID })
    else {
      return
    }

    let sub = eventLookupSubs.remove(at: index)
    unsubscribe(subscriptionID: sub.subscription.id)
    flushPendingEvents()

    let items = sub.receivedEvents
      .filter { $0.id == sub.eventID && !$0.content.isEmpty }
      .map(FeedItem.init(event:))

    sub.completion(items)
  }

  private func unsubscribeEventLookupsForAll() {
    let subs = eventLookupSubs
    eventLookupSubs.removeAll()

    for sub in subs {
      unsubscribe(subscriptionID: sub.subscription.id)
      sub.completion([])
    }
  }

  private func enqueueRepostOriginalLookup(
    repostEvent event: Event,
    origin: PersistedTextNoteSummary.Origin
  ) {
    guard let targetEventID = RRepost.targetEventID(from: event) else { return }

    var pendingEvents = pendingRepostLookupsByTargetID[targetEventID] ?? []
    guard !pendingEvents.contains(where: { $0.event.id == event.id }) else { return }

    pendingEvents.append(PendingRepostEvent(event: event, origin: origin))
    pendingRepostLookupsByTargetID[targetEventID] = pendingEvents

    if !activeRepostLookupTargetIDs.contains(targetEventID)
      && !repostLookupQueue.contains(targetEventID)
    {
      repostLookupQueue.append(targetEventID)
    }

    while repostLookupQueue.count > Self.maxQueuedRepostLookups {
      let droppedTargetID = repostLookupQueue.removeFirst()
      pendingRepostLookupsByTargetID.removeValue(forKey: droppedTargetID)
    }

    drainRepostLookupQueue()
  }

  private func drainRepostLookupQueue() {
    guard connected else { return }

    while repostLookupSubs.count < Self.maxActiveRepostLookups,
      !repostLookupQueue.isEmpty
    {
      let targetEventID = repostLookupQueue.removeFirst()
      guard pendingRepostLookupsByTargetID[targetEventID]?.isEmpty == false,
        !activeRepostLookupTargetIDs.contains(targetEventID)
      else {
        continue
      }

      startRepostLookup(targetEventID: targetEventID)
    }
  }

  private func startRepostLookup(targetEventID: String) {
    let subscription = Subscription(
      filters: [
        .init(
          ids: [targetEventID],
          eventKinds: [.textNote],
          limit: 1
        )
      ],
      id: UUID().uuidString
    )

    let lookupSub = RepostLookupSub(
      subscription: subscription,
      targetEventID: targetEventID,
      receivedEvents: []
    )

    activeRepostLookupTargetIDs.insert(targetEventID)
    repostLookupSubs.append(lookupSub)
    sendSubscribe(subscription)
    scheduleRepostLookupTimeout(subscriptionID: subscription.id)
  }

  private func scheduleRepostLookupTimeout(subscriptionID: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.repostLookupSubscriptionTimeout) {
      [weak self] in
      self?.completeRepostLookup(withId: subscriptionID)
    }
  }

  private func completeRepostLookup(withId subscriptionID: String) {
    guard let index = repostLookupSubs.firstIndex(where: { $0.subscription.id == subscriptionID })
    else {
      return
    }

    let sub = repostLookupSubs.remove(at: index)
    activeRepostLookupTargetIDs.remove(sub.targetEventID)
    unsubscribe(subscriptionID: sub.subscription.id)
    flushPendingEvents()

    let originalEvent = sub.receivedEvents.first {
      $0.id == sub.targetEventID && !$0.content.isEmpty && $0.kind == .textNote
    }
    let pendingReposts = pendingRepostLookupsByTargetID.removeValue(forKey: sub.targetEventID) ?? []

    if originalEvent != nil {
      for pendingRepost in pendingReposts
      where NostrEventIngestionGate.shared.claim(pendingRepost.event.id) {
        enqueueRepostEvent(pendingRepost.event, origin: pendingRepost.origin)
      }
      flushPendingEvents()
    }

    drainRepostLookupQueue()
  }

  private func unsubscribeRepostLookupsForAll() {
    let subs = repostLookupSubs
    repostLookupSubs.removeAll()
    repostLookupQueue.removeAll()
    pendingRepostLookupsByTargetID.removeAll()
    activeRepostLookupTargetIDs.removeAll()

    for sub in subs {
      unsubscribe(subscriptionID: sub.subscription.id)
    }
  }

  func subscribeProfileTextNotes(forPublicKey publicKey: String) {
    unsubscribeProfileTextNotes(forPublicKey: publicKey)

    let subscription = Subscription(filters: [
      .init(
        authors: [publicKey],
        eventKinds: [.textNote],
        limit: Self.profileTextNoteSubscriptionLimit
      )
    ])

    let profileSub = ProfileTextNoteSub(subscription: subscription, publicKey: publicKey)
    profileTextNoteSubs.append(profileSub)

    while profileTextNoteSubs.count > Self.maxProfileTextNoteSubscriptions {
      let expiredSub = profileTextNoteSubs.removeFirst()
      unsubscribe(subscriptionID: expiredSub.subscription.id)
    }

    sendSubscribe(subscription)
    scheduleProfileTextNoteTimeout(subscriptionID: subscription.id)
  }

  private func scheduleProfileTextNoteTimeout(subscriptionID: String) {
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.profileTextNoteSubscriptionTimeout
    ) { [weak self] in
      guard let self,
        self.profileTextNoteSubs.contains(where: { $0.subscription.id == subscriptionID })
      else {
        return
      }

      self.flushPendingEvents()
      self.unsubscribeProfileTextNotes(withId: subscriptionID)
    }
  }

  private func unsubscribeProfileTextNotes(forPublicKey publicKey: String) {
    let matchingSubs = profileTextNoteSubs.filter { $0.publicKey == publicKey }
    profileTextNoteSubs.removeAll { $0.publicKey == publicKey }

    for sub in matchingSubs {
      unsubscribe(subscriptionID: sub.subscription.id)
    }
  }

  private func unsubscribeProfileTextNotes(withId subscriptionID: String) {
    guard let index = profileTextNoteSubs.firstIndex(where: { $0.subscription.id == subscriptionID })
    else {
      return
    }

    let sub = profileTextNoteSubs.remove(at: index)
    unsubscribe(subscriptionID: sub.subscription.id)
  }

  private func unsubscribeProfileTextNotesForAll() {
    let subs = profileTextNoteSubs
    profileTextNoteSubs.removeAll()

    for sub in subs {
      unsubscribe(subscriptionID: sub.subscription.id)
    }
  }

  private func sendSubscribe(_ subscription: Subscription) {
    guard connected, let cm = try? ClientMessage.subscribe(subscription).string() else {
      return
    }

    self.webSocketTask?.send(
      .string(cm),
      completionHandler: { error in
        if let error {
          print(error)
        }
      })
  }

  private func sendTextNotePageSubscribe(_ pageSub: TextNotePageSub) {
    if let rawFilters = pageSub.rawFilters {
      sendRawSubscribe(id: pageSub.subscription.id, filters: rawFilters)
    } else {
      sendSubscribe(pageSub.subscription)
    }
  }

  private func sendThreadPageSubscribe(_ sub: ThreadPageSub) {
    let filter = RawThreadFilter(
      kind: sub.query.eventKind,
      indexedTag: sub.query.indexedTag,
      indexedValue: sub.query.indexedValue,
      until: sub.query.until,
      limit: sub.query.limit
    )
    sendRawSubscribe(id: sub.subscriptionID, filters: [filter])
  }

  private func sendProfileSearchSubscribe(_ sub: ProfileSearchSub) {
    let filter = RawProfileSearchFilter(
      kinds: [0],
      authors: sub.query.authors,
      search: sub.query.search,
      limit: sub.query.relayLimit
    )

    sendRawSubscribe(id: sub.subscriptionID, filters: [filter])
  }

  private func sendRawSubscribe<Filter: Encodable>(id: String, filters: [Filter]) {
    guard connected,
      let idJSON = try? encodedJSONString(id),
      let filtersJSON = try? filters.map({ try encodedJSONString($0) })
    else {
      return
    }

    let message = "[\"REQ\",\(idJSON),\(filtersJSON.joined(separator: ","))]"
    self.webSocketTask?.send(
      .string(message),
      completionHandler: { error in
        if let error {
          print(error)
        }
      })
  }

  private func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
    String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? ""
  }

  private func standardTextNoteFilters(
    scope: TextNoteFeedScope,
    since: Timestamp?,
    until: Timestamp?,
    limit: Int
  ) -> [EventFilter]? {
    switch scope {
    case .global:
      return [
        .init(eventKinds: Self.feedEventKinds, since: since, until: until, limit: limit)
      ]
    case .authors(let authors):
      let relayAuthors = Array(authors).sorted().prefix(Self.maxProfileSubscriptionAuthors)
      guard !relayAuthors.isEmpty else { return [] }
      return [
        .init(
          authors: Array(relayAuthors),
          eventKinds: Self.feedEventKinds,
          since: since,
          until: until,
          limit: limit
        )
      ]
    case .terms, .verse:
      return nil
    }
  }

  private func rawTextNoteFilters(
    scope: TextNoteFeedScope,
    since: Timestamp?,
    until: Timestamp?,
    limit: Int
  ) -> [RawTextNoteFilter] {
    let authors: [String]
    let hashtags: [String]

    switch scope {
    case .terms:
      authors = []
      hashtags = Array(scope.relayHashtags.prefix(16))
    case .verse(let authorSet, _):
      authors = Array(authorSet).sorted().prefix(Self.maxProfileSubscriptionAuthors).map { $0 }
      hashtags = Array(scope.relayHashtags.prefix(16))
    case .global, .authors:
      return []
    }

    let filterCount = [!authors.isEmpty, !hashtags.isEmpty].filter { $0 }.count
    guard filterCount > 0 else { return [] }

    let perFilterLimit = max(1, limit / filterCount)
    var filters: [RawTextNoteFilter] = []

    if !authors.isEmpty {
      filters.append(
        RawTextNoteFilter(
          kinds: Self.rawFeedEventKinds,
          authors: authors,
          eventReferences: nil,
          hashtags: nil,
          search: nil,
          since: since?.timestamp,
          until: until?.timestamp,
          limit: perFilterLimit
        )
      )
    }

    if !hashtags.isEmpty {
      filters.append(
        RawTextNoteFilter(
          kinds: Self.rawFeedEventKinds,
          authors: nil,
          eventReferences: nil,
          hashtags: hashtags,
          search: nil,
          since: since?.timestamp,
          until: until?.timestamp,
          limit: perFilterLimit
        )
      )
    }

    return filters
  }

  private func unsubscribe(subscriptionID: String) {
    guard connected, let cm = try? ClientMessage.unsubscribe(subscriptionID).string() else {
      return
    }

    self.webSocketTask?.send(
      .string(cm),
      completionHandler: { error in
        if let error {
          print(error)
        }
      })
  }

  func subscribeReactions() {
    if reactionSub != nil {
      unsubscribeReactions()
    }

    let since = Timestamp(date: Date().addingTimeInterval(Self.reactionHistoryWindow))
    self.reactionSub = Subscription(filters: [
      .init(eventKinds: [.custom(7)], since: since, limit: Self.reactionSubscriptionLimit)
    ])

    if let reactionSub, connected {
      if let cm = try? ClientMessage.subscribe(reactionSub).string() {
        self.webSocketTask?.send(
          .string(cm),
          completionHandler: { error in
            if let error {
              print(error)
            }
          })
      }
    }
  }

  func unsubscribeReactions() {
    if let reactionSub = reactionSub, connected {
      if let cm = try? ClientMessage.unsubscribe(reactionSub.id).string() {
        self.webSocketTask?.send(
          .string(cm),
          completionHandler: { error in
            if let error {
              print(error)
            }
          })
      }
    }
    self.reactionSub = nil
  }

  struct ContactListSub {
    let subscription: Subscription
    let subType: String
    var publicKey: String
    var publicKeys: Set<String>
    var hasReceivedEvent = false
    var latestEventTimestamp: Timestamp?
  }

  private struct FollowNotificationEvent {
    let event: Event
    let targetPublicKey: String
  }

  private struct PendingTextNoteEvent {
    let event: Event
    let origin: PersistedTextNoteSummary.Origin
  }

  private struct PendingRepostEvent {
    let event: Event
    let origin: PersistedTextNoteSummary.Origin
  }

  private struct PendingThreadActivityEvent {
    let event: Event
    let targetPublicKey: String
  }

  func subscribeContactList(forPublicKey publicKey: String) {
    if connected {

      let subs = self.contactListSubs.filter({ $0.publicKey == publicKey })

      for sub in subs {
        if let followingSub = try? ClientMessage.unsubscribe(sub.subscription.id).string() {
          self.webSocketTask?.send(
            .string(followingSub),
            completionHandler: { error in
              if let error {
                print(error)
              }
            })
        }
      }

      self.contactListSubs.removeAll(where: { $0.publicKey == publicKey })

      let followingSub = Subscription(filters: [
        .init(authors: [publicKey], eventKinds: [.custom(3)], limit: Self.contactListFollowingLimit)
      ])
      let a = ContactListSub(
        subscription: followingSub, subType: "following", publicKey: publicKey, publicKeys: [])

      let followedSub = Subscription(filters: [
        .init(
          eventKinds: [.custom(3)],
          pubKeyTags: [publicKey],
          limit: Self.contactListFollowedByLimit
        )
      ])
      let b = ContactListSub(
        subscription: followedSub, subType: "followedBy", publicKey: publicKey, publicKeys: [])

      self.contactListSubs.append(contentsOf: [a, b])

      for sub in [a, b] {
        if let cm = try? ClientMessage.subscribe(sub.subscription).string() {
          self.webSocketTask?.send(
            .string(cm),
            completionHandler: { error in
              if let error {
                print(error)
              }
            })
        }
      }
    }
  }

  func unsubscribeContactList(withId: String) {
    if let indexOf = self.contactListSubs.firstIndex(where: { $0.subscription.id == withId }) {
      let sub = self.contactListSubs[indexOf]
      if connected {
        if let cm = try? ClientMessage.unsubscribe(sub.subscription.id).string() {
          self.webSocketTask?.send(
            .string(cm),
            completionHandler: { error in
              if let error {
                print(error)
              }
            })
        }
      }
      self.contactListSubs.remove(at: indexOf)
    }
  }

  func unsubscribeContactListForAll() {
    if connected {
      for sub in self.contactListSubs {
        if let cm = try? ClientMessage.unsubscribe(sub.subscription.id).string() {
          self.webSocketTask?.send(
            .string(cm),
            completionHandler: { error in
              if let error {
                print(error)
              }
            })
        }
      }
    }
    self.contactListSubs.removeAll()
  }

  func subscribe() {
    DispatchQueue.main.async {
      self.subscribeProfiles()
      self.subscribeTextNotes()
      self.subscribeReactions()
      for sub in self.activitySubs {
        self.sendSubscribe(sub.subscription)
      }
      for sub in self.activityPageSubs {
        self.sendSubscribe(sub.subscription)
      }
      for sub in self.profileTextNoteSubs {
        self.sendSubscribe(sub.subscription)
      }
      for sub in self.textNotePageSubs {
        self.sendTextNotePageSubscribe(sub)
      }
      for sub in self.threadPageSubs {
        self.sendThreadPageSubscribe(sub)
      }
      for sub in self.threadEventLookupSubs {
        self.sendSubscribe(sub.subscription)
      }
      for sub in self.profileSearchSubs {
        self.sendProfileSearchSubscribe(sub)
      }
      for sub in self.repostLookupSubs {
        self.sendSubscribe(sub.subscription)
      }
      self.drainRepostLookupQueue()
    }
  }

  func unsubscribe() {
    DispatchQueue.main.async {
      self.unsubscribeProfiles()
      self.unsubscribeTextNotes()
      self.unsubscribeReactions()
      self.unsubscribeContactListForAll()
      self.unsubscribeActivityForAll()
      self.unsubscribeActivityPagesForAll()
      self.unsubscribeProfileTextNotesForAll()
      self.unsubscribeOlderTextNotePagesForAll()
      self.unsubscribeEventLookupsForAll()
      self.unsubscribeThreadRequestsForAll()
      self.unsubscribeProfileSearchesForAll()
      self.unsubscribeRepostLookupsForAll()
    }
  }

  func disconnect() {
    shouldReconnect = false
    isConnecting = false
    flushWorkItem?.cancel()
    flushWorkItem = nil
    profileRefreshWorkItem?.cancel()
    profileRefreshWorkItem = nil
    pendingProfileEvents.removeAll()
    pendingTextNoteEvents.removeAll()
    pendingRepostEvents.removeAll()
    pendingReactionEvents.removeAll()
    pendingFollowNotificationEvents.removeAll()
    pendingThreadActivityEvents.removeAll()
    profileFetchedTextNoteIDs.removeAll()
    activitySubs.removeAll()
    profileTextNoteSubs.removeAll()
    textNotePageSubs.removeAll()
    activityPageSubs.removeAll()
    eventLookupSubs.removeAll()
    let pendingThreadPages = threadPageSubs
    let pendingThreadLookups = threadEventLookupSubs
    let pendingProfileSearches = profileSearchSubs
    threadPageSubs.removeAll()
    threadEventLookupSubs.removeAll()
    profileSearchSubs.removeAll()
    pendingThreadPages.forEach { $0.completion([]) }
    pendingThreadLookups.forEach { $0.completion([]) }
    pendingProfileSearches.forEach { $0.completion([]) }
    repostLookupSubs.removeAll()
    repostLookupQueue.removeAll()
    pendingRepostLookupsByTargetID.removeAll()
    activeRepostLookupTargetIDs.removeAll()
    self.pingTimer?.invalidate()
    self.webSocketTask?.cancel(with: .goingAway, reason: nil)
    self.webSocketTask = nil
    connected = false
  }

  private func retryConnect() {
    guard shouldReconnect, !connected, !isConnecting else { return }

    if retryCount < maxRetries {
      retryCount += 1
      let delay = min(Double(retryCount) * 1.5, 10)
      logRelay("RECONNECT scheduled retry=\(retryCount) delay=\(String(format: "%.1f", delay))")
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, self.shouldReconnect, !self.connected, !self.isConnecting else { return }
        self.connect()
      }
    } else {
      shouldReconnect = false
      logRelay("RECONNECT abandoned retries=\(retryCount)")
    }
  }

  private func receiveMessage() {
    self.webSocketTask?.receive(completionHandler: { [weak self] result in
      switch result {
      case .success(let message):
        switch message {
        case .data(_):
          self?.receiveMessage()
        case .string(let messageString):
          if let relayMessage = try? RelayMessage(text: messageString) {
            DispatchQueue.main.async {
              self?.parse(relayMessage)
            }
          }
          self?.receiveMessage()
        @unknown default:
          print("Unknown type received from WebSocket")
          self?.receiveMessage()
        }
      case .failure(let error):
        self?.connected = false
        self?.isConnecting = false
        self?.retryConnect()
        if self?.shouldReconnect == true {
          self?.logRelay("ERROR receive=\(error)")
        }
      }
    })
  }

  private func startPing() {
    DispatchQueue.main.async {
      self.pingTimer?.invalidate()
      self.pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) {
        [weak self] timer in
        self?.webSocketTask?.sendPing(pongReceiveHandler: { error in
          if let error = error {
            print("Failed with Error \(error.localizedDescription)")
            self?.retryConnect()
          } else {
            // no-op
          }
        })
      }
    }
  }

  private func enqueueProfileEvent(_ event: Event) {
    pendingProfileEvents.append(event)
    if pendingProfileEvents.count > Self.maxBufferedProfiles {
      pendingProfileEvents.removeFirst(pendingProfileEvents.count - Self.maxBufferedProfiles)
    }

    scheduleFlush(immediate: pendingProfileEvents.count >= Self.writeBatchSize)
  }

  private func enqueueTextNoteEvent(
    _ event: Event,
    origin: PersistedTextNoteSummary.Origin
  ) {
    pendingTextNoteEvents.append(PendingTextNoteEvent(event: event, origin: origin))
    if pendingTextNoteEvents.count > Self.maxBufferedTextNotes {
      pendingTextNoteEvents.removeFirst(pendingTextNoteEvents.count - Self.maxBufferedTextNotes)
    }

    scheduleFlush(immediate: pendingTextNoteEvents.count >= Self.writeBatchSize)
  }

  private func enqueueRepostEvent(
    _ event: Event,
    origin: PersistedTextNoteSummary.Origin
  ) {
    pendingRepostEvents.append(PendingRepostEvent(event: event, origin: origin))
    if pendingRepostEvents.count > Self.maxBufferedTextNotes {
      pendingRepostEvents.removeFirst(pendingRepostEvents.count - Self.maxBufferedTextNotes)
    }

    scheduleFlush(immediate: pendingRepostEvents.count >= Self.writeBatchSize)
  }

  private func enqueueReactionEvent(_ event: Event) {
    pendingReactionEvents.append(event)
    if pendingReactionEvents.count > Self.maxBufferedReactions {
      pendingReactionEvents.removeFirst(pendingReactionEvents.count - Self.maxBufferedReactions)
    }

    scheduleFlush(immediate: pendingReactionEvents.count >= Self.writeBatchSize)
  }

  private func enqueueFollowNotificationEvent(_ event: Event, targetPublicKey: String) {
    pendingFollowNotificationEvents.append(
      FollowNotificationEvent(event: event, targetPublicKey: targetPublicKey)
    )
    if pendingFollowNotificationEvents.count > Self.maxBufferedReactions {
      pendingFollowNotificationEvents.removeFirst(
        pendingFollowNotificationEvents.count - Self.maxBufferedReactions
      )
    }

    scheduleFlush(immediate: pendingFollowNotificationEvents.count >= Self.writeBatchSize)
  }

  private func enqueueThreadActivityEvent(_ event: Event, targetPublicKey: String) {
    pendingThreadActivityEvents.append(
      PendingThreadActivityEvent(event: event, targetPublicKey: targetPublicKey)
    )
    if pendingThreadActivityEvents.count > Self.maxBufferedReactions {
      pendingThreadActivityEvents.removeFirst(
        pendingThreadActivityEvents.count - Self.maxBufferedReactions
      )
    }

    scheduleFlush(immediate: pendingThreadActivityEvents.count >= Self.writeBatchSize)
  }

  private func scheduleFlush(immediate: Bool = false) {
    flushWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      self?.flushPendingEvents()
    }
    flushWorkItem = workItem

    DispatchQueue.main.asyncAfter(
      deadline: .now() + (immediate ? 0 : Self.writeBatchDelay),
      execute: workItem
    )
  }

  private func flushPendingEvents() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.flushPendingEvents()
      }
      return
    }

    flushWorkItem?.cancel()
    flushWorkItem = nil

    let profileEvents = pendingProfileEvents
    let textNoteEvents = pendingTextNoteEvents
    let repostEvents = pendingRepostEvents
    let reactionEvents = pendingReactionEvents
    let followNotificationEvents = pendingFollowNotificationEvents
    let threadActivityEvents = pendingThreadActivityEvents
    let profileFetchedTextNoteIDs = self.profileFetchedTextNoteIDs
    pendingProfileEvents.removeAll()
    pendingTextNoteEvents.removeAll()
    pendingRepostEvents.removeAll()
    pendingReactionEvents.removeAll()
    pendingFollowNotificationEvents.removeAll()
    pendingThreadActivityEvents.removeAll()
    self.profileFetchedTextNoteIDs.removeAll()

    guard !profileEvents.isEmpty || !textNoteEvents.isEmpty || !repostEvents.isEmpty
      || !reactionEvents.isEmpty || !followNotificationEvents.isEmpty
      || !threadActivityEvents.isEmpty || !profileFetchedTextNoteIDs.isEmpty
    else {
      return
    }

    let encoder = JSONEncoder()
    let batch = RelayPersistenceBatch(
      profileEvents: profileEvents.compactMap { try? encoder.encode($0) },
      textNoteEvents: textNoteEvents.compactMap { pendingEvent in
        guard let data = try? encoder.encode(pendingEvent.event) else { return nil }
        return RelayPersistenceEvent(encodedEvent: data, origin: pendingEvent.origin)
      },
      repostEvents: repostEvents.compactMap { pendingEvent in
        guard let data = try? encoder.encode(pendingEvent.event) else { return nil }
        return RelayPersistenceEvent(encodedEvent: data, origin: pendingEvent.origin)
      },
      reactionEvents: reactionEvents.compactMap { try? encoder.encode($0) },
      followEvents: followNotificationEvents.compactMap { pendingEvent in
        guard let data = try? encoder.encode(pendingEvent.event) else { return nil }
        return RelayFollowPersistenceEvent(
          encodedEvent: data,
          targetPublicKey: pendingEvent.targetPublicKey
        )
      },
      threadActivityEvents: threadActivityEvents.compactMap { pendingEvent in
        guard let data = try? encoder.encode(pendingEvent.event) else { return nil }
        return RelayActivityPersistenceEvent(
          encodedEvent: data,
          targetPublicKey: pendingEvent.targetPublicKey
        )
      },
      profileFetchedTextNoteIDs: profileFetchedTextNoteIDs
    )

    guard !batch.isEmpty else { return }

    let previousTask = persistenceTask
    let persistenceActor = persistenceActor
    let relay = self
    persistenceTask = Task {
      await previousTask?.value
      guard !Task.isCancelled else { return }

      let result = await persistenceActor.ingest(batch)
      await relay.applyPersistenceResult(result)
    }
  }

  @MainActor
  private func applyPersistenceResult(_ result: RelayPersistenceResult) {
    if let errorDescription = result.errorDescription {
      logRelay("PERSISTENCE error=\(errorDescription)")
      return
    }
    if result.shouldRefreshProfiles {
      scheduleProfileRefresh()
      onProfilesPersisted?()
    }
    onTextNotesPersisted?(result.textNoteSummaries)
    onActivityItemsPersisted?(result.activityItems)
  }

  private func textNote(eventID: String, in context: ModelContext) -> RTextNote? {
    let targetEventID = eventID
    var descriptor = FetchDescriptor<RTextNote>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    descriptor.fetchLimit = 1

    return try? context.fetch(descriptor).first
  }

  private func profileForPublicKey(
    _ publicKey: String,
    in context: ModelContext,
    profileCache: inout [String: RUserProfile]
  ) -> RUserProfile {
    if let cachedProfile = profileCache[publicKey] {
      return cachedProfile
    }

    let targetPublicKey = publicKey
    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == targetPublicKey }
    )
    descriptor.fetchLimit = 1

    if let existingProfile = try? context.fetch(descriptor).first {
      profileCache[publicKey] = existingProfile
      return existingProfile
    }

    let profile = RUserProfile.createEmpty(withPublicKey: publicKey)
    context.insert(profile)
    profileCache[publicKey] = profile
    return profile
  }

  private func scheduleProfileRefresh() {
    profileRefreshWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      self?.subscribeProfiles()
    }
    profileRefreshWorkItem = workItem

    DispatchQueue.main.asyncAfter(deadline: .now() + Self.profileRefreshDelay, execute: workItem)
  }

  private func persistContactList(_ contactSub: ContactListSub) {
    let context = ModelContext(modelContainer)

    let targetPublicKey = contactSub.publicKey
    var descriptor = FetchDescriptor<RContactList>(
      predicate: #Predicate { $0.publicKey == targetPublicKey }
    )
    descriptor.fetchLimit = 1

    let existingLists = (try? context.fetch(descriptor)) ?? []
    let contactList = existingLists.first ?? RContactList.createEmpty(withPublicKey: targetPublicKey)
    if existingLists.isEmpty {
      context.insert(contactList)
    }

    let contactPublicKeys = contactSub.publicKeys
    var profileCache: [String: RUserProfile] = [:]
    let profiles = contactPublicKeys
      .prefix(Self.maxContactListProfiles)
      .map { profileForPublicKey($0, in: context, profileCache: &profileCache) }

    if contactSub.subType == "following" {
      contactList.following = profiles
      contactList.followingCount = contactPublicKeys.count
    } else if contactSub.subType == "followedBy" {
      contactList.followedBy = profiles
      contactList.followedByCount = contactPublicKeys.count
    }

    do {
      try context.save()
    } catch {
      print("Error saving contact list: \(error)")
    }
  }

  private func handleRepostEvent(subscriptionID id: String, event: Event) {
    let eventDate = Date(timeIntervalSince1970: Double(event.createdAt.timestamp))
    guard TextNoteFeedPolicy.accepts(createdAt: eventDate) else { return }

    let pageIndex = textNotePageSubs.firstIndex(where: { $0.subscription.id == id })
    let isFeedLiveEvent = textNoteSub?.id == id
    let pageScope = pageIndex.map { textNotePageSubs[$0].scope }
    let feedItem = FeedItem(networkEvent: event)
    let scopeAllowsLookup =
      pageScope?.matches(publicKey: event.publicKey, content: event.content) == true
      || (isFeedLiveEvent && textNoteFeedScope.matches(publicKey: event.publicKey, content: event.content))

    if let pageIndex,
      let feedItem,
      textNotePageSubs[pageIndex].scope.matches(feedItem)
    {
      textNotePageSubs[pageIndex].receivedEvents.append(event)
    }

    let shouldPersistEvent =
      pageScope.map { scope in
        feedItem.map { scope.matches($0) } ?? scope.isGlobal
      } == true
      || (isFeedLiveEvent && (feedItem.map { textNoteFeedScope.matches($0) } ?? textNoteFeedScope.isGlobal))
      || scopeAllowsLookup

    guard shouldPersistEvent else { return }

    if isFeedLiveEvent {
      advanceHomeLiveCursor(to: Int64(event.createdAt.timestamp))
    }

    if isFeedLiveEvent && bootstrapedTextNotes {
      let admission = homeLiveAdmission(
        event.id,
        Int64(event.createdAt.timestamp),
        feedItem
      )
      switch admission.decision {
      case .collectBacklog, .collectRefreshHandoff:
        break
      case .dropDuplicate, .dropSaturated, .dropInactive:
        return
      }
    }

    let origin: PersistedTextNoteSummary.Origin =
      isFeedLiveEvent && bootstrapedTextNotes ? .liveRelay : .historicalRelay

    if feedItem != nil
      || RRepost.targetEventID(from: event).map(hasCachedTextNote(eventID:)) == true
    {
      guard NostrEventIngestionGate.shared.claim(event.id) else { return }
      enqueueRepostEvent(event, origin: origin)
    } else {
      enqueueRepostOriginalLookup(repostEvent: event, origin: origin)
    }
  }

  private func hasCachedTextNote(eventID: String) -> Bool {
    let context = ModelContext(modelContainer)
    return textNote(eventID: eventID, in: context) != nil
  }

  private func parse(_ message: RelayMessage) {
    switch message {
    case .event(let id, let event):
      if let profileSearchIndex = profileSearchSubs.firstIndex(where: {
        $0.subscriptionID == id && event.kind.integerValue == 0
      }) {
        profileSearchSubs[profileSearchIndex].receivedEvents.append(event)
        return
      }

      if let pageIndex = threadPageSubs.firstIndex(where: {
        $0.subscriptionID == id && $0.query.eventKind == event.kind.integerValue
      }) {
        threadPageSubs[pageIndex].receivedEvents.append(event)
      }

      if let lookupIndex = threadEventLookupSubs.firstIndex(where: {
        $0.subscription.id == id
          && $0.eventID == event.id
          && ($0.eventKind == nil || $0.eventKind == event.kind.integerValue)
      }) {
        threadEventLookupSubs[lookupIndex].receivedEvents.append(event)
      }

      switch event.kind {
      case .setMetadata:
        guard NostrEventIngestionGate.shared.claim(event.id) else { return }
        enqueueProfileEvent(event)

      case .textNote:
        if let targetPublicKey = activityTargetPublicKey(for: id, event: event) {
          enqueueThreadActivityEvent(event, targetPublicKey: targetPublicKey)
        }
        if let targetPublicKey = activityPageTargetPublicKey(for: id, event: event),
          let pageIndex = activityPageSubs.firstIndex(where: { $0.subscription.id == id }),
          activityPageSubs[pageIndex].scope.includesThreadActivity,
          let item = ActivityItem(event: event, targetPublicKey: targetPublicKey),
          activityPageSubs[pageIndex].scope.includes(item.kind)
        {
          activityPageSubs[pageIndex].receivedEvents.append(event)
          enqueueThreadActivityEvent(event, targetPublicKey: targetPublicKey)
        }

        let eventDate = Date(timeIntervalSince1970: Double(event.createdAt.timestamp))
        guard TextNoteFeedPolicy.accepts(createdAt: eventDate) else { return }

        let lookupIndex = eventLookupSubs.firstIndex {
          $0.subscription.id == id && $0.eventID == event.id
        }
        let repostLookupIndex = repostLookupSubs.firstIndex {
          $0.subscription.id == id && $0.targetEventID == event.id
        }
        let pageIndex = textNotePageSubs.firstIndex(where: { $0.subscription.id == id })
        let isProfileFetchEvent = profileTextNoteSubs.contains { $0.subscription.id == id }
        let isFeedLiveEvent = textNoteSub?.id == id
        let isEventLookupEvent = lookupIndex != nil
        let isRepostLookupEvent = repostLookupIndex != nil
        let pageScope = pageIndex.map { textNotePageSubs[$0].scope }

        if let lookupIndex,
          !event.content.isEmpty
        {
          eventLookupSubs[lookupIndex].receivedEvents.append(event)
        }

        if let repostLookupIndex,
          !event.content.isEmpty
        {
          repostLookupSubs[repostLookupIndex].receivedEvents.append(event)
        }

        if let pageIndex,
          !event.content.isEmpty,
          textNotePageSubs[pageIndex].scope.matches(event)
        {
          textNotePageSubs[pageIndex].receivedEvents.append(event)
        }

        if isProfileFetchEvent {
          profileFetchedTextNoteIDs.insert(event.id)
        }

        let shouldPersistEvent =
          isProfileFetchEvent
          || isEventLookupEvent
          || isRepostLookupEvent
          || pageScope?.matches(event) == true
          || (isFeedLiveEvent && textNoteFeedScope.matches(event))

        guard shouldPersistEvent else { return }
        guard !event.content.isEmpty else { return }

        if isFeedLiveEvent {
          advanceHomeLiveCursor(to: Int64(event.createdAt.timestamp))
        }

        if isFeedLiveEvent && bootstrapedTextNotes {
          let admission = homeLiveAdmission(
            event.id,
            Int64(event.createdAt.timestamp),
            FeedItem(textNoteEvent: event)
          )
          switch admission.decision {
          case .collectBacklog, .collectRefreshHandoff:
            break
          case .dropDuplicate, .dropSaturated, .dropInactive:
            return
          }
        }

        guard NostrEventIngestionGate.shared.claim(event.id) else { return }

        let origin: PersistedTextNoteSummary.Origin =
          isFeedLiveEvent && bootstrapedTextNotes ? .liveRelay : .historicalRelay
        enqueueTextNoteEvent(event, origin: origin)
      case .recommentServer:
        ()
      case .custom(let kind):
        if kind == 6 {
          handleRepostEvent(subscriptionID: id, event: event)
        } else if kind == 3 {  // Contact list
          if let contactSub = self.contactListSubs.first(where: { $0.subscription.id == id }) {
            if let indexOf = self.contactListSubs.firstIndex(where: { $0.subscription.id == id }) {
              self.contactListSubs[indexOf].hasReceivedEvent = true

              if contactSub.subType == "following" {
                if let latestEventTimestamp = self.contactListSubs[indexOf].latestEventTimestamp,
                  event.createdAt.timestamp < latestEventTimestamp.timestamp
                {
                  return
                }

                self.contactListSubs[indexOf].latestEventTimestamp = event.createdAt
                self.contactListSubs[indexOf].publicKeys = Set(
                  event.tags.compactMap({ $0.otherInformation.first }))
	              } else if contactSub.subType == "followedBy" {
	                self.contactListSubs[indexOf].publicKeys.update(with: event.publicKey)
	                self.enqueueFollowNotificationEvent(event, targetPublicKey: contactSub.publicKey)
	              }
	            }
	          }
	          if let targetPublicKey = activityTargetPublicKey(for: id, event: event) {
	            enqueueFollowNotificationEvent(event, targetPublicKey: targetPublicKey)
	          }
	          if let targetPublicKey = activityPageTargetPublicKey(for: id, event: event),
	            let pageIndex = activityPageSubs.firstIndex(where: { $0.subscription.id == id }),
	            activityPageSubs[pageIndex].scope.includesFollows
	          {
	            activityPageSubs[pageIndex].receivedEvents.append(event)
	            enqueueFollowNotificationEvent(event, targetPublicKey: targetPublicKey)
	          }
	        } else if kind == 7 {
	          if activityPageTargetPublicKey(for: id, event: event) != nil,
	            let pageIndex = activityPageSubs.firstIndex(where: { $0.subscription.id == id }),
	            activityPageSubs[pageIndex].scope.includesReactions
	          {
	            activityPageSubs[pageIndex].receivedEvents.append(event)
	          }

	          guard NostrEventIngestionGate.shared.claim(event.id) else { return }
	          enqueueReactionEvent(event)
        } else if kind == 1111 {
          if let targetPublicKey = activityTargetPublicKey(for: id, event: event) {
            enqueueThreadActivityEvent(event, targetPublicKey: targetPublicKey)
          }
          if let targetPublicKey = activityPageTargetPublicKey(for: id, event: event),
            let pageIndex = activityPageSubs.firstIndex(where: { $0.subscription.id == id }),
            activityPageSubs[pageIndex].scope.includesThreadActivity,
            let item = ActivityItem(event: event, targetPublicKey: targetPublicKey),
            activityPageSubs[pageIndex].scope.includes(item.kind)
          {
            activityPageSubs[pageIndex].receivedEvents.append(event)
            enqueueThreadActivityEvent(event, targetPublicKey: targetPublicKey)
          }
        }
      }
    case .notice(let notice):
      print(notice)
    case .other(let others):
      ()
      if others.count == 2 {
        let op = others[0]
        let subscriptionId = others[1]
        if op == "EOSE" {

          // MARK: - Handle contact list EOSE
          if let contactSub = self.contactListSubs.first(where: {
            $0.subscription.id == subscriptionId
          }) {
            if contactSub.hasReceivedEvent {
              self.persistContactList(contactSub)
              self.scheduleProfileRefresh()
            }

            self.unsubscribeContactList(withId: subscriptionId)
          }

          // MARK: - Handle setmetadata EOSE
          if subscriptionId == profileSub?.id && !self.bootstrapedProfiles {

            logRelay("EOSE purpose=profiles sub=\(subscriptionId)")

            self.bootstrapedProfiles = true
            self.flushPendingEvents()
          }

          // MARK: - Handle textnotes EOSE
          if subscriptionId == textNoteSub?.id && !self.bootstrapedTextNotes {

            logRelay("EOSE purpose=text-notes sub=\(subscriptionId)")

            self.bootstrapedTextNotes = true
            self.flushPendingEvents()
            self.scheduleProfileRefresh()
          }

          // MARK: - Handle older text note page EOSE
          if self.textNotePageSubs.contains(where: { $0.subscription.id == subscriptionId }) {
            self.completeOlderTextNotePage(withId: subscriptionId, reason: "eose")
          }

          // MARK: - Handle event lookup EOSE
          if self.eventLookupSubs.contains(where: { $0.subscription.id == subscriptionId }) {
            self.completeEventLookup(withId: subscriptionId)
          }

          // MARK: - Handle thread pages and focused-event lookups
          if self.threadPageSubs.contains(where: { $0.subscriptionID == subscriptionId }) {
            self.completeThreadPage(subscriptionID: subscriptionId, reason: "eose")
          }
          if self.threadEventLookupSubs.contains(where: {
            $0.subscription.id == subscriptionId
          }) {
            self.completeThreadEventLookup(subscriptionID: subscriptionId, reason: "eose")
          }

          if self.profileSearchSubs.contains(where: {
            $0.subscriptionID == subscriptionId
          }) {
            self.completeProfileSearch(subscriptionID: subscriptionId, reason: "eose")
          }

          // MARK: - Handle repost original lookup EOSE
          if self.repostLookupSubs.contains(where: { $0.subscription.id == subscriptionId }) {
            self.completeRepostLookup(withId: subscriptionId)
          }

          // MARK: - Handle profile text notes EOSE
	          if self.profileTextNoteSubs.contains(where: { $0.subscription.id == subscriptionId }) {
	            logRelay("EOSE purpose=profile-text-notes sub=\(subscriptionId)")

	            self.flushPendingEvents()
	            self.scheduleProfileRefresh()
	            self.unsubscribeProfileTextNotes(withId: subscriptionId)
	          }

	          // MARK: - Handle activity EOSE
	          if self.activitySubs.contains(where: { $0.subscription.id == subscriptionId }) {
	            self.flushPendingEvents()
	            self.scheduleProfileRefresh()
	          }

	          // MARK: - Handle activity page EOSE
	          if self.activityPageSubs.contains(where: { $0.subscription.id == subscriptionId }) {
	            self.completeActivityPage(withId: subscriptionId)
	          }

	          // MARK: - Handle reactions EOSE
          if subscriptionId == reactionSub?.id && !self.bootstrapedReactions {

            logRelay("EOSE purpose=reactions sub=\(subscriptionId)")

            self.bootstrapedReactions = true
            self.flushPendingEvents()
          }

        }
      }
    }
  }
}

extension NostrRelay: URLSessionWebSocketDelegate {
  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    connected = true
    isConnecting = false
    shouldReconnect = true
    authors.removeAll()  // TODO:
    startPing()
    subscribe()
    retryCount = 0
    logRelay("OPEN")
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    connected = false
    isConnecting = false
    self.webSocketTask = nil
    logRelay("CLOSE code=\(closeCode)")
    if shouldReconnect && closeCode != .normalClosure && closeCode != .goingAway {
      retryConnect()
    }
  }
}
