> 当前硬件重训交付包：星空、立体派、马赛克位于[deployed](deployed/README.md)，与当前硬件结构一致。

> 最新网络定义见`common/model_codec16_std_two_upfirst`。

# 四风格模型与训练边界

公共网络定义、量化器、打包器和整数参考统一放在 `common`。原训练模型和当前重训模型复用相同的基础实现，当前结构另有自己的 QAT 配置。现有检查点不重新训练、不重新解释成其他网络。中文显示名称与目录：星空`starry`、立体派`cubist`、抽象派`abstract`、马赛克`mosaic`。

| 风格 | 原训练检查点 | 原量化导出 | 原训练资料 |
|---|---|---|---|
| 星空 | FP32.pth、FP32_torchscript.pt、PTQ_calibrated.pth | 所选E012 FP32重新PTQ；有10个校准输入 | 配置/训练历史/选模证据，无完整原训练入口/原始数据 |
| 立体派 | FP32_best.pt、QAT_master.pt、INT8_tensor_bundle.pt | QAT配套定点数据 | 有原FP32 train.py与硬件QAT算子；原配对数据、SqueezeNet及完整QAT训练调度未随包提供 |
| 抽象派 | FP32_best.pt、QAT_master.pt、INT8_tensor_bundle.pt | QAT配套定点数据 | 已整合最终阶段训练入口、初始化及导出代码；Magenta教师、原始数据/VGG/运行环境按需准备 |
| 马赛克 | FP32_best.pt、QAT_master.pt、INT8_tensor_bundle.pt | QAT配套定点数据 | 有配置及损失函数记录，已整合完整纹理版入口、初始化、教师与导出代码；原始数据/VGG/CUDA需外部提供 |

## 推理与权重

`python tools/model_workflow.py verify`检查原训练模型的结构、数值范围及 24960 字节扫描包重建。当前重训模型另有[验证入口](deployed/README.md)。`infer`提供FP32、即时IN整数诊断和历史帧IN三个模式。`export`将已经量化的分项数据重新构成55段扫描并核对原字节；不把浮点QAT master误称为真实INT8张量。

完整PTQ复现入口为`python tools/export_in.py`（星空），输出只在`build/model_exports/starry`。其余三套当前以已交付INT8参数及配套IN/量化表进行确定性重打包；不能仅凭浮点检查点推断缺失的教师生成与历史QAT调度。当前 FPGA 读取根目录 `weights/runtime` 的运行包。重训模型目录还保留校验和独立推理需要的量化源数据。

## 可运行的配对微调

```powershell
python models/train.py --style abstract --content data/content/train --targets data/abstract/targets/train --output build/training/abstract --steps 1000 --batch 4 --device cpu
python models/train.py --style cubist --checkpoint models/cubist/checkpoints/QAT_master.pt --content data/content/train --targets data/cubist/targets/train --output build/training/cubist_qat --qat --steps 1000
```

输入和教师目标必须是同名256×144 PNG。通用入口从所选FP32/QAT检查点微调，采用明确记录的L1 RGB与梯度目标，保留同一16卷积/15 IN结构。QAT算子来自已交付立体派代码，IN统计、取整和位宽保持同一硬件协议。该入口已做一次FP32和QAT正反向/保存测试，但**不是原四种风格历史训练配方的复原，也不保证沿用原有视觉效果**。输出只写build，不能自动覆盖当前模型或烧录文件。

可使用`training/cubist/train.py`运行包内原FP32感知训练配方，数据布局见根`data/README.md`。它保留原损失，只将失效工作目录替换为工程内路径。额外需要requirements-training.txt、同名内容/教师图、SqueezeNet权重和风格参考图。

新训练检查点需要完整校准/导出、正乘数/INT20等范围检查、整数对照及硬件验证后才能替换部署包。训练完成不等于可以直接拼接FP32或QAT文件进Flash。

## 马赛克完整训练流程

实际入口为`models/training/mosaic/mosaic.py`，包含教师数据准备、原纹理损失、FP32/QAT循环与整数导出，配套教师及初始化已整合。数据集、VGG16和CUDA环境仍为外部依赖。其CPU接口/原检查点一致性已检查，完整训练需准备环境后运行；不将通用L1微调入口当作此实际训练配方。

## 抽象派完整训练流程

实际入口为`models/training/abstract/run.py`，详见[抽象派训练说明](training/abstract/README.md)。补齐Magenta 0.65教师目标、FP32 2400步→QAT 800步、最终阶段初始化和INT8导出；教师四文件约94MB，已压缩归档到工程外的project_backups/optional_training_assets，训练时按需解压或显式下载；交付FP32/QAT与当前抽象派检查点哈希一致。数据和VGG仍需外部准备。训练使用当前帧IN，未训练板端的历史帧统计更新过程。



