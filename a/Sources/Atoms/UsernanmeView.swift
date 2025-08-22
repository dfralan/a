// a

import SwiftUI

class Network {
  let url = URL(string: "https://nostr.ar/.well-known/nostr.json?name=dfralan")!

  func getString() async -> String {
    do {
      let request = URLRequest(url: url)
      let (data, _) = try await URLSession.shared.data(for: request)
      return String(data: data, encoding: .utf8) ?? "Error converting data to string"
    } catch {
      return error.localizedDescription
    }
  }
}

struct usernameView: View {

  let username: String
  let nip05: String
  let extended: Bool?

  var body: some View {
    HStack(spacing: 0) {
      Text(username)
        .font(extended! ? .title2 : .headline).bold()
        .frame(alignment: .leading)
        .lineLimit(1)
      // NIP05 verification
      HStack(spacing: 0) {
        if !nip05.isEmpty {
          Image(systemName: "checkmark.seal.fill")
            .foregroundColor(.accentColor)
            .font(extended! ? .title2 : .subheadline).bold()
        }
        extended! ? Text(nip05).font(extended! ? .title2 : .subheadline).lineLimit(1) : nil

      }
    }
  }
}

struct username_Previews: PreviewProvider {
  static var previews: some View {

    VStack {
      usernameView(username: "fernandolguevara", nip05: "relay.nostr.ar", extended: true)
      usernameView(username: "pepe", nip05: "relay.nostr.ar", extended: false)
    }
  }
}
