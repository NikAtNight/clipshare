import XCTest
@testable import ClipShareCore

final class MP4BoxesTests: XCTestCase {
    func testMoovBeforeMdatIsFastStart() {
        XCTAssertTrue(MP4Boxes.isFastStart(in: box("moov") + box("mdat")))
    }

    func testMdatBeforeMoovIsNotFastStart() {
        XCTAssertFalse(MP4Boxes.isFastStart(in: box("mdat") + box("moov")))
    }

    func testLargeSizeBoxIsHandled() {
        var bytes = box("moov", largeSize: 16)
        bytes += box("mdat")
        XCTAssertTrue(MP4Boxes.isFastStart(in: bytes))
    }

    func testTruncatedHeaderReturnsFalse() {
        XCTAssertFalse(MP4Boxes.isFastStart(in: [0, 0, 0, 8, 109, 111]))
    }

    private func box(_ type: String, largeSize: UInt64? = nil) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        if let largeSize {
            return [0, 0, 0, 1] + typeBytes + bytes(of: largeSize)
        }
        return [0, 0, 0, 8] + typeBytes
    }

    private func bytes(of value: UInt64) -> [UInt8] {
        [
            UInt8((value >> 56) & 0xff), UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff), UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
    }
}
