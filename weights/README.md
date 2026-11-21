# 权重文件说明

`runtime/<风格>/weights.bin`与`in.bin`是当前硬件实际加载的数据，每套分别为63296B、3200B；地址清单见`style_banks.json`，Flash布局由`hardware/tools/combine_flash.py`检查。四个DDR槽间距为128KiB。

`starry`、`cubist`、`abstract`、`mosaic`根风格目录保存原训练网络的导出资料，原扫描包为24960B，不能直接替换当前63296B运行包。`tools/model_workflow.py`和`tools/export_in.py`处理这些原训练资料；它们不是当前修改后RTL的最终部署转换器。训练权重保留在`models`，具体网络差异见根README。
