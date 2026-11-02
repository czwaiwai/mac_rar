import XCTest
@testable import Core

final class PathSafetyValidatorTests: XCTestCase {

    func testAcceptsNormalRelativePath() throws {
        XCTAssertEqual(try PathSafetyValidator.validate(entryPath: "a/b/c.txt"), "a/b/c.txt")
    }

    func testAcceptsSingleComponent() throws {
        XCTAssertEqual(try PathSafetyValidator.validate(entryPath: "readme.txt"), "readme.txt")
    }

    func testRejectsAbsolutePath() {
        XCTAssertThrowsError(try PathSafetyValidator.validate(entryPath: "/etc/passwd")) { error in
            guard case PathSafetyValidator.ValidationError.absolutePath = error else {
                return XCTFail("expected absolutePath, got \(error)")
            }
        }
    }

    func testRejectsTraversalDotDot() {
        XCTAssertThrowsError(try PathSafetyValidator.validate(entryPath: "../secret.txt"))
        XCTAssertThrowsError(try PathSafetyValidator.validate(entryPath: "a/../../secret.txt"))
    }

    func testRejectsEmptyPath() {
        XCTAssertThrowsError(try PathSafetyValidator.validate(entryPath: ""))
    }

    func testRejectsSymlink() {
        XCTAssertThrowsError(try PathSafetyValidator.validate(entryPath: "link", isSymbolicLink: true))
    }

    func testNormalizesWindowsSeparators() throws {
        XCTAssertEqual(try PathSafetyValidator.validate(entryPath: "a\\b\\c.txt"), "a/b/c.txt")
    }

    func testResolveSafelyStaysInsideTarget() throws {
        let target = URL(fileURLWithPath: "/tmp/out")
        let resolved = try PathSafetyValidator.resolveSafely(entryPath: "a/b.txt", relativeTo: target)
        XCTAssertEqual(resolved.path, "/tmp/out/a/b.txt")
    }

    func testResolveSafelyRejectsEscaping() {
        let target = URL(fileURLWithPath: "/tmp/out")
        XCTAssertThrowsError(
            try PathSafetyValidator.resolveSafely(entryPath: "../x.txt", relativeTo: target)
        )
    }
}
