import SwiftUI

/// Dark theme matching the TradingView chart aesthetic in use:
/// black background, purple/green accents, muted chart-gray text.
enum Theme {
    // Backgrounds
    static let bg = Color(hex: 0x000000)
    static let card = Color(hex: 0x0D0D10)
    static let cardBorder = Color(hex: 0x1C1F26)
    static let inset = Color(hex: 0x14161B)

    // Text
    static let text = Color(hex: 0xD1D4DC)
    static let textDim = Color(hex: 0x787B86)

    // Accents (indicator palette)
    static let green = Color(hex: 0x00FF00)      // longs / T1 / good
    static let purple = Color(hex: 0x673AB7)     // shorts / stop / brand accent
    static let teal = Color(hex: 0x26A69A)       // ON levels / positive-muted
    static let cyan = Color(hex: 0x00BCD4)       // VWAP
    static let amber = Color(hex: 0xFFB300)      // warnings / forming
    static let red = Color(hex: 0xEF5350)        // losses / blocked
    static let blue = Color(hex: 0x2962FF)       // info / VA

    // Star colors (match indicator star ladder)
    static func starColor(_ stars: Int) -> Color {
        switch stars {
        case 5: return Color(hex: 0xFFD54F)
        case 4: return Color(hex: 0xFF9800)
        case 3: return Color(hex: 0x2962FF)
        case 2: return Color(hex: 0x787B86)
        default: return Color(hex: 0x4C5158)
        }
    }

    static func starText(_ stars: Int) -> String {
        String(repeating: "★", count: max(1, min(5, stars)))
    }

    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
