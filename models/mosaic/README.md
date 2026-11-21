# 马赛克风格

对应部署槽3，PC命令使用`--style mosaic`。检查点在checkpoints，推理样本在samples，训练来源与配置在provenance；部署BIN/MEM统一放根weights/mosaic。

公共模型实现只保留在models/common，推理、重打包和新配对微调用根tools/model_workflow.py与models/train.py。完整原始训练数据未随包提供，原训练入口可用性见models/README，不将新微调脚本描述为历史配方。
