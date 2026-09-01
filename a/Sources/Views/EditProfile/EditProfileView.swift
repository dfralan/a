import Foundation
import NostrKit
import SwiftData
import SwiftUI

struct EditProfileView: View {

  let publicKey: String

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var keyManager: KeyManager
  @EnvironmentObject private var nostrData: NostrData
  @Query private var userProfiles: [RUserProfile]

  @State private var usernameInput = ""
  @State private var aboutInput = ""
  @State private var nip05Input = ""
  @State private var isSaving = false
  @State private var isCheckingNIP05 = false
  @State private var didEditFields = false
  @State private var nip05CheckStatus: NIP05VerificationStatus?
  @State private var nip05CheckURL: URL?
  @State private var nip05CheckTask: Task<Void, Never>?

  init(publicKey: String) {
    self.publicKey = publicKey

    let profilePublicKey = publicKey
    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == profilePublicKey }
    )
    descriptor.fetchLimit = 1
    _userProfiles = Query(descriptor)
  }

  init(userProfile: RUserProfile) {
    self.init(publicKey: userProfile.publicKey)
  }

  var body: some View {
    Form {
      Section {
        HStack {
          Text("Name")
          TextField("name", text: usernameBinding)
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }

        VStack(alignment: .leading, spacing: 8) {
          Text("Description")
          TextField("About you", text: aboutBinding, axis: .vertical)
            .lineLimit(3...7)
        }
      } footer: {
        footerText
      }

      Section {
        HStack {
          Text("NIP-05")
          TextField("name@example.com", text: nip05Binding)
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .autocorrectionDisabled()
        }

        if !normalizedNIP05.isEmpty {
          nip05VerificationRow
        }
      } footer: {
        nip05FooterText
      }
    }
    .navigationTitle("Edit Profile")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button {
          saveProfile()
        } label: {
          if isSaving {
            ProgressView()
          } else {
            Text("Save")
          }
        }
        .disabled(!canSave)
      }
    }
    .onAppear {
      seedFieldsIfNeeded()
    }
    .onChange(of: userProfile.createdAt) { _, _ in
      seedFieldsIfNeeded()
    }
    .onDisappear {
      nip05CheckTask?.cancel()
    }
  }

  private var userProfile: RUserProfile {
    userProfiles.first ?? RUserProfile.createEmpty(withPublicKey: publicKey)
  }

  private var usernameBinding: Binding<String> {
    Binding(
      get: { usernameInput },
      set: {
        usernameInput = $0
        didEditFields = true
      }
    )
  }

  private var aboutBinding: Binding<String> {
    Binding(
      get: { aboutInput },
      set: {
        aboutInput = $0
        didEditFields = true
      }
    )
  }

  private var nip05Binding: Binding<String> {
    Binding(
      get: { nip05Input },
      set: {
        nip05Input = $0
        didEditFields = true
        resetNIP05Check()
      }
    )
  }

  private var normalizedUsername: String {
    let trimmed = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
  }

  private var normalizedAbout: String {
    aboutInput.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var normalizedNIP05: String {
    let trimmed = nip05Input
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    guard !trimmed.isEmpty else { return "" }
    guard !trimmed.contains("@"), trimmed.contains(".") else {
      return trimmed
    }

    return "_@\(trimmed)"
  }

  private var parsedNIP05: NIP05? {
    NIP05.parse(normalizedNIP05)
  }

  private var usernameIsValid: Bool {
    normalizedUsername.isEmpty || normalizedUsername.isValidName()
  }

  private var nip05IsValid: Bool {
    normalizedNIP05.isEmpty || parsedNIP05 != nil
  }

  private var hasChanges: Bool {
    normalizedUsername != userProfile.name
      || normalizedAbout != userProfile.about
      || normalizedNIP05 != userProfile.nip05
  }

  private var selectedSigningPublicKey: String? {
    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else { return nil }
    return privkey_to_pubkey(privkey: privateKeyHex)
  }

  private var canSignCurrentProfile: Bool {
    selectedSigningPublicKey == publicKey
  }

  private var canSave: Bool {
    usernameIsValid && nip05IsValid && hasChanges && canSignCurrentProfile && !isSaving
  }

  @ViewBuilder
  private var footerText: some View {
    if !canSignCurrentProfile {
      Text("A private key is required to publish profile changes.")
    } else if !usernameIsValid {
      Text("Use letters, numbers, underscores, or hyphens.")
    }
  }

  @ViewBuilder
  private var nip05FooterText: some View {
    if !nip05IsValid {
      Text("Use name@domain.com, or domain.com to save _@domain.com.")
    } else {
      Text("Your domain must return this public key from /.well-known/nostr.json. The badge appears after it validates.")
    }
  }

  @ViewBuilder
  private var nip05VerificationRow: some View {
    if !nip05IsValid {
      Label("Invalid identifier", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
    } else {
      Button {
        checkNIP05()
      } label: {
        HStack {
          Label("Check Verification", systemImage: nip05VerificationSystemImage)
          Spacer()

          if isCheckingNIP05 {
            ProgressView()
          } else if let nip05CheckStatus {
            Text(nip05CheckStatusLabel(for: nip05CheckStatus))
              .foregroundStyle(nip05CheckStatus == .verified ? .green : .secondary)
          } else if let parsedNIP05 {
            Text(parsedNIP05.displayIdentifier)
              .foregroundStyle(.secondary)
          }
        }
      }
      .disabled(isCheckingNIP05)

      if let nip05CheckURL {
        Link(destination: nip05CheckURL) {
          Label("Proof URL", systemImage: "link")
        }
        .font(.subheadline)
      }
    }
  }

  private func seedFieldsIfNeeded() {
    guard !didEditFields else { return }

    usernameInput = userProfile.name
    aboutInput = userProfile.about
    nip05Input = userProfile.nip05
  }

  @MainActor
  private func saveProfile() {
    guard canSave else { return }

    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else {
      EfimerousManager.shared.showMessage("Private key required")
      return
    }

    let relayUrls = selectedRelayURLs()
    guard !relayUrls.isEmpty else {
      EfimerousManager.shared.showMessage("Select at least one relay")
      return
    }

    do {
      isSaving = true
      let draft = NIP01.profileMetadata(
        name: normalizedUsername,
        about: normalizedAbout,
        picture: userProfile.picture,
        nip05: normalizedNIP05
      )
      let profileEvent = try PostEventContent(privateKeyHex: privateKeyHex, draft: draft)

      publish(profileEvent, to: relayUrls)
    } catch {
      isSaving = false
      EfimerousManager.shared.showMessage("Couldn't save profile")
    }
  }

  private func selectedRelayURLs() -> [URL] {
    NostrData.shared.storedRelays.activeRelayAddresses.compactMap { URL(string: $0) }
  }

  private func publish(_ profileEvent: PostEventContent, to relayUrls: [URL]) {
    var completedCount = 0
    var failedCount = 0
    var didPersistAcceptedEvent = false

    for relayUrl in relayUrls {
      profileEvent.sendToNostr(relayUrl: relayUrl) { result in
        Task { @MainActor in
          completedCount += 1

          switch result {
          case .success:
            if !didPersistAcceptedEvent {
              didPersistAcceptedEvent = nostrData.persistPublishedProfileMetadata(profileEvent.event)
            }
          case .failure:
            failedCount += 1
          }

          guard completedCount == relayUrls.count else { return }
          finishSaving(
            relayCount: relayUrls.count,
            failedCount: failedCount,
            didPersistAcceptedEvent: didPersistAcceptedEvent
          )
        }
      }
    }
  }

  @MainActor
  private func finishSaving(
    relayCount: Int,
    failedCount: Int,
    didPersistAcceptedEvent: Bool
  ) {
    isSaving = false

    guard failedCount < relayCount else {
      EfimerousManager.shared.showMessage("Couldn't save profile")
      return
    }

    if didPersistAcceptedEvent {
      EfimerousManager.shared.showMessage("Profile updated")
    } else {
      EfimerousManager.shared.showMessage("Profile saved. Sync pending")
    }

    didEditFields = false
    usernameInput = normalizedUsername
    aboutInput = normalizedAbout
    nip05Input = normalizedNIP05
    dismiss()
  }

  private var nip05VerificationSystemImage: String {
    switch nip05CheckStatus {
    case .verified:
      return "checkmark.seal.fill"
    case .invalid:
      return "xmark.seal"
    case .checking:
      return "checkmark.seal"
    case .unchecked, .none:
      return "checkmark.seal"
    }
  }

  private func nip05CheckStatusLabel(for status: NIP05VerificationStatus) -> String {
    switch status {
    case .verified:
      return "Verified"
    case .invalid:
      return "Not Found"
    case .checking:
      return "Checking"
    case .unchecked:
      return "Ready"
    }
  }

  private func resetNIP05Check() {
    nip05CheckTask?.cancel()
    nip05CheckTask = nil
    nip05CheckStatus = nil
    nip05CheckURL = parsedNIP05?.url
    isCheckingNIP05 = false
  }

  @MainActor
  private func checkNIP05() {
    guard let parsedNIP05 else { return }

    let identifier = normalizedNIP05
    nip05CheckTask?.cancel()
    isCheckingNIP05 = true
    nip05CheckStatus = .checking
    nip05CheckURL = parsedNIP05.url

    nip05CheckTask = Task {
      let result = await NIP05Verifier.verify(publicKey: publicKey, nip05: identifier)

      await MainActor.run {
        guard normalizedNIP05 == identifier else { return }

        isCheckingNIP05 = false
        nip05CheckStatus = result?.status ?? .invalid
        nip05CheckURL = result?.verificationURL ?? parsedNIP05.url

        if result?.isVerified == true {
          EfimerousManager.shared.showMessage("NIP-05 verified")
        } else {
          EfimerousManager.shared.showMessage("NIP-05 not configured yet")
        }
      }
    }
  }
}
