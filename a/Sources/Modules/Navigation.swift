// a

// MAIN NAVIGATION STRUCTURE

import Foundation
import SwiftUI

class MainTabNavigation: ObservableObject {
  @Published var mainTabPath = NavigationPath()
}

class Navigation: ObservableObject {

  @Published var homePath = NavigationPath() {
    didSet {
      print("Home Path: \(homePath)")  // Imprimir el estado actual del homePath
    }
  }

  // PROFILE DETAILED VIEW
  struct NavUserProfile: Hashable {
    let userProfile: RUserProfile
  }

  // FOLLOWING LIST VIEW
  struct NavFollowing: Hashable {
    let userProfile: RUserProfile
  }

  // FOLLOWERS LIST VIEW
  struct NavFollowers: Hashable {
    let userProfile: RUserProfile
  }

  // QR VIEW
  struct NavQR: Hashable {
    let userProfile: RUserProfile
  }

  //EDIT PROFILE VIEW
  struct NavEditProfile: Hashable {
    let userProfile: RUserProfile
  }

  //HOMEVIEW
  struct NavHome: Hashable {
    let userProfile: RUserProfile
  }
}
