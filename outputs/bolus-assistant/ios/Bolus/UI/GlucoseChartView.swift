import SwiftUI
import Charts

struct ChartGlucosePoint: Identifiable {
    let id: UUID
    let date: Date
    let value: Double
}

struct ChartEventPoint: Identifiable {
    let id: UUID
    let date: Date
    let kind: EntryKind
}

/// Glucose line with the target range band and meal/insulin/activity markers.
struct GlucoseChartView: View {
    @Environment(\.theme) private var theme
    let entries: [DiaryRecord]
    let unit: GlucoseUnit
    var height: CGFloat = 220

    private var points: [ChartGlucosePoint] {
        entries.filter { $0.kind == .glucose }.compactMap { entry in
            entry.data.double("value_mmol").map { ChartGlucosePoint(id: entry.id, date: entry.occurredAt, value: unit.fromMmol($0)) }
        }.sorted { $0.date < $1.date }
    }

    private var events: [ChartEventPoint] {
        guard let first = points.first?.date, let last = points.last?.date else { return [] }
        return entries.filter { [.meal, .insulin, .activity].contains($0.kind) && $0.occurredAt >= first && $0.occurredAt <= last }
            .suffix(40)
            .map { ChartEventPoint(id: $0.id, date: $0.occurredAt, kind: $0.kind) }
    }

    var body: some View {
        let data = points
        if data.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(theme.muted)
                Text("Здесь появится график глюкозы").font(.subheadline).foregroundStyle(theme.muted)
                Text("Добавьте первое измерение в дневник").font(.caption).foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: height)
        } else {
            chart(data)
        }
    }

    private func chart(_ data: [ChartGlucosePoint]) -> some View {
        let low = 3.9 * unit.factor
        let high = 10 * unit.factor
        let top = max(15 * unit.factor, (data.map(\.value).max() ?? 0) * 1.05)
        let start = data.first?.date ?? Date()
        let end = max(data.last?.date ?? Date(), start.addingTimeInterval(60))
        let markerY = 1.1 * unit.factor
        return Chart {
            RectangleMark(xStart: .value("Начало", start), xEnd: .value("Конец", end),
                          yStart: .value("Нижняя граница", low), yEnd: .value("Верхняя граница", high))
                .foregroundStyle(BolusTheme.rangeBand.opacity(theme.isDark ? 0.18 : 0.45))
            ForEach(data) { point in
                LineMark(x: .value("Время", point.date), y: .value("Глюкоза", point.value))
                    .foregroundStyle(BolusTheme.glucoseLine)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Время", point.date), y: .value("Глюкоза", point.value))
                    .foregroundStyle(BolusTheme.glucoseLine)
                    .symbolSize(data.count > 60 ? 8 : 22)
            }
            ForEach(events) { event in
                PointMark(x: .value("Время", event.date), y: .value("Событие", markerY))
                    .foregroundStyle(color(event.kind))
                    .symbolSize(40)
            }
        }
        .chartYScale(domain: 0...top)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
        .frame(height: height)
    }

    private func color(_ kind: EntryKind) -> Color {
        switch kind {
        case .meal: return BolusTheme.meal
        case .insulin: return BolusTheme.insulin
        default: return BolusTheme.activity
        }
    }
}

struct ChartLegend: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            legend("Еда", BolusTheme.meal)
            legend("Инсулин", BolusTheme.insulin)
            legend("Активность", BolusTheme.activity)
        }
        .font(.caption2)
        .foregroundStyle(theme.muted)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
    }
}
