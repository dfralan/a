// a

import SwiftUI

final class AppNavigation: ObservableObject {

  enum Route: Hashable {
    case profile(publicKey: String)
    case following(publicKey: String)
    case followers(publicKey: String)
    case qr(publicKey: String)
    case editProfile(publicKey: String)
    case chat(publicKey: String)
    case event(reference: NostrEventReference)
    case thread(target: ThreadTarget)
    case search
  }

  @Published var path: [Route] = []

  var isAtRoot: Bool {
    path.isEmpty
  }

  func push(_ route: Route) {
    path.append(route)
  }

  func popToRoot() {
    guard !path.isEmpty else { return }
    path.removeAll()
  }
}
