import AppKit
import SwiftUI

/// Farben und Schriften aus dem Designsystem „Bewerbungs-CD 2027“.
enum CD {
    static let forest500 = Color(hex: 0x446230) // header-bg
    static let forest600 = Color(hex: 0x3B5527) // rule
    static let forest700 = Color(hex: 0x33511F) // header-shade
    static let forest800 = Color(hex: 0x2E4A1F) // heading, pill-bg
    static let sage300   = Color(hex: 0x90A67F) // ring (nur dekorativ)
    static let gray900   = Color(hex: 0x111827) // text-strong
    static let gray700   = Color(hex: 0x374151) // text
    static let gray500   = Color(hex: 0x6B7280) // text-muted
    static let paper     = Color.white

    /// Inter (auch als „Inter Variable“ installiert), sonst Systemschrift.
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let w: NSFont.Weight = switch weight {
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
        for family in ["Inter", "Inter Variable"] {
            let desc = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: w.rawValue],
            ])
            if let font = NSFont(descriptor: desc, size: size),
               font.familyName?.hasPrefix("Inter") == true {
                return Font(font)
            }
        }
        return .system(size: size, weight: weight)
    }

    // Typostile (px-Werte aus tokens.json, für die Bildschirmdarstellung leicht vergrössert)
    static let name           = inter(26, .bold)
    static let pill           = inter(12, .medium)
    static let sectionHeading = inter(12, .bold)
    static let roleTitle      = inter(14, .bold)
    static let body           = inter(13.5)
    static let meta           = inter(11.5)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Grünes Kopfband mit dunklem Diagonal-Keil unten rechts.
struct HeaderBand: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CD.forest500
            GeometryReader { geo in
                Path { p in
                    let w = geo.size.width, h = geo.size.height
                    p.move(to: CGPoint(x: w * 0.62, y: h))
                    p.addLine(to: CGPoint(x: w, y: h * 0.18))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.closeSubpath()
                }
                .fill(CD.forest700)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("STELLENARCHIV")
                    .font(CD.name)
                    .foregroundStyle(.white)
                    .kerning(0.5)
                Text("Stellenanzeige → PDF + Markdown")
                    .font(CD.pill)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(CD.forest800))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 22)
        }
        .frame(height: 128)
    }
}

/// Abschnittstitel in Versalien mit 2pt-Linie darunter.
struct SectionHeading: View {
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(CD.sectionHeading)
                .foregroundStyle(CD.forest800)
                .kerning(0.4)
            Rectangle().fill(CD.forest600).frame(height: 2)
        }
    }
}

/// Flacher, eckiger Button in forest-800.
struct CDButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CD.inter(13, .bold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.white : CD.forest800)
            .background(
                Rectangle().fill(prominent ? CD.forest800 : Color.white)
            )
            .overlay(
                Rectangle().stroke(CD.forest800, lineWidth: prominent ? 0 : 1.5)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
