// a

import SDWebImageSwiftUI
import SwiftData
import SwiftUI

struct FollowingView: View {

  @EnvironmentObject var nostrData: NostrData
  let publicKey: String
  @Query var userProfiles: [RUserProfile]
  @Query var contactLists: [RContactList]

  init(publicKey: String) {
    self.publicKey = publicKey

    let profilePublicKey = publicKey
    var profileDescriptor = FetchDescriptor<RUserProfile>(
      predicate: #Predicate { $0.publicKey == profilePublicKey }
    )
    profileDescriptor.fetchLimit = 1
    _userProfiles = Query(profileDescriptor)

    var contactListDescriptor = FetchDescriptor<RContactList>(
      predicate: #Predicate { $0.publicKey == profilePublicKey }
    )
    contactListDescriptor.fetchLimit = 1
    _contactLists = Query(contactListDescriptor)
  }

  init(userProfile: RUserProfile) {
    self.init(publicKey: userProfile.publicKey)
  }

  var userProfile: RUserProfile {
    userProfiles.first ?? RUserProfile.createEmpty(withPublicKey: publicKey)
  }

  var following: [RUserProfile] {
    if let contactList = contactLists.first {
      return contactList.following.sorted { $0.name > $1.name }
    }
    return []
  }

  var body: some View {
    List {

      Section("Following") {

        ForEach(following) { userProfile in

          NavigationLink(value: AppNavigation.Route.profile(publicKey: userProfile.publicKey)) {
            UserProfileListViewRow(userProfile: userProfile)
          }
          .id(userProfile.publicKey)
        }

      }

    }
    .listStyle(.plain)
    .task {
      nostrData.fetchContactList(forPublicKey: publicKey)
    }
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
    FollowingView(publicKey: "abc")
      .environmentObject(NostrData.shared)
      .modelContainer(NostrData.shared.modelContainer)
  }
}
