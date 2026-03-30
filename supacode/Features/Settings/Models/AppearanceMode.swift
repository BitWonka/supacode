import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
  case system
  case light
  case dark

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .system:
      return "Auto"
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }

  var imageName: String {
    switch self {
    case .system:
      return "AppearanceAuto"
    case .light:
      return "AppearanceLight"
    case .dark:
      return "AppearanceDark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system:
      return nil
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }

  /// Resolves the color scheme, falling back to the system color scheme for `.system`.
  func resolved(systemColorScheme: ColorScheme) -> ColorScheme {
    colorScheme ?? systemColorScheme
  }
}
