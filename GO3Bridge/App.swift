import SwiftUI
import UIKit
import CoreBluetooth

@main
struct GO3BridgeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var ble = GO3Central()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    deviceSection
                    initSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("GO3 Bridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("复制日志") { ble.copyLog() }
                        .disabled(ble.log.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(ble.scanning ? "停止" : "扫描") {
                        if ble.scanning {
                            ble.stopScan()
                        } else {
                            ble.startScan()
                        }
                    }
                    .disabled(!ble.scanning && ble.managerState != .poweredOn)
                }
            }
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: ble.managerState))
                    .frame(width: 9, height: 9)
                Text(ble.stateText)
                    .font(.subheadline)
                Spacer()
                if ble.scanning {
                    Text("扫描中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let name = ble.connectedName {
                HStack {
                    Text("已连接：\(name)")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("断开") { ble.disconnect() }
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func color(for s: CBManagerState) -> Color {
        switch s {
        case .poweredOn:    return .green
        case .poweredOff:   return .orange
        case .unauthorized: return .red
        case .unsupported:  return .red
        default:            return .gray
        }
    }

    // MARK: - 设备

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("周边设备")
                .font(.headline)

            if ble.devices.isEmpty {
                Text("点右上角「扫描」。眼镜要开机，最好先把官方 INMO App 退到后台。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ble.devices) { d in
                    Button {
                        ble.connect(d)
                    } label: {
                        HStack(spacing: 10) {
                            Text(d.isGO3 ? "★" : "•")
                                .foregroundStyle(d.isGO3 ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name.isEmpty ? "(无名设备)" : d.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text(String(d.id.uuidString.prefix(8)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(d.rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    Divider()
                }
            }
        }
    }

    // MARK: - 初始化握手

    /// P3 的核心区。
    /// 眼镜会响"连接成功"的音效，但屏幕一直提示「下载 INMO App」——
    /// 因为 BLE 只是连上了，App 一个字节都没回，眼镜不认这个对端。
    ///
    /// 上一版发出去没用，原因已查明：`INTEL/app_init_wire.json` 里的帧是
    /// 早前按「接收方向」模板合成的，`src=1 dst=3`（眼镜→手机）。
    /// 把对方说的话原样念回给它听，它当然不理。官方真正发出的是 `type=0x00 src=3 dst=1`。
    private var initSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("初始化握手")
                .font(.headline)

            Text("先点「投递自检」——它发的是官方真实抓到的「亮度 30」命令，效果立刻可见。屏幕变了，才说明通道和信封都对；这一步不过，后面发初始化没有意义。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                ble.sendBrightnessTest()
            } label: {
                Text("投递自检：把亮度设成 30")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSendInit)

            Divider()

            Toggle(isOn: $ble.useRW2021) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.useRW2021 ? "写通道：2021" : "写通道：1001")
                        .font(.subheadline)
                    Text(ble.useRW2021 ? "read+write+writeNR，与通知 2022 同服务" : "7033 服务下的 writeNR")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(ble.initRunning)

            Toggle(isOn: $ble.useWriteResponse) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.useWriteResponse ? "写类型：带回执(write)" : "写类型：无回执(writeNR)")
                        .font(.subheadline)
                    Text("无回执是官方做法；若眼镜完全不理，切这个再试")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(ble.initRunning)

            Toggle(isOn: $ble.keepVersionPrefix) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.keepVersionPrefix ? "带 08 01 版本前缀" : "不带版本前缀（默认）")
                        .font(.subheadline)
                    Text("官方发出的 95 条帧都没有 version 字段，所以默认不带；不生效再打开")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(ble.initRunning)

            HStack(spacing: 10) {
                Button {
                    ble.sendInit(firstOnly: true)
                } label: {
                    Text("只发第 1 步")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    ble.sendInit(firstOnly: false)
                } label: {
                    Text("发全部 \(InitSequence.steps.count) 步")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline)
            .disabled(!canSendInit)

            if ble.initRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("发送中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(ble.connectedName == nil
                     ? "先在上面连上眼镜"
                     : "顺序：投递自检（看屏幕亮度）→ 只发第 1 步 → 还不消失就发全部 21 步。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var canSendInit: Bool {
        ble.connectedName != nil && !ble.initRunning
    }

    // MARK: - 日志
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("日志")
                    .font(.headline)
                Spacer()
                Text("\(ble.log.count) 行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(ble.log.enumerated()), id: \.offset) { pair in
                    Text(pair.element)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
