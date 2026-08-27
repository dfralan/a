// a

import SwiftUI

enum KeyCreationMode: String, CaseIterable, Identifiable {
  case generate
  case importExisting

  var id: Self { self }

  var title: String {
    switch self {
    case .generate: return "Generate"
    case .importExisting: return "Import"
    }
  }

  var helpText: String {
    switch self {
    case .generate:
      return "Create a fresh private key on this device."
    case .importExisting:
      return "Paste an existing npub or nsec key."
    }
  }
}

private enum KeyCopyTarget {
  case generatedPublicKey
  case generatedPrivateKey
  case importedPublicKey
}

struct KeyGen: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject var keyManager: KeyManager
  @FocusState private var focusedField: FocusedField?

  @State private var mode: KeyCreationMode
  @State private var generatedKeypair = Keypair(pubkey: "", privkey: nil)
  @State private var importKey = ""
  @State private var showsGeneratedPrivateKey = false
  @State private var showsImportedKey = false
  @State private var copiedTarget: KeyCopyTarget?
  @State private var confirmationKey = ""
  @State private var confirmationText = ""
  @State private var didLoadPendingKeypair = false
  @State private var isGeneratingKeypair = false
  @State private var isSavingKey = false

  private enum FocusedField {
    case importKey
  }

  init(initialMode: KeyCreationMode = .generate) {
    _mode = State(initialValue: initialMode)
  }

  private var generatedPrivateKey: String? {
    generatedKeypair.privkey_bech32
  }

  private var normalizedImportKey: String? {
    keyManager.normalizedKey(importKey)
  }

  private var activeKey: String? {
    switch mode {
    case .generate:
      return generatedPrivateKey
    case .importExisting:
      return normalizedImportKey
    }
  }

  private var activePublicKey: String? {
    switch mode {
    case .generate:
      return generatedKeypair.pubkey_bech32.isEmpty ? nil : generatedKeypair.pubkey_bech32
    case .importExisting:
      guard let normalizedImportKey else { return nil }
      return keyManager.publicKey(for: normalizedImportKey)
    }
  }

  private var activeKeyIsStored: Bool {
    guard let activeKey else { return false }
    return keyManager.storedKeys.contains(activeKey)
  }

  private var activeKeyIsSelected: Bool {
    guard let activeKey else { return false }
    return keyManager.selectedKey == activeKey
  }

  private var primaryButtonTitle: String {
    guard activeKey != nil else { return "Save Key" }
    if activeKeyIsStored {
      return activeKeyIsSelected ? "Selected" : "Use Key"
    }
    return "Save Key"
  }

  private var primaryButtonIsDisabled: Bool {
    isSavingKey || isGeneratingKeypair || activeKey == nil || (activeKeyIsStored && activeKeyIsSelected)
  }

  private var activeConfirmationText: String? {
    guard let activeKey, confirmationKey == activeKey else { return nil }
    return confirmationText
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        modeSelector

        List {
          if mode == .generate {
            generatedKeyContent
          } else {
            importKeyContent
          }

          if let activePublicKey {
            Section {
              identityPreview(publicKey: activePublicKey)
              if mode == .importExisting {
                keyValueRow(
                  title: "Public Key",
                  value: activePublicKey.accordionString(index: 14),
                  copyValue: activePublicKey,
                  copyTarget: .importedPublicKey
                )
              }
            } header: {
              Text("Preview")
            }
          }
        }
        .listStyle(.insetGrouped)
      }
      .navigationTitle("Add Key")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        primaryActionBar
      }
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          if mode == .generate {
            Button {
              regenerateKeypair()
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .disabled(isGeneratingKeypair)
          }
        }
      }
      .onAppear {
        keyManager.loadKeys()
        loadPendingKeypairIfNeeded()
        if mode == .importExisting {
          DispatchQueue.main.async {
            focusedField = .importKey
          }
        }
      }
      .onChange(of: mode) { _, _ in
        resetTransientState()
        if mode == .importExisting {
          focusedField = .importKey
        } else {
          focusedField = nil
          loadPendingKeypairIfNeeded()
        }
      }
      .onChange(of: importKey) { _, _ in
        clearConfirmation()
        copiedTarget = nil
      }
    }
  }

  private var modeSelector: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("Key creation mode", selection: $mode) {
        ForEach(KeyCreationMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      Text(mode.helpText)
        .font(.footnote)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .padding(.bottom, 10)
    .background(Color(.systemGroupedBackground))
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private var primaryActionBar: some View {
    VStack(spacing: 8) {
      Button {
        saveOrSelectActiveKey()
      } label: {
        Text(primaryButtonTitle)
          .fontWeight(.semibold)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(primaryButtonIsDisabled)

      if let activeConfirmationText {
        Label(activeConfirmationText, systemImage: "checkmark.circle.fill")
          .font(.footnote)
          .foregroundColor(.secondary)
      } else {
        Text("Saved keys are stored in Keychain and appear in the sidebar.")
          .font(.footnote)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 10)
    .background(.regularMaterial)
    .overlay(alignment: .top) {
      Divider()
    }
  }

  private var generatedKeyContent: some View {
    Section {
      keyValueRow(
        title: "Public Key",
        value: generatedKeypair.pubkey_bech32.accordionString(index: 14),
        copyValue: generatedKeypair.pubkey_bech32,
        copyTarget: .generatedPublicKey
      )

      privateKeyRow
    } header: {
      Text("New Key")
    } footer: {
      Text("The public key can be shared. Keep the private key private.")
    }
  }

  private var importKeyContent: some View {
    Section {
      HStack(spacing: 8) {
        Group {
          if showsImportedKey {
            TextField("npub1... or nsec1...", text: $importKey)
          } else {
            SecureField("npub1... or nsec1...", text: $importKey)
          }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($focusedField, equals: .importKey)

        if !importKey.isEmpty {
          Button {
            importKey = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.borderless)
        }

        Button {
          showsImportedKey.toggle()
        } label: {
          Image(systemName: showsImportedKey ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
      }

      importValidationRow
    } header: {
      Text("Existing Key")
    } footer: {
      Text("Use an nsec private key to post. An npub public key is read-only.")
    }
  }

  private var privateKeyRow: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Private Key")
        Text(generatedPrivateKeyDisplayText)
          .font(.caption.monospaced())
          .foregroundColor(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Button {
        showsGeneratedPrivateKey.toggle()
      } label: {
        Image(systemName: showsGeneratedPrivateKey ? "eye.slash" : "eye")
      }
      .buttonStyle(.borderless)

      if showsGeneratedPrivateKey, let generatedPrivateKey {
        copyButton(value: generatedPrivateKey, target: .generatedPrivateKey)
      }
    }
    .padding(.vertical, 2)
  }

  private var generatedPrivateKeyDisplayText: String {
    guard let generatedPrivateKey else { return "Unavailable" }
    return showsGeneratedPrivateKey ? generatedPrivateKey.accordionString(index: 14) : "Hidden"
  }

  @ViewBuilder
  private var importValidationRow: some View {
    if importKey.isEmpty {
      Label("Waiting for a key.", systemImage: "info.circle")
        .font(.footnote)
        .foregroundColor(.secondary)
    } else if let normalizedImportKey {
      Label(
        keyManager.storedKeys.contains(normalizedImportKey)
          ? "This key is already saved."
          : "\(keyManager.keyKindDescription(for: normalizedImportKey)) ready.",
        systemImage: "checkmark.circle"
      )
      .font(.footnote)
      .foregroundColor(.secondary)
    } else {
      Label("Enter a valid npub or nsec key.", systemImage: "exclamationmark.triangle")
        .font(.footnote)
        .foregroundColor(.red)
    }
  }

  private func keyValueRow(
    title: String,
    value: String,
    copyValue: String,
    copyTarget: KeyCopyTarget
  ) -> some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
        Text(value)
          .font(.caption.monospaced())
          .foregroundColor(.secondary)
          .lineLimit(1)
      }

      Spacer()

      copyButton(value: copyValue, target: copyTarget)
    }
    .padding(.vertical, 2)
  }

  private func copyButton(value: String, target: KeyCopyTarget) -> some View {
    Button {
      UIPasteboard.general.string = value
      copiedTarget = target
      EfimerousManager.shared.showMessage("Copied")

      DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
        if copiedTarget == target {
          copiedTarget = nil
        }
      }
    } label: {
      Label(
        copiedTarget == target ? "Copied" : "Copy",
        systemImage: copiedTarget == target ? "checkmark" : "doc.on.doc"
      )
    }
    .buttonStyle(.borderless)
  }

  private func identityPreview(publicKey: String) -> some View {
    HStack(spacing: 12) {
      AvatarView(publicKey: publicKey, size: 56)

      VStack(alignment: .leading, spacing: 4) {
        Text(mode == .generate ? "New Identity" : "Imported Identity")
          .font(.headline)
        Text(publicKey.accordionString(index: 12))
          .font(.caption.monospaced())
          .foregroundColor(.secondary)
          .lineLimit(1)
        if let activeKey {
          Label(keyManager.keyKindDescription(for: activeKey), systemImage: "key.horizontal")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Spacer()
    }
    .padding(.vertical, 4)
  }

  private func saveOrSelectActiveKey() {
    guard let activeKey, !isSavingKey else { return }
    guard let keyToStore = keyManager.normalizedKey(activeKey) else {
      EfimerousManager.shared.showMessage("Could not save key")
      return
    }

    isSavingKey = true
    focusedField = nil

    let manager = keyManager
    let keyAlreadyStored = manager.storedKeys.contains(keyToStore)

    dismiss()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
      if keyAlreadyStored {
        manager.selectKey(keyToStore)
        EfimerousManager.shared.showMessage("Key selected")
      } else if manager.saveKey(keyToStore) {
        EfimerousManager.shared.showMessage("Key saved")
      } else {
        EfimerousManager.shared.showMessage("Could not save key")
      }
    }
  }

  private func regenerateKeypair() {
    guard !isGeneratingKeypair else { return }

    isGeneratingKeypair = true
    let newKeypair = generate_new_keypair()

    guard newKeypair.privkey_bech32 != nil, !newKeypair.pubkey_bech32.isEmpty else {
      isGeneratingKeypair = false
      EfimerousManager.shared.showMessage("Could not generate key")
      return
    }

    withAnimation(.spring(response: 0.2, dampingFraction: 0.8, blendDuration: 0.2)) {
      generatedKeypair = newKeypair
      showsGeneratedPrivateKey = false
      resetTransientState()
    }
    isGeneratingKeypair = false
  }

  private func loadPendingKeypairIfNeeded() {
    guard !didLoadPendingKeypair else { return }
    didLoadPendingKeypair = true
    if keyManager.pendingKeypair.privkey_bech32 != nil,
      !keyManager.pendingKeypair.pubkey_bech32.isEmpty
    {
      generatedKeypair = keyManager.pendingKeypair
    } else {
      regenerateKeypair()
    }
  }

  private func resetTransientState() {
    copiedTarget = nil
    clearConfirmation()
  }

  private func clearConfirmation() {
    confirmationKey = ""
    confirmationText = ""
  }

  private func setConfirmation(_ text: String) {
    guard let activeKey else { return }
    confirmationKey = activeKey
    confirmationText = text
  }
}

struct KeyGenerator_Previews: PreviewProvider {
  static var previews: some View {
    KeyGen()
      .environmentObject(KeyManager())
  }
}
