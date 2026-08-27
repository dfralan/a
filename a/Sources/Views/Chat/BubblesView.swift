// a

import SwiftData
import SwiftUI

enum ChatMessageDeliveryState: Equatable {
  case pending
  case sent
  case failed

  var systemImage: String {
    switch self {
    case .pending: return "clock"
    case .sent: return "checkmark"
    case .failed: return "exclamationmark.circle"
    }
  }

  var inlineSystemImage: String? {
    switch self {
    case .pending: return "clock"
    case .sent: return "checkmark"
    case .failed: return nil
    }
  }
}

struct ChatMessage: Identifiable, Hashable {
  let id: String
  let authorPublicKey: String
  let content: String
  let createdAt: Date
  let deliveryState: ChatMessageDeliveryState
  let errorMessage: String?

  init(
    id: String,
    authorPublicKey: String,
    content: String,
    createdAt: Date,
    deliveryState: ChatMessageDeliveryState = .sent,
    errorMessage: String? = nil
  ) {
    self.id = id
    self.authorPublicKey = authorPublicKey
    self.content = content
    self.createdAt = createdAt
    self.deliveryState = deliveryState
    self.errorMessage = errorMessage
  }
}

struct BubblesView: View {
  let messages: [ChatMessage]
  let currentUserPublicKey: String
  let peerPublicKey: String
  let peerAvatarURL: URL?
  let onNostrEventLinkTap: (NostrEventReference) -> Void

  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var nostrData: NostrData
  @State private var postPreviewsByEventID: [String: ChatPostPreview] = [:]
  @State private var requestedPreviewIDs = Set<String>()

  var body: some View {
    LazyVStack(spacing: 4) {
      ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
        let isFromCurrentUser = message.authorPublicKey == currentUserPublicKey
        let postPreview = postPreview(for: message)

        VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 3) {
          HStack(alignment: .bottom, spacing: 8) {
            if isFromCurrentUser {
              Spacer(minLength: 44)
            } else {
              peerAvatar(at: index)
            }

            ChatBubble(
              message: message,
              isFromCurrentUser: isFromCurrentUser,
              isFirstInGroup: isFirstInGroup(at: index),
              isLastInGroup: isLastInGroup(at: index),
              postPreview: postPreview,
              onNostrEventLinkTap: onNostrEventLinkTap
            )

            if isFromCurrentUser, message.deliveryState == .failed {
              failedDeliveryIcon(for: message)
            }

            if !isFromCurrentUser {
              Spacer(minLength: 44)
            }
          }

          if isFromCurrentUser {
            deliveryErrorText(for: message)
          }
        }
        .padding(.bottom, isLastInGroup(at: index) ? 8 : 0)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .task(id: previewRequestSignature) {
      await prefetchMissingPostPreviews()
    }
  }

  @ViewBuilder
  private func peerAvatar(at index: Int) -> some View {
    if isLastInGroup(at: index) {
      AvatarView(publicKey: peerPublicKey, url: peerAvatarURL, size: 30)
        .offset(y: 4)
    } else {
      Color.clear
        .frame(width: 30, height: 30)
    }
  }

  @ViewBuilder
  private func failedDeliveryIcon(for message: ChatMessage) -> some View {
    Image(systemName: message.deliveryState.systemImage)
      .font(.system(size: 22, weight: .semibold))
      .foregroundColor(Color(.systemRed))
      .frame(width: 26, height: 26)
      .padding(.bottom, 7)
      .accessibilityLabel("Message not delivered")
  }

  @ViewBuilder
  private func deliveryErrorText(for message: ChatMessage) -> some View {
    if message.deliveryState == .failed {
      Text(message.errorMessage ?? "Message could not be sent.")
        .font(.caption.weight(.semibold))
        .foregroundColor(Color(.systemRed))
        .lineLimit(2)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 280, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 34)
        .accessibilityLabel("Message not delivered. \(message.errorMessage ?? "Message could not be sent.")")
    }
  }

  private func isFirstInGroup(at index: Int) -> Bool {
    guard index > 0 else { return true }
    return messages[index].authorPublicKey != messages[index - 1].authorPublicKey
  }

  private func isLastInGroup(at index: Int) -> Bool {
    guard index < messages.count - 1 else { return true }
    return messages[index].authorPublicKey != messages[index + 1].authorPublicKey
  }

  private func postPreview(for message: ChatMessage) -> ChatPostPreview? {
    guard let reference = ChatNostrEventLinks.firstReference(in: message.content) else {
      return nil
    }

    return postPreviewsByEventID[reference.id] ?? ChatPostPreview.unresolved(reference: reference)
  }

  private func postPreview(for item: FeedItem, reference: NostrEventReference) -> ChatPostPreview {
    let profile = profile(for: item.pubkey)
    return ChatPostPreview(
      reference: reference,
      authorPublicKey: item.pubkey,
      authorDisplayName: displayName(for: item.pubkey, profile: profile),
      excerpt: excerpt(from: item.content),
      linkText: reference.canonicalLink,
      isResolved: true
    )
  }

  private func profile(for publicKey: String) -> RUserProfile? {
    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == publicKey }
    )
    descriptor.fetchLimit = 1
    return try? modelContext.fetch(descriptor).first
  }

  private var previewRequestSignature: String {
    messages
      .compactMap { ChatNostrEventLinks.firstReference(in: $0.content)?.id }
      .joined(separator: "|")
  }

  @MainActor
  private func prefetchMissingPostPreviews() async {
    var references: [NostrEventReference] = []
    var seenIDs = Set<String>()

    for message in messages {
      guard let reference = ChatNostrEventLinks.firstReference(in: message.content),
        seenIDs.insert(reference.id).inserted
      else {
        continue
      }

      references.append(reference)
    }

    for reference in references.prefix(6) {
      guard !requestedPreviewIDs.contains(reference.id),
        postPreviewsByEventID[reference.id] == nil
      else {
        continue
      }

      requestedPreviewIDs.insert(reference.id)

      if let cachedItem = nostrData.cachedTextNoteEvent(eventID: reference.id) {
        postPreviewsByEventID[reference.id] = postPreview(for: cachedItem, reference: reference)
        continue
      }

      if let remoteItem = await nostrData.fetchTextNoteEvent(reference: reference) {
        postPreviewsByEventID[reference.id] = postPreview(for: remoteItem, reference: reference)
      }
    }
  }

  private func displayName(for publicKey: String, profile: RUserProfile?) -> String {
    if let name = profile?.name, name.isValidName() {
      return name
    }

    return (bech32_pubkey(publicKey) ?? publicKey).accordionString(index: 8)
  }

  private func excerpt(from content: String) -> String {
    let trimmed = content
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n\n", with: "\n")

    guard trimmed.count > 140 else { return trimmed }
    return "\(trimmed.prefix(140))..."
  }
}

private struct ChatPostPreview: Hashable {
  let reference: NostrEventReference
  let authorPublicKey: String
  let authorDisplayName: String
  let excerpt: String
  let linkText: String
  let isResolved: Bool

  static func unresolved(reference: NostrEventReference) -> ChatPostPreview {
    ChatPostPreview(
      reference: reference,
      authorPublicKey: "",
      authorDisplayName: "Post Preview",
      excerpt: "Tap to open this post.",
      linkText: reference.canonicalLink,
      isResolved: false
    )
  }
}

private struct ChatBubble: View {
  let message: ChatMessage
  let isFromCurrentUser: Bool
  let isFirstInGroup: Bool
  let isLastInGroup: Bool
  let postPreview: ChatPostPreview?
  let onNostrEventLinkTap: (NostrEventReference) -> Void

  var body: some View {
    VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 4) {
      if !shouldHideMessageText {
        Text(
          ChatNostrEventLinks.attributedContent(
            message.content,
            linkColor: isFromCurrentUser ? .white : .accentColor
          )
        )
          .font(.body)
          .foregroundColor(isFromCurrentUser ? .white : .primary)
          .textSelection(.enabled)
          .environment(\.openURL, OpenURLAction { url in
            guard let reference = NostrEventReference(url: url) else {
              return .systemAction
            }

            onNostrEventLinkTap(reference)
            return .handled
          })
      }

      if let postPreview {
        ChatPostPreviewCard(
          preview: postPreview,
          isFromCurrentUser: isFromCurrentUser,
          action: {
            onNostrEventLinkTap(postPreview.reference)
          }
        )
      }

      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(Self.timeFormatter.string(from: message.createdAt))
          .font(.caption2)

        if isFromCurrentUser, let inlineSystemImage = message.deliveryState.inlineSystemImage {
          Image(systemName: inlineSystemImage)
            .font(.caption2.weight(.semibold))
        }
      }
      .foregroundColor(isFromCurrentUser ? .white.opacity(0.7) : .secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(bubbleColor, in: bubbleShape)
    .frame(maxWidth: 280, alignment: isFromCurrentUser ? .trailing : .leading)
    .accessibilityElement(children: .combine)
  }

  private var bubbleColor: Color {
    isFromCurrentUser ? .accentColor : Color(.secondarySystemFill)
  }

  private var shouldHideMessageText: Bool {
    postPreview != nil && ChatNostrEventLinks.isOnlyEventLink(message.content)
  }

  private var bubbleShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      topLeadingRadius: isFromCurrentUser || isFirstInGroup ? 18 : 8,
      bottomLeadingRadius: isFromCurrentUser || isLastInGroup ? 18 : 8,
      bottomTrailingRadius: isFromCurrentUser && !isLastInGroup ? 8 : 18,
      topTrailingRadius: !isFromCurrentUser || isFirstInGroup ? 18 : 8,
      style: .continuous
    )
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()
}

private struct ChatPostPreviewCard: View {
  let preview: ChatPostPreview
  let isFromCurrentUser: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 7) {
          Image(systemName: "paperplane")
            .font(.caption.weight(.semibold))

          Text("Shared Post")
            .font(.caption.weight(.semibold))
        }
        .foregroundColor(secondaryTextColor)

        Text(preview.authorDisplayName)
          .font(.caption.weight(.semibold))
          .foregroundColor(primaryTextColor)
          .lineLimit(1)

        if preview.isResolved && !preview.excerpt.isEmpty {
          Text(preview.excerpt)
            .font(.subheadline)
            .foregroundColor(primaryTextColor)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
        } else if !preview.isResolved {
          Text(preview.excerpt)
            .font(.subheadline)
            .foregroundColor(secondaryTextColor)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        }

        Text(preview.linkText)
          .font(.caption2.monospaced())
          .foregroundColor(secondaryTextColor)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open shared post")
  }

  private var cardBackground: Color {
    isFromCurrentUser ? Color.white.opacity(0.18) : Color(.tertiarySystemFill)
  }

  private var primaryTextColor: Color {
    isFromCurrentUser ? .white : .primary
  }

  private var secondaryTextColor: Color {
    isFromCurrentUser ? .white.opacity(0.72) : .secondary
  }
}

private enum ChatNostrEventLinks {
  private static let bech32Characters = "023456789acdefghjklmnpqrstuvwxyz"

  static func attributedContent(
    _ content: String,
    linkColor: Color
  ) -> AttributedString {
    var attributed = AttributedString(content)

    for match in matches(in: content) {
      guard let lowerBound = AttributedString.Index(match.range.lowerBound, within: attributed),
        let upperBound = AttributedString.Index(match.range.upperBound, within: attributed),
        let url = match.url
      else {
        continue
      }

      let attributedRange = lowerBound..<upperBound
      attributed[attributedRange].font = .body.weight(.semibold)
      attributed[attributedRange].foregroundColor = linkColor
      attributed[attributedRange].link = url
    }

    return attributed
  }

  static func firstReference(in content: String) -> NostrEventReference? {
    matches(in: content).first?.reference
  }

  static func isOnlyEventLink(_ content: String) -> Bool {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let match = matches(in: trimmed).first,
      match.range.lowerBound == trimmed.startIndex,
      match.range.upperBound == trimmed.endIndex
    else {
      return false
    }

    return true
  }

  private static func matches(in content: String) -> [NostrEventLinkMatch] {
    let pattern = "(?<![A-Za-z0-9_/:])(?:nostr:)?((?:note|nevent)1[\(bech32Characters)]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return []
    }

    let source = content as NSString
    return regex
      .matches(in: content, range: NSRange(location: 0, length: source.length))
      .compactMap { result in
        guard let range = Range(result.range, in: content) else { return nil }

        let rawText = String(content[range])
        guard let reference = NostrEventReference(rawValue: rawText) else {
          return nil
        }

        let normalizedLink = rawText.lowercased().hasPrefix("nostr:")
          ? rawText
          : "nostr:\(rawText)"
        let url = URL(string: normalizedLink) ?? reference.url

        return NostrEventLinkMatch(range: range, reference: reference, url: url)
      }
  }

  private struct NostrEventLinkMatch {
    let range: Range<String.Index>
    let reference: NostrEventReference
    let url: URL?
  }
}
