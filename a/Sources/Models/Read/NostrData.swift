/*
 The `NostrData` class is the main data manager for the app, using **SwiftData** for persistence.

 1. **Singleton**: It uses a shared instance (`NostrData.shared`) to manage all data globally.

 2. **SwiftData ModelContainer**: Initializes a `ModelContainer` with all SwiftData models like `RTextNote`, `RUserProfile`, etc., for local storage and queries.

 3. **Stored Relays**: Uses `StoredRelays` (backed by SwiftData) to manage relay information.

 4. **Last Seen Date**: Keeps track of the user's last activity date using `UserDefaults`. The value updates through `updateLastSeenDate()`.

 5. **Relays Management**:
    - `bootstrapRelays()` creates and connects relays.
    - `disconnect()` unsubscribes and disconnects all relays.
    - `reconnect()` reconnects only disconnected relays.
    - `fetchContactList()` subscribes to a contact list for a given public key.

 6. **Previews**: `initPreview()` returns the shared instance for SwiftUI previews.

 In short, `NostrData` centralizes relay connections, persistence, and session state using SwiftData.
 */

import Foundation
import NostrKit
import SwiftData
import SwiftUI

class NostrData: ObservableObject {

  static let lastSeenDefaultsKey = "lastSeenDefaultsKey"
  static let networkEnabledDefaultsKey = "networkEnabledDefaultsKey"
  static let localStoreSchemaVersionDefaultsKey = "localStoreSchemaVersionDefaultsKey"
  static let localStoreSchemaVersion = 5
  static let defaultRelayURLs = [
    "wss://relay.damus.io",
    "wss://nos.lol",
  ]

  @Published private(set) var isNetworkEnabled =
    UserDefaults.standard.object(forKey: NostrData.networkEnabledDefaultsKey) as? Bool ?? true

  @Published var lastSeenDate = Date(
    timeIntervalSince1970: Double(
      UserDefaults.standard.integer(forKey: NostrData.lastSeenDefaultsKey)))

  @ObservedObject var storedRelays: StoredRelays

  var nostrRelays: [NostrRelay] = []
  private var contactListFetchDates: [String: Date] = [:]
  private var profileTextNoteFetchDates: [String: Date] = [:]
  private var activityFetchDates: [String: Date] = [:]
  private var activeNIP05VerificationKeys = Set<String>()
  private let nip05VerificationGate = NIP05VerificationGate(limit: 3)
  private var textNoteObservers: [UUID: ([PersistedTextNoteSummary]) -> Void] = [:]
  private var activityObservers: [UUID: ([ActivityItem]) -> Void] = [:]
  private var textNoteFeedScope: TextNoteFeedScope = .global
  private let contactListFetchCooldown: TimeInterval = 10
  private let profileTextNoteFetchCooldown: TimeInterval = 15
  private let activityFetchCooldown: TimeInterval = 15
  let modelContainer: ModelContainer
  static let shared = NostrData()

  private init() {
    if UserDefaults.standard.integer(forKey: NostrData.lastSeenDefaultsKey) == 0 {
      UserDefaults.standard.setValue(
        Timestamp(date: Date.now).timestamp, forKey: NostrData.lastSeenDefaultsKey)
      self.lastSeenDate = Date(
        timeIntervalSince1970: Double(
          UserDefaults.standard.integer(forKey: NostrData.lastSeenDefaultsKey)))
    }

    Self.resetLocalStoreIfNeeded()

    let container = Self.makeModelContainer()
    self.modelContainer = container
    self.storedRelays = StoredRelays(modelContainer: container)
  }

  private static func resetLocalStoreIfNeeded() {
    let currentVersion = UserDefaults.standard.integer(forKey: localStoreSchemaVersionDefaultsKey)
    guard currentVersion < localStoreSchemaVersion else { return }

    resetLocalSwiftDataStore()
    UserDefaults.standard.set(localStoreSchemaVersion, forKey: localStoreSchemaVersionDefaultsKey)
  }

  private static func makeModelContainer() -> ModelContainer {
    do {
      return try configuredModelContainer()
    } catch {
      print("Failed to create ModelContainer. Resetting local SwiftData store: \(error)")
      resetLocalSwiftDataStore()

      do {
        return try configuredModelContainer()
      } catch {
        fatalError("Failed to create ModelContainer after reset: \(error)")
      }
    }
  }

  private static func configuredModelContainer() throws -> ModelContainer {
    try ModelContainer(
      for: RTextNote.self,
      RUserProfile.self,
      RContactList.self,
      RReaction.self,
      RRepost.self,
      RFollowNotification.self,
      RDirectMessage.self,
      RThreadEvent.self,
      VerseWatcher.self,
      RelayItem.self,
      AppConsole.self,
      SwiftDataEvent.self,
      PendingPost.self
    )
  }

  private static func resetLocalSwiftDataStore() {
    let fileManager = FileManager.default
    let storeExtensions = Set(["store", "sqlite"])
    let storeSuffixes = ["-shm", "-wal"]

    let roots = [
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
      fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
    ].compactMap { $0 }

    for root in roots {
      guard let files = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ) else {
        continue
      }

      for file in files where shouldDeleteSwiftDataStoreFile(file) {
        try? fileManager.removeItem(at: file)
      }
    }

    func shouldDeleteSwiftDataStoreFile(_ url: URL) -> Bool {
      let extensionMatches = storeExtensions.contains(url.pathExtension.lowercased())
      let suffixMatches = storeSuffixes.contains { url.lastPathComponent.hasSuffix($0) }
      return extensionMatches || suffixMatches
    }
  }

  func initPreview() -> NostrData {
    //        userProfiles = [UserProfile.preview]
    //        textNotes = [TextNote.preview]
    return .shared
  }

  func setNetworkEnabled(_ isEnabled: Bool) {
    guard isNetworkEnabled != isEnabled else { return }

    isNetworkEnabled = isEnabled
    UserDefaults.standard.set(isEnabled, forKey: Self.networkEnabledDefaultsKey)

    if isEnabled {
      bootstrapConfiguredRelays()
    } else {
      disconnect()
    }
  }

  func toggleNetworkEnabled() {
    setNetworkEnabled(!isNetworkEnabled)
  }

  func bootstrapRelays(relay: String) {
    guard isNetworkEnabled else { return }

    guard let normalizedRelay = storedRelays.normalizedRelayAddress(relay) else {
      return
    }

    if let existingRelay = nostrRelays.first(where: { $0.urlString == normalizedRelay }) {
      if !existingRelay.connected {
        existingRelay.connect()
      }
      return
    }

    let nostrRelay = NostrRelay(urlString: normalizedRelay, modelContainer: modelContainer)
    nostrRelay.setTextNoteFeedScope(textNoteFeedScope)
    nostrRelay.onTextNotesPersisted = { [weak self] summaries in
      self?.notifyPersistedTextNotes(summaries)
    }
    nostrRelay.onActivityItemsPersisted = { [weak self] items in
      self?.notifyPersistedActivityItems(items)
    }
    self.nostrRelays.append(nostrRelay)
    nostrRelay.connect()
  }

  func bootstrapDefaultRelays() {
    for relay in Self.defaultRelayURLs {
      bootstrapRelays(relay: relay)
    }
  }

  func bootstrapConfiguredRelays() {
    guard isNetworkEnabled else { return }

    storedRelays.ensureDefaultRelays()
    storedRelays.loadData()

    for relay in storedRelays.activeRelayAddresses {
      bootstrapRelays(relay: relay)
    }

    let activeRelayURLs = Set(storedRelays.activeRelayAddresses)
    for relay in nostrRelays where !activeRelayURLs.contains(relay.urlString) {
      relay.unsubscribe()
      relay.disconnect()
    }
  }

  func disconnect() {
    for relay in nostrRelays {
      relay.unsubscribe()
      relay.disconnect()
    }
  }

  func reconnect() {
    guard isNetworkEnabled else { return }

    storedRelays.loadData()

    guard !storedRelays.relayItems.isEmpty else {
      disconnect()
      return
    }

    let activeRelayURLs = Set(storedRelays.activeRelayAddresses)

    for relayAddress in activeRelayURLs {
      bootstrapRelays(relay: relayAddress)
    }

    for relay in nostrRelays {
      if activeRelayURLs.contains(relay.urlString) {
        if !relay.connected {
          relay.connect()
        }
      } else {
        relay.unsubscribe()
        relay.disconnect()
      }
    }
  }

  func disconnectRelay(urlString: String) {
    guard let relay = nostrRelays.first(where: { $0.urlString == urlString }) else {
      return
    }

    relay.unsubscribe()
    relay.disconnect()
  }

  func fetchContactList(forPublicKey publicKey: String, force: Bool = false) {
    guard isNetworkEnabled else { return }

    let now = Date()
    if !force,
      let lastFetchDate = contactListFetchDates[publicKey],
      now.timeIntervalSince(lastFetchDate) < contactListFetchCooldown
    {
      return
    }

    contactListFetchDates[publicKey] = now

    for relay in nostrRelays {
      relay.subscribeContactList(forPublicKey: publicKey)
    }
  }

  func fetchTextNotes(forPublicKey publicKey: String, force: Bool = false) {
    guard isNetworkEnabled else { return }

    let now = Date()
    if !force,
      let lastFetchDate = profileTextNoteFetchDates[publicKey],
      now.timeIntervalSince(lastFetchDate) < profileTextNoteFetchCooldown
    {
      return
    }

    profileTextNoteFetchDates[publicKey] = now
    bootstrapConfiguredRelays()

    for relay in nostrRelays {
      relay.subscribeProfileTextNotes(forPublicKey: publicKey)
    }
  }

  func fetchTextNoteEvent(reference: NostrEventReference) async -> FeedItem? {
    if let cachedItem = cachedTextNoteEvent(eventID: reference.id) {
      return cachedItem
    }

    guard isNetworkEnabled else { return nil }

    bootstrapConfiguredRelays()

    let relays = nostrRelays.filter { $0.connected || $0.isConnecting }
    guard !relays.isEmpty else { return nil }

    return await withCheckedContinuation { continuation in
      let lock = NSLock()
      var completedCount = 0
      var itemByID: [String: FeedItem] = [:]

      func relayDidComplete(with items: [FeedItem]) {
        lock.lock()
        for item in items where item.id == reference.id {
          itemByID[item.id] = item
        }
        completedCount += 1
        let shouldComplete = completedCount == relays.count
        let item = itemByID[reference.id]
        lock.unlock()

        guard shouldComplete else { return }

        DispatchQueue.main.async {
          continuation.resume(returning: item)
        }
      }

      for relay in relays {
        relay.subscribeTextNoteEvent(eventID: reference.id) { items in
          relayDidComplete(with: items)
        }
      }
    }
  }

  func cachedTextNoteEvent(eventID: String) -> FeedItem? {
    let context = ModelContext(modelContainer)
    let targetEventID = eventID
    var descriptor = FetchDescriptor<RTextNote>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    descriptor.fetchLimit = 1

    guard let textNote = try? context.fetch(descriptor).first else {
      return nil
    }

    return FeedItem(textNote: textNote)
  }

  @MainActor
  @discardableResult
  func persistPublishedRepost(
    _ repostEvent: Event,
    originalEventID: String,
    originalPublicKey: String,
    originalContent: String,
    originalCreatedAt: Date,
    originalIsSensitiveContent: Bool,
    originalSensitiveContentReason: String
  ) -> Bool {
    let context = ModelContext(modelContainer)
    let targetEventID = originalEventID
    var noteDescriptor = FetchDescriptor<RTextNote>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    noteDescriptor.fetchLimit = 1

    do {
      let textNote: RTextNote
      if let existingNote = try context.fetch(noteDescriptor).first {
        textNote = existingNote
      } else {
        textNote = RTextNote(
          eventId: originalEventID,
          publicKey: originalPublicKey,
          content: originalContent,
          createdAt: originalCreatedAt,
          isSensitiveContent: originalIsSensitiveContent,
          sensitiveContentReason: originalSensitiveContentReason
        )
        context.insert(textNote)
      }

      guard !repostExists(eventID: repostEvent.id, in: context),
        let repost = RRepost.create(with: repostEvent, targetTextNote: textNote)
      else {
        return true
      }

      repost.userProfile = profile(for: repost.publicKey, in: context)
      context.insert(repost)
      try context.save()

      notifyPersistedTextNotes([
        PersistedTextNoteSummary(
          id: repost.eventId,
          eventId: textNote.eventId,
          publicKey: textNote.publicKey,
          content: textNote.content,
          createdAt: repost.createdAt,
          eventCreatedAt: textNote.createdAt,
          hashtags: textNote.taggedHashtags,
          isSensitiveContent: textNote.isSensitiveContent,
          sensitiveContentReason: textNote.sensitiveContentReason,
          origin: .localPublish,
          repost: FeedRepost(repost: repost)
        )
      ])
      return true
    } catch {
      print("Error saving published repost: \(error)")
      return false
    }
  }

  @MainActor
  @discardableResult
  func persistPublishedGenericRepost(_ repostEvent: Event) -> Bool {
    let context = ModelContext(modelContainer)

    do {
      guard !repostExists(eventID: repostEvent.id, in: context),
        let repost = RRepost.create(with: repostEvent)
      else {
        return true
      }

      repost.userProfile = profile(for: repost.publicKey, in: context)
      context.insert(repost)
      try context.save()
      return true
    } catch {
      print("Error saving published generic repost: \(error)")
      return false
    }
  }

  private func repostExists(eventID: String, in context: ModelContext) -> Bool {
    let targetEventID = eventID
    var descriptor = FetchDescriptor<RRepost>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    descriptor.fetchLimit = 1

    do {
      return try !context.fetch(descriptor).isEmpty
    } catch {
      return false
    }
  }

  private func profile(for publicKey: String, in context: ModelContext) -> RUserProfile? {
    let targetPublicKey = publicKey
    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == targetPublicKey }
    )
    descriptor.fetchLimit = 1

    return try? context.fetch(descriptor).first
  }

  @MainActor
  func verifyNIP05IfNeeded(
    forPublicKey publicKey: String,
    identifier rawIdentifier: String,
    force: Bool = false
  ) async {
    let identifier = rawIdentifier
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard NIP05.parse(identifier) != nil else { return }

    let verificationKey = "\(publicKey)|\(identifier)"
    guard !activeNIP05VerificationKeys.contains(verificationKey) else { return }

    let context = ModelContext(modelContainer)
    guard let storedProfile = profile(for: publicKey, in: context) else { return }
    guard storedProfile.nip05 == identifier else { return }

    if !force,
      !NIP05VerificationPolicy.shouldRefresh(
        status: storedProfile.nip05VerificationStatus,
        lastCheckedAt: storedProfile.nip05LastCheckedAt
      )
    {
      return
    }

    await nip05VerificationGate.acquire()
    guard !Task.isCancelled else {
      await nip05VerificationGate.release()
      return
    }

    let verificationContext = ModelContext(modelContainer)
    guard let profileToVerify = profile(for: publicKey, in: verificationContext),
      profileToVerify.nip05 == identifier,
      !activeNIP05VerificationKeys.contains(verificationKey)
    else {
      await nip05VerificationGate.release()
      return
    }

    if !force,
      !NIP05VerificationPolicy.shouldRefresh(
        status: profileToVerify.nip05VerificationStatus,
        lastCheckedAt: profileToVerify.nip05LastCheckedAt
      )
    {
      await nip05VerificationGate.release()
      return
    }

    activeNIP05VerificationKeys.insert(verificationKey)
    let previousStatus = profileToVerify.nip05VerificationStatus
    if previousStatus != .verified {
      profileToVerify.nip05VerificationStatus = .checking
      try? verificationContext.save()
    }

    let result = await NIP05Verifier.verify(publicKey: publicKey, nip05: identifier)
    if let latestProfile = profile(for: publicKey, in: verificationContext),
      latestProfile.nip05 == identifier
    {
      if Task.isCancelled {
        if latestProfile.nip05VerificationStatus == .checking {
          latestProfile.nip05VerificationStatus = previousStatus
          try? verificationContext.save()
        }
      } else if let result {
        latestProfile.nip05VerificationStatus = result.status
        latestProfile.nip05LastCheckedAt = result.checkedAt
        latestProfile.nip05VerificationURLString = result.verificationURL.absoluteString
        try? verificationContext.save()
      } else {
        latestProfile.nip05VerificationStatus = .invalid
        latestProfile.nip05LastCheckedAt = Date()
        latestProfile.nip05VerificationURLString = NIP05.parse(identifier)?.url?.absoluteString ?? ""
        try? verificationContext.save()
      }
    }

    activeNIP05VerificationKeys.remove(verificationKey)
    await nip05VerificationGate.release()
  }

  func fetchActivity(forPublicKey publicKey: String, force: Bool = false) {
    guard isNetworkEnabled else { return }

    let now = Date()
    if !force,
      let lastFetchDate = activityFetchDates[publicKey],
      now.timeIntervalSince(lastFetchDate) < activityFetchCooldown
    {
      return
    }

    activityFetchDates[publicKey] = now
    bootstrapConfiguredRelays()

    for relay in nostrRelays {
      relay.subscribeActivity(forPublicKey: publicKey)
    }
  }

  func fetchOlderTextNotes(
    until date: Date,
    limit: Int,
    scope: TextNoteFeedScope = .global,
    completion: @escaping ([PersistedTextNoteSummary]) -> Void
  ) {
    if case .verse(let authors, let hashtags) = scope {
      let hashtagTerms = hashtags.map { "#\($0)" }
      var branchScopes: [TextNoteFeedScope] = []
      if !authors.isEmpty {
        branchScopes.append(.authors(authors))
      }
      if !hashtagTerms.isEmpty {
        branchScopes.append(.terms(hashtagTerms))
      }

      guard !branchScopes.isEmpty else {
        completion([])
        return
      }

      fetchOlderTextNoteBranches(
        branchScopes,
        until: date,
        limit: max(1, limit / branchScopes.count),
        completion: completion
      )
      return
    }

    guard isNetworkEnabled else {
      completion([])
      return
    }

    bootstrapConfiguredRelays()

    let relays = nostrRelays.filter { $0.connected || $0.isConnecting }
    guard !relays.isEmpty else {
      completion([])
      return
    }

    let lock = NSLock()
    var completedCount = 0
    var receivedSummariesByID: [String: PersistedTextNoteSummary] = [:]

    func relayDidComplete(with summaries: [PersistedTextNoteSummary]) {
      lock.lock()
      for summary in summaries {
        receivedSummariesByID[summary.eventId] = summary
      }
      completedCount += 1
      let shouldComplete = completedCount == relays.count
      let summaries = receivedSummariesByID.values.sorted {
        if $0.createdAt == $1.createdAt {
          return $0.eventId < $1.eventId
        }

        return $0.createdAt > $1.createdAt
      }
      lock.unlock()

      if shouldComplete {
        DispatchQueue.main.async {
          completion(summaries)
        }
      }
    }

    for relay in relays {
      relay.subscribeOlderTextNotes(until: date, limit: limit, scope: scope) { summaries in
        relayDidComplete(with: summaries)
      }
    }
  }

  func fetchOlderFeedPage(
    scope: FeedScope,
    cursor: FeedCursor?,
    limit: Int
  ) async -> FeedPage<FeedItem> {
    guard isNetworkEnabled else {
      return FeedPage(items: [], cursor: cursor, exhausted: true)
    }

    bootstrapConfiguredRelays()

    let relays = nostrRelays.filter { $0.connected || $0.isConnecting }
    guard !relays.isEmpty else {
      return FeedPage(items: [], cursor: cursor, exhausted: true)
    }

    let requestDate = cursor?.date ?? Date()
    let textNoteScope = scope.textNoteFeedScope

    return await withCheckedContinuation { continuation in
      let lock = NSLock()
      var completedCount = 0
      var itemsByID: [String: FeedItem] = [:]

      func relayDidComplete(with items: [FeedItem]) {
        lock.lock()
        for item in items {
          itemsByID[item.id] = item
        }
        completedCount += 1
        let shouldComplete = completedCount == relays.count
        let mergedItems = itemsByID.values.sorted {
          if $0.createdAtTimestamp == $1.createdAtTimestamp {
            return $0.id < $1.id
          }

          return $0.createdAtTimestamp > $1.createdAtTimestamp
        }
        lock.unlock()

        guard shouldComplete else { return }

        let pageItems = Array(mergedItems.prefix(limit))
        let nextCursor = pageItems.last.map {
          FeedCursor(until: max(0, $0.createdAtTimestamp - 1))
        }
        let page = FeedPage(
          items: pageItems,
          cursor: nextCursor,
          exhausted: mergedItems.isEmpty
        )

        DispatchQueue.main.async {
          continuation.resume(returning: page)
        }
      }

      for relay in relays {
        relay.subscribeOlderFeedItems(
          until: requestDate,
          limit: limit,
          scope: textNoteScope
        ) { items in
          relayDidComplete(with: items)
        }
      }
    }
  }

  func fetchOlderActivityPage(
    scope: ActivityScope,
    cursor: ActivityCursor?,
    limit: Int
  ) async -> ActivityPage<ActivityItem> {
    guard isNetworkEnabled else {
      return ActivityPage(items: [], cursor: cursor, exhausted: true)
    }

    bootstrapConfiguredRelays()

    let relays = nostrRelays.filter { $0.connected || $0.isConnecting }
    guard !relays.isEmpty else {
      return ActivityPage(items: [], cursor: cursor, exhausted: true)
    }

    let requestDate = cursor?.date ?? Date()

    return await withCheckedContinuation { continuation in
      let lock = NSLock()
      var completedCount = 0
      var itemsByID: [String: ActivityItem] = [:]

      func relayDidComplete(with items: [ActivityItem]) {
        lock.lock()
        for item in items where scope.matches(item) {
          itemsByID[item.id] = item
        }
        completedCount += 1
        let shouldComplete = completedCount == relays.count
        let mergedItems = itemsByID.values.sorted {
          if $0.createdAtTimestamp == $1.createdAtTimestamp {
            return $0.id < $1.id
          }

          return $0.createdAtTimestamp > $1.createdAtTimestamp
        }
        lock.unlock()

        guard shouldComplete else { return }

        let pageItems = Array(mergedItems.prefix(limit))
        let nextCursor = pageItems.last.map {
          ActivityCursor(until: max(0, $0.createdAtTimestamp - 1))
        }
        let page = ActivityPage(
          items: pageItems,
          cursor: nextCursor,
          exhausted: mergedItems.isEmpty
        )

        DispatchQueue.main.async {
          continuation.resume(returning: page)
        }
      }

      for relay in relays {
        relay.subscribeOlderActivityItems(
          scope: scope,
          until: requestDate,
          limit: limit
        ) { items in
          relayDidComplete(with: items)
        }
      }
    }
  }

  private func fetchOlderTextNoteBranches(
    _ branchScopes: [TextNoteFeedScope],
    until date: Date,
    limit: Int,
    completion: @escaping ([PersistedTextNoteSummary]) -> Void
  ) {
    let lock = NSLock()
    var completedCount = 0
    var receivedSummariesByID: [String: PersistedTextNoteSummary] = [:]

    func branchDidComplete(with summaries: [PersistedTextNoteSummary]) {
      lock.lock()
      for summary in summaries {
        receivedSummariesByID[summary.eventId] = summary
      }
      completedCount += 1
      let shouldComplete = completedCount == branchScopes.count
      let summaries = receivedSummariesByID.values.sorted {
        if $0.createdAt == $1.createdAt {
          return $0.eventId < $1.eventId
        }

        return $0.createdAt > $1.createdAt
      }
      lock.unlock()

      if shouldComplete {
        DispatchQueue.main.async {
          completion(summaries)
        }
      }
    }

    for branchScope in branchScopes {
      fetchOlderTextNotes(until: date, limit: limit, scope: branchScope) { summaries in
        branchDidComplete(with: summaries)
      }
    }
  }

  func updateTextNoteFeedScope(_ scope: TextNoteFeedScope) {
    guard textNoteFeedScope != scope else { return }

    textNoteFeedScope = scope

    for relay in nostrRelays {
      relay.setTextNoteFeedScope(scope)
    }
  }

  @discardableResult
  func observePersistedTextNotes(
    _ observer: @escaping ([PersistedTextNoteSummary]) -> Void
  ) -> UUID {
    let id = UUID()
    textNoteObservers[id] = observer
    return id
  }

  func removePersistedTextNoteObserver(_ id: UUID) {
    textNoteObservers.removeValue(forKey: id)
  }

  @discardableResult
  func observePersistedActivityItems(
    _ observer: @escaping ([ActivityItem]) -> Void
  ) -> UUID {
    let id = UUID()
    activityObservers[id] = observer
    return id
  }

  func removePersistedActivityObserver(_ id: UUID) {
    activityObservers.removeValue(forKey: id)
  }

  @MainActor
  @discardableResult
  func persistPublishedTextNote(_ event: Event) -> Bool {
    let context = ModelContext(modelContainer)
    let eventID = event.id
    var noteDescriptor = FetchDescriptor<RTextNote>(
      predicate: #Predicate { $0.eventId == eventID }
    )
    noteDescriptor.fetchLimit = 1

    do {
      let textNote: RTextNote
      if let existingNote = try context.fetch(noteDescriptor).first {
        textNote = existingNote
      } else {
        textNote = RTextNote.create(with: event)

        let publicKey = event.publicKey
        var profileDescriptor = FetchDescriptor<RUserProfile>(
          predicate: #Predicate { $0.publicKey == publicKey }
        )
        profileDescriptor.fetchLimit = 1

        if let profile = try context.fetch(profileDescriptor).first {
          textNote.userProfile = profile
        }

        context.insert(textNote)
        try context.save()
      }

      notifyPersistedTextNotes([
        PersistedTextNoteSummary(
          eventId: textNote.eventId,
          publicKey: textNote.publicKey,
          content: textNote.content,
          createdAt: textNote.createdAt,
          hashtags: textNote.taggedHashtags,
          isSensitiveContent: textNote.isSensitiveContent,
          sensitiveContentReason: textNote.sensitiveContentReason,
          origin: .localPublish
        )
      ])
      return true
    } catch {
      print("Error saving published text note: \(error)")
      return false
    }
  }

  @MainActor
  @discardableResult
  func persistPublishedProfileMetadata(_ event: Event) -> Bool {
    guard let publishedProfile = RUserProfile.create(with: event) else {
      return false
    }

    let context = ModelContext(modelContainer)
    let publicKey = publishedProfile.publicKey
    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == publicKey }
    )
    descriptor.fetchLimit = 1

    do {
      if let existingProfile = try context.fetch(descriptor).first {
        guard publishedProfile.createdAt >= existingProfile.createdAt else {
          return true
        }

        existingProfile.name = publishedProfile.name
        existingProfile.about = publishedProfile.about
        existingProfile.picture = publishedProfile.picture
        if existingProfile.nip05 != publishedProfile.nip05 {
          existingProfile.nip05 = publishedProfile.nip05
          existingProfile.resetNIP05Verification()
        }
        existingProfile.createdAt = publishedProfile.createdAt
      } else {
        context.insert(publishedProfile)
      }

      try context.save()
      return true
    } catch {
      print("Error saving published profile metadata: \(error)")
      return false
    }
  }

  @discardableResult
  func wipeLocalDataPreservingKeysAndRelays() -> Bool {
    disconnect()
    nostrRelays.removeAll()
    contactListFetchDates.removeAll()
    profileTextNoteFetchDates.removeAll()
    activityFetchDates.removeAll()
    NostrRelay.resetIngestionGate()

    let context = ModelContext(modelContainer)

    do {
      try deleteAll(RTextNote.self, in: context)
      try deleteAll(RThreadEvent.self, in: context)
      try deleteAll(RContactList.self, in: context)
      try deleteAll(RReaction.self, in: context)
      try deleteAll(RRepost.self, in: context)
      try deleteAll(RFollowNotification.self, in: context)
      try deleteAll(RUserProfile.self, in: context)
      try deleteAll(AppConsole.self, in: context)
      try deleteAll(SwiftDataEvent.self, in: context)
      try deleteAll(PendingPost.self, in: context)
      try context.save()

      updateLastSeenDate()
      storedRelays.loadData()
      bootstrapConfiguredRelays()
      return true
    } catch {
      print("Error wiping local data: \(error)")
      reconnect()
      return false
    }
  }

  private func deleteAll<Item: PersistentModel>(_: Item.Type, in context: ModelContext)
    throws
  {
    let items = try context.fetch(FetchDescriptor<Item>())
    for item in items {
      context.delete(item)
    }
  }

  func updateLastSeenDate() {
    updateLastSeenDate(to: Date.now)
  }

  func updateLastSeenDate(to date: Date) {
    UserDefaults.standard.setValue(
      Timestamp(date: date).timestamp, forKey: NostrData.lastSeenDefaultsKey)
    self.lastSeenDate = Date(
      timeIntervalSince1970: Double(
        UserDefaults.standard.integer(forKey: NostrData.lastSeenDefaultsKey)))
  }

  private func notifyPersistedTextNotes(_ summaries: [PersistedTextNoteSummary]) {
    guard !summaries.isEmpty else { return }

    DispatchQueue.main.async {
      for observer in self.textNoteObservers.values {
        observer(summaries)
      }
    }
  }

  private func notifyPersistedActivityItems(_ items: [ActivityItem]) {
    guard !items.isEmpty else { return }

    DispatchQueue.main.async {
      for observer in self.activityObservers.values {
        observer(items)
      }
    }
  }
}
