/*
 The provided code represents a `NostrData` class that serves as a data manager in the application. Here are a few points to note about the code:

 1. Initialization: The `NostrData` class is implemented as a singleton using a static `shared` instance. The initializer is private, and the shared instance can be accessed using `NostrData.shared`. The initializer sets up the Realm configuration and initializes the Realm instance.

 2. Realm: The `realm` property represents the Realm instance used for data storage and retrieval. It is initialized with a custom configuration.

 3. Last Seen Date: The `lastSeenDate` property is a published `Date` that represents the last seen date in the application. It is synchronized with the value stored in `UserDefaults`. The `init` method checks if the last seen date has not been set before and sets it to the current timestamp. The `updateLastSeenDate` method updates the last seen date and updates the corresponding value in `UserDefaults`.

 4. Bootstrap Relays: The `bootstrapRelays` method is responsible for adding and connecting to NostrRelay instances. It takes a relay URL string as a parameter and creates a `NostrRelay` object with the specified URL and the initialized Realm instance. The created `NostrRelay` object is then stored in the `nostrRelays` array and connected.

 5. Disconnect and Reconnect: The `disconnect` method unsubscribes and disconnects from all the NostrRelay instances stored in `nostrRelays`. The `reconnect` method checks if a relay is not already connected and reconnects it if necessary.

 6. Fetch Contact List: The `fetchContactList` method subscribes to the contact list updates for a specific public key by calling `subscribeContactList` on each NostrRelay instance.

 7. Init Preview: The `initPreview` method returns the shared instance of `NostrData`, allowing it to be used in preview environments for testing.

 Overall, the `NostrData` class appears to be a central component responsible for managing data, including relays, contact lists, and the last seen date. It uses Realm for data persistence and provides methods for interacting with the relays and contact lists.
 */
import Foundation
import NostrKit
import RealmSwift
import SwiftUI

class NostrData: ObservableObject {

  static let lastSeenDefaultsKey = "lastSeenDefaultsKey"

  @Published var lastSeenDate = Date(
    timeIntervalSince1970: Double(
      UserDefaults.standard.integer(forKey: NostrData.lastSeenDefaultsKey)))

  @ObservedObject var storedRelays = StoredRelays()

  var nostrRelays: [NostrRelay] = []

  private let realm: Realm
  static let shared = NostrData()

  private init() {
    if UserDefaults.standard.integer(forKey: NostrData.lastSeenDefaultsKey) == 0 {
      UserDefaults.standard.setValue(
        Timestamp(date: Date.now).timestamp, forKey: NostrData.lastSeenDefaultsKey)
      self.lastSeenDate = Date(
        timeIntervalSince1970: Double(
          UserDefaults.standard.integer(forKey: NostrData.lastSeenDefaultsKey)))
    }
    let config = Realm.Configuration(schemaVersion: 7)
    Realm.Configuration.defaultConfiguration = config
    self.realm = try! Realm()
    self.realm.autorefresh = true
  }

  func initPreview() -> NostrData {
    //        userProfiles = [UserProfile.preview]
    //        textNotes = [TextNote.preview]
    return .shared
  }

  func bootstrapRelays(relay: String) {
    self.nostrRelays.append(NostrRelay(urlString: relay, realm: realm))
    for relay in nostrRelays {
      relay.connect()
    }
  }

  func disconnect() {
    for relay in nostrRelays {
      relay.unsubscribe()
      relay.disconnect()
    }
  }

  func reconnect() {
    for relay in nostrRelays {
      if !relay.connected {
        relay.connect()
      }
    }
  }

  func fetchContactList(forPublicKey publicKey: String) {
    for relay in nostrRelays {
      relay.subscribeContactList(forPublicKey: publicKey)
    }
  }

  func updateLastSeenDate() {
    UserDefaults.standard.setValue(
      Timestamp(date: Date.now).timestamp, forKey: NostrData.lastSeenDefaultsKey)
    self.lastSeenDate = Date(
      timeIntervalSince1970: Double(
        UserDefaults.standard.integer(forKey: NostrData.lastSeenDefaultsKey)))
  }
}
