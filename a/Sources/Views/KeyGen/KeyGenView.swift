// a

import LifeHash
import SwiftUI
import secp256k1

struct KeyGen: View {
  @State private var generator = generate_new_keypair()
  @State private var rmGeneratorRefreshID = UUID()
  @State private var secIsHide = true
  @State private var keysSaved = false
  @State private var rmGenerated = false
  @State private var progressBar: CGFloat = 0

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 25) {

          VStack {
            //PUBKEY
            let size: CGFloat = 100

            ZStack {
              // HASHED FINGERPRINT
              let hashInput: Data? = Data(generator.pubkey.utf8)
              let version: LifeHashVersion = .version2

              UIKitLifeHashView(hashInput: hashInput, version: version, size: size)
                .frame(width: size, height: size)

                // AVATAR
                //RMGenerator(url: URL(string: generator.pubkey), size: size)
                //.id(rmGeneratorRefreshID) // Refresh RMGenerator with a new ID

                .onAppear {
                  print(generator.pubkey)
                }
            }
            .clipShape(Squircle(cornerRadius: size / 2))
            HStack {

              VStack {
                // USERNAME
                Text("Anonymous")
                  .font(.title3).bold()
                HStack(alignment: .center, spacing: 2) {

                  Text("\(Text(generator.pubkey.prefix(8)))...")
                    .foregroundColor(.gray)

                  Image(systemName: "key.horizontal")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
              }
            }
          }

          /// Bech32 Public Key
          VStack(alignment: .leading) {
            Text("Your public key")
            HStack {
              HStack {
                accordionString(generator.pubkey_bech32, index: 12)
                  .lineLimit(1)
                  .foregroundColor(.gray)
                Spacer()
                Button {
                  withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
                    keysSaved = false
                    progressBar = 0.25
                    generator = generate_new_keypair()
                    rmGeneratorRefreshID = UUID()
                  }
                } label: {
                  Image(systemName: "arrow.clockwise")
                    .foregroundColor(.gray)
                    .font(.subheadline)
                }

              }
              .padding(10)
              .padding(.top, -2)
              .background(.thinMaterial)
              .cornerRadius(9)
              if rmGenerated {
                Button {
                  UIPasteboard.general.string = generator.pubkey_bech32
                  EfimerousManager.shared.showMessage("Public Key copied")
                } label: {
                  Image(systemName: "square.on.square")
                }
              }
            }
          }

          /// Bech32 Private Key
          VStack(alignment: .leading) {
            Text("Your private key")
            HStack {
              ZStack {
                HStack {
                  accordionString(generator.privkey_bech32!, index: 12)
                    .lineLimit(1)
                    .blur(radius: secIsHide ? 14 : 0)

                  Spacer()
                }
                Spacer()
                if secIsHide {
                  Text("Show key")
                }
              }
              .lineLimit(1)
              .foregroundColor(.gray)
              .padding(10)
              .padding(.top, -2)
              .background(.thinMaterial)
              .cornerRadius(9)
              .onTapGesture {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
                  secIsHide.toggle()
                }
              }

              if rmGenerated {
                Button {
                  UIPasteboard.general.string = generator.privkey_bech32
                  EfimerousManager.shared.showMessage("Private Key copied")
                } label: {
                  Image(systemName: "square.on.square")
                }
              }
            }

            Text(
              "Your private key is your password. If you lose this key, you will lose access to your account! Copy it and keep it in a safe place. There is no way to reset your private key."
            )
          }
        }
      }
      Spacer()
      VStack {
        if !rmGenerated { ProgressView() }
        if !keysSaved && rmGenerated {
          Text("Save your keys!")
            .font(.headline)
        }
      }
      .padding()

      ProgressView(value: progressBar)
      Button {
        if !keysSaved {
          keysSaved = true
          withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
            progressBar = 0.50
          }
        }

      } label: {
        HStack {
          Spacer()
          if !keysSaved {
            Text("I've already save my keys")
          } else {
            Text("Create")
          }

          Spacer()
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
          progressBar = 0.25
          rmGenerated = true
        }
      }
    }
    .padding()
  }
}

struct KeyGenerator_Previews: PreviewProvider {
  static var previews: some View {
    KeyGen()
  }
}
