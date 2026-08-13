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
}
