import Foundation

enum ExportFilename {
    static func history(referenceDate: Date, calendar: Calendar) -> String {
        "CodePulse-History-\(dateComponent(referenceDate, calendar: calendar)).csv"
    }

    static func report(
        projectTitle: String?,
        timeframe: InsightsTimeframe,
        referenceDate: Date,
        calendar: Calendar
    ) -> String {
        var components = ["CodePulse", "Report"]
        if let projectTitle {
            components.append(sanitizedComponent(projectTitle, fallback: "Project"))
        }
        components.append(sanitizedComponent(timeframe.title, fallback: "Period"))
        components.append(dateComponent(referenceDate, calendar: calendar))
        return components.joined(separator: "-") + ".md"
    }

    static func sanitizedComponent(_ value: String, fallback: String) -> String {
        let unsafe = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/\\:?*|\"<>"))
        var result = ""

        for scalar in value.unicodeScalars {
            if unsafe.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                result.append("-")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }

        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        guard !result.isEmpty else { return fallback }
        return String(result.prefix(64))
    }

    private static func dateComponent(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
