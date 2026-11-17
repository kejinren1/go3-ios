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
                    sessionSection
                    bindSection
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

            // 眼镜是不是真的在跟我们说话，看这个数最省事。
            // 长按 GO 键说完一句话之后它不涨，说明是眼镜没发 ASR，不是我们没解析。
            Text("已收到 \(ble.rxCount) 帧（眼镜主动发来的）")
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    // MARK: - 会话让回

    /// 这一块是 P8 的核心，也是理解整件事的钥匙。
    /// 眼镜屏幕上的「会记 / AI 对话 / 翻译 / 演讲提词」不是眼镜自己算的：
    /// logcat 里 `InmoTranslateAsrClient: asr start Connected,zh` 之后才有
    /// `翻译模块asr断句内容：{"code":"200",...}` —— 采音在眼镜，识别和大模型在手机 App。
    /// 我们占着 BLE 连接，官方 App 就上不去，眼镜等于被拔了脑子。
    /// 所以这里只做一件事：干完活就撒手。
    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("会话让回")
                .font(.headline)

            Text("眼镜的会记/翻译/提词靠的是手机 App 调云端，不是眼镜自己算。我们连着不放，官方 App 就起不来，那些功能必然瘫着——你看到的「像没联网一样」就是这个。所以必须用完即断。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle(isOn: $ble.autoRelease) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.autoRelease ? "干完活自动断开（推荐）" : "一直连着（官方 App 会一直不可用）")
                        .font(.subheadline)
                    Text("断得越快，眼镜越快回到能用的状态")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text("停留")
                    .font(.subheadline)
                Slider(value: $ble.releaseAfter, in: 5...40, step: 1)
                Text("\(Int(ble.releaseAfter)) 秒")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            .disabled(!ble.autoRelease)

            Button {
                ble.releaseNow()
            } label: {
                Text("立刻把眼镜交回官方 App")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(ble.connectedName == nil)

            Text("连上之后日志里会有一段「单变量实验」，按它三步走一遍，就能确定到底是「占连接」还是「写坏了」。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 绑定

    /// 这一步是闸门。
    /// 22:31 的实测说明：眼镜回 `BIND_STATUS_RESPONSE{isBound=0, errorCode=3}` 然后
    /// 发 UNBIND 并断开。官方代码里 isBound=0 时它自己也会 `disconnect()`，
    /// 只有 isBound=1 才 `postDelayed(..., 5000)` 去跑初始化。
    /// 而首次连一台没记录过的设备，官方发的是 `BIND_USERDATA(2)`，不是 `BACK_LINK(1)`。
    private var bindSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("绑定")
                .font(.headline)

            Text("眼镜先要认下这个账号，才肯执行命令。官方：本地没这台设备的记录 → 发「首次绑定」；有记录才发「回连」。我们第一次连，所以用首次绑定。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("账号")
                    .font(.subheadline)
                TextField("52673", text: $ble.userAccount)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            HStack(spacing: 10) {
                Button {
                    ble.sendBind(kind: 2)
                } label: {
                    Text("首次绑定")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    ble.sendBind(kind: 1)
                } label: {
                    Text("回连")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline)
            .disabled(ble.connectedName == nil)

            Text("发送后看日志里的「★ 绑定响应」：isBound=1 才算过。errorCode=1 表示被别的账号占着。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

            Text("「一键流程」= 首次绑定 → 等绑定响应 → isBound=1 → 2 秒后发亮度 → 到点自动断开让回官方 App。绑定不过就停，不硬推。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                ble.runOfficialFlow()
            } label: {
                Text("一键：绑定 → 亮度 → 让回")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSendInit)

            Toggle(isOn: $ble.runInitAfterBind) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.runInitAfterBind ? "绑定后再跑 21 步初始化" : "绑定后直接发命令（默认）")
                        .font(.subheadline)
                    Text("那 21 步是官方走 SPP 时的会话初始化，里面混着切页面指令，可能把命令吃掉")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(ble.initRunning)

            Text("单独发亮度（0~10 档，档位差得越大越容易看出）")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("最暗 1") { ble.sendBrightness(level: 1) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("中 5") { ble.sendBrightness(level: 5) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("最亮 10") { ble.sendBrightness(level: 10) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .font(.subheadline)
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

            Text("第 1 步是回连帧，只在「已绑定」时才有意义；没绑定就发它，眼镜会回 errorCode=3 然后断开（22:31 那次就是这样）。")
                .font(.caption2)
                .foregroundStyle(.secondary)

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
                     : "跑完一键流程后：① 看亮度变没变（1 档应该明显变暗）；② 等它自动断开；③ 去官方 App 点「会记」，看是不是又能听、能计时了。")
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
