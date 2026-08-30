// a

import Kingfisher
import SDWebImageSwiftUI
import SwiftData
import SwiftUI
import UIKit

@main

// MARK: - "a" Main App

struct aApp: App {

  // MARK: - Properties

  @Environment(\.scenePhase) var scenePhase
  /// Get state of the scene app
  @StateObject var nostrData: NostrData = NostrData.shared
  /// Nostr Data Initialization

  init() {
    ImageCache.default.memoryStorage.config.totalCostLimit = 32 * 1_024 * 1_024
    ImageCache.default.memoryStorage.config.countLimit = 100
    ImageCache.default.memoryStorage.config.expiration = .seconds(5 * 60)
    SDImageCache.shared.config.maxMemoryCost = 32 * 1_024 * 1_024
    SDImageCache.shared.config.maxMemoryCount = 100
  }

  var body: some Scene {

    WindowGroup {
      RootView()
        .environmentObject(nostrData)
        .modelContainer(nostrData.modelContainer)
        .onReceive(
          NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
          )
        ) { _ in
          releaseEvictableMemory()
        }
    }

    // MARK: - Actions to retrieve on app scene change

    .onChange(of: scenePhase) { _, phase in
      switch phase {

      case .background:
        /// The scene is in the background. (Ex: The user switches to another application or when the application is running in the background.)
        print("'a' => Background Phase")
        nostrData.disconnect()

      case .active:
        /// The scene is active and visible to the user. (Ex: The user is interacting with the application in the foreground.)
        print("'a' => Active Phase")
        nostrData.reconnect()
      /// Call the reconnect() method of the nostrData object.

      case .inactive:
        /// The scene is inactive but still visible to the user. (Ex: There is another window or overlaying dialog partially hiding the current scene.)
        print("'a' => Inactive Phase")

      default:
        /// The scene has been terminated and is no longer available.
        print("'a' => Entered Unknown Phase")

      }
    }
  }

  private func releaseEvictableMemory() {
    EventRenderCache.shared.removeAll()
    ImageCache.default.clearMemoryCache()
    SDImageCache.shared.clearMemory()
    nostrData.handleMemoryWarning()
  }
}
