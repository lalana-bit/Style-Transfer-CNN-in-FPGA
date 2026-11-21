# 使用Efinity复现

## 打开和构建

1. 安装Efinity 2026.1.132及配套RISC-V SDK，打开`hardware/ti60f225_oob.xml`，器件为Ti60F225/I3。
2. 工程已包含RTL、Sapphire/CSI IP、Interface Designer配置和SDC，无需手动重新加载IP。工作目录使用`hardware`，保持仓库内部相对位置。
3. 若未修改摄像头初始化或CPU代码，可直接使用随附软核RAM初始化文件。若修改了`hardware/software/cnn_weight_loader/src`，先按下一节重新编译软核。
4. 在Efinity依次执行Synthesis、Interface Designer、Place & Route、Generate Bitstream。
5. 核对本次资源及setup/hold WNS。随附构建为59684 XLR、245 RAM、119 DSP，WNS为+0.048/+0.024ns；重新构建的报告可能不同。

## 修改摄像头或软核

摄像头寄存器位于`hardware/software/cnn_weight_loader/src/camera_init.h`。修改后，在工程根目录执行：

`python hardware/tools/build_cpu.py`

脚本调用SDK编译应用，检查16KiB RAM及2KiB栈布局，并更新`hardware/ip/ip/cnn_boot_soc`中的四条RAM初始化文件。再回到Efinity完成上述四步构建。不能只改C文件就直接生成BIT。

工具位置默认`E:/Efinity`和`E:/Efinity_riscv`。其他安装位置可用`EFINITY_HOME`、`EFINITY_RISCV_HOME`或不纳入Git的`config/toolchains.local.json`设置。

## 下载与合并

临时测试：Programmer选择JTAG，下载`hardware/outflow/ti60f225_oob.bit`。仅当Flash里的权重/IN与该BIT内软核CRC表一致时，才能沿用原数据；地址相同不代表内容正确。

独立启动：在Efinity已生成本轮`hardware/outflow/ti60f225_oob.hex`后，从根目录执行：

`python hardware/tools/combine_flash.py`

它用Efinity官方合并器生成`firmware/FLASH_CNN_CAMERA_START_0x00000000.hex`，检查区域不重叠及合并后的完整字节，并更新`config/project.json`。Programmer选择SPI Active using JTAG Bridge，从地址0擦除、写入、校验，之后断电重启。脚本本身不会烧录。

四套风格的W/IN Flash地址依次为`0x400000/0x420000`、`0x440000/0x450000`、`0x460000/0x470000`、`0x480000/0x490000`；DDR每套间距128KiB。BIN不直接当作FPGA配置文件选择。

## 检查

`python tools/verify_project.py`检查工程源文件、BSP路径、软核RAM与BIN一致、四风格CRC、Flash区域内容、BIT/HEX哈希。它不运行综合或烧录，也不代表训练或板上验证完成。

## 更换一套风格的正确顺序

1. 核对网络标识、16层张量形状、15处IN/400通道、复制填充、上采样先后、55个扫描段和数值范围。当前原始训练导出的24960B包不能直接覆盖63296B运行包。
2. 同时更新`weights/runtime/<风格>/weights.bin`、`in.bin`、布局/MEM与来源元数据；保留四个槽位的地址约定。权重更换不要求改模型结构RTL，前提是上述契约完全一致。
3. 更新`hardware/software/cnn_weight_loader/src/cnn_style_banks.h`中该槽的W与IN CRC。编译软核，检查BIN、链接RAM/栈和四路IP初始化。
4. 重新运行Efinity构建；必须让新CRC表进入本轮BIT。只合并新权重和旧BIT，会导致旧CPU拒绝新CRC。
5. 运行合并脚本并逐区域检查四套W/IN和FPGA前缀，查看新时序报告，再烧录完整HEX并回读校验。改换其他模型后，不能继续沿用上轮的通过记录。

当前三套重训模型为星空、立体派、马赛克，抽象派保留原兼容测试包。最近一次已核对配置内全部16KiB CPU RAM、完成Flash全范围host回读校验并加载新BIT；实际画面和长期帧率需要实机观察。板卡当次检测为8MiB Winbond W25Q64（JEDEC EF6017），不能仅凭旧例程注释认定Flash型号。

## 平台边界

本文仅描述Ti60/Efinity复现。Xilinx等平台须重新生成器件配置、DDR/摄像头/显示IP和启动镜像，不能使用现有Efinity联合HEX直接启动；详见[移植指南](porting.md)。组件实现原理和稀疏流接口见[硬件详解](../hardware/README.md)。
