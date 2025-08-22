// a

import CoreImage.CIFilterBuiltins
import Foundation
import RealmSwift
import SDWebImageSwiftUI
import SwiftUI

// MARK: - QRView

struct QRView: View {

  // MARK: - Properties

  /// Navigation enviroment context
  @EnvironmentObject var nostrData: NostrData
  @EnvironmentObject var navigation: Navigation

  /// Realm Object of the actual user profile
  @ObservedRealmObject var userProfile: RUserProfile

  /// Sharing screenshot sheet state
  @State private var isShowingShareSheet = false

  // MARK: - Main View

  var body: some View {

    let avatarUrl = userProfile.avatarUrl
    let username = userProfile.name.isValidName() ? ("@" + userProfile.name) : "Anonymous"
    let pubkey = userProfile.publicKey
    let pubkey_bech32 = bech32_pubkey(pubkey) ?? pubkey
    let qrURL = "nostr:\(pubkey_bech32)"

    VStack {
      VStack {
        VStack {
          Image(uiImage: generateQRCodeImage(url: qrURL))
            .interpolation(.none)
            .resizable()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .background(AnimatedBackground(blurRadius: 10))
        }
        .frame(width: 220, height: 220, alignment: .center)
        HStack(alignment: .top) {
          AvatarView(url: avatarUrl, size: 40)
          VStack(alignment: .leading) {
            Text(username)
              .bold()

            (Text(pubkey_bech32) + Text(Image(systemName: "key.horizontal")))
              .font(.caption2)
              .textSelection(.enabled)
              .onAppear {
                print(pubkey_bech32)
              }
          }
          Spacer()
        }

        .padding(.vertical)
      }
      .frame(width: 220, alignment: .center)

    }

    .navigationTitle("")

    .toolbar {

      ToolbarItem(placement: .principal) {
        Text("QR Code")
      }

      ToolbarItem(placement: .navigationBarTrailing) {

        /// Main Menu in QRView
        Menu {
          /// Make a screenshoot of the QR of the view and share it
          Button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
              captureScreenshotAndShare()
            }
          } label: {
            Text("Capture and Share")
          }

          /// Copy Bech32 Public key
          Button {
            UIPasteboard.general.string = pubkey_bech32
          } label: {
            Text("Copy Public Key")
          }

          /// Copy Bech32 Public key
          Button {
            UIPasteboard.general.string = pubkey
          } label: {
            Text("Copy Encoded Public Key")
          }

        } label: {
          Image(systemName: "ellipsis")
        }
      }
    }
  }
}

struct QRView_Previews: PreviewProvider {
  static var previews: some View {
    QRView(userProfile: RUserProfile.preview)
  }
}
