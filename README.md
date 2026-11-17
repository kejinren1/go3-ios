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

Sideloadly 要靠苹果的移动设备服务才能跟 iPhone 通信，需要
`C:\Program Files\Common Files\Apple\Mobile Device Support` 这个目录存在。
（本机已经有了，是随其它苹果软件装的，所以**不用再装 iTunes**。
换机器的话：从 Apple 官网装 **iTunes**，别用 Microsoft Store 那个版本。）

### 4. Sideloadly 签名安装（先装 App，别急着找开发者模式）

1. 从 <https://sideloadly.io> 下载，安装。
2. 数据线连 iPhone，手机上点「信任此电脑」。
3. Sideloadly 里把 `GO3Bridge.ipa` 拖进去，`Apple ID` 填你的**免费** Apple ID
   （建议专门注册一个备用账号，主账号密码不用交给第三方工具）。
4. 点 Start，中途可能要输密码和双重验证码。
5. 装完桌面会出现 App 图标，**先点它一次**（会弹出 "Developer Mode Required"，打不开，
   这是对的）。

### 5. 这时开发者模式才会出现（iOS 16+ 必须）

> ⚠️ **踩过的坑**：开发者模式默认是**藏起来的**。苹果的设计是——只有手机装过至少一个
> 开发者签名的 App（或连过 Xcode）之后，这个开关才会出现在设置里。
> 所以顺序必须是「先装 App，再开开发者模式」，反过来永远找不到那个选项。

1. 设置 → **隐私与安全性** → 滚到**最底部**（在「安全性」分组下，不在「通用」里）
2. 点「开发者模式」→ 打开开关
3. 点「重新启动」，等手机重启
4. 重启后解锁，会弹「打开开发者模式?」→ 点「打开」→ 输锁屏密码

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
aa 55 | type | seq | 00 01 | 00 00 | src | dst | len(2B 大端) | payload | crc16(2B 大端)
```

> 长度字段是 **2 字节大端**（偏移 10..11）。早期文档按 1 字节记，是因为短帧高位恰好是 00；
> 拿 283 字节的 SAGENOTE 语言表帧做 CRC 校验时才暴露。详见 `GO3Bridge/Frame.swift` 顶部注释。

电脑侧那套 `agentd / brain / llm / grid / vision` **一行都不用改**，
只把入口从「读 logcat」换成「收 WiFi 请求」。

---

## 五、P3 实机测试：让眼镜认下这个 App

现象：BLE 连上了（眼镜有连接音效），但眼镜屏幕一直提示「下载 INMO App 并连接眼镜」。

**第一版失败的原因已查明**：`INTEL/app_init_wire.json` 里的 `frame` 字段是早前按
「接收方向」模板合成的（`src=1 dst=3`，即眼镜→手机）。把对方说的话原样念回给它听，
眼镜当然不理。用 `sniff.log` 里官方 App 真实发出的 95 条帧反查，方向是：

| 方向 | 特征 |
|---|---|
| 手机 → 眼镜 | `type=0x00` `src=3` `dst=1`，95/95 一致 |
| 眼镜 → 手机 | `src=1或2` `dst=3`，type 各不相同 |

包头布局（两方向通用）：

```
AA 55 | type | seq(帧id) | 总包数(2B) | 当前包号(2B) | src | dst | len(2B) | payload | crc16(2B)
```

长消息要按总包数/包号分包，同一 `seq`；官方每包总长 ≤244B（Android MTU 247−3）。

### 测试顺序（每步只改一个变量）

1. 装新包，Sideloadly 覆盖安装（同一 Apple ID，不用重新信任）。
2. 「扫描」→ 点带 ★ 的眼镜连接。
3. 看日志两行：`包构造器自检：一致`（不一致就先别测了，说明构造器有问题）
   和 `单次写入上限：writeNR xxxB / write xxxB`。
4. **点「投递自检：把亮度设成 30」** ← 关键一步。它发的是官方真实抓到的
   `CONTROL_COMMAND{brightness=30}` 帧，payload 一个字节没改。
   **眼镜屏幕亮度变了 = 通道和信封都对**；没变，后面发初始化全是白费。
5. 自检过了再点「只发第 1 步」（`BLE_CONNECT_BIND`，带 `user_account`）。
6. 提示没消失 → 「发全部 21 步」。
7. 依次试这几个开关，每次只动一个：写类型切「带回执」→ 通道切 1001 → 打开版本前缀。

判断标准永远看**眼镜的实际反应**（亮度、屏幕提示），不看我们日志里的"发送完毕"——
那只代表字节交出去了。

