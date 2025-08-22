// a

import SwiftUI

struct floatingToolbarView: View {

  // FLOATING TOOLBAR VARIABLES
  @ObservedObject var toolbarState: ToolbarState

  var body: some View {
    HStack {

      //EXPAND BUTTONS
      //MAIN BUTTONS

      HStack {
        Button {
          toolbarState.homeTapped += 1
        } label: {
          AvatarView(size: 30)
        }
        if toolbarState.expanded {
          NavigationLink {
            MessagesView(userProfile: RUserProfile.preview)
          } label: {
            Image(systemName: "paperplane")
              .font(.title2)
              .foregroundColor(.accentColor)
          }
          NavigationLink {
            KeyManagerView()
            //SecuredView()
            //KeyGenerator()
            //RelayManager()
          } label: {
            Image(systemName: "aqi.medium")
              .font(.title2)
              .foregroundColor(.accentColor)
          }
        }

        Button {
          toolbarState.newEventSheetIsShowing.toggle()
        } label: {
          Image(systemName: "plus")
            .font(.title2)
            .foregroundColor(.accentColor)
        }
      }
      .padding(8)
      .overlay(Capsule().stroke(Color(.tertiarySystemFill), lineWidth: 1))
      .background(.thinMaterial)
      .clipShape(Capsule())
      .shadow(color: Color.primary.opacity(0.1), radius: 4, x: 0, y: 0)

      Button {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
          toolbarState.expanded.toggle()
        }
      } label: {
        ZStack {
          Circle()
            .frame(width: 4, height: 4)
            .offset(x: (toolbarState.expanded ? 0 : -8), y: (toolbarState.expanded ? -8 : 0))

          Circle()
            .frame(width: 4, height: 4)
            .offset(x: (toolbarState.expanded ? 0 : 0), y: (toolbarState.expanded ? 0 : 0))

          Circle()
            .frame(width: 4, height: 4)
            .offset(x: (toolbarState.expanded ? 0 : 8), y: (toolbarState.expanded ? 8 : 0))
        }
        .frame(width: toolbarState.expanded ? 10 : 20, height: toolbarState.expanded ? 20 : 10)

      }
      .padding(8)
      .overlay(Capsule().stroke(Color(.tertiarySystemFill), lineWidth: 1))
      .background(.thinMaterial)
      .clipShape(Capsule())
      .shadow(color: Color.primary.opacity(0.1), radius: 4, x: 0, y: 0)
    }
    .blurredSheet(.init(.ultraThinMaterial), show: $toolbarState.newEventSheetIsShowing) {
    } content: {
      NewEventView()
        .presentationDetents([.medium, .large])
    }
  }
}

struct floatingToolbarView_Previews: PreviewProvider {
  static var previews: some View {
    floatingToolbarView(toolbarState: ToolbarState())
  }
}
