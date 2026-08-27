// a

import LocalAuthentication
import SwiftUI

enum KeyAccessAuthenticator {
  static func authenticate(reason: String) async -> Bool {
    let context = LAContext()
    context.localizedCancelTitle = "Cancel"
    context.localizedFallbackTitle = "Use Passcode"

    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      return false
    }

    return await withCheckedContinuation { continuation in
      context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) {
        success,
        _ in
        continuation.resume(returning: success)
      }
    }
  }

  static var isAvailable: Bool {
    let context = LAContext()
    var error: NSError?
    return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
  }
}

struct KeyManagerSecuredView: View {
  var body: some View {
    KeyAccessGate(
      title: "Unlock Keys",
      message: "Use Face ID, Touch ID, or your device passcode to manage saved keys.",
      reason: "Unlock saved keys."
    ) {
      KeyManagerView()
    }
  }
}

struct KeyAccessGate<Content: View>: View {
  let title: String
  let message: String
  let reason: String
  let content: Content

  @Environment(\.scenePhase) private var scenePhase
  @State private var isUnlocked = false
  @State private var isAuthenticating = false
  @State private var authenticationMessage: String?

  init(
    title: String,
    message: String,
    reason: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.message = message
    self.reason = reason
    self.content = content()
  }

  var body: some View {
    Group {
      if isUnlocked {
        content
      } else {
        lockedView
      }
    }
    .onAppear(perform: authenticate)
    .onChange(of: scenePhase) { _, phase in
      if phase == .background {
        isUnlocked = false
      }
    }
  }

  private var lockedView: some View {
    NavigationStack {
      VStack(spacing: 18) {
        Image(systemName: "lock.shield")
          .font(.system(size: 46, weight: .regular))
          .foregroundStyle(.secondary)

        VStack(spacing: 7) {
          Text(title)
            .font(.title3.weight(.semibold))

          Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 310)
        }

        if let authenticationMessage {
          Text(authenticationMessage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)
        }

        Button(action: authenticate) {
          HStack(spacing: 8) {
            if isAuthenticating {
              ProgressView()
            }
            Text(isAuthenticating ? "Unlocking" : "Unlock")
              .fontWeight(.semibold)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isAuthenticating || !KeyAccessAuthenticator.isAvailable)
        .frame(maxWidth: 260)
      }
      .padding(28)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Keys")
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  private func authenticate() {
    guard !isUnlocked && !isAuthenticating else { return }

    guard KeyAccessAuthenticator.isAvailable else {
      authenticationMessage = "Set a device passcode to protect saved keys."
      return
    }

    isAuthenticating = true
    authenticationMessage = nil

    Task {
      let didAuthenticate = await KeyAccessAuthenticator.authenticate(reason: reason)

      await MainActor.run {
        isAuthenticating = false
        isUnlocked = didAuthenticate
        authenticationMessage = didAuthenticate ? nil : "Authentication was canceled."
      }
    }
  }
}
