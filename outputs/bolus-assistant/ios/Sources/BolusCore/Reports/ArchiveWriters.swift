import Foundation

/// Minimal ZIP writer (stored entries, UTF-8 names). Enough for CSV archives and XLSX
/// packages without third-party dependencies.
public struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count = 0

    public init() {}

    static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max((c.year ?? 1980) - 1980, 0)
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let month: Int = c.month ?? 1
        let dayOfMonth: Int = c.day ?? 1
        let time = UInt16(truncatingIfNeeded: (hour << 11) | (minute << 5) | (second / 2))
        let day = UInt16(truncatingIfNeeded: (year << 9) | (month << 5) | dayOfMonth)
        return (time, day)
    }

    private static func append(_ data: inout Data, _ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    private static func append(_ data: inout Data, _ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    public mutating func add(path: String, data: Data, modified: Date) {
        let name = Data(path.utf8)
        let crc = Self.crc32(data)
        let stamp = Self.dosTimestamp(modified)
        let offset = UInt32(body.count)
        var local = Data()
        Self.append(&local, UInt32(0x0403_4B50))
        Self.append(&local, UInt16(20))
        Self.append(&local, UInt16(0x0800))
        Self.append(&local, UInt16(0))
        Self.append(&local, stamp.time)
        Self.append(&local, stamp.date)
        Self.append(&local, crc)
        Self.append(&local, UInt32(data.count))
        Self.append(&local, UInt32(data.count))
        Self.append(&local, UInt16(name.count))
        Self.append(&local, UInt16(0))
        body.append(local)
        body.append(name)
        body.append(data)
        var entry = Data()
        Self.append(&entry, UInt32(0x0201_4B50))
        Self.append(&entry, UInt16(20))
        Self.append(&entry, UInt16(20))
        Self.append(&entry, UInt16(0x0800))
        Self.append(&entry, UInt16(0))
        Self.append(&entry, stamp.time)
        Self.append(&entry, stamp.date)
        Self.append(&entry, crc)
        Self.append(&entry, UInt32(data.count))
        Self.append(&entry, UInt32(data.count))
        Self.append(&entry, UInt16(name.count))
        Self.append(&entry, UInt16(0))
        Self.append(&entry, UInt16(0))
        Self.append(&entry, UInt16(0))
        Self.append(&entry, UInt16(0))
        Self.append(&entry, UInt32(0))
        Self.append(&entry, offset)
        central.append(entry)
        central.append(name)
        count += 1
    }

    public func finalize() -> Data {
        var result = body
        result.append(central)
        var end = Data()
        Self.append(&end, UInt32(0x0605_4B50))
        Self.append(&end, UInt16(0))
        Self.append(&end, UInt16(0))
        Self.append(&end, UInt16(count))
        Self.append(&end, UInt16(count))
        Self.append(&end, UInt32(central.count))
        Self.append(&end, UInt32(body.count))
        Self.append(&end, UInt16(0))
        result.append(end)
        return result
    }
}

/// Minimal Office Open XML spreadsheet writer (inline strings, bold header row,
/// frozen header, autofilter). Opens in Excel, Numbers and openpyxl.
public enum XLSXWriter {
    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                // Characters that are not allowed in XML 1.0 are dropped.
                if scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }

    public static func columnName(_ index: Int) -> String {
        var number = index + 1
        var name = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            number = (number - 1) / 26
        }
        return name
    }

    static func sheetName(_ name: String, used: inout Set<String>) -> String {
        let forbidden = CharacterSet(charactersIn: "[]:*?/\\")
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars where !forbidden.contains(scalar) && scalars.count < 31 { scalars.append(scalar) }
        var cleaned = String(scalars)
        if cleaned.isEmpty { cleaned = "Sheet" }
        var candidate = cleaned
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            candidate = String(cleaned.prefix(28)) + " \(suffix)"
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    static func cellXML(_ cell: ReportCell, reference: String, header: Bool = false) -> String {
        let style = header ? " s=\"1\"" : ""
        switch cell {
        case .empty: return ""
        case .number(let value) where value.isFinite:
            return "<c r=\"\(reference)\"\(style)><v>\(ReportTables.numberText(value))</v></c>"
        case .number(let value):
            return "<c r=\"\(reference)\" t=\"inlineStr\"\(style)><is><t>\(value)</t></is></c>"
        case .bool(let flag):
            return "<c r=\"\(reference)\" t=\"b\"\(style)><v>\(flag ? 1 : 0)</v></c>"
        case .text(let text):
            return "<c r=\"\(reference)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(escape(ReportTables.safeCell(text)))</t></is></c>"
        }
    }

    static func worksheet(_ table: ReportTable) -> String {
        var rows = "<row r=\"1\">" + table.columns.enumerated().map { index, column in
            cellXML(.text(column), reference: columnName(index) + "1", header: true)
        }.joined() + "</row>"
        for (rowIndex, row) in table.rows.enumerated() {
            let number = rowIndex + 2
            rows += "<row r=\"\(number)\">" + row.enumerated().map { index, cell in
                cellXML(cell, reference: columnName(index) + String(number))
            }.joined() + "</row>"
        }
        let lastColumn = columnName(max(table.columns.count - 1, 0))
        let lastRow = max(table.rows.count + 1, 1)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:\(lastColumn)\(lastRow)"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols><col min="1" max="\(max(table.columns.count, 1))" width="24" customWidth="1"/></cols><sheetData>\(rows)</sheetData><autoFilter ref="A1:\(lastColumn)\(lastRow)"/></worksheet>
        """
    }

    public static func workbook(_ tables: [ReportTable], modified: Date) -> Data {
        var used = Set<String>()
        let names = tables.map { sheetName($0.name, used: &used) }
        var zip = ZipWriter()
        let overrides = tables.indices.map {
            "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        zip.add(path: "[Content_Types].xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(overrides)</Types>
        """.utf8), modified: modified)
        zip.add(path: "_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8), modified: modified)
        let sheets = names.enumerated().map { "<sheet name=\"\(escape($1))\" sheetId=\"\($0 + 1)\" r:id=\"rId\($0 + 1)\"/>" }.joined()
        let filters = names.enumerated().map { index, name -> String in
            let table = tables[index]
            let ref = "$A$1:$\(columnName(max(table.columns.count - 1, 0)))$\(max(table.rows.count + 1, 1))"
            return "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"\(index)\" hidden=\"1\">'\(escape(name).replacingOccurrences(of: "'", with: "''"))'!\(ref)</definedName>"
        }.joined()
        zip.add(path: "xl/workbook.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheets)</sheets><definedNames>\(filters)</definedNames></workbook>
        """.utf8), modified: modified)
        let relationships = tables.indices.map {
            "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
        }.joined()
        zip.add(path: "xl/_rels/workbook.xml.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationships)<Relationship Id="rId\(tables.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """.utf8), modified: modified)
        zip.add(path: "xl/styles.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF237F6C"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """.utf8), modified: modified)
        for (index, table) in tables.enumerated() {
            zip.add(path: "xl/worksheets/sheet\(index + 1).xml", data: Data(worksheet(table).utf8), modified: modified)
        }
        return zip.finalize()
    }
}
