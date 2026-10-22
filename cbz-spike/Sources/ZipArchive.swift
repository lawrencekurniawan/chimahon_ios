import Foundation
import zlib

/// Minimal ZIP (CBZ) reader/writer for the CBZ spike — ZERO third-party
/// dependencies: central-directory parsing by hand + raw DEFLATE via system
/// zlib (`inflateInit2_(-15)` / `deflateInit2_(-15)`).
///
/// Scope decisions (documented in cbz-spike/README.md):
///  - Sizes/CRC come from the CENTRAL directory (authoritative even when the
///    local header uses data descriptors — streamed zips).
///  - ZIP64 (>4GB or >65535 entries) not supported → explicit error.
///  - Methods: 0 (stored) + 8 (deflate). Others (bzip2/zstd/lzma) → error.
///  - Every read is CRC-verified; byte-exact integrity checked by the bench.
///
/// If real-world CBZs ever hit unsupported edge cases, production swaps this
/// for ZIPFoundation (SPM) behind the same `ZipArchive` API.

struct ZipEntry {
    let name: String
    let method: UInt16
    let flags: UInt16
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    let crc32: UInt32
}

enum ZipError: Error, CustomStringConvertible {
    case truncated
    case eocdNotFound
    case zip64Unsupported
    case badSignature(String)
    case unsupportedMethod(UInt16)
    case inflateFailed(Int32)
    case deflateFailed(Int32)
    case sizeMismatch(expected: Int, got: Int)
    case crcMismatch(expected: UInt32, got: UInt32)

    var description: String {
        switch self {
        case .truncated: return "file truncated"
        case .eocdNotFound: return "end-of-central-directory not found"
        case .zip64Unsupported: return "ZIP64 not supported by spike reader"
        case .badSignature(let w): return "bad signature at \(w)"
        case .unsupportedMethod(let m): return "unsupported compression method \(m)"
        case .inflateFailed(let c): return "inflate failed (\(c))"
        case .deflateFailed(let c): return "deflate failed (\(c))"
        case .sizeMismatch(let e, let g): return "size mismatch (expected \(e), got \(g))"
        case .crcMismatch(let e, let g): return String(format: "CRC mismatch (expected %08x, got %08x)", e, g)
        }
    }
}

// MARK: - Data little-endian helpers

extension Data {
    func leUInt16(_ off: Int) throws -> UInt16 {
        guard off + 2 <= count else { throw ZipError.truncated }
        return UInt16(self[off]) | (UInt16(self[off + 1]) << 8)
    }

    func leUInt32(_ off: Int) throws -> UInt32 {
        guard off + 4 <= count else { throw ZipError.truncated }
        return UInt32(self[off]) | (UInt32(self[off + 1]) << 8)
            | (UInt32(self[off + 2]) << 16) | (UInt32(self[off + 3]) << 24)
    }

    var zipCrc32: UInt32 {
        if isEmpty { return 0 }
        return withUnsafeBytes { buf -> UInt32 in
            UInt32(crc32(0, buf.bindMemory(to: Bytef.self).baseAddress, uInt(count)))
        }
    }

    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

// MARK: - Reader

final class ZipArchive {
    let data: Data
    private(set) var entries: [ZipEntry] = []

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        try parseCentralDirectory()
    }

    private func parseCentralDirectory() throws {
        // Find EOCD (0x06054b50) scanning back past the max comment length.
        guard data.count >= 22 else { throw ZipError.truncated }
        var eocdOff: Int = -1
        let minOff = max(0, data.count - 22 - 65535)
        var i = data.count - 22
        while i >= minOff {
            if try data.leUInt32(i) == 0x06054b50 { eocdOff = i; break }
            i -= 1
        }
        guard eocdOff >= 0 else { throw ZipError.eocdNotFound }

        let totalEntriesRaw = try data.leUInt16(eocdOff + 10)
        let cdSizeRaw = try data.leUInt32(eocdOff + 12)
        let cdOffRaw = try data.leUInt32(eocdOff + 16)
        guard totalEntriesRaw != 0xFFFF, cdSizeRaw != 0xFFFFFFFF, cdOffRaw != 0xFFFFFFFF
        else { throw ZipError.zip64Unsupported }

        let total = Int(totalEntriesRaw)
        var off = Int(cdOffRaw)
        entries.reserveCapacity(total)
        for _ in 0..<total {
            guard try data.leUInt32(off) == 0x02014b50 else { throw ZipError.badSignature("central@\(off)") }
            let flags = try data.leUInt16(off + 8)
            let method = try data.leUInt16(off + 10)
            let crc = try data.leUInt32(off + 16)
            let csize = try data.leUInt32(off + 20)
            let usize = try data.leUInt32(off + 24)
            guard csize != 0xFFFFFFFF, usize != 0xFFFFFFFF else { throw ZipError.zip64Unsupported }
            let nameLen = Int(try data.leUInt16(off + 28))
            let extraLen = Int(try data.leUInt16(off + 30))
            let commentLen = Int(try data.leUInt16(off + 32))
            let lho = try data.leUInt32(off + 42)
            guard off + 46 + nameLen <= data.count else { throw ZipError.truncated }
            let nameData = data.subdata(in: off + 46 ..< off + 46 + nameLen)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)
            entries.append(ZipEntry(name: name, method: method, flags: flags,
                                    compressedSize: UInt64(csize),
                                    uncompressedSize: UInt64(usize),
                                    localHeaderOffset: UInt64(lho),
                                    crc32: crc))
            off += 46 + nameLen + extraLen + commentLen
        }
    }

    /// Page-ordered names (comic convention: natural order of stored names).
    var pageNames: [String] {
        entries.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func read(_ entry: ZipEntry) throws -> Data {
        let lh = Int(entry.localHeaderOffset)
        guard try data.leUInt32(lh) == 0x04034b50 else { throw ZipError.badSignature("local@\(lh)") }
        let nameLen = Int(try data.leUInt16(lh + 26))
        let extraLen = Int(try data.leUInt16(lh + 28))
        let dataOff = lh + 30 + nameLen + extraLen
        let cSize = Int(entry.compressedSize)
        guard dataOff >= 0, dataOff + cSize <= data.count else { throw ZipError.truncated }
        let comp = data.subdata(in: dataOff ..< dataOff + cSize)

        let raw: Data
        switch entry.method {
        case 0: raw = comp
        case 8: raw = try Self.inflateRaw(comp, expected: Int(entry.uncompressedSize))
        default: throw ZipError.unsupportedMethod(entry.method)
        }
        guard raw.count == Int(entry.uncompressedSize) else {
            throw ZipError.sizeMismatch(expected: Int(entry.uncompressedSize), got: raw.count)
        }
        let got = raw.zipCrc32
        guard got == entry.crc32 else { throw ZipError.crcMismatch(expected: entry.crc32, got: got) }
        return raw
    }

    static func inflateRaw(_ src: Data, expected: Int) throws -> Data {
        var stream = z_stream()
        var st = inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard st == Z_OK else { throw ZipError.inflateFailed(st) }
        defer { inflateEnd(&stream) }

        var out = Data(count: expected)
        var written = 0
        let ret: Int32 = out.withUnsafeMutableBytes { outBuf -> Int32 in
            src.withUnsafeBytes { inBuf -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: inBuf.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count)
                stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(expected)
                var s: Int32 = Z_OK
                if expected == 0 { return Z_STREAM_END }
                repeat { s = inflate(&stream, Z_FINISH) } while s == Z_OK
                written = expected - Int(stream.avail_out)
                return s
            }
        }
        guard ret == Z_STREAM_END else { throw ZipError.inflateFailed(ret) }
        if written < expected { out.removeSubrange(written ..< expected) }
        return out
    }
}

// MARK: - Writer (test-fixture generation only)

enum ZipWriter {
    /// Creates a standard ZIP at `url`. Files deflated (method 8) unless
    /// deflate doesn't help → stored (method 0).
    static func create(at url: URL, files: [(name: String, data: Data)]) throws {
        var localParts: [Data] = []
        var centralParts: [Data] = []
        var offset = 0
        let dosDate: UInt16 = UInt16(((2026 - 1980) << 9) | (10 << 5) | 22)
        let dosTime: UInt16 = 0

        for (name, content) in files {
            let nameBytes = Array(name.utf8)
            let crc = content.zipCrc32
            var payload = try deflateRaw(content)
            var method: UInt16 = 8
            if payload.count >= content.count {
                payload = content
                method = 0
            }

            var lh = Data()
            lh.appendLE(UInt32(0x04034b50))
            lh.appendLE(UInt16(20))          // version needed
            lh.appendLE(UInt16(0))           // flags
            lh.appendLE(method)
            lh.appendLE(dosTime); lh.appendLE(dosDate)
            lh.appendLE(crc)
            lh.appendLE(UInt32(payload.count))
            lh.appendLE(UInt32(content.count))
            lh.appendLE(UInt16(nameBytes.count))
            lh.appendLE(UInt16(0))           // extra len
            lh.append(contentsOf: nameBytes)
            lh.append(payload)
            localParts.append(lh)

            var cd = Data()
            cd.appendLE(UInt32(0x02014b50))
            cd.appendLE(UInt16(20)); cd.appendLE(UInt16(20))  // made by / needed
            cd.appendLE(UInt16(0))                            // flags
            cd.appendLE(method)
            cd.appendLE(dosTime); cd.appendLE(dosDate)
            cd.appendLE(crc)
            cd.appendLE(UInt32(payload.count))
            cd.appendLE(UInt32(content.count))
            cd.appendLE(UInt16(nameBytes.count))
            cd.appendLE(UInt16(0)); cd.appendLE(UInt16(0))    // extra, comment
            cd.appendLE(UInt16(0)); cd.appendLE(UInt16(0))    // disk, internal
            cd.appendLE(UInt32(0))                            // external attrs
            cd.appendLE(UInt32(offset))                       // local header offset
            cd.append(contentsOf: nameBytes)
            centralParts.append(cd)

            offset += lh.count
        }

        let centralData = centralParts.reduce(into: Data()) { $0.append($1) }
        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50))
        eocd.appendLE(UInt16(0)); eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(files.count)); eocd.appendLE(UInt16(files.count))
        eocd.appendLE(UInt32(centralData.count))
        eocd.appendLE(UInt32(offset))
        eocd.appendLE(UInt16(0))

        var all = Data()
        localParts.forEach { all.append($0) }
        all.append(centralData)
        all.append(eocd)
        try all.write(to: url, options: .atomic)
    }

    static func deflateRaw(_ src: Data) throws -> Data {
        if src.isEmpty { return Data() }
        var stream = z_stream()
        var st = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                               Z_DEFAULT_STRATEGY, zlibVersion(),
                               Int32(MemoryLayout<z_stream>.size))
        guard st == Z_OK else { throw ZipError.deflateFailed(st) }
        defer { deflateEnd(&stream) }

        let cap = Int(compressBound(uLong(src.count))) + 64
        var out = Data(count: cap)
        var written = 0
        let ret: Int32 = out.withUnsafeMutableBytes { outBuf -> Int32 in
            src.withUnsafeBytes { inBuf -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: inBuf.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count)
                stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(cap)
                var s: Int32 = Z_OK
                repeat { s = deflate(&stream, Z_FINISH) } while s == Z_OK
                written = cap - Int(stream.avail_out)
                return s
            }
        }
        guard ret == Z_STREAM_END else { throw ZipError.deflateFailed(ret) }
        if written < cap { out.removeSubrange(written ..< cap) }
        return out
    }
}
