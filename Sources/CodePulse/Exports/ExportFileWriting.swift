import Foundation

protocol ExportFileWriting {
    func write(_ data: Data, to url: URL) throws
}

struct AtomicExportFileWriter: ExportFileWriting {
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
