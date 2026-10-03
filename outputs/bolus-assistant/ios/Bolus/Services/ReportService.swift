import Foundation
import UIKit

/// Builds report files on the iPhone (no server, no network, no AI).
enum ReportService {
    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Reports", isDirectory: true)
    }

    /// Writes the report and returns its file URL (protected until first unlock).
    @MainActor
    static func generate(_ options: ReportOptions, store: DiaryStore) throws -> URL {
        try options.validate()
        let input = store.reportInput(options)
        let data: Data
        switch options.format {
        case .pdf: data = PDFReportRenderer.render(ReportBuilder.pdfContent(input))
        case .csv: data = ReportTables.csvArchive(ReportBuilder.tables(input), modified: input.generatedAt)
        case .xlsx: data = XLSXWriter.workbook(ReportBuilder.tables(input), modified: input.generatedAt)
        case .json: data = try store.exportBackup()
        }
        let name = options.format == .json ? backupFileName() : options.fileName
        return try write(data, name: name)
    }

    static func backupFileName(date: Date = Date()) -> String {
        "bolus-backup-\(LocalDate(date: date, timeZone: .current)).json"
    }

    static func write(_ data: Data, name: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Generated files (newest first) for re-sharing.
    static func recentFiles() -> [URL] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return folders.flatMap { (try? manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Draws `ReportDocument` blocks on A4 pages.
enum PDFReportRenderer {
    static let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    static let margin: CGFloat = 42

    static func render(_ document: ReportDocument) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: document.title, kCGPDFContextAuthor as String: "Bolus",
                               kCGPDFContextCreator as String: "Bolus for iPhone"]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        return renderer.pdfData { context in
            let layout = Layout(context: context, footer: document.footer)
            layout.beginPage()
            for block in document.blocks { layout.draw(block) }
            layout.drawFooter()
        }
    }

    static func color(_ hex: String) -> UIColor {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    final class Layout {
        let context: UIGraphicsPDFRendererContext
        let footer: String
        var y: CGFloat = margin
        var pageNumber = 0
        var width: CGFloat { page.width - 2 * margin }
        var bottom: CGFloat { page.height - 56 }

        init(context: UIGraphicsPDFRendererContext, footer: String) {
            self.context = context
            self.footer = footer
        }

        func beginPage() {
            context.beginPage()
            pageNumber += 1
            y = margin
        }

        func ensure(_ height: CGFloat) {
            if y + height > bottom {
                drawFooter()
                beginPage()
            }
        }

        func drawFooter() {
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7), .foregroundColor: color("#7a8781")]
            NSString(string: footer).draw(at: CGPoint(x: margin, y: page.height - 34), withAttributes: attributes)
            let number = NSString(string: "Страница \(pageNumber)")
            let size = number.size(withAttributes: attributes)
            number.draw(at: CGPoint(x: page.width - margin - size.width, y: page.height - 34), withAttributes: attributes)
        }

        func text(_ string: String, font: UIFont, color textColor: UIColor, spacingAfter: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let value = NSAttributedString(string: string, attributes: attributes)
            let height = ceil(value.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
            ensure(height)
            value.draw(with: CGRect(x: margin, y: y, width: width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            y += height + spacingAfter
        }

        func draw(_ block: ReportBlock) {
            switch block {
            case .title(let title):
                text(title, font: .systemFont(ofSize: 24, weight: .bold), color: color("#237f6c"), spacingAfter: 10)
            case .section(let title):
                y += 6
                text(title, font: .systemFont(ofSize: 14, weight: .semibold), color: color("#284a40"), spacingAfter: 8)
            case .note(let note):
                text(note, font: .systemFont(ofSize: 8), color: color("#75817e"), spacingAfter: 8)
            case .table(let headers, let rows, let widths):
                table(headers: headers, rows: rows, weights: widths)
            case .chart(let chart):
                draw(chart)
            case .pageBreak:
                if y > margin + 1 {
                    drawFooter()
                    beginPage()
                }
            }
        }

        func table(headers: [String], rows: [[String]], weights: [Double]) {
            let total = weights.reduce(0, +)
            let columns = weights.map { CGFloat($0 / max(total, 1)) * width }
            let font = UIFont.systemFont(ofSize: 9)
            let bold = UIFont.systemFont(ofSize: 9, weight: .semibold)
            func height(_ cells: [String], _ cellFont: UIFont) -> CGFloat {
                var result: CGFloat = 0
                for (index, cell) in cells.enumerated() where index < columns.count {
                    let rect = NSString(string: cell).boundingRect(with: CGSize(width: columns[index] - 12, height: .greatestFiniteMagnitude),
                                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                                    attributes: [.font: cellFont], context: nil)
                    result = max(result, ceil(rect.height))
                }
                return result + 12
            }
            func drawRow(_ cells: [String], _ cellFont: UIFont, fill: UIColor?) {
                let rowHeight = height(cells, cellFont)
                ensure(rowHeight)
                if let fill {
                    fill.setFill()
                    UIBezierPath(rect: CGRect(x: margin, y: y, width: width, height: rowHeight)).fill()
                }
                var x = margin
                for (index, cell) in cells.enumerated() where index < columns.count {
                    NSString(string: cell).draw(with: CGRect(x: x + 6, y: y + 6, width: columns[index] - 12, height: rowHeight - 6),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: [.font: cellFont, .foregroundColor: UIColor.black], context: nil)
                    x += columns[index]
                }
                color("#e5eae7").setStroke()
                let line = UIBezierPath()
                line.move(to: CGPoint(x: margin, y: y + rowHeight))
                line.addLine(to: CGPoint(x: margin + width, y: y + rowHeight))
                line.lineWidth = 0.4
                line.stroke()
                y += rowHeight
            }
            drawRow(headers, bold, fill: color("#eaf3ed"))
            if rows.isEmpty { drawRow(Array(repeating: "—", count: headers.count), font, fill: nil) }
            for (index, row) in rows.enumerated() { drawRow(row, font, fill: index % 2 == 1 ? color("#fafcfb") : nil) }
            y += 12
        }

        func draw(_ chart: ReportChart) {
            text(chart.title, font: .systemFont(ofSize: 13, weight: .semibold), color: color("#284a40"), spacingAfter: 4)
            guard !chart.points.isEmpty else {
                text("Нет данных в выбранном периоде.", font: .systemFont(ofSize: 8), color: color("#75817e"), spacingAfter: 8)
                return
            }
            let height: CGFloat = 170
            ensure(height + 20)
            let plot = CGRect(x: margin + 40, y: y + 8, width: width - 48, height: height - 36)
            let maxY = chart.yLabel == "%" ? 100 : max(chart.minimumTop, (chart.points.map(\.y).max() ?? 0) * 1.15)
            let maxX = max(1, chart.points.map(\.x).max() ?? 1, chart.xLabels.map(\.x).max() ?? 1)
            func point(_ x: Double, _ value: Double) -> CGPoint {
                CGPoint(x: plot.minX + CGFloat(x / maxX) * plot.width, y: plot.maxY - CGFloat(value / maxY) * plot.height)
            }
            let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7), .foregroundColor: color("#7c8985")]
            if let band = chart.rangeBand {
                color("#edf6ef").setFill()
                let top = point(0, min(band.upperBound, maxY)).y
                let low = point(0, band.lowerBound).y
                UIBezierPath(rect: CGRect(x: plot.minX, y: top, width: plot.width, height: low - top)).fill()
            }
            for step in 0...4 {
                let value = maxY * Double(step) / 4
                let p = point(0, value)
                color("#e3eae6").setStroke()
                let grid = UIBezierPath()
                grid.move(to: CGPoint(x: plot.minX, y: p.y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: p.y))
                grid.lineWidth = 0.4
                grid.stroke()
                NSString(string: BolusFormat.decimal(value, 1)).draw(at: CGPoint(x: margin, y: p.y - 4), withAttributes: small)
            }
            NSString(string: chart.yLabel).draw(at: CGPoint(x: margin, y: y - 2), withAttributes: small)
            for label in chart.xLabels {
                let p = point(label.x, 0)
                let labelText = NSString(string: label.text)
                let size = labelText.size(withAttributes: small)
                labelText.draw(at: CGPoint(x: p.x - size.width / 2, y: plot.maxY + 4), withAttributes: small)
            }
            let stroke = color(chart.color)
            switch chart.kind {
            case .bar:
                let barWidth = min(30, plot.width / CGFloat(max(chart.points.count, 1)) * 0.58)
                stroke.setFill()
                for item in chart.points {
                    let top = point(item.x, item.y)
                    UIBezierPath(rect: CGRect(x: top.x - barWidth / 2, y: top.y, width: barWidth, height: plot.maxY - top.y)).fill()
                }
            case .line:
                let sorted = chart.points.sorted { $0.x < $1.x }
                if sorted.count >= 2 {
                    let path = UIBezierPath()
                    path.move(to: point(sorted[0].x, sorted[0].y))
                    for item in sorted.dropFirst() { path.addLine(to: point(item.x, item.y)) }
                    path.lineWidth = 1.4
                    stroke.setStroke()
                    path.stroke()
                }
                stroke.setFill()
                let every = max(1, sorted.count / 120)
                for (index, item) in sorted.enumerated() where index % every == 0 {
                    let p = point(item.x, item.y)
                    UIBezierPath(ovalIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)).fill()
                }
            }
            y += height
            if let note = chart.note { text(note, font: .systemFont(ofSize: 8), color: color("#75817e"), spacingAfter: 8) }
        }
    }
}
