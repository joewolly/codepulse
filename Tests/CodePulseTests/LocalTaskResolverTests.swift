import Foundation
import XCTest
@testable import CodePulse

final class LocalTaskResolverTests: XCTestCase {
    func testCanonicalizesSpecificFoldersAndGuardsBroadRoots() {
        let resolver = SystemLocalTaskResolver(
            homeDirectory: URL(fileURLWithPath: "/Users/tester"),
            temporaryDirectory: URL(fileURLWithPath: "/private/tmp/codepulse-tests")
        )

        let folder = resolver.resolve(workingDirectory: "/Volumes/Archive/notes/../notes")
        XCTAssertEqual(folder?.canonicalPath, "/Volumes/Archive/notes")
        XCTAssertEqual(folder?.displayName, "notes")
        XCTAssertFalse(folder?.isTransient ?? true)

        XCTAssertTrue(resolver.resolve(workingDirectory: "/")?.isTransient ?? false)
        XCTAssertTrue(resolver.resolve(workingDirectory: "/Users/tester")?.isTransient ?? false)
        XCTAssertTrue(resolver.resolve(workingDirectory: "/private/tmp/codepulse-tests/task")?.isTransient ?? false)
    }

    func testResolvesAFileWithoutReadingItsDirectoryContents() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("meeting-notes.md")
        try Data("notes".utf8).write(to: file)
        let resolver = SystemLocalTaskResolver(
            homeDirectory: URL(fileURLWithPath: "/Users/tester"),
            temporaryDirectory: URL(fileURLWithPath: "/unrelated-temp")
        )

        let identity = try XCTUnwrap(resolver.resolve(workingDirectory: file.path))
        XCTAssertEqual(identity.canonicalPath, file.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(identity.displayName, "meeting-notes.md")
        XCTAssertTrue(identity.isFile)
        XCTAssertFalse(identity.isTransient)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulseLocalTaskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
