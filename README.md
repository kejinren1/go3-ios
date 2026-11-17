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
2. **先把 iOS 上的官方 INMO App 划掉（后台也不行）**，否则两边抢连接。
3. 「扫描」→ 点带 ★ 的眼镜连接。
4. 看日志：`包构造器自检：一致`、`单次写入上限：writeNR xxxB / write xxxB`，
   然后紧跟一段 `──── 单变量实验 ────`。
5. 先按「单变量实验」的三步走，把根因钉死（见下一节）。
6. 再点**「一键：绑定 → 亮度 → 让回」**。它按官方时序跑：
   首次绑定 → 等绑定响应 → `isBound=1` 后 2 秒发亮度 → 到点自动断开。
7. 看日志里的 `★ 绑定响应 ...`：
   - `isBound=1` → 绑定通过，后面会自动往下跑。
   - `isBound=0 errorCode=3` → 眼镜处于「被动解绑」状态，需要重新绑定。
   - `errorCode=1` → 设备被别的账号占着。改上面「账号」输入框里的 id 再试。
8. 断开后去官方 App 点「会记」，看是否恢复正常。

判断标准永远看**眼镜的实际反应**（亮度、屏幕提示、官方 App 能不能用），
不看我们日志里的"发送完毕"。

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

## 六、最关键的一条：眼镜的智能在手机里，不在眼镜里

这是 P7 实机之后才彻底想明白的事，它决定了整个项目的形态。

**现象**：绑定成功后，眼镜屏幕上的「会记」不听、不计时，「AI 对话」也不回，
「演讲提词」一直转圈，像没联网。**把我们这个 App 完全关掉，官方 App 立刻恢复正常。**

**为什么**：那些功能不是眼镜自己算的。logcat 铁证：

```
InmoTranslateAsrClient: asr start Connected,zh
翻译模块asr断句内容：{"code":"200","data":{"message":"把亮度调到30%。"}}
CodecOpus: [encoderInit] / [decoderInit]
```

链路是：**眼镜采音 → Opus 编码 → 手机 App 收 → 手机调云端 ASR → 文本回眼镜上屏**。
大模型对话、翻译同理。眼镜只有麦克风、屏幕和一颗解码器。

**推论**：`我们的 App 长期占着 BLE` + `官方 App 干活` 这个组合在物理上不成立。
iOS 一个外设同一时刻只服务一个 central，我们连着，官方 App 就上不去，
眼镜等于被拔了脑子 —— 这就是「像没联网一样」的字面来源。

**所以 P8 的形态是「用完即断」**：连上 → 绑定 → 干活 → 立刻撒手。
界面上就是「会话让回」那块：自动断开开关 + 停留秒数 + 「立刻把眼镜交回官方 App」。

### 单变量实验（连上后日志里会自动打出来）

之前的实测把四件事一起做了（连 + 绑定 + 21 步 + 命令），分不清是哪一步搞坏的。
按这个顺序单独试，一次只动一个：

| 步 | 做什么 | 官方 App 的「会记」 | 结论 |
|---|---|---|---|
| ① | 只连接，一个字节都不写 | 也不听 | 光是占连接就会挤掉它，只能「用完即断」 |
| | | 正常 | 说明是写入搞坏的，继续 ② |
| ② | 按「首次绑定」 | 变坏 | 绑定这一步就有副作用 |
| | | 正常 | 继续 ③ |
| ③ | 按亮度按钮 | 变坏 | 业务命令会抢占会话 |
| | | 正常 | 那问题在 21 步初始化里 |

### 如果要做「取代官方 App」

那就不是移植了，是在 iOS 上重写一套手机侧后端：音频接收 → Opus 解码 →
云端 ASR → 大模型 → 文本回传上屏。工作量远大于前面所有阶段之和，
而且 ASR/大模型的钱得自己出。**当前不做**，先把「用完即断」这条最小闭环跑稳。


