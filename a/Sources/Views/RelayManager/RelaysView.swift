// a

import SwiftUI

// REALYS VIEW

struct RelaysView: View {
  @State var read = true
  @State var write = true

  @State private var textInput = ""

  @State private var showDetails = false

  let supportedNips = [
    "01", "02", "04", "09", "11", "12", "15", "16", "20", "22", "26", "28", "11", "12",
  ]

  var body: some View {

    // RELAYS ROW VIEW
    Form {

      Section {

        // RELAY
        DisclosureGroup {

          HStack(alignment: .firstTextBaseline) {
            NavigationLink(destination: RelaysView()) {
              Text("Admin")
              Spacer()
              HStack {
                AvatarView(size: 30)
                VStack(alignment: .leading) {
                  usernameView(username: "Fer", nip05: "nostr.ar", extended: false)
                }
              }
            }
          }

          HStack {
            Text("Latency")
            Spacer()
            Text("355")
            Image(systemName: "wifi")
              .foregroundColor(.accentColor)
              .font(.subheadline).bold()
          }

          HStack {
            Text("Events")
            Spacer()
            Text("23")
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
              .foregroundColor(.accentColor)
              .font(.subheadline).bold()
          }
          HStack {
            Text("Software")
            Spacer()
            Text("https://github.com/v0l/nostr-rs-relayv0.8.7")
              .lineLimit(1)

          }
          HStack {
            Text("Contact")
            Spacer()
            Text("x@nostr.ar")
              .lineLimit(1)

          }
          VStack(alignment: .leading) {

            DisclosureGroup {
              WrappingHStack(horizontalSpacing: 12) {

                ForEach(supportedNips, id: \.self) { nip in

                  Text(nip)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .background(.thinMaterial)
                    .foregroundColor(.primary)
                    .cornerRadius(5)
                    .font(.subheadline)
                }
              }

            } label: {
              Text("Supported NIPS")

            }
            .transaction { transaction in
              transaction.animation = .spring(
                response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)
            }

          }

          Toggle("Read", isOn: $read)
          Toggle("Write", isOn: $write)
          HStack {
            Text("Version")
            Spacer()
            Text("v78-30b8c38")
              .lineLimit(1)

          }
          HStack {
            Spacer()
            Text("Remove")
            Image(systemName: "trash")
          }
          .foregroundColor(.red)

        } label: {
          HStack(spacing: 0) {
            Circle()
              .frame(width: 16, height: 16)
              .foregroundColor(.green)
              .offset(x: -5, y: 1)
            Text("wss://nostr.ar")

          }
        }
      }

      Section {
        HStack {
          TextField("Add a relay", text: $textInput)
          Button(action: {
            print("Hello")
          }) {
            Image(systemName: "plus")
          }
        }
      }
    }
    .navigationTitle("Relays")

    .tint(.accentColor)
  }
}

extension Array {
  func chunked(into size: Int) -> [[Element]] {
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}

struct RelaysView_Previews: PreviewProvider {
  static var previews: some View {
    RelaysView()
  }
}
