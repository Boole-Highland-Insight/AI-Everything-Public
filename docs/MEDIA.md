# 音视频扫描后端

音视频文件的后缀不能可靠说明内部轨道。`AIEMedia` 使用 AVFoundation 检查实际音轨、视频轨和抽帧结果；有可读音轨的文件，即使没有视频轨或画面解码失败，也可以走音频转写。

## 当前接入范围

- 独立 Swift 模块 `core/AIEMedia/`，运行于 macOS 14+。
- M4A / MP3 / WAV / AAC / FLAC 以及带可读音轨的 MP4 / MOV / M4V 已接入自动本机转写，默认使用 Whisper.cpp 多语言 small 模型；是否转写依据实际轨道，不依据扩展名。
- 首次需运行 `bash tools/setup_local_speech.sh`。脚本通过 Homebrew 安装 `whisper-cpp`，下载约 488 MB 的模型并校验固定 SHA-256。本次验证运行时为 1.8.3，模型保存在 `~/Library/Application Support/AI Everything/Speech/ggml-small.bin`。
- 本机推理不需要系统语音权限，不发送音频、不联网获取外部内容；模型缺失时提示安装，不自动下载或转用云端语音识别。
- 自动扫描复用已有转写语言，否则使用自动语言识别。显式命令可指定语言，并优先采用已安装的 Whisper；未安装时沿用 Apple 本机语音识别，可能需要系统语音权限与语言资源。
- 已设置 `--defer-scan` 的文件仍不进入自动队列。长视频也会自动转写，但任务可暂停并从已完成的 45 秒窗口续跑；显式命令仍可用于指定语言或立即启动。
- 视频画面按全时长均匀抽样，最多 8 帧。每帧运行 Apple Vision；已安装本机 Qwen3-VL 时，每帧另生成带时间锚点的画面描述。JPEG 只在内存中存在，不落盘。

## 显式运行与续跑

构建后执行：

```sh
"apps/macos/AIEPopup/build/AI Everything.app/Contents/MacOS/AIEPopup" \
  --transcribe-media /path/to/library recordings/lecture.mp4 en-US
```

最后一个参数是识别语言，例如 `en-US`、`zh-CN` 或 Whisper 的 `auto`。原文件不会改动。命令读取且只处理显式指定的资料根内文件；拒绝绝对相对路径、`..` 以及指向资料根外的文件。

命令输出状态、已完成秒数、总时长和数据库位置，不在终端打印完整转写。再次运行同一命令会跳过已完成的段，仅重试未完成或失败段。退出码 `0` 表示全部完成；`1` 表示部分完成、暂停、阻塞或错误；参数无效返回 `2`。

要暂停某文件的**自动**扫描（包括视频抽帧和 QuickScan）：

```sh
"apps/macos/AIEPopup/build/AI Everything.app/Contents/MacOS/AIEPopup" \
  --defer-scan /absolute/path/to/file.mp4
```

用 `--resume-scan` 恢复。该设置按本机用户保存；退出并重启应用后生效。文件仍参与文件名/路径检索，显式转写命令也不受该设置限制。命令不会取消已经开始的自动扫描。

## 分段、失败和存储

当前使用连续 **45 秒固定处理窗口**，最后一段保留实际尾部时长。它不是语义分句或 VAD 分段，窗口边界可能切断一句话，后续可增加重叠与去重。时间戳目前精确到处理窗口，不代表词级对齐。

1. 计算源文件 SHA-256，检查实际媒体轨道与时长。
2. 选择第一条音轨；多语言或解说轨道选择界面尚未实现。
3. 每次仅导出一段临时 M4A，用本机语音识别生成文字。导出超时为 60 秒，Apple 识别超时为 120 秒，Whisper 为 180 秒。Whisper 输入另转换为 16 kHz 单声道 PCM WAV，临时音频与文字在处理后删除。
4. 每段开始和完成时写入断点。某段失败后继续后面的段；磁盘保存失败立即停止。
5. 内容版本、识别语言或引擎版本改变时重新开始；处理中发现原文件改变则停止，旧转写不进入新文件版本的索引。
6. 临时音频目录权限为 `0700`，正常结束或抛错后清理。强制结束进程可能留下系统临时目录中的片段，系统清理前仍占用磁盘。

结果保存在原有 数据库分析记录的 `localScan.mediaTranscript` 中，包含：

- `sourceHash`、`parserVersion`、`model`、`locale`；
- `media`：时长、音视频轨道数量、可读画面标记、视频错误；
- `segments`：段编号、起止秒数、文字、状态、错误；
- 总状态：`running`、`ready`、`partial`、`paused`、`blocked`、`source_changed`。

重启时的 `running` 段视作未完成并重跑；完成段保持不变。自动扫描与显式命令共用 SQLite 工作租约避免重复转写，租约有效期 10 分钟，每次保存断点续期。后台本机扫描只合并自己负责的字段，保留转写断点、来源关联和云端标记。断点通过数据库事务更新；应用每 3 秒检查分析记录版本，显式命令的新结果会刷新到检索索引。不会创建 `scanner/`、锁文件或断点 JSON 文件。

## 索引和云端摘要边界

Gateway 导入已完成的转写段，即使整个文件仍是 `partial`。每段在 GRDB 中对应一个 `transcript` 块，保留 `startSeconds`、`endSeconds`；未完成段不作为正式文字索引。搜索片段显示时间范围，例如 `01:30–02:15`。

视频采样帧的原始 OCR 投影为 `frame_ocr` 直接证据；本机 8B 描述投影为 `video_segment_analysis` 弱证据，二者都保留约一秒的采样时间范围。模型描述不会冒充原始 OCR 或转写。带时间的音视频结果由内置 AVPlayer 打开并跳到命中起点；仅命中文件名或整片摘要时仍由系统默认应用打开。

### 从搜索结果播放 · 2026-10-13

- 带时间证据的结果在文件名旁显示可点击的播放时间；点击时间或双击结果会定位到命中起点，继续播放原文件，不生成裁剪副本、不在证据结束点强制停止。
- 播放窗口显示命中范围，可随时“回到命中位置”。空格和方向键交给原生播放器，Esc 关闭。切换文件、关闭窗口时取消旧定位并停止旧播放器，迟到回调不会恢复旧文件播放。
- 缺失、损坏、格式不支持、过期时间点和初始定位超时有明确提示及重试入口。超出当前媒体时长的时间点不会被默默改成其他位置。
- 播放窗口和结果右键菜单可交给默认播放器：QuickTime Player 使用 Apple Events 定位并播放（首次需 macOS 控制权限），IINA 使用带 `mpv_start` 的 URL。其他播放器仅标为“打开原文件”，不承诺跳转；QuickTime 自动化失败时可选择应用内定位或普通打开。
- 音频转写目前仍是 45 秒处理窗口，视频画面最多 8 个采样点。这轮改善了已有证据的打开体验，没有提高视频事件召回率，也没有增加词级对齐。

本机转写命令不会调用 Gemini、OpenRouter 或发送音频，也不设置 `cloudUpload`。正常自动扫描时，已有完整转写的 MP4 在抽帧失败时可以改用转写摘录生成 QuickScan 摘要；安装 Qwen3-VL 8B Instruct 后这一步也在本机完成，未安装时才沿用云端 API 配置。摘要覆盖范围标为 `transcript_excerpts`，不会声称全文逐段总结。独立音频同样复用完整转写，总预览预算 8,000 字符。以 `--local-scan-only` 启动可禁止自动云端扫描，同时保留本机 QuickScan、转写和索引。

## 验证

```sh
bash tools/check_media_backend.sh
bash tools/check_sidecar_concurrency.sh
bash tools/check_data_layer.sh
bash tools/check_gateway.sh
bash tools/check_media_playback.sh /tmp/aie-media-playback-layout
```

媒体检查使用合成的两秒音频验证纯音轨 MP4 检测和实际 AVFoundation 分段导出；用可控的模拟识别器验证 56 分钟计划、最多 8 点的视频采样、失败续跑、取消、本机能力缺失和内容改变。数据层/Gateway 验证帧与转写时间范围、证据等级、部分转写检索及旧版本失效。测试不读取用户媒体、不请求语音权限、不调用真实语音识别服务。

播放检查另生成四秒 H.264 视频并静音播放，核对实际播放位置、快速切换、重复定位、关闭取消、损坏/缺失文件、过期时间点、错误恢复及 IINA 参数编码；可选目录输出正常/失败界面截图。测试不打开外部播放器，QuickTime 权限拒绝和 IINA 实际调用仍需安装环境中的人工验收。AVPlayer 视频画面是独立合成图层，NSView 截图只用于检查窗口布局，不用来判断解码是否成功。

受限开发沙盒可能阻止系统音频编码器，导致 AVFoundation 导出报 `fmt?`；应在允许系统媒体服务的本机环境运行该合成测试，不能将其误判成所有用户音频损坏。实际语音识别准确率、长录音速度和不同语言仍需另做有授权的音频验收。

本机引擎参考：[Whisper.cpp](https://github.com/ggml-org/whisper.cpp)。模型文件与校验值来自维护者的 [GGML 模型仓库](https://huggingface.co/ggerganov/whisper.cpp)。
