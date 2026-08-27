// a

import SwiftData
import SwiftUI

struct floatingToolbarView: View {

  // FLOATING TOOLBAR VARIABLES
  @ObservedObject var toolbarState: ToolbarState
  @EnvironmentObject var coordinator: Coordinator
  @EnvironmentObject var keyManager: KeyManager
  @Query private var userProfiles: [RUserProfile]
  var canInteract = true
  var onInteractionRequiresKey: (() -> Void)?
  var onMenuTap: (() -> Void)?
  var onProfileTap: (() -> Void)?
  var onMessagesTap: (() -> Void)?
  var isCollapsed = false

  private var toolbarPublicKey: String {
    keyManager.publicKey(for: keyManager.selectedKey) ?? keyManager.pendingPublicKey
  }

  private var toolbarPublicKeyHex: String? {
    keyManager.publicKeyHex(for: keyManager.selectedKey)
      ?? PublicKeyIdentity.publicKeyHex(from: keyManager.pendingPublicKey)
  }

  private var toolbarAvatarURL: URL? {
    guard let toolbarPublicKeyHex else { return nil }
    return userProfiles.first { $0.publicKey == toolbarPublicKeyHex }?.avatarUrl
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      if !isCollapsed {
        HStack(spacing: 4) {
          Button(action: triggerMenuTap) {
            ZStack {
              Circle()
                .fill(Color.primary.opacity(0.001))

              AvatarView(publicKey: toolbarPublicKey, url: toolbarAvatarURL, size: 38)
                .allowsHitTesting(false)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Menu")

          Divider()
            .frame(height: 22)
            .padding(.horizontal, 2)

          Button {
            onProfileTap?()
          } label: {
            toolbarIcon("person.fill")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Current Profile")

          if canInteract {
            Button {
              onMessagesTap?()
            } label: {
              toolbarIcon("message.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Messages")
          } else {
            Button {
              onInteractionRequiresKey?()
            } label: {
              toolbarIcon("message.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Messages")
          }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
          Capsule()
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }

      Button {
        if canInteract {
          toolbarState.newEventSheetIsShowing.toggle()
        } else {
          onInteractionRequiresKey?()
        }
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 24, weight: .semibold))
          .foregroundColor(.primary)
          .frame(width: 58, height: 58)
          .background(.ultraThinMaterial, in: Circle())
          .overlay {
            Circle()
              .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
          }
      }
      .buttonStyle(.plain)
      .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 10)
      .accessibilityLabel("New Post")
    }
    .frame(maxWidth: .infinity, alignment: isCollapsed ? .trailing : .center)
    .animation(.spring(response: 0.24, dampingFraction: 0.86), value: isCollapsed)
    .blurredSheet(.init(.ultraThinMaterial), show: $toolbarState.newEventSheetIsShowing) {
    } content: {
      NewEventView()
        .environmentObject(coordinator)
        .environmentObject(keyManager)
        .presentationDetents([.medium, .large])
    }
  }

  private func triggerMenuTap() {
    onMenuTap?()
  }

  private func toolbarIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 19, weight: .semibold))
      .foregroundColor(.primary)
      .frame(width: 46, height: 46)
      .contentShape(Circle())
  }
}

struct floatingToolbarView_Previews: PreviewProvider {
  static var previews: some View {
    floatingToolbarView(toolbarState: ToolbarState())
      .environmentObject(Coordinator())
      .environmentObject(KeyManager())
  }
}
