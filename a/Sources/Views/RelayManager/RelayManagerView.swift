import RealmSwift
import SwiftUI

class RelayItem: Object, Identifiable {
  @objc dynamic var id = UUID().uuidString
  @objc dynamic var address = ""
  @objc dynamic var state = ""

  override static func primaryKey() -> String? {
    return "id"
  }
}

class StoredRelays: ObservableObject {
  private let realm = try! Realm()
  @Published var relayItems: Results<RelayItem> = try! Realm().objects(RelayItem.self)

  func addItem(address: String, state: String) {
    guard !address.isEmpty else {
      loadData()
      return
    }

    // Check if an item with the same address already exists
    let itemExists = relayItems.contains { $0.address == address }
    guard !itemExists else {
      // An item with the same address already exists
      // You can handle this scenario as per your requirement
      // For example, show an error message or perform an update instead of adding a new item
      print("Relay with address '\(address)' already exists")
      return
    }

    let item = RelayItem()
    item.address = address
    item.state = state

    try! realm.write {
      realm.add(item)
    }

    loadData()
  }

  func deleteItem(item: RelayItem) {
    try! realm.write {
      realm.delete(item)
    }
    loadData()
  }

  func updateItem(item: RelayItem, address: String, state: String) {
    try! realm.write {
      item.address = address
      item.state = state
    }
    loadData()
  }

  func loadData() {
    relayItems = realm.objects(RelayItem.self)
  }

  func deleteAllItems() {
    try! realm.write {
      realm.deleteAll()
    }
    loadData()
  }
}

struct RelayManager: View {

  @State private var showDeleteAllConfirmationAlert = false
  @ObservedObject var storedRelays = StoredRelays()
  @State private var newAddress = ""

  @State private var editing: Bool = false
  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        // Textfield
        HStack {
          HStack {
            TextField("Add a relay URL", text: $newAddress)

            if !newAddress.isEmpty {
              Button {
                self.newAddress = ""
              } label: {
                Image(systemName: "delete.left")
                  .foregroundColor(.accentColor)
              }
            }
          }.RoundedThinStyle()

          Button(action: {

            var urlStrings: [String]

            if newAddress.contains(",") {
              urlStrings = newAddress.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
              }
            } else {
              urlStrings = [newAddress.trimmingCharacters(in: .whitespaces)]
            }

            urlStrings.forEach { urlString in
              let trimmedUrlString = urlString.replacingOccurrences(of: " ", with: "").lowercased()

              if !trimmedUrlString.hasPrefix("wss://") {
                print("Invalid URL: \(trimmedUrlString)")
              } else {
                if let encodedUrlString = trimmedUrlString.addingPercentEncoding(
                  withAllowedCharacters: .urlQueryAllowed),
                  let url = URLComponents(string: encodedUrlString)?.url
                {
                  storedRelays.addItem(address: url.absoluteString, state: "plugged")
                } else {
                  // Handle invalid URL scenario
                  print("Invalid URL: \(trimmedUrlString)")
                }
              }
            }

            newAddress = ""

          }) {
            Image(systemName: "plus")
              .font(.headline)

          }
        }

        // ALL RELAYS
        ScrollView {
          VStack(spacing: 20) {
            ForEach(storedRelays.relayItems) { item in

              //RELAY
              HStack(spacing: 15) {

                if !editing {
                  Button {

                  } label: {
                    Image(systemName: "checkmark.circle.fill")
                      .font(.subheadline)
                  }

                  // PENDANTS
                  Button {
                  } label: {
                    HStack {
                      ZStack {
                        Image(systemName: "figure.run")
                          .offset(x: -5)
                          .opacity(0.25)
                        Image(systemName: "figure.run")
                          .opacity(0.5)
                        Image(systemName: "figure.run")
                          .offset(x: 5)
                      }
                      Text("-")
                    }

                  }.saturation(item.state == "plugged" ? 1 : 0)
                  Spacer()
                }
                // GO FURTHER
                NavigationLink(
                  destination: RelayItemDetailView(storedRelays: storedRelays, item: item)
                ) {
                  HStack {
                    Text(item.address)
                      .saturation(item.state == "plugged" ? 1 : 0)
                      .lineLimit(1)
                    Image(systemName: "chevron.right")
                  }
                }

                if editing {
                  Spacer()

                  // COPY RELAY URL
                  Button {
                    UIPasteboard.general.string = item.address
                  } label: {
                    Image(systemName: "square.on.square")
                  }

                  // DELETE
                  Button(role: .destructive) {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2))
                    {
                      storedRelays.deleteItem(item: item)
                      storedRelays.loadData()
                    }
                  } label: {
                    Image(systemName: "trash")
                  }

                }
              }
              Divider()
            }
            if storedRelays.relayItems.count > 1 && editing {

              Button {
                UIPasteboard.general.string =
                  (storedRelays.relayItems.map { $0.address }.sorted().joined(separator: ", "))
              } label: {
                Text("Copy All")
                Spacer()
                Image(systemName: "square.on.square")
              }

              Divider()

              Button(role: .destructive) {
                showDeleteAllConfirmationAlert = true
              } label: {
                Text("Delete All")
                Spacer()
                Image(systemName: "trash")
              }

            }

            Spacer()
          }
          .onAppear {
            storedRelays.loadData()
            print("loading data")
          }
        }
        Spacer()
      }
    }
    .padding()

    // HIDE KEYBOARD WHEN TAP OUTSIDE THE TEXTFIELD
    .onTapGesture {
      UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    .toolbar {
      ToolbarItem(placement: .principal) {

        Text("Relay Manager")
      }
      ToolbarItem(placement: .navigationBarTrailing) {

        if !storedRelays.relayItems.isEmpty {
          Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
              editing.toggle()
            }
          } label: {
            Text(editing ? "Done" : "Edit")
          }
        }
      }
    }
    .alert(isPresented: $showDeleteAllConfirmationAlert) {
      Alert(
        title: Text("Confirmation"),
        message: Text("Are you sure you want to delete all relays?"),
        primaryButton: .destructive(Text("Delete All")) {
          storedRelays.deleteAllItems()
        },
        secondaryButton: .cancel()
      )
    }

  }
}

struct RelayItemDetailView: View {
  let supportedNips = [
    "01", "02", "04", "09", "11", "12", "15", "16", "20", "22", "26", "28", "11", "12",
  ]
  @Environment(\.presentationMode) var presentationMode
  @ObservedObject var storedRelays: StoredRelays
  @StateObject var item: RelayItem
  @State private var editItemAddress = ""

  var body: some View {
    Form {
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
      TextField("Item address", text: $editItemAddress)
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
        transaction.animation = .spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)
      }
      HStack {
        Text("Version")
        Spacer()
        Text("v78-30b8c38")
          .lineLimit(1)

      }

      Spacer()

      Button("Delete") {
        storedRelays.deleteItem(item: item)
        presentationMode.wrappedValue.dismiss()
      }
      .padding()
    }
    .onAppear {
      editItemAddress = item.address
    }

    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {

        Button {
          if editItemAddress.isEmpty {
            //Empty address
            editItemAddress = item.address
          } else {
            storedRelays.updateItem(item: item, address: editItemAddress, state: item.state)
            presentationMode.wrappedValue.dismiss()
          }

        } label: {
          Text("Save")
        }

      }
      ToolbarItem(placement: .principal) {
        Text(item.address)
      }
    }

  }
}

struct relayManager_Previews: PreviewProvider {
  static var previews: some View {
    RelayManager()
  }
}
