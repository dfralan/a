// a

import RealmSwift
import SDWebImageSwiftUI
import SwiftUI

struct FollowingView: View {

  @EnvironmentObject var nostrData: NostrData
  @ObservedRealmObject var userProfile: RUserProfile
  @ObservedResults(RContactList.self) var contactLists

  var following: [RUserProfile] {
    if let following = contactLists.filter("publicKey = %@", userProfile.publicKey).first?.following
    {
      return Array(following.sorted(byKeyPath: "name", ascending: false))
    }
    return []
  }

  var body: some View {
    List {

      Section("Following") {

        ForEach(following) { userProfile in

          NavigationLink(value: Navigation.NavUserProfile(userProfile: userProfile)) {
            UserProfileListViewRow(userProfile: userProfile)
          }
          .id(userProfile.publicKey)
        }

      }

    }
    .listStyle(.plain)
    .navigationTitle("")
    .toolbar {
      ToolbarItem(placement: .principal) {
        UserProfileNavigationTitle(userProfile: userProfile)
      }
    }
  }
}

struct FollowingView_Previews: PreviewProvider {
  static var previews: some View {
    FollowingView(userProfile: RUserProfile.createEmpty(withPublicKey: "abc"))
      .environmentObject(NostrData.shared)
  }
}
