import SwiftUI

/// S14 · drawer tokens on top of `DSHTheme` (frozen). Values from design/board.html, screen 02.
extension DSHTheme {
    /// The highlighted row of the session that shows now.
    static let drawerCurrentRow = Color.white.opacity(0.06)
    /// The rule after a host name.
    static let drawerHostRule = Color.white.opacity(0.12)
    /// The background of the "2 / 3" hosts pill and the new-session button.
    static let drawerPill = Color.white.opacity(0.08)
    /// Size of the status dots.
    static let drawerDot: CGFloat = 8
}
