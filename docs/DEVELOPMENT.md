# 开发与验证

需要 macOS 14+、Swift 6.1+ 和 macOS SDK（Xcode 或 Command Line Tools）。

## 构建

```sh
bash apps/macos/AIEPopup/build.sh
open "apps/macos/AIEPopup/build/AI Everything.app"
```

首次构建下载锁定的 GRDB 7.11.1，后续复用 `apps/macos/AIEPopup/build/` 缓存。构建脚本只打包运行资源，不复制用户 Application Support。Release 会映射源路径并剥离调试符号，避免附带本机构建路径。

默认构建当前架构。Intel 交叉编译：

```sh
AIE_ARCH=x86_64 bash apps/macos/AIEPopup/build.sh
```

编译通过不等于 Intel 实机验收。本次下载版仅提供 arm64。

## 离线回归检查

这些检查使用临时合成资料；无需 Key，不调用云端模型。

```sh
bash tools/check_data_layer.sh
bash tools/check_gateway.sh
bash tools/check_api_configuration.sh
bash tools/check_reranking.sh
bash tools/check_desktop_behavior.sh
"apps/macos/AIEPopup/build/AI Everything.app/Contents/MacOS/AIEPopup" --verify-ai-tab
"apps/macos/AIEPopup/build/AI Everything.app/Contents/MacOS/AIEPopup" --verify-junk-classifier
"apps/macos/AIEPopup/build/AI Everything.app/Contents/MacOS/AIEPopup" --verify-reuse-pptx
```

回归检查不等于真实资料的搜索准确率评估。`tools/evaluate_search.sh` 用于自己的资料库，运行前必须准备与所选资料一致的用例；公开仓库不包含私人资料测试集。分享评测结果前删除文件名、片段和私人路径。

## 演示素材

`--export-onboarding-demo` 使用真实 SwiftUI 视图和合成文件，无需个人数据库或 Key。编码脚本输出 8 秒静音 MP4、GIF 和 PNG。

```sh
"apps/macos/AIEPopup/build/AI Everything.app/Contents/MacOS/AIEPopup" --export-onboarding-demo /tmp/aie-demo-frames
xcrun swiftc -parse-as-library tools/make_onboarding_demo.swift -o /tmp/aie-demo-encoder
/tmp/aie-demo-encoder /tmp/aie-demo-frames /tmp/aie-demo-media
```

演示表示交互方式，经过剪辑，不用于证明模型速度或真实生成质量。

## 打包

明确标记的未公证 GitHub 预览版 DMG：

```sh
AIE_RELEASE=0.1.0-preview.1 bash tools/package_macos_preview.sh
```

输出位于 `apps/macos/AIEPopup/build/releases/`，包含 DMG 和 `SHA256SUMS`。此流程使用 ad-hoc 签名，不经过 Apple 公证，必须在下载说明中告知用户。

有 Developer ID 证书和已保存的公证配置后，可使用严格签名 / 公证流程：

```sh
AIE_SIGN_IDENTITY='Developer ID Application: YOUR TEAM' \
AIE_NOTARY_PROFILE='YOUR_NOTARY_PROFILE' \
bash tools/package_macos_release.sh
```

私钥、证书、notary 密码与访问令牌不得放入仓库。

## 提交前

```sh
python3 tools/check_repository.py
git diff --check
```

密钥扫描只是检查的一部分；还需人工查看文档、素材、夹具、归档成员和提交元数据。不要上传本机数据库、API Key、真实用户截图、模型缓存或个人日志。调试日志默认关闭，只有设置 `AIE_DEBUG_LOGS=1` 才启用。
