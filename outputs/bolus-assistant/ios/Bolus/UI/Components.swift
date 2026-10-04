import SwiftUI
import UIKit

/// Rounded surface with a thin border (`.card` in the web app).
struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.radius, style: .continuous).stroke(theme.border, lineWidth: 1))
    }
}

/// Scrollable page with the themed background.
struct Screen<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.background.ignoresSafeArea())
    }
}

struct PageHeading: View {
    @Environment(\.theme) private var theme
    var eyebrow: String? = nil
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                Text(eyebrow.uppercased()).font(.caption2.weight(.semibold)).tracking(1.4).foregroundStyle(theme.muted)
            }
            Text(title).font(.title2.weight(.bold)).foregroundStyle(theme.text)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionTitle: View {
    @Environment(\.theme) private var theme
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(theme.text)
            Spacer()
            if let systemImage { Image(systemName: systemImage).foregroundStyle(theme.accent) }
        }
    }
}

enum NoticeStyle { case info, error, success }

struct Notice: View {
    @Environment(\.theme) private var theme
    let text: String
    var style: NoticeStyle = .info
    var systemImage: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage ?? icon)
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .foregroundStyle(foreground)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var icon: String {
        switch style {
        case .info: return "info.circle"
        case .error: return "exclamationmark.triangle"
        case .success: return "checkmark.circle"
        }
    }

    private var foreground: Color {
        switch style {
        case .info, .success: return theme.accent
        case .error: return theme.isDark ? Color(hex: "#e8b3aa") : BolusTheme.danger
        }
    }

    private var background: Color {
        switch style {
        case .info, .success: return theme.mint
        case .error: return theme.isDark ? Color(hex: "#422f2d") : Color(hex: "#fbecea")
        }
    }
}

struct DataRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    var dot: Color? = nil

    var body: some View {
        HStack {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label).foregroundStyle(theme.muted)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(theme.text).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }
}

struct EmptyState: View {
    @Environment(\.theme) private var theme
    var title = "Пока нет записей"
    var text = "Начните с одной записи — она появится здесь."
    var systemImage = "doc.text"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(theme.accent)
                .frame(width: 56, height: 56)
                .background(theme.mint)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.headline).foregroundStyle(theme.text)
            Text(text).font(.footnote).foregroundStyle(theme.muted).multilineTextAlignment(.center)
            if let action {
                Button(action: action) { Label("Добавить запись", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(theme.isDark ? Color.black : Color.white)
            .background(theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(theme.text.opacity(isEnabled ? 1 : 0.45))
            .background(theme.surface.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border))
    }
}

/// Numeric input stored as text (accepts both "," and ".").
struct NumberField: View {
    @Environment(\.theme) private var theme
    let title: String
    @Binding var text: String
    var unit: String? = nil
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(theme.text)
            HStack {
                TextField(placeholder, text: $text)
                    .keyboardType(.decimalPad)
                    .foregroundStyle(theme.text)
                if let unit { Text(unit).font(.footnote).foregroundStyle(theme.muted) }
            }
            .padding(11)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.border))
        }
    }

    var value: Double? { BolusFormat.parse(text) }
}

struct LabeledField<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(theme.text)
            content
                .padding(11)
                .background(theme.background)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.border))
            if let hint { Text(hint).font(.caption).foregroundStyle(theme.muted) }
        }
    }
}

/// Diary row: time, icon, title, description and value (`EventRow` of the web app).
struct EventRow: View {
    @Environment(\.theme) private var theme
    let entry: DiaryRecord
    let unit: GlucoseUnit
    let timeZone: TimeZone

    var body: some View {
        HStack(spacing: 12) {
            Text(WallClock.hourMinute(entry.occurredAt, timeZone: timeZone))
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.muted)
                .frame(width: 40, alignment: .leading)
            Image(systemName: EventRow.icon(entry.kind))
                .font(.subheadline)
                .foregroundStyle(EventRow.color(entry.kind, theme: theme))
                .frame(width: 34, height: 34)
                .background(EventRow.color(entry.kind, theme: theme).opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
                Text(valueUnit).font(.caption2).foregroundStyle(theme.muted)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.muted)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    static func icon(_ kind: EntryKind) -> String {
        switch kind {
        case .glucose: return "drop.fill"
        case .insulin: return "syringe.fill"
        case .meal: return "fork.knife"
        case .activity, .activitySummary: return "figure.walk"
        case .note: return "note.text"
        }
    }

    static func color(_ kind: EntryKind, theme: BolusTheme) -> Color {
        switch kind {
        case .glucose: return BolusTheme.glucoseLine
        case .insulin: return BolusTheme.insulin
        case .meal: return BolusTheme.meal
        case .activity, .activitySummary: return BolusTheme.activity
        case .note: return theme.muted
        }
    }

    private var title: String {
        switch entry.kind {
        case .glucose: return "Глюкоза"
        case .insulin: return entry.insulin.map { $0.insulinName.isEmpty ? "Инсулин" : $0.insulinName } ?? "Инсулин"
        case .meal: return entry.meal?.name ?? "Еда"
        case .activity: return entry.activity?.name ?? "Активность"
        case .activitySummary: return "Активность за день"
        case .note: return "Заметка"
        }
    }

    private var detail: String {
        switch entry.kind {
        case .glucose:
            guard let source = entry.glucose?.source else { return "" }
            return source == "manual" ? "Вручную" : source
        case .insulin: return entry.insulin?.purpose.label ?? ""
        case .meal: return entry.meal?.items.map(\.nameSnapshot).joined(separator: ", ") ?? ""
        case .activity: return entry.activity?.isFromAppleHealth == true ? "Apple «Здоровье»" : "Активность"
        case .activitySummary: return "Apple «Здоровье» · дневная сводка"
        case .note: return entry.noteText
        }
    }

    private var value: String {
        switch entry.kind {
        case .glucose: return BolusFormat.glucose(entry.data.double("value_mmol"), unit: unit)
        case .insulin: return BolusFormat.decimal(entry.data.double("units"))
        case .meal: return BolusFormat.decimal(entry.data.double("total_carbs"), 1)
        case .activity: return BolusFormat.decimal(entry.data.double("duration_minutes"), 0)
        case .activitySummary:
            let summary = entry.activitySummary
            return BolusFormat.decimal(summary?.steps ?? summary?.exerciseMinutes ?? summary?.activeEnergy, 0)
        case .note: return ""
        }
    }

    private var valueUnit: String {
        switch entry.kind {
        case .glucose: return unit.label
        case .insulin: return "ЕД"
        case .meal: return "г углеводов"
        case .activity: return "мин"
        case .activitySummary:
            let summary = entry.activitySummary
            if summary?.steps != nil { return "шагов" }
            if summary?.exerciseMinutes != nil { return "мин" }
            return summary?.activeEnergy != nil ? "ккал" : ""
        case .note: return ""
        }
    }
}

/// Cycle start shown in the diary on its date (cycles are kept apart from diary entries).
struct CycleDayRow: View {
    @Environment(\.theme) private var theme
    let cycle: CycleRecord

    var body: some View {
        HStack(spacing: 12) {
            Text("день").font(.caption).foregroundStyle(theme.muted).frame(width: 40, alignment: .leading)
            Image(systemName: "moon.fill")
                .font(.subheadline)
                .foregroundStyle(BolusTheme.below)
                .frame(width: 34, height: 34)
                .background(BolusTheme.below.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Начало цикла").font(.subheadline.weight(.semibold)).foregroundStyle(theme.text).lineLimit(1)
                Text("\(cycle.startDate.title("d MMMM yyyy")) · длина \(cycle.cycleLength) дней").font(.caption).foregroundStyle(theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("1-й день").font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.muted)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Standard iOS share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

extension Date {
    /// "3 октября 2026".
    func longDate(_ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: self)
    }

    func dateTime(_ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: self)
    }
}

extension LocalDate {
    func title(_ format: String = "d MMMM") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: startOfDay(in: TimeZone(identifier: "UTC")!))
    }
}
