// a

import SwiftData
import SwiftUI

struct NewChat: View {
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject var keyManager: KeyManager

  @State private var searchText = ""
  @State private var profileResults: [RUserProfile] = []
  @State private var profileSearchTask: Task<Void, Never>?
  @State private var showKeyGenerator = false

  var body: some View {
    List {
      if activePublicKey == nil {
        noKeySection
      } else {
        recipientInputSection
        directRecipientSection
        profileResultsSection
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("New Message")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: searchText) { _, _ in
      scheduleProfileSearch()
    }
    .onDisappear {
      profileSearchTask?.cancel()
    }
    .sheet(isPresented: $showKeyGenerator) {
      KeyGen(initialMode: .generate)
        .environmentObject(keyManager)
    }
  }

  private var activePublicKey: String? {
    guard let privateKeyHex = keyManager.selectedPrivateKeyHex else { return nil }
    return privkey_to_pubkey(privkey: privateKeyHex)
  }

  private var trimmedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var pastedPublicKey: String? {
    let normalized = trimmedSearchText.lowercased()
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

  @ViewBuilder
  private var noKeySection: some View {
    Section {
      VStack(spacing: 14) {
        Image(systemName: "key")
          .font(.system(size: 34, weight: .regular))
          .foregroundColor(.secondary)

        Text("Add a Key")
          .font(.title3.weight(.semibold))

        Text("Save a private key before starting encrypted conversations.")
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

  private var recipientInputSection: some View {
    Section("Recipient") {
      TextField("npub or public key", text: $searchText, axis: .vertical)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .lineLimit(1...3)
    }
  }

  @ViewBuilder
  private var directRecipientSection: some View {
    if let pastedPublicKey {
      Section("Direct") {
        NavigationLink {
          ChatView(publicKey: pastedPublicKey)
        } label: {
          MessagingProfileRow(profile: profileForPublicKey(pastedPublicKey))
        }
      }
    }
  }

  @ViewBuilder
  private var profileResultsSection: some View {
    let filteredResults = profileResults.filter { $0.publicKey != pastedPublicKey }

    if !filteredResults.isEmpty {
      Section("Recent Matches") {
        ForEach(filteredResults, id: \.publicKey) { profile in
          NavigationLink {
            ChatView(publicKey: profile.publicKey)
          } label: {
            MessagingProfileRow(profile: profile)
          }
        }
      }
    } else if trimmedSearchText.isEmpty {
      Section {
        VStack(spacing: 12) {
          Image(systemName: "person.crop.circle.badge.plus")
            .font(.system(size: 32, weight: .regular))
            .foregroundColor(.secondary)

          Text("Add Recipient")
            .font(.headline)

          Text("Paste an npub to start a private conversation.")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
      }
      .listRowBackground(Color.clear)
    } else if pastedPublicKey == nil {
      Section {
        VStack(spacing: 12) {
          Image(systemName: "person.crop.circle.badge.questionmark")
            .font(.system(size: 32, weight: .regular))
            .foregroundColor(.secondary)

          Text("No Match")
            .font(.headline)

          Text("Use a full npub or open a profile and tap Message.")
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

  private func scheduleProfileSearch() {
    profileSearchTask?.cancel()

    let query = trimmedSearchText.lowercased()
    guard activePublicKey != nil,
      pastedPublicKey == nil,
      query.count >= 3
    else {
      profileResults = []
      return
    }

    profileSearchTask = Task {
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }

      await MainActor.run {
        refreshProfileResults(for: query)
      }
    }
  }

  private func refreshProfileResults(for query: String) {
    var descriptor = FetchDescriptor<RUserProfile>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = 80

    let profiles = (try? modelContext.fetch(descriptor)) ?? []
    profileResults = Array(
      profiles
        .filter { profile in
          guard profile.publicKey != activePublicKey else { return false }
          let npub = bech32_pubkey(profile.publicKey) ?? ""
          return profile.name.lowercased().contains(query)
            || profile.publicKey.lowercased().contains(query)
            || npub.lowercased().contains(query)
        }
        .sorted {
          profileSortTitle($0).localizedCaseInsensitiveCompare(profileSortTitle($1))
            == .orderedAscending
        }
        .prefix(12)
    )
  }

  private func profileForPublicKey(_ publicKey: String) -> RUserProfile {
    if let profile = profileResults.first(where: { $0.publicKey == publicKey }) {
      return profile
    }

    var descriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == publicKey }
    )
    descriptor.fetchLimit = 1

    if let profile = try? modelContext.fetch(descriptor).first {
      return profile
    }

    return RUserProfile.createEmpty(withPublicKey: publicKey)
  }

  private func profileSortTitle(_ profile: RUserProfile) -> String {
    if profile.name.isValidName() {
      return profile.name
    }

    return bech32_pubkey(profile.publicKey) ?? profile.publicKey
  }
}

struct NewChat_Previews: PreviewProvider {
  static var previews: some View {
    NavigationStack {
      NewChat()
        .environmentObject(KeyManager())
    }
  }
}
