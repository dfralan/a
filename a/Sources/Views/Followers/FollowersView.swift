// a

import SwiftUI
import RealmSwift
import SDWebImageSwiftUI

struct FollowersView: View {
    
    @EnvironmentObject var nostrData: NostrData
    @EnvironmentObject var navigation: Navigation
    @ObservedRealmObject var userProfile: RUserProfile
    @ObservedResults(RContactList.self) var contactLists

    var followedBy: [RUserProfile] {
        if let followedBy = contactLists.filter("publicKey = %@", userProfile.publicKey).first?.followedBy {
            return Array(followedBy.sorted(byKeyPath: "name", ascending: false))
        }
        return  []
    }

    var body: some View {
        List {

            Section("Followers") {
                
                ForEach(followedBy) { userProfile in
                    
                    Button(action: {
                        navigation.safeNavigate(Navigation.NavUserProfile(userProfile: userProfile))
                    }) {
                        UserProfileListViewRow(userProfile: userProfile)
                    }
                    .id(userProfile.publicKey)
                    .buttonStyle(.plain)
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
        .onAppear {
            print("📱 FollowersView appeared for user: \(userProfile.publicKey.prefix(8))")
        }
        .onDisappear {
            print("📱 FollowersView disappeared")
        }
    }
}

struct FollowersView_Previews: PreviewProvider {
    static var previews: some View {
        FollowersView(userProfile: RUserProfile.createEmpty(withPublicKey: "abc"))
            .environmentObject(NostrData.shared)
    }
}
