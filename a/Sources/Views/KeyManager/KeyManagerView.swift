// a

import SwiftData
import SwiftUI

// MARK: - Key Manager View

struct KeyManagerView: View {
  @EnvironmentObject var keyManager: KeyManager

  @State private var showDeleteAllKeysAlert = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          NavigationLink {
            KeyGen(initialMode: .generate)
          } label: {
            Label("Create New Key", systemImage: "plus.circle")
          }

          NavigationLink {
            KeyGen(initialMode: .importExisting)
          } label: {
            Label("Import Existing Key", systemImage: "square.and.arrow.down")
          }
        } footer: {
          Text("Keys are saved in this device's Keychain.")
        }

        Section {
          if keyManager.storedKeys.isEmpty {
            Label("No saved keys", systemImage: "key")
              .foregroundColor(.secondary)
          } else {
            ForEach(keyManager.storedKeys, id: \.self) { key in
              NavigationLink {
                KeyDetailView(key: key)
              } label: {
                StoredKeyRow(key: key)
              }
            }
            .onDelete(perform: deleteKeys)
          }
        } header: {
          Text("Wallets")
        } footer: {
          Text("Open a wallet to view details or make it active. Swipe left or use Edit to delete.")
        }

        if !keyManager.storedKeys.isEmpty {
          Section {
            Button(role: .destructive) {
              showDeleteAllKeysAlert = true
            } label: {
              Label("Delete All Keys", systemImage: "trash")
            }
          }
        }
      }
      .navigationTitle("Keys")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          if !keyManager.storedKeys.isEmpty {
            EditButton()
          }
        }
      }
      .onAppear {
        keyManager.loadKeys()
      }
      .alert(isPresented: $showDeleteAllKeysAlert) {
        Alert(
          title: Text("Delete All Keys?"),
          message: Text("This removes every saved key from this device. Make sure you have a backup before deleting private keys."),
          primaryButton: .destructive(Text("Delete All")) {
            keyManager.deleteAllKeys()
          },
          secondaryButton: .cancel()
        )
      }
    }
  }

  private func deleteKeys(at offsets: IndexSet) {
    let keysToDelete = offsets.map { keyManager.storedKeys[$0] }
    keysToDelete.forEach { keyManager.deleteKey($0) }
  }
}

private enum StoredKeyCopyTarget {
  case publicKey
  case publicKeyHex
  case privateKey
}

private struct StoredKeyRow: View {
  @EnvironmentObject var keyManager: KeyManager
  @Query private var userProfiles: [RUserProfile]

  let key: String

  private var publicKey: String {
    keyManager.publicKey(for: key) ?? key
  }

  private var publicKeyHex: String? {
    keyManager.publicKeyHex(for: key)
  }

  private var userProfile: RUserProfile? {
    guard let publicKeyHex else { return nil }
    return userProfiles.first { $0.publicKey == publicKeyHex }
  }

  private var avatarURL: URL? {
    userProfile?.avatarUrl
  }

  private var displayName: String {
    if let name = userProfile?.name, name.isValidName() {
      return name
    }

    return "Anonymous"
  }

  private var isSelected: Bool {
    keyManager.selectedKey == key
  }

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(publicKey: publicKey, url: avatarURL, size: 40)

      VStack(alignment: .leading, spacing: 3) {
        Text(displayName)
          .font(.body)
        HStack(spacing: 4) {
          Text(keyManager.keyKindDescription(for: key))
          Text(publicKey.accordionString(index: 10))
            .font(.caption.monospaced())
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
      }

      Spacer()

      if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.accentColor)
      }
    }
    .contentShape(Rectangle())
    .padding(.vertical, 3)
  }
}

private struct KeyDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject var keyManager: KeyManager
  @Query private var userProfiles: [RUserProfile]

  let key: String

  @State private var showsPrivateKey = false
  @State private var copiedTarget: StoredKeyCopyTarget?
  @State private var isSelectingKey = false
  @State private var isAuthenticatingPrivateKey = false

  private var publicKey: String {
    keyManager.publicKey(for: key) ?? key
  }

  private var publicKeyHex: String? {
    keyManager.publicKeyHex(for: key)
  }

  private var userProfile: RUserProfile? {
    guard let publicKeyHex else { return nil }
    return userProfiles.first { $0.publicKey == publicKeyHex }
  }

  private var avatarURL: URL? {
    userProfile?.avatarUrl
  }

  private var displayName: String {
    if let name = userProfile?.name, name.isValidName() {
      return name
    }

    return "Anonymous"
  }

  private var isSelected: Bool {
    keyManager.selectedKey == key
  }

  private var hasPrivateKey: Bool {
    guard let decoded = decode_bech32_key(key) else { return false }
    if case .sec = decoded {
      return true
    }
    return false
  }

  var body: some View {
    Form {
      Section {
        VStack(spacing: 12) {
          AvatarView(publicKey: publicKey, url: avatarURL, size: 112)
            .padding(.top, 10)

          VStack(spacing: 4) {
            Text(displayName)
              .font(.title3)
              .fontWeight(.semibold)

            Text(keyManager.keyKindDescription(for: key))
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
      }

      Section {
        keyValueRow(
          title: "Public Key",
          value: publicKey.accordionString(index: 14),
          copyValue: publicKey,
          target: .publicKey
        )

        if let publicKeyHex {
          keyValueRow(
            title: "Public Key Hex",
            value: publicKeyHex.accordionString(index: 14),
            copyValue: publicKeyHex,
            target: .publicKeyHex
          )
        }
      } header: {
        Text("Identity")
      } footer: {
        Text("The public key identifies this account and can be shared.")
      }

      if hasPrivateKey {
        Section {
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Private Key")
              Text(showsPrivateKey ? key.accordionString(index: 14) : "Hidden")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button {
              togglePrivateKeyVisibility()
            } label: {
              if isAuthenticatingPrivateKey {
                ProgressView()
                  .controlSize(.small)
              } else {
                Image(systemName: showsPrivateKey ? "eye.slash" : "eye")
              }
            }
            .buttonStyle(.borderless)
            .disabled(isAuthenticatingPrivateKey)

            if showsPrivateKey {
              copyButton(value: key, target: .privateKey)
            }
          }
          .padding(.vertical, 2)
        } header: {
          Text("Signing")
        } footer: {
          Text("Keep the private key private. Anyone with it can use this account.")
        }
      }

      Section {
        Button {
          selectThisKey()
        } label: {
          Text(isSelectingKey ? "Unlocking" : isSelected ? "Selected" : "Use This Key")
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected || isSelectingKey ? .secondary : .accentColor)
        .disabled(isSelected || isSelectingKey)
      }
    }
    .navigationTitle("Wallet")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func keyValueRow(
    title: String,
    value: String,
    copyValue: String,
    target: StoredKeyCopyTarget
  ) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
        Text(value)
          .font(.caption.monospaced())
          .foregroundColor(.secondary)
          .lineLimit(1)
      }

      Spacer()

      copyButton(value: copyValue, target: target)
    }
    .padding(.vertical, 2)
  }

  private func copyButton(value: String, target: StoredKeyCopyTarget) -> some View {
    Button {
      if target == .privateKey {
        authenticatePrivateKeyAccess {
          copyValue(value, target: target)
        }
      } else {
        copyValue(value, target: target)
      }
    } label: {
      Label(
        copiedTarget == target ? "Copied" : "Copy",
        systemImage: copiedTarget == target ? "checkmark" : "doc.on.doc"
      )
    }
    .buttonStyle(.borderless)
    .disabled(target == .privateKey && isAuthenticatingPrivateKey)
  }

  private func selectThisKey() {
    guard !isSelected && !isSelectingKey else { return }

    isSelectingKey = true

    Task {
      let didAuthenticate = await KeyAccessAuthenticator.authenticate(
        reason: "Unlock this key to make it active."
      )

      await MainActor.run {
        isSelectingKey = false

        guard didAuthenticate else {
          EfimerousManager.shared.showMessage("Authentication canceled")
          return
        }

        dismiss()
        keyManager.selectKey(key)
      }
    }
  }

  private func togglePrivateKeyVisibility() {
    if showsPrivateKey {
      showsPrivateKey = false
      return
    }

    authenticatePrivateKeyAccess {
      showsPrivateKey = true
    }
  }

  private func authenticatePrivateKeyAccess(then action: @escaping () -> Void) {
    guard !isAuthenticatingPrivateKey else { return }

    isAuthenticatingPrivateKey = true

    Task {
      let didAuthenticate = await KeyAccessAuthenticator.authenticate(
        reason: "Unlock the private key."
      )

      await MainActor.run {
        isAuthenticatingPrivateKey = false

        guard didAuthenticate else {
          EfimerousManager.shared.showMessage("Authentication canceled")
          return
        }

        action()
      }
    }
  }

  private func copyValue(_ value: String, target: StoredKeyCopyTarget) {
    UIPasteboard.general.string = value
    copiedTarget = target
    EfimerousManager.shared.showMessage("Copied")

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
      if copiedTarget == target {
        copiedTarget = nil
      }
    }
  }
}

struct KeychainView_Previews: PreviewProvider {
  static var previews: some View {
    KeyManagerView()
      .environmentObject(KeyManager())
  }
}
