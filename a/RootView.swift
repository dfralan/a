// a

import SwiftData
import SwiftUI

// MARK: - Root View

struct RootView: View {

  // MARK: - Properties

  @State private var selection: SelectedView? = .home
  @StateObject var navigation = AppNavigation()
  @StateObject var coordinator: Coordinator = Coordinator()
  @StateObject var keyManager: KeyManager = KeyManager()
  @StateObject private var foregroundActivityNotifications =
    ForegroundActivityNotificationCenter()
  @EnvironmentObject var nostrData: NostrData
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.scenePhase) private var scenePhase
  @Query private var userProfiles: [RUserProfile]
  @State private var authenticatingSidebarKey: String?
  @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
  @State private var isSidebarSheetPresented = false
  @State private var isLaunchCurtainPresented = true
  @State private var pendingActivityRoute: AppNavigation.Route?

  var body: some View {
    ZStack {
      NavigationSplitView(columnVisibility: $columnVisibility) {
        sidebarContent
          .navigationTitle("Land")
      } detail: {
        detailContent
      }

      // MARK: - Quick ephemeral notifications

      EphemeralNotificationView()

      if let item = foregroundActivityNotifications.currentItem {
        VStack {
          ForegroundActivityBanner(
            item: item,
            onOpen: { openForegroundActivity(item) },
            onDismiss: foregroundActivityNotifications.dismissCurrent
          )
          .padding(.horizontal, 12)
          .padding(.top, 8)

          Spacer(minLength: 0)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .zIndex(2)
      }

      if isLaunchCurtainPresented {
        AppLaunchCurtain {
          isLaunchCurtainPresented = false
        }
        .zIndex(1)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .environmentObject(navigation)
    .environmentObject(coordinator)
    .environmentObject(keyManager)
    .onAppear {
      keyManager.loadKeys()
      foregroundActivityNotifications.configure(nostrData: nostrData)
      activateForegroundActivityNotifications()
    }
    .onChange(of: selection) { oldSelection, newSelection in
      if oldSelection != newSelection {
        navigation.popToRoot()
      }
      if let pendingActivityRoute {
        navigation.push(pendingActivityRoute)
        self.pendingActivityRoute = nil
      }
      closeSidebar()
    }
    .onChange(of: keyManager.selectedKey) { _, _ in
      activateForegroundActivityNotifications()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      activateForegroundActivityNotifications()
    }
    .sheet(isPresented: $isSidebarSheetPresented) {
      NavigationStack {
        sidebarSheetContent
          .navigationTitle("Land")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") {
                closeSidebar()
              }
            }
          }
      }
    }
    .preferredColorScheme(
      coordinator.themeMode > 0 ? coordinator.themeMode > 1 ? .dark : .light : .none
    )
    .tint(coordinator.accentColorSwitcher)/// Sets the tint or accent color of the entire app
    .accentColor(coordinator.accentColorSwitcher)
    .saturation(coordinator.saturationColor)
    .font(.system(size: coordinator.selectedFontSize.fontSizeValue))
    .dynamicTypeSize(...DynamicTypeSize.large)
  }
}

enum SelectedView: String, Codable, Hashable {
  case home, messages, notifications, keyManager, relays, settings
  var title: String {
    rawValue.capitalized
  }
}

extension RootView {

  var sidebarContent: some View {
    List(selection: $selection) {
      Section(header: Text("Stored Keys")) {
        if keyManager.storedKeys.isEmpty {
          navigationLink(to: .keyManager)
        } else {
          ForEach(keyManager.storedKeys, id: \.self) { key in
            Button {
              authenticateAndSelectKey(key)
            } label: {
              sidebarKeyRow(for: key)
            }
            .buttonStyle(.plain)
            .disabled(authenticatingSidebarKey != nil)
          }
          navigationLink(to: .keyManager)
        }
      }

      Section(header: Text("Access")) {
        navigationLink(to: .home)
        navigationLink(to: .messages)
        navigationLink(to: .notifications)
        navigationLink(to: .relays)
      }
      Section(header: Text("More")) {
        navigationLink(to: .settings)
      }
      Section(header: Text("Connection")) {
        networkToggleRow
      }
    }
  }

  var sidebarSheetContent: some View {
    List {
      Section(header: Text("Stored Keys")) {
        if keyManager.storedKeys.isEmpty {
          sheetButton(to: .keyManager)
        } else {
          ForEach(keyManager.storedKeys, id: \.self) { key in
            Button {
              authenticateAndSelectKey(key)
            } label: {
              sidebarKeyRow(for: key)
            }
            .buttonStyle(.plain)
            .disabled(authenticatingSidebarKey != nil)
          }
          sheetButton(to: .keyManager)
        }
      }

      Section(header: Text("Access")) {
        sheetButton(to: .home)
        sheetButton(to: .messages)
        sheetButton(to: .notifications)
        sheetButton(to: .relays)
      }
      Section(header: Text("More")) {
        sheetButton(to: .settings)
      }
      Section(header: Text("Connection")) {
        networkToggleRow
      }
    }
  }

  func sidebarKeyRow(for key: String) -> some View {
    let publicKey = keyManager.publicKey(for: key) ?? key
    let avatarURL = avatarURL(forKey: key)
    let isSelected = keyManager.selectedKey == key

    return HStack {
      AvatarView(publicKey: publicKey, url: avatarURL, size: 30)
      VStack(alignment: .leading) {
        Text(keyManager.keyKindDescription(for: key))
          .font(.subheadline)
          .bold()
        Text(publicKey.accordionString(index: 8))
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if authenticatingSidebarKey == key {
        ProgressView()
          .controlSize(.small)
      }
      if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.accentColor)
      }
    }
    .contentShape(Rectangle())
  }

  func avatarURL(forKey key: String) -> URL? {
    guard let publicKeyHex = keyManager.publicKeyHex(for: key) else { return nil }
    return userProfiles.first { $0.publicKey == publicKeyHex }?.avatarUrl
  }

  func authenticateAndSelectKey(_ key: String) {
    guard authenticatingSidebarKey == nil else { return }

    authenticatingSidebarKey = key

    Task {
      let reason =
        keyManager.selectedKey == key
        ? "Unlock the active key."
        : "Unlock this key to make it active."
      let didAuthenticate = await KeyAccessAuthenticator.authenticate(reason: reason)

      await MainActor.run {
        authenticatingSidebarKey = nil

        guard didAuthenticate else {
          EfimerousManager.shared.showMessage("Authentication canceled")
          return
        }

        keyManager.selectKey(key)
        selection = .home
        closeSidebar()
      }
    }
  }

  func navigationLink(to page: SelectedView) -> some View {
    NavigationLink(value: page) {
      sidebarLabel(for: page)
    }
  }

  func sheetButton(to page: SelectedView) -> some View {
    Button {
      select(page)
    } label: {
      HStack {
        sidebarLabel(for: page)
        Spacer()
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  func sidebarLabel(for page: SelectedView) -> some View {
    sidebarPlainLabel(for: page)
  }

  func sidebarPlainLabel(for page: SelectedView) -> some View {
    let metadata = sidebarLabelMetadata(for: page)

    return HStack {
      metadata.image
        .frame(minWidth: 20)
      Text(metadata.title)
    }
    .foregroundColor(.primary)
  }

  func sidebarLabelMetadata(for page: SelectedView) -> (title: String, image: Image) {
    switch page {
    case .home:
      return ("Home", Image(systemName: "house"))
    case .messages:
      return ("Messages", Image(systemName: "message"))
    case .notifications:
      return ("Notifications", Image(systemName: "bell"))
    case .keyManager:
      return ("Keys", Image(systemName: "key"))
    case .relays:
      return ("Relays", Image(systemName: "aqi.medium"))
    case .settings:
      return ("Settings", Image(systemName: "transmission"))
    }
  }

  var networkToggleRow: some View {
    Toggle(
      isOn: Binding(
        get: { nostrData.isNetworkEnabled },
        set: { nostrData.setNetworkEnabled($0) }
      )
    ) {
      HStack(spacing: 12) {
        Image(systemName: nostrData.isNetworkEnabled ? "power.circle.fill" : "power.circle")
          .frame(minWidth: 20)
          .foregroundStyle(nostrData.isNetworkEnabled ? .green : .secondary)

        VStack(alignment: .leading, spacing: 2) {
          Text(nostrData.isNetworkEnabled ? "Online" : "Offline")
            .foregroundStyle(.primary)

          Text(nostrData.isNetworkEnabled ? "Relays active" : "Relays paused")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .tint(.green)
  }

}

extension RootView {

  @ViewBuilder
  var detailContent: some View {
    if let selection = selection {
      detailContent(for: selection)
    } else {
      Text("No selection")
    }
  }

  @ViewBuilder
  func detailContent(for selectedView: SelectedView) -> some View {
    switch selectedView {
    case .home:
      appNavigationStack {
        HomeView(
          onMenuTap: showSidebar,
          onMessagesTap: { select(.messages) },
          onNotificationsTap: { select(.notifications) }
        )
      }
    case .messages:
      appNavigationStack {
        MessagesView()
      }
    case .notifications:
      appNavigationStack {
        NotificationsView()
      }
    case .keyManager: KeyManagerSecuredView()
    case .relays: RelayManager()
    case .settings: SettingsView()
    }
  }

  func showSidebar() {
    if usesCompactSidebarSheet {
      isSidebarSheetPresented = true
    } else {
      withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
        columnVisibility = .all
      }
    }
  }

  func closeSidebar() {
    isSidebarSheetPresented = false
    columnVisibility = .detailOnly
  }

  func select(_ page: SelectedView) {
    navigation.popToRoot()
    selection = page
    closeSidebar()
  }

  func activateForegroundActivityNotifications() {
    foregroundActivityNotifications.activate(
      publicKey: keyManager.publicKeyHex(for: keyManager.selectedKey)
    )
  }

  func openForegroundActivity(_ item: ActivityItem) {
    foregroundActivityNotifications.dismissCurrent()

    let route: AppNavigation.Route
    switch item.route {
    case .profile(let publicKey):
      route = .profile(publicKey: publicKey)
    case .event(let reference):
      route = .event(reference: reference)
    }

    navigation.popToRoot()
    if selection == .notifications {
      navigation.push(route)
    } else {
      pendingActivityRoute = route
      selection = .notifications
    }
    closeSidebar()
  }

  private var usesCompactSidebarSheet: Bool {
    horizontalSizeClass != .regular
  }

  func appNavigationStack<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    NavigationStack(path: $navigation.path) {
      content()
        .navigationDestination(for: AppNavigation.Route.self) { route in
          routeDestination(for: route)
        }
    }
  }

  @ViewBuilder
  func routeDestination(for route: AppNavigation.Route) -> some View {
    switch route {
    case .profile(let publicKey):
      ProfileDetailView(publicKey: publicKey)
    case .following(let publicKey):
      FollowingView(publicKey: publicKey)
    case .followers(let publicKey):
      FollowersView(publicKey: publicKey)
    case .qr(let publicKey):
      QRView(publicKey: publicKey)
    case .editProfile(let publicKey):
      EditProfileView(publicKey: publicKey)
    case .chat(let publicKey):
      ChatView(publicKey: publicKey)
    case .event(let reference):
      ThreadView(target: reference.threadTarget)
    case .thread(let target):
      ThreadView(target: target)
    case .search:
      SearchView()
    }
  }
}

struct RootView_Previews: PreviewProvider {
  static var previews: some View {
    RootView()
      .environmentObject(AppNavigation())
      .environmentObject(NostrData.shared.initPreview())
      .environmentObject(KeyManager())
  }
}
