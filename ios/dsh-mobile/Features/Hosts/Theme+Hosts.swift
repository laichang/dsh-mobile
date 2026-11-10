import SwiftUI

/// Hosts and control tokens on top of `DSHTheme`. Values from the design kit, screens H, X2 and X3.
extension DSHTheme {
    /// The sheets of the hosts screens (H, X2).
    static let hostsSheet = Color(hex: 0x1C1C1E)
    /// Cards on those sheets and on 01 (X3): device and audit lists, the all-offline card.
    static let hostsCard = Color(hex: 0x202124)
    /// The rounded square behind a host's icon.
    static let hostsIcon = Color.white.opacity(0.06)
    /// The pair button at the bottom of the hosts sheet.
    static let hostsButton = Color.white.opacity(0.08)
}
