import Foundation
import CoreBluetooth
import UIKit

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

    private func append(_ s: String) {
        let line = GO3Central.stamp.string(from: Date()) + "  " + s
        print(line)
        log.append(line)
        if log.count > 500 {
            log.removeFirst(log.count - 500)
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

    // MARK: - 发送初始化（P3 核心）

    /// 一帧可能要拆成多段写：BLE 单次写入受 MTU 限制（iOS 上 writeNR 通常 182B，
    /// withResponse 可能到 512B），而官方初始化序列里最长的一条是 283 字节。
    /// 官方 App 当年必然也是分段发出去的，所以这里照样逐段发。
    private struct PendingWrite {
        let data: Data
        let ch: CBCharacteristic
        let label: String
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
    private func enqueue(_ data: Data, ch: CBCharacteristic, label: String) {
        queue.append(PendingWrite(data: data, ch: ch, label: label))
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
    private func sendPayload(_ payload: [UInt8], ch: CBCharacteristic, label: String) {
        // 单包上限强制卡到 230B（总长 244B）——这是官方 App 的实际上限
        // （Android MTU 247 − 3 = 244）。iOS 报 509B，但 281B 那种一次写进去
        // 直接把连接写断了（22:31 实测："The connection has timed out unexpectedly"）。
        // 固件的接收缓冲显然是按 244B 设计的，不要拿我们的 MTU 去赌它。
        let perPacket = max(16, min(maxWriteLength(ch) - 14, 230))
        let seq = nextSeq()
        let parts = GO3Frame.packets(seq: seq, payload: payload, maxPayload: perPacket)
        for (i, pkt) in parts.enumerated() {
            let tag = parts.count > 1 ? "\(label) 包\(i + 1)/\(parts.count)" : label
            enqueue(pkt, ch: ch, label: "\(tag) seq=\(seq) \(payload.count)B")
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
    func sendBind(kind: UInt8) {
        guard let ch = targetChannel else {
            append("还没连上眼镜，先连接")
            return
        }
        let name = kind == 2 ? "BIND_USERDATA(2) 首次绑定" : "BACK_LINK(1) 回连"
        append("→ 发绑定：\(name)，userAccount=\"\(userAccount)\"")
        sendPayload(bindPayload(kind: kind), ch: ch, label: "BLE_CONNECT_BIND \(name)")
        stage = .waitingBind
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, self.stage == .waitingBind else { return }
            self.stage = .idle
            self.append("6 秒内没等到绑定响应。眼镜可能直接忽略了这条绑定。")
        }
    }

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
                append("  → 绑定未通过：\(rep.hint)")
                append("  → 先别发初始化。官方在未绑定状态下会直接断开，硬发只会把连接搞崩。")
                if stage == .waitingBind { stage = .idle }
                testAfterInit = false
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
        append("→ \(short(item.ch.uuid))  \(item.data.count)B  \(item.label)")
        if item.data.count <= 64 {
            append("       \(hex(item.data))")
        } else {
            append("       \(hex(item.data.prefix(10)))…（共 \(item.data.count)B）")
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
            var line = "  ← \(short(characteristic.uuid))  \(f.summary)"
            if let pb = f.pbBrief {
                line += "  \(pb)"
            }
            append(line)
            append("       \(hex(d))")

            // 绑定消息单独解成人话，并驱动流程往下走。
            if let rep = BindReport.decode(f.payload) {
                append("  ★ \(rep.summary)")
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
