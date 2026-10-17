import Foundation
import zlib

enum ZIPPackage {
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1 }
        return value
    }
    static func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
        return value ^ 0xFFFFFFFF
    }
    static func encode(_ entries: [(String, Data)]) throws -> Data {
        guard entries.count <= 60000, entries.allSatisfy({ $0.0.utf8.count <= 65535 }),
              entries.reduce(0, { $0 + $1.1.count }) < Int(UInt32.max) else { throw AppError.message("Word 内容过大") }
        var output = Data(); var central = Data()
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        for (name, bytes) in entries {
            let filename = Data(name.utf8); let offset = UInt32(output.count); let checksum = crc(bytes)
            append(UInt32(0x04034B50), to: &output); append(UInt16(20), to: &output); append(UInt16(0x800), to: &output)
            append(UInt16(0), to: &output); append(UInt16(0), to: &output); append(UInt16(0x21), to: &output)
            append(checksum, to: &output); append(UInt32(bytes.count), to: &output); append(UInt32(bytes.count), to: &output)
            append(UInt16(filename.count), to: &output); append(UInt16(0), to: &output); output.append(filename); output.append(bytes)
            append(UInt32(0x02014B50), to: &central); append(UInt16(20), to: &central); append(UInt16(20), to: &central)
            append(UInt16(0x800), to: &central); append(UInt16(0), to: &central); append(UInt16(0), to: &central); append(UInt16(0x21), to: &central)
            append(checksum, to: &central); append(UInt32(bytes.count), to: &central); append(UInt32(bytes.count), to: &central)
            append(UInt16(filename.count), to: &central); append(UInt16(0), to: &central); append(UInt16(0), to: &central)
            append(UInt16(0), to: &central); append(UInt16(0), to: &central); append(UInt32(0), to: &central); append(offset, to: &central); central.append(filename)
        }
        let offset = UInt32(output.count); output.append(central)
        append(UInt32(0x06054B50), to: &output); append(UInt16(0), to: &output); append(UInt16(0), to: &output)
        append(UInt16(entries.count), to: &output); append(UInt16(entries.count), to: &output)
        append(UInt32(central.count), to: &output); append(offset, to: &output); append(UInt16(0), to: &output)
        return output
    }
    static func decode(_ data: Data) throws -> [String: Data] {
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= data.count else { throw AppError.message("Word 压缩包损坏") }
            return (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard data.count >= 22 else { throw AppError.message("Word 文件无效") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try number(offset, 4) == 0x06054B50 {
                if try offset + 22 + number(offset + 20, 2) == data.count { end = offset; break }
            }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw AppError.message("不支持此 Word 压缩格式") }
        let count = try number(end + 10, 2); var offset = try number(end + 16, 4)
        guard count <= 10000 else { throw AppError.message("Word 包含过多文件") }
        var result: [String: Data] = [:]; var total = 0
        for _ in 0..<count {
            guard try number(offset, 4) == 0x02014B50 else { throw AppError.message("Word 文件目录损坏") }
            let flags = try number(offset + 8, 2); let method = try number(offset + 10, 2)
            let checksum = try number(offset + 16, 4); let compressed = try number(offset + 20, 4); let size = try number(offset + 24, 4)
            let nameLength = try number(offset + 28, 2); let extra = try number(offset + 30, 2); let comment = try number(offset + 32, 2)
            let local = try number(offset + 42, 4)
            guard flags & 1 == 0, size <= DocumentTransfer.maximumFileSize, total + size <= DocumentTransfer.maximumFileSize,
                  offset + 46 + nameLength + extra + comment <= data.count else { throw AppError.message("Word 已加密或解压后超过 100 MB") }
            let name = String(decoding: data[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            guard try number(local, 4) == 0x04034B50 else { throw AppError.message("Word 文件内容损坏") }
            let start = try local + 30 + number(local + 26, 2) + number(local + 28, 2)
            guard start >= 0, start + compressed <= data.count, result[name] == nil else { throw AppError.message("Word 文件条目无效") }
            let packed = data.subdata(in: start..<(start + compressed)); let unpacked: Data
            if method == 0 { unpacked = packed }
            else if method == 8 {
                if size == 0 { unpacked = Data() }
                else {
                    var stream = z_stream(); var bytes = Data(count: size)
                    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AppError.message("无法解压 Word") }
                    defer { inflateEnd(&stream) }
                    let status = packed.withUnsafeBytes { input in bytes.withUnsafeMutableBytes { output -> Int32 in
                        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                        stream.avail_in = uInt(packed.count); stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(size); return inflate(&stream, Z_FINISH)
                    } }
                    guard status == Z_STREAM_END, stream.total_out == size else { throw AppError.message("Word 解压失败") }
                    unpacked = bytes
                }
            } else { throw AppError.message("不支持此 Word 压缩算法") }
            guard unpacked.count == size, Int(crc(unpacked)) == checksum else { throw AppError.message("Word 文件校验失败") }
            result[name] = unpacked; total += size; offset += 46 + nameLength + extra + comment
        }
        return result
    }
}
