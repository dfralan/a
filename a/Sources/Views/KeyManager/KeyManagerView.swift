import LifeHash
/// Life Hash Library for hash visualization
import SwiftUI

// MARK: - Key Manager View

struct KeyManagerView: View {

  // MARK: - Properties

  /// Initialize KeyManager instance to manage keys
  @ObservedObject var keyManager = KeyManager()

  /// Key entered into the textfield
  @State private var inputKey = ""

  /// Determines whether the view is in edit mode
  @State private var isEditing = false

  /// Whether the entered key is valid
  @State private var isInputKeyValid = false

  /// Helper or validation message to display
  @State private var validationMessage = ""

  /// Alert for deleting all keys
  @State private var showDeleteAllKeysAlert = false

  /// Alert for deleting a single key when is a private one
  @State private var showDeleteKeyAlert = false

  /// Focus on textfield when there
  @State private var isFocused: Bool = false
  @FocusState private var textFieldFocus: Bool

  // MARK: - Body

  var body: some View {
    NavigationStack {
      /// Display list of keys
      VStack(spacing: 15) {
        HStack {

          /// Textfield for entering a new key
          HStack {
            TextField("Paste a new nsec or npub...", text: $inputKey)
              .focused($textFieldFocus)
            /// Show delete content button if textfield is not empty
            if !inputKey.isEmpty {
              Button {
                inputKey = ""
                validationMessage = ""
                isInputKeyValid = false
              } label: {
                Image(systemName: "delete.left")
              }
            }
          }
          .RoundedThinStyle()

          /// Listen for changes in the textfield
          .onChange(of: inputKey) { newValue in
            if !inputKey.isEmpty {
              withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
                if keyManager.isValidBech32EncodedKey(inputKey) {
                  isInputKeyValid = true
                  validationMessage = "Valid key"
                } else {
                  isInputKeyValid = false
                  validationMessage =
                    "The key must start with 'nsec' or 'npub' and be 63 characters long."
                }
              }
            }
          }

          /// Button for adding a key (only visible when key is valid)
          if isInputKeyValid {
            Button {
              isEditing = false
              keyManager.saveKey(inputKey)
              inputKey = ""
              validationMessage = ""
              isInputKeyValid = false
            } label: {
              Image(systemName: "plus")
            }
          }
        }

        /// Display validation message
        if !validationMessage.isEmpty {
          HStack {
            Text(validationMessage)
            Spacer()
          }
        }
        ScrollView(showsIndicators: false) {
          VStack(spacing: 15) {
            ForEach(keyManager.storedKeys, id: \.self) { key in
              HStack(spacing: 10) {
                /// Display key information
                KeyItemView(key: key)
                  //.padding(10)
                  //.background(.ultraThinMaterial)
                  .cornerRadius(9)
                /// Delete key button (only visible when editing)
                if isEditing {
                  Spacer()
                  Button(role: .destructive) {
                    keyManager.deleteKey(key)
                  } label: {
                    Image(systemName: "trash")
                  }
                }
              }
              Divider()

            }
          }

          if isEditing {
            /// Content when there is no keys stored
            if keyManager.storedKeys.count > 1 {
              ///Delete all keys button (Only visible when there is more than one key)
              Button(role: .destructive) {
                showDeleteAllKeysAlert = true
              } label: {
                Text("Delete All Keys")
                Image(systemName: "trash")
              }.padding()
            }
            /// Content when there is no keys stored
            if keyManager.storedKeys.count < 1 {
              Button {
                isFocused = true
                textFieldFocus = true
              } label: {
                Text("No keys added")
              }
            }
          }

        }

      }
      .padding()

      /// Retrieve existent stored keys on view appear
      .onAppear {
        keyManager.saveKey("nsec1c6ccyshx0etgyzgxe29d0q08r6e0rg5epfdgj2et4sl5mt3k9p8s63na24")
        keyManager.saveKey("npub19fm9h69lna6wrejzs4k0pqmssug8pt3z37c5l3jqny9ghu3t4rzq7l3fwq")
        keyManager.loadKeys()
      }

      /// Hide keyboard when tap outside content
      .onTapGesture {
        UIApplication.shared.sendAction(
          #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
      }

      .navigationTitle("Key Manager")

      /// Toolbar elements
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {

          /// Edit button toggle
          if !keyManager.storedKeys.isEmpty {
            Button {
              withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
                isEditing.toggle()
              }
            } label: {
              Text(isEditing ? "Done" : "Edit")
            }
          }
        }
      }

      /// Delete all confirmation alert
      .alert(isPresented: $showDeleteAllKeysAlert) {
        Alert(
          title: Text("Delete all saved keys"),
          message: Text(
            "Are you sure you want to delete all keys? If you do not have a backup with them you will lose access forever."
          ),
          primaryButton: .destructive(Text("Delete All")) {
            ///Delete all keys stored
            keyManager.deleteAllKeys()
            /// Hide alert
            showDeleteAllKeysAlert = false
          },
          secondaryButton: .cancel()
        )
      }
    }
  }
}

// MARK: - Key Manager View

struct KeyItemView: View {

  // MARK: - Properties

  /// Passed key to create view
  @State var key: String

  /// Private key visualization state
  @State private var privateKeyIsShowing = false

  /// Blurred private key toggle
  @State private var isBlurred = false

  var body: some View {
    HStack {
      let version: LifeHashVersion = .version2
      let size: CGFloat = 50
      if let decoded = decode_bech32_key(key) {

        /// Handling public key
        if case .pub(let publicKeyHexed) = decoded {
          let hashedData: Data? = Data(publicKeyHexed.utf8)
          /// HashLive digital pingerprint image
          UIKitLifeHashView(hashInput: hashedData, version: version, size: size)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 9))
          /// Bech32 encoded public and private keys
          VStack(alignment: .leading) {
            VStack(alignment: .leading) {
              if privateKeyIsShowing {
                Text(key)
                  .onTapGesture {
                    UIPasteboard.general.string = key
                  }

              } else {
                accordionString(key, index: 10)
                Text("Public key only")
                  .foregroundColor(.secondary)
                  .font(.subheadline)
              }

            }
          }
          Spacer()

          /// Show private key button toggle
          Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
              privateKeyIsShowing.toggle()
            }
          } label: {
            Image(systemName: "chevron.down")
              .rotationEffect(Angle.degrees(privateKeyIsShowing ? 540 : 0))
          }
        }/// Handling a private key
        else if case .sec(let privKeyHex) = decoded {
          /// Decoding private key bech32 to hex
          let publicKeyHex = privkey_to_pubkey(privkey: privKeyHex)
          /// Building a full keypair from decoded private key
          let keypair = Keypair(pubkey: publicKeyHex!, privkey: privKeyHex)
          /// Declaring string data
          let publicKey = keypair.pubkey_bech32
          let privateKey = keypair.privkey_bech32!
          /// HashLive digital pingerprint image
          let hashInput: Data? = Data(publicKeyHex!.utf8)
          /// Bech32 encoded public and private keys
          VStack(alignment: .leading) {

            HStack {
              UIKitLifeHashView(hashInput: hashInput, version: version, size: size)
                .frame(width: size, height: size)
                .onAppear {
                  print(hashInput?.bytes)
                }
                //.cornerRadius(9)
                .clipShape(RoundedRectangle(cornerRadius: 9))
              VStack(alignment: .leading) {
                if privateKeyIsShowing {
                  Text(publicKey)
                    .onTapGesture {
                      UIPasteboard.general.string = publicKey
                    }

                } else {
                  accordionString(publicKey, index: 10)
                  Text("Full keypair")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                }

              }

              Spacer()

              /// Show private key button toggle
              Button {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
                  privateKeyIsShowing.toggle()
                }
              } label: {
                Image(systemName: "chevron.down")
                  .rotationEffect(Angle.degrees(privateKeyIsShowing ? 540 : 0))
              }
            }
            if privateKeyIsShowing {
              /// Private key
              VStack(alignment: .leading, spacing: 10) {
                Text("Your private key:")
                Button {
                  isBlurred.toggle()
                } label: {
                  ZStack {
                    if !isBlurred {
                      HStack {
                        Text("Show key")
                        Image(systemName: "lock")
                      }
                    }

                    Text(privateKey)
                      .lineLimit(privateKeyIsShowing ? 12 : 0)
                      .foregroundColor(.primary)
                      .blur(radius: isBlurred ? 0 : 10)
                  }
                  .frame(maxWidth: .infinity)

                }
                .buttonStyle(.bordered)
                Text(
                  "Sharing keys can compromise the security of the encrypted data. Please do not share this key with anyone."
                )
                .font(.subheadline)
                .foregroundColor(.red)
                HStack {
                  Button {
                    UIPasteboard.general.string = privateKey
                  } label: {
                    HStack {
                      Text("Copy private key")
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                  }
                  .buttonStyle(.bordered)
                  Button {
                    UIPasteboard.general.string = privateKey
                  } label: {
                    HStack {
                      Text("Copy public key")
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                  }
                  .buttonStyle(.borderedProminent)

                }
              }
            }
          }
        }
      }
    }
  }
}

struct KeychainView_Previews: PreviewProvider {
  static var previews: some View {
    KeyManagerView()
  }
}
