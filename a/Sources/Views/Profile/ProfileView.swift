// a

import SwiftUI

struct ProfilePrimaryView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "person.crop.circle")
        .font(.system(size: 48, weight: .regular))
        .foregroundColor(.secondary)

      Text("Profile")
        .font(.title3.weight(.semibold))

      Text("Open profiles from the feed or search results.")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

struct ProfilePrimaryView_Previews: PreviewProvider {
  static var previews: some View {
    ProfilePrimaryView()
  }
}
