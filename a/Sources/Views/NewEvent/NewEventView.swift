import Foundation
import NostrKit
import SwiftUI
import SwiftData
import UIKit

struct NewEventView: View {
    @State private var selectedPostingOptions: Set<String> = []
    @State private var newEvent = ""
    @State private var includeSensitiveContent = false
    @State private var sensitiveContentReason = ""
    @State private var isPosting = false

    // TOOLBAR STATE
    @StateObject var toolbarState = ToolbarState()
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var coordinator: Coordinator
    @EnvironmentObject var keyManager: KeyManager
    @Query private var userProfiles: [RUserProfile]

    var body: some View {
        VStack {
            HStack {
                Button {
                    presentationMode.wrappedValue.dismiss()
                    print("Dismiss event!")
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Task {
                        await postEvent()
                    }
                } label: {
                    ZStack {
                        Text("Post")
                            .opacity(isPosting ? 0 : 1)

                        if isPosting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.secondary)
                        }
                    }
                }
                .buttonStyle(ComposerPostButtonStyle())
                .disabled(!hasPostContent || isPosting)
            }
            ScrollView {
                HStack(alignment: .top) {
                    AvatarView(
                        publicKey: composerPublicKey,
                        url: composerAvatarURL,
                        size: 70
                    )
                    VStack(alignment: .leading, spacing: 10) {
                        NostrComposerInput(text: $newEvent, placeholder: "Share something")
                            .frame(minHeight: 150, alignment: .top)

                        ComposerMentionPreviewList(
                            publicKeys: detectedMentionPublicKeys,
                            profile: profile
                        )
                    }
                }
            }
            Spacer()
            PostingOn(
                selectedOptions: $selectedPostingOptions,
                includeSensitiveContent: $includeSensitiveContent,
                sensitiveContentReason: $sensitiveContentReason
            )
        }
        .padding()
        .onAppear {
            NostrData.shared.storedRelays.ensureDefaultRelays()
        }
    }

    private var trimmedEventContent: String {
        newEvent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasPostContent: Bool {
        !trimmedEventContent.isEmpty
    }

    private var detectedMentionPublicKeys: [String] {
        NostrInlineText.profileMentionPublicKeys(in: newEvent)
    }

    private var composerPublicKey: String {
        guard let publicKeyHex = selectedPublicKeyHex else {
            return keyManager.pendingPublicKey
        }

        return bech32_pubkey(publicKeyHex) ?? publicKeyHex
    }

    private var composerAvatarURL: URL? {
        guard let publicKeyHex = selectedPublicKeyHex else { return nil }
        return userProfiles.first { $0.publicKey == publicKeyHex }?.avatarUrl
    }

    private func profile(for publicKey: String) -> RUserProfile? {
        userProfiles.first { $0.publicKey == publicKey }
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

    @MainActor
    private func postEvent() async {
        guard hasPostContent, !isPosting else { return }

        guard let privateKeyHex = keyManager.selectedPrivateKeyHex else {
            EfimerousManager.shared.showMessage("Save a private key to post")
            return
        }

        let relayUrls = selectedRelayURLs()
        guard !relayUrls.isEmpty else {
            EfimerousManager.shared.showMessage("Select at least one relay")
            return
        }

        do {
            isPosting = true
            let draft = NIP01.textNote(
                content: trimmedEventContent,
                isSensitive: includeSensitiveContent,
                sensitiveReason: sensitiveContentReason
            )
            let postEvent = try PostEventContent(privateKeyHex: privateKeyHex, draft: draft)
            let fallbackPostEvent: PostEventContent?

            if draft.nips.contains(.nip27) {
                let fallbackDraft = NIP01.textNote(
                    content: trimmedEventContent,
                    isSensitive: includeSensitiveContent,
                    sensitiveReason: sensitiveContentReason,
                    parseProfileMentions: false
                )
                fallbackPostEvent = try PostEventContent(
                    privateKeyHex: privateKeyHex,
                    draft: fallbackDraft
                )
            } else {
                fallbackPostEvent = nil
            }

            publish(postEvent, to: relayUrls, fallbackPostEvent: fallbackPostEvent)
        } catch {
            isPosting = false
            if savePendingPost() {
                EfimerousManager.shared.showMessage("Post saved. \(shortErrorMessage(error))")
            } else {
                EfimerousManager.shared.showMessage(shortErrorMessage(error))
            }
        }
    }

    private func selectedRelayURLs() -> [URL] {
        let relayAddresses =
            selectedPostingOptions.isEmpty
            ? NostrData.shared.storedRelays.activeRelayAddresses
            : Array(selectedPostingOptions)

        return relayAddresses.compactMap { URL(string: $0) }
    }

    private func publish(
        _ postEvent: PostEventContent,
        to relayUrls: [URL],
        fallbackPostEvent: PostEventContent? = nil
    ) {
        var completedCount = 0
        var failedCount = 0
        var didPersistAcceptedEvent = false
        var didCompleteComposer = false
        var firstFailureMessage: String?

        print(
            "[Post] SEND event=\(postEvent.event.id.prefix(8)) relays=\(relayUrls.count) contentLength=\(postEvent.content.count)"
        )

        for relayUrl in relayUrls {
            postEvent.sendToNostr(relayUrl: relayUrl) { result in
                Task { @MainActor in
                    completedCount += 1

                    switch result {
                    case .success:
                        print(
                            "[Post] ACCEPT event=\(postEvent.event.id.prefix(8)) relay=\(relayUrl.absoluteString)"
                        )
                        if !didPersistAcceptedEvent {
                            didPersistAcceptedEvent = NostrData.shared.persistPublishedTextNote(
                                postEvent.event
                            )
                        }

                        if !didCompleteComposer {
                            didCompleteComposer = true
                            finishPostingSuccess()
                        }
                    case .failure(let error):
                        failedCount += 1
                        print(
                            "[Post] REJECT event=\(postEvent.event.id.prefix(8)) relay=\(relayUrl.absoluteString) reason=\(shortErrorMessage(error))"
                        )
                        if firstFailureMessage == nil {
                            firstFailureMessage = shortErrorMessage(error)
                        }
                    }

                    guard completedCount == relayUrls.count else { return }
                    guard !didCompleteComposer else { return }

                    if failedCount == relayUrls.count, let fallbackPostEvent {
                        print("[Post] RETRY event=\(postEvent.event.id.prefix(8)) mode=plain-text")
                        publish(fallbackPostEvent, to: relayUrls)
                        return
                    }

                    finishPostingFailure(firstFailureMessage: firstFailureMessage)
                }
            }
        }
    }

    @MainActor
    private func finishPostingSuccess() {
        isPosting = false
        EfimerousManager.shared.showMessage("Posted")

        newEvent = ""
        includeSensitiveContent = false
        sensitiveContentReason = ""
        presentationMode.wrappedValue.dismiss()
    }

    @MainActor
    private func finishPostingFailure(firstFailureMessage: String?) {
        isPosting = false
        savePendingPost()

        if let firstFailureMessage {
            EfimerousManager.shared.showMessage("Post saved. \(firstFailureMessage)")
        } else {
            EfimerousManager.shared.showMessage("Post saved to retry")
        }
    }

    @discardableResult
    private func savePendingPost() -> Bool {
        guard !trimmedEventContent.isEmpty else {
            return false
        }

        let pendingPost = PendingPost(
            content: trimmedEventContent,
            timestamp: Date(),
            isSensitiveContent: includeSensitiveContent,
            sensitiveContentReason: sensitiveContentReason.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.insert(pendingPost)
        try? modelContext.save()
        return true
    }

    private func shortErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return "Could not post"
        }

        guard message.count > 140 else {
            return message
        }

        return "\(message.prefix(140))..."
    }
}

private struct ComposerPostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(
                isEnabled ? Color(uiColor: .systemBackground) : Color(uiColor: .secondaryLabel)
            )
            .frame(minWidth: 58, minHeight: 34)
            .padding(.horizontal, 4)
            .background(
                isEnabled ? Color.primary : Color(uiColor: .secondarySystemFill),
                in: Capsule()
            )
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct NostrComposerInput: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }

            NostrComposerTextView(text: $text)
        }
    }
}

private struct NostrComposerTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.keyboardDismissMode = .interactive
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        context.coordinator.applyHighlighting(to: textView, text: text)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.adjustsFontForContentSizeCategory = true

        guard textView.text != text else {
            context.coordinator.applyHighlighting(to: textView, text: text)
            return
        }

        context.coordinator.applyHighlighting(to: textView, text: text)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NostrComposerTextView
        private var isApplyingAttributes = false

        init(parent: NostrComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingAttributes else { return }

            parent.text = textView.text
            guard textView.markedTextRange == nil else { return }
            applyHighlighting(to: textView, text: textView.text)
        }

        func applyHighlighting(to textView: UITextView, text: String) {
            let selectedRange = textView.selectedRange
            let contentOffset = textView.contentOffset
            let font = textView.font ?? .preferredFont(forTextStyle: .body)

            isApplyingAttributes = true
            textView.attributedText = Self.attributedString(
                for: text,
                font: font,
                textColor: textView.textColor ?? .label
            )
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: textView.textColor ?? .label,
            ]
            textView.selectedRange = Self.clampedRange(selectedRange, length: textView.attributedText.length)
            textView.setContentOffset(contentOffset, animated: false)
            isApplyingAttributes = false
        }

        private static func attributedString(
            for text: String,
            font: UIFont,
            textColor: UIColor
        ) -> NSAttributedString {
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                ]
            )

            let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
            let boldFont = UIFont(descriptor: descriptor, size: font.pointSize)

            for range in NostrInlineText.emphasisRanges(in: text) {
                attributed.addAttribute(
                    .font,
                    value: boldFont,
                    range: NSRange(range, in: text)
                )
            }

            return attributed
        }

        private static func clampedRange(_ range: NSRange, length: Int) -> NSRange {
            let location = min(range.location, length)
            let remainingLength = max(0, length - location)
            return NSRange(location: location, length: min(range.length, remainingLength))
        }
    }
}

private struct ComposerMentionPreviewList: View {
    let publicKeys: [String]
    let profile: (String) -> RUserProfile?

    var body: some View {
        if !publicKeys.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(publicKeys, id: \.self) { publicKey in
                    ComposerMentionPreviewRow(
                        publicKey: publicKey,
                        profile: profile(publicKey)
                    )
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

private struct ComposerMentionPreviewRow: View {
    let publicKey: String
    let profile: RUserProfile?

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(publicKey: publicKey, url: profile?.avatarUrl, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(shortPublicKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("Mention")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName), mention")
    }

    private var displayName: String {
        MessagingProfileText.displayName(for: profile, publicKey: publicKey)
    }

    private var shortPublicKey: String {
        (bech32_pubkey(publicKey) ?? publicKey).accordionString(index: 10)
    }
}

// Model for pending posts
@Model
final class PendingPost {
    var content: String
    var timestamp: Date
    var isSensitiveContent: Bool = false
    var sensitiveContentReason: String = ""

    init(
        content: String,
        timestamp: Date,
        isSensitiveContent: Bool = false,
        sensitiveContentReason: String = ""
    ) {
        self.content = content
        self.timestamp = timestamp
        self.isSensitiveContent = isSensitiveContent
        self.sensitiveContentReason = sensitiveContentReason
    }
}


struct NewEventView_Previews: PreviewProvider {
  static var previews: some View {
    NewEventView()
      .environmentObject(Coordinator())
      .environmentObject(KeyManager())
  }
}

//BLURRED SHEET

extension View {
  // MARK: Custom View Modifier
  func blurredSheet<Content: View>(
    _ style: AnyShapeStyle, show: Binding<Bool>,
    onDismiss:
      @escaping () -> Void, @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    self
      .sheet(isPresented: show, onDismiss: onDismiss) {
        content()
          .background(RemovebackgroundColor())
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background {
            Rectangle()
              .fill(style)
              .ignoresSafeArea(.container, edges: .all)
          }
      }
  }
}

// MARK: Helper View
struct RemovebackgroundColor: UIViewRepresentable {
  func makeUIView(context: Context) -> UIView {
    return UIView()
  }
  func updateUIView(_ uiView: UIView, context: Context) {
    DispatchQueue.main.async {
      uiView.superview?.superview?.backgroundColor = .clear
    }
  }
}
