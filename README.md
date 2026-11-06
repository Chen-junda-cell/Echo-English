# Echo English

把日常中文对话录下来 → 自动转成英文 → 挑出词块收藏 → 让 AI 复现当天的场景陪你练。

一个纯本地的 Android App（Flutter）。没有后端、没有账号体系，所有数据存在手机上的 SQLite 里，
语音识别 / 语音合成 / 大模型全部走你自己填的 API Key。

---

## 三个核心功能

**1. 录音 → 英文**

按住录音，说一段中文。App 会：

- 用讯飞听写（IAT）把语音转成中文文字
- 交给大模型做「口语清洗 + 英译 + 场景标注」，输出真实的英文说法（不是直译腔）
- 落库成「语音记录」，逐句对照展示中文原文 / 英文说法

**2. 挑词块**

翻译的同时，大模型会从这段对话里挑 5–12 个**值得背的词块**（chunk：搭配、短语、惯用句），
你在详情页一键收进当天的词块本。词块带 SM-2 风格的间隔复习：`ease` / `intervalDays` / `dueAt`，
答对间隔拉长、答错重来，到 7 天自动标「已掌握」。

**3. AI 情景复现（语音对话）**

进「复习」页点「开始情景」：

- AI 扮演当天场景里的另一个人，先开口说一句英文（自动朗读）
- 你**按住底栏说话**（微信那种交互），松手 → 讯飞听写 → DeepSeek 回复 → 讯飞 TTS 念出来
- 每轮限制 1–2 句、只在你真的说错时温柔纠一次
- 聊完点「结算」，AI 判定今天哪些词块用对了（`used`）、没用上（`missed`）、用错了（`wrong`），
  直接回写复习进度

也可以点「AIUI 全双工」走讯飞 AIUI 本地 VAD：说完自动断句、边听边答边播报，不用按住。

---

## 技术栈

| 层 | 选型 |
| --- | --- |
| UI | Flutter 3.47 / Material 3 / Riverpod |
| 本地存储 | sqflite（`sessions` / `utterances` / `chunks` / `chat_messages` / `review_reports` / `kv`） |
| 录音 | `record` 插件，PCM 16k / 16bit / 单声道（另外自己做了能量 VAD 切句） |
| 听写 | 讯飞 IAT WebSocket（`iat-api.xfyun.cn/v2/iat`），HMAC-SHA256 鉴权，`dwa=wpgs` 动态修正 |
| 合成 | 讯飞**超拟人**语音合成（`cbm01.cn-huabei-1.xf-yun.com/v1/private/mcd9m97e6`，MP3 24k）+ 经典流式合成（`tts-api.xfyun.cn/v2/tts`，PCM 16k）双通道 |
| 大模型 | 任意 OpenAI 兼容接口（默认 DeepSeek `deepseek-chat`） |
| 播放 | 自写原生 MethodChannel（Android `MediaPlayer`）+ WAV 包壳，没有引第三方播放插件 |
| 全双工 | 讯飞 AIUI Android SDK（`AIUI.jar` + `xrtcsdk.aar`），Kotlin 桥接给 Dart |

### 目录结构

```
lib/
  data/          db.dart（建表/迁移）  models.dart  dao.dart  settings.dart
  services/      xunfei_iat.dart   讯飞听写
                 xunfei_tts.dart   讯飞合成（双协议 + 双鉴权 + 串行锁）
                 llm.dart          OpenAI 兼容客户端 + 翻译流水线
                 aiui.dart         AIUI 全双工客户端
                 recorder.dart     录音（PCM 落盘 + 实时流）
                 audio_io.dart     播放 / WAV 读写 / 按句切片
                 pcm.dart          WAV 封装 + 能量 VAD
  ui/            providers.dart（所有 Riverpod provider）  theme.dart  home_shell.dart
    pages/       record_page    录音 + 流水线
                 library_page   日志（重命名 / 删除语音）
                 chunks_page    词块本
                 chunk_edit_page
                 session_detail_page  逐句对照 + 候选词块
                 chat_page      情景复现（文字 / 语音 / AIUI）
                 settings_page  三件套 + 模型 + 音色 + 偏好
android/app/src/main/kotlin/com/echoenglish/echo_english/
  MainActivity.kt
  aiui/AiuiBridge.kt          AIUI ↔ Dart 的 MethodChannel + EventChannel
  aiui/PcmStreamPlayer.kt     AudioTrack 流式播放
  audio/AudioPlayerBridge.kt  MediaPlayer 播放（修掉「文件播不出声」那个坑）
```

---

## 跑起来

### 1. 环境

- Flutter 3.47+ / Dart 3.13+
- JDK 21、Android SDK（compileSdk 35、build-tools 35.0.0、NDK 27）
- 项目 minSdk 23

### 2. 还原 AIUI 原生依赖（必需，只有 Android）

仓库里**故意不放**讯飞 AIUI 的二进制（闭源 + 约 60MB），需要自己从官方的 `Android_aiui_soft_*.zip` 还原：

```powershell
pwsh -File tools/setup_aiui.ps1 -SdkZip "C:\你的下载目录\Android_aiui_soft_6.7.0001.0007.zip"
```

脚本会补回 `android/app/libs`、`jniLibs`、`assets/{vad,ivw,cfg}`。
如果你不需要 AIUI 全双工，只想用「按住说话」那套在线方案，也可以跳过 ——
`AiuiClient.isSupported` 之外的代码会自己降级，只是「开启 AIUI 全双工」那个按钮会报错。

### 3. 填三个 Key

App 里「设置」页填写，或者参考 `.env` 思路手动灌入 `kv` 表：

| 项 | 在哪拿 |
| --- | --- |
| 大模型 BaseURL / APIKey / Model | 任意 OpenAI 兼容服务（DeepSeek / OpenAI / Moonshot / 通义 / 智谱都有预设按钮） |
| 讯飞 APPID / APIKey / APISecret | 控制台 → 语音识别（听写）+ 语音合成 |
| 超拟人 APIKey（选填） | 控制台那行 `ak-…`；填了就改用 `x-api-key` 请求头鉴权 |

> **APISecret 是 Base64，长度一定是 32 位**。少复制两个字符的表现是 `HMAC signature does not match`，
> 或者「合成超时、没有收到任何音频」—— 长度校验已经写进报错文案里了。

### 4. 构建

```powershell
flutter pub get
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

> `pubspec.yaml` 里有一条 `dependency_overrides: record_android: path: packages/record_android_pruned`。
> 原因是 `record 5.2.x` 的传递依赖会拉进 `record_linux`，而它在 Android-only 工程里会导致内核编译失败
> （`RecordLinux` 没实现 `startStream`）。`packages/record_android_pruned` 是去掉 `resolution: workspace`
> 的本地副本，用它顶掉 hosted 版本，`record_linux` 就不再参与编译了。

---

## 踩过的坑（都修好了，写在这免得再踩）

1. **`flutter analyze` 在中文路径下必崩** —— analysis server 的 LSP 通道解析 `%E8%8B%B1%E6%96%87%E8%BD%AF%E4%BB%B6` 出错，
   报 `FormatException: Unexpected end of input`。把工程镜像到纯 ASCII 路径再用 `dart analyze` 检查即可。
2. **`am start -d file://...` 播放私有目录音频没声音** —— `/data/user/0/<pkg>/cache` 别的进程读不到，
   但 `am` 返回码是 0，界面显示成功、实际静音。改成本进程 `MediaPlayer`（`AudioPlayerBridge.kt`）。
3. **超拟人合成的 `payload.text.text` 必须 base64** —— 塞明文报 `10163 … must be encode to base64 string`。
4. **超拟人偶尔不发结束位** —— 只认 `status==2` 会一直等到超时并把收到的音频丢掉。
   现在三重判定：`payload.audio.status==2` / `header.status==2` / 收到音频后 1.2 秒静默。
5. **TTS 客户端把 socket 放在实例字段上** —— 「自动朗读」和「点小喇叭」并发时后一次覆盖前一次，
   前一次的 `finally` 把后一次的 socket 关掉，表现为「完全没声音 + 报超时」。
   现在每次合成都是函数内局部状态 + 串行锁。
6. **AIUI 桥接里 `mapOf(...)` 混合类型** —— Kotlin 会推成 `Serializable`，必须显式 `mapOf<String, Any?>(...)`。
7. **`ref.read(chatRevisionProvider)` 不会触发刷新** —— 要 `ref.read(chatRevisionProvider.notifier).state++`，
   否则「开始情景」点了界面没反应（数据其实已经进库了）。

---

## 隐私

- 没有服务端，没有埋点，没有第三方统计。
- 对话、词块、音频全部在本地 SQLite + 应用私有目录。
- 网络只有三条：讯飞听写、讯飞合成、你自己填的大模型接口。
- 讯飞密钥写在 `android/app/src/main/assets/cfg/aiui_phone.cfg`（已 gitignore）和本地 `kv` 表里，
  **不要提交**。

---

## License

个人学习项目，代码随便看。讯飞 AIUI / 听写 / 合成的 SDK 与接口归科大讯飞所有，用之前自己去看他们的条款。
