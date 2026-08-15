import Foundation

struct HistoryCSVExportWorker {
    static func write(
        sessions: [CompletedSession],
        to destination: URL,
        writer: any ExportFileWriting = AtomicExportFileWriter()
    ) throws {
        let data = HistoryCSVExporter.data(for: sessions)
        try writer.write(data, to: destination)
    }
}

struct HistoryCSVExportActivity: Equatable {
    private(set) var isActive = false

    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    mutating func end() {
        isActive = false
    }
}
