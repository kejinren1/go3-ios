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
        append("开始扫描。眼镜要开机、并且尽量别和官方 App 抢连接。")
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
        let perPacket = max(16, maxWriteLength(ch) - 14)   // 14 = 12B 包头 + 2B CRC
        let seq = nextSeq()
        let parts = GO3Frame.packets(seq: seq, payload: payload, maxPayload: perPacket)
        for (i, pkt) in parts.enumerated() {
            let tag = parts.count > 1 ? "\(label) 包\(i + 1)/\(parts.count)" : label
            enqueue(pkt, ch: ch, label: "\(tag) seq=\(seq) \(payload.count)B")
        }
    }

    /// 投递自检：发官方的「亮度 30」命令。
    /// 为什么挑它：效果立刻可见、无害可逆，而且这条帧是从真实抓包里原样抄的，
    /// 不依赖我们对绑定语义的任何猜测。屏幕一变，就说明通道和信封都对了。
    func sendBrightnessTest() {
        guard let ch = targetChannel else {
            append("还没连上眼镜，先连接")
            return
        }
        append("投递自检：把亮度设成 30（官方原帧，payload 未改一个字节）")
        sendPayload([0x10, 0x0B, 0x72, 0x08, 0x08, 0x01, 0x1A, 0x04, 0x08, 0x01, 0x28, 0x06],
                    ch: ch, label: "CONTROL_COMMAND 亮度30")
    }

    private var targetChannel: CBCharacteristic? {
        useRW2021 ? rwChar2021 : writeChar1001
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
    /// 为什么要有这个开关：绑定帧里带 user_account，是最可能让眼镜"认下"
    /// 这个 App 的一步；先只发它，能干净地判断「是不是就缺这一下」，
    /// 而不是一口气推 21 帧、出了问题分不清是哪一步的锅。
    func sendInit(firstOnly: Bool) {
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

        let list = firstOnly ? Array(InitSequence.steps.prefix(1)) : InitSequence.steps
        append("开始发送初始化：\(list.count) 步，通道 \(short(ch.uuid))，单次写入上限 \(maxWriteLength(ch))B")
        append("  信封：type=0x00 src=3 dst=1，\(keepVersionPrefix ? "带" : "不带") 08 01 版本前缀")
        if !firstOnly {
            append("已跳过第 \(InitSequence.skippedIdx) 步（原始数据标了含猜测字段）")
        }
        initRunning = true
        sendStep(list, 0, ch, 0)
    }

    /// `wait` 是"这一帧因为流控被挡住"的重试计数，防止死等。
    private func sendStep(_ list: [InitStep], _ i: Int, _ ch: CBCharacteristic, _ wait: Int) {
        // 中途断连就把循环停掉，否则会在断连后继续空转、最后还误报"发送完毕"。
        guard let p = connectedPeripheral, p.state == .connected else {
            initRunning = false
            queue.removeAll()
            writing = false
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
            append("初始化发送完毕（\(list.count) 步）。看看眼镜还提不提示「下载 INMO App」")
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
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            append("  ← \(short(characteristic.uuid)) 读取出错：\(error.localizedDescription)")
            return
        }
        guard let d = characteristic.value else { return }

        // 能按 aa55 帧解出来就解，解不出来就老实打 hex —— 不猜。
        if let f = GO3Frame.parse(d) {
            var line = "  ← \(short(characteristic.uuid))  \(f.summary)"
            if let pb = f.pbBrief {
                line += "  \(pb)"
            }
            append(line)
            append("       \(hex(d))")
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
