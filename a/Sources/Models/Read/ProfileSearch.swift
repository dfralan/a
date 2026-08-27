import Foundation
import NostrKit
import SwiftData

struct ProfileSearchProfile: Identifiable, Hashable, Sendable {
  let publicKey: String
  let name: String
  let about: String
  let picture: String
  let nip05: String
  let createdAt: Date

  var id: String { publicKey }

  var avatarURL: URL? {
    let value = picture.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, let url = URL(string: value) else { return nil }
    guard url.scheme != nil || value.hasPrefix("data:") else { return nil }
    return url
  }

  var hasMetadata: Bool {
    name.isValidName()
      || !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !picture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  init?(cachedProfile: RUserProfile) {
    self.init(
      publicKey: cachedProfile.publicKey,
      name: cachedProfile.name,
      about: cachedProfile.about,
      picture: cachedProfile.picture,
      nip05: cachedProfile.nip05,
      createdAt: cachedProfile.createdAt
    )
  }

  init?(
    publicKey: String,
    name: String,
    about: String,
    picture: String,
    nip05: String,
    createdAt: Date
  ) {
    guard Self.isValidPublicKey(publicKey) else { return nil }

    self.publicKey = publicKey.lowercased()
    self.name = Self.bounded(name, limit: 256)
    self.about = Self.bounded(about, limit: 4_096)
    self.picture = Self.bounded(picture, limit: 2_048)
    self.nip05 = Self.bounded(nip05.lowercased(), limit: 320)
    self.createdAt = createdAt
  }

  init?(event: Event) {
    guard event.kind.integerValue == 0,
      event.content.utf8.count <= 128 * 1_024,
      let data = event.content.data(using: .utf8),
      let metadata = try? JSONDecoder().decode(NostrRelay.SetMetaDataEventData.self, from: data)
    else {
      return nil
    }

    self.init(
      publicKey: event.publicKey,
      name: metadata.preferredName,
      about: metadata.about ?? "",
      picture: metadata.picture ?? "",
      nip05: metadata.normalizedNIP05,
      createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt.timestamp))
    )
  }

  private static func bounded(_ value: String, limit: Int) -> String {
    String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
  }

  static func isValidPublicKey(_ value: String) -> Bool {
    guard value.count == 64 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 48...57, 65...70, 97...102: return true
      default: return false
      }
    }
  }
}

enum ProfileSearchMode: Hashable, Sendable {
  case text(String)
  case publicKey(String)

  var normalizedValue: String {
    switch self {
    case .text(let query):
      return query.trimmingCharacters(in: .whitespacesAndNewlines)
    case .publicKey(let query):
      return query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
  }

  var isExactPublicKey: Bool {
    if case .publicKey = self { return true }
    return false
  }

  var isValid: Bool {
    switch self {
    case .text:
      return (2...256).contains(normalizedValue.count)
    case .publicKey:
      return ProfileSearchProfile.isValidPublicKey(normalizedValue)
    }
  }
}

struct ProfileSearchRelayQuery: Hashable, Sendable {
  let mode: ProfileSearchMode
  let limit: Int

  var authors: [String]? {
    guard case .publicKey = mode else { return nil }
    return [mode.normalizedValue]
  }

  var search: String? {
    guard case .text = mode else { return nil }
    return mode.normalizedValue
  }

  var relayLimit: Int {
    mode.isExactPublicKey ? 1 : limit
  }
}

final class ProfileSearchRequest {
  private let lock = NSLock()
  private var cancellation: (() -> Void)?

  init(cancellation: @escaping () -> Void = {}) {
    self.cancellation = cancellation
  }

  func cancel() {
    lock.lock()
    let action = cancellation
    cancellation = nil
    lock.unlock()
    action?()
  }
}

protocol ProfileSearchRepositoryProtocol: AnyObject {
  @discardableResult
  func search(
    mode: ProfileSearchMode,
    limit: Int,
    completion: @escaping ([ProfileSearchProfile]) -> Void
  ) -> ProfileSearchRequest
}

final class NostrProfileSearchRepository: ProfileSearchRepositoryProtocol {
  private let nostrData: NostrData

  init(nostrData: NostrData) {
    self.nostrData = nostrData
  }

  @discardableResult
  func search(
    mode: ProfileSearchMode,
    limit: Int = 20,
    completion: @escaping ([ProfileSearchProfile]) -> Void
  ) -> ProfileSearchRequest {
    guard mode.isValid, nostrData.isNetworkEnabled else {
      completion([])
      return ProfileSearchRequest()
    }

    let activeRelayURLs = Set(nostrData.storedRelays.activeRelayAddresses)
    for relayURL in activeRelayURLs
      where !nostrData.nostrRelays.contains(where: { $0.urlString == relayURL })
    {
      nostrData.bootstrapRelays(relay: relayURL)
    }

    let relays = nostrData.nostrRelays.filter { activeRelayURLs.contains($0.urlString) }
    guard !relays.isEmpty else {
      completion([])
      return ProfileSearchRequest()
    }

    let query = ProfileSearchRelayQuery(mode: mode, limit: max(1, min(limit, 40)))
    let state = ProfileSearchAggregationState(expectedCount: relays.count)

    for relay in relays {
      if !relay.connected && !relay.isConnecting {
        relay.connect()
      }

      let subscriptionID = relay.subscribeProfileSearch(query: query) { events in
        state.lock.lock()
        guard !state.cancelled else {
          state.lock.unlock()
          return
        }

        state.events.append(contentsOf: events)
        state.completedCount += 1
        let isComplete = state.completedCount == state.expectedCount
        let mergedEvents = state.events
        state.lock.unlock()

        guard isComplete else { return }
        let profiles = Self.process(events: mergedEvents, mode: mode, limit: query.limit)
        self.persist(profiles)
        completion(profiles)
      }
      state.requests.append((relay, subscriptionID))
    }

    return ProfileSearchRequest {
      state.lock.lock()
      guard !state.cancelled else {
        state.lock.unlock()
        return
      }
      state.cancelled = true
      let requests = state.requests
      state.lock.unlock()

      requests.forEach { request in
        request.0.cancelProfileSearch(subscriptionID: request.1)
      }
    }
  }

  static func process(
    events: [Event],
    mode: ProfileSearchMode,
    limit: Int
  ) -> [ProfileSearchProfile] {
    var seenEventIDs = Set<String>()
    var newestByPublicKey: [String: ProfileSearchProfile] = [:]

    for event in events where seenEventIDs.insert(event.id).inserted {
      guard let profile = ProfileSearchProfile(event: event) else { continue }

      switch mode {
      case .text(let query):
        guard Self.matches(profile: profile, query: query) else { continue }
      case .publicKey(let publicKey):
        guard profile.publicKey == publicKey.lowercased() else { continue }
      }

      if let existing = newestByPublicKey[profile.publicKey],
        existing.createdAt > profile.createdAt
      {
        continue
      }
      newestByPublicKey[profile.publicKey] = profile
    }

    return Array(
      newestByPublicKey.values
        .sorted {
          if $0.createdAt == $1.createdAt { return $0.publicKey < $1.publicKey }
          return $0.createdAt > $1.createdAt
        }
        .prefix(max(1, limit))
    )
  }

  private static func matches(profile: ProfileSearchProfile, query: String) -> Bool {
    let terms = query
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !terms.isEmpty else { return false }

    let searchableText = [
      profile.name,
      profile.about,
      profile.nip05,
      profile.publicKey,
      bech32_pubkey(profile.publicKey) ?? "",
    ]
    .joined(separator: " ")
    .lowercased()

    return terms.allSatisfy(searchableText.contains)
  }

  private func persist(_ profiles: [ProfileSearchProfile]) {
    guard !profiles.isEmpty else { return }

    let context = ModelContext(nostrData.modelContainer)
    for profile in profiles {
      let publicKey = profile.publicKey
      var descriptor = FetchDescriptor<RUserProfile>(
        predicate: #Predicate { $0.publicKey == publicKey }
      )
      descriptor.fetchLimit = 1

      if let cached = try? context.fetch(descriptor).first {
        guard cached.createdAt <= profile.createdAt else { continue }
        let nip05Changed = cached.nip05 != profile.nip05
        cached.name = profile.name
        cached.about = profile.about
        cached.picture = profile.picture
        cached.nip05 = profile.nip05
        cached.createdAt = profile.createdAt
        if nip05Changed {
          cached.resetNIP05Verification()
        }
      } else {
        context.insert(
          RUserProfile(
            publicKey: profile.publicKey,
            name: profile.name,
            about: profile.about,
            picture: profile.picture,
            createdAt: profile.createdAt,
            nip05: profile.nip05
          )
        )
      }
    }

    do {
      try context.save()
    } catch {
      print("ProfileSearch cache save failed: \(error)")
    }
  }
}

private final class ProfileSearchAggregationState {
  let lock = NSLock()
  let expectedCount: Int
  var completedCount = 0
  var events: [Event] = []
  var requests: [(NostrRelay, String)] = []
  var cancelled = false

  init(expectedCount: Int) {
    self.expectedCount = expectedCount
  }
}
