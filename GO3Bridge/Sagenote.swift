import Foundation

/// 「会记」（SAGENOTE，msgType 43 / 内层 f46）的协议实现。
///
/// 为什么单独一个文件：这是眼镜上「会记」功能的全部控制面，字段和枚举都是从
/// 官方 App 反编译里逐条抠出来的，不是猜的：
///   tools/jadx_full/sources/com/inmo/app/module_go3device/SagenoteProto.java
///   tools/jadx_full/sources/com/inmo/app/module_go3device/manager/SagenoteProbufProcessManager.java
///
/// 关键结论（2026-11-19 实测日志 22:24:44 印证）：
/// 眼镜打开会记后会发 `SAGENOTE_COMMAND`，**App 必须回 `SAGENOTE_COMMAND_ACK`**，
/// 官方 `SagenoteProbufProcessManager.sendAck()` 就是干这个的。我们不回，
/// 眼镜就一直等 ACK —— 屏幕上的计时因此不动。
enum SagenoteMsg: Int {
    case command = 0
    case commandAck = 1
    case query = 2
    case state = 3
    case asr = 4
    case translation = 5
    case summary = 6
    case config = 7
    case panel = 8
    case marker = 9
    case languageList = 11
    case tabView = 12
    case backup = 13

    var name: String {
        switch self {
        case .command: return "COMMAND 命令"
        case .commandAck: return "COMMAND_ACK 命令回执"
        case .query: return "QUERY 查询"
        case .state: return "STATE 采集状态"
        case .asr: return "ASR 识别结果"
        case .translation: return "TRANSLATION 翻译"
        case .summary: return "SUMMARY 摘要"
        case .config: return "CONFIG 配置"
        case .panel: return "PANEL 面板"
        case .marker: return "MARKER 标记"
        case .languageList: return "LANGUAGE_LIST 语言表"
        case .tabView: return "TAB_VIEW 页签"
        case .backup: return "BACKUP 音频备份"
        }
    }
}

/// `SagenoteCommandType`：0 开始 / 1 停止 / 2 通知已开始 / 3 通知已停止 / 4 暂停 / 5 继续
enum SagenoteCmd: Int {
    case start = 0, stop = 1, notifyStarted = 2, notifyStopped = 3, pause = 4, resume = 5
    var name: String {
        switch self {
        case .start: return "START_MEETING 开始"
        case .stop: return "STOP_MEETING 停止"
        case .notifyStarted: return "NOTIFY_MEETING_STARTED 已开始"
        case .notifyStopped: return "NOTIFY_MEETING_STOPPED 已停止"
        case .pause: return "PAUSE_MEETING 暂停"
        case .resume: return "RESUME_MEETING 继续"
        }
    }
}

/// `SagenoteCaptureState`：0 空闲 / 1 采集中 / 2 挂起
enum SagenoteCapture: Int {
    case idle = 0, active = 1, suspended = 2
    var name: String {
        switch self {
        case .idle: return "IDLE 空闲"
        case .active: return "ACTIVE 采集中"
        case .suspended: return "SUSPENDED 挂起"
        }
    }
}

/// 解出来的一条 SAGENOTE 消息。id 保留原始字节 —— ACK 要原样回显，转成 String 再转回去
/// 一旦有非 ASCII 就会变样。
struct SagenoteIn {
    let msgType: Int
    let commandId: [UInt8]
    let sessionId: [UInt8]
    let cmd: Int?
    let source: Int?
    let captureState: Int?

    var typeName: String { SagenoteMsg(rawValue: msgType)?.name ?? "未知(\(msgType))" }
    var commandIdStr: String { String(decoding: commandId, as: UTF8.self) }
    var sessionIdStr: String { String(decoding: sessionId, as: UTF8.self) }

    /// 从 `Message` 顶层 payload 里解；不是会记消息返回 nil。
    /// 判定依据是内层字段号：msgType 43 → f46（43+3），不依赖 f2 是否出现
    /// —— 实测眼镜发的会记帧里 f2 有时缺失。
    static func decode(_ payload: [UInt8]) -> SagenoteIn? {
        let top = Pb.parse(payload)
        guard let inner = Pb.first(top, 46), inner.wire == 2 else { return nil }
        let s = Pb.parse(inner.bytes)

        let msgType = Pb.first(s, 1)?.asInt ?? -1
        let commandId = Pb.first(s, 2)?.bytes ?? []
        let sessionId = Pb.first(s, 3)?.bytes ?? []

        var cmd: Int?
        var source: Int?
        if let c = Pb.first(s, 10), c.wire == 2 {
            let f = Pb.parse(c.bytes)
            cmd = Pb.first(f, 1)?.asInt
            source = Pb.first(f, 2)?.asInt
        }
        var capture: Int?
        if let st = Pb.first(s, 13), st.wire == 2 {
            capture = Pb.first(Pb.parse(st.bytes), 1)?.asInt
        }
        return SagenoteIn(msgType: msgType, commandId: commandId, sessionId: sessionId,
                          cmd: cmd, source: source, captureState: capture)
    }

    var summary: String {
        var parts = ["会记 \(typeName)"]
        if let c = cmd {
            parts.append("cmd=\(c)(\(SagenoteCmd(rawValue: c)?.name ?? "?"))")
        }
        if let src = source {
            parts.append("来自\(src == 1 ? "眼镜" : src == 0 ? "手机" : "系统")")
        }
        if let cs = captureState {
            parts.append("采集=\(SagenoteCapture(rawValue: cs)?.name ?? "?")")
        }
        if !sessionId.isEmpty { parts.append("session=\(sessionIdStr)") }
        return parts.joined(separator: " ")
    }
}

/// 编解码工具：极简 protobuf 写入。
enum PbW {
    static func varint(_ v: Int) -> [UInt8] {
        var n = UInt64(max(0, v))
        var out: [UInt8] = []
        repeat {
            var b = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 { b |= 0x80 }
            out.append(b)
        } while n != 0
        return out
    }

    static func int(_ field: Int, _ v: Int) -> [UInt8] {
        var out = varint(field << 3 | 0)
        out.append(contentsOf: varint(v))
        return out
    }

    static func bytes(_ field: Int, _ v: [UInt8]) -> [UInt8] {
        var out = varint(field << 3 | 2)
        out.append(contentsOf: varint(v.count))
        out.append(contentsOf: v)
        return out
    }

    static func string(_ field: Int, _ s: String) -> [UInt8] {
        bytes(field, Array(s.utf8))
    }
}

enum SagenoteOut {

    /// 官方 `SagenoteProbufProcessManager.sendAck()` 的逐字段复刻：
    /// ```
    /// Sagenote{ f1=COMMAND_ACK(1), f2=commandId, f3=sessionId, f4=now_ms,
    ///           f11 = CommandAck{ f1=cmd, f2=ok, f3=errorCode, f5=sessionId } }
    /// ```
    /// 关键：`commandId` 和 `sessionId` 必须**原样回显**，眼镜靠这两个对账。
    static func commandAck(commandId: [UInt8], sessionId: [UInt8],
                           cmd: Int, ok: Bool, errorCode: Int = 0) -> [UInt8] {
        var ack: [UInt8] = []
        ack += PbW.int(1, cmd)
        ack += PbW.int(2, ok ? 1 : 0)
        // 官方样本里 errorCode=0 时这个字段是**不出现**的（`5a 18 08 02 10 01 2a 12 …`）。
        // 显式写 `18 00` 语义一样，但对不上字节，排查时容易误判，所以照官方的做法省掉。
        if errorCode != 0 { ack += PbW.int(3, errorCode) }
        ack += PbW.bytes(5, sessionId)

        var body: [UInt8] = []
        body += PbW.int(1, SagenoteMsg.commandAck.rawValue)
        body += PbW.bytes(2, commandId)
        body += PbW.bytes(3, sessionId)
        body += PbW.int(4, Int(Date().timeIntervalSince1970 * 1000))
        body += PbW.bytes(11, ack)
        return wrap(body)
    }

    /// 把 Sagenote 塞进 `Message{ f2=43, f46=... }`。
    /// 手机发出的帧不带 `08 01` 版本前缀（官方 95 条发送样本里都没有）。
    /// 对照真实抓包 `aa55006200020000030100e6 102b f202 9902 ...`：
    /// 顶层就是 `10 2b | f2 02 <len> | <sagenote>`。
    static func wrap(_ sagenote: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x10, 0x2B]          // f2 = 43 (SAGENOTE)
        out += PbW.bytes(46, sagenote)           // f46 = 内层
        return out
    }

    /// 每秒一条的「采集状态心跳」。
    ///
    /// **这是眼镜屏幕上那个计时器的驱动源。** 官方抓包里手机每秒发一条：
    /// `08 03 | 1a 12 "mt-…" | 20 <ts> | 6a 0a 08 01 10 01 18 01 20 02 2a 00`
    /// 其中 `18 01` 那个数是**逐秒递增**的序号（抓包里 01→02→04→05…→1a）。
    /// 我们从来不发，所以眼镜进了会记界面也一直显示 00:00 —— 这就是「不计时」的根因。
    static func state(sessionId: [UInt8], seq: Int) -> [UInt8] {
        var st: [UInt8] = []
        st += PbW.int(1, SagenoteCapture.active.rawValue)   // 采集中
        st += PbW.int(2, 1)
        st += PbW.int(3, seq)                                // 递增序号
        st += PbW.int(4, 2)
        st += PbW.bytes(5, [])                               // 官方也带这个空串

        var body: [UInt8] = []
        body += PbW.int(1, SagenoteMsg.state.rawValue)
        body += PbW.bytes(3, sessionId)
        body += PbW.int(4, Int(Date().timeIntervalSince1970 * 1000))
        body += PbW.bytes(13, st)
        return wrap(body)
    }

    /// 上报一段识别结果（`SAGENOTE_ASR`）。
    ///
    /// 官方抓包原文（seq=6b）：
    /// `08 04 | 1a 12 "mt-…" | 20 <ts> | 72 1e | 10 01 | 1a 1a 08 01 12 03 "叫" 20 02 2a 09 "其他人" 30 cc17 38 cc17`
    /// 结构：`SagenoteAsr{ f1=is_final, f2=mode, f3=SagenoteSegment }`，
    /// 段里 `f1=段号 / f2=文字 / f4=角色 / f5=说话人 / f6=开始ms / f7=结束ms`。
    ///
    /// 说明：真正要做会记，这段文字得来自「Opus 解码 + 云端 ASR」。
    /// 现在先提供手动注入，用来单独验证**回传通道**通不通 —— 通道和识别是两个问题，别混在一起查。
    static func asr(sessionId: [UInt8], text: String, segmentId: Int,
                    beginMs: Int, endMs: Int, speaker: String = "其他人") -> [UInt8] {
        var seg: [UInt8] = []
        seg += PbW.int(1, segmentId)
        seg += PbW.string(2, text)
        seg += PbW.int(4, 2)                 // role
        seg += PbW.string(5, speaker)
        seg += PbW.int(6, beginMs)
        seg += PbW.int(7, endMs)

        var asr: [UInt8] = []
        asr += PbW.int(1, 1)                 // is_final
        asr += PbW.int(2, 1)                 // mode
        asr += PbW.bytes(3, seg)

        var body: [UInt8] = []
        body += PbW.int(1, SagenoteMsg.asr.rawValue)
        body += PbW.bytes(3, sessionId)
        body += PbW.int(4, Int(Date().timeIntervalSince1970 * 1000))
        body += PbW.bytes(14, asr)
        return wrap(body)
    }
}
