import Foundation

/// 极简 protobuf 读取器。
/// 为什么需要它：绑定结果（`BLE_CONNECT_BIND` / f27）是整个流程的闸门——
/// 官方代码里 `if (bindStatus.getIsBound())` 才在 5 秒后跑初始化，否则**直接断开**。
/// 不解出 isBound / errorCode，就只能靠猜。
enum Pb {

    struct Field {
        let number: Int
        let wire: Int
        let varint: UInt64
        let bytes: [UInt8]

        var asInt: Int { Int(varint) }
        var asBool: Bool { varint != 0 }
        var asString: String { String(decoding: bytes, as: UTF8.self) }
    }

    static func varint(_ d: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < d.count, shift < 64 {
            let b = d[i]
            value |= UInt64(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 { return (value, i) }
            shift += 7
        }
        return nil
    }

    /// 把一层 protobuf 切成字段列表。遇到不认识的 wire type 就停，不硬猜。
    static func parse(_ d: [UInt8]) -> [Field] {
        var out: [Field] = []
        var i = 0
        while i < d.count {
            guard let (key, afterKey) = varint(d, i) else { return out }
            i = afterKey
            let number = Int(key >> 3)
            let wire = Int(key & 0x07)
            switch wire {
            case 0:
                guard let (v, afterV) = varint(d, i) else { return out }
                i = afterV
                out.append(Field(number: number, wire: 0, varint: v, bytes: []))
            case 2:
                guard let (len, afterLen) = varint(d, i) else { return out }
                let end = afterLen + Int(len)
                guard end <= d.count else { return out }
                out.append(Field(number: number, wire: 2, varint: len,
                                 bytes: Array(d[afterLen ..< end])))
                i = end
            case 5:
                i += 4
            case 1:
                i += 8
            default:
                return out
            }
        }
        return out
    }

    static func first(_ fields: [Field], _ number: Int) -> Field? {
        fields.first { $0.number == number }
    }
}

/// `BLE_CONNECT_BIND`（msg 24 / 内层 f27）的解码结果。
/// 枚举值对照 `INTEL/commands.md` 的 BleConnectBindType 表：
/// 0 查询绑定状态 / 1 回连 / 2 上报绑定用户数据 / 3 绑定状态响应 /
/// 4 解绑响应 / 5 重连响应 / 6 解绑 / 7 手机信息
struct BindReport {
    let msgType: Int
    let isBound: Bool
    let errorCode: Int
    let boundUserId: String

    static let typeNames: [Int: String] = [
        0: "QUERY_BIND_STATE", 1: "BACK_LINK", 2: "BIND_USERDATA",
        3: "BIND_STATUS_RESPONSE", 4: "UNBIND_RESPONSE", 5: "RECONNECT_RESPONSE",
        6: "UNBIND", 7: "PHONE_INFO",
    ]

    var typeName: String { BindReport.typeNames[msgType] ?? "未知(\(msgType))" }

    /// 从一条 `Message` 的 payload 里解出绑定信息；不是绑定消息就返回 nil。
    static func decode(_ payload: [UInt8]) -> BindReport? {
        let top = Pb.parse(payload)
        // 先确认是 BLE_CONNECT_BIND：顶层 f2 = 24
        if let f2 = Pb.first(top, 2), f2.wire == 0, f2.asInt != 24 { return nil }
        guard let inner = Pb.first(top, 27), inner.wire == 2 else { return nil }

        let sub = Pb.parse(inner.bytes)
        let msgType = Pb.first(sub, 1)?.asInt ?? -1

        var isBound = false
        var errorCode = 0
        var userId = ""
        if let st = Pb.first(sub, 4), st.wire == 2 {
            let s = Pb.parse(st.bytes)
            isBound = Pb.first(s, 1)?.asBool ?? false
            if let u = Pb.first(s, 2), u.wire == 2 { userId = u.asString }
            errorCode = Pb.first(s, 3)?.asInt ?? 0
        }
        return BindReport(msgType: msgType, isBound: isBound,
                          errorCode: errorCode, boundUserId: userId)
    }

    /// 官方 `BleProtocolManager` 对 errorCode 的处理，原样搬过来当人话：
    /// 1 = 该设备已被别的账号绑定；3/4 = 被动解绑（需重新绑定）；2 = 直接收工。
    var hint: String {
        switch errorCode {
        case 1: return "设备已被其他账号绑定"
        case 2: return "设备拒绝（errorCode=2）"
        case 3, 4: return "被动解绑状态，需要重新绑定"
        default: return "errorCode=\(errorCode)"
        }
    }

    var summary: String {
        "绑定响应 \(typeName)：isBound=\(isBound ? 1 : 0) "
            + "errorCode=\(errorCode)\(boundUserId.isEmpty ? "" : " boundUserId=\(boundUserId)")"
    }
}
