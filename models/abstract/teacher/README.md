# 抽象派教师按需准备

`art1.png`是训练风格参考，已保留。Magenta教师四文件共94,135,836字节（约89.8 MiB），仅生成训练目标时使用，不参与FPGA综合、当前检查点推理、权重打包或板端运行。

教师已压缩保存在工程外的`E:/sth_interesting/elinx_project/project_backups/optional_training_assets/Magenta_TF1_256_v2.zip`，归档内四文件已逐一校验SHA256。桌面原训练包路径目前不存在，不作为恢复依赖。需要复训时，将ZIP解压到本目录，保持如下结构：

```text
magenta/
  saved_model.pb
  variables/
    variables.index
    variables.data-00000-of-00002
    variables.data-00001-of-00002
```

也可在工程根目录主动运行下面命令，按已记录来源和哈希下载教师及VGG16；该操作需要联网，VGG体积也较大，不属于常规硬件复现步骤：

```powershell
python models/training/abstract/tools/fetch_assets.py --config models/training/abstract/configs/train.json
```

原始四文件的大小与SHA256记录在`models/training/abstract/provenance/magenta_weights.json`。默认训练配置继续指向本目录的`magenta`，未准备时`run.py check`会列出该路径不存在。不要把“当前工程不含教师”理解为当前已训练权重缺失。
