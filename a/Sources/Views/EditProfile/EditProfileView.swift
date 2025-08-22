// a

import CoreImage.CIFilterBuiltins
import Foundation
import RealmSwift
import SDWebImageSwiftUI
import SwiftUI

struct EditProfileView: View {

  // QRVIEW PARAMETERS
  @EnvironmentObject var nostrData: NostrData
  @EnvironmentObject var navigation: Navigation

  // REALM OBJECTS
  @ObservedRealmObject var userProfile: RUserProfile

  //FORM INPUTS VARIABLES
  @State private var usernameInput: String = "Fernando"
  @State private var nameInput: String = "@fer"
  @State private var aboutInput: String = "Flawless 🥷"
  @State private var websiteInput: String = ""
  @State private var lightningInput: String = ""
  @State private var nip05InputInput: String = "nostr.ar"

  var body: some View {

    let avatarUrl = userProfile.avatarUrl
    let _ = userProfile.name.isValidName() ? ("@" + userProfile.name) : "Anonymous"
    let _ = userProfile.publicKey

    VStack(alignment: .center) {
      AvatarView(url: avatarUrl, size: 70)
      Text("Change avatar")
        .foregroundColor(.accentColor)
    }
    .padding()

    List {
      HStack {
        Text("Name")
        TextField("name", text: $nameInput)
      }
      HStack {
        Text("Username")
        Spacer()
        TextField("username", text: $usernameInput)
      }
      HStack {
        Text("Bio")
        TextField("about me", text: $aboutInput, axis: .vertical)
          .lineLimit(5)
      }
      HStack {
        Text("Link")
        TextField("mywebsite.com", text: $websiteInput)

      }
      HStack {
        Text("BTC Lightning")
        TextField("Lightning Address", text: $lightningInput)
      }
      HStack {
        Text("nip-05 address")
        TextField("fer@mywebsite.com", text: $nip05InputInput)
      }
    }
    .listStyle(PlainListStyle())
    .navigationTitle("")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text("Edit profile")
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button {
          print("Saved changes")
        } label: {
          Text("Save")
        }
      }
    }
  }
}
