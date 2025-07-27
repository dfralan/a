// a

import SwiftUI
import RealmSwift
import SDWebImageSwiftUI

struct FollowingView: View {
    
    @EnvironmentObject var nostrData: NostrData
    @EnvironmentObject var navigation: Navigation
    @ObservedRealmObject var userProfile: RUserProfile
    @ObservedResults(RContactList.self) var contactLists

    var following: [RUserProfile] {
        if let following = contactLists.filter("publicKey = %@", userProfile.publicKey).first?.following {
            return Array(following.sorted(byKeyPath: "name", ascending: false))
        }
        return  []
    }

    var body: some View {
        List {

            Section("Following") {
                
                ForEach(following) { userProfile in
                    
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
            print("📱 FollowingView appeared for user: \(userProfile.publicKey.prefix(8))")
        }
        .onDisappear {
            print("📱 FollowingView disappeared")
        }
    }
}

struct FollowingView_Previews: PreviewProvider {
    static var previews: some View {
        FollowingView(userProfile: RUserProfile.createEmpty(withPublicKey: "abc"))
            .environmentObject(NostrData.shared)
    }
}
