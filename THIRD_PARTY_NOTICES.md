# 第三方说明

AI Everything 使用或参考以下开源项目。各项目仍适用其原始许可证。

- [GRDB.swift](https://github.com/groue/GRDB.swift)，MIT License。固定版本见 [`Package.resolved`](Package.resolved)，构建时许可证会复制进 App 资源目录。
- [llama.cpp](https://github.com/ggml-org/llama.cpp)，MIT License。构建时从固定提交编译 `llama-server`，随 App 分发于 `Contents/Resources/GemmaRuntime/`，许可证与提交号一并复制（见 [`tools/build_gemma_runtime.sh`](tools/build_gemma_runtime.sh)）。
- [EmbeddingGemma 2 GGUF](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF)，Apache-2.0（以模型仓库声明为准）。仓库不含模型权重；构建时下载并校验 SHA256 后随 App 分发，来源与许可证见 [`apps/macos/AIEPopup/Resources/EmbeddingGemma2-SOURCE.txt`](apps/macos/AIEPopup/Resources/EmbeddingGemma2-SOURCE.txt) 和 [`EmbeddingGemma2-APACHE-2.0.txt`](apps/macos/AIEPopup/Resources/EmbeddingGemma2-APACHE-2.0.txt)。
- [DigUp](https://github.com/ARahim3/DigUp)，MIT License。项目仅参考其索引交互和成本估算设计；保留的许可证见 [`apps/macos/AIEPopup/Resources/DigUp-LICENSE.txt`](apps/macos/AIEPopup/Resources/DigUp-LICENSE.txt)。

AI Everything 自身使用仓库根目录的 [`LICENSE`](LICENSE)。
