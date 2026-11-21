# 外部训练数据位置

训练数据集和VGG/SqueezeNet感知网络权重未包含在工程中；马赛克教师已随模型整合，抽象派Magenta教师作为外部可选资产按需准备，不会自动下载，也不会把少量演示图当成完整训练集。

通用配对微调：

```text
data/content/train/*.png
data/content/val/*.png
data/starry/targets/train/*.png
data/cubist/targets/train/*.png
data/abstract/targets/train/*.png
data/mosaic/targets/train/*.png
```

内容和目标按文件名一一对应，物理分辨率必须256×144。通用入口的content/targets路径可通过命令行改变。原立体派训练还需要`data/cubist/targets/val`、`data/perceptual/squeezenet1_1-b8a52dc0.pth`和`data/styles/cubist.jpg`；未提供时会明确报缺失，不静默联网或替换教师。

`assets/images/source`里的两张图用于板端静图验证，`models/*/samples`是少量推理/校准样本；它们不代表完整原始训练集。

## 马赛克数组训练

实际训练入口`models/training/mosaic/mosaic.py`使用`data/mosaic/arrays/{train,val,test,external_test}_{content,target}.npy`和prepared.json。数组为uint8、N×3×144×256，验证/测试至少101张。准备数据还需data/base_arrays基础npy、data/coco/train2014 JPG以及data/perceptual/vgg16-397923af.pth；教师和风格图已随工程保存在models/mosaic/teacher。

## 抽象派数组训练

`models/training/abstract/run.py`使用`data/abstract/content/{train,val,test,external_test}_content.npy`，类型uint8、N×3×144×256、RGB。默认最终阶段均匀选1024张训练图；原始照片/数组没有随包提供。`prepare --images`可按固定种子从照片生成内容数组，居中裁剪到16:9。风格参考位于`models/abstract/teacher`，Magenta教师需按该目录README准备，VGG16需放入`data/perceptual/vgg16-397923af.pth`。生成目标与训练候选仅写`build/training/abstract`。
