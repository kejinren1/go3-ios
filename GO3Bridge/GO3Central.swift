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
        connectedName = peripheral.name ?? peripheral.identifier.uuidString
        append("已连接 \(connectedName ?? "")，开始枚举服务")
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
            append("  订阅失败 \(characteristic.uuid.uuidString)：\(error.localizedDescription)")
        }
    }
}
