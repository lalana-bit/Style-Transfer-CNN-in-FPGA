# 抽象派（Blue Glass）训练

此处是当前四风格工程中抽象派的实际训练、教师生成和INT8导出入口。它补齐最终阶段的训练来源；当前部署权重继续使用`weights/abstract`，不会因执行检查或训练自动替换。

## 网络与训练方法

- 输入/输出：256×144 RGB；16层卷积、15处IN、400个IN通道、15,619个可训练参数。
- 编码器：3→8前置卷积，8→16→32两级下采样；主体为5个32通道DW/PW残差块；解码器32→16，再上采样卷积16→8→3。
- 训练采用当前图像的InstanceNorm，硬件采用逐层轮换历史帧统计。没有将历史帧IN更新过程加入训练。
- Magenta原始教师在内容/风格特征之间以0.65强度插值生成目标，再进行2,400步FP32与800步QAT训练；不是将教师输出与原图按像素混合。
- 初始化为已有前期蓝玻璃训练的`blue_glass_init_fp32.pt`，因此复现的是最终训练阶段，不能称为从随机初始化恢复全部历史训练。
- 损失包含多尺度Gram/局部纹理、配色、内容/布局/轮廓、教师蒸馏、过量高频、TV和棋盘相位约束；具体系数见`configs/train.json`。

## 文件位置

| 内容 | 工程内位置 |
|---|---|
| 统一入口 | `models/training/abstract/run.py` |
| 配置 | `models/training/abstract/configs/train.json` |
| 训练、损失、教师及导出 | 本目录`src/blue_glass/` |
| 公共网络和整数参考 | `models/common/`，与原训练包逐字节一致，复用同一份 |
| 最终阶段初始化 | `models/abstract/checkpoints/blue_glass_init_fp32.pt` |
| 当前已交付FP32/QAT | `models/abstract/checkpoints/FP32_best.pt`、`QAT_master.pt`，与训练包交付检查点哈希一致 |
| Magenta教师与风格参考 | 教师按需准备到`models/abstract/teacher/magenta/`；风格图`art1.png`已提供 |
| 历史记录及源码来源 | 本目录`provenance/`；历史数值报告不代表整合后重新训练已通过 |

风格参考`art1.png`来自原仓库的已风格化输出，不能认定为已知原始画作。完整Magenta教师四文件约94MB，已压缩归档到工程外，不占主工程体积。仅重新生成教师目标时需要，按[教师准备说明](../../abstract/teacher/README.md)解压或显式下载；FPGA复现、现有模型推理和权重重打包不需要它。训练照片、VGG16、TensorFlow/PyTorch环境仍需自行准备，不自动下载。

## 准备及运行

所有命令在工程根目录运行。建议Python 3.11，训练与教师分别使用独立环境；依赖分别见本目录`requirements-train.txt`、`requirements-teacher.txt`。训练默认CUDA，CPU只适合接口调试。不要为复现FPGA硬件而安装这些训练依赖。

配置路径相对配置文件解析，默认使用工程内相对路径。准备：

1. 在`data/abstract/content/`提供`train_content.npy`、`val_content.npy`、`test_content.npy`、`external_test_content.npy`，类型为uint8、形状N×3×144×256、RGB顺序。也可用`prepare --images <目录>`从照片生成；它会居中裁剪到16:9。
2. 按需准备Magenta教师和`data/perceptual/vgg16-397923af.pth`，在配置中指定独立TensorFlow解释器`teacher_python`。
3. 教师目标写到`build/training/abstract/targets`，训练与导出写到`build/training/abstract/run`，不覆盖部署目录。开始新实验时设置新的输出目录。

```powershell
python models/training/abstract/run.py check
python models/training/abstract/run.py targets
python models/training/abstract/run.py train
python models/training/abstract/run.py export
```

`train --resume`继续保存的优化器/RNG状态；`validate`执行整数/浮点与历史IN诊断。`run_local.ps1`只是便捷入口，默认使用当前Python，不引用原作者电脑上的D盘环境。`tools/fetch_assets.py`保留显式下载入口，仅主动调用时联网。

`check`会列出缺失路径和CUDA状态，不能将命令退出成功理解为数据和环境均已齐备。整合已核对来源哈希、共享源码、交付检查点和网络接口；没有重新生成教师目标或完成训练，也未运行完整数值/上板验证。

## 导出与部署

导出得到24,960B、55段扫描BIN及3,200B IN表，必须配套使用。保留INT20偏置、正INT31乘数及shift 32～47等约束。导出目录只产生候选文件；要替换板端模型，仍需更新`weights/abstract`、CRC绑定和Flash数据HEX，再按工程复现流程打包。此次整合没有改变任何当前部署字节、风格槽位或RTL。
