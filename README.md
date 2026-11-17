# GO3 Bridge for iOS

把 [go3-bridge](../go3-bridge) 那套「眼镜能听能看能干活」的能力搬到 iPhone 上。

**前提约束（决定了这里的每个选择）**

| 约束 | 后果 |
|---|---|
| 没有付费 Apple 开发者账号 | 只能用免费 Apple ID 签名，**7 天过期**，最多 3 个 App |
| iPhone 是 iOS 26 | TrollStore 那条永久签名的路已封死（只到 17.0） |
| 没有 Mac | 编译必须借 GitHub Actions 的 macOS runner |

---

## 一、先搞懂这条路是怎么走的

```
   Windows 这边                      GitHub 那边                  iPhone 那边
   ─────────────                     ────────────                 ───────────
   ① git push  ────────────────►  ② macOS runner
                                      xcodegen → xcodebuild
                                      CODE_SIGNING_ALLOWED=NO
                                          ↓
                                   ③ GO3Bridge.ipa（未签名）
   ④ 下载 artifact ◄──────────────────────┘
   ⑤ Sideloadly + 免费 Apple ID
      现场签名并安装 ──────────────────────────────────────►  ⑥ 信任证书 → 能用了
                                                                  ↓
                                                              7 天后过期，回 ⑤ 重签
```

关键点：**CI 只编译、不签名**。签名在本地做，所以不需要把开发者证书塞进 GitHub Secrets，
也就不需要那 $99。代价是每 7 天重签一次。

---

## 二、第一次跑通（P0：只验证"能装"）

### 1. 仓库（已建好）

仓库已经是公开的：<https://github.com/kejinren1/go3-ios>

```bash
cd go3-ios
git push            # 平时只需要这句，推上去 CI 就自动编译
```

**必须是 public 仓库** —— 公开仓库的 macOS runner 分钟数免费，私有仓库要走付费额度
（macOS 分钟按 10 倍计费）。

> 踩过的坑：这台机器走 HTTP 代理，`github.com` 偶尔会返回
> `CONNECT tunnel failed, response 502`。这是代理抖动，不是权限问题。
> 隔几十秒重试就能过，已经在 `.git/config` 里把 `http.postBuffer`
> 调大、`http.version` 锁 HTTP/1.1 减轻影响。

### 2. 等 Actions 跑绿

Actions 页面 → `ios-ipa` → 最新一次运行。跑完后在页面底部 **Artifacts** 里
下载 `GO3Bridge-ipa`，解压得到 `GO3Bridge.ipa`。

编译失败的话，下载 `xcodebuild-log` 那个 artifact，里面有完整日志。

### 3. Windows 上装 Sideloadly 的前置

Sideloadly 要靠苹果的移动设备服务才能跟 iPhone 通信，所以得先装：

- 从 Apple 官网装 **iTunes**（不是 Microsoft Store 那个版本），或者
- 装 **Apple Devices** 应用

装完确认 `C:\Program Files\Common Files\Apple\Mobile Device Support` 这个目录存在。

### 4. iPhone 上打开开发者模式（iOS 16+ 必须）

设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启 → 重启后确认。

### 5. Sideloadly 签名安装

1. 从 <https://sideloadly.io> 下载，安装。
2. 数据线连 iPhone，手机上点「信任此电脑」。
3. Sideloadly 里把 `GO3Bridge.ipa` 拖进去，`Apple ID` 填你的**免费** Apple ID
   （建议专门注册一个备用账号，主账号密码不用交给第三方工具）。
4. 点 Start，中途可能要输密码和双重验证码。
5. 装完后首次启动会提示「不受信任的开发者」。

### 6. 信任证书

设置 → 通用 → VPN 与设备管理 → 开发者 App → 点你的 Apple ID → 信任。

然后回桌面点开 App。看到「安装链路 已跑通」就说明 P0 成了。

### 7. 7 天后

App 会打不开，提示开发者证书失效。重新走第 5 步即可，**不用重新编译**，
同一个 ipa 文件再签一次就行。

> 嫌每周接电脑烦的话，后面可以换 **SideStore**：一样用免费 Apple ID，
> 但它能在手机上自己续签，装一次不用再碰电脑。不影响这里的任何代码。

---

## 三、目录结构

```
go3-ios/
├─ project.yml                  # 工程定义（YAML）。本机没 Xcode，所以不手写 pbxproj
├─ GO3Bridge/
│  └─ App.swift                 # P0 阶段只有这个文件
└─ .github/workflows/build.yml  # CI：xcodegen → 编译（不签名）→ 打包 ipa
```

`GO3Bridge.xcodeproj` 和 `Info.plist` 都是 CI 现场生成的，**不入库**。
Info.plist 的内容写在 `project.yml` 的 `info.properties` 里，改权限描述改那里。

---

## 四、跟安卓侧的分工（重要）

安卓那边是「改官方 App 的 smali + 电脑侧 adb 旁路」。**这两根支柱在 iOS 上都不存在**：

- 官方 App 的 IPA 是加密二进制，改它需要先越狱砸壳 → 放弃
- iOS 没有 adb，App 沙盒和日志都拿不到 → 旁路作废

所以 iOS 侧是**自己写 App 直连眼镜**，但眼镜协议是同一套，已经在
[`../go3-bridge/proto/PROTOCOL.md`](../go3-bridge/proto/PROTOCOL.md) 里挖全了。
其中 `../go3-bridge/proto/send.py` 的 `build_frame()` 是 Swift 移植的参照实现：

```
aa 55 | type | seq | 00 01 | 00 00 | src | dst | 00 | len | payload | crc16(2B, 大端)
```

电脑侧那套 `agentd / brain / llm / grid / vision` **一行都不用改**，
只把入口从「读 logcat」换成「收 WiFi 请求」。
