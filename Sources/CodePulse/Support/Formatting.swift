import Foundation

enum CodePulseFormatting {
    static func duration(_ duration: TimeInterval, includeSeconds: Bool = false) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if includeSeconds {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        return String(format: "%dm", minutes)
    }

    static func menuBarDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration.rounded(.down)) / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0
            ? String(format: "%d:%02d", hours, minutes)
            : String(format: "%d:%02d", 0, minutes)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }

    static func fullDay(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }

    static func dateRange(start: Date, end: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        let startLabel = formatter.string(from: start)
        let endLabel = formatter.string(from: end)
        return calendar.isDate(start, inSameDayAs: end)
            ? startLabel
            : "\(startLabel) – \(endLabel)"
    }

    static func signedDuration(_ duration: TimeInterval) -> String {
        let sign = duration < 0 ? "−" : "+"
        return "\(sign)\(self.duration(abs(duration)))"
    }

    static func exportDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
