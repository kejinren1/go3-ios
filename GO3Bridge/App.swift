import SwiftUI
import UIKit

@main
struct GO3BridgeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// P0 阶段只做一件事：证明这个 App 能被编译出来、签名、装到手机上、能启动。
/// 所以这里刻意只显示环境信息，不碰蓝牙 —— 出问题时可以立刻判断是
/// 安装链路坏了，还是后面的蓝牙代码坏了。
struct RootView: View {
    private let rows: [(String, String, Bool)] = [
        ("安装链路", "已跑通", true),
        ("蓝牙连接", "未接入", false),
        ("协议收发", "未接入", false),
        ("语音上屏", "未接入", false),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows, id: \.0) { row in
                        HStack {
                            Text(row.0)
                            Spacer()
                            Text(row.1)
                                .foregroundStyle(row.2 ? Color.green : Color.secondary)
                        }
                    }
                } header: {
                    Text("阶段进度")
                }

                Section {
                    LabeledContent("App 版本", value: appVersion)
                    LabeledContent("系统版本", value: UIDevice.current.systemVersion)
                    LabeledContent("机型", value: UIDevice.current.model)
                } header: {
                    Text("运行环境")
                }

                Section {
                    Text("当前是 P0：只验证「能不能装进 iPhone」。蓝牙与协议在 P1/P2 接进来。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("GO3 Bridge")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
