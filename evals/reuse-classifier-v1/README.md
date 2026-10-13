# 咔哒分类评测集 v1

这是一个可复现的 100-instance 本地评测集，用于测量 `JunkClassifier` 和本机模型的分类准确率、漏召回与误报。全部文件均由生成脚本创建，不包含真实用户资料或个人信息。

## 分布

| 维度 | 数量 |
|---|---:|
| 文本 | 30 |
| 图片 | 25 |
| PDF | 25 |
| PPTX | 20 |
| 补全 | 25 |
| 优化 | 20 |
| 正常 | 45 |
| 精确重复 | 10（5 组） |

`completion` 表示内容存在明确缺失；`optimization` 表示内容完整但值得打磨；`none` 表示不应推荐；`duplicate` 表示同组文件字节完全一致。`cue` 区分显式线索、语义判断和精确哈希。

这个集合是平衡后的回归测试集，适合比较版本，不代表用户资料库中的自然类别比例。产品误报率还需要在真实文件的随机样本上单独统计。

本公开版提供合成实例与评分工具；私人环境的扫描记录和历史评测结果不随仓库发布。

## 文件

- `labels.jsonl`：100 条金标、理由、媒体类型、相对路径和 SHA-256。
- `instances/`：可直接送入扫描器的文件。
- `validate_dataset.py`：验证数量、分布、文件完整性和重复组哈希。
- `evaluate.py`：读取预测 JSONL，输出混淆矩阵、每类 precision、recall、miss 和误报。
- `generate.sh`：重新生成全部 100 个实例并立即验证。

## 计分

预测文件每行格式：

```json
{"id":"txt-completion-001","predicted_label":"completion"}
```

运行：

```bash
python3 evaluate.py predictions.jsonl
```

允许的预测标签为 `completion`、`optimization`、`none`、`duplicate`。

仓库已经包含全部 100 个合成实例。建立独立环境并验证现有数据集：

```bash
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r requirements.txt
python3 validate_dataset.py
```

重新生成全部实例并验证：

```bash
bash generate.sh
```
