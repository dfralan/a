// a

import SwiftUI

@main

// MARK: - "a" Main App

struct aApp: App {

  // MARK: - Properties

  @Environment(\.scenePhase) var scenePhase
  /// Get state of the scene app
  @StateObject var nostrData: NostrData = NostrData.shared
  /// Nostr Data Initialization

  var body: some Scene {

    WindowGroup {
      RootView()
        .environmentObject(nostrData)
    }

    // MARK: - Actions to retrieve on app scene change

    .onChange(of: scenePhase) { phase in
      switch phase {

      case .background:
        /// The scene is in the background. (Ex: The user switches to another application or when the application is running in the background.)
        print("'a' => Background Phase")

      case .active:
        /// The scene is active and visible to the user. (Ex: The user is interacting with the application in the foreground.)
        print("'a' => Active Phase")
        nostrData.reconnect()
      /// Call the reconnect() method of the nostrData object.

      case .inactive:
        /// The scene is inactive but still visible to the user. (Ex: There is another window or overlaying dialog partially hiding the current scene.)
        print("'a' => Inactive Phase")
        nostrData.disconnect()
      /// Call the disconnect() method of the nostrData object.

      default:
        /// The scene has been terminated and is no longer available.
        print("'a' => Entered Unknown Phase")

      }
    }
  }
}

