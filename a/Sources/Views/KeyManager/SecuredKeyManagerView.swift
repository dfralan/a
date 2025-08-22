//  a

import LocalAuthentication
import SwiftUI

// MARK: - Key Manager Secured View

struct KeyManagerSecuredView: View {

  @State private var isUnlocked = false

  var body: some View {
    VStack {
      if isUnlocked {
        KeyManagerView()
      }
    }
    .onAppear {
      authenticate()
    }
  }

  func authenticate() {
    let context = LAContext()
    var error: NSError?

    // check whether biometric authentication is possible
    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
      // it's possible, so go ahead and use it
      let reason = "We need to unlock your data."

      context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) {
        success, authenticationError in
        // authentication has now completed
        if success {
          isUnlocked = true
        } else {
          if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            // it's possible, so go ahead and use it
            let reason = "We need to unlock your data."

            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) {
              success, authenticationError in
              // authentication has now completed
              if success {
                isUnlocked = true
              } else {
                // there was a problem
              }
            }
          } else {
            // no passcode authentication
          }
        }
      }
    } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
      // it's possible, so go ahead and use it
      let reason = "We need to unlock your data."

      context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) {
        success, authenticationError in
        // authentication has now completed
        if success {
          isUnlocked = true
        } else {
          // there was a problem
        }
      }
    } else {
      // no passcode authentication
    }
  }
}
