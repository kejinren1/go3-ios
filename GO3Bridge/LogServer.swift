import Foundation
import Network

/// 把日志实时送到电脑，**不再手抄**。
///
/// 原理：App 在设备上监听一个 TCP 端口；电脑用 usbmux 把它映射成本机端口。
/// ```
/// 电脑: pymobiledevice3 usbmux forward 8787 8787
/// 电脑: nc 127.0.0.1 8787          # 或者 curl -N http://127.0.0.1:8787/
/// ```
/// 为什么走 usbmux 而不是 WiFi：手机用眼镜时常常连着 `INMO GO3 42D3` 热点，
/// 那时电脑和手机根本不在一个网段，WiFi 直连必失败；而 usbmux 走的是数据线，
/// 与网络拓扑无关。另外 loopback/局域网监听都不弹「本地网络」权限框的例外情况是
/// 只有 loopback 才免授权 —— 这里绑 0.0.0.0，所以在 project.yml 里补了
/// `NSLocalNetworkUsageDescription`，插线场景不影响、同 WiFi 场景也不至于静默失败。
///
/// 设计取舍：
/// - **单向下行**（App → 电脑）。反向发指令不做，避免半成品把眼镜状态搞乱。
/// - 连上来先回放最近 `backlogLimit` 行，这样"后开电脑"也能看到出事那一段。
/// - 每条日志一行一个 TCP 包直接写，不做协议包装：`nc` 就能看，越笨越可靠。
final class LogServer {

    static let shared = LogServer()

    /// 端口别乱改：电脑端脚本里写的是这个数。
    static let port: UInt16 = 8787

    /// 新连接进来时先补发多少行历史。
    private let backlogLimit = 300

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "go3.logserver")
    private var backlog: [String] = []
    private var started = false

    /// 界面上的显示用：一共来过几个连接、当前几个在线。
    private(set) var totalConnections = 0
    private(set) var liveConnections = 0

    /// 启动失败的原因，给界面显示（最常见：端口被占）。
    private(set) var lastError: String?

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true

            guard let p = NWEndpoint.Port(rawValue: LogServer.port) else { return }
            let params = NWParameters.tcp
            // 允许端口复用，避免上一次进程残留导致 bind 失败
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true

            do {
                let l = try NWListener(using: params, on: p)
                l.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.lastError = nil
                    case .failed(let e):
                        self.lastError = "监听失败：\(e.localizedDescription)"
                        self.listener?.cancel()
                        self.listener = nil
                    default:
                        break
                    }
                }
                l.newConnectionHandler = { [weak self] conn in
                    self?.accept(conn)
                }
                self.listener = l
                l.start(queue: self.queue)
            } catch {
                self.lastError = "监听 \(LogServer.port) 失败：\(error.localizedDescription)"
                self.started = false
            }
        }
    }

    private func accept(_ conn: NWConnection) {
        clients[ObjectIdentifier(conn)] = conn
        totalConnections += 1
        liveConnections = clients.count

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.drop(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)

        // 先把最近的历史补上，再进入实时模式
        if !backlog.isEmpty {
            let snap = backlog.joined(separator: "\n") + "\n"
            conn.send(content: Data(snap.utf8), completion: .idempotent)
        }
    }

    private func drop(_ conn: NWConnection) {
        clients.removeValue(forKey: ObjectIdentifier(conn))
        liveConnections = clients.count
    }

    /// 每产生一行日志就调这里。没有客户端时只维护 backlog，开销接近零。
    func broadcast(_ line: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.backlog.append(line)
            if self.backlog.count > self.backlogLimit {
                self.backlog.removeFirst(self.backlog.count - self.backlogLimit)
            }
            guard !self.clients.isEmpty else { return }
            let data = Data((line + "\n").utf8)
            for c in self.clients.values {
                c.send(content: data, completion: .idempotent)
            }
        }
    }

    /// 状态文案，给界面显示。
    var statusText: String {
        if let e = lastError { return e }
        if listener == nil { return "未启动" }
        if liveConnections > 0 { return "在线 \(liveConnections) 个连接（累计 \(totalConnections)）" }
        return "在 \(LogServer.port) 等电脑连（累计 \(totalConnections)）"
    }
}
