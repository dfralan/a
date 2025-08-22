// a

import Kingfisher
import SwiftUI

// MARK: - Settings View

struct SettingsView: View {

  // MARK: - Properties

  /// Main coordinator observable class with app storaged properties
  @StateObject var coordinator = Coordinator()

  @State private var playNotificationSounds = false

  @State private var sendReadReceipts = false

  var body: some View {
    Form {

      // Accessibility selection
      Section(header: Text("App Font Size")) {
        VStack {

          HStack {
            Text("aA")
              .font(.system(size: 14))
            Slider(
              value: $coordinator.selectedFontSizeValue,
              in: 0...CGFloat(Coordinator.FontSize.allCases.count - 1),
              step: 1
            )
            Text("aA")
              .font(.system(size: 26))
          }
        }
      }

      // Saturation section
      Section(header: Text("Saturation")) {
        Slider(value: $coordinator.saturationColor, in: 0.00...0.99, step: 0.01)
      }

      // Appearance section
      Section(header: Text("Appearance")) {

        Picker("Select a theme", selection: $coordinator.themeMode) {
          Text("Auto").tag(0)
          Text("Light").tag(1)
          Text("Dark").tag(2)
        }
        .pickerStyle(SegmentedPickerStyle())

        HStack {
          Image(systemName: "circle.fill")
            .foregroundColor(.accentColor)

          Picker("Accent Color", selection: $coordinator.accentColor) {
            Text("Purple").tag(0)
            Text("Indigo").tag(1)
            Text("Blue").tag(2)
            Text("Green").tag(3)
            Text("Yellow").tag(4)
            Text("Orange").tag(5)
            Text("Pink").tag(6)
          }
        }
      }

      // Notifications section
      Section(header: Text("Notifications")) {

        Picker("Notify Me About", selection: $coordinator.notifyMeAbout) {
          Text("Messages").tag(0)
          Text("Mentions").tag(1)
          Text("Anything").tag(2)
        }

        Toggle("Play notification sounds", isOn: $playNotificationSounds)

        Toggle("Send read receipts", isOn: $sendReadReceipts)

      }

      // Storage section
      Toggle("Allways blur images", isOn: $coordinator.blurredImages)

      Section(header: Text("PREFERENCES")) {
        Picker("File cloud service", selection: $coordinator.cloudService) {
          Text("void.cat").tag(0)
          Text("nostr.build").tag(1)
          Text("nostrimg.com").tag(2)
        }
        Button("Clear Image Cache") {
          ImageCache.default.clearMemoryCache()
          ImageCache.default.clearDiskCache()
        }
      }
    }
    .tint(.accentColor)
  }
}

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
  }
}
