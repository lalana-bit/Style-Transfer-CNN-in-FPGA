# 抽象派（Blue Glass）风格

对应部署槽2，PC命令使用`--style abstract`。部署BIN/MEM统一放根`weights/abstract`，当前FP32/QAT检查点在`checkpoints`，示例在`examples`与`samples`，原始部署记录在`provenance`。

实际训练与导出入口已整合到[训练目录](../training/abstract/README.md)，包含Magenta 0.65教师目标生成、FP32 2400步→QAT 800步、最终阶段初始化及55段扫描/IN导出。风格参考为`teacher/art1.png`；完整Magenta教师约94MB，已压缩归档到工程外，训练时按需解压到`teacher/magenta`，详见[教师准备说明](teacher/README.md)。

该训练包的交付FP32、QAT检查点与本目录现有文件哈希一致，公共网络代码与`models/common`逐字节一致，因此直接复用，不再保留重复副本。网络为256×144、16卷积/15 IN，训练当前图像IN，板端逐层轮换历史统计。

训练从已经学习过蓝玻璃风格的初始化继续最终阶段；原训练照片、VGG16与运行环境仍需另行准备。没有重新训练或替换现有权重，也不将历史验证报告视为此次整合后的运行验证。
