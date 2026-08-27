// a

import SwiftData
import SwiftUI

struct SearchView: View {
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var nostrData: NostrData
  @EnvironmentObject var keyManager: KeyManager

  @State private var searchText = ""
  @State private var profileResults: [ProfileSearchResult] = []
  @State private var suggestions: [ProfileSearchResult] = []
  @State private var remoteProfiles: [ProfileSearchProfile] = []
  @State private var isSearchingRelays = false
  @State private var profileSearchTask: Task<Void, Never>?
  @State private var remoteSearchRequest: ProfileSearchRequest?
  @State private var searchGeneration = UUID()

  var body: some View {
    List {
      searchInputSection
      directProfileSection

      if trimmedSearchText.isEmpty {
        suggestionsSection
      } else {
        profileResultsSection
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Search")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      refreshSuggestions()
    }
    .onChange(of: searchText) { _, _ in
      scheduleProfileSearch()
    }
    .onChange(of: keyManager.selectedKey) { _, _ in
      refreshSuggestions()
      scheduleProfileSearch()
    }
    .onDisappear {
      profileSearchTask?.cancel()
      remoteSearchRequest?.cancel()
      remoteSearchRequest = nil
    }
  }

  private var activePublicKey: String? {
    if let privateKeyHex = keyManager.selectedPrivateKeyHex {
      return privkey_to_pubkey(privkey: privateKeyHex)
    }

    guard case .pub(let publicKeyHex) = decode_bech32_key(keyManager.selectedKey) else {
      return nil
    }

    return publicKeyHex
  }

  private var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var normalizedSearchText: String {
    trimmedSearchText.lowercased()
  }

  private var pastedPublicKey: String? {
    let normalized = normalizedSearchText
    guard !normalized.isEmpty else { return nil }

    if case .pub(let publicKeyHex) = decode_bech32_key(normalized) {
      return publicKeyHex
    }

    let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
    if normalized.count == 64,
      normalized.unicodeScalars.allSatisfy({ hexCharacters.contains($0) })
    {
      return normalized
    }

    return nil
  }

  private var searchInputSection: some View {
    Section("Search") {
      TextField("npub, name, keyword", text: $searchText, axis: .vertical)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .lineLimit(1...3)
    }
  }

  @ViewBuilder
  private var directProfileSection: some View {
    if let pastedPublicKey {
      Section("Open") {
        NavigationLink(value: AppNavigation.Route.profile(publicKey: pastedPublicKey)) {
          SearchProfileRow(
            publicKey: pastedPublicKey,
            profile: profile(for: pastedPublicKey),
            reason: "Public Key"
          )
        }

        if isSearchingRelays {
          searchProgressRow
        }
      }
    }
  }

  @ViewBuilder
  private var suggestionsSection: some View {
    if suggestions.isEmpty {
      Section {
        SearchEmptyState(
          systemImage: "safari",
          title: "Explore",
          message: "Search by npub, profile name, or keyword."
        )
      }
      .listRowBackground(Color.clear)
    } else {
      Section("Suggestions") {
        ForEach(suggestions) { result in
          NavigationLink(value: AppNavigation.Route.profile(publicKey: result.publicKey)) {
            SearchProfileRow(
              publicKey: result.publicKey,
              profile: result.profile,
              reason: result.reason
            )
          }
        }
      }
    }
  }

  @ViewBuilder
  private var profileResultsSection: some View {
    let filteredResults = profileResults.filter { $0.publicKey != pastedPublicKey }

    if pastedPublicKey != nil {
      EmptyView()
    } else if !filteredResults.isEmpty || isSearchingRelays {
      Section("Profiles") {
        ForEach(filteredResults) { result in
          NavigationLink(value: AppNavigation.Route.profile(publicKey: result.publicKey)) {
            SearchProfileRow(
              publicKey: result.publicKey,
              profile: result.profile,
              reason: result.reason
            )
          }
        }

        if isSearchingRelays {
          searchProgressRow
        }
      }
    } else {
      Section {
        if normalizedSearchText.count < 2 {
          SearchEmptyState(
            systemImage: "text.cursor",
            title: "Keep Typing",
            message: "Enter at least two characters or paste a full npub."
          )
        } else if !nostrData.isNetworkEnabled {
          SearchEmptyState(
            systemImage: "wifi.slash",
            title: "Offline",
            message: "Turn network access on to search for profiles."
          )
        } else if nostrData.storedRelays.activeRelayAddresses.isEmpty {
          SearchEmptyState(
            systemImage: "network.slash",
            title: "No Active Relays",
            message: "Turn on a relay to search for profiles."
          )
        } else {
          SearchEmptyState(
            systemImage: "person.crop.circle.badge.questionmark",
            title: "No Results",
            message: "No profiles were found on your active relays."
          )
        }
      }
      .listRowBackground(Color.clear)
    }
  }

  private var searchProgressRow: some View {
    HStack(spacing: 12) {
      ProgressView()
        .controlSize(.small)

      Text("Searching relays...")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private func scheduleProfileSearch() {
    profileSearchTask?.cancel()
    remoteSearchRequest?.cancel()
    remoteSearchRequest = nil

    let generation = UUID()
    searchGeneration = generation
    remoteProfiles = []
    isSearchingRelays = false

    let query = normalizedSearchText
    if let pastedPublicKey {
      profileResults = []
      isSearchingRelays = true
      beginRemoteSearch(
        mode: .publicKey(pastedPublicKey),
        query: query,
        generation: generation
      )
      return
    }

    guard query.count >= 2 else {
      profileResults = []
      return
    }

    isSearchingRelays = true
    profileSearchTask = Task {
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }

      await MainActor.run {
        refreshProfileResults(for: query)
      }

      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard searchGeneration == generation else { return }
        beginRemoteSearch(mode: .text(trimmedSearchText), query: query, generation: generation)
      }
    }
  }

  private func refreshProfileResults(for query: String) {
    let profiles = mergedProfiles(cached: fetchProfiles(limit: 180), remote: remoteProfiles)
    let scored = scoreProfiles(
      profiles,
      query: query,
      remotePublicKeys: Set(remoteProfiles.map(\.publicKey))
    )

    profileResults = Array(scored.prefix(20))
  }

  private func beginRemoteSearch(
    mode: ProfileSearchMode,
    query: String,
    generation: UUID
  ) {
    guard searchGeneration == generation else { return }

    let repository = NostrProfileSearchRepository(nostrData: nostrData)
    remoteSearchRequest = repository.search(mode: mode, limit: 20) { profiles in
      Task { @MainActor in
        guard searchGeneration == generation else { return }

        remoteProfiles = profiles
        isSearchingRelays = false
        remoteSearchRequest = nil

        if !mode.isExactPublicKey {
          refreshProfileResults(for: query)
        }
      }
    }
  }

  private func refreshSuggestions() {
    let profiles = fetchProfiles(limit: 220)
    suggestions = Array(scoreProfiles(profiles, query: "").prefix(18))
  }

  private func scoreProfiles(
    _ profiles: [ProfileSearchProfile],
    query: String,
    remotePublicKeys: Set<String> = []
  ) -> [ProfileSearchResult] {
    let activePublicKey = activePublicKey
    let interactionScores = fetchInteractionScores(activePublicKey: activePublicKey)
    let watcherTerms = fetchWatcherTerms(activePublicKey: activePublicKey)
    let postSignals = fetchPostSignals(watcherTerms: watcherTerms)
    let followingPublicKeys = fetchFollowingPublicKeys(activePublicKey: activePublicKey)

    return profiles
      .compactMap { profile -> ProfileSearchResult? in
        guard profile.publicKey != activePublicKey else { return nil }

        let npub = bech32_pubkey(profile.publicKey) ?? profile.publicKey
        let searchableText = [
          profile.name,
          profile.about,
          profile.publicKey,
          npub,
          postSignals.profileText[profile.publicKey] ?? "",
        ]
        .joined(separator: " ")
        .lowercased()

        let isRemoteResult = remotePublicKeys.contains(profile.publicKey)
        guard query.isEmpty || searchableText.contains(query) || isRemoteResult else { return nil }

        var score = 0
        var reasons: [String] = []

        if !query.isEmpty {
          if profile.name.lowercased().contains(query) {
            score += 80
            reasons.append("Name")
          }
          if npub.lowercased().contains(query) || profile.publicKey.lowercased().contains(query) {
            score += 70
            reasons.append("Public Key")
          }
          if profile.about.lowercased().contains(query) {
            score += 45
            reasons.append("Bio")
          }
          if (postSignals.profileText[profile.publicKey] ?? "").lowercased().contains(query) {
            score += 35
            reasons.append("Posts")
          }
        }

        let interactionScore = interactionScores[profile.publicKey, default: 0]
        if interactionScore > 0 {
          score += 40 + min(interactionScore, 40)
          reasons.append("Interaction")
        }

        let likeScore = postSignals.likeScores[profile.publicKey, default: 0]
        if likeScore > 0 {
          score += min(likeScore, 50)
          reasons.append("Liked Posts")
        }

        if followingPublicKeys.contains(profile.publicKey) {
          score += 30
          reasons.append("Following")
        }

        if postSignals.watcherMatches.contains(profile.publicKey) {
          score += 25
          reasons.append("My Verse")
        }

        if isRemoteResult {
          score += 20
        }

        if profile.createdAt > .distantPast {
          score += 4
        }

        guard !query.isEmpty || score > 0 || profile.hasMetadata else { return nil }

        return ProfileSearchResult(
          publicKey: profile.publicKey,
          profile: profile,
          score: score,
          reason: reasons.first
            ?? (isRemoteResult ? "Search" : (profile.hasMetadata ? "Cached" : "Profile"))
        )
      }
      .sorted { lhs, rhs in
        if lhs.score == rhs.score {
          return profileSortTitle(lhs.profile, publicKey: lhs.publicKey)
            .localizedCaseInsensitiveCompare(
              profileSortTitle(rhs.profile, publicKey: rhs.publicKey)
            ) == .orderedAscending
        }

        return lhs.score > rhs.score
      }
  }

  private func fetchProfiles(limit: Int) -> [ProfileSearchProfile] {
    var descriptor = FetchDescriptor<RUserProfile>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    return ((try? modelContext.fetch(descriptor)) ?? [])
      .compactMap(ProfileSearchProfile.init(cachedProfile:))
  }

  private func mergedProfiles(
    cached: [ProfileSearchProfile],
    remote: [ProfileSearchProfile]
  ) -> [ProfileSearchProfile] {
    var profilesByPublicKey = Dictionary(uniqueKeysWithValues: cached.map { ($0.publicKey, $0) })

    for profile in remote {
      if let existing = profilesByPublicKey[profile.publicKey],
        existing.createdAt > profile.createdAt
      {
        continue
      }
      profilesByPublicKey[profile.publicKey] = profile
    }

    return Array(profilesByPublicKey.values)
  }

  private func fetchInteractionScores(activePublicKey: String?) -> [String: Int] {
    guard let activePublicKey else { return [:] }

    var scores: [String: Int] = [:]

    var messageDescriptor = FetchDescriptor<RDirectMessage>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    messageDescriptor.fetchLimit = 160

    for message in (try? modelContext.fetch(messageDescriptor)) ?? [] {
      guard let peerPublicKey = message.peerPublicKey(for: activePublicKey) else { continue }
      scores[peerPublicKey, default: 0] += 6
    }

    var reactionDescriptor = FetchDescriptor<RReaction>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    reactionDescriptor.fetchLimit = 240

    for reaction in (try? modelContext.fetch(reactionDescriptor)) ?? [] {
      if reaction.reactorPublicKey == activePublicKey {
        scores[reaction.targetPublicKey, default: 0] += 4
      } else if reaction.targetPublicKey == activePublicKey {
        scores[reaction.reactorPublicKey, default: 0] += 5
      }
    }

    var followDescriptor = FetchDescriptor<RFollowNotification>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    followDescriptor.fetchLimit = 120

    for notification in (try? modelContext.fetch(followDescriptor)) ?? []
      where notification.targetPublicKey == activePublicKey
    {
      scores[notification.followerPublicKey, default: 0] += 5
    }

    return scores
  }

  private struct PostSignals {
    var likeScores: [String: Int] = [:]
    var watcherMatches = Set<String>()
    var profileText: [String: String] = [:]
  }

  private func fetchPostSignals(watcherTerms: [String]) -> PostSignals {
    var noteDescriptor = FetchDescriptor<RTextNote>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    noteDescriptor.fetchLimit = 220
    let notes = (try? modelContext.fetch(noteDescriptor)) ?? []

    var likeScoresByEventID: [String: Int] = [:]
    var reactionDescriptor = FetchDescriptor<RReaction>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    reactionDescriptor.fetchLimit = 600

    for reaction in (try? modelContext.fetch(reactionDescriptor)) ?? [] where reaction.isLike {
      likeScoresByEventID[reaction.reactedEventId, default: 0] += 1
    }

    var signals = PostSignals()

    for note in notes {
      signals.likeScores[note.publicKey, default: 0] += likeScoresByEventID[note.eventId, default: 0]

      let normalizedContent = note.content.lowercased()
      if watcherTerms.contains(where: { normalizedContent.contains($0) }) {
        signals.watcherMatches.insert(note.publicKey)
      }

      if signals.profileText[note.publicKey, default: ""].count < 2_000 {
        signals.profileText[note.publicKey, default: ""].append(" \(normalizedContent)")
      }
    }

    return signals
  }

  private func fetchWatcherTerms(activePublicKey: String?) -> [String] {
    guard let activePublicKey else { return [] }

    let ownerPublicKey = activePublicKey
    let descriptor = FetchDescriptor<VerseWatcher>(
      predicate: #Predicate { $0.ownerPublicKey == ownerPublicKey && $0.isEnabled }
    )

    let watchers = (try? modelContext.fetch(descriptor)) ?? []
    return watchers.flatMap(\.terms)
  }

  private func fetchFollowingPublicKeys(activePublicKey: String?) -> Set<String> {
    guard let activePublicKey else { return [] }

    let ownerPublicKey = activePublicKey
    var descriptor = FetchDescriptor<RContactList>(
      predicate: #Predicate { $0.publicKey == ownerPublicKey }
    )
    descriptor.fetchLimit = 1

    guard let contactList = try? modelContext.fetch(descriptor).first else {
      return []
    }

    return Set(contactList.following.map(\.publicKey))
  }

  private func profile(for publicKey: String) -> ProfileSearchProfile? {
    let remoteProfile = remoteProfiles.first { $0.publicKey == publicKey }
    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == publicKey }
    )
    descriptor.fetchLimit = 1

    let cachedProfile = (try? modelContext.fetch(descriptor).first)
      .flatMap(ProfileSearchProfile.init(cachedProfile:))

    guard let remoteProfile else { return cachedProfile }
    guard let cachedProfile else { return remoteProfile }
    return remoteProfile.createdAt >= cachedProfile.createdAt ? remoteProfile : cachedProfile
  }

  private func profileSortTitle(_ profile: ProfileSearchProfile?, publicKey: String) -> String {
    if let name = profile?.name, name.isValidName() {
      return name
    }

    return bech32_pubkey(publicKey) ?? publicKey
  }
}

private struct ProfileSearchResult: Identifiable {
  var id: String { publicKey }
  let publicKey: String
  let profile: ProfileSearchProfile?
  let score: Int
  let reason: String
}

private struct SearchProfileRow: View {
  let publicKey: String
  let profile: ProfileSearchProfile?
  let reason: String

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(publicKey: publicKey, url: profile?.avatarURL, size: 42)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(displayName)
            .font(.body.weight(.semibold))
            .foregroundColor(.primary)
            .lineLimit(1)

          Spacer(minLength: 8)

          Text(reason)
            .font(.caption.weight(.medium))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }

        Text(shortPublicKey)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)

        if let about = profile?.about, !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(about)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(2)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private var displayName: String {
    if let name = profile?.name, name.isValidName() {
      return name
    }

    return shortPublicKey
  }

  private var shortPublicKey: String {
    (bech32_pubkey(publicKey) ?? publicKey).accordionString(index: 10)
  }
}

private struct SearchEmptyState: View {
  let systemImage: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 34, weight: .regular))
        .foregroundColor(.secondary)

      Text(title)
        .font(.headline)

      Text(message)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 300)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
  }
}

struct SearchView_Previews: PreviewProvider {
  static var previews: some View {
    NavigationStack {
      SearchView()
        .environmentObject(KeyManager())
        .environmentObject(NostrData.shared.initPreview())
        .modelContainer(NostrData.shared.modelContainer)
    }
  }
}
