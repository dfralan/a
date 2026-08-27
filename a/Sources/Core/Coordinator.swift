// a

import SwiftUI
import UIKit

// MARK: - Main Coordinator

class Coordinator: ObservableObject {

  // MARK: - Properties

  @AppStorage("blurredImages") var blurredImages: Bool = true  //  TODO: Load images only when unblurred
  @AppStorage("blurSensitiveMedia") var blurSensitiveMedia: Bool = true
  @AppStorage("attachmentLoadingMode") var attachmentLoadingMode: Int = AttachmentLoadingMode.askFirst.rawValue
  @AppStorage("themeMode") var themeMode: Int = 1
  @AppStorage("accentColor") var accentColor: Int = 1
  @AppStorage("saturationColor") var saturationColor: Double = 0.99
  /// Works on main app saturation, focus mode should work on independent mode
  @AppStorage("notifyMeAbout") var notifyMeAbout: Int = 0
  @AppStorage("cloudService") var cloudService: Int = 1
  @AppStorage("selectedFontSize") var selectedFontSize: FontSize = .medium

  // MARK: - Coordinator Initializer

  init() {
    /// Override UI Theme mode
    UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self])
      .overrideUserInterfaceStyle = (themeModeSwitcherUI)

    /// Override UI Accent Color
    UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = UIColor(
      accentColorSwitcher)
  }

  /// Theme mode switcher (also override system UI to keep theme selection on pop up alerts)
  var themeModeSwitcherUI: UIUserInterfaceStyle {
    switch themeMode {
    case 1:
      return .light
    case 2:
      return .dark
    default:
      return .unspecified
    }
  }

  /// Theme Mode Setter
  func setThemeMode(_ value: Int) {
    themeMode = value
    UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self])
      .overrideUserInterfaceStyle = (themeModeSwitcherUI)
  }

  /// Accent Color Switcher
  var accentColorSwitcher: Color {
    selectedAccentColor.color
  }

  var selectedAccentColor: AccentColorOption {
    AccentColorOption(rawValue: accentColor) ?? .indigo
  }

  var accentColorTitle: String {
    selectedAccentColor.title
  }

  /// File cloud service switcher
  var cloudServiceSwitcher: String {
    FileCloudProviderStore.shared.selectedProviderTitle
  }

  var fileCloudProvider: FileCloudProvider? {
    FileCloudProviderStore.shared.selectedProvider
  }

  /// Tint Color Setter
  func setAccentColor(_ value: Int) {
    accentColor = value
    UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = UIColor(
      accentColorSwitcher)

  }

  /// Get actual system font size
  func getSystemTextSize() -> CGFloat {
    let font = UIFont.preferredFont(forTextStyle: .body)
    let fontMetrics = UIFontMetrics(forTextStyle: .body)
    let scaledFont = fontMetrics.scaledFont(for: font)

    return scaledFont.pointSize
  }

  /// Saturation Color Setter
  func setSaturationColor(_ value: Double) {
    saturationColor = value
  }

  /// Notification filter
  func setNotifyMeAbout(_ value: Int) {
    notifyMeAbout = value
  }

  var selectedAttachmentLoadingMode: AttachmentLoadingMode {
    AttachmentLoadingMode(rawValue: attachmentLoadingMode) ?? .askFirst
  }

  var attachmentLoadingModeTitle: String {
    selectedAttachmentLoadingMode.title
  }

  func setAttachmentLoadingMode(_ value: Int) {
    attachmentLoadingMode = value
  }

  /// Return true if is an iPhone
  var isAnIphone: Bool {
    return
      !(UIDevice.current.userInterfaceIdiom == .mac || UIDevice.current.userInterfaceIdiom == .pad)
  }

  /// Selected font size
  var selectedFontSizeValue: CGFloat {
    get {
      CGFloat(FontSize.allCases.firstIndex(of: selectedFontSize) ?? 0)
    }
    set {
      selectedFontSize = FontSize.allCases[Int(newValue)]
    }
  }

  /// Font size cases
  enum FontSize: String, CaseIterable {
    case extraSmall = "Extra Small"
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    case extraLarge = "Extra Large"
    case extraExtraLarge = "Extra Extra Large"
    case extraExtraExtraLarge = "Extra Extra Extra Large"
    case accessibilityMedium = "Accessibility Medium"

    var fontSizeValue: CGFloat {
      switch self {
      case .extraSmall:
        return 10
      case .small:
        return 12
      case .medium:
        return 16
      case .large:
        return 20
      case .extraLarge:
        return 24
      case .extraExtraLarge:
        return 28
      case .extraExtraExtraLarge:
        return 32
      case .accessibilityMedium:
        return 36
      }
    }
  }

  enum AccentColorOption: Int, CaseIterable, Identifiable {
    case purple = 0
    case indigo = 1
    case blue = 2
    case green = 3
    case yellow = 4
    case orange = 5
    case pink = 6

    var id: Int {
      rawValue
    }

    var title: String {
      switch self {
      case .purple: return "Purple"
      case .indigo: return "Indigo"
      case .blue: return "Blue"
      case .green: return "Green"
      case .yellow: return "Yellow"
      case .orange: return "Orange"
      case .pink: return "Pink"
      }
    }

    var color: Color {
      switch self {
      case .purple: return .purple
      case .indigo: return .indigo
      case .blue: return .blue
      case .green: return .green
      case .yellow: return .yellow
      case .orange: return .orange
      case .pink: return .pink
      }
    }
  }

  enum AttachmentLoadingMode: Int, CaseIterable, Identifiable {
    case automatically = 0
    case askFirst = 1
    case sensitiveOnly = 2

    var id: Int {
      rawValue
    }

    var title: String {
      switch self {
      case .automatically: return "Automatically"
      case .askFirst: return "Ask First"
      case .sensitiveOnly: return "Sensitive Only"
      }
    }
  }

}
