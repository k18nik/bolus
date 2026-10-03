import SwiftUI

extension Color {
    init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}

/// The six themes of the web app (CSS variables of `globals.css`).
struct BolusTheme: Equatable {
    let id: String
    let name: String
    let background: Color
    let surface: Color
    let text: Color
    let muted: Color
    let accent: Color
    let mint: Color
    let border: Color
    let radius: CGFloat
    let isDark: Bool
    let swatch: Color

    static let light = BolusTheme(id: "light", name: "Minimal Light", background: Color(hex: "#f6f8fa"), surface: .white, text: Color(hex: "#263b3b"),
                                  muted: Color(hex: "#7c898c"), accent: Color(hex: "#237f6c"), mint: Color(hex: "#eaf5ef"), border: Color(hex: "#e9eeee"),
                                  radius: 20, isDark: false, swatch: Color(hex: "#f4f8f6"))
    static let dark = BolusTheme(id: "dark", name: "Minimal Dark", background: Color(hex: "#1b2527"), surface: Color(hex: "#253133"), text: Color(hex: "#e1ece8"),
                                 muted: Color(hex: "#a4b6b0"), accent: Color(hex: "#81bca5"), mint: Color(hex: "#30473e"), border: Color(hex: "#364446"),
                                 radius: 20, isDark: true, swatch: Color(hex: "#253436"))
    static let cat = BolusTheme(id: "cat", name: "Cat Café", background: Color(hex: "#f7f3eb"), surface: Color(hex: "#fffdf8"), text: Color(hex: "#584f45"),
                                muted: Color(hex: "#968779"), accent: Color(hex: "#8b7355"), mint: Color(hex: "#f0e7d8"), border: Color(hex: "#ece4d7"),
                                radius: 23, isDark: false, swatch: Color(hex: "#e9dfcf"))
    static let pink = BolusTheme(id: "pink", name: "Pink Pastel", background: Color(hex: "#fbf4f7"), surface: Color(hex: "#fffcfd"), text: Color(hex: "#5a4351"),
                                 muted: Color(hex: "#9e8292"), accent: Color(hex: "#b76f91"), mint: Color(hex: "#f7e6ee"), border: Color(hex: "#f0e1e7"),
                                 radius: 23, isDark: false, swatch: Color(hex: "#f6dce6"))
    static let dino = BolusTheme(id: "dino", name: "Dino", background: Color(hex: "#f3f6ed"), surface: Color(hex: "#fffefa"), text: Color(hex: "#425242"),
                                 muted: Color(hex: "#87947a"), accent: Color(hex: "#6e884c"), mint: Color(hex: "#e9f0dc"), border: Color(hex: "#e3e9d9"),
                                 radius: 18, isDark: false, swatch: Color(hex: "#cce2bc"))
    static let oled = BolusTheme(id: "oled", name: "OLED Black", background: .black, surface: Color(hex: "#0c1212"), text: Color(hex: "#ecf5f1"),
                                 muted: Color(hex: "#a7bab1"), accent: Color(hex: "#85c9ae"), mint: Color(hex: "#16372a"), border: Color(hex: "#26332c"),
                                 radius: 20, isDark: true, swatch: Color(hex: "#030404"))

    static let all: [BolusTheme] = [light, dark, cat, pink, dino, oled]

    static func named(_ id: String) -> BolusTheme { all.first { $0.id == id } ?? light }

    // Event and range colors shared by every theme.
    static let glucoseLine = Color(hex: "#319b7d")
    static let meal = Color(hex: "#d5ae73")
    static let insulin = Color(hex: "#b0a0ce")
    static let activity = Color(hex: "#7ca9cb")
    static let below = Color(hex: "#dfa59f")
    static let inRange = Color(hex: "#6daf93")
    static let above = Color(hex: "#e2be78")
    static let rangeBand = Color(hex: "#dceee2")
    static let danger = Color(hex: "#c4574f")
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = BolusTheme.light
}

extension EnvironmentValues {
    var theme: BolusTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Little helper of the diary. Its mood never depends on glucose values.
struct Mascot {
    let id: String
    let emoji: String
    let name: String

    static let all: [Mascot] = AppPreferences.mascots.map { Mascot(id: $0.id, emoji: $0.emoji, name: $0.name) }
    static func named(_ id: String) -> Mascot { all.first { $0.id == id } ?? all[0] }
}

struct MascotArt: View {
    let id: String
    var size: CGFloat = 120

    var body: some View {
        if id == "cat" {
            Image("MascotCat")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel("Кот Персик, ваш помощник")
        } else {
            Text(Mascot.named(id).emoji)
                .font(.system(size: size * 0.62))
                .frame(width: size, height: size)
                .accessibilityLabel(Mascot.named(id).name)
        }
    }
}
