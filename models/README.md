> 本目录保留原训练资料，不代表可直接将原训练权重用于当前FPGA网络。工程入口以根README为准；最新网络定义见`common/model_codec16_std_two_upfirst`。

# 四风格模型与训练边界

公共网络定义、量化器、打包器、整数参考仅保留在`common`一份，四个部署原包及新增抽象派训练包的公共源码已逐字节核对相同。现有检查点不重新训练、不重新解释成其他网络。中文显示名称与目录：星空`starry`、立体派`cubist`、抽象派`abstract`、马赛克`mosaic`。

| 风格 | 检查点 | 部署来源 | 原训练资料 |
|---|---|---|---|
| 星空 | FP32.pth、FP32_torchscript.pt、PTQ_calibrated.pth | 所选E012 FP32重新PTQ；有10个校准输入 | 配置/训练历史/选模证据，无完整原训练入口/原始数据 |
| 立体派 | FP32_best.pt、QAT_master.pt、INT8_tensor_bundle.pt | QAT配套定点数据 | 有原FP32 train.py与硬件QAT算子；原配对数据、SqueezeNet及完整QAT训练调度未随包提供 |
| 抽象派 | FP32_best.pt、QAT_master.pt、INT8_tensor_bundle.pt | QAT配套定点数据 | 已整合最终阶段训练入口、初始化及导出代码；Magenta教师、原始数据/VGG/运行环境按需准备 |
| 马赛克 | FP32_best.pt、QAT_master.pt、INT8_tensor_bundle.pt | QAT配套定点数据 | 有配置及损失函数记录，已整合完整纹理版入口、初始化、教师与导出代码；原始数据/VGG/CUDA需外部提供 |

## 推理与权重

`python tools/model_workflow.py verify`检查四套结构、数值范围及扫描重建。`infer`提供FP32、即时IN整数诊断和历史帧IN三个模式。`export`将已经量化的分项数据重新构成55段扫描并核对原字节；不把浮点QAT master误称为真实INT8张量。

完整PTQ复现入口为`python tools/export_in.py`（星空），输出只在`build/model_exports/starry`。其余三套当前以已交付INT8参数及配套IN/量化表进行确定性重打包；不能仅凭浮点检查点推断缺失的教师生成与历史QAT调度。所有正在使用的部署数据统一位于根`weights`，不在模型目录再保存重复BIN/MEM。

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

这里“完整”指最终阶段的代码和教师入口，不表示从随机初始化恢复全部历史训练，也不表示现已重新完成训练。当前部署权重和Flash保持不变。


