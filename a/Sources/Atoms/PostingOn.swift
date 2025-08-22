// a

import SwiftUI

// MARK: - Posting On View

struct PostingOn: View {

  @StateObject var storedRelays = StoredRelays()
  @Binding var selectedOptions: Set<String>
  /// Passing selected
  @State var includeSensitiveContent = false

  var body: some View {

    let options: [String] = storedRelays.relayItems.map { $0.address }
    VStack(alignment: .leading) {

      HStack(alignment: .top) {
        let formattedOptions = selectedOptions.sorted().map {
          $0.replacingOccurrences(of: "wss://", with: "")
        }
        let formattedText = "Posting on: \(formattedOptions.joined(separator: ", "))"

        Text(formattedText)
        Spacer()
        Button {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
            if selectedOptions.count == options.count {
              selectedOptions.removeAll()
            } else {
              selectedOptions = Set(options)
            }
          }
        } label: {
          HStack {
            Text(selectedOptions.count == options.count ? "Deselect All" : "Select All").bold()
          }
        }
      }
      WrappingHStack(horizontalSpacing: 12) {

        ForEach(options, id: \.self) { option in
          Button(action: {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2)) {
              if selectedOptions.contains(option) {
                selectedOptions.remove(option)
              } else {
                selectedOptions.insert(option)
              }
            }
          }) {
            HStack {
              let trimmedUrlString = option.replacingOccurrences(of: "wss://", with: "")
              Text(trimmedUrlString)
                .font(.subheadline)
                .padding(.horizontal, 5)
                .foregroundColor(selectedOptions.contains(option) ? Color.primary : Color.gray)
              ZStack {
                if selectedOptions.contains(option) {
                  Image(systemName: "checkmark.circle.fill")
                }
              }
            }
          }
          .padding(5)
          .background(.thinMaterial)
          .clipShape(
            Capsule()
          )
        }
      }
      Button {
        includeSensitiveContent.toggle()
      } label: {
        Toggle(isOn: $includeSensitiveContent) {
          HStack {
            Text("Includes Sensitive Content")
            Spacer()
          }
          .foregroundColor(includeSensitiveContent ? .accentColor : .gray)
        }
        .padding()
      }
    }
  }
}
