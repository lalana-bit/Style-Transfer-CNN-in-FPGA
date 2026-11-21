# 当前重训模型

[星空](starry/README.md)、[立体派](cubist/README.md)和[马赛克](mosaic/README.md)是 2026-11-15 的当前结构重训模型。各风格目录保存 FP32/QAT 检查点、逐层 INT8/IN 参数、示例及验证记录。抽象派兼容权重见[运行权重说明](../../weights/README.md)。

在各风格目录运行 `python -B verify_package.py` 可以核对模型、权重与整数结果。运行 `infer_int8.py` 可以进行单帧和历史 IN 软件推理。两条命令使用仓库内的[共享参考实现](../common/model_codec16_std_two_upfirst/README.md)，依赖见各风格目录的 `requirements.txt`。

FPGA 实际加载四套 `weights/runtime` 权重。工程构建和替换权重见[Efinity 复现指南](../../docs/reproduce.md)。模型来源与部署哈希见[配置清单](../../config/deployed_models.json)，旧版构建数据见[原交付记录](reports/complete_build_receipt_20261115.json)。
