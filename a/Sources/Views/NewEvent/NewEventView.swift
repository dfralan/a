// a

import Foundation
import NostrKit
import RealmSwift
import SwiftUI

struct NewEventView: View {

  @State private var selectedPostingOptions: Set<String> = []

  @State private var newEvent = ""

  // TOOLBAR STATE
  @StateObject var toolbarState = ToolbarState()
  @StateObject var coordinator = Coordinator()
  @Environment(\.presentationMode) var presentationMode

  var body: some View {
    VStack {
      HStack {
        Button {

          presentationMode.wrappedValue.dismiss()

          print("Dismiss event!")
        } label: {
          Text("Cancel")
        }
        .buttonStyle(.plain)

        Spacer()

        Button {
          if !newEvent.isEmpty {
            do {
              let keyPair = try KeyPair(
                privateKey: "df9aae2ac8233ffa210a086c54059d02ba3247dab1130dad968f28f036326a83")
              let postEvent = try PostEventContent(keyPair: keyPair, content: newEvent)

              selectedPostingOptions.forEach { option in

                EfimerousManager.shared.showMessage("Posted on \(option)")
                postEvent.sendToNostr(relayUrl: URL(string: option)!)

              }
              newEvent = ""
              print("Posting event successful!")
              presentationMode.wrappedValue.dismiss()
            } catch {
              do {
                let keyPair = try KeyPair(
                  privateKey: "df9aae2ac8233ffa210a086c54059d02ba3247dab1130dad968f28f036326a83")
                let postEvent = try PostEventContent(keyPair: keyPair, content: newEvent)
                postEvent.saveToRealm()
              } catch {
                print("Error: \(error)")
              }
              print("Error posting event: \(error), saving to Realm to try later maybe.")
            }
          }

        } label: {
          Text("Post")
        }
        .buttonStyle(.borderedProminent)
        //.tint(.white)
        //.background(AnimatedBackground(blurRadius: 5))

      }
      ScrollView {
        HStack(alignment: .top) {
          AvatarView(size: 70)
          TextField("Share something", text: $newEvent, axis: .vertical)
            .textFieldStyle(TextAreaStyle())
          //.lineLimit(3)
        }
      }
      Spacer()
      PostingOn(selectedOptions: $selectedPostingOptions)
    }

    .padding()

  }
}

struct NewEventView_Previews: PreviewProvider {
  static var previews: some View {
    NewEventView()
  }
}

//BLURRED SHEET

extension View {
  // MARK: Custom View Modifier
  func blurredSheet<Content: View>(
    _ style: AnyShapeStyle, show: Binding<Bool>,
    onDismiss:
      @escaping () -> Void, @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    self
      .sheet(isPresented: show, onDismiss: onDismiss) {
        content()
          .background(RemovebackgroundColor())
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background {
            Rectangle()
              .fill(style)
              .ignoresSafeArea(.container, edges: .all)
          }
      }
  }
}

// MARK: Helper View
struct RemovebackgroundColor: UIViewRepresentable {
  func makeUIView(context: Context) -> UIView {
    return UIView()
  }
  func updateUIView(_ uiView: UIView, context: Context) {
    DispatchQueue.main.async {
      uiView.superview?.superview?.backgroundColor = .clear
    }
  }
}
