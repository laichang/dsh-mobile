import SwiftUI

/// S20 · the parts the workspace sheet (07) and the model sheet (M, X4) share: a grey group
/// title, a card of rows with hairlines, and a row with a check mark on the right.
struct PickerGroupTitle: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(DSHTheme.textTertiary)
            .padding(.horizontal, 4)
            .padding(.top, 18)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PickerCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 14)
            .background(DSHTheme.card, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(DSHTheme.hairline))
    }
}

struct PickerDivider: View {
    var body: some View {
        Rectangle().fill(DSHTheme.hairline).frame(height: 1)
    }
}

struct PickerRow<Label: View>: View {
    let id: String
    let checked: Bool
    var enabled = true
    @ViewBuilder var label: Label
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                label
                if checked {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DSHTheme.check)
                }
            }
            .font(.body)
            .foregroundStyle(DSHTheme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

extension View {
    /// The sheet's look: dark sheet color, inline title, the grabber.
    func pickerSheetChrome(title: String) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(DSHTheme.sheet.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DSHTheme.sheet, for: .navigationBar)
            .presentationDragIndicator(.visible)
            .presentationBackground(DSHTheme.sheet)
    }
}
