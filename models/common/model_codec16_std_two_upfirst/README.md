# 双标准残差、解码先上采样的训练模型

训练入口：`model.Codec16TwoStandardUpFirstIN`，输入 `[N,3,144,256]`，RGB浮点范围沿用原Codec16模型。前两个残差块是双标准3×3，后三个是DW/PW；编码器保持3→8→16→32。

解码顺序：最近邻×2 → 3×3 32→16及IN → 最近邻×2 → 3×3 16→8及IN → 3×3 8→3。两处解码IN分别统计128×72和256×144。总计16层卷积、15处IN，clamp复制填充。

`interface_contract.json`记录了实际前向hook得到的每层输入/输出形状。`save_checkpoint`和`load_checkpoint`使用独立architecture标识；旧网络检查点不会被误当成新结构的训练结果。

星空、立体派和马赛克已有配套重训权重和整数参考。四风格实际运行包用当前 55 段扫描格式，旧网络导出的 24960 字节包用于对应训练模型。[重训权重与推理入口](../../deployed/README.md)

硬件实验与资源限制见 `../../../hardware/README.md`。