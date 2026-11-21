#ifndef CNN_CAMERA_INIT_H
#define CNN_CAMERA_INIT_H
#include <stdint.h>

/* Sequencing/retry follows the reference Ti60_hdmi_riscv firmware.
 * Register accesses use the already-generated Sapphire I2C0 (SDK i2c.h map).
 * No unbounded SDK blocking helpers are used: every poll has a CLINT timeout.
 */
#ifndef CAM_I2C_READ
#define CAM_I2C_READ(o) (*(volatile uint32_t *)(uintptr_t)(SYSTEM_I2C_0_IO_CTRL+(o)))
#define CAM_I2C_WRITE(o,v) (*(volatile uint32_t *)(uintptr_t)(SYSTEM_I2C_0_IO_CTRL+(o))=(v))
#define CAM_NOW() clint_getTimeLow(BSP_CLINT)
#define CAM_DELAY_US(us) bsp_uDelay(us)
#endif
#define CAMERA_CONTROL_REG 0x1cu
#define CAMERA_CNN_ENABLED (1u<<8)
#define CAM_TX_DATA 0x00u
#define CAM_TX_ACK 0x04u
#define CAM_RX_DATA 0x08u
#define CAM_RX_ACK 0x0cu
#define CAM_MASTER_STATUS 0x40u
#define CAM_VALID 0x100u
#define CAM_START 0x10u
#define CAM_STOP 0x20u
#define CAM_DROP 0x40u
#define CAM_RECOVER 0x80u
#define CAM_TIMEOUT (SYSTEM_CLINT_HZ/100u)

/* Derived from the v6-3 active 1080p30 table. Bit24=verified read. */
/* 720p60: retain the known-working 0x301F=0x10 / 315Mb/s PLL/PHY table.
 * Sensor ROI output, not a post-CSI crop: 1280x720, VTS=750.
 * Nominal line time 22.222us => 60fps; board validation is still required.
 * Y scan [359,1088] is 730 rows; output offset Y=5 gives 720 active rows.
 * Relative to the old ROI, X shifts +320 and Y +180: Bayer phase is preserved.
 * E=1472 half-lines <= 2*750-11=1489. Analog gain stays 4.043x.
 * The complete previous 1080p table below is retained as line comments.
 */
// ---- Previous working 1080p initialization (inactive, preserved) ----
// static const uint32_t camera_sequence[] = {
//  0x013107cdu,
//  0x0131086bu,
//  0x00010000u,
//  0x0036e980u,
//  0x0037f980u,
//  0x00301f10u,
//  0x00305821u,
//  0x00305953u,
//  0x00305a40u,
//  0x00325000u,
//  0x0033010cu,
//  0x00330450u,
//  0x00330500u,
//  0x00330650u,
//  0x00330704u,
//  0x0033080au,
//  0x00330960u,
//  0x00330bc8u,
//  0x00330d08u,
//  0x00330e38u,
//  0x00331e41u,
//  0x00331f51u,
//  0x00333310u,
//  0x00333440u,
//  0x0033645eu,
//  0x00338ee2u,
//  0x00338f80u,
//  0x00339008u,
//  0x00339118u,
//  0x003392b8u,
//  0x00339312u,
//  0x00339414u,
//  0x00339510u,
//  0x00339688u,
//  0x00339798u,
//  0x003398b8u,
//  0x00339910u,
//  0x00339a16u,
//  0x00339b1cu,
//  0x00339c40u,
//  0x0033ac0au,
//  0x0033ad10u,
//  0x0033ae4fu,
//  0x0033af5eu,
//  0x0033b250u,
//  0x0033b310u,
//  0x0033f800u,
//  0x0033f950u,
//  0x0033fa00u,
//  0x0033fb50u,
//  0x0033fc48u,
//  0x0033fd78u,
//  0x00349f03u,
//  0x0034a640u,
//  0x0034a758u,
//  0x0034a810u,
//  0x0034a910u,
//  0x0034f878u,
//  0x0034f910u,
//  0x00363344u,
//  0x00363b8fu,
//  0x00363c02u,
//  0x00364108u,
//  0x00365420u,
//  0x003674c2u,
//  0x003675b4u,
//  0x00367688u,
//  0x00367c88u,
//  0x00367db8u,
//  0x00369034u,
//  0x00369144u,
//  0x00369254u,
//  0x00369388u,
//  0x00369498u,
//  0x00369680u,
//  0x00369783u,
//  0x00369881u,
//  0x00369981u,
//  0x00369a84u,
//  0x00369b82u,
//  0x0036a280u,
//  0x0036a388u,
//  0x0036a4f8u,
//  0x0036a5b8u,
//  0x0036a698u,
//  0x0036d015u,
//  0x0036ea23u,
//  0x0036eb0du,
//  0x0036ec65u,
//  0x0036ed18u,
//  0x00370f01u,
//  0x00372203u,
//  0x00372492u,
//  0x00372714u,
//  0x0037b017u,
//  0x0037b19bu,
//  0x0037b29bu,
//  0x0037b388u,
//  0x0037b4b8u,
//  0x0037fa23u,
//  0x0037fb54u,
//  0x0037fc21u,
//  0x0037fd1cu,
//  0x00391f41u,
//  0x003926e0u,
//  0x00393380u,
//  0x003934f8u,
//  0x00393500u,
//  0x00393645u,
//  0x00393766u,
//  0x00393866u,
//  0x00393900u,
//  0x00393a03u,
//  0x00393b00u,
//  0x00393c00u,
//  0x00393d02u,
//  0x00393e80u,
//  /* 长曝光：E = ((3E00 & 0x0F)<<12) | (3E01<<4) | (3E02>>4)。
//   * E 的单位为半行；曝光时间 = E * 行时间 / 2。当前 E=0x08A0，即 1104 行。
//   * 修改曝光后，也要同步修改后面相同地址的读回校验期望值。 */
//  0x003e0000u, // 写入 0x3E00：长曝光 E[15:12]，使用本寄存器 bit[3:0]
//  0x003e0189u, // 写入 0x3E01：长曝光 E[11:4]，使用本寄存器 bit[7:0]
//  0x003e0200u, // 写入 0x3E02：长曝光 E[3:0]，使用本寄存器 bit[7:4]；bit[3:0] 不属于曝光值
//  0x003e1600u,
//  0x003e17c5u,
//  0x003e1800u,
//  0x003e19c5u,
//  0x00450920u,
//  0x00450d0bu,
//  0x00578076u,
//  0x0057840au,
//  0x00578504u,
//  0x0057870au,
//  0x0057880au,
//  0x00578908u,
//  0x00578a0au,
//  0x00578b0au,
//  0x00578c08u,
//  0x00578d40u,
//  0x00579008u,
//  0x00579104u,
//  0x00579204u,
//  0x00579308u,
//  0x00579404u,
//  0x00579504u,
//  0x0057ac00u,
//  0x0057ad00u,
//  0x0036e953u,
//  0x0037f953u,
//  /* 分辨率窗口：3200~3207 为阵列读出范围；3208~320B 为最终输出宽高。
//   * 3210~3213 为输出窗口起始偏移；阵列窗口大小不能直接当作输出分辨率。 */
//  0x00320000u, // 写入 0x3200：阵列读出窗口 X 起点，高字节
//  0x00320100u, // 写入 0x3201：阵列读出窗口 X 起点，低字节
//  0x00320200u, // 写入 0x3202：阵列读出窗口 Y 起点，高字节
//  0x003203b3u, // 写入 0x3203：阵列读出窗口 Y 起点，低字节
//  0x0032040au, // 写入 0x3204：阵列读出窗口 X 终点，高字节
//  0x00320507u, // 写入 0x3205：阵列读出窗口 X 终点，低字节
//  0x00320604u, // 写入 0x3206：阵列读出窗口 Y 终点，高字节
//  0x003207f4u, // 写入 0x3207：阵列读出窗口 Y 终点，低字节
//  0x00320807u, // 写入 0x3208：输出图像宽度，高字节
//  0x00320980u, // 写入 0x3209：输出图像宽度，低字节；与 0x3208 组成 0x0780 = 1920 像素
//  0x00320a04u, // 写入 0x320A：输出图像高度，高字节
//  0x00320b38u, // 写入 0x320B：输出图像高度，低字节；与 0x320A 组成 0x0438 = 1080 行
//  0x00321001u, // 写入 0x3210：输出窗口列起始偏移，高字节
//  0x00321144u, // 写入 0x3211：输出窗口列起始偏移，低字节；当前 0x0144 = 324
//  0x00321200u, // 写入 0x3212：输出窗口行起始偏移，高字节
//  0x00321305u, // 写入 0x3213：输出窗口行起始偏移，低字节；当前 0x0005 = 5
//  // Previous 3.032x write: 0x003e0880u,
//  0x003e0881u, // write: 3E08=0x81, 3E09=0x2A: 4.043x analog gain
//  // Previous write: 0x003e092au, // ANA fine gain 0x2A: about 2.021x total
//  // Previous 3.032x write: 0x003e093fu,
//  0x003e092au, // write: 3E08=0x81, 3E09=0x2A: 4.043x analog gain
//  0x00322166u,
//  /* 帧长：VTS = ((320E & 0x7F)<<8) | 320F，单位为行。
//   * VTS 不等于输出图像高度，包含有效读出及消隐等行。 */
//  0x00320e04u, // 写入 0x320E：帧长 VTS 高 7 位，使用 bit[6:0]
//  0x00320f54u, // 写入 0x320F：帧长 VTS 低字节；与 0x320E 组成 0x0454 = 1108 行
//  0x004501a4u,
//  
//  /* 以下为关键配置的读回校验；0x01 开头的 DD 是期望读回值。
//   * 改动前面的曝光、帧长、输出宽高或起始偏移时，同步修改对应期望值。 */
//  0x01320807u, // 读回校验 0x3208：输出图像宽度，高字节
//  0x01320980u, // 读回校验 0x3209：输出图像宽度，低字节；与 0x3208 组成 0x0780 = 1920 像素
//  0x01320a04u, // 读回校验 0x320A：输出图像高度，高字节
//  0x01320b38u, // 读回校验 0x320B：输出图像高度，低字节；与 0x320A 组成 0x0438 = 1080 行
//  0x01321001u, // 读回校验 0x3210：输出窗口列起始偏移，高字节
//  0x01321144u, // 读回校验 0x3211：输出窗口列起始偏移，低字节；当前 0x0144 = 324
//  0x01321200u, // 读回校验 0x3212：输出窗口行起始偏移，高字节
//  0x01321305u, // 读回校验 0x3213：输出窗口行起始偏移，低字节；当前 0x0005 = 5
//  0x01320e04u, // 读回校验 0x320E：帧长 VTS 高 7 位，使用 bit[6:0]
//  0x01320f54u, // 读回校验 0x320F：帧长 VTS 低字节；与 0x320E 组成 0x0454 = 1108 行
//  0x013e0000u, // 读回校验 0x3E00：长曝光 E[15:12]，使用本寄存器 bit[3:0]
//  0x013e0189u, // 读回校验 0x3E01：长曝光 E[11:4]，使用本寄存器 bit[7:0]
//  0x013e0200u, // 读回校验 0x3E02：长曝光 E[3:0]，使用本寄存器 bit[7:4]；bit[3:0] 不属于曝光值
//  // Previous 3.032x readback: 0x013e0880u,
//  0x013e0881u, // readback: 3E08=0x81, 3E09=0x2A: 4.043x analog gain
//  // Previous readback: 0x013e092au, // ANA fine gain 0x2A: about 2.021x total
//  // Previous 3.032x readback: 0x013e093fu,
//  0x013e092au, // readback: 3E08=0x81, 3E09=0x2A: 4.043x analog gain
//  0x01322166u,
//  0x014501a4u,
//  0x01010000u,
//  0x00010001u,
//  0x01010001u,
// };

static const uint32_t camera_sequence[] = {
 0x013107cdu,
 0x0131086bu,
 0x00010000u,
 0x0036e980u,
 0x0037f980u,
 0x00301f10u,
 0x00305821u,
 0x00305953u,
 0x00305a40u,
 0x00325000u,
 0x0033010cu,
 0x00330450u,
 0x00330500u,
 0x00330650u,
 0x00330704u,
 0x0033080au,
 0x00330960u,
 0x00330bc8u,
 0x00330d08u,
 0x00330e38u,
 0x00331e41u,
 0x00331f51u,
 0x00333310u,
 0x00333440u,
 0x0033645eu,
 0x00338ee2u,
 0x00338f80u,
 0x00339008u,
 0x00339118u,
 0x003392b8u,
 0x00339312u,
 0x00339414u,
 0x00339510u,
 0x00339688u,
 0x00339798u,
 0x003398b8u,
 0x00339910u,
 0x00339a16u,
 0x00339b1cu,
 0x00339c40u,
 0x0033ac0au,
 0x0033ad10u,
 0x0033ae4fu,
 0x0033af5eu,
 0x0033b250u,
 0x0033b310u,
 0x0033f800u,
 0x0033f950u,
 0x0033fa00u,
 0x0033fb50u,
 0x0033fc48u,
 0x0033fd78u,
 0x00349f03u,
 0x0034a640u,
 0x0034a758u,
 0x0034a810u,
 0x0034a910u,
 0x0034f878u,
 0x0034f910u,
 0x00363344u,
 0x00363b8fu,
 0x00363c02u,
 0x00364108u,
 0x00365420u,
 0x003674c2u,
 0x003675b4u,
 0x00367688u,
 0x00367c88u,
 0x00367db8u,
 0x00369034u,
 0x00369144u,
 0x00369254u,
 0x00369388u,
 0x00369498u,
 0x00369680u,
 0x00369783u,
 0x00369881u,
 0x00369981u,
 0x00369a84u,
 0x00369b82u,
 0x0036a280u,
 0x0036a388u,
 0x0036a4f8u,
 0x0036a5b8u,
 0x0036a698u,
 0x0036d015u,
 0x0036ea23u,
 0x0036eb0du,
 0x0036ec65u,
 0x0036ed18u,
 0x00370f01u,
 0x00372203u,
 0x00372492u,
 0x00372714u,
 0x0037b017u,
 0x0037b19bu,
 0x0037b29bu,
 0x0037b388u,
 0x0037b4b8u,
 0x0037fa23u,
 0x0037fb54u,
 0x0037fc21u,
 0x0037fd1cu,
 0x00391f41u,
 0x003926e0u,
 0x00393380u,
 0x003934f8u,
 0x00393500u,
 0x00393645u,
 0x00393766u,
 0x00393866u,
 0x00393900u,
 0x00393a03u,
 0x00393b00u,
 0x00393c00u,
 0x00393d02u,
 0x00393e80u,
 /* 长曝光：E = ((3E00 & 0x0F)<<12) | (3E01<<4) | (3E02>>4)。
  * E 的单位为半行；曝光时间 = E * 行时间 / 2。当前 E=0x05C0，即 736 行，约 16.36ms（行时间22.222us）。
  * 修改曝光后，也要同步修改后面相同地址的读回校验期望值。 */
 0x003e0000u, // 写入 0x3E00：长曝光 E[15:12]，使用本寄存器 bit[3:0]
 // Previous 720p60: 0x003e015cu, // write: E = 0x05C0 = 1472 half-lines = 736 lines
 // Previous 720p30: 0x003e01b8u, // write: E=0x0B80=2944 half-lines=1472 lines, nominal 32.711ms
 0x003e015cu, // write: E=0x05C0=1472 half-lines=736 lines, nominal 16.356ms
 0x003e0200u, // 写入 0x3E02：长曝光 E[3:0]，使用本寄存器 bit[7:4]；bit[3:0] 不属于曝光值
 0x003e1600u,
 0x003e17c5u,
 0x003e1800u,
 0x003e19c5u,
 0x00450920u,
 0x00450d0bu,
 0x00578076u,
 0x0057840au,
 0x00578504u,
 0x0057870au,
 0x0057880au,
 0x00578908u,
 0x00578a0au,
 0x00578b0au,
 0x00578c08u,
 0x00578d40u,
 0x00579008u,
 0x00579104u,
 0x00579204u,
 0x00579308u,
 0x00579404u,
 0x00579504u,
 0x0057ac00u,
 0x0057ad00u,
 0x0036e953u,
 0x0037f953u,
 /* 分辨率窗口：3200~3207 为阵列读出范围；3208~320B 为最终输出宽高。
  * 3210~3213 为输出窗口起始偏移；阵列窗口大小不能直接当作输出分辨率。 */
 0x00320000u, // 写入 0x3200：阵列读出窗口 X 起点，高字节
 0x00320100u, // 写入 0x3201：阵列读出窗口 X 起点，低字节
 0x00320201u, // write: array Y start high
 0x00320367u, // write: array Y start = 0x0167 = 359
 0x0032040au, // 写入 0x3204：阵列读出窗口 X 终点，高字节
 0x00320507u, // 写入 0x3205：阵列读出窗口 X 终点，低字节
 0x00320604u, // 写入 0x3206：阵列读出窗口 Y 终点，高字节
 0x00320740u, // write: array Y end = 0x0440 = 1088 (730 scanned rows)
 0x00320805u, // write: output width high
 0x00320900u, // write: output width = 0x0500 = 1280
 0x00320a02u, // write: output height high
 0x00320bd0u, // write: output height = 0x02D0 = 720
 0x00321002u, // write: horizontal output offset high
 0x00321184u, // write: horizontal offset = 0x0284 = 644
 0x00321200u, // 写入 0x3212：输出窗口行起始偏移，高字节
 0x00321305u, // 写入 0x3213：输出窗口行起始偏移，低字节；当前 0x0005 = 5
 // Previous 3.032x write: 0x003e0880u,
 // 调低增益前：0x003e0881u, // write: 3E08=0x81, 3E09=0x2A: 4.043x analog gain
 // 修改前：0x003e0880u, // 写入 3E08=0x80；与另一增益寄存器配合，模拟增益约 3.032 倍
 0x003e0881u, // 写入：模拟增益粗调；与3E09=2A组成手册4.043倍档，最接近4.00倍
 // Previous write: 0x003e092au, // ANA fine gain 0x2A: about 2.021x total
 // Previous 3.032x write: 0x003e093fu,
 // 调低增益前：0x003e092au, // write: 3E08=0x81, 3E09=0x2A: 4.043x analog gain
 // 修改前：0x003e093fu, // 写入 3E09=0x3F；与另一增益寄存器配合，模拟增益约 3.032 倍
 0x003e092au, // 写入：模拟增益细调；与3E08=81组成手册4.043倍档
 // 修改前：0x00322166u,
 0x00322160u, // 写入：bit[2:1]=00取消水平镜像，bit[6:5]=11保持原垂直翻转
 /* 帧长：VTS = ((320E & 0x7F)<<8) | 320F，单位为行。
  * VTS 不等于输出图像高度，包含有效读出及消隐等行。 */
 // Previous 720p60: 0x00320e02u, // write: VTS high
 // Previous 720p30: 0x00320e05u, // write: VTS high; 0x05DC=1500 lines, nominal 30fps
 0x00320e02u, // write: VTS high; 0x02EE=750 lines, nominal 60fps
 // Previous 720p60: 0x00320feeu, // write: VTS = 0x02EE = 750 lines
 // Previous 720p30: 0x00320fdcu, // write: VTS low; 0x05DC=1500 lines, nominal 30fps
 0x00320feeu, // write: VTS low; 0x02EE=750 lines, nominal 60fps
 0x004501a4u,
 
 /* 以下为关键配置的读回校验；0x01 开头的 DD 是期望读回值。
  * 改动前面的曝光、帧长、输出宽高或起始偏移时，同步修改对应期望值。 */
 0x01320805u, // readback: output width high
 0x01320900u, // readback: output width = 0x0500 = 1280
 0x01320a02u, // readback: output height high
 0x01320bd0u, // readback: output height = 0x02D0 = 720
 0x01321002u, // readback: horizontal output offset high
 0x01321184u, // readback: horizontal offset = 0x0284 = 644
 0x01321200u, // 读回校验 0x3212：输出窗口行起始偏移，高字节
 0x01321305u, // 读回校验 0x3213：输出窗口行起始偏移，低字节；当前 0x0005 = 5
 // Previous 720p60: 0x01320e02u, // readback: VTS high
 // Previous 720p30: 0x01320e05u, // readback: VTS high; 0x05DC=1500 lines, nominal 30fps
 0x01320e02u, // readback: VTS high; 0x02EE=750 lines, nominal 60fps
 // Previous 720p60: 0x01320feeu, // readback: VTS = 0x02EE = 750 lines
 // Previous 720p30: 0x01320fdcu, // readback: VTS low; 0x05DC=1500 lines, nominal 30fps
 0x01320feeu, // readback: VTS low; 0x02EE=750 lines, nominal 60fps
 0x013e0000u, // 读回校验 0x3E00：长曝光 E[15:12]，使用本寄存器 bit[3:0]
 // Previous 720p60: 0x013e015cu, // readback: E = 0x05C0 = 1472 half-lines = 736 lines
 // Previous 720p30: 0x013e01b8u, // readback: E=0x0B80=2944 half-lines=1472 lines, nominal 32.711ms
 0x013e015cu, // readback: E=0x05C0=1472 half-lines=736 lines, nominal 16.356ms
 0x013e0200u, // 读回校验 0x3E02：长曝光 E[3:0]，使用本寄存器 bit[7:4]；bit[3:0] 不属于曝光值
 // Previous 3.032x readback: 0x013e0880u,
 // 调低增益前：0x013e0881u, // readback: 3E08=0x81, 3E09=0x2A: 4.043x analog gain
 // 修改前：0x013e0880u, // 读回校验 3E08=0x80；与另一增益寄存器配合，模拟增益约 3.032 倍
 0x013e0881u, // 读回校验：模拟增益粗调；与3E09=2A组成手册4.043倍档，最接近4.00倍
 // Previous readback: 0x013e092au, // ANA fine gain 0x2A: about 2.021x total
 // Previous 3.032x readback: 0x013e093fu,
 // 调低增益前：0x013e092au, // readback: 3E08=0x81, 3E09=0x2A: 4.043x analog gain
 // 修改前：0x013e093fu, // 读回校验 3E09=0x3F；与另一增益寄存器配合，模拟增益约 3.032 倍
 0x013e092au, // 读回校验：模拟增益细调；与3E08=81组成手册4.043倍档
 // 修改前：0x01322166u,
 0x01322160u, // 读回校验：bit[2:1]=00取消水平镜像，bit[6:5]=11保持原垂直翻转
 0x014501a4u,

 /* Verify the actual array readout ROI before streaming, not only output dimensions. */
 0x01320201u, // readback: array ROI
 0x01320367u, // readback: array ROI
 0x01320604u, // readback: array ROI
 0x01320740u, // readback: array ROI
 0x01010000u,
 0x00010001u,
 0x01010001u,
};


static uint32_t camera_wait(uint32_t offset,uint32_t mask,uint32_t value)
{
 uint32_t start=CAM_NOW();
 while((CAM_I2C_READ(offset)&mask)!=value)
  if((uint32_t)(CAM_NOW()-start)>=CAM_TIMEOUT) return 3u;
 return 0u;
}

static uint32_t camera_command(uint32_t command)
{
 CAM_I2C_WRITE(CAM_MASTER_STATUS,command|0xe00u); /* W1C dropped flags. */
 uint32_t result=camera_wait(CAM_MASTER_STATUS,command,0u);
 if(result) return result;
 return (CAM_I2C_READ(CAM_MASTER_STATUS)&0xe00u)?4u:0u;
}

static uint32_t camera_send(uint32_t value)
{
 (void)CAM_I2C_READ(CAM_RX_ACK); /* Consume any previous read's master NACK. */
 CAM_I2C_WRITE(CAM_RX_ACK,0x200u); /* Listen for the slave's ACK. */
 CAM_I2C_WRITE(CAM_TX_DATA,(value&255u)|0xb00u);
 CAM_I2C_WRITE(CAM_TX_ACK,0x301u); /* Release SDA on the ninth bit. */
 uint32_t result=camera_wait(CAM_TX_ACK,CAM_VALID,0u);
 if(result) return result;
 uint32_t start=CAM_NOW();
 for(;;) {
  uint32_t ack=CAM_I2C_READ(CAM_RX_ACK);
  if(ack&CAM_VALID) return (ack&1u)?2u:0u;
  if((uint32_t)(CAM_NOW()-start)>=CAM_TIMEOUT) return 3u;
 }
}

static uint32_t camera_receive(uint32_t *value)
{
 (void)CAM_I2C_READ(CAM_RX_DATA);
 CAM_I2C_WRITE(CAM_RX_DATA,0x200u);
 /* No conflict checking while the slave is driving the payload. */
 CAM_I2C_WRITE(CAM_TX_DATA,0x3ffu);
 CAM_I2C_WRITE(CAM_TX_ACK,0x301u); /* Single-byte read: master NACK. */
 uint32_t result=camera_wait(CAM_TX_ACK,CAM_VALID,0u);
 if(result) return result;
 uint32_t start=CAM_NOW();
 for(;;) {
  uint32_t data=CAM_I2C_READ(CAM_RX_DATA);
  if(data&CAM_VALID) { *value=data&255u;return 0u; }
  if((uint32_t)(CAM_NOW()-start)>=CAM_TIMEOUT) return 3u;
 }
}

static uint32_t camera_transfer(uint32_t address,uint32_t *value,uint32_t read)
{
 uint32_t result=camera_command(CAM_START);
 if(!result) result=camera_send(0x60u);
 if(!result) result=camera_send(address>>8);
 if(!result) result=camera_send(address);
 if(read) {
  if(!result) result=camera_command(CAM_START); /* Repeated START. */
  if(!result) result=camera_send(0x61u);
  if(!result) result=camera_receive(value);
 } else if(!result) result=camera_send(*value);
 uint32_t stop=camera_command(CAM_STOP);
 if(!stop) stop=camera_wait(CAM_MASTER_STATUS,1u,0u);
 if(result || stop) {
  (void)camera_command(CAM_DROP);
  return result?result:stop;
 }
 return 0u;
}

static uint32_t camera_init(void)
{
 reg_write(CAMERA_CONTROL_REG,1u); /* Assert the board's reset output. */
 CAM_DELAY_US(10000u);
 reg_write(CAMERA_CONTROL_REG,0u);
 CAM_DELAY_US(100000u);
 /* Same cycle-based timing units as the generated SDK's I2C demo.
  * Conservative 50kHz, with a 10ms bus timeout. */
 CAM_I2C_WRITE(0x20u,0u); /* No interrupts are needed for startup polling. */
 CAM_I2C_WRITE(0x28u,3u);
 CAM_I2C_WRITE(0x2cu,CAM_TIMEOUT);
 CAM_I2C_WRITE(0x30u,SYSTEM_CLINT_HZ/1000000u);
 CAM_I2C_WRITE(0x50u,SYSTEM_CLINT_HZ/100000u);
 CAM_I2C_WRITE(0x54u,SYSTEM_CLINT_HZ/100000u);
 CAM_I2C_WRITE(0x58u,SYSTEM_CLINT_HZ/100000u);
 uint32_t result=camera_command(CAM_RECOVER);
 if(result) { reg_write(CAMERA_CONTROL_REG,1u);return 0xc0000000u|result; }
 for(uint32_t i=0;i<sizeof(camera_sequence)/sizeof(camera_sequence[0]);++i) {
  uint32_t word=camera_sequence[i],address=(word>>8)&65535u;
  for(uint32_t retry=0;retry<3u;++retry) {
   uint32_t value=word&255u;
   result=camera_transfer(address,&value,word>>24);
   if(!result && (word>>24) && value!=(word&255u)) result=5u;
   CAM_DELAY_US(1000u);
   if(!result) break;
   (void)camera_command(CAM_RECOVER);
  }
  if(result) {
   reg_write(CAMERA_CONTROL_REG,1u);
   return 0xc0000000u|(address<<8)|result;
  }
 }
 reg_write(CAMERA_CONTROL_REG,2u); /* Configuration and streaming readback passed. */
 return 0u;
}
#endif
