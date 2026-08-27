// a

import SwiftData
import SwiftUI

struct MessagesView: View {
  private let inboxSync = MessagingInboxSync()

  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject var keyManager: KeyManager

  @State private var searchText = ""
  @State private var showKeyGenerator = false
  @State private var isSyncingInbox = false
  @StateObject private var inboxController = MessagingInboxController()

  var body: some View {
    List {
      if activePublicKey == nil {
        noKeySection
      } else if filteredConversationSummaries.isEmpty {
        emptyMessagesSection
      } else {
        conversationsSection
      }
    }
    .listStyle(.insetGrouped)
    .searchable(text: $searchText, prompt: "Search messages")
    .navigationTitle("Messages")
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        NavigationLink {
          NewChat()
        } label: {
          Image(systemName: "square.and.pencil")
        }
        .disabled(activePublicKey == nil)
        .accessibilityLabel("New Message")
      }
    }
    .sheet(isPresented: $showKeyGenerator) {
      KeyGen(initialMode: .generate)
        .environmentObject(keyManager)
    }
    .onAppear {
      configureInboxController()
    }
    .task(id: activePublicKey) {
      configureInboxController()
      syncInboxIfPossible()
    }
  }

  private var activePublicKey: String? {
    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else { return nil }
    return privkey_to_pubkey(privkey: privateKeyHex)
  }

  private var filteredConversationSummaries: [DirectConversationItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return conversationSummaries }

    return conversationSummaries.filter { summary in
      let profile = profile(for: summary.peerPublicKey)
      let displayName = MessagingProfileText.displayName(for: profile, publicKey: summary.peerPublicKey)
      let npub = bech32_pubkey(summary.peerPublicKey) ?? summary.peerPublicKey

      return displayName.lowercased().contains(query)
        || npub.lowercased().contains(query)
        || summary.lastMessage.lowercased().contains(query)
    }
  }

  private var conversationSummaries: [DirectConversationItem] {
    guard activePublicKey != nil else { return [] }
    return inboxController.visibleConversations
  }

  private var noKeySection: some View {
    Section {
      VStack(spacing: 14) {
        Image(systemName: "key")
          .font(.system(size: 36, weight: .regular))
          .foregroundColor(.secondary)

        Text("Add a Key")
          .font(.title3.weight(.semibold))

        Text("Messages need a saved private key so they can be encrypted and opened on this device.")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 300)

        Button("Add Key") {
          showKeyGenerator = true
        }
        .buttonStyle(.borderedProminent)
        .padding(.top, 4)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 34)
    }
    .listRowBackground(Color.clear)
  }

  private var emptyMessagesSection: some View {
    Section {
      VStack(spacing: 14) {
        Image(systemName: "lock.shield")
          .font(.system(size: 36, weight: .regular))
          .foregroundColor(.secondary)

        Text("No Messages")
          .font(.title3.weight(.semibold))

        Text("Start a private conversation from a profile, or compose a new one.")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 300)

        NavigationLink {
          NewChat()
        } label: {
          Text("New Message")
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .padding(.top, 4)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 34)
    }
    .listRowBackground(Color.clear)
  }

  private var conversationsSection: some View {
    Section {
      ForEach(filteredConversationSummaries) { summary in
        NavigationLink(value: AppNavigation.Route.chat(publicKey: summary.peerPublicKey)) {
          MessagingConversationRow(
            publicKey: summary.peerPublicKey,
            profile: profile(for: summary.peerPublicKey),
            lastMessage: summary.lastMessage,
            lastDate: summary.lastDate
          )
        }
      }
    }
  }

  private func profile(for publicKey: String) -> RUserProfile? {
    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == publicKey }
    )
    descriptor.fetchLimit = 1

    return try? modelContext.fetch(descriptor).first
  }

  private func syncInboxIfPossible() {
    guard !isSyncingInbox,
      let privateKeyHex = keyManager.selectedPrivateKeyHex
    else {
      return
    }

    NostrData.shared.storedRelays.ensureDefaultRelays()
    let relayURLs = NostrData.shared.storedRelays.activeRelayAddresses.compactMap { URL(string: $0) }
    guard !relayURLs.isEmpty else { return }

    isSyncingInbox = true
    inboxSync.sync(
      recipientPrivateKeyHex: privateKeyHex,
      relayURLs: relayURLs,
      modelContainer: NostrData.shared.modelContainer
    ) { _ in
      isSyncingInbox = false
      configureInboxController()
      inboxController.refreshFromCache()
    }
  }

  private func configureInboxController() {
    guard let activePublicKey else {
      inboxController.reset()
      return
    }

    inboxController.configure(
      modelContainer: NostrData.shared.modelContainer,
      activePublicKey: activePublicKey
    )
  }
}

struct MessagingConversationSummary: Identifiable, Hashable {
  var id: String { peerPublicKey }
  let peerPublicKey: String
  let lastMessage: String
  let lastDate: Date
}

struct MessagingProfileRow: View {
  let profile: RUserProfile

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(publicKey: profile.publicKey, url: profile.avatarUrl, size: 42)

      VStack(alignment: .leading, spacing: 3) {
        Text(displayName)
          .font(.body.weight(.semibold))
          .foregroundColor(.primary)
          .lineLimit(1)

        Text(shortPublicKey)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 4)
  }

  private var displayName: String {
    MessagingProfileText.displayName(for: profile, publicKey: profile.publicKey)
  }

  private var shortPublicKey: String {
    (bech32_pubkey(profile.publicKey) ?? profile.publicKey).accordionString(index: 10)
  }
}

struct MessagingConversationRow: View {
  let publicKey: String
  let profile: RUserProfile?
  let lastMessage: String
  let lastDate: Date

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(publicKey: publicKey, url: profile?.avatarUrl, size: 46)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(displayName)
            .font(.body.weight(.semibold))
            .foregroundColor(.primary)
            .lineLimit(1)

          Spacer(minLength: 8)

          Text(dateLabel)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }

        Text(lastMessage)
          .font(.subheadline)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 4)
  }

  private var displayName: String {
    MessagingProfileText.displayName(for: profile, publicKey: publicKey)
  }

  private var dateLabel: String {
    if Calendar.current.isDateInToday(lastDate) {
      return Self.timeFormatter.string(from: lastDate)
    }

    return Self.dateFormatter.string(from: lastDate)
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
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
  }()
}

enum MessagingProfileText {
  static func displayName(for profile: RUserProfile?, publicKey: String) -> String {
    if let name = profile?.name, name.isValidName() {
      return name
    }

    return (bech32_pubkey(publicKey) ?? publicKey).accordionString(index: 10)
  }
}

struct MessagesView_Previews: PreviewProvider {
  static var previews: some View {
    NavigationStack {
      MessagesView()
        .environmentObject(KeyManager())
    }
  }
}
