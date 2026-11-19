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

### 测试顺序（P9，2026-11-17 23:29 事故后修订）

1. 装新包，Sideloadly 覆盖安装（同一 Apple ID，不用重新信任）。
2. 眼镜开机、亮屏，并且退到主界面（不要停在「会记」之类的页面里）。
3. 「扫描」→ 点带 ★ 的 `INMO GO3 42D3_BLE` 连接。
4. 看日志：`包构造器自检：一致`、`单次写入上限：writeNR xxxB / write xxxB`。
5. 点**「一键：绑定 → 握手 → 去眼镜选会记」**。它按官方时序跑：
   首次绑定 → 等 `isBound=1` → 等 5 秒 → 发 20 步握手（第 1 步的绑定已发过，跳过）。
6. 看 `★ 绑定响应 ...`：
   - `isBound=1` → 过闸门，后面自动往下跑。
   - `isBound=0 errorCode=3` → 眼镜处于「被动解绑」状态，需要重新绑定。
   - `errorCode=1` → 设备被别的账号占着。改「账号」输入框里的 id 再试。
7. 等日志滚到 `初始化发送完毕（20 步）`。
8. 去**眼镜菜单**里选「会记」，看还报不报「APP 版本过低无法打开」。
9. 仍然报 → 把「版本」输入框改成更高的值（如 `3.0.500`），点「补发版本」，再试。

判断标准看**眼镜的实际反应**（能不能进会记界面、听不听、计时走不走），
不看我们日志里的"发送完毕"。

**注意 P9 修掉的两个坑**（都出在我自己的默认值上，不是眼镜的问题）：

| 现象 | 真因 | 修法 |
|---|---|---|
| 连接成功几秒后提示蓝牙断开 | P8 的 `autoRelease` 默认开 12 秒，到点我方主动 `cancelPeripheralConnection` | 默认关，「连接保持」卡片里可手动断 |
| 眼镜菜单选「会记」报「APP 版本过低」 | P7 把 21 步全跳过，连 `PHONE_INFO` 版本上报一起丢了 | 默认发全套，`phoneVersion` 可改 |

### 绑定这道闸门（为什么必须先过它）

反编译 `BleProtocolManager` / `BluetoothMultiProfileHelper` 得到的官方逻辑：

```java
// sendBindConnectProtocol()
if (DeviceInfo.isDeviceExist(address)) BACK_LINK(1);
else                                  BIND_USERDATA(2);   // 首次连接走这条

// 收到 BIND_STATUS_RESPONSE 时
isAuthorizedConnect = bindStatus.getIsBound();
if (bindStatus.getIsBound()) { postDelayed(globalUnifiedProcess, 5000); return; }
disconnect();                       // 未绑定 → 官方自己断开
// errorCode 1/3/4 → 弹"被动解绑"对话框
```

所以：**未绑定状态下硬发那 21 步初始化，眼镜会回 `UNBIND` 并断开**，
屏幕上就是"连接失败"。22:31 那次实测就是这样。P6 改发 `BIND_USERDATA(2)` 后
23:06 拿到 `isBound=1 errorCode=0 boundUserId=52673`，闸门过了。

---

## 六、眼镜的「脑」在手机侧，而我们自己就是那个脑

### 先纠正一个已经作废的结论

P8 第一版曾推断「官方 App 才是脑，我们只能当遥控器，用完即断」。
**2026-11-17 23:32 用户当面纠正，这个结论作废**：

- **绑定由我们这个 App 完成**，官方 App 不是这条链路的一环。
  如果不经我们绑定，官方 App 也操控不了眼镜。
- 此前的成功形态是：**绑定成功后，直接在眼镜菜单里选「会记」就能打开**，
  全程不需要官方 App。
- 23:29 日志里那句「连接成功几秒后蓝牙断开」，罪魁是 P8 自己加的
  12 秒 `autoRelease`（日志 `⏳ 到点，主动断开` 之后紧跟 `连接断开`），
  不是眼镜踢人，也不是官方 App 抢连接。

所以当前形态是：**常连**。`autoRelease` 默认关，只作为调试开关留着。

### 为什么眼镜功能依赖手机侧

这一点没有变，安卓 logcat 铁证：

```
InmoTranslateAsrClient: asr start Connected,zh
翻译模块asr断句内容：{"code":"200","data":{"message":"把亮度调到30%。"}}
CodecOpus: [encoderInit] / [decoderInit]
```

链路是「眼镜采音 → Opus 编码 → 手机侧收 → 调云端 ASR → 文本回眼镜上屏」。
眼镜只有麦克风、屏幕、解码器。**手机侧必须有人顶上这个角色 —— 现在这个人是我们。**

### 「APP 版本过低无法打开」的精确成因

眼镜靠 `BLE_CONNECT_BIND` 的 `kind=7` 子消息知道对端 App 的版本。
官方抓包（`app_init_wire.json` 第 4 步）原文：

```
08 01                            f1 = version
da 01 0f                         f27 = BleConnectBind
   08 07                             f1 = kind = 7 (PHONE_INFO)
   3a 0b                             f7 = PhoneInfo
      0a 07 33 2e 30 2e 34 35 35        f1 = "3.0.455"   ← App 版本号
      10 01                            f2 = 1
```

去掉 `08 01` 后实际要发的是：

```
10 18 da 01 0f 08 07 3a 0b 0a 07 33 2e 30 2e 34 35 35 10 01
```

**P7 把整个 21 步跳过后，这条版本上报也一起没了**，眼镜等不到版本信息，
就在打开「会记」时直接拒绝，提示「APP 版本过低无法打开」。

修正：`phoneVersion` 默认 `3.0.455`，界面上可改；绑定成功后自动随握手发出，
也能单独点「补发版本」。若 3.0.455 仍被判过低，往上调（眼镜固件是 `Go3_DC_V3.0.406`）。

### 那 21 步到底是什么

不是"会话初始化装饰"，是**让眼镜相信对面是够新的正版 App 的握手**：

| 步骤 | 内容 | 少了会怎样 |
|---|---|---|
| #1 | `BLE_CONNECT_BIND` 绑定 | 眼镜回 `UNBIND` 并断开 |
| #2 #3 #14 #15 #20 | `SAGENOTE` 语言表 | 翻译/语种相关功能不可用 |
| #4 | `BLE_CONNECT_BIND{kind=7}` 版本上报 | **「APP 版本过低无法打开」** |
| #6 | `OTHER_CONTROL_COMMANDS` | 控制类命令可能被忽略 |
| #7 #23 | `FILE_LOG_FETCH_COMMAND` | 日志抓取不可用 |
| #8 #16 #18 #19 #22 #24 | `glasses_settings`（含设备名 `INMO GO3 42D3`） | 设置项不同步 |
| #10 #17 #25 | `SPEECH_INSCRIPTION` | 提词/字幕通道未握手 |
| #11 | `img_manager` | 图片通道未握手 |
| #21 | `SUPPORTED_MODULES` | 眼镜不知道我们支持哪些能力 |

**结论：默认必须发全。** 跳过它只适合做单点排查。

### 还差什么才能真正"用起来"

绑定 + 握手能解决「认不认你」，但「会记听不听、提词转不转圈」还取决于
手机侧有没有提供 ASR / 云端能力。我们的 App 目前只有协议层，
没有音频接收和云端识别 —— 这是下一步要做的事，不是配置问题。

---

## 七、会记（SAGENOTE）：一条完整闭环

2026-11-19 的日志把问题定死了：**版本号修好后，眼镜打开会记会用 `AUDIO(0)` 持续把
麦克风数据推上来**（248 帧里 235 帧是音频，约 18 帧/秒、每帧 ~185B，16 kHz / 32 kbps），
而我们一条都没回。所以症状不是"眼镜不工作"，是"手机侧没接"。

### 消息地图（`MessageTypeProto` 原文）

| msgType | 名字 | 内外层 |
|---|---|---|
| 0 | AUDIO | f3 = `{f1=AudioConfig{sampleRate, ch, bitrate, model}, f3=len, f4=opus}` |
| 43 | SAGENOTE | f46 = `Sagenote` |

`Sagenote`（`SagenoteProto.java`）字段：1 类型 / 2 command_id / 3 session_id /
4 时间戳 / 10 command / 11 command_ack / 12 query / 13 state / 14 asr /
15 translation / 16 summary / 17 config / 18 panel / 19 marker / 21 语言表 / 22 tab_view / 23 backup

`SagenoteMessageType`：0 COMMAND / 1 COMMAND_ACK / 2 QUERY / 3 STATE / 4 ASR /
5 TRANSLATION / 6 SUMMARY / 7 CONFIG / 8 PANEL / 9 MARKER / 11 LANGUAGE_LIST /
12 TAB_VIEW / 13 BACKUP

### 闭环长什么样（官方抓包 `INTEL/sniff.log` 手机→眼镜方向，逐字节核对过）

| 步 | 帧 | 关键字节 |
|---|---|---|
| 1 | 语言表 / 配置 | `10 2b f2 02 <len> 08 0b …`（281 字节，要分包） |
| 2 | 命令回执 | `08 01 … 5a 18 08 02 10 01 2a 12 <session>` |
| 3 | **每秒状态心跳** | `08 03 … 6a 0a 08 01 10 01 18 <seq> 20 02 2a 00` |
| 4 | 识别结果 | `08 04 … 72 1e 10 01 1a 1a 08 01 12 03 <文字> 20 02 2a 09 <说话人> 30 <begin> 38 <end>` |
| 5 | 音频备份 | `08 0d …` |

**「不计时」就是这个第 3 步**：眼镜屏幕上的时长靠手机每秒发一条 `SAGENOTE_STATE` 推进，
`18 <seq>` 那个数是逐秒递增的（抓包里 01→02→04→05…→1a）。我们从来不发，屏幕就一直是 00:00。

**「不识别文字」是第 4 步**：得先解 Opus 再调云端 ASR。目前没做，
所以界面上给了一个「手动注入一句识别结果」的框 —— 用来**单独验证回传通道**。
通道和识别是两个问题，别混着查。

### 现在能自己验证什么

1. 眼镜上打开会记 → 界面「音频帧」开始涨 = 采音在跑、链路是通的
2. 日志出现 `⏱ 开始每秒状态心跳` → 看眼镜屏幕上的计时是否开始走
3. 手动注入一句「测试一二三」→ 眼镜屏幕上出现了 = 回传通道没问题，只差识别

### 还没做的

`Opus 解码 + 云端 ASR`。iOS 没有公开的 Opus 解码 API，可选：
① CI 里编一份 libopus 静态库塞进 App；② 把裸 Opus 包转发到电脑/服务端解码再回传。
两条都要真实 ASR 账号（讯飞/火山/阿里）才出文字。

---

## 八、日志怎么取（不用再手抄）

以前的做法是：App 里一个 `TextEditor`，用户手抹选文字 → 粘到 docx → 发过来。
一份 500 行的日志要来回好几趟，而且 `TextEditor` 里选中长文本本身就会漏行。
P12 起有三条路，按"省事程度"从上到下：

### 1. App 内直接导出（零依赖，最先用这个）

右上角菜单 →「导出为文件并分享」→ 存到「文件」App / AirDrop / 发给微信。
落到沙盒 `Documents/go3bridge.log`，同时弹系统分享面板。

`project.yml` 里已经打开：
```yaml
UIFileSharingEnabled: true
LSSupportsOpeningDocumentsInPlace: true
```
所以这个文件在「文件」App 的「我的 iPhone → GO3 Bridge」里也直接可见。

### 2. 电脑直接拉文件（不做任何操作，适合"事后取证"）

```bash
pip install pymobiledevice3
python -m pymobiledevice3 apps pull --documents com.go3bridge.app ./
```
不需要 Info.plist 开文件共享也能拉（走 house_arrest），所以这条路对**旧包也有效**。
代价是只能拿到"已经写进文件的部分"，看不到实时滚动。

### 3. 实时推送（边操作边看，最优）

App 里 `LogServer` 在 8787 上监听；电脑用 usbmux 把它映射出来：

```bash
python tools/tail-log.py          # 一条命令搞定，内部自己起转发再连接
```

等价的手工版本：
```bash
python -m pymobiledevice3 usbmux forward 8787 8787
# 另开一个窗口
nc 127.0.0.1 8787
```

**为什么走 usbmux 而不是 WiFi**：用眼镜时手机常常连着 `INMO GO3 42D3` 热点，
这时电脑和手机根本不在一个网段，WiFi 直连必失败。usbmux 走数据线，与网络拓扑无关。
连上会先补发最近 300 行，所以"先出事、后开电脑"也不会丢现场。

### 为什么还要 `os_log`

`append()` 原来是裸 `print()` —— 在侧载的发行版里 stdout 直接进黑洞，
`Console.app` / `syslog` 一个字都看不到。现在同时走 `os_log`
（`subsystem=com.go3bridge.app, category=bridge`，全部 `%{public}@`），
所以数据线插着时 `python -m pymobiledevice3 syslog` 也能看到一份。

### 顺手修的两个坑

- **日志上限 500 行 → 4000 行**。一轮 21 步握手的 hex 就能把前面的现场全挤掉，
  22:47 那份日志里"眼镜刚连上时发了什么"就是这么丢的。
- **界面只渲染最后 300 行**。`ForEach` 铺上千行会卡，而排查要看的信息都在尾部。

### 会记帧现在会打原文

以前 `handleSagenote` 只打人话（`◆ 会记 ...`）就 `return`，原文 hex 没了。
22:47 那场出现 `typeName=未知(10)` 时就没法回头核对到底发了哪几个字段。
现在会记帧也打 hex；音频则**只留首帧**（含 `AudioConfig` 解析：采样率/声道/码率/型号），
其余仍然只计数——一秒十几帧全打会把有用的东西冲走。
