import Foundation

/// GO3 的帧格式，与 go3-bridge/proto/send.py 的 build_frame() 逐字节对应：
///
///     AA 55 | type | seq | 00 01 | 00 00 | src | dst | 00 | len | payload | crc16(2B, 大端)
///      0  1     2      3     4  5     6  7     8     9    10   11     12..     末尾2B
///
/// 这个布局不是猜的：安卓侧用 bleak 实测收发验证过，记录在
/// go3-bridge/proto/PROTOCOL.md 与 recon/out/4E048CFE585E_notify.log。
enum GO3FrameError: Error {
    case notOurFrame
    case tooShort
    case lengthMismatch
    case crcMismatch
}

struct GO3Frame {
    let type: UInt8
    let seq: UInt8
    let src: UInt8
    let dst: UInt8
    let payload: [UInt8]
    let crcOK: Bool

    static let headerLength = 12
    static let crcLength = 2

    /// 从通知里收到的字节解析。解析失败返回 nil，调用方按原样打印 hex 即可。
    static func parse(_ data: Data) -> GO3Frame? {
        let b = [UInt8](data)
        guard b.count >= headerLength + crcLength else { return nil }
        guard b[0] == 0xAA, b[1] == 0x55 else { return nil }

        let len = Int(b[11])
        guard b.count >= headerLength + len + crcLength else { return nil }

        let payload = Array(b[headerLength ..< (headerLength + len)])
        let crcRecv = (UInt16(b[headerLength + len]) << 8) | UInt16(b[headerLength + len + 1])
        let crcCalc = CRC16.ccittFalse(Array(b[0 ..< (headerLength + len)]))

        return GO3Frame(type: b[2], seq: b[3], src: b[8], dst: b[9],
                        payload: payload, crcOK: crcRecv == crcCalc)
    }

    /// 构造一帧（P2 之后发命令用）。P1 阶段不调用，先摆在这里保证两边算法一致。
    static func build(type: UInt8, seq: UInt8, src: UInt8, dst: UInt8,
                      payload: [UInt8]) -> Data {
        var body: [UInt8] = [0xAA, 0x55, type, seq,
                             0x00, 0x01, 0x00, 0x00,
                             src, dst, 0x00, UInt8(payload.count & 0xFF)]
        body.append(contentsOf: payload)
        let crc = CRC16.ccittFalse(body)
        body.append(UInt8(crc >> 8))
        body.append(UInt8(crc & 0xFF))
        return Data(body)
    }

    /// 给日志看的一行摘要。
    var summary: String {
        String(format: "type=0x%02X seq=0x%02X src=%u dst=%u len=%d crc=%@",
               type, seq, src, dst, payload.count, crcOK ? "OK" : "BAD")
    }

    /// 尽力把 payload 开头的 protobuf 读成人话。
    /// 最常见的形态是 f1(=1 表示"状态") + f2(=命令号)，字节序列为 `08 01 10 XX`。
    /// 读不出来就返回 nil，不要编。
    var pbBrief: String? {
        guard payload.count >= 4 else { return nil }
        guard payload[0] == 0x08, payload[2] == 0x10 else { return nil }
        let f1 = payload[1]
        var idx = 3
        var value: UInt32 = 0
        var shift: UInt32 = 0
        while idx < payload.count {
            let byte = payload[idx]
            value |= UInt32(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            idx += 1
            if shift > 21 { break }
        }
        return String(format: "f1=%u f2=0x%02X(%u)", f1, value, value)
    }
}

enum CRC16 {
    /// CRC-16/CCITT-FALSE：初值 0xFFFF，多项式 0x1021，不反转，不异或。
    /// 与 send.py 的 crc16_ccitt_false() 完全一致。
    static func ccittFalse(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0 ..< 8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }
}
