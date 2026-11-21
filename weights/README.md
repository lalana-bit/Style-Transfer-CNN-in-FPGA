<!--
 * @Author: koharu 3262447331@qq.com
 * @Date: 2026-11-21 19:39:43
 * @LastEditors: koharu 3262447331@qq.com
 * @LastEditTime: 2026-11-21 22:36:05
 * @FilePath: \Ti60_FourStyle_IN15\weights\README.md
 * @Description: 
 * 
 * Copyright (c) 2026 by ${git_name_email}, All Rights Reserved. 
-->
# 权重文件说明

`runtime/<风格>/weights.bin`与`in.bin`是当前硬件实际加载的数据，每套分别为63296B、3200B；地址清单见`style_banks.json`，Flash布局由`hardware/tools/combine_flash.py`检查。四个DDR槽间距为128KiB。

`starry`、`cubist`、`abstract`、`mosaic`根风格目录保存原训练网络的导出资料，原扫描包为24960B，不能直接替换当前63296B运行包。`tools/model_workflow.py`和`tools/export_in.py`处理这些原训练资料；它们不是当前修改后RTL的最终部署转换器。训练权重保留在`models`，具体网络差异见根README。

## 格式与更新入口

运行包的55段依次是16层W/A/B、五块残差LUT、输入LUT和输出LUT。IN文件每通道8B，存训练gamma/beta/epsilon；它不是A段bias/multiplier/shift的替代品。软核使用历史统计计算运行系数，再在层内帧边界换区。

具体地址、位宽、物理RAM组织和分发路径见[硬件说明第7～9节](../hardware/README.md)。更换权重必须同步CPU CRC表、重新生成BIT和联合HEX，步骤见[复现说明](../docs/reproduce.md)。跨平台可保留这套逻辑格式，但BIT/HEX容器及CPU/Flash偏移需要适配，见[移植指南](../docs/porting.md)。
