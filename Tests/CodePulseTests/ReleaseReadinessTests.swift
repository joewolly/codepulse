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

        XCTAssertEqual(metadata["CFBundleShortVersionString"] as? String, "1.1.2")
        XCTAssertEqual(metadata["CFBundleVersion"] as? String, "1102")
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

    func testReleasePackagerDefaultsToAdHocSigningAndChecksNestedCode() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot.appendingPathComponent("script/package_release.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("ADHOC_SIGN=\"${CODEPULSE_ADHOC_SIGN:-1}\""))
        XCTAssertTrue(script.contains("--unsigned"))
        XCTAssertTrue(script.contains("/usr/bin/codesign --force --sign - \"$signing_helpers/codepulse-integration\""))
        XCTAssertTrue(script.contains("/usr/bin/codesign --force --sign - \"$signing_helpers/codepulsectl\""))
        XCTAssertTrue(script.contains("/usr/bin/codesign --verify --strict --verbose=2 \"$signing_bundle/Contents/Frameworks/Sparkle.framework\""))
        XCTAssertTrue(script.contains("/usr/bin/codesign --verify --strict --verbose=2 \"$APP_BUNDLE\""))
        XCTAssertTrue(script.contains("Signature=adhoc"))
        XCTAssertTrue(script.contains("TeamIdentifier=not set"))
    }
}
