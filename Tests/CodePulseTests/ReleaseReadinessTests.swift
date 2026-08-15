import Foundation
import XCTest

@testable import CodePulse

final class ReleaseReadinessTests: XCTestCase {
    func testCanonicalAppMetadataMatchesV1AndExistingSparkleTrustKey() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let metadataURL = repositoryRoot.appendingPathComponent("Resources/Info.plist")
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: metadataData,
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(metadata["CFBundleShortVersionString"] as? String, "1.0.0")
        XCTAssertEqual(metadata["CFBundleVersion"] as? String, "1000")
        XCTAssertEqual(metadata["LSMinimumSystemVersion"] as? String, "13.0")
        XCTAssertEqual(metadata["LSUIElement"] as? Bool, true)
        XCTAssertEqual(
            metadata["SUPublicEDKey"] as? String,
            "EX4J6W41dIHFiPsqUhlk6Jp/VsX/2AxoYmCDlsqzuDM="
        )
        XCTAssertEqual(
            metadata["SUFeedURL"] as? String,
            "https://github.com/joewolly/codepulse/releases/latest/download/appcast.xml"
        )
    }
}
