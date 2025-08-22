// a

import SwiftUI

// MARK: - Root View

struct RootView: View {

  // MARK: - Properties

  @State private var selection: SelectedView? = .home
  @StateObject var navigation: Navigation = Navigation()
  @StateObject var coordinator: Coordinator = Coordinator()

  var body: some View {
    ZStack {
      NavigationSplitView {
        sidebarContent
          .navigationTitle("Land")
      } detail: {
        detailContent
      }

      // MARK: - Quick ephemeral notifications

      EphemeralNotificationView()

    }
    .navigationSplitViewStyle(.balanced)
    .environmentObject(navigation)
    .environmentObject(coordinator)
    .preferredColorScheme(
      coordinator.themeMode > 0 ? coordinator.themeMode > 1 ? .dark : .light : .none
    )
    .tint(coordinator.accentColorSwitcher)/// Sets the tint or accent color of the entire app
    .saturation(coordinator.saturationColor)
    .font(.system(size: coordinator.selectedFontSize.fontSizeValue))
    .dynamicTypeSize(...DynamicTypeSize.large)
  }
}

enum SelectedView: String, Codable {
  case home, messages, notifications, keyManager, relays, wallet, settings, collaborate, logout,
    profileDetailed
  var title: String {
    rawValue.capitalized
  }
}

extension RootView {

  var sidebarContent: some View {
    List(selection: $selection) {
      Section(header: Text("Stored Keys")) {
        link(to: .home)
        HStack {
          AvatarView(size: 30)
          VStack(alignment: .leading) {
            usernameView(username: "A", nip05: "nostr.ar", extended: false)
            Text("npub1f...pz9c7")
              .lineLimit(1)
          }
          Spacer()
          Text("Switch")
            .foregroundColor(.gray)
        }
        link(to: .keyManager)
      }

      Section(header: Text("Access")) {
        link(to: .messages)
        link(to: .notifications)
        link(to: .relays)
        link(to: .wallet)
      }
      Section(header: Text("More")) {
        link(to: .settings)
        link(to: .collaborate)
      }
      Section(header: Text("Log out")) {
        link(to: .logout)
      }
    }
  }

  func link(to page: SelectedView) -> some View {
    let title: String
    let image: Image

    switch page {
    case .home:
      title = "Home"
      image = Image(systemName: "house")
      return AnyView(
        NavigationLink(destination: detailContent(for: page)) {
          HStack {
            AvatarView(size: 40)
            VStack(alignment: .leading) {
              usernameView(username: "Alan", nip05: "nostr.ar", extended: false)
              Text("npub1f...pz9c7")
                .lineLimit(1)
            }
            Spacer()
            Text("Logged").bold()
              .foregroundColor(.accentColor)
          }
        })
    case .messages:
      title = "Messages"
      image = Image(systemName: "message")
    case .notifications:
      title = "Notifications"
      image = Image(systemName: "bell")
    case .keyManager:
      title = "Add a key"
      image = Image(systemName: "key")
    case .relays:
      title = "Relays"
      image = Image(systemName: "aqi.medium")
    case .wallet:
      title = "Wallet"
      image = Image(systemName: "bolt")
    case .settings:
      title = "Settings"
      image = Image(systemName: "transmission")
    case .collaborate:
      title = "Collaborate"
      image = Image(systemName: "heart")
    case .logout:
      title = "Logout"
      image = Image(systemName: "arrowshape.turn.up.left")
      return AnyView(
        NavigationLink(destination: detailContent(for: page)) {
          HStack {
            Image(systemName: "door.right.hand.open")
              .frame(width: 20)
            HStack {
              Text("Logout from")
              usernameView(username: "Alan", nip05: "nostr.ar", extended: false)
            }
          }
        })
    case .profileDetailed:
      title = "Detail"
      image = Image(systemName: "trash")
    }

    return AnyView(
      NavigationLink(destination: detailContent(for: page)) {
        HStack {
          image
            .frame(minWidth: 20)
          Text(title)
        }
        .foregroundColor(.primary)
      })
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
    case .home: HomeView()
    case .messages: MessagesView(userProfile: RUserProfile())
    case .notifications: NotificationsView(userProfile: RUserProfile())
    case .keyManager: KeyGen()
    case .relays: RelayManager()
    case .wallet: WalletListView()
    case .settings: SettingsView()
    case .collaborate: CollaborateView()
    case .logout: HomeView()
    case .profileDetailed: ProfileDetailView(userProfile: RUserProfile())
    }
  }
}

struct RootView_Previews: PreviewProvider {
  static var previews: some View {
    RootView()
      .environmentObject(Navigation())
      .environmentObject(NostrData.shared.initPreview())
  }
}
