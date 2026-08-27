import NostrKit
import SwiftUI
import UIKit

struct ThreadView: View {
  private static let olderLoadThreshold: CGFloat = 180

  @EnvironmentObject private var nostrData: NostrData
  @EnvironmentObject private var keyManager: KeyManager

  @StateObject private var controller: ThreadController
  @State private var repository: NostrThreadRepository?
  @State private var draftText = ""
  @State private var isPosting = false
  @State private var publishError: String?
  @State private var failedEvent: PostEventContent?
  @State private var showKeyGenerator = false
  @State private var didTriggerOlderLoadForBottomEdge = false

  init(target: ThreadTarget) {
    _controller = StateObject(wrappedValue: ThreadController(target: target))
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        focusedSection

        Divider()

        repliesSection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 24)
    }
    .scrollDismissesKeyboard(.interactively)
    .onScrollGeometryChange(for: ThreadScrollState.self) { geometry in
      let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
      let bottomDistance = max(0, geometry.contentSize.height - visibleBottom)
      return ThreadScrollState(
        isNearBottom: bottomDistance <= Self.olderLoadThreshold,
        distanceBucket: Int(bottomDistance / 48)
      )
    } action: { _, state in
      updateOlderLoadProximity(isNearBottom: state.isNearBottom)
    }
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      replyComposer
    }
    .sheet(isPresented: $showKeyGenerator) {
      KeyGen(initialMode: .generate)
        .environmentObject(keyManager)
    }
    .onAppear {
      let repository = repository ?? NostrThreadRepository(nostrData: nostrData)
      self.repository = repository
      controller.start(repository: repository)
    }
    .onDisappear {
      controller.cancel()
      didTriggerOlderLoadForBottomEdge = false
    }
  }

  @ViewBuilder
  private var focusedSection: some View {
    if let focusedItem = controller.focusedItem {
      EventView(threadItem: focusedItem, layout: .threadFocus)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if controller.isLoadingFocusedItem {
      ThreadEventSkeleton(count: 1)
    } else if controller.target.focused.eventID == nil {
      externalTargetHeader
    } else {
      ContentUnavailableView(
        "Post Unavailable",
        systemImage: "exclamationmark.bubble",
        description: Text("This event was not returned by your active relays.")
      )
      .frame(maxWidth: .infinity)

      if controller.errorMessage != nil {
        Button("Try Again") {
          controller.retry()
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
      }
    }
  }

  @ViewBuilder
  private var repliesSection: some View {
    if controller.directReplies.isEmpty {
      if controller.isLoadingInitialReplies {
        ThreadEventSkeleton(count: 3)
      } else if activeRelayURLs.isEmpty {
        ContentUnavailableView(
          "No Active Relays",
          systemImage: "network.slash",
          description: Text("Enable a relay to load replies.")
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
      } else if controller.hasReachedReplyEnd {
        ContentUnavailableView(
          "No Replies",
          systemImage: "bubble.left",
          description: Text("Be the first to reply.")
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
      } else {
        VStack(spacing: 12) {
          ContentUnavailableView(
            "No Replies Found",
            systemImage: "bubble.left",
            description: Text("There may be older replies on your relays.")
          )

          Button("Load Older Replies") {
            controller.loadOlderReplies()
          }
          .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
      }
    } else {
      ForEach(controller.directReplies) { reply in
        EventView(threadItem: reply)
          .id(reply.id)
          .frame(maxWidth: .infinity, alignment: .leading)

        Divider()
      }

      if controller.isLoadingOlderReplies {
        ThreadEventSkeleton(count: 1)
      } else if let errorMessage = controller.errorMessage {
        VStack(spacing: 10) {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

          Button("Try Again") {
            controller.retry()
          }
          .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
      }
    }
  }

  private var externalTargetHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      Image(systemName: "link")
        .font(.title2)
        .foregroundStyle(.secondary)

      Text("Comments")
        .font(.headline)

      Text(controller.target.focused.parentQueryValue)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var replyComposer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let publishError {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(publishError)
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)

          if failedEvent != nil {
            Button("Retry") {
              retryFailedPublish()
            }
            .font(.caption.weight(.semibold))
          }
        }
      }

      HStack(alignment: .bottom, spacing: 10) {
        TextField(composerPlaceholder, text: $draftText, axis: .vertical)
          .textInputAutocapitalization(.sentences)
          .lineLimit(1...5)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(.thinMaterial, in: Capsule())

        Button {
          postReply()
        } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 30, weight: .semibold))
            .frame(width: 34, height: 34)
            .symbolEffect(.pulse, isActive: isPosting)
        }
        .buttonStyle(.plain)
        .foregroundStyle(canPost ? Color.accentColor : Color.secondary)
        .disabled(!canPost)
        .accessibilityLabel("Send Reply")
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .background(.bar)
  }

  private var navigationTitle: String {
    controller.target.focused.canonicalKey == controller.target.root.canonicalKey
      ? "Post"
      : "Reply"
  }

  private var composerPlaceholder: String {
    guard let name = controller.focusedItem?.publicKey else { return "Write a reply" }
    let display = bech32_pubkey(name)?.accordionString(index: 6)
      ?? name.accordionString(index: 6)
    return "Reply to \(display)"
  }

  private var trimmedDraftText: String {
    draftText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canPost: Bool {
    !trimmedDraftText.isEmpty && !isPosting
  }

  private var activeRelayURLs: [URL] {
    nostrData.storedRelays.activeRelayAddresses.compactMap(URL.init(string:))
  }

  private func updateOlderLoadProximity(isNearBottom: Bool) {
    guard !controller.directReplies.isEmpty else {
      didTriggerOlderLoadForBottomEdge = false
      return
    }

    if !isNearBottom {
      didTriggerOlderLoadForBottomEdge = false
      return
    }

    guard !didTriggerOlderLoadForBottomEdge else { return }
    didTriggerOlderLoadForBottomEdge = true
    controller.loadOlderReplies()
  }

  private func postReply() {
    guard canPost else { return }
    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else {
      showKeyGenerator = true
      return
    }
    guard !activeRelayURLs.isEmpty else {
      publishError = "Enable at least one relay before replying."
      return
    }
    guard let repository else { return }

    do {
      let keyPair = try KeyPair(privateKey: privateKeyHex)
      let strategy = ThreadProtocolStrategies.strategy(for: controller.target)
      let draft = try strategy.makeReplyDraft(
        content: trimmedDraftText,
        target: controller.target,
        parseProfileMentions: true
      )
      let event = try PostEventContent(keyPair: keyPair, draft: draft)
      let fallbackEvent: PostEventContent?

      if draft.nips.contains(.nip27) {
        let fallbackDraft = try strategy.makeReplyDraft(
          content: trimmedDraftText,
          target: controller.target,
          parseProfileMentions: false
        )
        fallbackEvent = try PostEventContent(keyPair: keyPair, draft: fallbackDraft)
      } else {
        fallbackEvent = nil
      }

      guard let optimisticItem = ThreadItem(event: event.event) else {
        throw ThreadProtocolValidationError.unsupportedTarget
      }

      controller.registerPublishedReply(optimisticItem)
      isPosting = true
      publishError = nil
      failedEvent = nil
      draftText = ""
      publish(
        event,
        fallbackEvent: fallbackEvent,
        optimisticEventID: optimisticItem.id,
        repository: repository
      )
    } catch {
      publishError = shortErrorMessage(error)
    }
  }

  private func retryFailedPublish() {
    guard let failedEvent, let repository, !activeRelayURLs.isEmpty else { return }
    isPosting = true
    publishError = nil
    self.failedEvent = nil
    publish(
      failedEvent,
      fallbackEvent: nil,
      optimisticEventID: failedEvent.event.id,
      repository: repository
    )
  }

  private func publish(
    _ event: PostEventContent,
    fallbackEvent: PostEventContent?,
    optimisticEventID: String,
    repository: NostrThreadRepository
  ) {
    let relayURLs = activeRelayURLs
    var completedCount = 0
    var failedCount = 0
    var didPersist = false
    var firstFailure: String?

    for relayURL in relayURLs {
      event.sendToNostr(relayUrl: relayURL) { result in
        DispatchQueue.main.async {
          completedCount += 1
          switch result {
          case .success:
            if !didPersist {
              didPersist = repository.persistPublishedEvent(event.event) != nil
            }
          case .failure(let error):
            failedCount += 1
            firstFailure = firstFailure ?? shortErrorMessage(error)
          }

          guard completedCount == relayURLs.count else { return }

          if failedCount == relayURLs.count, let fallbackEvent,
            let fallbackItem = ThreadItem(event: fallbackEvent.event)
          {
            controller.replacePublishedReply(eventID: optimisticEventID, with: fallbackItem)
            publish(
              fallbackEvent,
              fallbackEvent: nil,
              optimisticEventID: fallbackItem.id,
              repository: repository
            )
            return
          }

          isPosting = false
          if failedCount == relayURLs.count {
            failedEvent = event
            publishError = firstFailure ?? "No relay accepted this reply."
          } else if !didPersist {
            publishError = "Reply sent, but it could not be cached on this device."
          } else {
            publishError = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
          }
        }
      }
    }
  }

  private func shortErrorMessage(_ error: Error) -> String {
    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return "Could not send reply." }
    guard message.count > 160 else { return message }
    return "\(message.prefix(160))..."
  }
}

private struct ThreadScrollState: Equatable {
  let isNearBottom: Bool
  let distanceBucket: Int
}

private struct ThreadEventSkeleton: View {
  let count: Int

  var body: some View {
    ForEach(0..<count, id: \.self) { _ in
      HStack(alignment: .top, spacing: 12) {
        Circle()
          .fill(Color.secondary.opacity(0.18))
          .frame(width: 44, height: 44)

        VStack(alignment: .leading, spacing: 10) {
          Capsule()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 132, height: 14)

          Capsule()
            .fill(Color.secondary.opacity(0.14))
            .frame(maxWidth: .infinity, minHeight: 13, maxHeight: 13)

          Capsule()
            .fill(Color.secondary.opacity(0.12))
            .frame(maxWidth: 230, minHeight: 13, maxHeight: 13)
        }
      }
      .redacted(reason: .placeholder)

      Divider()
    }
  }
}
