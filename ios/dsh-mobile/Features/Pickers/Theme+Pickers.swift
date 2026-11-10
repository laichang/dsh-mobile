import SwiftUI

/// Tokens of the picker sheets (07, M, X4) that `DSHTheme` does not have. The values are the
/// design kit's own (`design/kit/kit.css` `.sheet`, `.lst`, `.field`). The sheet color itself is
/// `DSHTheme.sheet` from `Theme+ApprovalSheet.swift` (the same kit value).
extension DSHTheme {
    /// The path field (`.field`).
    static let field = Color(hex: 0x0E0E10)
    /// The check mark of a picked row (`.lst .it .ck`).
    static let check = Color(hex: 0x8EA2FF)
}
