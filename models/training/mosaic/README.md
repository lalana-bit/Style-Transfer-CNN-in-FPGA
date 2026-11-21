# 马赛克实际训练与整数导出

这是用户提供的MOSAIC_TRAINING_SOURCE整合入口，保留其FP32→校准→QAT→整数导出流程、损失、教师和纹理阶段初始化。公共网络/量化/打包代码已与其他三风格逐字节核对，只在models/common保留一份。已交付FP32/QAT检查点与当前models/mosaic/checkpoints相同，不复制第二份。

```powershell
python models/training/mosaic/mosaic.py --config models/training/mosaic/config.example.json check
python models/training/mosaic/mosaic.py --config models/training/mosaic/config.example.json prepare
python models/training/mosaic/mosaic.py --config models/training/mosaic/config.example.json train --run mosaic_new
python models/training/mosaic/mosaic.py --config models/training/mosaic/config.example.json export --run mosaic_new
```

所有输出写入build/training/mosaic，不改现有weights或固件。配置相对路径以配置文件所在目录为准。teacher_mosaic.pth和mosaic.jpg位于models/mosaic/teacher；texture_v2_init.pt是实际纹理阶段初始化，不能用其他星空权重随意替代。交付FP32/QAT作为对照位于models/mosaic/checkpoints。

训练/prepare/selftest需要CUDA PyTorch、匹配torchvision、VGG16权重和真实训练数据。CPU可检查接口和做整数导出；当前PC Python为CPU版，未在本次整理执行完整训练。缺少数据/VGG/CUDA时check明确返回非零并说明缺项，不静默联网或改用其他数据。

默认训练3000步FP32+600步QAT，batch6，种子20261031；校准用64张训练图的0.5/1/1.5亮度，参数与损失权重写在config。新的训练不会恢复旧优化器和随机数状态，也不保证GPU训练逐比特复现。重新导出的启动IN系数受校准样本/版本影响；必须作为新候选单独验证，不能自动覆盖当前部署字节。

data/mosaic/arrays需包含prepared.json及train/val/test/external_test的*_content.npy、*_target.npy，uint8 N×3×144×256。原方案2560/144/144/4张，验证和测试至少101张。prepare还需要data/base_arrays中的基础npy和data/coco/train2014原图；VGG16放data/perceptual/vgg16-397923af.pth。外部数据未打包，详见data/README。
