// a

import SwiftData
import SwiftUI

struct ChatView: View {
  let publicKey: String
  private let messagingService = MessagingService()
  private let inboxSync = MessagingInboxSync()

  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject var keyManager: KeyManager
  @EnvironmentObject var navigation: AppNavigation
  @Query private var userProfiles: [RUserProfile]

  @State private var chatField = ""
  @State private var showKeyGenerator = false
  @State private var deliveryNotice: String?
  @State private var isSyncingInbox = false
  @State private var isAdvertisingInbox = false
  @State private var lastInboxRelayPublishDate: Date?
  @StateObject private var conversationController = DirectConversationController()

  init(publicKey: String) {
    self.publicKey = publicKey

    let targetPublicKey = publicKey
    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == targetPublicKey }
    )
    descriptor.fetchLimit = 1
    _userProfiles = Query(descriptor)
  }

  init(userProfile: RUserProfile) {
    self.init(publicKey: userProfile.publicKey)
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        if messages.isEmpty {
          emptyState
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .padding(.horizontal, 24)
      } else if let currentUserPublicKey {
        VStack(spacing: 0) {
          olderMessagesLoader

          BubblesView(
            messages: messages,
            currentUserPublicKey: currentUserPublicKey,
            peerPublicKey: publicKey,
            peerAvatarURL: userProfile.avatarUrl,
            onNostrEventLinkTap: { reference in
              navigation.push(.event(reference: reference))
            }
          )
        }
      }
    }
      .scrollDismissesKeyboard(.interactively)

      composer
    }
    .navigationTitle(displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack(spacing: 8) {
          AvatarView(publicKey: publicKey, url: userProfile.avatarUrl, size: 30)
          Text(displayName)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
        }
      }

      ToolbarItem(placement: .navigationBarTrailing) {
        advertiseInboxButton
      }
    }
    .sheet(isPresented: $showKeyGenerator) {
      KeyGen(initialMode: .generate)
        .environmentObject(keyManager)
    }
    .onAppear {
      configureConversationController()
    }
    .task(id: conversationScopeID) {
      configureConversationController()
      syncInboxIfPossible()
    }
  }

  private var userProfile: RUserProfile {
    userProfiles.first ?? RUserProfile.createEmpty(withPublicKey: publicKey)
  }

  private var displayName: String {
    if userProfile.name.isValidName() {
      return userProfile.name
    }

    return (bech32_pubkey(publicKey) ?? publicKey).accordionString(index: 8)
  }

  private var currentUserPublicKey: String? {
    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else { return nil }
    return privkey_to_pubkey(privkey: privateKeyHex)
  }

  private var conversationScopeID: String {
    "\(currentUserPublicKey ?? "no-key"):\(publicKey)"
  }

  private var messages: [ChatMessage] {
    guard currentUserPublicKey != nil else { return [] }

    return conversationController.visibleItems
      .map {
        ChatMessage(
          id: $0.id,
          authorPublicKey: $0.senderPublicKey,
          content: $0.content,
          createdAt: $0.createdAt,
          deliveryState: deliveryState(from: $0),
          errorMessage: $0.errorMessage
        )
      }
  }

  @ViewBuilder
  private var olderMessagesLoader: some View {
    if conversationController.isLoadingOlder {
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    } else if conversationController.canLoadOlder {
      Button("Earlier Messages") {
        conversationController.loadOlder()
      }
      .font(.footnote.weight(.medium))
      .buttonStyle(.borderless)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    VStack(spacing: 14) {
      Image(systemName: "lock.shield")
        .font(.system(size: 42, weight: .regular))
        .foregroundColor(.secondary)

      Text("No Messages")
        .font(.title3.weight(.semibold))

      Text("Encrypted direct messages will appear here for the active key.")
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 280)

      Button(action: advertiseInboxRelays) {
        Label("Enable DMs", systemImage: "dot.radiowaves.left.and.right")
          .font(.body.weight(.semibold))
      }
      .buttonStyle(.bordered)
      .disabled(isAdvertisingInbox)
      .padding(.top, 4)
    }
  }

  @ViewBuilder
  private var advertiseInboxButton: some View {
    Button(action: advertiseInboxRelays) {
      if isAdvertisingInbox {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "dot.radiowaves.left.and.right")
      }
    }
    .disabled(isAdvertisingInbox)
    .accessibilityLabel("Enable DMs")
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let deliveryNotice {
        Label(deliveryNotice, systemImage: "info.circle")
          .font(.footnote)
          .foregroundColor(.secondary)
          .labelStyle(.titleAndIcon)
          .padding(.horizontal, 4)
      }

      HStack(alignment: .bottom, spacing: 10) {
        TextField("Message", text: $chatField, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...5)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(Color(.secondarySystemFill), in: Capsule(style: .continuous))

        Button(action: sendMessage) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 32, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.35)
        .accessibilityLabel("Send")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
    .animation(.easeInOut(duration: 0.18), value: deliveryNotice)
  }

  private var canSend: Bool {
    !trimmedMessage.isEmpty
  }

  private var trimmedMessage: String {
    chatField.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func sendMessage() {
    let content = trimmedMessage
    guard !content.isEmpty else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex,
      let currentUserPublicKey = privkey_to_pubkey(privkey: privateKeyHex)
    else {
      showKeyGenerator = true
      return
    }

    deliveryNotice = nil

    let message: MessagingPlaintextMessage
    do {
      message = try messagingService.buildDirectMessage(
        currentUserPublicKey: currentUserPublicKey,
        peerPublicKey: publicKey,
        content: content
      )
    } catch {
      deliveryNotice = (error as? MessagingError)?.userMessage
        ?? "Message could not be prepared."
      return
    }

    chatField = ""
    guard saveOptimisticMessage(message, currentUserPublicKey: currentUserPublicKey) else {
      deliveryNotice = "Message could not be saved on this device."
      return
    }

    publishInboxRelayListIfPossible(privateKeyHex: privateKeyHex)

    messagingService.send(
      MessagingSendRequest(
        message: message,
        senderPrivateKeyHex: privateKeyHex,
        relayURLs: activeRelayURLs()
      )
    ) { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let sendResult):
          updateMessage(
            rumorId: message.id,
            deliveryState: "sent",
            errorMessage: nil,
            wrapEventIds: sendResult.wrapEventIds
          )
        case .failure(let error):
          let sendFailure = error as? MessagingSendFailure
          let failureMessage = sendFailure?.userMessage
            ?? (error as? MessagingError)?.userMessage
            ?? "Message could not be sent."
          deliveryNotice = failureMessage
          updateMessage(
            rumorId: message.id,
            deliveryState: "failed",
            errorMessage: failureMessage,
            wrapEventIds: sendFailure?.wrapEventIds ?? []
          )
        }
      }
    }
  }

  private func activeRelayURLs() -> [URL] {
    NostrData.shared.storedRelays.ensureDefaultRelays()
    return NostrData.shared.storedRelays.activeRelayAddresses.compactMap { URL(string: $0) }
  }

  private func syncInboxIfPossible() {
    guard !isSyncingInbox,
      let privateKeyHex = keyManager.selectedPrivateKeyHex
    else {
      return
    }

    let relayURLs = activeRelayURLs()
    guard !relayURLs.isEmpty else { return }

    isSyncingInbox = true
    inboxSync.sync(
      recipientPrivateKeyHex: privateKeyHex,
      relayURLs: relayURLs,
      modelContainer: NostrData.shared.modelContainer
    ) { _ in
      isSyncingInbox = false
      configureConversationController()
      conversationController.refreshFromCache()
    }
  }

  private func deliveryState(from directMessage: DirectMessageItem) -> ChatMessageDeliveryState {
    switch directMessage.deliveryState {
    case "pending", "sending":
      return .pending
    case "failed":
      return .failed
    default:
      return .sent
    }
  }

  private func saveOptimisticMessage(
    _ message: MessagingPlaintextMessage,
    currentUserPublicKey: String
  ) -> Bool {
    if existingMessage(rumorId: message.id) != nil {
      return true
    }

    let directMessage = RDirectMessage(
      id: UUID().uuidString,
      rumorId: message.id,
      conversationID: RDirectMessage.conversationID(currentUserPublicKey, publicKey),
      peerPubkey: publicKey,
      senderPublicKey: currentUserPublicKey,
      recipientPublicKey: publicKey,
      content: message.content,
      createdAt: message.createdAt,
      isFromCurrentUser: true,
      deliveryState: "sending",
      errorMessage: nil,
      wrapEventIds: [],
      protocolKind: MessagingProtocolKind.nip17.rawValue
    )

    modelContext.insert(directMessage)

    do {
      try modelContext.save()
      conversationController.refreshFromCache()
      return true
    } catch {
      modelContext.delete(directMessage)
      return false
    }
  }

  private func updateMessage(
    rumorId: String,
    deliveryState: String,
    errorMessage: String?,
    wrapEventIds: [String]
  ) {
    guard let directMessage = existingMessage(rumorId: rumorId) else { return }

    directMessage.deliveryState = deliveryState
    directMessage.errorMessage = errorMessage
    directMessage.wrapEventIds = mergedWrapEventIds(directMessage.wrapEventIds, wrapEventIds)

    do {
      try modelContext.save()
      conversationController.refreshFromCache()
    } catch {
      deliveryNotice = "Message status could not be saved."
    }
  }

  private func existingMessage(rumorId: String) -> RDirectMessage? {
    var rumorDescriptor = FetchDescriptor<RDirectMessage>(
      predicate: #Predicate { $0.rumorId == rumorId }
    )
    rumorDescriptor.fetchLimit = 1

    if let message = try? modelContext.fetch(rumorDescriptor).first {
      return message
    }

    var legacyDescriptor = FetchDescriptor<RDirectMessage>(
      predicate: #Predicate { $0.id == rumorId }
    )
    legacyDescriptor.fetchLimit = 1

    return try? modelContext.fetch(legacyDescriptor).first
  }

  private func configureConversationController() {
    guard let currentUserPublicKey else {
      conversationController.reset()
      return
    }

    conversationController.configure(
      modelContainer: NostrData.shared.modelContainer,
      activePublicKey: currentUserPublicKey,
      peerPublicKey: publicKey
    )
  }

  private func mergedWrapEventIds(_ current: [String], _ incoming: [String]) -> [String] {
    var result = current

    for id in incoming where !id.isEmpty && !result.contains(id) {
      result.append(id)
    }

    return result
  }

  private func publishInboxRelayListIfPossible(
    privateKeyHex: String,
    relayURLs: [URL]? = nil
  ) {
    let relayURLs = relayURLs ?? activeRelayURLs()
    guard !relayURLs.isEmpty else { return }
    if let lastInboxRelayPublishDate,
      Date().timeIntervalSince(lastInboxRelayPublishDate) < 60
    {
      return
    }

    lastInboxRelayPublishDate = Date()
    messagingService.publishInboxRelayList(
      privateKeyHex: privateKeyHex,
      relayURLs: relayURLs
    ) { _ in }
  }

  private func advertiseInboxRelays() {
    guard !isAdvertisingInbox else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex,
      privkey_to_pubkey(privkey: privateKeyHex) != nil
    else {
      showKeyGenerator = true
      return
    }

    let relayURLs = activeRelayURLs()
    guard !relayURLs.isEmpty else {
      deliveryNotice = "Enable at least one relay before turning on DMs."
      return
    }

    isAdvertisingInbox = true
    deliveryNotice = "Publishing your DM relay list..."

    messagingService.publishInboxRelayList(
      privateKeyHex: privateKeyHex,
      relayURLs: relayURLs
    ) { result in
      DispatchQueue.main.async {
        isAdvertisingInbox = false

        switch result {
        case .success:
          lastInboxRelayPublishDate = Date()
          deliveryNotice = "DMs are ready on your active relays."
        case .failure(let error):
          deliveryNotice = (error as? MessagingError)?.userMessage
            ?? (error as? LocalizedError)?.errorDescription
            ?? "DM relay list could not be published."
        }
      }
    }
  }
}

struct ChatView_Previews: PreviewProvider {
  static var previews: some View {
    NavigationStack {
      ChatView(userProfile: RUserProfile.preview)
        .environmentObject(KeyManager())
    }
  }
}
