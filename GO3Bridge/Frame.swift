import Foundation

/// GO3 的帧格式，与 go3-bridge/proto/send.py 的 build_frame() 逐字节对应：
///
///     AA 55 | type | seq | 00 01 | 00 00 | src | dst | len(2B 大端) | payload | crc16(2B 大端)
///      0  1     2      3     4  5     6  7     8     9     10  11        12..      末尾2B
///
/// **长度字段是 2 字节大端（偏移 10..11），不是 1 字节** —— 这条 2026-11-18 才纠正。
/// 短帧的高位恰好是 00，所以按单字节读也一直"能用"；直到拿官方初始化序列里
/// 两条 283 字节的 SAGENOTE 语言表帧做 CRC 校验才露馅（283−14=269=0x010D）。
/// 改成 `(b[10]<<8)|b[11]` 后：初始化序列 21/21、历史通知日志 27/27 全过。
enum GO3FrameError: Error {
    case notOurFrame
    case tooShort
    case lengthMismatch
    case crcMismatch
}

/// 地址约定，来自 sniff.log 的实测：
/// 手机 → 眼镜 的 95 条发送帧**全部**是 `type=0x00 src=3 dst=1`；
/// 眼镜 → 手机 的 1537 条接收帧是 `src=1或2 dst=3`。
/// 早前把「接收方向」的帧原样发回眼镜，等于把对方的话念回给它听，眼镜当然没反应。
enum GO3Peer {
    static let typePhone: UInt8 = 0x00
    static let srcPhone: UInt8 = 3
    static let dstGlasses: UInt8 = 1
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

        let len = (Int(b[10]) << 8) | Int(b[11])
        guard b.count >= headerLength + len + crcLength else { return nil }

        let payload = Array(b[headerLength ..< (headerLength + len)])
        let crcRecv = (UInt16(b[headerLength + len]) << 8) | UInt16(b[headerLength + len + 1])
        let crcCalc = CRC16.ccittFalse(Array(b[0 ..< (headerLength + len)]))

        return GO3Frame(type: b[2], seq: b[3], src: b[8], dst: b[9],
                        payload: payload, crcOK: crcRecv == crcCalc)
    }

    /// 造一个包。包头布局全部来自官方 App 真实发出的字节（sniff.log 里 95 条发送帧），
    /// 不是推的：`[2]=0x00`、`[4..5]=总包数`、`[6..7]=当前包号`、`[8]=3(手机)`、`[9]=1(眼镜)`。
    static func buildPacket(seq: UInt8, total: Int, index: Int, payload: [UInt8]) -> Data {
        var body: [UInt8] = [0xAA, 0x55,
                             GO3Peer.typePhone, seq,
                             UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF),
                             UInt8((index >> 8) & 0xFF), UInt8(index & 0xFF),
                             GO3Peer.srcPhone, GO3Peer.dstGlasses,
                             UInt8((payload.count >> 8) & 0xFF),
                             UInt8(payload.count & 0xFF)]
        body.append(contentsOf: payload)
        let crc = CRC16.ccittFalse(body)
        body.append(UInt8(crc >> 8))
        body.append(UInt8(crc & 0xFF))
        return Data(body)
    }

    /// 一条消息按单包上限切成多个包。官方 App 就是这么发的：
    /// 每包总长 ≤244B（Android MTU 247 − 3），超出就 total=N、index=k、seq 不变。
    static func packets(seq: UInt8, payload: [UInt8], maxPayload: Int) -> [Data] {
        let size = max(16, maxPayload)
        let total = max(1, (payload.count + size - 1) / size)
        if total == 1 {
            return [buildPacket(seq: seq, total: 1, index: 0, payload: payload)]
        }
        var out: [Data] = []
        for i in 0 ..< total {
            let lo = i * size
            let hi = min(lo + size, payload.count)
            out.append(buildPacket(seq: seq, total: total, index: i,
                                   payload: Array(payload[lo ..< hi])))
        }
        return out
    }

    /// 从记录下来的帧里只取 payload。
    /// 注意：`INTEL/app_init_wire.json` 里的 `frame` 字段是早前按「接收方向」模板合成的，
    /// 包头（type/src/dst）是错的，只有 payload 是官方 protobuf 的真实内容。
    /// stripVersion：官方发出的 protobuf 文本里没有 `version:` 字段，而收到的都有
    /// `version: 1`，说明手机发的时候不带这 2 个字节。
    static func payloadFromRecorded(_ hex: String, stripVersion: Bool) -> [UInt8]? {
        guard let data = dataFromHex(hex) else { return nil }
        let b = [UInt8](data)
        guard b.count >= 14 else { return nil }
        let len = (Int(b[10]) << 8) | Int(b[11])
        guard len > 0, b.count >= 12 + len + 2 else { return nil }
        var p = Array(b[12 ..< (12 + len)])
        if stripVersion, p.count >= 2, p[0] == 0x08, p[1] == 0x01 {
            p.removeFirst(2)
        }
        return p
    }

    /// 构造器自检：拿官方真实捕获的「亮度 30」帧逐字节比对。
    /// 这条帧是从 sniff.log 的「传输数据：」里原样抄的，CRC 已验证通过。
    static func builderSelfTest() -> String {
        let golden = "aa5500b2000100000301000c100b720808011a040801280628fe"
        let payload: [UInt8] = [0x10, 0x0b, 0x72, 0x08, 0x08, 0x01,
                                0x1a, 0x04, 0x08, 0x01, 0x28, 0x06]
        let built = buildPacket(seq: 178, total: 1, index: 0, payload: payload)
        let mine = built.map { String(format: "%02x", $0) }.joined()
        if mine == golden { return "一致" }
        return "不一致！我方=\(mine) 官方=\(golden)"
    }

    /// 十六进制字符串 → 字节。初始化序列里存的是原样帧，直接还原即可。
    static func dataFromHex(_ s: String) -> Data? {
        let clean = s.replacingOccurrences(of: " ", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            guard let next = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) else { return nil }
            guard let b = UInt8(clean[i ..< next], radix: 16) else { return nil }
            bytes.append(b)
            i = next
        }
        return Data(bytes)
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
