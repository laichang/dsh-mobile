import SwiftUI

/// S21 · what the hosts screens ask of the app: pair a new host, and forget a host after this
/// device lost its access to it (a revoke of this device). With no host left, the app shows 08.
/// The app sets it at the root (`dsh_mobileApp`), so sheets get it too.
struct HostActions {
    var pair: () -> Void = {}
    var forget: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var hostActions = HostActions()
}

extension View {
    /// S21 · a tap on the "2 / 3" hosts pill in the drawer opens the hosts sheet (H). The pill
    /// keeps its identifier (`drawer.hosts`) and value; it gets the button trait.
    func opensHostsSheet() -> some View { modifier(OpensHostsSheet()) }
}

private struct OpensHostsSheet: ViewModifier {
    @Environment(ShellModel.self) private var shell

    func body(content: Content) -> some View {
        content
            .contentShape(.capsule)
            .onTapGesture { shell.present(.hosts) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { shell.present(.hosts) }
    }
}
