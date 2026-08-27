// a

import Kingfisher
import SDWebImageSwiftUI
import SwiftUI

// MARK: - Settings View

struct SettingsView: View {

  // MARK: - Properties

  /// Main coordinator observable class with app storaged properties
  @EnvironmentObject var coordinator: Coordinator
  @EnvironmentObject var nostrData: NostrData

  @State private var playNotificationSounds = false

  @State private var sendReadReceipts = false
  @State private var isClearingImageCache = false
  @State private var isWipingLocalData = false
  @State private var showWipeDataConfirmation = false
  @State private var showProviderManager = false
  @ObservedObject private var fileCloudProviders = FileCloudProviderStore.shared

  var body: some View {
    List {

      // Accessibility selection
      Section(header: Text("App Font Size")) {
        VStack {

          HStack {
            Text("aA")
              .font(.system(size: 14))
            Slider(
              value: selectedFontSizeBinding,
              in: 0...CGFloat(Coordinator.FontSize.allCases.count - 1),
              step: 1
            )
            Text("aA")
              .font(.system(size: 26))
          }
        }
      }

      // Saturation section
      Section(header: Text("Saturation")) {
        Slider(value: saturationBinding, in: 0.00...0.99, step: 0.01)
      }

      // Appearance section
      Section(header: Text("Appearance")) {

        Picker("Select a theme", selection: themeModeBinding) {
          Text("Auto").tag(0)
          Text("Light").tag(1)
          Text("Dark").tag(2)
        }
        .pickerStyle(SegmentedPickerStyle())

        accentColorSelector
      }

      // Notifications section
      Section(header: Text("Notifications")) {

        settingsMenu(
          title: "Notify Me About",
          selectedTitle: notifyMeAboutTitle,
          options: [
            (0, "Messages"),
            (1, "Mentions"),
            (2, "Anything"),
          ],
          selection: notifyMeAboutBinding
        )

        Toggle("Play notification sounds", isOn: $playNotificationSounds)

        Toggle("Send read receipts", isOn: $sendReadReceipts)

      }

      // Storage section
      Section(
        header: Text("Media Safety"),
        footer: Text("Ask First keeps attachments from downloading until you load them. Sensitive Only loads regular media automatically and asks before sensitive media. Blur still applies after media is loaded.")
      ) {
        settingsMenu(
          title: "Load Attachments",
          selectedTitle: coordinator.attachmentLoadingModeTitle,
          options: [
            (Coordinator.AttachmentLoadingMode.askFirst.rawValue, Coordinator.AttachmentLoadingMode.askFirst.title),
            (
              Coordinator.AttachmentLoadingMode.sensitiveOnly.rawValue,
              Coordinator.AttachmentLoadingMode.sensitiveOnly.title
            ),
            (
              Coordinator.AttachmentLoadingMode.automatically.rawValue,
              Coordinator.AttachmentLoadingMode.automatically.title
            ),
          ],
          selection: attachmentLoadingModeBinding
        )

        Toggle("Always blur loaded media", isOn: $coordinator.blurredImages)

        Toggle("Blur sensitive media", isOn: $coordinator.blurSensitiveMedia)
      }

      Section(
        header: Text("Storage"),
        footer: Text("Wipe Local Data clears cached events, profiles, contact lists, pending posts, and logs. Keys and relays stay saved.")
      ) {

        Button {
          clearImageCache()
        } label: {
          HStack {
            Label("Clear Image Cache", systemImage: "photo.stack")
            Spacer()
            if isClearingImageCache {
              ProgressView()
            }
          }
        }
        .disabled(isClearingImageCache)

        Button(role: .destructive) {
          showWipeDataConfirmation = true
        } label: {
          HStack {
            Label("Wipe Local Data", systemImage: "trash")
            Spacer()
            if isWipingLocalData {
              ProgressView()
            }
          }
        }
        .disabled(isWipingLocalData)
      }

      Section(header: Text("PREFERENCES")) {
        fileCloudProviderSelector

        Button {
          showProviderManager = true
        } label: {
          Label("Manage File Providers", systemImage: "externaldrive")
        }
      }
    }
    .tint(coordinator.accentColorSwitcher)
    .accentColor(coordinator.accentColorSwitcher)
    .sheet(isPresented: $showProviderManager) {
      NavigationStack {
        FileCloudProviderManagerView(providerStore: fileCloudProviders)
      }
    }
    .confirmationDialog(
      "Wipe Local Data?",
      isPresented: $showWipeDataConfirmation,
      titleVisibility: .visible
    ) {
      Button("Wipe Local Data", role: .destructive) {
        wipeLocalData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Cached Nostr data will be removed from this device. Your keys and relays will not be deleted.")
    }
  }

  private func clearImageCache() {
    guard !isClearingImageCache else { return }

    isClearingImageCache = true
    clearImageCaches {
      isClearingImageCache = false
      EfimerousManager.shared.showMessage("Image cache cleared")
    }
  }

  private var themeModeBinding: Binding<Int> {
    Binding(
      get: { coordinator.themeMode },
      set: { coordinator.setThemeMode($0) }
    )
  }

  private var accentColorBinding: Binding<Int> {
    Binding(
      get: { coordinator.accentColor },
      set: { coordinator.setAccentColor($0) }
    )
  }

  private var notifyMeAboutBinding: Binding<Int> {
    Binding(
      get: { coordinator.notifyMeAbout },
      set: { coordinator.setNotifyMeAbout($0) }
    )
  }

  private var attachmentLoadingModeBinding: Binding<Int> {
    Binding(
      get: { coordinator.attachmentLoadingMode },
      set: { coordinator.setAttachmentLoadingMode($0) }
    )
  }

  private var saturationBinding: Binding<Double> {
    Binding(
      get: { coordinator.saturationColor },
      set: { coordinator.setSaturationColor($0) }
    )
  }

  private var selectedFontSizeBinding: Binding<CGFloat> {
    Binding(
      get: { coordinator.selectedFontSizeValue },
      set: { coordinator.selectedFontSizeValue = $0 }
    )
  }

  private var notifyMeAboutTitle: String {
    switch coordinator.notifyMeAbout {
    case 1: return "Mentions"
    case 2: return "Anything"
    default: return "Messages"
    }
  }

  private var cloudServiceTitle: String {
    fileCloudProviders.selectedProviderTitle
  }

  private var fileCloudProviderSelector: some View {
    Menu {
      ForEach(fileCloudProviders.enabledProviders) { provider in
        Button {
          fileCloudProviders.select(provider)
        } label: {
          if fileCloudProviders.selectedProvider?.id == provider.id {
            Label(provider.title, systemImage: "checkmark")
          } else {
            Text(provider.title)
          }
        }
      }
    } label: {
      HStack {
        Label("File Upload Provider", systemImage: "externaldrive")
          .foregroundColor(.primary)

        Spacer()

        Text(cloudServiceTitle)
          .foregroundColor(coordinator.accentColorSwitcher)

        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundColor(coordinator.accentColorSwitcher.opacity(0.85))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(fileCloudProviders.enabledProviders.isEmpty)
  }

  private var accentColorSelector: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Accent Color", systemImage: "circle.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(coordinator.accentColorSwitcher, .secondary)

        Spacer()

        Text(coordinator.accentColorTitle)
          .foregroundColor(.secondary)
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 34), spacing: 12)],
        alignment: .leading,
        spacing: 12
      ) {
        ForEach(Coordinator.AccentColorOption.allCases) { option in
          accentColorSwatch(option)
        }
      }
      .padding(.vertical, 2)
    }
  }

  private func accentColorSwatch(_ option: Coordinator.AccentColorOption) -> some View {
    Button {
      accentColorBinding.wrappedValue = option.rawValue
    } label: {
      ZStack {
        Circle()
          .fill(option.color)
          .frame(width: 28, height: 28)

        if coordinator.accentColor == option.rawValue {
          Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
        }
      }
      .padding(3)
      .overlay {
        Circle()
          .stroke(
            coordinator.accentColor == option.rawValue
              ? option.color
              : Color.secondary.opacity(0.22),
            lineWidth: coordinator.accentColor == option.rawValue ? 2 : 1
          )
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(option.title)
    .accessibilityValue(coordinator.accentColor == option.rawValue ? "Selected" : "")
  }

  private func settingsMenu(
    title: String,
    selectedTitle: String,
    options: [(Int, String)],
    selection: Binding<Int>
  ) -> some View {
    Menu {
      ForEach(options.indices, id: \.self) { index in
        let option = options[index]
        Button {
          selection.wrappedValue = option.0
        } label: {
          if selection.wrappedValue == option.0 {
            Label(option.1, systemImage: "checkmark")
          } else {
            Text(option.1)
          }
        }
      }
    } label: {
      HStack {
        Text(title)
          .foregroundColor(.primary)

        Spacer()

        Text(selectedTitle)
          .foregroundColor(coordinator.accentColorSwitcher)

        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundColor(coordinator.accentColorSwitcher.opacity(0.85))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func wipeLocalData() {
    guard !isWipingLocalData else { return }

    isWipingLocalData = true
    clearImageCaches {
      let didWipeData = nostrData.wipeLocalDataPreservingKeysAndRelays()
      isWipingLocalData = false
      EfimerousManager.shared.showMessage(didWipeData ? "Local data wiped" : "Couldn't wipe data")
    }
  }

  private func clearImageCaches(completion: @escaping () -> Void) {
    let group = DispatchGroup()

    ImageCache.default.clearMemoryCache()
    group.enter()
    ImageCache.default.clearDiskCache {
      group.leave()
    }

    SDImageCache.shared.clearMemory()
    group.enter()
    SDImageCache.shared.clearDisk {
      group.leave()
    }

    URLCache.shared.removeAllCachedResponses()

    group.notify(queue: .main) {
      completion()
    }
  }
}

private struct FileCloudProviderManagerView: View {
  @ObservedObject var providerStore: FileCloudProviderStore
  @Environment(\.dismiss) private var dismiss
  @State private var editingProvider: FileCloudProvider?
  @State private var showResetConfirmation = false

  var body: some View {
    List {
      Section {
        if providerStore.enabledProviders.isEmpty {
          Text("No active providers")
            .foregroundColor(.secondary)
        } else {
          ForEach(providerStore.enabledProviders) { provider in
            Button {
              providerStore.select(provider)
            } label: {
              HStack {
                Text(provider.title)
                  .foregroundColor(.primary)
                Spacer()
                if providerStore.selectedProvider?.id == provider.id {
                  Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                }
              }
            }
          }
        }
      } header: {
        Text("ACTIVE PROVIDER")
      }

      Section {
        ForEach(providerStore.providers) { provider in
          Button {
            editingProvider = provider
          } label: {
            providerRow(provider)
          }
          .buttonStyle(.plain)
        }
        .onDelete(perform: providerStore.deleteProviders)
      } header: {
        Text("PROVIDERS")
      } footer: {
        Text("nostr.build signs uploads with your active key. Legacy providers may be unavailable; if a service rejects the upload, Land shows the provider response.")
      }
    }
    .navigationTitle("File Providers")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button("Done") {
          dismiss()
        }
      }

      ToolbarItem(placement: .navigationBarTrailing) {
        Button {
          editingProvider = FileCloudProvider(
            id: UUID().uuidString,
            title: "New Provider",
            endpoint: "https://",
            uploadMode: .nip96,
            isEnabled: true
          )
        } label: {
          Image(systemName: "plus")
        }
      }

      ToolbarItem(placement: .bottomBar) {
        Button("Reset Defaults") {
          showResetConfirmation = true
        }
      }
    }
    .sheet(item: $editingProvider) { provider in
      NavigationStack {
        FileCloudProviderEditorView(
          provider: provider,
          providerStore: providerStore
        )
      }
    }
    .confirmationDialog(
      "Reset file providers?",
      isPresented: $showResetConfirmation,
      titleVisibility: .visible
    ) {
      Button("Reset Defaults", role: .destructive) {
        providerStore.resetToDefaults()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This restores the built-in providers and removes custom edits.")
    }
  }

  private func providerRow(_ provider: FileCloudProvider) -> some View {
    HStack(spacing: 12) {
      Image(systemName: provider.isEnabled ? "externaldrive.fill" : "externaldrive")
        .foregroundColor(provider.isEnabled ? .accentColor : .secondary)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(provider.title)
            .foregroundColor(.primary)

          if providerStore.selectedProvider?.id == provider.id {
            Image(systemName: "checkmark.circle.fill")
              .foregroundColor(.accentColor)
              .font(.caption)
          }
        }

        Text(provider.endpoint)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)

        Text(provider.uploadMode.title)
          .font(.caption2)
          .foregroundColor(.secondary)
      }

      Spacer()

      if !provider.isEnabled {
        Text("Off")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .contentShape(Rectangle())
  }
}

private struct FileCloudProviderEditorView: View {
  @ObservedObject var providerStore: FileCloudProviderStore
  @Environment(\.dismiss) private var dismiss
  @State private var provider: FileCloudProvider

  init(provider: FileCloudProvider, providerStore: FileCloudProviderStore) {
    self.providerStore = providerStore
    _provider = State(initialValue: provider)
  }

  var body: some View {
    List {
      Section {
        TextField("Name", text: $provider.title)
          .textInputAutocapitalization(.words)

        TextField("Upload URL", text: $provider.endpoint)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()

        Picker("Upload Mode", selection: $provider.uploadMode) {
          ForEach(FileCloudProvider.UploadMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }

        Toggle("Enabled", isOn: $provider.isEnabled)
      } footer: {
        Text(provider.uploadMode.detail)
      }

      Section {
        Button("Save") {
          saveProvider()
        }
        .disabled(!canSave)
      }
    }
    .navigationTitle(provider.title.isEmpty ? "Provider" : provider.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button("Cancel") {
          dismiss()
        }
      }
    }
  }

  private var canSave: Bool {
    !provider.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && isValidEndpoint
  }

  private var isValidEndpoint: Bool {
    guard let url = provider.endpointURL else { return false }
    return url.scheme == "https" || url.scheme == "http"
  }

  private func saveProvider() {
    guard canSave else {
      EfimerousManager.shared.showMessage("Enter a valid upload URL")
      return
    }

    provider.title = provider.title.trimmingCharacters(in: .whitespacesAndNewlines)
    provider.endpoint = provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    providerStore.save(provider)
    EfimerousManager.shared.showMessage("Provider saved")
    dismiss()
  }
}

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
      .environmentObject(Coordinator())
      .environmentObject(NostrData.shared)
  }
}
