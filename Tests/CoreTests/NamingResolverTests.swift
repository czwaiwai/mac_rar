import XCTest
@testable import Core

final class NamingResolverTests: XCTestCase {

    func testSingleTopLevelFolder() {
        let result = NamingResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/dir/photo.rar"),
            topLevelEntries: ["photo/", "photo/a.jpg", "photo/sub/b.jpg"],
            destinationDirectory: URL(fileURLWithPath: "/dir")
        )
        XCTAssertEqual(result.decision, .singleTopLevelFolder(name: "photo"))
        XCTAssertEqual(result.outputURL.path, "/dir/photo")
    }

    func testMultipleTopLevelEntries() {
        let result = NamingResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/dir/photo.rar"),
            topLevelEntries: ["a.txt", "b.txt"],
            destinationDirectory: URL(fileURLWithPath: "/dir")
        )
        XCTAssertEqual(result.decision, .newFolder(name: "photo"))
        XCTAssertEqual(result.outputURL.path, "/dir/photo")
    }

    func testSingleTopLevelFile() {
        let result = NamingResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/dir/photo.rar"),
            topLevelEntries: ["readme.txt"],
            destinationDirectory: URL(fileURLWithPath: "/dir")
        )
        XCTAssertEqual(result.decision, .newFolder(name: "photo"))
    }

    func testSingleTopLevelFileWithoutDirectoryEntry() {
        // 只有文件、没有显式目录 entry：不应误判为单顶层文件夹。
        let result = NamingResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/dir/photo.rar"),
            topLevelEntries: ["docs/a.txt"],
            destinationDirectory: URL(fileURLWithPath: "/dir")
        )
        XCTAssertEqual(result.decision, .newFolder(name: "photo"))
    }

    func testUniquifyAppendsSequenceNumber() {
        let existing: Set<String> = ["/dir/photo", "/dir/photo 2"]
        let result = NamingResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/dir/photo.rar"),
            topLevelEntries: ["a.txt", "b.txt"],
            destinationDirectory: URL(fileURLWithPath: "/dir"),
            fileExists: { existing.contains($0) }
        )
        XCTAssertEqual(result.decision, .newFolder(name: "photo"))
        XCTAssertEqual(result.outputURL.path, "/dir/photo 3")
    }

    func testBaseNameStripsOnlyLastExtension() {
        let result = NamingResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/dir/photo.backup.rar"),
            topLevelEntries: ["a.txt"],
            destinationDirectory: URL(fileURLWithPath: "/dir")
        )
        XCTAssertEqual(result.decision, .newFolder(name: "photo.backup"))
    }

    func testSplitMainVolumeUsesBaseNameWithoutPartSuffix() {
        let result = NamingResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/dir/split.part1.rar"),
            topLevelEntries: ["a.txt", "b.txt"],
            destinationDirectory: URL(fileURLWithPath: "/dir")
        )
        XCTAssertEqual(result.decision, .newFolder(name: "split"))
        XCTAssertEqual(result.outputURL.path, "/dir/split")
    }

    func testOldStyleSplitMainVolumeKeepsBaseName() {
        let result = NamingResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/dir/split.rar"),
            topLevelEntries: ["a.txt", "b.txt"],
            destinationDirectory: URL(fileURLWithPath: "/dir")
        )
        XCTAssertEqual(result.decision, .newFolder(name: "split"))
    }
}
