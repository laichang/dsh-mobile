import SwiftUI

/// First run (screen 08, STORY §6). With no paired computer, say what the phone does, what
/// the user needs (a computer with DSH and the bridge; same Wi-Fi or Tailscale), and offer the two
/// ways in: scan the QR the terminal prints, or paste the link printed under it.
///
/// Accessibility contract: `firstRun.purpose`, `firstRun.requiresHost`, `firstRun.step` (×2; the
/// second one is the network requirement), `pairing.scan`, `pairing.pasteLink`, `firstRun.setup`.
struct WelcomeView: View {
    let scan: () -> Void
    let paste: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DSHWordmark().padding(.top, 36)
                    Text("Connect your computer")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(DSHTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 36)
                    Text("Send tasks from your phone, follow their progress, and answer approval requests. DeepSeek Harness runs the tasks on your computer; the phone never calls a model.",
                         tableName: "FirstRun")
                        .font(.body)
                        .foregroundStyle(DSHTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("firstRun.purpose")
                        .padding(.top, 14)
                    ChannelCard().padding(.top, 24)
                    Text("You need a computer that runs DSH with the dsh-mobile bridge enabled.", tableName: "FirstRun")
                        .font(.footnote)
                        .foregroundStyle(DSHTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("firstRun.requiresHost")
                        .padding(.top, 24)
                    Step(number: 1, text: Text("When DSH starts, its terminal prints a pairing QR code and a link.", tableName: "FirstRun"))
                        .padding(.top, 8)
                    Divider().overlay(DSHTheme.hairline)
                    Step(number: 2, text: Text("Keep the phone and the computer on the same Wi-Fi, or connect them through a private network such as Tailscale.",
                                               tableName: "FirstRun"))
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 16)
            }
            actions
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(DSHTheme.canvas.ignoresSafeArea())
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: scan) {
                Label { Text("Scan the pairing QR code", tableName: "FirstRun") } icon: { Image(systemName: "qrcode.viewfinder") }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DSHTheme.canvas)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(DSHTheme.textPrimary, in: .rect(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pairing.scan")
            Button(action: paste) {
                Text("Paste a pairing link", tableName: "FirstRun")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DSHTheme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(DSHTheme.bubble, in: .rect(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pairing.pasteLink")
            Link(destination: FirstRun.setupGuide) {
                Text("No pairing code? Read the bridge setup", tableName: "FirstRun")
                    .font(.footnote)
                    .foregroundStyle(DSHTheme.textSecondary)
                    .padding(.vertical, 8)
            }
            .accessibilityIdentifier("firstRun.setup")
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 8)
    }
}

enum FirstRun {
    static let setupGuide = URL(string: "https://github.com/laichang/dsh-mobile/blob/main/bridge/README.md")!

    /// The first task that fills the composer after the first pairing.
    static var suggestion: String {
        String(localized: "Say hello and describe one way you can help me on this computer.")
    }
}

/// "deepseek" with the HARNESS badge, as on the DSH desktop and Web.
struct DSHWordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "deepseek")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.5)
            Text(verbatim: "HARNESS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DSHTheme.textPrimary, lineWidth: 1))
        }
        .foregroundStyle(DSHTheme.textPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "DeepSeek Harness"))
    }
}

/// Phone ⋯ end-to-end encrypted ⋯ your computer.
private struct ChannelCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            end(icon: "iphone", label: Text("Phone", tableName: "FirstRun"))
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    dots
                    Label { Text("End-to-end encrypted", tableName: "FirstRun") } icon: { Image(systemName: "lock") }
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(DSHTheme.green)
                        .fixedSize()
                    dots
                }
                .frame(height: 44)
            }
            .frame(maxWidth: .infinity)
            end(icon: "desktopcomputer", label: Text("Your computer", tableName: "FirstRun"))
        }
        .padding(16)
        .background(Color(hex: 0x1F2023), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(DSHTheme.hairline))
        .accessibilityElement(children: .combine)
    }

    private var dots: some View {
        Line().stroke(DSHTheme.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            .frame(height: 1)
    }

    private func end(icon: String, label: Text) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(DSHTheme.textPrimary)
                .frame(width: 44, height: 44)
                .background(DSHTheme.bubble, in: .rect(cornerRadius: 12))
            label.font(.footnote).foregroundStyle(DSHTheme.textSecondary)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(verbatim: "\(number)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(DSHTheme.textTertiary)
            text
                .foregroundStyle(DSHTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("firstRun.step")
    }
}
