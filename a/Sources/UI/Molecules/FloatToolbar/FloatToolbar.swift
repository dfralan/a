// a

import Foundation

// MARK: - Toolbar Class Module

class ToolbarState: ObservableObject {
  @Published var homeTapped: Int = 0
  @Published var newEventSheetIsShowing = false
}
