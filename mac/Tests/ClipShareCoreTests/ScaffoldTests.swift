import XCTest
@testable import ClipShareCore

final class ScaffoldTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(ClipShareCore.version, "0.1.0")
    }
}
