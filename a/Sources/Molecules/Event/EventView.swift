// a

import AVKit
import Kingfisher
import RealmSwift
import SDWebImageSwiftUI
import SwiftUI

// MARK: - Event View

struct EventView: View {

  // MARK: - Properties

  /// Toolbar State
  @StateObject var toolbarState = ToolbarState()
  @StateObject var reactionsBarState = ReactionsBarState()

  // ENVIROMENT OBJECTS
  @EnvironmentObject var nostrData: NostrData
  @EnvironmentObject var navigation: Navigation

  // LAUNCH OBJECTS TO OBSERVE
  @ObservedRealmObject var textNote: TextNoteVM

  // EVENT ACTIONS DIALOG
  @State private var showActionEventDialog = false

  // INTERACTION TOGGLES
  @State private var lighted: Bool = false
  @State private var reposted: Bool = false
  @State private var commentSection: Bool = false

  // IMAGE BLUR AND FULLSCREEN MODE TOGGLES

  @StateObject var coordinator = Coordinator()
  @State private var isBlurred = true
  @State var isFullScreen = false

  var body: some View {

    let pubkey = textNote.publicKey
    let pubkey_bech32 = bech32_pubkey(pubkey) ?? pubkey

    VStack(alignment: .leading, spacing: 10) {

      // EVENT HEADER
      HStack(alignment: .top) {

        // EVENT INFO BLOCK
        HStack(alignment: .top) {

          // AVATAR IMAGE VIEW
          AvatarView(url: textNote.userProfile?.avatarUrl, size: 40)

          // USER INFO & TIMESTAMP
          VStack(alignment: .leading, spacing: 4) {

            // USERNAME & PUBKEY
            HStack(alignment: .center) {

              // USERNAME

              if let name = textNote.userProfile?.name, name.isValidName() {

                Text("@" + name)
                  .font(.subheadline).bold()
                  .lineLimit(1)
              } else {
                Text("Anonymous")
                  .font(.subheadline).bold()
              }

              // PUBKEY
              HStack(alignment: .center, spacing: 2) {
                (accordionString(pubkey_bech32, index: 8)
                  + Text(Image(systemName: "key.horizontal")))
                  .font(.caption)
              }
              .foregroundColor(.secondary)
            }

            // TIMESTAMP
            Text(textNote.createdAt, style: .relative)
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }
        // NAVIGATOR TO PROFILE PRIMARY VIEW ON TAP GESTURE
        .onTapGesture {
          if let userProfile = self.textNote.userProfile {
            self.navigation.homePath.append(Navigation.NavUserProfile(userProfile: userProfile))
          }
        }

        // EVENT ACTIONS DIALOG BUTTON
        Spacer()
        Button {
          UIPasteboard.general.string = (textNote.userProfile?.avatarUrl)?.absoluteString
          showActionEventDialog = true
        } label: {
          Image(systemName: "ellipsis")
        }
        .foregroundColor(.primary)
      }

      // EVENT CONTENT FORMATTED
      VStack(alignment: .leading) {
        if let content = textNote.contentFormatted {

          // VIDEO CASE
          if let videoUrl = textNote.videoUrl {
            let player = AVPlayer(url: videoUrl)
            VideoPlayer(player: player)
              .frame(height: 200)
              .background(.secondary.opacity(0.3))
              .cornerRadius(8)
          }

          // WEB IMAGE CASE
          else if let imageUrl = textNote.imageUrl {

            // IMAGE CONTAINER
            VStack(alignment: .leading) {

              // IMAGE CASE ACTION SWITCH
              switch imageUrl.pathExtension.lowercased() {

              // ANIMATED IMAGE CASE
              case "gif", "webp", "svg":
                AnimatedImage(url: imageUrl)
                  .placeholder {
                    ProgressView()
                  }
                  .resizable()
                  .aspectRatio(contentMode: .fill)
                  .scaledToFit()
                  .blur(radius: isBlurred ? 40 : 0)

                  .gesture(
                    TapGesture(count: 2)
                      // GO FULLSCREEN GESTURE
                      .onEnded({
                        withAnimation(
                          .spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)
                        ) {
                          isFullScreen = true
                        }
                      })
                      // UNBLURRED GESTURE
                      .exclusively(
                        before:
                          TapGesture()
                          .onEnded({
                            withAnimation {
                              self.isBlurred.toggle()
                            }
                          })
                      )
                  )

                  // FULLSCREEN VIEW
                  .fullScreenCover(isPresented: $isFullScreen) {
                    VStack(alignment: .trailing) {
                      Button {
                        isFullScreen = false
                      } label: {
                        Image(systemName: "xmark")
                      }
                      .padding()
                      .foregroundColor(.primary)
                      AnimatedImage(url: imageUrl)
                        .placeholder { ProgressView() }
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                          isFullScreen = false
                        }
                        .onTapGesture {
                          isFullScreen = false
                        }
                    }
                  }

              // DEFAULT IMAGE CASE
              default:
                let FKImage = KFImage(imageUrl)

                FKImage
                  .placeholder {
                    ProgressView()
                  }
                  .resizable()
                  .loadDiskFileSynchronously()
                  .cacheOriginalImage()
                  .transition(.fade(duration: 1))
                  .aspectRatio(contentMode: .fill)
                  .scaledToFit()
                  .blur(radius: isBlurred ? 40 : 0)
                  .gesture(
                    TapGesture(count: 2)
                      // GO FULLSCREEN GESTURE
                      .onEnded({
                        withAnimation(
                          .spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)
                        ) {
                          isFullScreen = true
                        }
                      })
                      // UNBLURRED GESTURE
                      .exclusively(
                        before:
                          TapGesture()
                          .onEnded({
                            withAnimation {
                              self.isBlurred.toggle()
                            }
                          })
                      )
                  )

                  // FULLSCREEN VIEW
                  .fullScreenCover(isPresented: $isFullScreen) {
                    VStack(alignment: .trailing) {
                      Button {
                        isFullScreen = false
                      } label: {
                        Image(systemName: "xmark")
                      }
                      .padding()
                      .foregroundColor(.primary)
                      FKImage
                        .placeholder { ProgressView() }
                        .resizable()
                        .loadDiskFileSynchronously()
                        .cacheOriginalImage()
                        .transition(.fade(duration: 1))
                        .aspectRatio(contentMode: .fit)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                          isFullScreen = false
                        }
                    }
                  }
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }

          //TYPED CONTENT
          Text(content)
            .font(.body)
            .padding(.vertical, 8)
        }
      }

      // SHOW COMMENTS BUTTON WITH COUNTER ELSE ADD COMMENT
      Button(action: {
      }) {
        Text("Show comments").font(.subheadline)
      }
      .buttonStyle(.plain)

      // REACTIONS BAR
      ReactionsBarView(reactionsBarState: reactionsBarState)
        .offset(x: -3)

      // ACTIONS SECTION
      HStack {
        Spacer()

        // ADD COMMENT OR REACTION
        Button {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
            reactionsBarState.expanded.toggle()
          }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 20, weight: .regular))
            .foregroundColor(.primary)
            .rotationEffect(Angle.degrees(reactionsBarState.expanded ? 45 : 0))
        }

        // SAT
        Button {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
            self.lighted.toggle()
          }
        } label: {
          Image(systemName: lighted ? "bolt.fill" : "bolt")
            .background(lighted ? AnimatedSatBackground(blurRadius: 10, opacity: 0.6) : nil)
        }
        .font(.system(size: 18, weight: .regular))
        .foregroundColor(lighted ? .orange : .primary)

        // REPOST
        Button {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
            self.reposted.toggle()
          }
        } label: {
          Image(systemName: "arrow.2.squarepath")
            .rotationEffect(Angle.degrees(reposted ? 180 : 0))
        }
        .font(.system(size: 18, weight: .regular))
        .foregroundColor(reposted ? .green : .primary)
      }
    }
    .onAppear {
      if !coordinator.blurredImages {
        isBlurred = false
      }
    }

    //EVENT ACTIONS DIALOG
    .confirmationDialog(
      "EventActions", isPresented: $showActionEventDialog
    ) {
      Button("Report", role: .destructive) {
      }
      Button("Block", role: .destructive) {
      }
      Button("Profile detail") {
      }
      Button("Copy event content") {
      }
      Button("Copy user pubkey") {
      }
      Button("Copy profile URL") {
      }
      Button("QR code") {
      }
    }  //message: {Text("You cannot undo this action.")}
  }
}
