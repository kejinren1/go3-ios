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

/// 分享面板要一个 Identifiable 的载体，URL 本身不是。
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// 把系统的「分享」面板包一层：可以直接 AirDrop / 存到「文件」/ 发微信，
/// 比在 TextEditor 里抹选文字再粘贴快得多。
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct RootView: View {
    @StateObject private var ble = GO3Central()
    @State private var asrText = ""
    @State private var shareItem: ShareItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    audioSection
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
                    // 三个动作合成一个菜单：手抄、分享、清场。
                    // 「导出文件」是最省事的——存到「文件」或直接发给电脑，不用选文字。
                    Menu {
                        Button("复制全部日志") { ble.copyLog() }
                        Button("导出为文件并分享") {
                            if let u = ble.exportLog() { shareItem = ShareItem(url: u) }
                        }
                        Button("清空日志", role: .destructive) { ble.clearLog() }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
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
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url])
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
                Text("点右上角「扫描」。眼镜要开机亮屏。一个蓝牙外设同一时刻只能被一个 App 连着，若别的 App 也连在眼镜上，先让它断开。")
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

    // MARK: - 音频 / 会记

    /// 这一块是判断「会记到底卡在哪」的仪表盘。
    /// 眼镜打开会记后会用 `AUDIO(0)` 往上狂推 Opus（实测约 18 帧/秒、16 kHz、32 kbps），
    /// 同时发 `SAGENOTE(43)` 的命令和状态。音频帧数在涨 = 它确实在采音，
    /// 那么「不识别文字」就一定是手机侧没做识别，而不是没收到声音。
    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("音频 / 会记")
                .font(.headline)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ble.audioFrames)")
                        .font(.title3.monospacedDigit())
                    Text("音频帧")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f KB", Double(ble.audioBytes) / 1024.0))
                        .font(.title3.monospacedDigit())
                    Text("累计")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.0f", ble.audioFPS))
                        .font(.title3.monospacedDigit())
                    Text("帧/秒")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(ble.audioFrames > 0
                 ? "眼镜在采音并推 Opus 上来。这些字节目前只统计不解码——要出文字得在手机侧加「Opus 解码 + 云端 ASR」。"
                 : "还没收到音频。去眼镜菜单打开「会记」，这个数应该立刻开始涨。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Text("最近一条会记消息")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ble.lastSagenote)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // 上一场没收尾，眼镜会连着旧会话：一进会记就显示"已经开了 23 分钟"。
            // 这两个按钮就是给这种情况准备的手动闸门。
            VStack(alignment: .leading, spacing: 6) {
                Text("会记命令（试验性）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("STOP 收尾旧场") { ble.sendSagenoteCommand(.stop) }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                    Button("START 新建一场") { ble.sendSagenoteCommand(.start) }
                        .buttonStyle(.borderedProminent)
                        .font(.subheadline)
                    Spacer()
                }
                Text(ble.lastSessionId.isEmpty
                     ? "还没有会话 id：先在眼镜上打开一次「会记」，让眼镜把 session 报上来。"
                     : "当前 session：\(String(decoding: ble.lastSessionId, as: UTF8.self))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // 眼镜屏幕上的计时靠手机每秒发一条 SAGENOTE_STATE 推进。
            // 官方抓包里序号是 01→02→03 递增的，我们照做。
            HStack(spacing: 8) {
                Circle()
                    .fill(ble.tickerRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(ble.tickerRunning
                     ? "状态心跳：运行中，已发 \(ble.stateTicks) 条（眼镜的计时靠它）"
                     : "状态心跳：未运行（等眼镜发 START/RESUME）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 还没有真正的语音识别，但通道可以先验：这段字如果出现在眼镜上，
            // 说明缺的只剩「Opus 解码 + 云端 ASR」，协议层是通的。
            HStack(spacing: 8) {
                TextField("手动注入一句识别结果", text: $asrText)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                Button("发送") {
                    ble.injectAsr(asrText)
                    asrText = ""
                }
                .buttonStyle(.borderedProminent)
                .font(.subheadline)
                .disabled(asrText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(ble.lastSessionId.isEmpty)

            Text("这句话会以「识别结果」的身份发给眼镜。屏幕上出现了它 = 回传通道通了；没出现 = 协议字段还有问题。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 连接保持

    /// 上一版这块叫「会话让回」，思路是干完活赶紧断、把连接还给官方 App。
    /// **23:32 被用户纠正、作废**：绑定是我们这个 App 做的，官方 App 不是这条链路的一环。
    /// 而且 23:29 的日志证明，那个 12 秒自动断开正是「连接成功几秒后蓝牙断开」的元凶
    /// （日志 `⏳ 到点，主动断开` 之后紧跟 `连接断开`）。
    /// 现在默认保持连接，定时断开只当调试开关留着。
    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接保持")
                .font(.headline)

            Text("绑定由本 App 完成，眼镜只认账号绑定状态。所以必须一直连着——断了眼镜就没法工作。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle(isOn: $ble.autoRelease) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.autoRelease ? "定时断开：开（调试用）" : "保持连接（正常状态）")
                        .font(.subheadline)
                    Text(ble.autoRelease
                         ? "到点会主动断，眼镜屏幕会显示蓝牙断开 —— 这是它在掐连接，别误判成故障"
                         : "只有你手动按「断开」才会断")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if ble.autoRelease {
                HStack(spacing: 8) {
                    Text("停留")
                        .font(.subheadline)
                    Slider(value: $ble.releaseAfter, in: 5...60, step: 1)
                    Text("\(Int(ble.releaseAfter)) 秒")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }

            Button {
                ble.releaseNow()
            } label: {
                Text("断开连接")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(ble.connectedName == nil)
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

            // 先问一句「现在绑没绑」，比盲猜发 BIND_USERDATA 还是 BACK_LINK 靠谱。
            // 眼镜的 BIND_STATUS_RESPONSE 三种 kind 都回同一种消息，所以发查询也一样解。
            Button {
                ble.sendBind(kind: 0)
            } label: {
                Text("查询当前绑定状态")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
            .disabled(ble.connectedName == nil)

            Text("发送后看日志里的「★ 绑定响应」：isBound=1 才算过。errorCode=1 表示被别的账号占着。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            // 「APP 版本过低无法打开」就是缺这一条。
            // 眼镜靠 BLE_CONNECT_BIND{kind=7, phoneInfo{f1=版本}} 判断对端 App 的版本，
            // 官方抓包里发的是 3.0.455。不发或发低了，眼镜菜单里的「会记」直接拒绝打开。
            Text("上报 App 版本（修「APP 版本过低」）")
                .font(.subheadline)

            Text("眼镜用这条判断对面是不是够新的正版 App。官方抓包值是 3.0.455。若仍被判过低，往上调再试。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("版本")
                    .font(.subheadline)
                TextField("3.0.455", text: $ble.phoneVersion)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("补发版本") { ble.sendPhoneInfo() }
                    .buttonStyle(.borderedProminent)
                    .font(.subheadline)
            }
            .disabled(ble.connectedName == nil)
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

            Text("「一键流程」= 首次绑定 → 等 isBound=1 → 等 5 秒 → 发握手（含版本上报）。绑定不过就停，不硬推。不自动发亮度、也不会自动断开。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                ble.runOfficialFlow()
            } label: {
                Text("一键：绑定 → 握手 → 去眼镜选会记")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSendInit)

            Toggle(isOn: $ble.runInitAfterBind) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.runInitAfterBind ? "绑定后发完整握手（必须开着）" : "只补发版本号（最小修复）")
                        .font(.subheadline)
                    Text("关掉会让「会记」报 APP 版本过低 —— 那 21 步里第 4 步就是版本上报，还有语言表/模块声明")
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
                     : "跑完一键流程后：① 确认日志滚到「初始化发送完毕」；② 去眼镜菜单选「会记」；③ 断了就把日志发我。")
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

            // 实时通道状态。电脑侧一行命令就能看到：
            //   pymobiledevice3 usbmux forward 8787 8787  然后  nc 127.0.0.1 8787
            Text("实时推送：\(LogServer.shared.statusText)  ·  端口 \(LogServer.port)")
                .font(.caption2)
                .foregroundStyle(LogServer.shared.liveConnections > 0 ? .green : .secondary)
            Text("磁盘：Documents/\(GO3Central.logFileName)（关掉 App 也还在，电脑可用 pymobiledevice3 apps pull 拉走）")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                // 只渲染最后 300 行：一次性 ForEach 上千行会把界面拖卡，
                // 而排查要看的信息都在尾部。
                ForEach(Array(ble.log.suffix(300).enumerated()), id: \.offset) { pair in
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
