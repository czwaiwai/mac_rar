import XCTest
@testable import Core

final class SplitArchiveDetectorTests: XCTestCase {

    func testNewStyleMainVolume() {
        let d = SplitArchiveDetector.detect(URL(fileURLWithPath: "/dir/photo.part1.rar"))
        XCTAssertEqual(d.classification, .mainVolume(baseName: "photo"))
        XCTAssertTrue(d.shouldProcess)
        XCTAssertTrue(d.isSplit)
    }

    func testNewStyleContinuationVolume() {
        let d = SplitArchiveDetector.detect(URL(fileURLWithPath: "/dir/photo.part2.rar"))
        XCTAssertEqual(d.classification, .partContinuation(baseName: "photo"))
        XCTAssertFalse(d.shouldProcess)
    }

    func testPaddedPartNumber() {
        let d = SplitArchiveDetector.detect(URL(fileURLWithPath: "/dir/photo.part01.rar"))
        XCTAssertEqual(d.classification, .mainVolume(baseName: "photo"))
    }

    func testOldStyleContinuationVolume() {
        let d = SplitArchiveDetector.detect(URL(fileURLWithPath: "/dir/photo.r00"))
        XCTAssertEqual(d.classification, .oldContinuation(baseName: "photo"))
        XCTAssertFalse(d.shouldProcess)
    }

    func testPlainRAR() {
        let d = SplitArchiveDetector.detect(URL(fileURLWithPath: "/dir/photo.rar"))
        XCTAssertEqual(d.classification, .singleArchive(baseName: "photo"))
        XCTAssertTrue(d.shouldProcess)
        XCTAssertFalse(d.isSplit)
    }

    func testCaseInsensitive() {
        let d = SplitArchiveDetector.detect(URL(fileURLWithPath: "/dir/PHOTO.PART1.RAR"))
        XCTAssertEqual(d.classification, .mainVolume(baseName: "PHOTO"))
    }

    func testNonRAR() {
        let d = SplitArchiveDetector.detect(URL(fileURLWithPath: "/dir/photo.zip"))
        XCTAssertEqual(d.classification, .notRAR)
        XCTAssertFalse(d.shouldProcess)
    }
}
