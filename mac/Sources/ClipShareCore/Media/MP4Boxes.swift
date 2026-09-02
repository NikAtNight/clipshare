import Foundation

enum MP4Boxes {
    struct Box: Equatable {
        let type: String
        let offset: UInt64
        let size: UInt64
    }

    static func isFastStart(in bytes: [UInt8]) -> Bool {
        let boxes = topLevelBoxes(in: bytes, fileSize: UInt64(bytes.count))
        guard
            let moov = boxes.firstIndex(where: { $0.type == "moov" }),
            let mdat = boxes.firstIndex(where: { $0.type == "mdat" })
        else {
            return false
        }
        return moov < mdat
    }

    static func topLevelBoxes(in bytes: [UInt8], fileSize: UInt64) -> [Box] {
        var boxes: [Box] = []
        var offset: UInt64 = 0

        while offset < fileSize {
            guard let index = Int(exactly: offset), index <= bytes.count, bytes.count - index >= 8 else {
                return boxes
            }

            let size32 = unsigned32(bytes, at: index)
            let type = fourCC(bytes[index + 4 ..< index + 8])
            var headerSize: UInt64 = 8
            var boxSize = UInt64(size32)

            if size32 == 1 {
                guard bytes.count - index >= 16 else {
                    return boxes
                }
                boxSize = unsigned64(bytes, at: index + 8)
                headerSize = 16
            } else if size32 == 0 {
                boxSize = fileSize - offset
            }

            guard boxSize >= headerSize, boxSize <= fileSize - offset else {
                return boxes
            }

            boxes.append(Box(type: type, offset: offset, size: boxSize))
            offset += boxSize
        }

        return boxes
    }

    static func fileInfo(at url: URL) throws -> (isFastStart: Bool, majorBrand: String?) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let byteCount = values.fileSize else {
            throw MediaPipelineError.inspectionFailed("macOS could not read this file.")
        }

        let fileSize = UInt64(byteCount)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var moovOffset: UInt64?
        var mdatOffset: UInt64?
        var majorBrand: String?

        while offset < fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else {
                return (false, majorBrand)
            }

            let headerBytes = Array(header)
            let size32 = unsigned32(headerBytes, at: 0)
            let type = fourCC(headerBytes[4 ..< 8])
            var headerSize: UInt64 = 8
            var boxSize = UInt64(size32)

            if size32 == 1 {
                guard headerBytes.count >= 16 else {
                    return (false, majorBrand)
                }
                boxSize = unsigned64(headerBytes, at: 8)
                headerSize = 16
            } else if size32 == 0 {
                boxSize = fileSize - offset
            }

            guard boxSize >= headerSize, boxSize <= fileSize - offset else {
                return (false, majorBrand)
            }

            if type == "ftyp", boxSize >= headerSize + 4 {
                try handle.seek(toOffset: offset + headerSize)
                if let brandData = try handle.read(upToCount: 4), brandData.count == 4 {
                    majorBrand = fourCC(Array(brandData)[0 ..< 4])
                }
            } else if type == "moov" {
                moovOffset = offset
            } else if type == "mdat" {
                mdatOffset = offset
            }

            offset += boxSize
        }

        guard let moovOffset, let mdatOffset else {
            return (false, majorBrand)
        }
        return (moovOffset < mdatOffset, majorBrand)
    }

    private static func unsigned32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24) |
            (UInt32(bytes[index + 1]) << 16) |
            (UInt32(bytes[index + 2]) << 8) |
            UInt32(bytes[index + 3])
    }

    private static func unsigned64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        (UInt64(bytes[index]) << 56) |
            (UInt64(bytes[index + 1]) << 48) |
            (UInt64(bytes[index + 2]) << 40) |
            (UInt64(bytes[index + 3]) << 32) |
            (UInt64(bytes[index + 4]) << 24) |
            (UInt64(bytes[index + 5]) << 16) |
            (UInt64(bytes[index + 6]) << 8) |
            UInt64(bytes[index + 7])
    }

    private static func fourCC(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .macOSRoman) ?? ""
    }
}
