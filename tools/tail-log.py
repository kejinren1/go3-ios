"""在 Windows 上实时看 iPhone 里 GO3Bridge 的日志 —— 不用再手抄。

原理（和 Shazam 那套一样，只是换了壳）：
    App 在手机里监听 8787 端口 ──usbmux──► 电脑的 127.0.0.1:8787
usbmux 走的是数据线，跟 WiFi 无关，所以手机连着眼镜热点 `INMO GO3 42D3`
也照样能看。

用法：
    pip install pymobiledevice3
    python tools/tail-log.py

    # 只想存文件、不刷屏：
    python tools/tail-log.py > log.txt

    # 端口被占时换一个（同时要改 App 里 LogServer.port 并重新打包）：
    python tools/tail-log.py --port 8788

前提：手机用数据线连着电脑，并且已经在手机上点过「信任此电脑」。
"""
import argparse
import socket
import subprocess
import sys
import time

LOCAL_HINT = "127.0.0.1"


def start_forward(port: int) -> subprocess.Popen:
    """起 usbmux 端口转发：电脑 port → 手机 port。"""
    cmd = [sys.executable, "-m", "pymobiledevice3", "usbmux", "forward",
           str(port), str(port)]
    print(f"[*] 启动转发：{' '.join(cmd)}", file=sys.stderr)
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def wait_port(port: int, timeout: float = 20.0) -> bool:
    """等转发端口真的能连上。usbmux 起来需要一两秒，不看就 connect 会立刻失败。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((LOCAL_HINT, port), timeout=1):
                return True
        except OSError:
            time.sleep(0.5)
    return False


def tail(port: int, out_file: str | None) -> None:
    """连上就不停读，一行一行往外吐；断了自己重连。"""
    while True:
        try:
            with socket.create_connection((LOCAL_HINT, port), timeout=5) as s:
                # 关掉 Nagle，日志要的是"立刻看到"
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                print(f"[*] 已连上 App 日志流（端口 {port}），Ctrl+C 退出", file=sys.stderr)
                buf = b""
                while True:
                    chunk = s.recv(4096)
                    if not chunk:
                        print("[!] 流断了（手机上 App 被杀 / 线松了），重连中…", file=sys.stderr)
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        text = line.decode("utf-8", "replace")
                        if out_file:
                            with open(out_file, "a", encoding="utf-8") as f:
                                f.write(text + "\n")
                        else:
                            print(text)
        except KeyboardInterrupt:
            return
        except OSError as e:
            print(f"[!] 连接失败：{e}；2 秒后重试", file=sys.stderr)
            time.sleep(2)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787,
                    help="端口，必须和 App 里 LogServer.port 一致（默认 8787）")
    ap.add_argument("--save", default=None,
                    help="同时把日志追加写进这个文件")
    ap.add_argument("--no-forward", action="store_true",
                    help="已经有别的进程在做转发了，这里只连不转发")
    args = ap.parse_args()

    proc = None
    if not args.no_forward:
        proc = start_forward(args.port)

    if not wait_port(args.port):
        print("[x] 等不到转发端口。检查：\n"
              "    1) 数据线连着、手机已点「信任此电脑」\n"
              "    2) pip install pymobiledevice3 是否成功\n"
              "    3) 手机上 GO3Bridge 是否在前台跑过（App 里才起监听）",
              file=sys.stderr)
        if proc:
            proc.terminate()
        sys.exit(1)

    try:
        tail(args.port, args.save)
    finally:
        if proc:
            proc.terminate()


if __name__ == "__main__":
    main()
