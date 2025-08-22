// a

import SwiftUI

struct NewChat: View {

  @State private var searchText = ""

  var body: some View {

    // TEXT FIELD
    HStack {
      ZStack(alignment: .leading) {

        TextField("Search or insert a pubkey", text: $searchText)
          .textFieldStyle(ClassicTextFieldStyle(text: $searchText, paddingLeft: 35))

        Button(
          action: {},
          label: {
            Image(systemName: "magnifyingglass")
              .foregroundColor(Color(.gray))
              .font(.system(size: 18))
          }

        ).padding(.horizontal, 10)

      }
      if !searchText.isEmpty {
        Button(
          action: { self.searchText = "" },
          label: {
            Text("Cancel")
              .foregroundColor(.accentColor)
          }

        )
      }
    }
    .padding(.horizontal)

    //SEARCH RESULT LIST
    List {
      ForEach(0...20, id: \.self) { _ in
        NavigationLink(destination: ChatView(userProfile: RUserProfile.preview)) {
          AvatarView(size: 50)
          VStack(alignment: .leading) {
            usernameView(username: "pepe", nip05: "relay.nostr.ar", extended: false)
            Text("npub1f...pz9c7")
              .font(.caption)
              .lineLimit(1)
          }
        }

      }

    }
    .listStyle(.plain)

    //PLACEHOLDER MODEL
    //.redacted(reason: .placeholder)
    //.unredacted()

    //VIEW TITLE
    .navigationTitle("New chat")

  }
}

struct NewChat_Previews: PreviewProvider {
  static var previews: some View {
    NewChat()
  }
}
