# 立体派风格重训模型与验证

适配仓库当前的 [Efinity 工程](../../../hardware/ti60f225_oob.xml)。模型标识为 `stem8_enc16_32_stdres2_sep3_upfirst32_16_8_3_in15_v1`，输入和输出为 RGB 256×144，53955 个参数。

前两块为双标准 3×3 残差，后三块为 DW/PW 残差。解码器依次进行最近邻 ×2 与 32→16 的 3×3 卷积、最近邻 ×2 与 16→8 的 3×3 卷积、同尺寸 8→3 的 3×3 输出卷积。全网 16 层卷积，15 处 IN，共 400 个 IN 通道。两处解码 IN 分别统计 9216 和 36864 个像素。

## 包内文件

- checkpoints 包含新结构 FP32 与硬件 QAT 检查点。
- model 包含 INT8 张量、逐层量化参数、63296 字节扫描包、3200 字节 IN 参数和三种位宽 MEM。
- [共享参考实现](../../common/model_codec16_std_two_upfirst/README.md)包含模型、打包、量化和整数推理。
- examples 包含目标对比和四张外部示例。
- reports 包含训练记录、完整分辨率整数验证和最新 RTL 复查。
- [运行权重](../../../weights/runtime/cubist)供硬件加载。

本次使用原风格权重初始化，复用已有内容与教师目标完成新结构训练。

## 独立验证

在本包根目录运行以下命令。

```text
python -B verify_package.py
```

验证覆盖文件 SHA256、检查点、IN 参数、扫描包与实际部署字节、MEM、全分辨率 INT64 参考，以及两种历史 IN 调度各 60 帧的像素结果。两种调度与当前帧参考的固定样例逐像素一致，共用一张期望图。依赖 Python 3.11+、PyTorch、NumPy 和 Pillow。

## 推理

```text
python -B infer_int8.py --input model/seed_input.png --output result.png
python -B infer_int8.py --input model/seed_input.png --output history.png --stream-warmup --frames 60
```

输入经 EXIF 方向处理后居中裁剪为 16∶9 并缩放至 256×144。历史模式默认三组轮转，使用完整帧快照和帧后更新。CPU 服务时间和跨时钟域延迟需实机验证。

## 工程构建与烧录

软核、比特流、打包与权重替换步骤见[工程复现指南](../../../docs/reproduce.md)。

本风格槽位为 1，权重 Flash 地址为 `0x00440000`，IN 地址为 `0x00450000`。权重 CRC 为 `0x00168b51`，IN CRC 为 `0x9df9e772`。

## 训练交付验证记录

交付时使用 16×8 输入、真实重训权重和通用 RAM/DSP 模型运行两帧 RTL 仿真，并逐像素比对 RGB、IN 累加和与平方和。另有 144 张完整分辨率测试图用于 QAT/整数对比。[软件和 RTL 验证数据](reports/full_resolution_integer_validation.json)

[2026-11-15 原交付构建记录](../reports/complete_build_receipt_20261115.json)保留当时的 CPU、时序和 Flash 检查结果。当前工程的资源、时序及烧录状态见[硬件说明](../../../hardware/README.md)与[部署记录](../../../reports/deployment_update.json)。
