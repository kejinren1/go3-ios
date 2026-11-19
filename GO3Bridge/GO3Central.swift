import Foundation
import CoreBluetooth
import UIKit
import os

/// GO3 眼镜的 GATT 坐标。
/// 这些值不是猜的，是从安卓官方 App 的 smali 里挖出来、再用 bleak 实测验证过的，
/// 记录在 go3-bridge/recon/out/4E048CFE585E_gatt.txt 与 proto/PROTOCOL.md。
enum GO3UUID {
    static let svc7033     = CBUUID(string: "00007033-0000-1000-8000-00805f9b34fb")
    static let write1001   = CBUUID(string: "00001001-0000-1000-8000-00805f9b34fb")
    static let notify1002  = CBUUID(string: "00001002-0000-1000-8000-00805f9b34fb")

    static let svc2020     = CBUUID(string: "00002020-0000-1000-8000-00805f9b34fb")
    static let rw2021      = CBUUID(string: "00002021-0000-1000-8000-00805f9b34fb")
    static let notify2022  = CBUUID(string: "00002022-0000-1000-8000-00805f9b34fb")
    static let notify2023  = CBUUID(string: "00002023-0000-1000-8000-00805f9b34fb")
}

struct BleDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
    let isGO3: Bool
}

/// P1 阶段的目标只有一个：**能不能连上、GATT 表跟安卓那边是不是同一张**。
/// 所以这里只做「扫描 → 连接 → 枚举 → 读一次 2021 → 订阅通知」，
/// 一个字节都不写。写错了可能把眼镜的对话状态机搞成半开（安卓那边踩过）。
/// `Message` 信封的拆解结果。
///
/// 铁律是 `Message{ f1=version, f2=msgType, f<msgType+3>=内层 }`，
/// 但**实测眼镜发来的帧经常没有 f2**（会记的 f46、绑定的 f27、音频的 f3 都没有）。
/// 所以这里不靠 f2 判断，直接取第一个 length-delimited 字段，用「字段号 − 3」反推 msgType：
///   f3 → AUDIO(0) · f14 → AI_ASSISTANT(11) · f27 → BLE_CONNECT_BIND(24) · f46 → SAGENOTE(43)
/// 这四种都跟 `MessageTypeProto` 对得上，也跟真实抓包一致。
struct GO3Envelope {
    let msgType: Int
    let inner: [UInt8]

    static func decode(_ payload: [UInt8]) -> GO3Envelope {
        let fields = Pb.parse(payload)
        // f2 存在时优先信它（和字段号互校过，见上面注释）
        let f2 = Pb.first(fields, 2).flatMap { $0.wire == 0 ? $0.asInt : nil }
        guard let body = fields.first(where: { $0.wire == 2 }) else {
            return GO3Envelope(msgType: f2 ?? -1, inner: [])
        }
        return GO3Envelope(msgType: f2 ?? (body.number - 3), inner: body.bytes)
    }
}

final class GO3Central: NSObject, ObservableObject {

    @Published private(set) var managerState: CBManagerState = .unknown
    @Published private(set) var devices: [BleDevice] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var scanning = false

    private var central: CBCentralManager!
    private var found: [UUID: CBPeripheral] = [:]

    /// 发送初始化帧要用到的三条特征。连上后才会被填。
    private var connectedPeripheral: CBPeripheral?
    private var writeChar1001: CBCharacteristic?
    private var rwChar2021: CBCharacteristic?

    /// 写哪条通道。默认 2021（read+write+writeNR，和通知 2022 同属一个服务），
    /// 但抓包里没记官方 App 用的是哪条，所以做成可切换，靠实测定。
    @Published var useRW2021 = true
    @Published private(set) var initRunning = false

    /// 手机发给眼镜的消息带不带 `08 01`（Message.version=1）这 2 个字节。
    /// 默认不带：官方发出了 95 条帧，protobuf 文本里没有一条有 `version:` 字段，
    /// 而眼镜发来的帧全部有 `version: 1`。真不生效再打开这个开关兜底。
    @Published var keepVersionPrefix = false

    /// 用"带回执"(write) 还是"无回执"(writeNR)。默认无回执——官方是流式发包。
    /// 但如果眼镜对 2021 上的无回执写直接不理，就得靠这个开关把两种情况分开，
    /// 否则永远分不清是信封错还是写方式错。
    @Published var useWriteResponse = false

    /// 绑定成功后要不要继续跑那 21 步初始化。
    ///
    /// ── 2026-11-17 23:29 实测后**改回默认开** ──
    /// P7 曾把它默认关掉，理由是「怕 SPEECH_INSCRIPTION 切页面吃命令」，那是猜的。
    /// 23:29 这次跳过 21 步后，眼镜菜单里的「会记」直接报「APP 版本过低无法打开」。
    /// 原因找到了：初始化第 4 步就是
    ///   `BLE_CONNECT_BIND{ kind=7(PHONE_INFO), f7=PhoneInfo{ f1="3.0.455" } }`
    /// —— 眼镜靠这条知道对端 App 的版本号。不发，它就认为版本过低。
    /// 那 21 步不是"会话初始化"的装饰，是**让眼镜相信对面是正版 App 的握手**，不能跳。
    @Published var runInitAfterBind = true

    /// 收到的帧数。这是判断"眼镜到底有没有在跟我们说话"最直接的指标：
    /// 长按 GO 键说了话之后如果这个数不涨，就是它根本没把 ASR 发出来，
    /// 而不是我们没解析。
    @Published private(set) var rxCount = 0

    // MARK: - 音频流统计（会记/翻译的语音都走这条）

    /// 眼镜把麦克风数据用 Opus 编好、按 `AUDIO(0)` 往上推。
    /// 22:24 那份日志里 248 帧中有 235 帧是音频：约 18 帧/秒、每帧 ~185B，
    /// 对应 16 kHz / 32 kbps。**它一直在送，是我们这边没接。**
    @Published private(set) var audioFrames = 0
    @Published private(set) var audioBytes = 0
    @Published private(set) var audioFPS: Double = 0

    private var audioWindowStart = Date()
    private var audioWindowFrames = 0
    private var lastAudioLog = Date.distantPast
    /// 本连接内是否已经留过首帧原文。一帧就够，多了刷屏。
    private var audioFirstFrameLogged = false

    /// 把 `AUDIO` 内层的 `AudioConfig{ f1=采样率, f2=声道, f3=码率, f4=型号 }` 读成人话。
    /// f4 的取值对照 `AudioModelTypeProto`：12 = AUDIO_SAGENOTE_MEETING。
    private func audioConfigText(_ inner: [UInt8]) -> String {
        let f = Pb.parse(inner)
        guard let cfgField = Pb.first(f, 1), cfgField.wire == 2 else {
            return "（没有 f1 AudioConfig，字段号：\(f.map { "f\($0.number)" }.joined(separator: ","))）"
        }
        let c = Pb.parse(cfgField.bytes)
        let rate = Pb.first(c, 1)?.asInt ?? -1
        let ch = Pb.first(c, 2)?.asInt ?? -1
        let br = Pb.first(c, 3)?.asInt ?? -1
        let model = Pb.first(c, 4)?.asInt ?? -1
        let modelName: String
        switch model {
        case 12: modelName = "12=会记(AUDIO_SAGENOTE_MEETING)"
        default: modelName = "\(model)"
        }
        return "AudioConfig 采样率=\(rate) 声道=\(ch) 码率=\(br) 型号=\(modelName)"
    }

    /// 最近一次收到的会记 session id。用来在「眼镜没让我们开录」时也能给它下发 STOP 收尾。
    @Published private(set) var lastSessionId: [UInt8] = []

    /// 最近一条会记消息的摘要，给界面看。
    @Published private(set) var lastSagenote = "（还没收到会记消息）"

    /// 已经回过 ACK 的 commandId。官方也有去重（`sagenoteCommandDedupKey`），
    /// 眼镜每秒会重发同一条命令，不挡就会把 ACK 刷成洪水。
    private var lastAckedCommandId: [UInt8] = []

    /// 一键流程用：全量初始化发完后自动补一枪亮度自检。
    /// 顺序很关键——绑定之前发命令，眼镜是直接丢的（用户 22:25 实测印证：
    /// 没绑定时亮度没反应，绑定后长按 GO 键从"要连接 INMO APP"变成"我在听"）。
    private var testAfterInit = false

    /// ── 定时断开（**默认关**，仅调试用）──────────────────────────
    /// 23:29 实测事故：P8 上一版把它默认开成 12 秒，用户刚绑定完准备去眼镜菜单点
    /// 「会记」，12 秒一到我方主动 `cancelPeripheralConnection`，眼镜屏幕上就跳出
    /// "蓝牙已断开"。日志里那行「⏳ 到点，主动断开」就是它干的，不是眼镜踢我们。
    ///
    /// 更要紧的是：**绑定由我们这个 App 完成，官方 App 不是这条链路的一环**
    /// （用户 23:32 明确纠正）。眼镜只认账号绑定状态，谁连上谁就能用。
    /// 所以「赶紧断开放手给官方 App」这个思路作废 —— 我们要一直在线。
    @Published var autoRelease = false
    /// 干完活后留几秒再断。留一点是因为亮度变化要人眼确认。
    @Published var releaseAfter: Double = 12

    private var releaseWork: DispatchWorkItem?
    /// 「单变量实验」提示只打一次，免得每个服务枚举完都刷一遍。
    private var experimentHintShown = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        // 日志实时通道：先起来，之后每行 append 都会顺手推出去。
        // 电脑端：pymobiledevice3 usbmux forward 8787 8787 → nc 127.0.0.1 8787
        LogServer.shared.start()
    }

    var stateText: String {
        switch managerState {
        case .poweredOn:    return "蓝牙已就绪"
        case .poweredOff:   return "蓝牙未打开"
        case .unauthorized: return "未授权使用蓝牙"
        case .unsupported:  return "设备不支持蓝牙"
        case .resetting:    return "蓝牙正在重置"
        case .unknown:      return "等待蓝牙初始化"
        @unknown default:   return "未知状态"
        }
    }

    // MARK: - 日志

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 日志同时落盘，目的只有一个：**不用手抄**。
    /// 沙盒 Documents 在打开 `UIFileSharingEnabled` 之后，电脑端可以用
    /// `pymobiledevice3 afc pull` 直接把文件拉走；Files App 里也能看到并分享。
    static let logFileName = "go3bridge.log"

    static var logFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(logFileName)
    }

    private static let osLog = OSLog(subsystem: "com.go3bridge.app", category: "bridge")
    private static let fileQueue = DispatchQueue(label: "go3.logfile", qos: .utility)

    private static func writeToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        fileQueue.async {
            let url = logFileURL
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                // 首次：带上启动时间，方便判断这份日志是哪一次的
                let head = "# GO3Bridge log started \(Date())\n"
                try? (head.data(using: .utf8)! + data).write(to: url)
            }
        }
    }

    /// 清空磁盘日志（新一轮排查前点一下，免得和上一场混在一起）
    func clearLogFile() {
        try? FileManager.default.removeItem(at: GO3Central.logFileURL)
        append("已清空磁盘日志文件（后续只记新的）")
    }

    /// 把当前内存里的日志整段写到磁盘并返回文件 URL，给界面上的「分享」用。
    func exportLog() -> URL? {
        let text = log.joined(separator: "\n") + "\n"
        let url = GO3Central.logFileURL
        do {
            try text.data(using: .utf8)?.write(to: url)
            append("已写出日志文件：\(url.lastPathComponent)（\(log.count) 行）")
            return url
        } catch {
            append("写日志文件失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func append(_ s: String) {
        let line = GO3Central.stamp.string(from: Date()) + "  " + s
        print(line)
        // 换掉裸 print：print 只进 stdout，侧载的发行版在设备上等于丢进黑洞。
        // os_log 才能被 syslog / Console 抓到（这是"实时看日志"的另一条通路）。
        os_log("%{public}@", log: GO3Central.osLog, type: .default, line)
        GO3Central.writeToFile(line)
        LogServer.shared.broadcast(line)
        log.append(line)
        // 原来 500 行，一轮 21 步握手的 hex 就能把前面的现场全挤掉。
        if log.count > 4000 {
            log.removeFirst(log.count - 4000)
        }
    }

    private func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    /// CBUUID 太长会把日志撑爆，只留后 4 位：00002022-... → 2022
    private func short(_ u: CBUUID) -> String {
        let s = u.uuidString
        return String(s.prefix(8)).suffix(4).uppercased()
    }

    private func props(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNR") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out.isEmpty ? "-" : out.joined(separator: ",")
    }

    // MARK: - 对外动作

    func startScan() {
        guard managerState == .poweredOn else {
            append("蓝牙未就绪（\(stateText)），不能扫描")
            return
        }
        devices.removeAll()
        found.removeAll()
        scanning = true
        append("开始扫描。眼镜要开机、亮屏，并且在眼镜上退出其他界面。")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        scanning = false
        append("停止扫描，共看到 \(devices.count) 个设备")
    }

    /// 把整段日志塞进剪贴板。
    /// 为什么要这个：日志要发给电脑端分析，截图会有识别误差，
    /// 而帧的十六进制差一个字符就全错，所以必须走原文。
    func copyLog() {
        UIPasteboard.general.string = log.joined(separator: "\n")
        append("已把 \(log.count) 行日志复制到剪贴板")
    }

    /// 清空内存日志 + 磁盘日志。"新一轮排查前点一下"，
    /// 否则上一场的 AUDIO/STATE 残留会把这一场的现象带偏（22:47 那场就吃这个亏）。
    func clearLog() {
        log.removeAll()
        try? FileManager.default.removeItem(at: GO3Central.logFileURL)
        append("日志已清空（内存 + 磁盘）")
    }

    // MARK: - 发送初始化（P3 核心）

    /// 一帧可能要拆成多段写：BLE 单次写入受 MTU 限制（iOS 上 writeNR 通常 182B，
    /// withResponse 可能到 512B），而官方初始化序列里最长的一条是 283 字节。
    /// 官方 App 当年必然也是分段发出去的，所以这里照样逐段发。
    private struct PendingWrite {
        let data: Data
        let ch: CBCharacteristic
        let label: String
        /// 心跳类高频帧不打逐条日志，否则一秒一行把有用的信息全冲走。
        var quiet: Bool = false
    }

    private var queue: [PendingWrite] = []
    /// withResponse 的写正在等回执，此时不能再发下一段。
    private var writing = false

    private func maxWriteLength(_ ch: CBCharacteristic) -> Int {
        guard let p = connectedPeripheral else { return 20 }
        let nr = !useWriteResponse && ch.properties.contains(.writeWithoutResponse)
        return max(20, p.maximumWriteValueLength(for: nr ? .withoutResponse : .withResponse))
    }

    /// 排队一次写。分包已经在 `sendPayload` 里按协议做完了，这里不再切字节——
    /// 把一条逻辑帧随便切片会破坏它自己的长度字段和 CRC。
    private func enqueue(_ data: Data, ch: CBCharacteristic, label: String, quiet: Bool = false) {
        queue.append(PendingWrite(data: data, ch: ch, label: label, quiet: quiet))
        pump()
    }

    /// 帧号。官方 App 每条逻辑消息一个帧号，多个分包共用同一个。
    private var seqCounter: UInt8 = 1

    private func nextSeq() -> UInt8 {
        let s = seqCounter
        seqCounter = seqCounter &+ 1
        if seqCounter == 0 { seqCounter = 1 }
        return s
    }

    /// 把一条 protobuf 消息发出去：按 MTU 算单包 payload 上限，切成 1..N 个包。
    private func sendPayload(_ payload: [UInt8], ch: CBCharacteristic, label: String,
                             quiet: Bool = false) {
        // 单包上限强制卡到 230B（总长 244B）——这是官方 App 的实际上限
        // （Android MTU 247 − 3 = 244）。iOS 报 509B，但 281B 那种一次写进去
        // 直接把连接写断了（22:31 实测："The connection has timed out unexpectedly"）。
        // 固件的接收缓冲显然是按 244B 设计的，不要拿我们的 MTU 去赌它。
        let perPacket = max(16, min(maxWriteLength(ch) - 14, 230))
        let seq = nextSeq()
        let parts = GO3Frame.packets(seq: seq, payload: payload, maxPayload: perPacket)
        for (i, pkt) in parts.enumerated() {
            let tag = parts.count > 1 ? "\(label) 包\(i + 1)/\(parts.count)" : label
            enqueue(pkt, ch: ch, label: "\(tag) seq=\(seq) \(payload.count)B", quiet: quiet)
        }
    }

    /// 投递自检：发官方的「亮度」命令。
    /// 为什么挑它：效果立刻可见、无害可逆，而且这条帧结构是从真实抓包里扒出来的：
    ///   `command{ brightness{ brightness:30 } type:BRIGHTNESS_CTRL }`
    ///   payload = 10 0b | 72 08 | 08 01 | 1a 04 | 08 01 | 28 06
    /// 其中 `28 <level>` 就是亮度值，实测 30% 对应 6，所以是 0~10 档。
    /// 上一版固定发 30（level 6）有个坑：眼镜本来就接近这个亮度时，看不出来。
    func sendBrightnessTest() {
        sendBrightness(level: 1)
    }

    func sendBrightness(level: Int) {
        guard let ch = targetChannel else {
            append("还没连上眼镜，先连接")
            return
        }
        let lv = UInt8(max(0, min(10, level)))
        append("→ 亮度设为 \(lv) 档（约 \(lv * 5)%）")
        sendPayload([0x10, 0x0B, 0x72, 0x08, 0x08, 0x01, 0x1A, 0x04, 0x08, 0x01, 0x28, lv],
                    ch: ch, label: "CONTROL_COMMAND 亮度\(lv)")
        observeAfterCommand()
        scheduleRelease(seconds: releaseAfter, reason: "亮度命令已发完")
    }

    /// 发完命令后看眼镜有没有动静。这是判断"写到底有没有被消费"最直接的办法：
    /// 如果 3 秒内收到帧数一点没涨，很可能是命令被丢在 BLE 通道上没人处理。
    private func observeAfterCommand() {
        let before = rxCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            self.append("  ▸ 命令发出后 3 秒：新收到 \(self.rxCount - before) 帧")
        }
    }

    // MARK: - 音频流与会记（会记到底卡在哪）

    /// 音频帧不进逐帧日志 —— 一秒十几帧，会把有用的东西全冲走。
    /// 只更新计数，并每秒最多打一行汇总。
    private func noteAudioFrame(bytes: Int) {
        audioFrames += 1
        audioBytes += bytes
        audioWindowFrames += 1

        let now = Date()
        let dt = now.timeIntervalSince(audioWindowStart)
        guard dt >= 1.0 else { return }
        audioFPS = Double(audioWindowFrames) / dt
        audioWindowFrames = 0
        audioWindowStart = now

        if now.timeIntervalSince(lastAudioLog) >= 1.0 {
            lastAudioLog = now
            append(String(format: "  ♪ 音频累计 %d 帧 · %.1f KB · %.0f 帧/秒（眼镜在采音，等我们解码）",
                          audioFrames, Double(audioBytes) / 1024.0, audioFPS))
        }
    }

    /// 处理一条会记消息。
    ///
    /// 最要紧的一步：眼镜发来 `SAGENOTE_COMMAND` 后**必须回 `COMMAND_ACK`**。
    /// 官方 `SagenoteProbufProcessManager.sendAck()` 就是逐字这么构造的。
    /// 不回，眼镜就一直在等，屏幕上那个计时不会动。
    private func handleSagenote(_ s: SagenoteIn) {
        lastSagenote = s.summary
        if !s.sessionId.isEmpty { lastSessionId = s.sessionId }
        append("  ◆ \(s.summary)")

        guard s.msgType == SagenoteMsg.command.rawValue, let cmd = s.cmd else { return }

        // 先按命令切换「每秒心跳」的开关，再管 ACK。
        // 顺序有讲究：眼镜重发同一条命令时 ACK 会被去重挡掉，但心跳不能因此漏开。
        applyCommandEffect(cmd, sessionId: s.sessionId)

        if s.commandId == lastAckedCommandId {
            append("     （同一 commandId 已回过 ACK，按官方做法去重）")
            return
        }
        guard let ch = targetChannel else {
            append("     （还没连上，ACK 发不出去）")
            return
        }

        lastAckedCommandId = s.commandId
        let payload = SagenoteOut.commandAck(commandId: s.commandId,
                                             sessionId: s.sessionId,
                                             cmd: cmd, ok: true)
        append("  → 回 COMMAND_ACK：cmd=\(cmd)(\(SagenoteCmd(rawValue: cmd)?.name ?? "?")) ok=1 session=\(s.sessionIdStr)")
        sendPayload(payload, ch: ch, label: "SAGENOTE COMMAND_ACK")
    }

    /// 手机主动下发会记命令（试验性）。
    ///
    /// 用途：给上一场没收尾的会话补一刀 STOP，或者试着自己开一场。
    /// 22:47 那场就是因为上一场没停、眼镜连着旧会话，
    /// 一进会记就显示 23 分钟（会话 id 里的毫秒戳 = 22:24:22）。
    func sendSagenoteCommand(_ cmd: SagenoteCmd) {
        guard let ch = targetChannel else {
            append("还没连上眼镜，命令发不出去")
            return
        }
        let sid = activeSessionId.isEmpty ? lastSessionId : activeSessionId
        guard !sid.isEmpty else {
            append("没有会话 id。先在眼镜上打开一次「会记」，让眼镜把 session 报上来，再发命令。")
            return
        }
        let cid = "p\(Int(Date().timeIntervalSince1970 * 1000))"
        let payload = SagenoteOut.command(cmd: cmd.rawValue, sessionId: sid, commandId: cid)
        append("  → 下发会记命令 \(cmd.name)（session=\(String(decoding: sid, as: UTF8.self))，commandId=\(cid)）")
        append("     ※ 这条是按 ACK 结构推定的，官方发送样本里没有 COMMAND，看眼镜屏幕反应")
        sendPayload(payload, ch: ch, label: "SAGENOTE COMMAND \(cmd.name)")
    }

    private func applyCommandEffect(_ cmd: Int, sessionId: [UInt8]) {
        switch SagenoteCmd(rawValue: cmd) {
        case .start, .notifyStarted, .resume:
            startStateTicker(sessionId: sessionId)
        case .stop, .notifyStopped, .pause:
            stopStateTicker()
        default:
            break
        }
    }

    // MARK: - 每秒状态心跳（眼镜屏幕上的计时就是它驱动的）

    @Published private(set) var stateTicks = 0
    @Published private(set) var tickerRunning = false

    private var stateTimer: Timer?
    private var stateSeq = 0
    private var activeSessionId: [UInt8] = []

    /// 官方抓包里手机每秒发一条 `SAGENOTE_STATE`，序号递增（01→02→03…）。
    /// 停掉它就等于告诉眼镜"采集停了"，屏幕上的时长会停住。
    func startStateTicker(sessionId: [UInt8]) {
        if tickerRunning, sessionId == activeSessionId { return }
        stopStateTicker()

        activeSessionId = sessionId
        stateSeq = 0
        stateTicks = 0
        sessionStart = Date()
        tickerRunning = true
        append("  ⏱ 开始每秒状态心跳（session=\(String(decoding: sessionId, as: UTF8.self))）—— 眼镜屏幕上的计时靠它推进")

        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        stateTimer = t
        tick()   // 立刻发第一条，别让屏幕空等 1 秒
    }

    func stopStateTicker() {
        stateTimer?.invalidate()
        stateTimer = nil
        if tickerRunning {
            append("  ⏱ 停止状态心跳（共 \(stateTicks) 条）")
        }
        tickerRunning = false
    }

    private func tick() {
        guard let ch = targetChannel else { return }
        stateSeq += 1
        stateTicks += 1
        let payload = SagenoteOut.state(sessionId: activeSessionId, seq: stateSeq)
        // 每秒一条，全打日志会刷屏：前 3 条留痕，之后静默，靠界面上的计数看。
        if stateTicks <= 3 {
            append("  ⏱ 状态 #\(stateSeq)")
        }
        sendPayload(payload, ch: ch, label: "SAGENOTE STATE #\(stateSeq)",
                    quiet: stateTicks > 3)
    }

    // MARK: - 手动注入识别结果（验证回传通道用）

    private var asrSegmentId = 0
    private var sessionStart = Date()

    /// 把一段文字当成 ASR 结果发给眼镜。
    /// 用途：此刻我们还没有真正的语音识别，但可以先验证"手机→眼镜的文字回传通道"通不通。
    /// 眼镜屏幕上出现了这段字，就说明缺的只剩识别本身，而不是协议。
    func injectAsr(_ text: String) {
        guard let ch = targetChannel else {
            append("还没连上眼镜，先连接")
            return
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // 会话 id 优先用活动会话；没有就退回"眼镜最近报上来的那个"。
        // 22:47 那场因为没收到 START，activeSessionId 一直是空，
        // 注入按钮直接报"还没有活动的会记会话"，连通道都没法验。
        let sid = activeSessionId.isEmpty ? lastSessionId : activeSessionId
        guard !sid.isEmpty else {
            append("还没有会话 id。先在眼镜上打开一次「会记」，让眼镜把 session 报上来。")
            return
        }
        asrSegmentId += 1
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let begin = now - sessionStartMs()

        let payload = SagenoteOut.asr(sessionId: sid, text: t,
                                      segmentId: asrSegmentId,
                                      beginMs: begin, endMs: now)
        append("  → 注入识别结果：「\(t)」")
        sendPayload(payload, ch: ch, label: "SAGENOTE ASR")
    }

    private func sessionStartMs() -> Int {
        Int(Date().timeIntervalSince(sessionStart) * 1000)
    }

    // MARK: - 定时断开（调试用）

    /// 排一个「到点自动断开」的定时器。
    /// **默认不启用**。启用后眼镜会在到点时看到"蓝牙已断开"，
    /// 23:29 那次就是它在用户刚要打开「会记」时把连接掐了，属于自伤。
    /// 只在做长连接泄漏/重连测试时才打开。
    func scheduleRelease(seconds: Double, reason: String) {
        guard autoRelease else {
            append("  （定时断开未启用：连接会一直保持）")
            return
        }
        releaseWork?.cancel()
        let secs = max(2, seconds)
        append("  ⏳ [调试] \(Int(secs)) 秒后主动断开（\(reason)）")
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.append("  ⏳ [调试] 到点主动断开 —— 眼镜屏幕上会显示蓝牙断开，这是预期内的")
            self.disconnect()
        }
        releaseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: w)
    }

    /// 立刻断开。做重连测试或换设备时用。
    func releaseNow() {
        releaseWork?.cancel()
        releaseWork = nil
        append("→ 手动断开连接")
        disconnect()
    }

    private var targetChannel: CBCharacteristic? {
        useRW2021 ? rwChar2021 : writeChar1001
    }

    // MARK: - 绑定（整个流程的闸门）

    /// 绑定用的账号 id。官方取的是 `AccountInfo.userInfo.id`（安卓那个账号）。
    /// 眼镜侧记的 boundUserId 要和它对上，所以保留原值 "52673"；
    /// 如果眼镜说"已被其他账号绑定"，就在界面上改这里。
    @Published var userAccount = "52673"

    private enum Stage {
        case idle
        /// 已发绑定、等眼镜回 BIND_STATUS_RESPONSE
        case waitingBind
        /// 绑定成功，等 5 秒（官方 `postDelayed(..., 5000)`）
        case waitingInit
        case runningInit
    }

    private var stage: Stage = .idle

    /// 造一条 `BLE_CONNECT_BIND`：
    /// `Message{ f2=24, f27 = BleConnectBind{ f1=kind, f2=userAccount } }`。
    /// kind = 2 是 BIND_USERDATA（首次绑定），kind = 1 是 BACK_LINK（回连）。
    /// 官方 `sendBindConnectProtocol()` 就是按「本地有没有这台设备的记录」二选一，
    /// 我们第一次连的时候本地当然没有记录 —— 所以要用 2。
    private func bindPayload(kind: UInt8) -> [UInt8] {
        var acc = Array(userAccount.utf8)
        if acc.count > 100 { acc = Array(acc.prefix(100)) }
        var inner: [UInt8] = [0x08, kind, 0x12, UInt8(acc.count & 0xFF)]
        inner.append(contentsOf: acc)
        var out: [UInt8] = [0x10, 0x18, 0xDA, 0x01]
        // varint 长度
        var n = inner.count
        while n >= 0x80 {
            out.append(UInt8((n & 0x7F) | 0x80))
            n >>= 7
        }
        out.append(UInt8(n))
        out.append(contentsOf: inner)
        return out
    }

    /// 手动发绑定。kind: 2 = 首次绑定（BIND_USERDATA），1 = 回连（BACK_LINK）。
    ///
    /// `autoFallback` 默认 true：眼镜重启后绑定状态其实还在，这时官方会发 BACK_LINK(1)，
    /// 而我们固定发 BIND_USERDATA(2) 可能被冷处理。所以发完等不到 `isBound=1`
    /// 就自动补一发 kind=1，最多来回一次，避免死循环。
    func sendBind(kind: UInt8, autoFallback: Bool = true) {
        guard let ch = targetChannel else {
            append("还没连上眼镜，先连接")
            return
        }
        bindIsQuery = (kind == 0)
        let name = kind == 2 ? "BIND_USERDATA(2) 首次绑定"
                 : kind == 1 ? "BACK_LINK(1) 回连"
                 : "QUERY(0) 查询绑定状态"
        append("→ 发绑定：\(name)，userAccount=\"\(userAccount)\"")
        sendPayload(bindPayload(kind: kind), ch: ch, label: "BLE_CONNECT_BIND \(name)")
        stage = .waitingBind
        bindTries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, self.stage == .waitingBind else { return }
            self.stage = .idle
            if self.bindIsQuery {
                self.bindIsQuery = false
                self.append("6 秒内没等到查询回包。眼镜可能不支持 kind=0，直接点「首次绑定」即可。")
                return
            }
            if autoFallback, self.bindTries < 2 {
                self.append("6 秒内没等到绑定响应。改发一条「回连」试试（眼镜保留着上次的绑定）")
                self.sendBind(kind: kind == 2 ? 1 : 2, autoFallback: false)
                return
            }
            self.append("6 秒内没等到绑定响应。眼镜可能直接忽略了这条绑定。")
        }
    }

    /// 一次连接内最多试几次绑定，防止两种 kind 互相触发无限循环。
    private var bindTries = 0
    /// 当前这条绑定是不是「查状态」，是的话回包只报状态、不驱动握手。
    private var bindIsQuery = false

    // MARK: - 上报 App 版本（「APP 版本过低」的唯一解药）

    /// 上报给眼镜的 App 版本号。
    /// 默认 `3.0.455` —— 这是官方 App 抓包时真实发出的值（`app_init_wire.json` 第 4 步，
    /// 原文 `3a 0b 0a 07 33 2e 30 2e 34 35 35` → "3.0.455"）。
    /// 眼镜固件是 `Go3_DC_V3.0.406`，如果 3.0.455 仍被判过低，就往上调（如 3.0.500）。
    @Published var phoneVersion = "3.0.455"

    /// 造一条 `BLE_CONNECT_BIND{ kind=7(PHONE_INFO), f7=PhoneInfo{ f1=version, f2=1 } }`。
    /// 逐字节对齐官方抓包：
    ///   `10 18 | da 01 0f | 08 07 | 3a 0b | 0a 07 "3.0.455" | 10 01`
    /// 其中 f2=1 的含义没查清（可能是平台或 App 类型），照抄抓包值不动。
    private func phoneInfoPayload(version: String) -> [UInt8] {
        var v = Array(version.utf8)
        if v.count > 40 { v = Array(v.prefix(40)) }

        var pi: [UInt8] = [0x0A, UInt8(v.count & 0xFF)]
        pi.append(contentsOf: v)
        pi.append(contentsOf: [0x10, 0x01])

        var inner: [UInt8] = [0x08, 0x07, 0x3A, UInt8(pi.count & 0xFF)]
        inner.append(contentsOf: pi)

        var out: [UInt8] = [0x10, 0x18, 0xDA, 0x01]   // f2=24(msgType) + f27 起始
        var n = inner.count
        while n >= 0x80 {                              // varint 长度
            out.append(UInt8((n & 0x7F) | 0x80))
            n >>= 7
        }
        out.append(UInt8(n))
        out.append(contentsOf: inner)
        return out
    }

    /// 单独补发一条版本上报。绑定成功后、或者眼镜已经在抱怨版本过低时都能用。
    func sendPhoneInfo() {
        guard let ch = targetChannel else {
            append("还没连上眼镜，先连接")
            return
        }
        let p = phoneInfoPayload(version: phoneVersion)
        append("→ 上报 App 版本：\(phoneVersion)（眼镜就是靠这条判断「APP 版本过低」）")
        sendPayload(p, ch: ch, label: "BLE_CONNECT_BIND PHONE_INFO v\(phoneVersion)")
    }

    /// 完整流程，严格按官方顺序：
    /// 发 BIND_USERDATA → 等 BIND_STATUS_RESPONSE → isBound=1 → 等 5 秒 → 发 21 步。
    /// 绑定失败就停，不再往下发——22:31 那次就是在未绑定状态硬推初始化，
    /// 结果眼镜回 UNBIND 并断开，屏幕上显示"连接失败"。
    ///
    /// 不再自动补一枪亮度：那会改屏幕显示，干扰「去眼镜菜单打开会记」的判断。
    /// 亮度仍是手动按钮，要验投递时再点。
    func runOfficialFlow() {
        guard connectedPeripheral?.state == .connected, targetChannel != nil else {
            append("一键流程要先连上眼镜")
            return
        }
        testAfterInit = false
        append("—— 一键流程开始 ——")
        sendBind(kind: 2)
    }

    /// 处理眼镜回的绑定消息。照抄官方 `BleProtocolManager` 的分支：
    /// isBound=1 → `postDelayed(5000)` 后才跑初始化；isBound=0 → 它自己调 disconnect()。
    private func handleBindReport(_ rep: BindReport) {
        switch rep.msgType {
        case 3: // BIND_STATUS_RESPONSE
            if rep.isBound {
                bindTries = 0
                // 查询（kind=0）的回包只报告状态，不触发握手，否则点一下「查一下」就会
                // 莫名其妙开始发 21 步，容易把人搞懵。
                if bindIsQuery {
                    bindIsQuery = false
                    stage = .idle
                    append("  → 查询结果：这台眼镜已绑在账号 \(rep.boundUserId) 上。")
                    append("  → 不需要重新绑定，直接点「一键流程」或「发全部 \(InitSequence.steps.count) 步」即可。")
                    return
                }
                append("  → 绑定成功。")
                guard stage == .waitingBind else {
                    stage = .idle
                    return
                }
                stage = .waitingInit
                if runInitAfterBind {
                    append("  → 按官方时序等 5 秒再发 21 步（第 1 步的绑定我们刚发过，会跳过）")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self = self, self.stage == .waitingInit else { return }
                        self.append("  → 5 秒到，开始发初始化")
                        self.sendInit(firstOnly: false, skipFirstBind: true)
                    }
                } else {
                    append("  → 不跑 21 步，只补一条 PHONE_INFO 上报版本 \(phoneVersion)")
                    append("  → 注意：只发版本号是「最小修复」，眼镜要的其他能力（语言表/模块声明）还是缺，能进界面不等于能用")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self = self, self.stage == .waitingInit else { return }
                        self.sendPhoneInfo()
                        self.stage = .idle
                        self.append("  → 完成。现在去眼镜菜单选「会记」，看还报不报「APP 版本过低」。")
                    }
                }
            } else {
                if bindIsQuery {
                    bindIsQuery = false
                    stage = .idle
                    append("  → 查询结果：这台眼镜当前没有绑定（\(rep.hint)）。")
                    append("  → 点「首次绑定」建立绑定。")
                    return
                }
                append("  → 绑定未通过：\(rep.hint)")
                append("  → 先别发初始化。官方在未绑定状态下会直接断开，硬发只会把连接搞崩。")
                if stage == .waitingBind { stage = .idle }
                testAfterInit = false
                // errorCode=3 常见于「眼镜还留着旧绑定、等的是回连」这种情形，
                // 换一种 kind 再试一次，别让用户来回点。
                if bindTries < 2, rep.errorCode == 3 {
                    append("  → 改发一条「回连」再试一次")
                    sendBind(kind: 1, autoFallback: false)
                }
            }
        case 6: // UNBIND
            append("  → 眼镜发来 UNBIND（解绑/未授权），需要重新绑定。")
            if stage == .waitingBind { stage = .idle }
        default:
            break
        }
    }

    /// 一次只发一段。无响应写没有回调，靠 20ms 让出主线程再发下一段；
    /// 有响应写则等 didWriteValueFor 把 writing 放开。
    private func pump() {
        guard !writing,
              let p = connectedPeripheral, p.state == .connected,
              !queue.isEmpty else { return }

        let item = queue[0]
        let nr = !useWriteResponse && item.ch.properties.contains(.writeWithoutResponse)
        // 无响应写有流控：上一段还没被控制器吐出去就硬塞会被静默丢弃。
        if nr && !p.canSendWriteWithoutResponse { return }

        queue.removeFirst()
        p.writeValue(item.data, for: item.ch, type: nr ? .withoutResponse : .withResponse)
        if !item.quiet {
            append("→ \(short(item.ch.uuid))  \(item.data.count)B  \(item.label)")
            if item.data.count <= 64 {
                append("       \(hex(item.data))")
            } else {
                append("       \(hex(item.data.prefix(10)))…（共 \(item.data.count)B）")
            }
        }

        if nr {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.pump()
            }
        } else {
            writing = true
        }
    }

    /// firstOnly = true 时只发第 1 步（BLE_CONNECT_BIND）。
    /// skipFirstBind = true 时把第 1 步剔掉 —— 一键流程里我们已经单独发过绑定，
    /// 再发一遍只会让眼镜回两次 BIND_STATUS_RESPONSE，纯噪音。
    func sendInit(firstOnly: Bool, skipFirstBind: Bool = false) {
        guard let p = connectedPeripheral, p.state == .connected else {
            append("还没连上眼镜，先连接再发")
            return
        }
        let target = useRW2021 ? rwChar2021 : writeChar1001
        guard let ch = target else {
            append(useRW2021 ? "没找到 2021 特征" : "没找到 1001 特征")
            return
        }
        guard !initRunning else {
            append("上一轮还没发完")
            return
        }

        var list = firstOnly ? Array(InitSequence.steps.prefix(1)) : InitSequence.steps
        if skipFirstBind { list = list.filter { $0.idx != 1 } }
        append("开始发送初始化：\(list.count) 步，通道 \(short(ch.uuid))，单次写入上限 \(maxWriteLength(ch))B")
        append("  信封：type=0x00 src=3 dst=1，\(keepVersionPrefix ? "带" : "不带") 08 01 版本前缀")
        if !firstOnly {
            append("已跳过第 \(InitSequence.skippedIdx) 步（原始数据标了含猜测字段）")
        }
        initRunning = true
        stage = .runningInit
        sendStep(list, 0, ch, 0)
    }

    /// `wait` 是"这一帧因为流控被挡住"的重试计数，防止死等。
    private func sendStep(_ list: [InitStep], _ i: Int, _ ch: CBCharacteristic, _ wait: Int) {
        // 中途断连就把循环停掉，否则会在断连后继续空转、最后还误报"发送完毕"。
        guard let p = connectedPeripheral, p.state == .connected else {
            initRunning = false
            queue.removeAll()
            writing = false
            stage = .idle
            append("连接已断，初始化中止（已排到第 \(i)/\(list.count) 步）")
            return
        }
        guard i < list.count else {
            // 队列还没吐完就再等一会儿，别提前报完成。
            // wait 在这里被复用作"等待轮数"，上限 150×200ms=30s，超时就认账收工，
            // 免得某一个回执丢了就把界面卡在"发送中"永远不退。
            guard queue.isEmpty && !writing else {
                if wait >= 150 {
                    initRunning = false
                    writing = false
                    append("还有 \(queue.count) 段没发出去，超时收工（可能是写回执丢了）")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.sendStep(list, i, ch, wait + 1)
                }
                return
            }
            initRunning = false
            stage = .idle
            append("初始化发送完毕（\(list.count) 步）")
            append("  ✔ 里面已包含 PHONE_INFO v\(phoneVersion)，眼镜现在应该认为对端是正版 App 了")
            append("  → 现在去**眼镜菜单里选「会记」**，看还报不报「APP 版本过低无法打开」。")
            append("  → 连接会一直保持，不会自己断（定时断开默认关着）。")
            if testAfterInit {
                testAfterInit = false
                append("2 秒后自动发亮度自检——这次是在绑定之后发的，意义完全不同")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.sendBrightnessTest()
                }
            }
            return
        }

        if !p.canSendWriteWithoutResponse, wait < 60,
           ch.properties.contains(.writeWithoutResponse) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.sendStep(list, i, ch, wait + 1)
            }
            return
        }

        let s = list[i]
        let cleanName = s.name.replacingOccurrences(of: " {", with: "")
        if let payload = GO3Frame.payloadFromRecorded(s.hex, stripVersion: !keepVersionPrefix) {
            sendPayload(payload, ch: ch, label: "init#\(s.idx) \(cleanName)")
        } else {
            append("init#\(s.idx) 的 hex 解析失败，跳过")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.sendStep(list, i + 1, ch, 0)
        }
    }

    func connect(_ d: BleDevice) {
        guard let p = found[d.id] else {
            append("拿不到外设对象，重新扫一次")
            return
        }
        append("连接 \(d.name.isEmpty ? "(无名)" : d.name) …")
        central.stopScan()
        scanning = false
        central.connect(p, options: nil)
    }

    func disconnect() {
        releaseWork?.cancel()
        releaseWork = nil
        if let p = connectedPeripheral {
            central.cancelPeripheralConnection(p)
            return
        }
        for (_, p) in found where p.state == .connected {
            central.cancelPeripheralConnection(p)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension GO3Central: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        managerState = central.state
        append("蓝牙状态：\(stateText)")
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? ""

        var advServices: [CBUUID] = []
        if let list = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            advServices = list
        }

        // 只要名字里有 INMO，或者广播里带了 GO3 的那两条厂商服务，
        // 就当它是目标设备。两个条件任一命中即可 —— 只按名字过滤太脆，
        // 眼镜的广播名不一定带 INMO。
        let upper = name.uppercased()
        let isGO3 = upper.contains("INMO")
            || upper.contains("GO3")
            || advServices.contains(GO3UUID.svc7033)
            || advServices.contains(GO3UUID.svc2020)

        found[peripheral.identifier] = peripheral

        let rssi = RSSI.intValue
        let item = BleDevice(id: peripheral.identifier, name: name, rssi: rssi, isGO3: isGO3)

        if let idx = devices.firstIndex(where: { $0.id == item.id }) {
            devices[idx] = item
        } else {
            devices.append(item)
            var detail = "发现 \(name.isEmpty ? "(无名)" : name)  rssi=\(rssi)"
            if !advServices.isEmpty {
                detail += "  服务广播=\(advServices.map { $0.uuidString }.joined(separator: ","))"
            }
            append(detail)
        }

        // GO3 排前面，其余按信号强度
        devices.sort { a, b in
            if a.isGO3 != b.isGO3 { return a.isGO3 }
            return a.rssi > b.rssi
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        connectedName = peripheral.name ?? peripheral.identifier.uuidString
        experimentHintShown = false
        bindTries = 0
        audioFrames = 0
        audioBytes = 0
        audioFPS = 0
        audioWindowFrames = 0
        audioWindowStart = Date()
        lastAudioLog = Date.distantPast
        audioFirstFrameLogged = false
        lastAckedCommandId = []
        lastSagenote = "（还没收到会记消息）"
        append("已连接 \(connectedName ?? "")，开始枚举服务")
        // 把包构造器和官方真实捕获的那条帧逐字节比一次。
        // 这行如果显示"不一致"，后面发什么都白费，先修构造器。
        append("包构造器自检：\(GO3Frame.builderSelfTest())")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        append("连接失败：\(error?.localizedDescription ?? "未知原因")")
        connectedName = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        append("连接断开：\(error?.localizedDescription ?? "对端主动断开")")
        connectedName = nil
        connectedPeripheral = nil
        writeChar1001 = nil
        rwChar2021 = nil
        initRunning = false
        queue.removeAll()
        writing = false
        seqCounter = 1
        testAfterInit = false
        stage = .idle
        bindTries = 0
        bindIsQuery = false
        stopStateTicker()
        activeSessionId = []
        lastAckedCommandId = []
        releaseWork?.cancel()
        releaseWork = nil
        append("  连接已断。如果不是你手动断的，重点看断之前最后几帧眼镜发了什么。")
    }
}

// MARK: - CBPeripheralDelegate

extension GO3Central: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            append("枚举服务出错：\(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        append("发现 \(services.count) 个服务")
        for s in services {
            append("  服务 \(short(s.uuid))")
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            append("  枚举特征出错：\(error.localizedDescription)")
            return
        }
        for c in service.characteristics ?? [] {
            append("    特征 \(short(c.uuid))  [\(props(c.properties))]")

            if c.uuid == GO3UUID.write1001 { writeChar1001 = c }
            if c.uuid == GO3UUID.rw2021 {
                rwChar2021 = c
                // 这个数字直接决定 283 字节的长帧要不要拆段，先打出来,
                // 免得后面靠猜。
                let nr = peripheral.maximumWriteValueLength(for: .withoutResponse)
                let wr = peripheral.maximumWriteValueLength(for: .withResponse)
                append("      单次写入上限：writeNR \(nr)B / write \(wr)B")
            }

            // 订阅通知：只读，不会改变眼镜状态。安卓那边靠这条拿 60 秒心跳。
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
                append("      已订阅通知")
            }

            // 2021 是唯一可读的那个，零风险，先读出来看看当前值。
            if c.properties.contains(.read) {
                let tag = (c.uuid == GO3UUID.rw2021) ? "（读写口 2021）" : ""
                append("      读一次当前值\(tag)")
                peripheral.readValue(for: c)
            }
        }

        // 连上之后给一段"正确顺序"的提示。
        // 23:29 那次就是顺序错了（跳过 21 步 → 缺 PHONE_INFO → 眼镜报「APP 版本过低」），
        // 所以这里直接把正确顺序写在日志里，不用记。
        if !experimentHintShown, (rwChar2021 != nil || writeChar1001 != nil) {
            experimentHintShown = true
            append("──── 正确顺序（绑定由我们这个 App 完成，官方 App 不参与）────")
            append("① 点「首次绑定」，等日志出现 isBound=1")
            append("② 它会自动等 5 秒，然后发 \(InitSequence.steps.count) 步握手（含 PHONE_INFO v\(phoneVersion)）")
            append("③ 去**眼镜菜单**选「会记」")
            append("④ 连接会一直保持。若还报「APP 版本过低」，把版本号调高再单独点「补发版本」")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            append("  ← \(short(characteristic.uuid)) 读取出错：\(error.localizedDescription)")
            return
        }
        guard let d = characteristic.value else { return }
        rxCount += 1

        // 能按 aa55 帧解出来就解，解不出来就老实打 hex —— 不猜。
        if let f = GO3Frame.parse(d) {
            let env = GO3Envelope.decode(f.payload)

            // ① 音频帧：一秒十几帧，绝不能逐帧打日志。只计数 + 每秒一行汇总。
            //    22:24 的日志里 248 帧有 235 帧是这个，等于眼镜一直在把麦克风数据推给我们。
            if env.msgType == 0 {
                // 首帧单独留一份原文：AudioConfig 里的采样率/声道/码率/型号只能这样确认。
                // 22:47 那场一帧音频都没有，光看计数"是 0"说明不了是没采到还是没记到。
                if !audioFirstFrameLogged {
                    audioFirstFrameLogged = true
                    append("  ♪ 首帧音频 \(env.inner.count)B  \(audioConfigText(env.inner))")
                    append("       \(hex(Data(f.payload)))")
                }
                noteAudioFrame(bytes: env.inner.count)
                return
            }

            // ② 会记：解成人话，并对 COMMAND 回 ACK（这是官方唯一要求的应答）。
            //    注意这里**要把原文也打出来**：22:47 那场只打了人话，导致事后无法
            //    核对眼镜到底发了哪几个字段（出现过 typeName 显示"未知(10)"却查不下去）。
            if env.msgType == 43 {
                if let s = SagenoteIn.decode(f.payload) {
                    append("  ← \(short(characteristic.uuid))  \(f.summary)")
                    append("       \(hex(d))")
                    handleSagenote(s)
                } else {
                    append("  ← \(short(characteristic.uuid))  会记帧解不出（f46 缺失或截断）")
                    append("       \(hex(d))")
                }
                return
            }

            var line = "  ← \(short(characteristic.uuid))  \(f.summary)"
            if let pb = f.pbBrief {
                line += "  \(pb)"
            }
            append(line)
            append("       \(hex(d))")

            // ③ 绑定消息单独解成人话，并驱动流程往下走。
            if let rep = BindReport.decode(f.payload) {
                append("  ★ \(rep.summary)")
                if rep.msgType == 6 {
                    append("  ⚠ 眼镜发来 UNBIND（解绑请求）。我**没有**自动回 UNBIND_RESPONSE ——")
                    append("     回了就等于确认解绑，绑定状态可能被清掉，这个要你决定。")
                }
                handleBindReport(rep)
            }
        } else {
            append("  ← \(short(characteristic.uuid))  \(d.count)B  \(hex(d))")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            append("  订阅失败 \(short(characteristic.uuid))：\(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // 只报错，成功不刷屏 —— 21 步初始化会打出 21 行噪音，反而把异常淹了。
        if let error = error {
            append("  写入失败 \(short(characteristic.uuid))：\(error.localizedDescription)")
        }
        // 有响应写走的是"发一段等一段"，回执到了才放下一段。
        writing = false
        pump()
    }

    /// 无响应写被流控挡住时，系统在这里告诉我们"可以继续了"。
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump()
    }
}
