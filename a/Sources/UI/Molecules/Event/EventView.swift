// a

import AVKit
import Kingfisher
import NostrKit
import SDWebImageSwiftUI
import SwiftData
import SwiftUI
import UIKit

// MARK: - Event View

struct EventViewModel: Identifiable, Hashable {
  let id: String
  let pubkey: String
  let createdAt: Date
  let content: String
  let kind: Int
  let isSensitiveContent: Bool
  let sensitiveContentReason: String
  let profileName: String?
  let profileAvatarURL: URL?
  let repost: FeedRepost?
  let threadTarget: ThreadTarget

  init(
    id: String,
    pubkey: String,
    createdAt: Date,
    content: String,
    kind: Int = 1,
    isSensitiveContent: Bool,
    sensitiveContentReason: String,
    profileName: String? = nil,
    profileAvatarURL: URL? = nil,
    repost: FeedRepost? = nil,
    threadTarget: ThreadTarget? = nil
  ) {
    self.id = id
    self.pubkey = pubkey
    self.createdAt = createdAt
    self.content = content
    self.kind = kind
    self.isSensitiveContent = isSensitiveContent
    self.sensitiveContentReason = sensitiveContentReason
    self.profileName = profileName
    self.profileAvatarURL = profileAvatarURL
    self.repost = repost
    let reference = ThreadReference.event(
      id: id,
      kind: kind,
      publicKey: pubkey,
      relayHints: []
    )
    self.threadTarget = threadTarget ?? ThreadTarget(focused: reference)
  }

  init(textNote: RTextNote) {
    self.init(
      id: textNote.eventId,
      pubkey: textNote.publicKey,
      createdAt: textNote.createdAt,
      content: textNote.content,
      kind: 1,
      isSensitiveContent: textNote.isSensitiveContent,
      sensitiveContentReason: textNote.sensitiveContentReason,
      profileName: textNote.userProfile?.name,
      profileAvatarURL: textNote.userProfile?.avatarUrl
    )
  }

  init(feedItem: FeedItem) {
    self.init(
      id: feedItem.eventId,
      pubkey: feedItem.pubkey,
      createdAt: feedItem.eventCreatedAt,
      content: feedItem.content,
      kind: 1,
      isSensitiveContent: feedItem.isSensitiveContent,
      sensitiveContentReason: feedItem.sensitiveContentReason,
      repost: feedItem.repost
    )
  }

  init(threadItem: ThreadItem) {
    self.init(
      id: threadItem.id,
      pubkey: threadItem.publicKey,
      createdAt: threadItem.createdAt,
      content: threadItem.content,
      kind: threadItem.kind,
      isSensitiveContent: threadItem.isSensitiveContent,
      sensitiveContentReason: threadItem.sensitiveContentReason,
      threadTarget: threadItem.target
    )
  }

  var sensitiveContentLabel: String {
    let trimmedReason = sensitiveContentReason.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedReason.isEmpty ? "Sensitive content" : trimmedReason
  }
}

enum EventViewLayout {
  case standard
  case threadFocus
}

struct FeedProfileSnapshot: Hashable {
  let name: String
  let avatarURL: URL?
  let isNIP05Verified: Bool

  init(profile: RUserProfile) {
    self.name = profile.name
    self.avatarURL = profile.avatarUrl
    self.isNIP05Verified = profile.verifiedNIP05 != nil
  }
}

struct FeedEventSupplement: Hashable {
  let authorProfile: FeedProfileSnapshot?
  let reposterProfile: FeedProfileSnapshot?
  let likeCount: Int
  let commentCount: Int
  let repostCount: Int
  let isLikedBySelectedKey: Bool
  let isRepostedBySelectedKey: Bool
}

struct FeedEventView: View {
  private static let mediaAspectRatio: CGFloat = 4 / 3
  private static let mediaCornerRadius: CGFloat = 14
  private static let collapsedContentCharacterLimit = 360

  @EnvironmentObject private var nostrData: NostrData
  @EnvironmentObject private var navigation: AppNavigation
  @EnvironmentObject private var keyManager: KeyManager
  @EnvironmentObject private var coordinator: Coordinator
  @Environment(\.modelContext) private var modelContext

  let event: EventViewModel
  let supplement: FeedEventSupplement?
  var onInteractionRequiresKey: (() -> Void)?
  private let presentation: EventPresentationModel

  @State private var showReportReasonDialog = false
  @State private var showKeyGenerator = false
  @State private var showShareSheet = false
  @State private var isPublishingReport = false
  @State private var isPublishingReaction = false
  @State private var isPublishingRepost = false
  @State private var pendingReactionEventID: String?
  @State private var pendingRepostEventID: String?
  @State private var isBlurred = true
  @State private var fullscreenMediaItem: EventFullscreenMediaItem?
  @State private var loadedAttachmentURLs = Set<String>()
  @State private var isContentExpanded = false

  init(
    feedItem: FeedItem,
    supplement: FeedEventSupplement? = nil,
    onInteractionRequiresKey: (() -> Void)? = nil
  ) {
    self.event = EventViewModel(feedItem: feedItem)
    self.supplement = supplement
    self.onInteractionRequiresKey = onInteractionRequiresKey
    self.presentation = EventRenderCache.shared.rendered(for: event)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      repostLegend

      HStack(alignment: .top, spacing: 6) {
        avatarButton

        VStack(alignment: .leading, spacing: 8) {
          authorHeader
          eventContentAndActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 2)
    .onAppear {
      resetBlurState()
    }
    .onChange(of: coordinator.blurredImages) { _, _ in
      resetBlurState()
    }
    .onChange(of: coordinator.blurSensitiveMedia) { _, _ in
      resetBlurState()
    }
    .fullScreenCover(item: $fullscreenMediaItem) { mediaItem in
      EventFullscreenMediaViewer(item: mediaItem) {
        fullscreenMediaItem = nil
      }
    }
    .confirmationDialog(
      "Report Post",
      isPresented: $showReportReasonDialog,
      titleVisibility: .visible
    ) {
      Button(sensitiveReportTitle, role: .destructive) {
        publishReport(
          type: .other,
          note: sensitiveReportNote
        )
      }
      Button(NIP56.ReportType.spam.title, role: .destructive) {
        publishReport(type: .spam)
      }
      Button(NIP56.ReportType.illegal.title, role: .destructive) {
        publishReport(type: .illegal)
      }
      Button(NIP56.ReportType.malware.title, role: .destructive) {
        publishReport(type: .malware)
      }
      Button(NIP56.ReportType.impersonation.title, role: .destructive) {
        publishReport(type: .impersonation)
      }
      Button(NIP56.ReportType.profanity.title, role: .destructive) {
        publishReport(type: .profanity)
      }
      Button(NIP56.ReportType.other.title, role: .destructive) {
        publishReport(type: .other)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Reports are sent to your active relays as a NIP-56 event.")
    }
    .sheet(isPresented: $showKeyGenerator) {
      KeyGen(initialMode: .generate)
        .environmentObject(keyManager)
    }
    .sheet(isPresented: $showShareSheet) {
      EventShareSheet(
        event: event,
        authorDisplayName: displayName,
        onOpenChat: { publicKey in
          navigation.push(.chat(publicKey: publicKey))
        }
      )
      .environmentObject(keyManager)
    }
  }

  private var avatarButton: some View {
    Button(action: navigateToProfile) {
      ZStack {
        Circle()
          .fill(Color.primary.opacity(0.001))

        AvatarView(publicKey: event.pubkey, url: profileAvatarURL, size: 44)
          .allowsHitTesting(false)
      }
      .frame(width: 48, height: 48)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Profile")
  }

  private var authorHeader: some View {
    HStack(alignment: .top, spacing: 8) {
      Button(action: navigateToProfile) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(displayName)
              .font(.subheadline.weight(.semibold))
              .foregroundColor(.primary)
              .lineLimit(1)

            if isAuthorNIP05Verified {
              Image(systemName: "checkmark.seal.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityLabel("Verified NIP-05")
            }

            Text(Self.publicationTimeLabel(for: event.createdAt))
              .font(.subheadline)
              .foregroundColor(.secondary)
              .monospacedDigit()
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .accessibilityLabel(Self.fullPublicationDateFormatter.string(from: event.createdAt))
          }

          Text(authorPublicKeyLabel)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Spacer(minLength: 8)
      eventActionsMenu
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var repostLegend: some View {
    if event.repost != nil {
      HStack(alignment: .center, spacing: 6) {
        AvatarView(publicKey: event.repost?.publicKey ?? "", url: reposterAvatarURL, size: 18)

        HStack(alignment: .center, spacing: 5) {
          HStack(alignment: .center, spacing: 2) {
            Text(reposterDisplayName)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)

            if isReposterNIP05Verified {
              Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityLabel("Verified NIP-05")
            }
          }

          Text("reposted this")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(.leading, 60)
      .accessibilityLabel("\(reposterDisplayName) reposted this")
    }
  }

  @ViewBuilder
  private var eventContentAndActions: some View {
    if let content = presentation.contentWithoutImageLinks ?? presentation.contentFormatted,
      !content.characters.isEmpty
    {
      contentView(for: content)
    }

    mediaContent
    eventFooter
  }

  private var authorPublicKeyLabel: String {
    (bech32_pubkey(event.pubkey) ?? event.pubkey).accordionString(index: 10)
  }

  private var profileAvatarURL: URL? {
    supplement?.authorProfile?.avatarURL ?? event.profileAvatarURL
  }

  private var displayName: String {
    let name = supplement?.authorProfile?.name ?? event.profileName ?? ""
    return name.isValidName() ? name : "Anonymous"
  }

  private var isAuthorNIP05Verified: Bool {
    supplement?.authorProfile?.isNIP05Verified ?? false
  }

  private var reposterAvatarURL: URL? {
    supplement?.reposterProfile?.avatarURL
  }

  private var reposterDisplayName: String {
    let name = supplement?.reposterProfile?.name ?? ""
    if name.isValidName() {
      return name
    }

    guard let publicKey = event.repost?.publicKey else {
      return "Someone"
    }

    return bech32_pubkey(publicKey)?.accordionString(index: 8)
      ?? publicKey.accordionString(index: 8)
  }

  private var isReposterNIP05Verified: Bool {
    supplement?.reposterProfile?.isNIP05Verified ?? false
  }

  private var selectedPublicKeyHex: String? {
    if let privateKeyHex = keyManager.selectedPrivateKeyHex {
      return privkey_to_pubkey(privkey: privateKeyHex)
    }

    guard case .pub(let publicKeyHex) = decode_bech32_key(keyManager.selectedKey) else {
      return nil
    }

    return publicKeyHex
  }

  private var isLiked: Bool {
    supplement?.isLikedBySelectedKey ?? false
  }

  private var isVisuallyLiked: Bool {
    isLiked || pendingReactionEventID != nil
  }

  private var isReposted: Bool {
    supplement?.isRepostedBySelectedKey ?? false
  }

  private var isVisuallyReposted: Bool {
    isReposted || pendingRepostEventID != nil
  }

  private var isRepostHighlighted: Bool {
    (supplement?.repostCount ?? 0) > 0 || isVisuallyReposted
  }

  private var likeCount: Int {
    let baseCount = supplement?.likeCount ?? 0
    guard pendingReactionEventID != nil,
      selectedPublicKeyHex != nil,
      !isLiked
    else {
      return baseCount
    }

    return baseCount + 1
  }

  private var commentCount: Int {
    supplement?.commentCount ?? 0
  }

  private func navigateToProfile() {
    navigation.push(.profile(publicKey: event.pubkey))
  }

  @ViewBuilder
  private var eventFooter: some View {
    HStack(spacing: 10) {
      reactionControl
      commentControl
      repostControl
      shareControl
    }
    .padding(.top, 6)
  }

  @ViewBuilder
  private var reactionControl: some View {
    Button {
      publishLike()
    } label: {
      LikeControlLabel(
        isLiked: isVisuallyLiked,
        isPublishing: isPublishingReaction,
        count: likeCount
      )
    }
    .buttonStyle(.plain)
    .disabled(isPublishingReaction)
    .accessibilityLabel(isVisuallyLiked ? "Liked" : "Like")
    .accessibilityValue("\(likeCount) likes")
  }

  @ViewBuilder
  private var commentControl: some View {
    Button {
      navigation.push(.thread(target: event.threadTarget))
    } label: {
      EventCountIconLabel(
        systemImage: "bubble.left",
        activeSystemImage: "bubble.left",
        count: commentCount,
        isActive: commentCount > 0,
        activeColor: .primary
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Comments")
    .accessibilityValue("\(commentCount) comments")
  }

  @ViewBuilder
  private var repostControl: some View {
    Button {
      publishRepost()
    } label: {
      Image(systemName: "arrow.2.squarepath")
        .font(.system(size: 17, weight: isRepostHighlighted ? .semibold : .regular))
        .foregroundStyle(isRepostHighlighted ? Color.primary : Color.secondary)
        .frame(width: 36, height: 36, alignment: .center)
        .scaleEffect(isPublishingRepost ? 1.08 : 1)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isPublishingRepost)
    .accessibilityLabel(isVisuallyReposted ? "Reposted" : "Repost")
  }

  @ViewBuilder
  private var shareControl: some View {
    Button(action: openShareSheet) {
      Image(systemName: "paperplane")
        .font(.system(size: 17, weight: .regular))
        .foregroundColor(.secondary)
        .frame(width: 36, height: 36, alignment: .center)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Share")
  }

  @ViewBuilder
  private var eventActionsMenu: some View {
    Menu {
      Button {
        navigateToProfile()
      } label: {
        Label("Open Profile", systemImage: "person.crop.circle")
      }

      Button {
        copyEventContent()
      } label: {
        Label("Copy Content", systemImage: "doc.on.doc")
      }

      Button {
        copyEventID()
      } label: {
        Label("Copy Event ID", systemImage: "number")
      }

      Button {
        copyUserPublicKey()
      } label: {
        Label("Copy npub", systemImage: "key.horizontal")
      }

      Button {
        copyProfileURL()
      } label: {
        Label("Copy Profile Link", systemImage: "link")
      }

      Button {
        navigation.push(.qr(publicKey: event.pubkey))
      } label: {
        Label("QR Code", systemImage: "qrcode")
      }

      Divider()

      Button(role: .destructive) {
        showReportReasonDialog = true
      } label: {
        Label("Report", systemImage: "exclamationmark.bubble")
      }
    } label: {
      Group {
        if isPublishingReport {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "ellipsis")
            .font(.system(size: 17, weight: .semibold))
        }
      }
      .foregroundColor(.secondary)
      .frame(width: 32, height: 32)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(isPublishingReport)
    .accessibilityLabel("More")
  }

  @ViewBuilder
  private var mediaContent: some View {
    if let linkPreview = presentation.linkPreview {
      LinkPreviewCard(descriptor: linkPreview)
    }

    if let videoUrl = presentation.videoUrl {
      if shouldLoadAttachment(videoUrl) {
        let mediaItem = EventFullscreenMediaItem.video(url: videoUrl)

        mediaContainer {
          EventVideoAttachment(url: videoUrl) {
            openFullscreenMedia(mediaItem)
          }
        }
        .gesture(mediaTapGesture(for: mediaItem))
        .accessibilityAction {
          openFullscreenMedia(mediaItem)
        }
      } else {
        attachmentPlaceholder(for: [videoUrl], includesVideo: true)
      }
    } else {
      let imageUrls = presentation.imageUrls

      if imageUrls.count > 1 {
        if imageUrls.allSatisfy(shouldLoadAttachment) {
          TabView {
            ForEach(Array(imageUrls.enumerated()), id: \.offset) { _, imageUrl in
              imageView(for: imageUrl)
                .padding(.vertical, 2)
            }
          }
          .tabViewStyle(.page(indexDisplayMode: .automatic))
          .aspectRatio(Self.mediaAspectRatio, contentMode: .fit)
        } else {
          attachmentPlaceholder(for: imageUrls)
        }
      } else if let imageUrl = imageUrls.first {
        if shouldLoadAttachment(imageUrl) {
          imageView(for: imageUrl)
        } else {
          attachmentPlaceholder(for: [imageUrl])
        }
      }
    }
  }

  @ViewBuilder
  private func contentView(for content: AttributedString) -> some View {
    let displayContent = collapsedContent(for: content)
    let canToggleExpansion = content.characters.count > Self.collapsedContentCharacterLimit

    VStack(alignment: .leading, spacing: 6) {
      Text(displayContent)
        .font(.body)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      if canToggleExpansion {
        Button {
          withAnimation(.easeOut(duration: 0.16)) {
            isContentExpanded.toggle()
          }
        } label: {
          Text(isContentExpanded ? "Show Less" : "Read More")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isContentExpanded ? "Collapse post" : "Read full post")
      }
    }
    .padding(.top, 2)
    .environment(\.openURL, OpenURLAction { url in
      if let publicKey = NostrInlineText.profilePublicKey(from: url) {
        navigation.push(.profile(publicKey: publicKey))
        return .handled
      }

      return .systemAction
    })
  }

  private func collapsedContent(for content: AttributedString) -> AttributedString {
    let characterCount = content.characters.count
    guard !isContentExpanded,
      characterCount > Self.collapsedContentCharacterLimit
    else {
      return content
    }

    let plainText = String(content.characters)
    let cutoffIndex = collapsedContentCutoffIndex(in: plainText)
    guard let attributedCutoff = AttributedString.Index(cutoffIndex, within: content) else {
      return content
    }

    var excerpt = AttributedString(content[..<attributedCutoff])
    excerpt.append(AttributedString("…"))
    return excerpt
  }

  private func collapsedContentCutoffIndex(in text: String) -> String.Index {
    let hardLimit = text.index(
      text.startIndex,
      offsetBy: Self.collapsedContentCharacterLimit,
      limitedBy: text.endIndex
    ) ?? text.endIndex
    let softWindowStart = text.index(
      hardLimit,
      offsetBy: -70,
      limitedBy: text.startIndex
    ) ?? text.startIndex
    let searchRange = softWindowStart..<hardLimit

    if let newlineIndex = text[searchRange].lastIndex(where: \.isNewline) {
      return newlineIndex
    }
    if let whitespaceIndex = text[searchRange].lastIndex(where: \.isWhitespace) {
      return whitespaceIndex
    }

    return hardLimit
  }

  @ViewBuilder
  private func imageView(for imageUrl: URL) -> some View {
    let mediaItem = EventFullscreenMediaItem.image(url: imageUrl)

    mediaContainer {
      switch imageUrl.pathExtension.lowercased() {
      case "gif", "webp", "svg":
        AnimatedImage(url: imageUrl)
          .placeholder {
            EventMediaSkeleton()
          }
          .resizable()
          .aspectRatio(contentMode: .fill)
          .blur(radius: isBlurred ? 40 : 0)
          .overlay {
            sensitiveWarningOverlay
          }

      default:
        KFImage(imageUrl)
          .placeholder {
            EventMediaSkeleton()
          }
          .setProcessor(
            DownsamplingImageProcessor(size: CGSize(width: 1_024, height: 768))
          )
          .resizable()
          .cancelOnDisappear(true)
          .transition(.fade(duration: 0.16))
          .aspectRatio(contentMode: .fill)
          .blur(radius: isBlurred ? 40 : 0)
          .overlay {
            sensitiveWarningOverlay
          }
      }
    }
    .gesture(mediaTapGesture(for: mediaItem))
    .accessibilityAction {
      openFullscreenMedia(mediaItem)
    }
  }

  private func mediaContainer<Content: View>(
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    GeometryReader { proxy in
      ZStack {
        EventMediaSkeleton()

        content()
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipped()
      }
    }
    .aspectRatio(Self.mediaAspectRatio, contentMode: .fit)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: Self.mediaCornerRadius, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: Self.mediaCornerRadius, style: .continuous))
  }

  private func mediaTapGesture(for mediaItem: EventFullscreenMediaItem) -> some Gesture {
    TapGesture()
      .onEnded {
        if isBlurred {
          withAnimation(.easeOut(duration: 0.16)) {
            isBlurred = false
          }
          return
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        fullscreenMediaItem = mediaItem
      }
  }

  private func openFullscreenMedia(_ mediaItem: EventFullscreenMediaItem) {
    if isBlurred {
      withAnimation(.easeOut(duration: 0.16)) {
        isBlurred = false
      }
      return
    }

    fullscreenMediaItem = mediaItem
  }

  private var shouldBlurMediaByDefault: Bool {
    coordinator.blurredImages || (coordinator.blurSensitiveMedia && event.isSensitiveContent)
  }

  private var shouldShowSensitiveWarning: Bool {
    isBlurred && event.isSensitiveContent
  }

  private func resetBlurState() {
    isBlurred = shouldBlurMediaByDefault
  }

  private func shouldLoadAttachment(_ url: URL) -> Bool {
    if loadedAttachmentURLs.contains(url.absoluteString) {
      return true
    }

    switch coordinator.selectedAttachmentLoadingMode {
    case .automatically:
      return true
    case .askFirst:
      return false
    case .sensitiveOnly:
      return !event.isSensitiveContent
    }
  }

  @ViewBuilder
  private func attachmentPlaceholder(for urls: [URL], includesVideo: Bool = false) -> some View {
    EventAttachmentPlaceholder(
      count: urls.count,
      isSensitive: event.isSensitiveContent,
      reason: event.sensitiveContentLabel,
      includesVideo: includesVideo,
      action: {
        loadAttachments(urls)
      }
    )
  }

  private func loadAttachments(_ urls: [URL]) {
    withAnimation(.easeOut(duration: 0.16)) {
      for url in urls {
        loadedAttachmentURLs.insert(url.absoluteString)
      }
      resetBlurState()
    }
  }

  @ViewBuilder
  private var sensitiveWarningOverlay: some View {
    if shouldShowSensitiveWarning {
      ZStack {
        Rectangle()
          .fill(Color.black.opacity(0.18))

        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.title3)

          Text("Sensitive Content")
            .font(.subheadline.weight(.semibold))

          let sensitiveReason = event.sensitiveContentReason
            .trimmingCharacters(in: .whitespacesAndNewlines)

          if !sensitiveReason.isEmpty {
            Text(sensitiveReason)
              .font(.caption)
              .multilineTextAlignment(.center)
              .lineLimit(2)
          }

          Text("Tap to reveal")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundColor(.primary)
      }
      .allowsHitTesting(false)
    }
  }

  private func openShareSheet() {
    guard keyManager.selectedPrivateKeyHex != nil else {
      if let onInteractionRequiresKey {
        onInteractionRequiresKey()
      } else {
        showKeyGenerator = true
      }
      return
    }

    showShareSheet = true
  }

  private func publishLike() {
    guard !isPublishingReaction else { return }
    guard !isLiked else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else {
      if let onInteractionRequiresKey {
        onInteractionRequiresKey()
      } else {
        showKeyGenerator = true
      }
      return
    }

    let relayUrls = selectedRelayURLs()
    guard !relayUrls.isEmpty else {
      EfimerousManager.shared.showMessage("Select at least one relay")
      return
    }

    do {
      let draft = NIP25.reaction(
        eventID: event.id,
        publicKey: event.pubkey,
        content: "+",
        eventKind: event.kind,
        relayHint: event.threadTarget.focused.primaryRelayHint,
        address: eventAddress
      )
      let reactionEvent = try PostEventContent(privateKeyHex: privateKeyHex, draft: draft)

      withAnimation(.spring(response: 0.16, dampingFraction: 0.62)) {
        pendingReactionEventID = reactionEvent.event.id
        isPublishingReaction = true
      }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      cacheReactionEvent(reactionEvent.event)
      publishReaction(reactionEvent, to: relayUrls)
    } catch {
      EfimerousManager.shared.showMessage("Could not create reaction")
    }
  }

  private func publishRepost() {
    guard !isPublishingRepost else { return }
    guard !isReposted else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else {
      if let onInteractionRequiresKey {
        onInteractionRequiresKey()
      } else {
        showKeyGenerator = true
      }
      return
    }

    let relayUrls = selectedRelayURLs()
    guard !relayUrls.isEmpty else {
      EfimerousManager.shared.showMessage("Select at least one relay")
      return
    }

    do {
      let draft = NIP18.repost(
        eventID: event.id,
        publicKey: event.pubkey,
        eventKind: event.kind,
        relayHint: event.threadTarget.focused.primaryRelayHint
      )
      let repostEvent = try PostEventContent(privateKeyHex: privateKeyHex, draft: draft)

      withAnimation(.spring(response: 0.16, dampingFraction: 0.7)) {
        pendingRepostEventID = repostEvent.event.id
        isPublishingRepost = true
      }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      if event.kind == 1 {
        _ = nostrData.persistPublishedRepost(
          repostEvent.event,
          originalEventID: event.id,
          originalPublicKey: event.pubkey,
          originalContent: event.content,
          originalCreatedAt: event.createdAt,
          originalIsSensitiveContent: event.isSensitiveContent,
          originalSensitiveContentReason: event.sensitiveContentReason
        )
      } else {
        _ = nostrData.persistPublishedGenericRepost(repostEvent.event)
      }
      publishRepost(repostEvent, to: relayUrls)
    } catch {
      EfimerousManager.shared.showMessage("Could not create repost")
    }
  }

  private func publishRepost(_ repostEvent: PostEventContent, to relayUrls: [URL]) {
    var completedCount = 0
    var failedCount = 0

    for relayUrl in relayUrls {
      repostEvent.sendToNostr(relayUrl: relayUrl) { result in
        DispatchQueue.main.async {
          completedCount += 1

          if case .failure = result {
            failedCount += 1
          }

          guard completedCount == relayUrls.count else { return }
          finishRepostPublishing(relayCount: relayUrls.count, failedCount: failedCount)
        }
      }
    }
  }

  private func finishRepostPublishing(relayCount: Int, failedCount: Int) {
    withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
      isPublishingRepost = false
    }

    guard failedCount < relayCount else {
      if let pendingRepostEventID {
        removeCachedRepost(eventID: pendingRepostEventID)
      }
      withAnimation(.easeOut(duration: 0.15)) {
        pendingRepostEventID = nil
      }
      EfimerousManager.shared.showMessage("Could not send repost")
      return
    }

    pendingRepostEventID = nil
  }

  private func removeCachedRepost(eventID: String) {
    let targetEventID = eventID
    var descriptor = FetchDescriptor<RRepost>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    descriptor.fetchLimit = 1

    guard let repost = try? modelContext.fetch(descriptor).first else {
      return
    }

    modelContext.delete(repost)
    try? modelContext.save()
  }

  private func publishReaction(_ reactionEvent: PostEventContent, to relayUrls: [URL]) {
    var completedCount = 0
    var failedCount = 0

    for relayUrl in relayUrls {
      reactionEvent.sendToNostr(relayUrl: relayUrl) { result in
        DispatchQueue.main.async {
          completedCount += 1

          if case .failure = result {
            failedCount += 1
          }

          guard completedCount == relayUrls.count else { return }
          finishReactionPublishing(relayCount: relayUrls.count, failedCount: failedCount)
        }
      }
    }
  }

  private func finishReactionPublishing(relayCount: Int, failedCount: Int) {
    withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
      isPublishingReaction = false
    }

    guard failedCount < relayCount else {
      if let pendingReactionEventID {
        removeCachedReaction(eventID: pendingReactionEventID)
      }
      withAnimation(.easeOut(duration: 0.15)) {
        pendingReactionEventID = nil
      }
      EfimerousManager.shared.showMessage("Could not send reaction")
      return
    }

    pendingReactionEventID = nil
  }

  private func cacheReactionEvent(_ event: Event) {
    guard let reaction = RReaction.create(with: event),
      !cachedReactionExists(eventID: reaction.eventId)
    else {
      return
    }

    modelContext.insert(reaction)
    try? modelContext.save()
  }

  private func cachedReactionExists(eventID: String) -> Bool {
    let targetEventID = eventID
    var descriptor = FetchDescriptor<RReaction>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    descriptor.fetchLimit = 1

    guard let result = try? modelContext.fetch(descriptor) else {
      return false
    }

    return !result.isEmpty
  }

  private func removeCachedReaction(eventID: String) {
    let targetEventID = eventID
    var descriptor = FetchDescriptor<RReaction>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    descriptor.fetchLimit = 1

    guard let reaction = try? modelContext.fetch(descriptor).first else {
      return
    }

    modelContext.delete(reaction)
    try? modelContext.save()
  }

  private func publishReport(type: NIP56.ReportType, note: String = "") {
    guard !isPublishingReport else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else {
      if let onInteractionRequiresKey {
        onInteractionRequiresKey()
      } else {
        showKeyGenerator = true
      }
      return
    }

    let relayUrls = selectedRelayURLs()
    guard !relayUrls.isEmpty else {
      EfimerousManager.shared.showMessage("Select at least one relay")
      return
    }

    do {
      let draft = NIP56.report(
        eventID: event.id,
        publicKey: event.pubkey,
        type: type,
        note: reportNote(type: type, note: note)
      )
      let reportEvent = try PostEventContent(privateKeyHex: privateKeyHex, draft: draft)

      isPublishingReport = true
      publishReport(reportEvent, to: relayUrls)
    } catch {
      EfimerousManager.shared.showMessage("Could not create report")
    }
  }

  private func publishReport(_ reportEvent: PostEventContent, to relayUrls: [URL]) {
    var completedCount = 0
    var failedCount = 0

    for relayUrl in relayUrls {
      reportEvent.sendToNostr(relayUrl: relayUrl) { result in
        completedCount += 1

        if case .failure = result {
          failedCount += 1
        }

        guard completedCount == relayUrls.count else { return }
        finishReportPublishing(relayCount: relayUrls.count, failedCount: failedCount)
      }
    }
  }

  private func finishReportPublishing(relayCount: Int, failedCount: Int) {
    isPublishingReport = false

    guard failedCount < relayCount else {
      EfimerousManager.shared.showMessage("Could not send report")
      return
    }

    let sentCount = relayCount - failedCount
    EfimerousManager.shared.showMessage(sentCount == 1 ? "Report sent" : "Report sent to \(sentCount) relays")
  }

  private func selectedRelayURLs() -> [URL] {
    nostrData.storedRelays.ensureDefaultRelays()
    return nostrData.storedRelays.activeRelayAddresses.compactMap { URL(string: $0) }
  }

  private var eventAddress: String? {
    guard case .address(let coordinate, _, _, _, _) = event.threadTarget.focused else {
      return nil
    }
    return coordinate
  }

  private func reportNote(type: NIP56.ReportType, note: String) -> String {
    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedNote.isEmpty else { return trimmedNote }

    return "Reported as \(type.rawValue) from Land."
  }

  private var userPublicKeyBech32: String {
    bech32_pubkey(event.pubkey) ?? event.pubkey
  }

  private var profileURL: String {
    "https://nostr.com/\(userPublicKeyBech32)"
  }

  private var sensitiveReportTitle: String {
    event.isSensitiveContent ? "Sensitive Content Warning" : "Missing Content Warning"
  }

  private var sensitiveReportNote: String {
    if event.isSensitiveContent {
      return "Reported sensitive content warning: \(event.sensitiveContentLabel)"
    }

    return "Reported as sensitive content or missing content warning."
  }

  private func copyEventContent() {
    let content = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else {
      EfimerousManager.shared.showMessage("No content to copy")
      return
    }

    UIPasteboard.general.string = content
    EfimerousManager.shared.showMessage("Copied")
  }

  private func copyEventID() {
    UIPasteboard.general.string = event.id
    EfimerousManager.shared.showMessage("Copied")
  }

  private func copyUserPublicKey() {
    UIPasteboard.general.string = userPublicKeyBech32
    EfimerousManager.shared.showMessage("Copied")
  }

  private func copyProfileURL() {
    UIPasteboard.general.string = profileURL
    EfimerousManager.shared.showMessage("Copied")
  }

  private static let shortPublicationDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter
  }()

  private static let fullPublicationDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  private static func publicationTimeLabel(for date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))

    if seconds < 60 {
      return "now"
    }

    let minutes = seconds / 60
    if minutes < 60 {
      return "\(minutes)m"
    }

    let hours = minutes / 60
    if hours < 24 {
      return "\(hours)h"
    }

    let days = hours / 24
    if days < 7 {
      return "\(days)d"
    }

    return shortPublicationDateFormatter.string(from: date)
  }
}

struct EventView: View {

  // MARK: - Properties

  private static let mediaAspectRatio: CGFloat = 4 / 3
  private static let mediaCornerRadius: CGFloat = 14
  private static let collapsedContentCharacterLimit = 360

  // ENVIROMENT OBJECTS
  @EnvironmentObject var nostrData: NostrData
  @EnvironmentObject var navigation: AppNavigation
  @EnvironmentObject var keyManager: KeyManager
  @EnvironmentObject var coordinator: Coordinator
  @Environment(\.modelContext) private var modelContext

  // LAUNCH OBJECTS TO OBSERVE
  let event: EventViewModel
  var onInteractionRequiresKey: (() -> Void)?
  private let layout: EventViewLayout
  private let presentation: EventPresentationModel
  @Query private var reactions: [RReaction]
  @Query private var reposts: [RRepost]
  @Query private var comments: [RTextNote]
  @Query private var cachedThreadReplies: [RThreadEvent]
  @Query private var userProfiles: [RUserProfile]
  @Query private var reposterProfiles: [RUserProfile]

  // EVENT ACTIONS DIALOG
  @State private var showReportReasonDialog = false
  @State private var showKeyGenerator = false
  @State private var showShareSheet = false
  @State private var isPublishingReport = false
  @State private var isPublishingReaction = false
  @State private var isPublishingRepost = false
  @State private var pendingReactionEventID: String?
  @State private var pendingRepostEventID: String?

  // IMAGE BLUR AND FULLSCREEN MODE TOGGLES

  @State private var isBlurred = true
  @State private var fullscreenMediaItem: EventFullscreenMediaItem?
  @State private var loadedAttachmentURLs = Set<String>()
  @State private var isContentExpanded = false

  init(textNote: RTextNote, onInteractionRequiresKey: (() -> Void)? = nil) {
    self.init(event: EventViewModel(textNote: textNote), onInteractionRequiresKey: onInteractionRequiresKey)
  }

  init(feedItem: FeedItem, onInteractionRequiresKey: (() -> Void)? = nil) {
    self.init(event: EventViewModel(feedItem: feedItem), onInteractionRequiresKey: onInteractionRequiresKey)
  }

  init(
    threadItem: ThreadItem,
    layout: EventViewLayout = .standard,
    onInteractionRequiresKey: (() -> Void)? = nil
  ) {
    self.init(
      event: EventViewModel(threadItem: threadItem),
      onInteractionRequiresKey: onInteractionRequiresKey,
      layout: layout
    )
  }

  init(
    event: EventViewModel,
    onInteractionRequiresKey: (() -> Void)? = nil,
    layout: EventViewLayout = .standard
  ) {
    self.event = event
    self.onInteractionRequiresKey = onInteractionRequiresKey
    self.layout = layout
    self.presentation = EventRenderCache.shared.rendered(for: event)

    let reactedEventID = event.id
    var descriptor = FetchDescriptor<RReaction>(
      predicate: #Predicate { $0.reactedEventId == reactedEventID },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = 100
    _reactions = Query(descriptor)

    let repostedEventID = event.id
    var repostDescriptor = FetchDescriptor<RRepost>(
      predicate: #Predicate { $0.targetEventId == repostedEventID },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    repostDescriptor.fetchLimit = 100
    _reposts = Query(repostDescriptor)

    let commentedEventID = event.id
    var commentsDescriptor = FetchDescriptor<RTextNote>(
      predicate: #Predicate { note in
        note.eventId != commentedEventID
          && note.replyEventId == commentedEventID
      },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    commentsDescriptor.fetchLimit = 120
    _comments = Query(commentsDescriptor)

    let parentKey = event.threadTarget.focused.canonicalKey
    var threadRepliesDescriptor = FetchDescriptor<RThreadEvent>(
      predicate: #Predicate { $0.parentKey == parentKey },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    threadRepliesDescriptor.fetchLimit = 120
    _cachedThreadReplies = Query(threadRepliesDescriptor)

    let profilePublicKey = event.pubkey
    var profileDescriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == profilePublicKey }
    )
    profileDescriptor.fetchLimit = 1
    _userProfiles = Query(profileDescriptor)

    let reposterPublicKey = event.repost?.publicKey ?? ""
    var reposterDescriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == reposterPublicKey }
    )
    reposterDescriptor.fetchLimit = 1
    _reposterProfiles = Query(reposterDescriptor)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      repostLegend
      eventLayout
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 2)
    .onAppear {
      resetBlurState()
    }
    .task(id: authorNIP05VerificationTaskID) {
      await verifyAuthorNIP05IfNeeded()
    }
    .task(id: reposterNIP05VerificationTaskID) {
      await verifyReposterNIP05IfNeeded()
    }
    .onChange(of: coordinator.blurredImages) { _, _ in
      resetBlurState()
    }
    .onChange(of: coordinator.blurSensitiveMedia) { _, _ in
      resetBlurState()
    }
    .fullScreenCover(item: $fullscreenMediaItem) { mediaItem in
      EventFullscreenMediaViewer(item: mediaItem) {
        fullscreenMediaItem = nil
      }
    }

    .confirmationDialog(
      "Report Post",
      isPresented: $showReportReasonDialog,
      titleVisibility: .visible
    ) {
      Button(sensitiveReportTitle, role: .destructive) {
        publishReport(
          type: .other,
          note: sensitiveReportNote
        )
      }
      Button(NIP56.ReportType.spam.title, role: .destructive) {
        publishReport(type: .spam)
      }
      Button(NIP56.ReportType.illegal.title, role: .destructive) {
        publishReport(type: .illegal)
      }
      Button(NIP56.ReportType.malware.title, role: .destructive) {
        publishReport(type: .malware)
      }
      Button(NIP56.ReportType.impersonation.title, role: .destructive) {
        publishReport(type: .impersonation)
      }
      Button(NIP56.ReportType.profanity.title, role: .destructive) {
        publishReport(type: .profanity)
      }
      Button(NIP56.ReportType.other.title, role: .destructive) {
        publishReport(type: .other)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Reports are sent to your active relays as a NIP-56 event.")
    }
    .sheet(isPresented: $showKeyGenerator) {
      KeyGen(initialMode: .generate)
        .environmentObject(keyManager)
    }
    .sheet(isPresented: $showShareSheet) {
      EventShareSheet(
        event: event,
        authorDisplayName: displayName,
        onOpenChat: { publicKey in
          navigation.push(.chat(publicKey: publicKey))
        }
      )
      .environmentObject(keyManager)
    }
  }

  @ViewBuilder
  private var eventLayout: some View {
    switch layout {
    case .standard:
      HStack(alignment: .top, spacing: 0) {
        avatarButton

        VStack(alignment: .leading, spacing: 8) {
          authorHeader
          eventContentAndActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

    case .threadFocus:
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 0) {
          avatarButton
          authorHeader
        }

        eventContentAndActions
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var avatarButton: some View {
    Button(action: navigateToProfile) {
      ZStack {
        Circle()
          .fill(Color.primary.opacity(0.001))

        AvatarView(publicKey: event.pubkey, url: profileAvatarURL, size: 44)
          .allowsHitTesting(false)
      }
      .frame(width: 48, height: 48)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Profile")
  }

  private var authorHeader: some View {
    HStack(alignment: .top, spacing: 8) {
      Button(action: navigateToProfile) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(displayName)
              .font(.subheadline.weight(.semibold))
              .foregroundColor(.primary)
              .lineLimit(1)

            if isAuthorNIP05Verified {
              Image(systemName: "checkmark.seal.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityLabel("Verified NIP-05")
            }

            TimelineView(.periodic(from: .now, by: 60)) { timeline in
              Text(Self.publicationTimeLabel(for: event.createdAt, now: timeline.date))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(publicationAccessibilityLabel)
            }
          }

          Text(authorPublicKeyLabel)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Spacer(minLength: 8)
      eventActionsMenu
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var eventContentAndActions: some View {
    if let content = presentation.contentWithoutImageLinks ?? presentation.contentFormatted,
      !content.characters.isEmpty
    {
      contentView(for: content)
    }

    mediaContent
    eventFooter
  }

  private var authorPublicKeyLabel: String {
    (bech32_pubkey(event.pubkey) ?? event.pubkey).accordionString(index: 10)
  }

  private func navigateToProfile() {
    navigation.push(.profile(publicKey: event.pubkey))
  }

  private var profileAvatarURL: URL? {
    userProfiles.first?.avatarUrl ?? event.profileAvatarURL
  }

  private var displayName: String {
    if let name = userProfiles.first?.name, name.isValidName() {
      return name
    }

    if let name = event.profileName, name.isValidName() {
      return name
    }

    return "Anonymous"
  }

  private var isAuthorNIP05Verified: Bool {
    userProfiles.first?.verifiedNIP05 != nil
  }

  private var authorNIP05VerificationTaskID: String {
    let identifier = userProfiles.first?.nip05
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    return "\(event.pubkey.lowercased())|\(identifier)"
  }

  @MainActor
  private func verifyAuthorNIP05IfNeeded() async {
    let identifier = userProfiles.first?.nip05
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard NIP05.parse(identifier) != nil else { return }

    await nostrData.verifyNIP05IfNeeded(
      forPublicKey: event.pubkey,
      identifier: identifier
    )
  }

  @ViewBuilder
  private var repostLegend: some View {
    if let repost = event.repost {
      HStack(alignment: .center, spacing: 6) {
        AvatarView(publicKey: repost.publicKey, url: reposterProfiles.first?.avatarUrl, size: 18)

        HStack(alignment: .center, spacing: 5) {
          HStack(alignment: .center, spacing: 2) {
            Text(reposterDisplayName)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)

            if isReposterNIP05Verified {
              Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityLabel("Verified NIP-05")
            }
          }

          Text("reposted this")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(.leading, 60)
      .accessibilityLabel("\(reposterDisplayName) reposted this")
    }
  }

  private var reposterDisplayName: String {
    if let name = reposterProfiles.first?.name, name.isValidName() {
      return name
    }

    guard let publicKey = event.repost?.publicKey else {
      return "Someone"
    }

    return bech32_pubkey(publicKey)?.accordionString(index: 8)
      ?? publicKey.accordionString(index: 8)
  }

  private var isReposterNIP05Verified: Bool {
    reposterProfiles.first?.verifiedNIP05 != nil
  }

  private var reposterNIP05VerificationTaskID: String {
    let publicKey = event.repost?.publicKey.lowercased() ?? ""
    let identifier = reposterProfiles.first?.nip05
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    return "\(publicKey)|\(identifier)"
  }

  @MainActor
  private func verifyReposterNIP05IfNeeded() async {
    guard let publicKey = event.repost?.publicKey, publicKey != event.pubkey else { return }
    let identifier = reposterProfiles.first?.nip05
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard NIP05.parse(identifier) != nil else { return }

    await nostrData.verifyNIP05IfNeeded(
      forPublicKey: publicKey,
      identifier: identifier
    )
  }

  private var selectedPublicKeyHex: String? {
    if let privateKeyHex = keyManager.selectedPrivateKeyHex {
      return privkey_to_pubkey(privkey: privateKeyHex)
    }

    guard case .pub(let publicKeyHex) = decode_bech32_key(keyManager.selectedKey) else {
      return nil
    }

    return publicKeyHex
  }

  private var isLiked: Bool {
    guard let selectedPublicKeyHex else { return false }
    return reactions.contains {
      $0.reactedEventId == event.id
        && $0.reactorPublicKey == selectedPublicKeyHex
        && $0.isLike
    }
  }

  private var isVisuallyLiked: Bool {
    isLiked || pendingReactionEventID != nil
  }

  private var isReposted: Bool {
    guard let selectedPublicKeyHex else { return false }
    return reposts.contains {
      $0.targetEventId == event.id && $0.publicKey == selectedPublicKeyHex
    }
  }

  private var isVisuallyReposted: Bool {
    isReposted || pendingRepostEventID != nil
  }

  private var isRepostHighlighted: Bool {
    !reposts.isEmpty || isVisuallyReposted
  }

  private var likeCount: Int {
    var likerPublicKeys = Set<String>()

    for reaction in reactions where reaction.isLike {
      likerPublicKeys.insert(reaction.reactorPublicKey)
    }

    if let selectedPublicKeyHex, pendingReactionEventID != nil {
      likerPublicKeys.insert(selectedPublicKeyHex)
    }

    return likerPublicKeys.count
  }

  private var commentCount: Int {
    var commentIDs = Set(comments.map(\.eventId))
    commentIDs.formUnion(cachedThreadReplies.map(\.eventId))
    return commentIDs.count
  }

  @ViewBuilder
  private var eventFooter: some View {
    HStack(spacing: 10) {
      reactionControl
      commentControl
      repostControl
      shareControl
    }
    .padding(.top, 6)
  }

  @ViewBuilder
  private var reactionControl: some View {
    Button {
      publishLike()
    } label: {
      LikeControlLabel(
        isLiked: isVisuallyLiked,
        isPublishing: isPublishingReaction,
        count: likeCount
      )
    }
    .buttonStyle(.plain)
    .disabled(isPublishingReaction)
    .accessibilityLabel(isVisuallyLiked ? "Liked" : "Like")
    .accessibilityValue("\(likeCount) likes")
  }

  @ViewBuilder
  private var commentControl: some View {
    Button {
      navigation.push(.thread(target: event.threadTarget))
    } label: {
      EventCountIconLabel(
        systemImage: "bubble.left",
        activeSystemImage: "bubble.left",
        count: commentCount,
        isActive: commentCount > 0,
        activeColor: .primary
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Comments")
    .accessibilityValue("\(commentCount) comments")
  }

  @ViewBuilder
  private var repostControl: some View {
    Button {
      publishRepost()
    } label: {
      Image(systemName: "arrow.2.squarepath")
        .font(.system(size: 17, weight: isRepostHighlighted ? .semibold : .regular))
        .foregroundStyle(isRepostHighlighted ? Color.primary : Color.secondary)
        .frame(width: 36, height: 36, alignment: .center)
        .scaleEffect(isPublishingRepost ? 1.08 : 1)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isPublishingRepost)
    .accessibilityLabel(isVisuallyReposted ? "Reposted" : "Repost")
  }

  @ViewBuilder
  private var shareControl: some View {
    Button(action: openShareSheet) {
      Image(systemName: "paperplane")
        .font(.system(size: 17, weight: .regular))
        .foregroundColor(.secondary)
        .frame(width: 36, height: 36, alignment: .center)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Share")
  }

  @ViewBuilder
  private var eventActionsMenu: some View {
    Menu {
      Button {
        navigateToProfile()
      } label: {
        Label("Open Profile", systemImage: "person.crop.circle")
      }

      Button {
        copyEventContent()
      } label: {
        Label("Copy Content", systemImage: "doc.on.doc")
      }

      Button {
        copyEventID()
      } label: {
        Label("Copy Event ID", systemImage: "number")
      }

      Button {
        copyUserPublicKey()
      } label: {
        Label("Copy npub", systemImage: "key.horizontal")
      }

      Button {
        copyProfileURL()
      } label: {
        Label("Copy Profile Link", systemImage: "link")
      }

      Button {
        navigation.push(.qr(publicKey: event.pubkey))
      } label: {
        Label("QR Code", systemImage: "qrcode")
      }

      Divider()

      Button(role: .destructive) {
        showReportReasonDialog = true
      } label: {
        Label("Report", systemImage: "exclamationmark.bubble")
      }
    } label: {
      Group {
        if isPublishingReport {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "ellipsis")
            .font(.system(size: 17, weight: .semibold))
        }
      }
      .foregroundColor(.secondary)
      .frame(width: 32, height: 32)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(isPublishingReport)
    .accessibilityLabel("More")
  }

  @ViewBuilder
  private var mediaContent: some View {
    if let linkPreview = presentation.linkPreview {
      LinkPreviewCard(descriptor: linkPreview)
    }

    if let videoUrl = presentation.videoUrl {
      if shouldLoadAttachment(videoUrl) {
        let mediaItem = EventFullscreenMediaItem.video(url: videoUrl)

        mediaContainer {
          EventVideoAttachment(url: videoUrl) {
            openFullscreenMedia(mediaItem)
          }
        }
        .gesture(mediaTapGesture(for: mediaItem))
        .accessibilityAction {
          openFullscreenMedia(mediaItem)
        }
      } else {
        attachmentPlaceholder(for: [videoUrl], includesVideo: true)
      }
    } else {
      let imageUrls = presentation.imageUrls

      if imageUrls.count > 1 {
        if imageUrls.allSatisfy(shouldLoadAttachment) {
          TabView {
            ForEach(Array(imageUrls.enumerated()), id: \.offset) { _, imageUrl in
              imageView(for: imageUrl)
                .padding(.vertical, 2)
            }
          }
          .tabViewStyle(.page(indexDisplayMode: .automatic))
          .aspectRatio(Self.mediaAspectRatio, contentMode: .fit)
        } else {
          attachmentPlaceholder(for: imageUrls)
        }
      } else if let imageUrl = imageUrls.first {
        if shouldLoadAttachment(imageUrl) {
          imageView(for: imageUrl)
        } else {
          attachmentPlaceholder(for: [imageUrl])
        }
      }
    }
  }

  private var userPublicKeyBech32: String {
    bech32_pubkey(event.pubkey) ?? event.pubkey
  }

  @ViewBuilder
  private func contentView(for content: AttributedString) -> some View {
    let displayContent = collapsedContent(for: content)
    let canToggleExpansion = content.characters.count > Self.collapsedContentCharacterLimit

    VStack(alignment: .leading, spacing: 6) {
      Text(displayContent)
        .font(.body)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      if canToggleExpansion {
        Button {
          withAnimation(.easeOut(duration: 0.16)) {
            isContentExpanded.toggle()
          }
        } label: {
          Text(isContentExpanded ? "Show Less" : "Read More")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isContentExpanded ? "Collapse post" : "Read full post")
      }
    }
    .padding(.top, 2)
    .environment(\.openURL, OpenURLAction { url in
      if let publicKey = NostrInlineText.profilePublicKey(from: url) {
        navigation.push(.profile(publicKey: publicKey))
        return .handled
      }

      return .systemAction
    })
  }

  private func collapsedContent(for content: AttributedString) -> AttributedString {
    let characterCount = content.characters.count
    guard !isContentExpanded,
      characterCount > Self.collapsedContentCharacterLimit
    else {
      return content
    }

    let plainText = String(content.characters)
    let cutoffIndex = collapsedContentCutoffIndex(in: plainText)
    guard let attributedCutoff = AttributedString.Index(cutoffIndex, within: content) else {
      return content
    }

    var excerpt = AttributedString(content[..<attributedCutoff])
    excerpt.append(AttributedString("…"))
    return excerpt
  }

  private func collapsedContentCutoffIndex(in text: String) -> String.Index {
    let hardLimit = text.index(
      text.startIndex,
      offsetBy: Self.collapsedContentCharacterLimit,
      limitedBy: text.endIndex
    ) ?? text.endIndex

    let softWindowStart = text.index(
      hardLimit,
      offsetBy: -70,
      limitedBy: text.startIndex
    ) ?? text.startIndex

    let searchRange = softWindowStart..<hardLimit
    if let newlineIndex = text[searchRange].lastIndex(where: \.isNewline) {
      return newlineIndex
    }

    if let whitespaceIndex = text[searchRange].lastIndex(where: \.isWhitespace) {
      return whitespaceIndex
    }

    return hardLimit
  }

  private var profileURL: String {
    "https://nostr.com/\(userPublicKeyBech32)"
  }

  private var publicationAccessibilityLabel: String {
    Self.fullPublicationDateFormatter.string(from: event.createdAt)
  }

  private static let shortPublicationDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter
  }()

  private static let fullPublicationDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  private static func publicationTimeLabel(for date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))

    if seconds < 60 {
      return "now"
    }

    let minutes = seconds / 60
    if minutes < 60 {
      return "\(minutes)m"
    }

    let hours = minutes / 60
    if hours < 24 {
      return "\(hours)h"
    }

    let days = hours / 24
    if days < 7 {
      return "\(days)d"
    }

    return shortPublicationDateFormatter.string(from: date)
  }

  private var sensitiveReportTitle: String {
    event.isSensitiveContent ? "Sensitive Content Warning" : "Missing Content Warning"
  }

  private var sensitiveReportNote: String {
    if event.isSensitiveContent {
      return "Reported sensitive content warning: \(event.sensitiveContentLabel)"
    }

    return "Reported as sensitive content or missing content warning."
  }

  private func copyEventContent() {
    let content = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else {
      EfimerousManager.shared.showMessage("No content to copy")
      return
    }

    UIPasteboard.general.string = content
    EfimerousManager.shared.showMessage("Copied")
  }

  private func copyEventID() {
    UIPasteboard.general.string = event.id
    EfimerousManager.shared.showMessage("Copied")
  }

  private func copyUserPublicKey() {
    UIPasteboard.general.string = userPublicKeyBech32
    EfimerousManager.shared.showMessage("Copied")
  }

  private func copyProfileURL() {
    UIPasteboard.general.string = profileURL
    EfimerousManager.shared.showMessage("Copied")
  }

  private func openShareSheet() {
    guard keyManager.selectedPrivateKeyHex != nil else {
      if let onInteractionRequiresKey {
        onInteractionRequiresKey()
      } else {
        showKeyGenerator = true
      }
      return
    }

    showShareSheet = true
  }

  private func publishLike() {
    guard !isPublishingReaction else { return }
    guard !isLiked else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else {
      if let onInteractionRequiresKey {
        onInteractionRequiresKey()
      } else {
        showKeyGenerator = true
      }
      return
    }

    let relayUrls = selectedRelayURLs()
    guard !relayUrls.isEmpty else {
      EfimerousManager.shared.showMessage("Select at least one relay")
      return
    }

    do {
      let draft = NIP25.reaction(
        eventID: event.id,
        publicKey: event.pubkey,
        content: "+",
        eventKind: event.kind,
        relayHint: event.threadTarget.focused.primaryRelayHint,
        address: eventAddress
      )
      let reactionEvent = try PostEventContent(privateKeyHex: privateKeyHex, draft: draft)

      withAnimation(.spring(response: 0.16, dampingFraction: 0.62)) {
        pendingReactionEventID = reactionEvent.event.id
        isPublishingReaction = true
      }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      cacheReactionEvent(reactionEvent.event)
      publishReaction(reactionEvent, to: relayUrls)
    } catch {
      EfimerousManager.shared.showMessage("Could not create reaction")
    }
  }

  private func publishRepost() {
    guard !isPublishingRepost else { return }
    guard !isReposted else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else {
      if let onInteractionRequiresKey {
        onInteractionRequiresKey()
      } else {
        showKeyGenerator = true
      }
      return
    }

    let relayUrls = selectedRelayURLs()
    guard !relayUrls.isEmpty else {
      EfimerousManager.shared.showMessage("Select at least one relay")
      return
    }

    do {
      let draft = NIP18.repost(
        eventID: event.id,
        publicKey: event.pubkey,
        eventKind: event.kind,
        relayHint: event.threadTarget.focused.primaryRelayHint
      )
      let repostEvent = try PostEventContent(privateKeyHex: privateKeyHex, draft: draft)

      withAnimation(.spring(response: 0.16, dampingFraction: 0.7)) {
        pendingRepostEventID = repostEvent.event.id
        isPublishingRepost = true
      }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      if event.kind == 1 {
        _ = nostrData.persistPublishedRepost(
          repostEvent.event,
          originalEventID: event.id,
          originalPublicKey: event.pubkey,
          originalContent: event.content,
          originalCreatedAt: event.createdAt,
          originalIsSensitiveContent: event.isSensitiveContent,
          originalSensitiveContentReason: event.sensitiveContentReason
        )
      } else {
        _ = nostrData.persistPublishedGenericRepost(repostEvent.event)
      }
      publishRepost(repostEvent, to: relayUrls)
    } catch {
      EfimerousManager.shared.showMessage("Could not create repost")
    }
  }

  private func publishRepost(_ repostEvent: PostEventContent, to relayUrls: [URL]) {
    var completedCount = 0
    var failedCount = 0

    for relayUrl in relayUrls {
      repostEvent.sendToNostr(relayUrl: relayUrl) { result in
        DispatchQueue.main.async {
          completedCount += 1

          if case .failure = result {
            failedCount += 1
          }

          guard completedCount == relayUrls.count else { return }
          finishRepostPublishing(relayCount: relayUrls.count, failedCount: failedCount)
        }
      }
    }
  }

  private func finishRepostPublishing(relayCount: Int, failedCount: Int) {
    withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
      isPublishingRepost = false
    }

    guard failedCount < relayCount else {
      if let pendingRepostEventID {
        removeCachedRepost(eventID: pendingRepostEventID)
      }
      withAnimation(.easeOut(duration: 0.15)) {
        pendingRepostEventID = nil
      }
      EfimerousManager.shared.showMessage("Could not send repost")
      return
    }

    pendingRepostEventID = nil
  }

  private func removeCachedRepost(eventID: String) {
    let targetEventID = eventID
    var descriptor = FetchDescriptor<RRepost>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    descriptor.fetchLimit = 1

    guard let repost = try? modelContext.fetch(descriptor).first else {
      return
    }

    modelContext.delete(repost)
    try? modelContext.save()
  }

  private func publishReaction(_ reactionEvent: PostEventContent, to relayUrls: [URL]) {
    var completedCount = 0
    var failedCount = 0

    for relayUrl in relayUrls {
      reactionEvent.sendToNostr(relayUrl: relayUrl) { result in
        DispatchQueue.main.async {
          completedCount += 1

          if case .failure = result {
            failedCount += 1
          }

          guard completedCount == relayUrls.count else { return }
          finishReactionPublishing(relayCount: relayUrls.count, failedCount: failedCount)
        }
      }
    }
  }

  private func finishReactionPublishing(relayCount: Int, failedCount: Int) {
    withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
      isPublishingReaction = false
    }

    guard failedCount < relayCount else {
      if let pendingReactionEventID {
        removeCachedReaction(eventID: pendingReactionEventID)
      }
      withAnimation(.easeOut(duration: 0.15)) {
        pendingReactionEventID = nil
      }
      EfimerousManager.shared.showMessage("Could not send reaction")
      return
    }

    pendingReactionEventID = nil
  }

  private func cacheReactionEvent(_ event: Event) {
    guard let reaction = RReaction.create(with: event),
      !cachedReactionExists(eventID: reaction.eventId)
    else {
      return
    }

    modelContext.insert(reaction)
    try? modelContext.save()
  }

  private func cachedReactionExists(eventID: String) -> Bool {
    let targetEventID = eventID
    var descriptor = FetchDescriptor<RReaction>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    descriptor.fetchLimit = 1

    guard let result = try? modelContext.fetch(descriptor) else {
      return false
    }

    return !result.isEmpty
  }

  private func removeCachedReaction(eventID: String) {
    let targetEventID = eventID
    var descriptor = FetchDescriptor<RReaction>(
      predicate: #Predicate { $0.eventId == targetEventID }
    )
    descriptor.fetchLimit = 1

    guard let reaction = try? modelContext.fetch(descriptor).first else {
      return
    }

    modelContext.delete(reaction)
    try? modelContext.save()
  }

  private func publishReport(type: NIP56.ReportType, note: String = "") {
    guard !isPublishingReport else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else {
      if let onInteractionRequiresKey {
        onInteractionRequiresKey()
      } else {
        showKeyGenerator = true
      }
      return
    }

    let relayUrls = selectedRelayURLs()
    guard !relayUrls.isEmpty else {
      EfimerousManager.shared.showMessage("Select at least one relay")
      return
    }

    do {
      let draft = NIP56.report(
        eventID: event.id,
        publicKey: event.pubkey,
        type: type,
        note: reportNote(type: type, note: note)
      )
      let reportEvent = try PostEventContent(privateKeyHex: privateKeyHex, draft: draft)

      isPublishingReport = true
      publishReport(reportEvent, to: relayUrls)
    } catch {
      EfimerousManager.shared.showMessage("Could not create report")
    }
  }

  private func selectedRelayURLs() -> [URL] {
    nostrData.storedRelays.ensureDefaultRelays()
    return nostrData.storedRelays.activeRelayAddresses.compactMap { URL(string: $0) }
  }

  private var eventAddress: String? {
    guard case .address(let coordinate, _, _, _, _) = event.threadTarget.focused else {
      return nil
    }
    return coordinate
  }

  private func reportNote(type: NIP56.ReportType, note: String) -> String {
    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedNote.isEmpty else { return trimmedNote }

    return "Reported as \(type.rawValue) from Land."
  }

  private func publishReport(_ reportEvent: PostEventContent, to relayUrls: [URL]) {
    var completedCount = 0
    var failedCount = 0

    for relayUrl in relayUrls {
      reportEvent.sendToNostr(relayUrl: relayUrl) { result in
        completedCount += 1

        if case .failure = result {
          failedCount += 1
        }

        guard completedCount == relayUrls.count else { return }
        finishReportPublishing(relayCount: relayUrls.count, failedCount: failedCount)
      }
    }
  }

  private func finishReportPublishing(relayCount: Int, failedCount: Int) {
    isPublishingReport = false

    guard failedCount < relayCount else {
      EfimerousManager.shared.showMessage("Could not send report")
      return
    }

    let sentCount = relayCount - failedCount
    EfimerousManager.shared.showMessage(sentCount == 1 ? "Report sent" : "Report sent to \(sentCount) relays")
  }

  // MARK: - Image renderer honoring your existing handling
  @ViewBuilder
  private func imageView(for imageUrl: URL) -> some View {
    let mediaItem = EventFullscreenMediaItem.image(url: imageUrl)

    mediaContainer {
      switch imageUrl.pathExtension.lowercased() {
      case "gif", "webp", "svg":
        AnimatedImage(url: imageUrl)
          .placeholder {
            EventMediaSkeleton()
          }
          .resizable()
          .aspectRatio(contentMode: .fill)
          .blur(radius: isBlurred ? 40 : 0)
          .overlay {
            sensitiveWarningOverlay
          }

      default:
        KFImage(imageUrl)
          .placeholder {
            EventMediaSkeleton()
          }
          .setProcessor(
            DownsamplingImageProcessor(size: CGSize(width: 1_024, height: 768))
          )
          .resizable()
          .cancelOnDisappear(true)
          .transition(.fade(duration: 0.16))
          .aspectRatio(contentMode: .fill)
          .blur(radius: isBlurred ? 40 : 0)
          .overlay {
            sensitiveWarningOverlay
        }
      }
    }
    .gesture(mediaTapGesture(for: mediaItem))
    .accessibilityAction {
      openFullscreenMedia(mediaItem)
    }
  }

  private func mediaContainer<Content: View>(
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    GeometryReader { proxy in
      ZStack {
        EventMediaSkeleton()

        content()
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipped()
      }
    }
    .aspectRatio(Self.mediaAspectRatio, contentMode: .fit)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: Self.mediaCornerRadius, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: Self.mediaCornerRadius, style: .continuous))
  }

  private func mediaTapGesture(for mediaItem: EventFullscreenMediaItem) -> some Gesture {
    TapGesture()
      .onEnded {
        if isBlurred {
          withAnimation(.easeOut(duration: 0.16)) {
            isBlurred = false
          }
          return
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        fullscreenMediaItem = mediaItem
      }
  }

  private func openFullscreenMedia(_ mediaItem: EventFullscreenMediaItem) {
    if isBlurred {
      withAnimation(.easeOut(duration: 0.16)) {
        isBlurred = false
      }
      return
    }

    fullscreenMediaItem = mediaItem
  }

  private var shouldBlurMediaByDefault: Bool {
    coordinator.blurredImages || (coordinator.blurSensitiveMedia && event.isSensitiveContent)
  }

  private var shouldShowSensitiveWarning: Bool {
    isBlurred && event.isSensitiveContent
  }

  private func resetBlurState() {
    isBlurred = shouldBlurMediaByDefault
  }

  private func shouldLoadAttachment(_ url: URL) -> Bool {
    if loadedAttachmentURLs.contains(url.absoluteString) {
      return true
    }

    switch coordinator.selectedAttachmentLoadingMode {
    case .automatically:
      return true
    case .askFirst:
      return false
    case .sensitiveOnly:
      return !event.isSensitiveContent
    }
  }

  @ViewBuilder
  private func attachmentPlaceholder(for urls: [URL], includesVideo: Bool = false) -> some View {
    EventAttachmentPlaceholder(
      count: urls.count,
      isSensitive: event.isSensitiveContent,
      reason: event.sensitiveContentLabel,
      includesVideo: includesVideo,
      action: {
        loadAttachments(urls)
      }
    )
  }

  private func loadAttachments(_ urls: [URL]) {
    withAnimation(.easeOut(duration: 0.16)) {
      for url in urls {
        loadedAttachmentURLs.insert(url.absoluteString)
      }
      resetBlurState()
    }
  }

  @ViewBuilder
  private var sensitiveWarningOverlay: some View {
    if shouldShowSensitiveWarning {
      ZStack {
        Rectangle()
          .fill(Color.black.opacity(0.18))

        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.title3)

          Text("Sensitive Content")
            .font(.subheadline.weight(.semibold))

          let sensitiveReason = event.sensitiveContentReason
            .trimmingCharacters(in: .whitespacesAndNewlines)

          if !sensitiveReason.isEmpty {
            Text(sensitiveReason)
              .font(.caption)
              .multilineTextAlignment(.center)
              .lineLimit(2)
          }

          Text("Tap to reveal")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundColor(.primary)
      }
      .allowsHitTesting(false)
    }
  }
}

private struct EventCountIconLabel: View {
  let systemImage: String
  let activeSystemImage: String
  let count: Int
  let isActive: Bool
  let activeColor: Color

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: isActive ? activeSystemImage : systemImage)
        .font(.system(size: 17, weight: isActive ? .semibold : .regular))
        .foregroundStyle(isActive ? activeColor : .secondary)
        .frame(width: 24, height: 24)
        .offset(y: 1)

      if count > 0 {
        Text(compactCount)
          .font(.subheadline.weight(.light))
          .monospacedDigit()
          .foregroundStyle(isActive ? activeColor : .secondary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .frame(minWidth: count > 0 ? 58 : 36, minHeight: 36, maxHeight: 36, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var compactCount: String {
    let suffixes = ["", "K", "M", "B"]
    var value = Double(count)
    var suffixIndex = 0

    while value >= 1_000 && suffixIndex < suffixes.count - 1 {
      value /= 1_000
      suffixIndex += 1
    }

    if suffixIndex == 0 {
      return "\(count)"
    }

    let formattedValue =
      value.truncatingRemainder(dividingBy: 1) == 0
      ? String(format: "%.0f", value)
      : String(format: "%.1f", value)

    return "\(formattedValue)\(suffixes[suffixIndex])"
  }
}

private struct EventShareSheet: View {
  let event: EventViewModel
  let authorDisplayName: String
  let onOpenChat: (String) -> Void

  private let messagingService = MessagingService()

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var keyManager: KeyManager

  @State private var searchText = ""
  @State private var profileResults: [RUserProfile] = []
  @State private var recentRecipientPublicKeys: [String] = []
  @State private var followingPublicKeys: [String] = []
  @State private var suggestions: [RUserProfile] = []
  @State private var searchTask: Task<Void, Never>?
  @State private var sendingPublicKey: String?
  @State private var errorMessage: String?
  @State private var showKeyGenerator = false

  var body: some View {
    NavigationStack {
      List {
        if activePublicKey == nil {
          noKeySection
        } else {
          eventPreviewSection
          searchSection
          directRecipientSection
          recipientsSection
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Share")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
      .onAppear {
        refreshSuggestions()
      }
      .onChange(of: searchText) { _, _ in
        scheduleSearch()
      }
      .onDisappear {
        searchTask?.cancel()
      }
      .sheet(isPresented: $showKeyGenerator) {
        KeyGen(initialMode: .generate)
          .environmentObject(keyManager)
      }
    }
  }

  private var activePublicKey: String? {
    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else { return nil }
    return privkey_to_pubkey(privkey: privateKeyHex)
  }

  private var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var normalizedSearchText: String {
    trimmedSearchText.lowercased()
  }

  private var pastedPublicKey: String? {
    let normalized = normalizedSearchText
      .trimmingPrefix("@")
      .trimmingPrefix("nostr:")

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

  private var shareMessage: String {
    NostrEventReference(
      id: event.id,
      relayHints: event.threadTarget.focused.relayHints,
      kind: event.kind,
      publicKey: event.pubkey
    ).canonicalLink
  }

  private var eventExcerpt: String {
    let content = NostrInlineText.displayContent(event.content)
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard content.count > 120 else { return content }
    return "\(content.prefix(120))..."
  }

  @ViewBuilder
  private var noKeySection: some View {
    Section {
      VStack(spacing: 14) {
        Image(systemName: "key")
          .font(.system(size: 34, weight: .regular))
          .foregroundColor(.secondary)

        Text("Add a Key")
          .font(.title3.weight(.semibold))

        Text("Save a private key before sharing posts over encrypted messages.")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 280)

        Button("Add Key") {
          showKeyGenerator = true
        }
        .buttonStyle(.borderedProminent)
        .padding(.top, 4)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 32)
    }
    .listRowBackground(Color.clear)
  }

  private var eventPreviewSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "paperplane")
            .foregroundColor(.secondary)

          Text("Share Post")
            .font(.subheadline.weight(.semibold))
        }

        Text(authorDisplayName)
          .font(.caption)
          .foregroundColor(.secondary)

        if !eventExcerpt.isEmpty {
          Text(eventExcerpt)
            .font(.subheadline)
            .foregroundColor(.primary)
            .lineLimit(3)
        }

        Text(shareMessage)
          .font(.caption.monospaced())
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .padding(.vertical, 2)
    }
  }

  private var searchSection: some View {
    Section {
      TextField("Search or paste npub", text: $searchText, axis: .vertical)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .lineLimit(1...3)
    } header: {
      Text("Send To")
    } footer: {
      if let errorMessage {
        Text(errorMessage)
          .foregroundColor(.red)
      }
    }
  }

  @ViewBuilder
  private var directRecipientSection: some View {
    if let pastedPublicKey, pastedPublicKey != activePublicKey {
      Section {
        ShareRecipientRow(
          publicKey: pastedPublicKey,
          profile: profile(for: pastedPublicKey),
          isSending: sendingPublicKey == pastedPublicKey,
          action: {
            sendShare(to: pastedPublicKey)
          }
        )
      } header: {
        Text("Direct")
      }
    }
  }

  @ViewBuilder
  private var recipientsSection: some View {
    if trimmedSearchText.isEmpty {
      let directKey = pastedPublicKey
      let currentUserPublicKey = activePublicKey
      let recentKeys = recentRecipientPublicKeys.filter {
        $0 != currentUserPublicKey && $0 != directKey
      }
      let recentSet = Set(recentKeys)
      let followingKeys = followingPublicKeys.filter {
        $0 != currentUserPublicKey && $0 != directKey && !recentSet.contains($0)
      }
      let alreadyShown = Set(recentKeys + followingKeys)
      let fallbackProfiles = suggestions.filter {
        $0.publicKey != currentUserPublicKey
          && $0.publicKey != directKey
          && !alreadyShown.contains($0.publicKey)
      }

      if !recentKeys.isEmpty {
        Section("Recent Messages") {
          ForEach(recentKeys, id: \.self) { publicKey in
            ShareRecipientRow(
              publicKey: publicKey,
              profile: profile(for: publicKey),
              isSending: sendingPublicKey == publicKey,
              action: {
                sendShare(to: publicKey)
              }
            )
          }
        }
      }

      if !followingKeys.isEmpty {
        Section("Following") {
          ForEach(followingKeys, id: \.self) { publicKey in
            ShareRecipientRow(
              publicKey: publicKey,
              profile: profile(for: publicKey),
              isSending: sendingPublicKey == publicKey,
              action: {
                sendShare(to: publicKey)
              }
            )
          }
        }
      }

      if !fallbackProfiles.isEmpty {
        Section("Suggestions") {
          ForEach(fallbackProfiles, id: \.publicKey) { profile in
            ShareRecipientRow(
              publicKey: profile.publicKey,
              profile: profile,
              isSending: sendingPublicKey == profile.publicKey,
              action: {
                sendShare(to: profile.publicKey)
              }
            )
          }
        }
      }
    } else {
      let results = displayedRecipients

      if !results.isEmpty {
        Section("Profiles") {
          ForEach(results, id: \.publicKey) { profile in
            ShareRecipientRow(
              publicKey: profile.publicKey,
              profile: profile,
              isSending: sendingPublicKey == profile.publicKey,
              action: {
                sendShare(to: profile.publicKey)
              }
            )
          }
        }
      } else if pastedPublicKey == nil {
        Section {
          VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
              .font(.system(size: 32, weight: .regular))
              .foregroundColor(.secondary)

            Text("No Match")
              .font(.headline)

            Text("Use a full npub, or search cached profiles.")
              .font(.subheadline)
              .foregroundColor(.secondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 280)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 28)
        }
        .listRowBackground(Color.clear)
      }
    }
  }

  private var displayedRecipients: [RUserProfile] {
    profileResults.filter {
      $0.publicKey != activePublicKey && $0.publicKey != pastedPublicKey
    }
  }

  private func scheduleSearch() {
    searchTask?.cancel()

    let query = normalizedSearchText
    guard activePublicKey != nil,
      pastedPublicKey == nil,
      query.count >= 2
    else {
      profileResults = []
      return
    }

    searchTask = Task {
      try? await Task.sleep(for: .milliseconds(160))
      guard !Task.isCancelled else { return }

      await MainActor.run {
        refreshProfileResults(for: query)
      }
    }
  }

  private func refreshSuggestions() {
    refreshRecentRecipients()
    refreshFollowing()
    refreshCachedSuggestions()
  }

  private func refreshRecentRecipients() {
    guard let activePublicKey else {
      recentRecipientPublicKeys = []
      return
    }

    let currentUserPublicKey = activePublicKey
    var descriptor = FetchDescriptor<RDirectMessage>(
      predicate: #Predicate { message in
        message.senderPublicKey == currentUserPublicKey
      },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = 160

    let messages = (try? modelContext.fetch(descriptor)) ?? []
    var seen = Set<String>()
    var recipients: [String] = []

    for message in messages {
      let recipientPublicKey = message.recipientPublicKey
      guard recipientPublicKey != currentUserPublicKey,
        seen.insert(recipientPublicKey).inserted
      else {
        continue
      }

      recipients.append(recipientPublicKey)
      if recipients.count == 8 { break }
    }

    recentRecipientPublicKeys = recipients
  }

  private func refreshFollowing() {
    guard let activePublicKey else {
      followingPublicKeys = []
      return
    }

    let currentUserPublicKey = activePublicKey
    var descriptor = FetchDescriptor<RContactList>(
      predicate: #Predicate { contactList in
        contactList.publicKey == currentUserPublicKey
      }
    )
    descriptor.fetchLimit = 1

    guard let contactList = try? modelContext.fetch(descriptor).first else {
      followingPublicKeys = []
      return
    }

    var seen = Set<String>()
    followingPublicKeys = Array(
      contactList.following
        .map(\.publicKey)
        .filter { publicKey in
          publicKey != currentUserPublicKey && seen.insert(publicKey).inserted
        }
        .prefix(30)
    )
  }

  private func refreshCachedSuggestions() {
    var descriptor = FetchDescriptor<RUserProfile>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = 120

    suggestions = ((try? modelContext.fetch(descriptor)) ?? [])
      .filter { profile in
        profile.publicKey != activePublicKey && profileHasMetadata(profile)
      }
      .sorted {
        profileSortTitle($0).localizedCaseInsensitiveCompare(profileSortTitle($1))
          == .orderedAscending
      }
  }

  private func refreshProfileResults(for query: String) {
    var descriptor = FetchDescriptor<RUserProfile>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = 180

    let profiles = (try? modelContext.fetch(descriptor)) ?? []
    profileResults = Array(
      profiles
        .filter { profile in
          guard profile.publicKey != activePublicKey else { return false }
          let npub = bech32_pubkey(profile.publicKey) ?? ""
          return profile.name.lowercased().contains(query)
            || profile.about.lowercased().contains(query)
            || profile.publicKey.lowercased().contains(query)
            || npub.lowercased().contains(query)
        }
        .sorted {
          profileSortTitle($0).localizedCaseInsensitiveCompare(profileSortTitle($1))
            == .orderedAscending
        }
        .prefix(20)
    )
  }

  private func profile(for publicKey: String) -> RUserProfile? {
    if let profile = suggestions.first(where: { $0.publicKey == publicKey })
      ?? profileResults.first(where: { $0.publicKey == publicKey })
    {
      return profile
    }

    let targetPublicKey = publicKey
    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == targetPublicKey }
    )
    descriptor.fetchLimit = 1

    return try? modelContext.fetch(descriptor).first
  }

  private func sendShare(to peerPublicKey: String) {
    guard sendingPublicKey == nil else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex,
      let currentUserPublicKey = privkey_to_pubkey(privkey: privateKeyHex)
    else {
      showKeyGenerator = true
      return
    }

    let relayURLs = activeRelayURLs()
    guard !relayURLs.isEmpty else {
      errorMessage = "Enable at least one relay before sending."
      return
    }

    errorMessage = nil
    sendingPublicKey = peerPublicKey

    let message: MessagingPlaintextMessage
    do {
      message = try messagingService.buildDirectMessage(
        currentUserPublicKey: currentUserPublicKey,
        peerPublicKey: peerPublicKey,
        content: shareMessage
      )
    } catch {
      sendingPublicKey = nil
      errorMessage = (error as? MessagingError)?.userMessage ?? "Message could not be prepared."
      return
    }

    guard saveOptimisticMessage(
      message,
      currentUserPublicKey: currentUserPublicKey,
      peerPublicKey: peerPublicKey
    ) else {
      sendingPublicKey = nil
      errorMessage = "Message could not be saved on this device."
      return
    }

    publishInboxRelayList(privateKeyHex: privateKeyHex, relayURLs: relayURLs)
    dismiss()
    onOpenChat(peerPublicKey)

    messagingService.send(
      MessagingSendRequest(
        message: message,
        senderPrivateKeyHex: privateKeyHex,
        relayURLs: relayURLs
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

          updateMessage(
            rumorId: message.id,
            deliveryState: "failed",
            errorMessage: failureMessage,
            wrapEventIds: sendFailure?.wrapEventIds ?? []
          )
          EfimerousManager.shared.showMessage(failureMessage)
        }
      }
    }
  }

  private func activeRelayURLs() -> [URL] {
    NostrData.shared.storedRelays.ensureDefaultRelays()
    return NostrData.shared.storedRelays.activeRelayAddresses.compactMap { URL(string: $0) }
  }

  private func publishInboxRelayList(privateKeyHex: String, relayURLs: [URL]) {
    messagingService.publishInboxRelayList(
      privateKeyHex: privateKeyHex,
      relayURLs: relayURLs
    ) { _ in }
  }

  private func saveOptimisticMessage(
    _ message: MessagingPlaintextMessage,
    currentUserPublicKey: String,
    peerPublicKey: String
  ) -> Bool {
    if existingMessage(rumorId: message.id) != nil {
      return true
    }

    let directMessage = RDirectMessage(
      id: UUID().uuidString,
      rumorId: message.id,
      conversationID: RDirectMessage.conversationID(currentUserPublicKey, peerPublicKey),
      peerPubkey: peerPublicKey,
      senderPublicKey: currentUserPublicKey,
      recipientPublicKey: peerPublicKey,
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
    try? modelContext.save()
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

  private func mergedWrapEventIds(_ current: [String], _ incoming: [String]) -> [String] {
    var result = current

    for id in incoming where !id.isEmpty && !result.contains(id) {
      result.append(id)
    }

    return result
  }

  private func profileHasMetadata(_ profile: RUserProfile) -> Bool {
    profile.name.isValidName()
      || !profile.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !profile.picture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func profileSortTitle(_ profile: RUserProfile) -> String {
    if profile.name.isValidName() {
      return profile.name
    }

    return bech32_pubkey(profile.publicKey) ?? profile.publicKey
  }
}

private struct ShareRecipientRow: View {
  let publicKey: String
  let profile: RUserProfile?
  let isSending: Bool
  let action: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(publicKey: publicKey, url: profile?.avatarUrl, size: 42)

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

      Spacer(minLength: 8)

      Button(action: action) {
        if isSending {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "paperplane.fill")
            .font(.system(size: 16, weight: .semibold))
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(isSending)
      .accessibilityLabel("Send")
    }
    .padding(.vertical, 4)
  }

  private var displayName: String {
    MessagingProfileText.displayName(for: profile, publicKey: publicKey)
  }

  private var shortPublicKey: String {
    (bech32_pubkey(publicKey) ?? publicKey).accordionString(index: 10)
  }
}

private extension String {
  func trimmingPrefix(_ prefix: String) -> String {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
  }
}

private struct LikeControlLabel: View {
  private static let likeColor = Color(
    red: 254.0 / 255.0,
    green: 1.0 / 255.0,
    blue: 51.0 / 255.0
  )

  let isLiked: Bool
  let isPublishing: Bool
  let count: Int

  @State private var fillAmount: CGFloat = 0
  @State private var isPulsing = false

  var body: some View {
    HStack(spacing: 2) {
      heartIcon

      if count > 0 {
        Text(compactCount)
          .font(.subheadline.weight(.light))
          .monospacedDigit()
          .foregroundColor(isLiked ? Self.likeColor : .secondary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .frame(minWidth: count > 0 ? 58 : 36, minHeight: 36, maxHeight: 36, alignment: .leading)
    .contentShape(Rectangle())
    .onAppear {
      fillAmount = isLiked ? 1 : 0
      updatePulse(isPublishing)
    }
    .onChange(of: isLiked) { _, newValue in
      withAnimation(.easeOut(duration: 0.14)) {
        fillAmount = newValue ? 1 : 0
      }
    }
    .onChange(of: isPublishing) { _, newValue in
      updatePulse(newValue)
    }
  }

  private var heartIcon: some View {
    ZStack {
      Image(systemName: "heart")
        .font(.system(size: 17, weight: .regular))
        .foregroundColor(isLiked ? Self.likeColor.opacity(0.35) : .secondary)

      Image(systemName: "heart.fill")
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(Self.likeColor)
        .mask {
          GeometryReader { proxy in
            VStack(spacing: 0) {
              Spacer(minLength: 0)
              Rectangle()
                .frame(width: proxy.size.width, height: proxy.size.height * fillAmount)
            }
          }
        }
    }
    .frame(width: 24, height: 24)
    .scaleEffect(isPublishing ? (isPulsing ? 1.12 : 0.96) : (isLiked ? 1.04 : 1))
  }

  private var compactCount: String {
    Self.compactCount(count)
  }

  private func updatePulse(_ shouldPulse: Bool) {
    guard shouldPulse else {
      withAnimation(.spring(response: 0.18, dampingFraction: 0.76)) {
        isPulsing = false
      }
      return
    }

    isPulsing = false
    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
      isPulsing = true
    }
  }

  private static func compactCount(_ count: Int) -> String {
    let suffixes = ["", "K", "M", "B"]
    var value = Double(count)
    var suffixIndex = 0

    while value >= 1_000 && suffixIndex < suffixes.count - 1 {
      value /= 1_000
      suffixIndex += 1
    }

    if suffixIndex == 0 {
      return "\(count)"
    }

    let formattedValue =
      value.truncatingRemainder(dividingBy: 1) == 0
      ? String(format: "%.0f", value)
      : String(format: "%.1f", value)

    return "\(formattedValue)\(suffixes[suffixIndex])"
  }
}

struct EventPresentationModel {
  let contentFormatted: AttributedString?
  let contentWithoutImageLinks: AttributedString?
  let imageUrls: [URL]
  let videoUrl: URL?
  let linkPreview: LinkPreviewDescriptor?
}

private final class EventPresentationBox {
  let value: EventPresentationModel

  init(_ value: EventPresentationModel) {
    self.value = value
  }
}

final class EventRenderCache {
  static let shared = EventRenderCache()

  private static let maximumCost = 12 * 1_024 * 1_024
  private let cache = NSCache<NSString, EventPresentationBox>()

  private init() {
    cache.countLimit = 64
    cache.totalCostLimit = Self.maximumCost
  }

  func removeAll() {
    cache.removeAllObjects()
  }

  func rendered(for textNote: RTextNote) -> EventPresentationModel {
    rendered(id: textNote.eventId, content: textNote.content)
  }

  func rendered(for event: EventViewModel) -> EventPresentationModel {
    rendered(id: event.id, content: event.content)
  }

  private func rendered(id: String, content: String) -> EventPresentationModel {
    let cacheKey = id as NSString
    if let cached = cache.object(forKey: cacheKey) {
      return cached.value
    }

    let rendered = render(content: content)
    let contentCost = max(content.utf8.count * 4, 1)
    cache.setObject(EventPresentationBox(rendered), forKey: cacheKey, cost: contentCost)
    return rendered
  }

  private func render(content: String) -> EventPresentationModel {
    guard !content.isEmpty else {
      return EventPresentationModel(
        contentFormatted: nil,
        contentWithoutImageLinks: nil,
        imageUrls: [],
        videoUrl: nil,
        linkPreview: nil
      )
    }

    let displayContent = NostrInlineText.displayContent(content)
    let parsedAttributed = try? AttributedString(
      markdown: displayContent,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )

    guard let parsedAttributed else {
      return EventPresentationModel(
        contentFormatted: nil,
        contentWithoutImageLinks: nil,
        imageUrls: [],
        videoUrl: nil,
        linkPreview: nil
      )
    }

    let attributed = applyingInlineActionsAndEmphasis(to: parsedAttributed)
    var contentWithoutImageLinks = AttributedString()
    var imageUrls: [URL] = []
    var videoUrl: URL?
    var linkPreview: LinkPreviewDescriptor?

    for run in attributed.runs {
      let slice = attributed[run.range]

      guard let link = run.link else {
        contentWithoutImageLinks.append(slice)
        continue
      }

      let absoluteURL = link.absoluteURL
      if absoluteURL.isImageType() {
        imageUrls.append(absoluteURL)
        continue
      }

      if videoUrl == nil, absoluteURL.isVideoType() {
        videoUrl = absoluteURL
        contentWithoutImageLinks.append(slice)
        continue
      }

      if linkPreview == nil, let detectedLink = LinkPreviewDescriptor.detect(url: absoluteURL) {
        linkPreview = detectedLink
        continue
      }

      contentWithoutImageLinks.append(slice)
    }

    return EventPresentationModel(
      contentFormatted: attributed,
      contentWithoutImageLinks: contentWithoutImageLinks,
      imageUrls: imageUrls,
      videoUrl: videoUrl,
      linkPreview: linkPreview
    )
  }

  private func applyingInlineActionsAndEmphasis(to attributed: AttributedString) -> AttributedString {
    let plainText = String(attributed.characters)
    let ranges = NostrInlineText.emphasisRanges(in: plainText)
    let mentionTargets = NostrInlineText.profileMentionTargets(in: plainText)

    guard !ranges.isEmpty || !mentionTargets.isEmpty else {
      return attributed
    }

    var emphasized = attributed

    for textRange in ranges {
      guard let start = AttributedString.Index(textRange.lowerBound, within: emphasized),
        let end = AttributedString.Index(textRange.upperBound, within: emphasized)
      else {
        continue
      }

      emphasized[start..<end].font = .body.weight(.semibold)
    }

    for target in mentionTargets {
      guard let start = AttributedString.Index(target.range.lowerBound, within: emphasized),
        let end = AttributedString.Index(target.range.upperBound, within: emphasized),
        let url = NostrInlineText.profileURL(for: target.publicKey)
      else {
        continue
      }

      emphasized[start..<end].link = url
    }

    return emphasized
  }
}

private struct EventMediaSkeleton: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.secondary.opacity(0.12))

      Image(systemName: "photo")
        .font(.system(size: 24, weight: .regular))
        .foregroundColor(.secondary.opacity(0.45))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct EventFullscreenMediaItem: Identifiable, Equatable {
  enum Kind: Equatable {
    case image
    case video
  }

  let id: String
  let url: URL
  let kind: Kind

  static func image(url: URL) -> EventFullscreenMediaItem {
    EventFullscreenMediaItem(id: "image-\(url.absoluteString)", url: url, kind: .image)
  }

  static func video(url: URL) -> EventFullscreenMediaItem {
    EventFullscreenMediaItem(id: "video-\(url.absoluteString)", url: url, kind: .video)
  }

  var isAnimatedImage: Bool {
    ["gif", "webp", "svg"].contains(url.pathExtension.lowercased())
  }
}

private struct EventFullscreenMediaViewer: View {
  let item: EventFullscreenMediaItem
  let onDismiss: () -> Void

  @GestureState private var inspectionState = EventMediaInspectionState.inactive

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Color.black
        .ignoresSafeArea()

      GeometryReader { proxy in
        mediaContent(size: proxy.size)
          .frame(width: proxy.size.width, height: proxy.size.height)
          .scaleEffect(isInspecting ? 2.15 : 1, anchor: .center)
          .offset(clampedOffset(in: proxy.size))
          .animation(.spring(response: 0.2, dampingFraction: 0.82), value: inspectionState)
          .gesture(inspectionGesture)
          .accessibilityHidden(true)
      }
      .ignoresSafeArea()

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.primary)
          .frame(width: 34, height: 34)
          .background(.ultraThinMaterial, in: Circle())
      }
      .buttonStyle(.plain)
      .padding(.top, 12)
      .padding(.trailing, 14)
      .opacity(isInspecting ? 0 : 1)
      .animation(.easeOut(duration: 0.12), value: isInspecting)
      .accessibilityLabel("Close")
    }
    .statusBarHidden(true)
  }

  @ViewBuilder
  private func mediaContent(size: CGSize) -> some View {
    switch item.kind {
    case .image:
      if item.isAnimatedImage {
        AnimatedImage(url: item.url)
          .placeholder { EventMediaSkeleton() }
          .resizable()
          .scaledToFill()
          .frame(width: size.width, height: size.height)
          .clipped()
      } else {
        KFImage(item.url)
          .placeholder { EventMediaSkeleton() }
          .resizable()
          .cacheOriginalImage()
          .transition(.fade(duration: 0.16))
          .scaledToFill()
          .frame(width: size.width, height: size.height)
          .clipped()
      }

    case .video:
      EventFullscreenVideoPlayer(url: item.url)
        .frame(width: size.width, height: size.height)
        .clipped()
    }
  }

  private var isInspecting: Bool {
    inspectionState.isActive
  }

  private var inspectionGesture: some Gesture {
    LongPressGesture(minimumDuration: 0.16, maximumDistance: 14)
      .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
      .updating($inspectionState) { value, state, _ in
        switch value {
        case .first(true):
          state = .pressing
        case .second(true, let dragValue):
          state = .dragging(dragValue?.translation ?? .zero)
        default:
          state = .inactive
        }
      }
  }

  private func clampedOffset(in size: CGSize) -> CGSize {
    guard case .dragging(let translation) = inspectionState else {
      return .zero
    }

    let maxX = size.width * 0.42
    let maxY = size.height * 0.42
    return CGSize(
      width: min(max(translation.width, -maxX), maxX),
      height: min(max(translation.height, -maxY), maxY)
    )
  }
}

private enum EventMediaInspectionState: Equatable {
  case inactive
  case pressing
  case dragging(CGSize)

  var isActive: Bool {
    switch self {
    case .inactive:
      return false
    case .pressing, .dragging:
      return true
    }
  }
}

private struct EventFullscreenVideoPlayer: UIViewRepresentable {
  let url: URL

  func makeUIView(context: Context) -> PlayerView {
    let view = PlayerView()
    view.playerLayer.videoGravity = .resizeAspectFill
    view.playerLayer.player = context.coordinator.player
    context.coordinator.player.play()
    return view
  }

  func updateUIView(_ uiView: PlayerView, context: Context) {
    if uiView.playerLayer.player !== context.coordinator.player {
      uiView.playerLayer.player = context.coordinator.player
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(url: url)
  }

  static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
    coordinator.player.pause()
    uiView.playerLayer.player = nil
  }

  final class Coordinator {
    let player: AVPlayer

    init(url: URL) {
      self.player = AVPlayer(url: url)
    }
  }

  final class PlayerView: UIView {
    override static var layerClass: AnyClass {
      AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
      layer as! AVPlayerLayer
    }
  }
}

private struct EventVideoAttachment: View {
  let url: URL
  var onOpenFullscreen: (() -> Void)?

  @State private var player: AVPlayer?

  var body: some View {
    ZStack {
      if let player {
        VideoPlayer(player: player)
          .onAppear {
            player.play()
          }
      } else {
        ZStack {
          EventMediaSkeleton()

          Image(systemName: "play.circle.fill")
            .font(.system(size: 42, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
          if let onOpenFullscreen {
            onOpenFullscreen()
            return
          }

          let nextPlayer = AVPlayer(url: url)
          player = nextPlayer
          nextPlayer.play()
        }
      }
    }
    .onDisappear {
      player?.pause()
      player = nil
    }
  }
}

private struct EventAttachmentPlaceholder: View {
  let count: Int
  let isSensitive: Bool
  let reason: String
  let includesVideo: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color.secondary.opacity(0.12))

        VStack(spacing: 7) {
          Image(systemName: iconName)
            .font(.system(size: 30, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundColor(isSensitive ? .orange : .secondary)

          if isSensitive {
            Text("Sensitive")
              .font(.caption.weight(.semibold))
              .foregroundColor(.orange)
              .lineLimit(1)
          }
        }

        if count > 1 {
          Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundColor(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
      }
    }
    .buttonStyle(.plain)
    .aspectRatio(4 / 3, contentMode: .fit)
    .frame(maxWidth: .infinity, alignment: .leading)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Loads hidden media.")
  }

  private var accessibilityLabel: String {
    if isSensitive {
      let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedReason.isEmpty ? "Sensitive attachment hidden" : trimmedReason
    }

    if includesVideo {
      return "Video attachment hidden"
    }

    return count > 1 ? "\(count) attachments hidden" : "Attachment hidden"
  }

  private var iconName: String {
    includesVideo ? "play.circle" : "arrow.down.circle"
  }
}
