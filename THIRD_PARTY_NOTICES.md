# 第三方说明

AI Everything 使用或参考以下开源项目。各项目仍适用其原始许可证。

- [GRDB.swift](https://github.com/groue/GRDB.swift)，MIT License。固定版本见 [`Package.resolved`](Package.resolved)，构建时许可证会复制进 App 资源目录。
- [llama.cpp](https://github.com/ggml-org/llama.cpp)，MIT License。构建时从固定提交编译 `llama-server`，随 App 分发于 `Contents/Resources/GemmaRuntime/`，许可证与提交号一并复制（见 [`tools/build_gemma_runtime.sh`](tools/build_gemma_runtime.sh)）。
- [EmbeddingGemma 2 GGUF](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF)，Apache-2.0（以模型仓库声明为准）。仓库不含模型权重；构建时下载并校验 SHA256 后随 App 分发，来源与许可证见 [`apps/macos/AIEPopup/Resources/EmbeddingGemma2-SOURCE.txt`](apps/macos/AIEPopup/Resources/EmbeddingGemma2-SOURCE.txt) 和 [`EmbeddingGemma2-APACHE-2.0.txt`](apps/macos/AIEPopup/Resources/EmbeddingGemma2-APACHE-2.0.txt)。
- [DigUp](https://github.com/ARahim3/DigUp)，MIT License。项目仅参考其索引交互和成本估算设计；保留的许可证见 [`apps/macos/AIEPopup/Resources/DigUp-LICENSE.txt`](apps/macos/AIEPopup/Resources/DigUp-LICENSE.txt)。

AI Everything 自身使用仓库根目录的 [`LICENSE`](LICENSE)。

- [BGE reranker v2 m3](https://huggingface.co/BAAI/bge-reranker-v2-m3)，Apache-2.0。固定原始模型提交 `953dc6f6f85a1b2dbfca4c34a2796e7dde08d41e`；安装包存储 float16 权重，与 Apple Silicon MPS 推理精度一致。来源及校验值记录于包内 `BGERuntime/SOURCE.json`，模型许可证随包附带。
- [Python Build Standalone](https://github.com/astral-sh/python-build-standalone)：固定 20261003 CPython 3.11.17 Apple Silicon 发行版，包含 CPython 及其原有许可证。
- PyTorch（BSD-3-Clause）、Transformers（Apache-2.0）及其依赖用于本地 BGE 推理。固定依赖见 `tools/bge-requirements.txt`；各依赖许可证和完整版本清单位于安装包的 Python `site-packages` 与 `BGERuntime/SOURCE.json`。
