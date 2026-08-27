// a

import NostrKit
import SwiftData
import SDWebImageSwiftUI
import SwiftUI

struct ProfileDetailView: View {

  // QRVIEW PARAMETERS
  @EnvironmentObject var nostrData: NostrData
  @EnvironmentObject var navigation: AppNavigation
  @EnvironmentObject var keyManager: KeyManager
  @Environment(\.modelContext) private var modelContext

  // SWIFT DATA OBJECTS
  let publicKey: String
  @Query var userProfiles: [RUserProfile]
  @Query var contactLists: [RContactList]

  @State private var principalOpacity: Double = 1.0
  @State private var yOffset: CGFloat = 0
  @State private var isPublishingFollow = false
  @State private var followStateOverride: Bool?
  @State private var showKeyGenerator = false
  @State private var profileMetadataRequest: ProfileSearchRequest?
  @StateObject private var profileFeedController = HomeFeedController()

  init(publicKey: String) {
    self.publicKey = publicKey

    let profilePublicKey = publicKey
    var profileDescriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == profilePublicKey }
    )
    profileDescriptor.fetchLimit = 1
    _userProfiles = Query(profileDescriptor)
  }

  init(userProfile: RUserProfile) {
    self.init(publicKey: userProfile.publicKey)
  }

  var userProfile: RUserProfile {
    userProfiles.first ?? RUserProfile.createEmpty(withPublicKey: publicKey)
  }

  var contactList: RContactList? {
    return contactLists.first { $0.publicKey == self.publicKey }
  }

  var currentUserPublicKey: String? {
    keyManager.publicKeyHex(for: keyManager.selectedKey)
  }

  var currentUserSigningPublicKey: String? {
    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else { return nil }
    return privkey_to_pubkey(privkey: privateKeyHex)
  }

  var currentUserContactList: RContactList? {
    guard let currentUserPublicKey else { return nil }
    return contactLists.first { $0.publicKey == currentUserPublicKey }
  }

  var isCurrentUserProfile: Bool {
    currentUserPublicKey == publicKey
  }

  var isFollowing: Bool {
    if let followStateOverride {
      return followStateOverride
    }

    return currentUserContactList?.following.contains {
      $0.publicKey == publicKey
    } ?? false
  }

  // EVENTS OF USER
  var textNotes: [FeedItem] {
    profileFeedController.visibleItems
  }

  var profilePublicKeyBech32: String {
    bech32_pubkey(publicKey) ?? publicKey
  }

  var body: some View {
    let avatarUrl = userProfile.avatarUrl
    let username = profileDisplayTitle
    let pubkey = publicKey

    VStack(alignment: .center) {

      ScrollView {
        profileHeader(username: username, avatarUrl: avatarUrl, publicKey: pubkey)

        Divider()
          .padding(.horizontal, 16)

        LazyVStack(spacing: 20) {
          ForEach(textNotes, id: \.id) { textNote in
            EventView(feedItem: textNote)
              .id(textNote.id)
              .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
          }

          olderProfileFeedLoader
        }
        .padding()
      }
      Spacer()
    }
    .coordinateSpace(name: "scroll")

    // FETCH
    .task(id: publicKey) {
      profileFeedController.configure(modelContainer: nostrData.modelContainer, nostrData: nostrData)
      profileFeedController.setScope(.profile(pubkey: publicKey))
      profileFeedController.bootstrap()
      refreshDisplayedProfileMetadata()
      NostrData.shared.storedRelays.ensureDefaultRelays()
      nostrData.fetchTextNotes(forPublicKey: publicKey)
      nostrData.fetchContactList(forPublicKey: publicKey)
      if let currentUserPublicKey {
        nostrData.fetchContactList(forPublicKey: currentUserPublicKey)
      }
    }
    .task(id: "\(publicKey)|\(userProfile.nip05)") {
      await verifyDisplayedProfileNIP05IfNeeded()
    }
    .onDisappear {
      profileMetadataRequest?.cancel()
      profileMetadataRequest = nil
    }
    .sheet(isPresented: $showKeyGenerator) {
      KeyGen(initialMode: .generate)
        .environmentObject(keyManager)
    }
    .navigationTitle("")

    .toolbar {
      //UserProfileNavigationTitle(userProfile: userProfile)

      ToolbarItem(placement: .principal) {
        HStack {
          // AVATAR
          AvatarView(publicKey: pubkey, url: avatarUrl, size: 32)
          VStack(alignment: .leading) {
            // USERNAME
            HStack(spacing: 2) {
              Text(username)
                .font(.subheadline)
                .lineLimit(1)

                if userProfile.nip05VerificationStatus == .verified {
                  Image(systemName: "checkmark.seal.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Verified NIP-05")
                }
            }
            //PUBKEY
            HStack(alignment: .center, spacing: 2) {
              Text("\(Text(pubkey.prefix(8)))...")
              Image(systemName: "key.horizontal")
            }
            .font(.caption)
            .foregroundColor(.secondary)
          }
        }
        .opacity(principalOpacity)
      }

      //QR CODE
      ToolbarItem(placement: .navigationBarTrailing) {
        Button {
          navigation.push(.qr(publicKey: publicKey))
        } label: {
          Image(systemName: "qrcode")
        }
        .accessibilityLabel("QR Code")
      }

      //ACTION BUTTONS
      ToolbarItem(placement: .navigationBarTrailing) {
        Menu {
          Button {
            copyProfilePublicKey()
          } label: {
            Label("Copy npub", systemImage: "doc.on.doc")
          }

          Button {
            copyProfilePublicKeyHex()
          } label: {
            Label("Copy public key", systemImage: "key.horizontal")
          }
        } label: {
          Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
      }
    }
  }

  @ViewBuilder
  private var olderProfileFeedLoader: some View {
    if profileFeedController.isLoadingOlder {
      ProfileEventSkeletonBatch(count: 2)
    } else if profileFeedController.canLoadOlder {
      Color.clear
        .frame(height: 24)
        .onAppear {
          profileFeedController.loadOlder()
        }
    } else if profileFeedController.hasReachedOlderEnd && !textNotes.isEmpty {
      Text("No earlier posts")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
  }

  private var profileDisplayTitle: String {
    if userProfile.name.isValidName() {
      return userProfile.name
    }

    return profilePublicKeyBech32.accordionString(index: 10)
  }

  @ViewBuilder
  private func profileHeader(username: String, avatarUrl: URL?, publicKey: String) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 5) {
          Text(username)
            .font(.largeTitle.weight(.bold))
            .lineLimit(2)
            .minimumScaleFactor(0.78)
            .fixedSize(horizontal: false, vertical: true)

          profileVerificationLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        AvatarView(publicKey: publicKey, url: avatarUrl, size: 88)
          .padding(.top, 2)
      }

      if let about = userProfile.aboutFormatted {
        Text(about)
          .font(.body)
          .lineSpacing(3)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .lineLimit(8)
      }

      profileStatsRow
      profileActionSection
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .padding(.bottom, 16)
    .background(
      GeometryReader { geometry in
        Color.clear
          .preference(key: ViewOffsetKey.self, value: geometry.frame(in: .named("scroll")).minY)
      }
    )
    .onPreferenceChange(ViewOffsetKey.self, perform: updatePrincipalOpacity)
  }

  @ViewBuilder
  private var profileVerificationLine: some View {
    if let verifiedIdentifier = userProfile.verifiedNIP05 {
      HStack(alignment: .center, spacing: 5) {
        if let verificationURL = userProfile.nip05VerificationURL ?? verifiedIdentifier.url {
          Link(destination: verificationURL) {
            Text(verifiedIdentifier.displayDomain)
              .font(.headline.weight(.semibold))
              .lineLimit(1)
          }
          .accessibilityLabel("Verified by \(verifiedIdentifier.displayIdentifier)")
        } else {
          Text(verifiedIdentifier.displayDomain)
            .font(.headline.weight(.semibold))
            .lineLimit(1)
        }

        Image(systemName: "checkmark.seal.fill")
          .font(.subheadline.weight(.semibold))
          .accessibilityLabel("Verified NIP-05")
      }
      .foregroundStyle(.tint)
    }
  }

  @ViewBuilder
  private var profileStatsRow: some View {
    let followingCount = contactList?.visibleFollowingCount ?? 0
    let followedByCount = contactList?.visibleFollowedByCount ?? 0

    HStack(spacing: 6) {
      Button {
        if followedByCount > 0 {
          navigation.push(.followers(publicKey: publicKey))
        }
      } label: {
        Text("\(followedByCount) \(Self.followersLabel(for: followedByCount))")
      }
      .disabled(followedByCount == 0)

      Text("•")

      Button {
        if followingCount > 0 {
          navigation.push(.following(publicKey: publicKey))
        }
      } label: {
        Text("\(followingCount) following")
      }
      .disabled(followingCount == 0)
    }
    .buttonStyle(.plain)
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(.secondary)
  }

  private static func followersLabel(for count: Int) -> String {
    count == 1 ? "follower" : "followers"
  }

  private func updatePrincipalOpacity(offset: CGFloat) {
    let maxOpacity: Double = 1.0
    let minOpacity: Double = 0.0

    if offset >= 0 && offset <= 100 {
      principalOpacity = minOpacity
    } else if offset < -100 {
      principalOpacity = maxOpacity
    } else {
      let progress = Double((offset + 100) / 100)
      principalOpacity = maxOpacity - progress * (maxOpacity - minOpacity)
    }
  }

  @MainActor
  private func verifyDisplayedProfileNIP05IfNeeded() async {
    let identifier = userProfile.nip05.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty, NIP05.parse(identifier) != nil else { return }

    await nostrData.verifyNIP05IfNeeded(forPublicKey: publicKey, identifier: identifier)
  }

  @MainActor
  private func refreshDisplayedProfileMetadata() {
    profileMetadataRequest?.cancel()

    let requestedPublicKey = publicKey.lowercased()
    let repository = NostrProfileSearchRepository(nostrData: nostrData)
    profileMetadataRequest = repository.search(
      mode: .publicKey(requestedPublicKey),
      limit: 1
    ) { profiles in
      let resolvedProfile = profiles.first { $0.publicKey == requestedPublicKey }
      Task { @MainActor in
        profileMetadataRequest = nil
        guard let resolvedProfile else { return }

        let identifier = resolvedProfile.nip05.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NIP05.parse(identifier) != nil else { return }
        await nostrData.verifyNIP05IfNeeded(
          forPublicKey: requestedPublicKey,
          identifier: identifier
        )
      }
    }
  }

  @ViewBuilder
  private var messageButton: some View {
    if keyManager.selectedPrivateKeyHex == nil {
      Button {
        showKeyGenerator = true
      } label: {
        profileActionLabel("Message")
      }
      .buttonStyle(ProfileActionButtonStyle(kind: .secondary))
    } else {
      Button {
        navigation.push(.chat(publicKey: publicKey))
      } label: {
        profileActionLabel("Message")
      }
      .buttonStyle(ProfileActionButtonStyle(kind: .secondary))
    }
  }

  @ViewBuilder
  private var profileActionSection: some View {
    HStack(spacing: 12) {
      if isCurrentUserProfile {
        Button {
          navigation.push(.editProfile(publicKey: publicKey))
        } label: {
          profileActionLabel("Edit Profile")
        }
        .buttonStyle(ProfileActionButtonStyle(kind: .primary))
        .frame(maxWidth: .infinity)

        ShareLink(item: profileShareText) {
          profileActionLabel("Share Profile")
        }
        .buttonStyle(ProfileActionButtonStyle(kind: .secondary))
        .frame(maxWidth: .infinity)
      } else {
        Button(action: toggleFollow) {
          Group {
            if isPublishingFollow {
              ProgressView()
            } else {
              Text(isFollowing ? "Following" : "Follow")
            }
          }
          .frame(maxWidth: .infinity, minHeight: ProfileActionButtonStyle.height)
        }
        .buttonStyle(ProfileActionButtonStyle(kind: isFollowing ? .secondary : .primary))
        .disabled(isPublishingFollow)
        .frame(maxWidth: .infinity)

        messageButton
          .frame(maxWidth: .infinity)
      }
    }
  }

  private func profileActionLabel(_ title: String) -> some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .frame(maxWidth: .infinity, minHeight: ProfileActionButtonStyle.height)
  }

  private var profileShareText: String {
    let title = userProfile.name.isValidName() ? userProfile.name : "Nostr profile"
    return "\(title)\nnostr:\(profilePublicKeyBech32)"
  }

  private func copyProfilePublicKey() {
    UIPasteboard.general.string = profilePublicKeyBech32
    EfimerousManager.shared.showMessage("Copied")
  }

  private func copyProfilePublicKeyHex() {
    UIPasteboard.general.string = publicKey
    EfimerousManager.shared.showMessage("Copied")
  }

  private func toggleFollow() {
    guard !isPublishingFollow else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex,
      let currentUserSigningPublicKey = currentUserSigningPublicKey
    else {
      showKeyGenerator = true
      return
    }

    guard currentUserSigningPublicKey != publicKey else { return }

    let shouldFollow = !isFollowing
    let relayUrls = selectedRelayURLs()
    guard !relayUrls.isEmpty else {
      EfimerousManager.shared.showMessage("Select at least one relay")
      return
    }

    do {
      let keyPair = try KeyPair(privateKey: privateKeyHex)
      let draft = NIP02.followList(followedPublicKeys: updatedFollowPublicKeys(shouldFollow: shouldFollow))
      let followEvent = try PostEventContent(keyPair: keyPair, draft: draft)

      isPublishingFollow = true
      publishFollow(
        followEvent,
        to: relayUrls,
        shouldFollow: shouldFollow,
        currentUserPublicKey: currentUserSigningPublicKey
      )
    } catch {
      EfimerousManager.shared.showMessage("Couldn’t update follow")
    }
  }

  private func updatedFollowPublicKeys(shouldFollow: Bool) -> [String] {
    var publicKeys = currentUserContactList?.following.map { $0.publicKey } ?? []
    publicKeys.removeAll { $0 == publicKey }

    if shouldFollow {
      publicKeys.append(publicKey)
    }

    return publicKeys
  }

  private func selectedRelayURLs() -> [URL] {
    NostrData.shared.storedRelays.ensureDefaultRelays()
    return NostrData.shared.storedRelays.activeRelayAddresses.compactMap { URL(string: $0) }
  }

  private func publishFollow(
    _ followEvent: PostEventContent,
    to relayUrls: [URL],
    shouldFollow: Bool,
    currentUserPublicKey: String
  ) {
    var completedCount = 0
    var failedCount = 0

    for relayUrl in relayUrls {
      followEvent.sendToNostr(relayUrl: relayUrl) { result in
        completedCount += 1

        if case .failure = result {
          failedCount += 1
        }

        guard completedCount == relayUrls.count else { return }
        finishFollowPublishing(
          relayCount: relayUrls.count,
          failedCount: failedCount,
          shouldFollow: shouldFollow,
          currentUserPublicKey: currentUserPublicKey
        )
      }
    }
  }

  private func finishFollowPublishing(
    relayCount: Int,
    failedCount: Int,
    shouldFollow: Bool,
    currentUserPublicKey: String
  ) {
    isPublishingFollow = false

    guard failedCount < relayCount else {
      EfimerousManager.shared.showMessage("Couldn’t update follow")
      return
    }

    updateLocalFollowState(shouldFollow: shouldFollow, currentUserPublicKey: currentUserPublicKey)
    followStateOverride = shouldFollow
    EfimerousManager.shared.showMessage(shouldFollow ? "Following" : "Unfollowed")
    nostrData.fetchContactList(forPublicKey: currentUserPublicKey, force: true)
  }

  private func updateLocalFollowState(shouldFollow: Bool, currentUserPublicKey: String) {
    let list: RContactList
    if let currentUserContactList {
      list = currentUserContactList
    } else {
      let newList = RContactList.createEmpty(withPublicKey: currentUserPublicKey)
      modelContext.insert(newList)
      list = newList
    }

    list.following.removeAll { $0.publicKey == publicKey }

    if shouldFollow {
      list.following.append(storedProfileForViewedUser())
    }

    list.followingCount = max(list.following.count, list.followingCount + (shouldFollow ? 1 : -1))

    try? modelContext.save()
  }

  private func storedProfileForViewedUser() -> RUserProfile {
    let targetPublicKey = publicKey
    let descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == targetPublicKey }
    )

    if let profile = try? modelContext.fetch(descriptor).first {
      return profile
    }

    let profile = RUserProfile(
      publicKey: publicKey,
      name: userProfile.name,
      about: userProfile.about,
      picture: userProfile.picture,
      createdAt: userProfile.createdAt,
      nip05: userProfile.nip05,
      nip05VerificationStatusRaw: userProfile.nip05VerificationStatusRaw,
      nip05LastCheckedAt: userProfile.nip05LastCheckedAt,
      nip05VerificationURLString: userProfile.nip05VerificationURLString
    )
    modelContext.insert(profile)
    return profile
  }
}

struct ViewOffsetKey: PreferenceKey {
  typealias Value = CGFloat
  static var defaultValue = CGFloat.zero
  static func reduce(value: inout Value, nextValue: () -> Value) {
    value += nextValue()
  }
}

private enum ProfileActionButtonKind {
  case primary
  case secondary
}

private struct ProfileActionButtonStyle: ButtonStyle {
  static let height: CGFloat = 40

  let kind: ProfileActionButtonKind
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(foregroundColor)
      .background(backgroundShape(for: configuration))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }

  @ViewBuilder
  private func backgroundShape(for configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    switch kind {
    case .primary:
      shape
        .fill(Color.primary)
    case .secondary:
      shape
        .fill(Color.clear)
        .overlay {
          shape.stroke(Color.secondary.opacity(colorScheme == .dark ? 0.38 : 0.3), lineWidth: 1)
        }
    }
  }

  private var foregroundColor: Color {
    switch kind {
    case .primary:
      return Color(uiColor: .systemBackground)
    case .secondary:
      return .primary
    }
  }
}

private struct ProfileEventSkeletonView: View {
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(Color.secondary.opacity(0.18))
        .frame(width: 44, height: 44)

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Capsule()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 132, height: 14)

          Capsule()
            .fill(Color.secondary.opacity(0.12))
            .frame(width: 36, height: 12)

          Spacer()
        }

        Capsule()
          .fill(Color.secondary.opacity(0.16))
          .frame(maxWidth: .infinity, minHeight: 13, maxHeight: 13)

        Capsule()
          .fill(Color.secondary.opacity(0.14))
          .frame(maxWidth: 260, minHeight: 13, maxHeight: 13)
      }
    }
    .redacted(reason: .placeholder)
    .padding(.vertical, 2)
  }
}

private struct ProfileEventSkeletonBatch: View {
  let count: Int

  var body: some View {
    ForEach(0..<count, id: \.self) { _ in
      ProfileEventSkeletonView()
      Divider()
    }
  }
}
