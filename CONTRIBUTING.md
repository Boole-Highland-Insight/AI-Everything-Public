# 参与贡献

感谢你帮助改进 AI Everything。当前项目处于开发预览阶段，接口和本机数据结构仍可能变化。

## 开始之前

- 使用 macOS 14 或更新版本，以及包含 Swift 6.1 的 Xcode Command Line Tools／Xcode。
- Issue 和测试夹具不得包含私人文件、API Key、日志或本机数据库。
- 功能改动应附带能复现问题的最小测试；界面改动请说明人工验收步骤。

## 本机构建与检查

```sh
bash apps/macos/AIEPopup/build.sh
bash tools/check_gateway.sh
bash tools/check_reranking.sh
bash tools/check_desktop_behavior.sh
```

更多专项检查见 [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)。提交前运行：

```sh
python3 tools/check_repository.py
git diff --check
```

## 提交范围

只提交与问题直接相关的源码、文档和合成测试数据。不要提交 `build/`、`.app`、SQLite、模型文件、个人资料或密钥。第三方代码和资源必须保留其许可证与来源说明。
