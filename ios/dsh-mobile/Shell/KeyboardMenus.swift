import SwiftUI
import UIKit

extension View {
    /// A menu on the composer (`Picker` `.menu`, `Menu`) opens in place, not through the
    /// shell, so `ShellModel` does not see it, and SwiftUI gives a menu no open callback. UIKit
    /// does: SwiftUI draws these menus with a `UIControl` that shows its menu as its primary
    /// action, and the control sends `.menuActionTriggered` just before the menu shows. This puts
    /// the keyboard away on that event. Not on touch down: the composer moves down with the
    /// keyboard, the touch ends outside the key, and the menu does not open.
    func dismissesKeyboardBeforeMenu() -> some View {
        background(MenuKeyboardHook())
    }
}

/// An empty view behind the menu, with the menu's frame. It finds the menu's `UIControl` near it
/// in the view tree and adds the action once (again when SwiftUI makes a new control).
private struct MenuKeyboardHook: UIViewRepresentable {
    func makeUIView(context: Context) -> MenuKeyboardHookView { MenuKeyboardHookView() }
    func updateUIView(_ view: MenuKeyboardHookView, context: Context) { view.setNeedsLayout() }
}

final class MenuKeyboardHookView: UIView {
    private static let action = UIAction.Identifier("dshm.keyboard.beforeMenu")
    private weak var hooked: UIControl?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        hook()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.hook() }
    }

    private func hook() {
        guard let window, !bounds.isEmpty else { return }
        if let hooked, hooked.window === window { return }
        let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: window)
        // The control is in a sibling's subtree: look a few levels up, the nearest level first.
        var ancestor = superview
        for _ in 0..<4 {
            guard let level = ancestor else { return }
            if let control = Self.menuControl(in: level, at: center, window: window, skipping: self) {
                control.addAction(UIAction(identifier: Self.action) { _ in Keyboard.dismiss() }, for: .menuActionTriggered)
                hooked = control
                return
            }
            ancestor = level.superview
        }
    }

    private static func menuControl(in view: UIView, at point: CGPoint, window: UIWindow, skipping hook: UIView) -> UIControl? {
        for sub in view.subviews where sub !== hook && !sub.isHidden {
            if let control = sub as? UIControl, control.showsMenuAsPrimaryAction,
               control.convert(control.bounds, to: window).contains(point) {
                return control
            }
            if let found = menuControl(in: sub, at: point, window: window, skipping: hook) { return found }
        }
        return nil
    }
}
