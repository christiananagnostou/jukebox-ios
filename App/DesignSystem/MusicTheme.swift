import SwiftUI

enum MusicUI {
  private nonisolated static let accentColor: @Sendable (UITraitCollection) -> UIColor = { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.66, green: 0.76, blue: 0.92, alpha: 1)
      : UIColor(red: 0.29, green: 0.41, blue: 0.61, alpha: 1)
  }
  private nonisolated static let accentForeground: @Sendable (UITraitCollection) -> UIColor = {
    traits in
    traits.userInterfaceStyle == .dark ? .black : .white
  }
  static let tint = Color(uiColor: UIColor(dynamicProvider: accentColor))
  static let onTint = Color(uiColor: UIColor(dynamicProvider: accentForeground))
  static let canvas = adaptive(0xFAFAFA, 0x121212)
  static let panel = adaptive(0xEFEFEF, 0x222222)
  static let border = adaptive(0xD8D8D8, 0x383838)
  static let quiet = adaptive(0xE8E8E8, 0x292929)

  private nonisolated static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(
      uiColor: UIColor { traits in
        let value = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
          red: CGFloat((value >> 16) & 255) / 255,
          green: CGFloat((value >> 8) & 255) / 255,
          blue: CGFloat(value & 255) / 255, alpha: 1)
      })
  }
  static let artworkRadius: CGFloat = 6
  static let target: CGFloat = 44
  static let group: CGFloat = 12
  static let section: CGFloat = 24
}

enum MusicType {
  static let section = Font.headline.weight(.semibold)
  static let identity = Font.title3.weight(.semibold)
  static let primary = Font.subheadline
  static let secondary = Font.caption
  static let support = Font.caption2
  static let notice = Font.footnote
  static let control = Font.subheadline.weight(.medium)
}
