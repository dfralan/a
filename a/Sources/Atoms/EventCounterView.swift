// a

import RealmSwift
import SwiftUI

// MARK: - New Posts Floating Capsule

struct NewPostsToastView: View {

  // LAUNCH OBJECTS TO OBSERVE
  @EnvironmentObject var nostrData: NostrData
  @ObservedResults(
    TextNoteVM.self, sortDescriptor: SortDescriptor(keyPath: "createdAt", ascending: false))

  // VARIABLES
  var textNoteResults
  var avatarUrls: [URL]
  var newTextNotes: [TextNoteVM] {
    return Array(textNoteResults.filter("createdAt > %@", nostrData.lastSeenDate))
  }

  var body: some View {
    HStack {

      // SIMPLE TOAST PILL
      HStack {

        // 3 LAST AVATARS PREVIEW
        HStack(spacing: -8) {
          ForEach(avatarUrls, id: \.self.absoluteString) { url in
            ZStack {
              AvatarView(url: url, size: 25)
            }
          }
        }

        // NEW NOTES COUNTER WITH ARROW
        if newTextNotes.count > 0 {
          HStack(spacing: 0) {
            Text(String(newTextNotes.count))
            Image(systemName: "chevron.up")
          }
        }
      }
      .font(.subheadline)
      .foregroundColor(.accentColor)
      .padding(6)
      .overlay(Capsule().stroke(Color(.tertiarySystemFill), lineWidth: 1))
      .background(.thinMaterial)
      .clipShape(Capsule())
      .shadow(color: Color.primary.opacity(0.1), radius: 4, x: 0, y: 0)

    }
    .padding()
  }
}
