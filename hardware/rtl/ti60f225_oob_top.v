/////////////////////////////////////////////////////////////////////////////
//
// 版权所有（C）2013-2021 Efinix Inc.，保留所有权利。
//
// 功能说明：
// Ti60F225 板级顶层：连接摄像头、图像预处理、DDR、CNN、软核和 HDMI。
//
// 语言：Verilog 2001。
//Ti60f225_sc431hai2hdmi_v7：
//debayer_v2 顶层接入: 删除 raw_gearbox_4to2 + debayer_top_2to1 链路,
//debayer_top_4to1 直挂 CSI pclk 域(4RAW/clk -> 4RGB/clk, 无 CDC),
//frame_buffer 写侧 96bit 移到 i_mipi_rx_pclk(参照 origin 版直挂时序),
// 公共DDR读服务按需取864×486，缩放器在225MHz域用gap9输出256×144并接入CNN。
// ------------------------------------------------------------------------------
/////////////////////////////////////////////////////////////////////////////////
`include "ddr3_controller/ddr3_parameter.vh"
// 旧版头文件引用（未启用）：`include "define.v"
// 用途：板级总封装，连接摄像头预处理、DDR帧缓存、软核、CNN与HDMI。
// 原理：按各时钟域连接原有流水单元，通过异步桥和AXI仲裁传递图像与权重，保持现有帧控制和显示时序。

module ti60f225_oob_top #(
    parameter RANK_RATIO = 1,
    // 每个存储秩的独立片选输出数量
    parameter CKE_WIDTH = `CKE_WIDTH,
    // 时钟使能输出数量
    parameter CS_WIDTH = `CS_WIDTH,
    // 独立片选输出数量
    parameter BANK_WIDTH = `BANK_WIDTH,
    // 存储体地址位数
    parameter ROW_WIDTH = `ROW_WIDTH,
    // 存储器行地址总线宽度
    parameter DM_WIDTH = `DM_WIDTH,
    // 数据掩码位数
    parameter DQS_WIDTH = `DQS_WIDTH,
    // 数据选通信号数量
    parameter DQ_WIDTH = `DQ_WIDTH,
    // 数据总线位数
    parameter ODT_WIDTH = `ODT_WIDTH,
    parameter DATA_WIDTH = `DATA_WIDTH,
    parameter ADDR_WIDTH = `ADDR_WIDTH,
    parameter AXI_ID_WIDTH = `AXI_ID_WIDTH,
    parameter AXI_ADDR_WIDTH = `AXI_ADDR_WIDTH,
    parameter AXI_DATA_WIDTH = `AXI_DATA_WIDTH,
    // 去马赛克后执行固定白平衡，增益参数沿用当前视频链路。
    // 增益采用无符号 Q2.14，16384 表示 1 倍；旁路时仍保持相同的两拍延迟。
    // parameter [15:0] WB_GAIN_R_Q14 = 16'd26400,
    // parameter [15:0] WB_GAIN_G_Q14 = 16'd22650,
    // parameter [15:0] WB_GAIN_B_Q14 = 16'd32000,
    parameter WB_GAIN_RATE = 1.2, //白平衡倍率
    parameter [15:0] WB_GAIN_R_Q14 = 16'd19200 * WB_GAIN_RATE, // 1.172倍
    parameter [15:0] WB_GAIN_G_Q14 = 16'd13384 * WB_GAIN_RATE, // 1.000倍
    parameter [15:0] WB_GAIN_B_Q14 = 16'd23040 * WB_GAIN_RATE, // 1.406倍
    // 编译期显示模式：1 为 1080p60，0 为 720p60。
    // 修改此参数时，须同步调整Interface Designer的HDMI PLL与SDC约束。
    parameter integer HDMI_1080P = 0,
    parameter WB_BYPASS = 0
) (
    input jtag_inst1_CAPTURE,
    input jtag_inst1_RESET,
    input jtag_inst1_SEL,
    input jtag_inst1_SHIFT,
    input jtag_inst1_TCK,
    input jtag_inst1_TDI,
    input jtag_inst1_UPDATE,
    output jtag_inst1_TDO,
    input system_spi_0_io_data_0_IN,
    input system_spi_0_io_data_1_IN,
    output system_spi_0_io_data_0_OUT,
    output system_spi_0_io_data_0_OE,
    output system_spi_0_io_data_1_OUT,
    output system_spi_0_io_data_1_OE,
    output system_spi_0_io_sclk_write,
    output system_spi_0_io_ss,
    //时钟与复位接口
    input wire i_arstn,
    input wire [2:0] key_i,
    // 按键低电平有效，对应 GPIOL_07、GPIOR_22、GPIOR_21
    input wire i_mipi_rx_pclk,
    input wire clk_225M,
    input wire vid_clk_dvi2,
    input wire hdmi_tx_slow_clk,
    input wire CLK_25M,
    output wire pll_inst1_RSTN,
    input wire i_pll_locked,
    input wire pll_locked,
    output wire pll_inst4_RSTN,
    input wire pll_inst4_LOCKED,
    output wire USER_PLL_RSTN,
    output wire DDR3_PLL_RSTN,
    input wire user_pll_locked,
    //摄像头 CSI 接口
    input wire io_cam_sda_IN,
    output wire io_cam_sda_OUT,
    output wire io_cam_sda_OE,
    output io_cam_scl_OUT,
    input io_cam_scl_IN,
    output io_cam_scl_OE,
    output wire o_cam_rst_p,
    input wire i_cam_ck_LP_P_IN,
    input wire i_cam_ck_LP_N_IN,
    output wire o_cam_ck_HS_TERM,
    output wire o_cam_ck_HS_ENA,
    input wire i_cam_ck_CLKOUT,
    input wire [7:0] cam_d0_HS_IN,
    input wire cam_d0_LP_P_IN,
    input wire cam_d0_LP_N_IN,
    output wire cam_d0_HS_TERM,
    output wire cam_d0_HS_ENA,
    output wire cam_d0_RST,
    output wire cam_d0_FIFO_RD,
    input wire cam_d0_FIFO_EMPTY,
    input wire [7:0] cam_d1_HS_IN,
    input wire cam_d1_LP_P_IN,
    input wire cam_d1_LP_N_IN,
    output wire cam_d1_HS_TERM,
    output wire cam_d1_HS_ENA,
    output wire cam_d1_RST,
    output wire cam_d1_FIFO_RD,
    input wire cam_d1_FIFO_EMPTY,
    input wire [7:0] cam_d2_HS_IN,
    input wire cam_d2_LP_P_IN,
    input wire cam_d2_LP_N_IN,
    output wire cam_d2_HS_TERM,
    output wire cam_d2_HS_ENA,
    output wire cam_d2_RST,
    output wire cam_d2_FIFO_RD,
    input wire cam_d2_FIFO_EMPTY,
    input wire [7:0] cam_d3_HS_IN,
    input wire cam_d3_LP_P_IN,
    input wire cam_d3_LP_N_IN,
    output wire cam_d3_HS_TERM,
    output wire cam_d3_HS_ENA,
    output wire cam_d3_RST,
    output wire cam_d3_FIFO_RD,
    input wire cam_d3_FIFO_EMPTY,
    input tx_cal_clk_90edge,
    input rx_cal_clk,
    input tx_cal_clk,
    input core_clk,
    // DDR 控制器核心时钟，频率由 Interface Designer 配置
    input sdram_clk,
    // DDR 存储器时钟，频率由 Interface Designer 配置
    // PLL 锁定及校准状态
    output [2:0] pll_shift,
    output [4:0] pll_shift_sel,
    output pll_shift_ena,
    // DDR 存储器物理接口
    output ddr_ck_hi,
    output ddr_ck_lo,
    output ddr_reset_n,
    output [CKE_WIDTH - 1:0] ddr_cke,
    output [ROW_WIDTH - 1:0] ddr_addr,
    output [BANK_WIDTH - 1:0] ddr_ba,
    output ddr_cas_n,
    output [CS_WIDTH * RANK_RATIO - 1:0] ddr_cs_n,
    output ddr_ras_n,
    output ddr_we_n,
    input [DQS_WIDTH - 1:0] ddr_dqs_in_hi,
    input [DQS_WIDTH - 1:0] ddr_dqs_in_lo,
    input [DQ_WIDTH - 1:0] ddr_dq_in_hi,
    input [DQ_WIDTH - 1:0] ddr_dq_in_lo,
    output [DQS_WIDTH - 1:0] ddr_dqs_oe,
    output [DQS_WIDTH - 1:0] ddr_dqs_oe_n,
    output [DQ_WIDTH - 1:0] ddr_dq_oe,
    output [DQS_WIDTH - 1:0] ddr_dqs_out_hi,
    output [DQS_WIDTH - 1:0] ddr_dqs_out_lo,
    output [DQ_WIDTH - 1:0] ddr_dq_out_hi,
    output [DQ_WIDTH - 1:0] ddr_dq_out_lo,
    output [DM_WIDTH - 1:0] ddr_dm_hi,
    output [DM_WIDTH - 1:0] ddr_dm_lo,
    output [ODT_WIDTH - 1:0] ddr_odt,
    //初始化状态指示灯
    output wire led_status,
    output wire led_camera_ready,
    output wire led_weights_ready,
    output wire led_first_frame,
    // 保留的 MIPI DSI 接口与复位控制
    input wire i_mipi_tx_pclk,
    output wire mipi_dp_clk_LP_P_OUT,
    output wire mipi_dp_clk_LP_N_OUT,
    output wire [7:0] mipi_dp_clk_HS_OUT,
    output wire mipi_dp_clk_HS_OE,
    output wire mipi_dp_data3_LP_P_OUT,
    output wire mipi_dp_data2_LP_P_OUT,
    output wire mipi_dp_data1_LP_P_OUT,
    output wire mipi_dp_data0_LP_P_OUT,
    output wire mipi_dp_data3_LP_N_OUT,
    output wire mipi_dp_data2_LP_N_OUT,
    output wire mipi_dp_data1_LP_N_OUT,
    output wire mipi_dp_data0_LP_N_OUT,
    output wire [7:0] mipi_dp_data0_HS_OUT,
    output wire [7:0] mipi_dp_data1_HS_OUT,
    output wire [7:0] mipi_dp_data2_HS_OUT,
    output wire [7:0] mipi_dp_data3_HS_OUT,
    output wire mipi_dp_data3_HS_OE,
    output wire mipi_dp_data2_HS_OE,
    output wire mipi_dp_data1_HS_OE,
    output wire mipi_dp_data0_HS_OE,
    output wire mipi_dp_clk_RST,
    output wire mipi_dp_data0_RST,
    output wire mipi_dp_data1_RST,
    output wire mipi_dp_data2_RST,
    output wire mipi_dp_data3_RST,
    output wire mipi_dp_clk_LP_P_OE,
    output wire mipi_dp_clk_LP_N_OE,
    output wire mipi_dp_data3_LP_P_OE,
    output wire mipi_dp_data3_LP_N_OE,
    output wire mipi_dp_data2_LP_P_OE,
    output wire mipi_dp_data2_LP_N_OE,
    output wire mipi_dp_data1_LP_P_OE,
    output wire mipi_dp_data1_LP_N_OE,
    output wire mipi_dp_data0_LP_P_OE,
    output wire mipi_dp_data0_LP_N_OE,
    input wire mipi_dp_data0_LP_P_IN,
    input wire mipi_dp_data0_LP_N_IN,
    output wire LCD_RST_P,
    output wire LCD_POWER,
    // HDMI 输出接口
    output tmds_tx_clk_TX_OE,
    output [9:0] tmds_tx_clk_TX_DATA,
    output tmds_tx_clk_TX_RST,
    output tmds_tx_data0_TX_OE,
    output [9:0] tmds_tx_data0_TX_DATA,
    output tmds_tx_data0_TX_RST,
    output tmds_tx_data1_TX_OE,
    output [9:0] tmds_tx_data1_TX_DATA,
    output tmds_tx_data1_TX_RST,
    output tmds_tx_data2_TX_OE,
    output [9:0] tmds_tx_data2_TX_DATA,
    output tmds_tx_data2_TX_RST
);

    //===============================================================================
    //===============================================================================
    // FIFO 保留 512 个 AXI 字，可容纳四个 128 拍突发。
    // 保持原突发长度，减少缓存容量时不增加 DDR 仲裁次数。
    localparam WR_FIFO_DEPTH = 512;
    localparam RD_FIFO_DEPTH = 512;
    localparam TX_FIFO_DEPTH = 512;
    localparam CNN_FIFO_DEPTH = 512;
    // 图像全程保持 16:9，消隐、同步宽度和 gap9 数据节拍沿用当前设置。
    localparam FB_IMG_W = 864;
    localparam FB_IMG_H = 486;
    localparam CNN_IMG_W = 256;
    localparam CNN_IMG_H = 144;
    // 下面的时钟配置标记由 tools/configure_display.py 自动更新。
    // 串行器 PLL 由 Interface Designer 管理；参数与物理时钟不符时拒绝编译。
    localparam HDMI_CLOCK_PROFILE_1080P = 0;

    generate
        if (HDMI_1080P != HDMI_CLOCK_PROFILE_1080P) begin : g_wrong_hdmi_clock_profile
            HDMI_CLOCK_PROFILE_MISMATCH_RUN_CONFIGURE_DISPLAY_PY configure_display_first (
            );

        end
    endgenerate
    localparam MAX_HRES = HDMI_1080P ? 1920:1280;
    localparam MAX_VRES = HDMI_1080P ? 1080:720;
    localparam HFP = HDMI_1080P ? 88:110;
    localparam HSP = HDMI_1080P ? 44:40;
    localparam HBP = HDMI_1080P ? 148:220;
    localparam VFP = HDMI_1080P ? 4:5;
    localparam VSP = 5;
    localparam VBP = HDMI_1080P ? 36:20;
    localparam HDMI_VIEW_W = MAX_HRES / 2;
    localparam HDMI_VIEW_H = MAX_VRES / 2;
    localparam HDMI_VIC = HDMI_1080P ? 16:4;
    localparam HDMI_AUDIO_CTS = HDMI_1080P ? 148500:74250;
    //===============================================================================
    //内部信号
    //===============================================================================
    wire cal_done;
    // DDR 从接口：AXI 写地址通道
    wire [AXI_ID_WIDTH - 1:0] s_axi_awid;
    wire [AXI_ADDR_WIDTH - 1:0] s_axi_awaddr;
    wire [7:0] s_axi_awlen;
    wire [2:0] s_axi_awsize;
    wire [1:0] s_axi_awburst;
    wire [0:0] s_axi_awlock;
    wire [3:0] s_axi_awcache;
    wire [2:0] s_axi_awprot;
    wire s_axi_awvalid;
    wire s_axi_awready;
    // DDR 从接口：AXI 写数据通道
    wire [AXI_DATA_WIDTH - 1:0] s_axi_wdata;
    wire [(AXI_DATA_WIDTH / 8) - 1:0] s_axi_wstrb;
    wire s_axi_wlast;
    wire s_axi_wvalid;
    wire s_axi_wready;
    // DDR 从接口：AXI 写响应通道
    wire s_axi_bready;
    wire [AXI_ID_WIDTH - 1:0] s_axi_bid;
    wire [1:0] s_axi_bresp;
    wire s_axi_bvalid;
    // DDR 从接口：AXI 读地址通道
    wire [AXI_ID_WIDTH - 1:0] s_axi_arid;
    wire [AXI_ADDR_WIDTH - 1:0] s_axi_araddr;
    wire [7:0] s_axi_arlen;
    wire [2:0] s_axi_arsize;
    wire [1:0] s_axi_arburst;
    wire [0:0] s_axi_arlock;
    wire [3:0] s_axi_arcache;
    wire [2:0] s_axi_arprot;
    wire s_axi_arvalid;
    wire s_axi_arready;
    // DDR 从接口：AXI 读数据与响应通道
    wire s_axi_rready;
    wire [AXI_ID_WIDTH - 1:0] s_axi_rid;
    wire [AXI_DATA_WIDTH - 1:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire s_axi_rlast;
    wire s_axi_rvalid;
    //==================== [ARB-ADD] 仲裁器新增: master侧AXI连线 ====================
    // checker0(frame_buffer) 的 AXI 端口改接这组 fb_axi_* 线,
    // 经 axi_wr_arb / axi_rd_arb 仲裁后汇入 s_axi_* (→ u_ddr3_top)
    // 注: 仲裁器统一分配 awid/arid, checker0 的 awid/arid 输出不再使用
    wire [AXI_ADDR_WIDTH - 1:0] fb_axi_awaddr;
    wire [7:0] fb_axi_awlen;
    wire [2:0] fb_axi_awsize;
    wire [1:0] fb_axi_awburst;
    wire [0:0] fb_axi_awlock;
    wire [3:0] fb_axi_awcache;
    wire [2:0] fb_axi_awprot;
    wire fb_axi_awvalid;
    wire fb_axi_awready;
    wire [AXI_DATA_WIDTH - 1:0] fb_axi_wdata;
    wire [(AXI_DATA_WIDTH / 8) - 1:0] fb_axi_wstrb;
    wire fb_axi_wlast;
    wire fb_axi_wvalid;
    wire fb_axi_wready;
    wire [AXI_ID_WIDTH - 1:0] fb_axi_bid;
    wire [1:0] fb_axi_bresp;
    wire fb_axi_bvalid;
    wire fb_axi_bready;
    // 写仲裁器 core_clk 域同步复位
    wire arb_wr_rstn;
    wire [11:0] boot_paddr;
    wire [31:0] boot_pwdata;
    wire [31:0] boot_prdata;
    wire boot_psel;
    wire boot_penable;
    wire boot_pwrite;
    wire boot_pready;
    wire boot_pslverror;
    wire boot_system_reset;
    // 软核负责摄像头初始化、Flash权重预载和运行期IN更新。
    wire cpu_cam_scl_release;
    wire cpu_cam_sda_release;
    // 摄像头 APB 控制开始
    wire camera_apb_select = (boot_paddr == 12'h01c);
    wire weight_boot_psel = boot_psel && !camera_apb_select;
    wire system_rst_n = i_arstn & i_pll_locked & pll_locked & user_pll_locked;
    wire [31:0] weight_boot_prdata;
    wire weight_boot_pready;
    wire weight_boot_pslverror;
    reg [1:0] camera_control = 2'b01;
    // 位 0 表示保持复位，位 1 表示摄像头配置完成。

    always @(posedge core_clk or negedge w_arstn) begin
        if (! w_arstn) camera_control <= 2'b01;
        else if (boot_system_reset) camera_control <= 2'b01;
        else if (boot_psel && boot_penable && boot_pwrite && camera_apb_select) camera_control <= boot_pwdata [1:0];
    end
    assign boot_prdata = camera_apb_select ? { 23'd0, 1'b1, 6'd0, camera_control }:weight_boot_prdata;
    assign boot_pready = camera_apb_select ? 1'b1:weight_boot_pready;
    assign boot_pslverror = camera_apb_select ? 1'b0:weight_boot_pslverror;
    // 摄像头 APB 控制结束

    generate
        begin : g_boot_cpu
            cnn_boot_soc u_boot_soc (
                .io_systemClk(core_clk),
                .io_asyncReset(~ arb_wr_rstn),
                .io_systemReset(boot_system_reset),
                .jtagCtrl_enable(jtag_inst1_SEL),
                .jtagCtrl_tdi(jtag_inst1_TDI),
                .jtagCtrl_capture(jtag_inst1_CAPTURE),
                .jtagCtrl_shift(jtag_inst1_SHIFT),
                .jtagCtrl_update(jtag_inst1_UPDATE),
                .jtagCtrl_reset(jtag_inst1_RESET),
                .jtagCtrl_tdo(jtag_inst1_TDO),
                .jtagCtrl_tck(jtag_inst1_TCK),
                .system_spi_0_io_data_0_read(system_spi_0_io_data_0_IN),
                .system_spi_0_io_data_0_write(system_spi_0_io_data_0_OUT),
                .system_spi_0_io_data_0_writeEnable(system_spi_0_io_data_0_OE),
                .system_spi_0_io_data_1_read(system_spi_0_io_data_1_IN),
                .system_spi_0_io_data_1_write(system_spi_0_io_data_1_OUT),
                .system_spi_0_io_data_1_writeEnable(system_spi_0_io_data_1_OE),
                .system_spi_0_io_data_2_read(1'b1),
                .system_spi_0_io_data_2_write(),
                .system_spi_0_io_data_2_writeEnable(),
                .system_spi_0_io_data_3_read(1'b1),
                .system_spi_0_io_data_3_write(),
                .system_spi_0_io_data_3_writeEnable(),
                .system_spi_0_io_sclk_write(system_spi_0_io_sclk_write),
                .system_spi_0_io_ss(system_spi_0_io_ss),
                .system_uart_0_io_rxd(1'b1),
                .system_i2c_0_io_scl_read(io_cam_scl_IN),
                .system_i2c_0_io_scl_write(cpu_cam_scl_release),
                .system_i2c_0_io_sda_read(io_cam_sda_IN),
                .system_i2c_0_io_sda_write(cpu_cam_sda_release),
                .system_uart_0_io_txd(),
                .io_apbSlave_0_PADDR(boot_paddr),
                .io_apbSlave_0_PENABLE(boot_penable),
                .io_apbSlave_0_PRDATA(boot_prdata),
                .io_apbSlave_0_PREADY(boot_pready),
                .io_apbSlave_0_PSEL(boot_psel),
                .io_apbSlave_0_PSLVERROR(boot_pslverror),
                .io_apbSlave_0_PWDATA(boot_pwdata),
                .io_apbSlave_0_PWRITE(boot_pwrite)
            );

        end
    endgenerate
    // 仲裁器调试信号 (ILA/波形观察用)
    //==============================================================================
    ////////////////////////////////////////////////////////////////
    // 系统复位与视频接口信号
    wire w_arstn;
    // wire	w_sysclk_mcu_arstn;
    // wire	w_sysclk_mcu_arst;
    wire w_mipi_rx_pclk_arstn;
    wire w_mipi_rx_pclk_arst;
    wire w_mipi_rx_vs;
    wire w_mipi_rx_hs;
    wire w_mipi_rx_de;
    wire [63:0] w_mipi_rx_data;
    // 只有 CSI 原始帧的有效像素数量完整时才计帧，避免同步毛刺或重复显示造成误计。
    reg camera_vs_d;
    reg camera_frame_toggle;
    reg [17:0] camera_frame_beats;
    wire camera_sof = w_mipi_rx_vs && ! camera_vs_d;

    always @(posedge i_mipi_rx_pclk or negedge vid_rst_n) if (! vid_rst_n) begin
        camera_vs_d <= 0;
        camera_frame_toggle <= 0;
        camera_frame_beats <= 0;
    end else begin
        camera_vs_d <= w_mipi_rx_vs;
        if (camera_sof) begin
            if (camera_frame_beats == 1280 * 720 / 4) camera_frame_toggle <= ~ camera_frame_toggle;
            camera_frame_beats <= w_mipi_rx_de ? 1:0;
        end else if (w_mipi_rx_de && camera_frame_beats < 1280 * 720 / 4 + 1) camera_frame_beats <= camera_frame_beats + 1'b1;
    end
    //===================================================================================================
    //复位控制
    //===================================================================================================
    // 旧版复位表达式（仅作记录）：w_arstn = i_pll_locked & pll_locked & user_pll_locked。
    assign w_arstn = system_rst_n;
    assign pll_inst1_RSTN = i_arstn;
    assign USER_PLL_RSTN = i_arstn;
    assign mipi_dsi_tx_pll_RSTN = i_arstn;
    assign DDR3_PLL_RSTN = i_arstn;
    reset_ctrl #(
        .NUM_RST(2),
        .CYCLE(1),
        .IN_RST_ACTIVE(4'b00),
        .OUT_RST_ACTIVE(4'b10)
    ) inst_reset_ctrl (
        .i_arst({ 2 { w_arstn } }),
        //({{4{i_pll_locked}},                  {2{i_arstn}}}),
        .i_clk({ 2 { i_mipi_rx_pclk } }),
        .o_srst({ w_mipi_rx_pclk_arst, w_mipi_rx_pclk_arstn })
    );

    assign led_status = cal_done;
    //========================================================================================================
    //MIPI 摄像头接收
    //========================================================================================================
    wire i_mipi_clk;
    assign i_mipi_clk = core_clk;
    assign cam_d0_RST = 1'b0;
    assign cam_d1_RST = 1'b0;
    assign cam_d2_RST = 1'b0;
    assign cam_d3_RST = 1'b0;
    csi_rx_controller inst_efx_csi2_rx (
        .reset_n(i_arstn),
        .clk(i_mipi_clk),
        .reset_byte_HS_n(i_arstn),
        .clk_byte_HS(i_cam_ck_CLKOUT),
        .reset_pixel_n(w_mipi_rx_pclk_arstn),
        .clk_pixel(i_mipi_rx_pclk),
        .Rx_LP_CLK_P(i_cam_ck_LP_P_IN),
        .Rx_LP_CLK_N(i_cam_ck_LP_N_IN),
        .Rx_HS_enable_C(o_cam_ck_HS_ENA),
        .LVDS_termen_C(o_cam_ck_HS_TERM),
        .Rx_LP_D_P({ cam_d3_LP_P_IN, cam_d2_LP_P_IN, cam_d1_LP_P_IN, cam_d0_LP_P_IN }),
        //(r_mipi_rx_data_LP_P_IN_2P),
        .Rx_LP_D_N({ cam_d3_LP_N_IN, cam_d2_LP_N_IN, cam_d1_LP_N_IN, cam_d0_LP_N_IN }),
        //(r_mipi_rx_data_LP_N_IN_2P),
        .Rx_HS_D_0(cam_d0_HS_IN),
        //(r_mipi_rx_data_HS_IN_2P[0*8+:8]),
        .Rx_HS_D_1(cam_d1_HS_IN),
        //(r_mipi_rx_data_HS_IN_2P[1*8+:8]),
        .Rx_HS_D_2(cam_d2_HS_IN),
        .Rx_HS_D_3(cam_d3_HS_IN),
        .Rx_HS_D_4(),
        .Rx_HS_D_5(),
        .Rx_HS_D_6(),
        .Rx_HS_D_7(),
        .Rx_HS_enable_D({ cam_d3_HS_ENA, cam_d2_HS_ENA, cam_d1_HS_ENA, cam_d0_HS_ENA }),
        //( w_cam_d_HS_ENA),
        .LVDS_termen_D({ cam_d3_HS_TERM, cam_d2_HS_TERM, cam_d1_HS_TERM, cam_d0_HS_TERM }),
        .fifo_rd_enable({ cam_d3_FIFO_RD, cam_d2_FIFO_RD, cam_d1_FIFO_RD, cam_d0_FIFO_RD }),
        .fifo_rd_empty({ cam_d3_FIFO_EMPTY, cam_d2_FIFO_EMPTY, cam_d1_FIFO_EMPTY, cam_d0_FIFO_EMPTY }),
        .DLY_enable_D(),
        .DLY_inc_D(),
        .u_dly_enable_D(),
        .u_dly_inc_D(),
        .axi_clk(1'b0),
        .axi_reset_n(1'b0),
        .axi_awaddr(6'b0),
        .axi_awvalid(1'b0),
        .axi_awready(),
        .axi_wdata(32'b0),
        .axi_wvalid(1'b0),
        .axi_wready(),
        .axi_bvalid(),
        .axi_bready(1'b0),
        .axi_araddr(6'b0),
        .axi_arvalid(1'b0),
        .axi_arready(),
        .axi_rdata(),
        .axi_rvalid(),
        .axi_rready(1'b1),
        .hsync_vc0(w_mipi_rx_hs),
        .hsync_vc1(),
        .hsync_vc2(),
        .hsync_vc3(),
        .vsync_vc0(w_mipi_rx_vs),
        .vsync_vc1(),
        .vsync_vc2(),
        .vsync_vc3(),
        .vc(),
        .word_count(),
        .shortpkt_data_field(),
        .datatype(),
        .pixel_per_clk(),
        .pixel_data(w_mipi_rx_data),
        .pixel_data_valid(w_mipi_rx_de),
        .irq(),
        .mipi_debug_out()
    );

    //     wire		       w1_mipi_rx_vs;
    // wire		       w1_mipi_rx_hs;
    // wire	       w1_mipi_rx_de;
    // wire	[39:0]			w1_mipi_rx_data	;
    // sensor_clipper  sensor_clipper_inst (
    //     .clk(i_mipi_rx_pclk),
    //     .i_vs(w_mipi_rx_vs),
    //     .i_hs(w_mipi_rx_hs),
    //     .i_de(w_mipi_rx_de),
    //     .i_dat(w_mipi_rx_data[39:0]),
    //     .o_hs(w1_mipi_rx_hs),
    //     .o_vs(w1_mipi_rx_vs),
    //     .o_de(w1_mipi_rx_de),
    //     .o_dat(w1_mipi_rx_data)
    //   );
    //========================================================================================================
    //
    //========================================================================================================
    // 摄像头初始化和 I2C 总线由软核控制。
    assign io_cam_scl_OUT = 1'b0;
    assign io_cam_sda_OUT = 1'b0;
    assign io_cam_scl_OE = ~ cpu_cam_scl_release;
    assign io_cam_sda_OE = ~ cpu_cam_sda_release;
    assign o_cam_rst_p = camera_control [0];
    wire deb2_vs;
    wire deb2_hs;
    wire deb2_de;
    wire [95:0] deb2_rgb96;
    // {B3,G3,R3,B2,G2,R2,B1,G1,R1,B0,G0,R0}, px0 最低
    wire wb_vs;
    wire wb_hs;
    wire wb_de;
    wire [95:0] wb_rgb96;
    wire [95:0] fb_vin96;
    wire [47:0] ch0_vout;
    // HDMI读出像素位于低24bit，高24bit保留为0
    wire sc_vs;
    wire sc_de;
    // scaler 输出帧同步/数据有效 (pclk 域)
    wire [95:0] sc_data96;
    // 同 debayer 打包序, px0 最低
    assign fb_vin96 = { sc_data96 [23:0], sc_data96 [47:24], sc_data96 [71:48], sc_data96 [95:72] };
    debayer_top_4to1 #(// 按当前 1280 像素行宽设置缓存，行时序仍由 CSI 的 HS/DE 驱动。
    .MAX_LINE_PIXELS(1280),
    .P_DEPTH(8),
    // 摄像头3221=60取消水平镜像，去马赛克先恢复原先使用的BGGR配置。
    // 撤回未经RAW实测确认的GBRG推断；镜像寄存器与实际Bayer相位需分别确认。
    .SENSOR_PATTERN(3)
    ) u_debayer_v2(.in_pclk(i_mipi_rx_pclk),.in_rstn(vid_rst_n),.raw_vs_i(w_mipi_rx_vs),.raw_hs_i(w_mipi_rx_hs), // 透传至 rgb_hs_o, 供写侧 de&hs 门控(origin 式)
    .raw_de_i(w_mipi_rx_de), // [V7.3 已回退] de|hs 实验失败: 画面冻结首帧
    .raw_valid_i(w_mipi_rx_de),.raw_datax4_i({ w_mipi_rx_data [39:32], w_mipi_rx_data [29:22], w_mipi_rx_data [19:12], w_mipi_rx_data [9:2] }), // 4 x RAW8, px0 最低
    // 清除VIO后固定为原默认增益，避免使用未驱动的调试控制线。
    .r_gain(16'd255),.g_gain(16'd255),.b_gain(16'd255),.rgb_vs_o(deb2_vs),.rgb_hs_o(deb2_hs),.rgb_de_o(deb2_de),.rgb_valid_o(),.rgb_rout(),.rgb_gout(),.rgb_bout(),.rgb_datax4_o(deb2_rgb96) // 每拍输出四个 RGB 像素
    );

    // 缩放前校正 RGB，使原图和 CNN 支路使用相同的白平衡结果。
    rgb_white_balance_4px #(
        .GAIN_R_Q14(WB_GAIN_R_Q14),
        .GAIN_G_Q14(WB_GAIN_G_Q14),
        .GAIN_B_Q14(WB_GAIN_B_Q14),
        .BYPASS(WB_BYPASS)
    ) u_green_fix_wb (
        .clk(i_mipi_rx_pclk),
        .rst_n(vid_rst_n),
        .i_vs(deb2_vs),
        .i_hs(deb2_hs),
        .i_de(deb2_de),
        .i_valid(deb2_de),
        .i_data(deb2_rgb96),
        .o_vs(wb_vs),
        .o_hs(wb_hs),
        .o_de(wb_de),
        .o_valid(),
        .o_data(wb_rgb96)
    );

    // [V7.8] 流式两级双线性缩小 1920x1080 -> 864x486 (img_preprocess/scaler_line_96.v)
    //   输入 4px/clk 直挂 debayer (无齿轮箱, 每拍最多双发射, 源行窗 480 拍足够);
    //   输出 4px/clk 96bit (o_vs 为电平型帧同步: 整帧拉高, 与 origin 版写侧 w_mipi_rx_vs 同语义);
    //   行缓存为2x432x48bit乒乓；地址宽度仍为10位，与原640宽度相同。
    //   逐位全对; 链路仿真 tb_scaler_fb: SWZ + 读侧 2475x500 时序 0 错。
    // 摄像头 720p 数据缩放后写入原有 864×486 DDR 帧缓存。
    scaler_line_720p_96 u_scaler (
        .i_clk(i_mipi_rx_pclk),
        .i_rst_n(vid_rst_n),
        .i_vs(wb_vs),
        .i_de(wb_de),
        // 与原 FB 写侧相同的 de&hs 门控(origin 式)
        .i_hs(wb_hs),
        .i_data(wb_rgb96),
        .o_vs(sc_vs),
        .o_de(sc_de),
        .o_href(),
        .o_data(sc_data96)
    );

    //=====================================================================================
    //输入帧缓存与 CNN 数据桥接
    //=====================================================================================
    wire ch0_vs;
    wire ch0_hs;
    wire ch0_de;
    // 原 data_tx 在 CLK_25M 域连续读; CNN 消费异步 FIFO 输出。
    wire fb_fast_vs;
    wire fb_fast_de;
    wire fb_fast_underflow;
    wire [23:0] fb_fast_data;
    wire fb_fast_href;
    wire fb_stream_start;
    wire fb_stream_ready;
    wire fb_stream_available;
    wire fb_stream_idle;
    wire small_stream_vs;
    wire small_stream_href;
    wire small_stream_valid;
    wire small_stream_abort;
    wire small_stream_error;
    wire [23:0] small_stream_data;
    // 完整CNN等待DDR权重初始化、回读及各层参数加载完毕，桥接器再接收完整帧。
    // ready只表示权重就绪，不能接!busy，否则会在帧中途停止桥接器。
    // 视频延时复位来自vid_clk_dvi2域；CNN域必须异步置零、225MHz同步释放。
    // 桥接器和HDMI framebuffer内部已有各自的本地复位同步链。
    (* async_reg="true", syn_preserve="true" *)
    reg [2:0] cnn_reset_pipe = 3'b000;

    always @(posedge clk_225M or negedge vid_rst_n) if (! vid_rst_n) cnn_reset_pipe <= 3'b000;
    else cnn_reset_pipe <= { cnn_reset_pipe [1:0], 1'b1 };
    wire cnn_rst_n = cnn_reset_pipe [2];
    // 三按键控制：暂停、分屏/全屏、循环风格
    // 按键采用低电平有效的稳定确认方式，三个按键共用一个 1ms 时基。
    // 每个按键使用五位消抖计数，仅产生单击事件，不处理长按或双击。
    localparam integer KEY_TICK_CYCLES = 25000;
    // 25MHz 时钟每 25000 拍产生一次 1ms 计数节拍
    (* async_reg="true" *)
    reg [2:0] key_reset_pipe = 0;

    always @(posedge CLK_25M or negedge vid_rst_n) if (! vid_rst_n) key_reset_pipe <= 0;
    else key_reset_pipe <= { key_reset_pipe [1:0], 1'b1 };
    wire key_rst_n = key_reset_pipe [2];
    (* async_reg="true" *)
    reg [2:0] key_meta;
    (* async_reg="true" *)
    reg [2:0] key_sync;
    reg [2:0] key_stable;
    reg [2:0] key_press;
    reg [14:0] key_tick_count;
    reg [4:0] key_count [0:2];
    reg key_pause;
    reg key_raw;
    reg key_style_toggle;
    integer key_index;

    always @(posedge CLK_25M or negedge key_rst_n) if (! key_rst_n) begin
        key_meta <= 3'b111;
        key_sync <= 3'b111;
        key_stable <= 3'b111;
        key_press <= 0;
        key_tick_count <= 0;
        key_style_toggle <= 0;
        key_pause <= 0;
        key_raw <= 0;
        for (key_index = 0; key_index < 3; key_index = key_index + 1) key_count [key_index] <= 0;
    end else begin
        key_meta <= key_i;
        key_sync <= key_meta;
        key_press <= 0;
        if (key_tick_count == KEY_TICK_CYCLES - 1) key_tick_count <= 0;
        else key_tick_count <= key_tick_count + 1'b1;
        for (key_index = 0; key_index < 3; key_index = key_index + 1) begin
            if (key_sync [key_index] == key_stable [key_index]) key_count [key_index] <= 0;
            else if (key_tick_count == KEY_TICK_CYCLES - 1) begin
                // 连续 21 次采样覆盖至少 20ms，不受按键与时基相位关系影响。
                if (key_count [key_index] == 20) begin
                    key_count [key_index] <= 0;
                    key_stable [key_index] <= key_sync [key_index];
                    if (! key_sync [key_index]) key_press [key_index] <= 1;
                end else key_count [key_index] <= key_count [key_index] + 1'b1;
            end
        end
        if (key_press [0]) key_pause <= ~key_pause;
        if (key_press [1]) key_raw <= ~key_raw;
        if (key_press [2]) key_style_toggle <= ~key_style_toggle;
    end
    // 跨时钟域传递保持型控制状态，不直接传递单拍按键脉冲。
    (* async_reg="true" *)
    reg [1:0] display_control_meta;
    (* async_reg="true" *)
    reg [1:0] display_control_sync;

    always @(posedge clk_225M or negedge cnn_rst_n) if (! cnn_rst_n) begin
        display_control_meta <= 0;
        display_control_sync <= 0;
    end else begin
        display_control_meta <= { key_raw, key_pause };
        display_control_sync <= display_control_meta;
    end
    // 三按键控制结束
    wire cnn_params_ready;
    wire cnn_result_vs;
    wire cnn_result_href;
    wire cnn_result_valid;
    wire [23:0] cnn_result_data;
    wire cnn_result_abort;
    wire cnn_small_vs;
    wire cnn_small_href;
    wire cnn_small_valid;
    wire cnn_small_abort;
    wire [23:0] cnn_small_data;
    // 摄像头、帧缓存及 HDMI 使用 {B,G,R}，CNN 接口使用 {R,G,B}。
    // 只在 CNN 边界交换颜色字节，属于固定接线，不增加处理延迟。
    wire [23:0] cnn_input_data = { cnn_small_data [7:0], cnn_small_data [15:8], cnn_small_data [23:16] };
    wire [23:0] cnn_display_data = { cnn_result_data [7:0], cnn_result_data [15:8], cnn_result_data [23:16] };
    // 同时传递帧、行、像素有效、数据和中止信号，保持完整视频包对齐。
    wire display_vs = cnn_result_vs;
    wire display_href = cnn_result_href;
    wire display_valid = cnn_result_valid;
    wire display_abort = cnn_result_abort;
    wire [23:0] display_data = cnn_display_data;
    // SC431HAI 预处理结果写入帧缓存
    // 统一原画帧池：采集仅写一次，显示与 CNN 通过公共 DDR 服务读取。
    wire raw_display_start;
    wire [AXI_ADDR_WIDTH-1:0] raw_display_base;
    wire raw_display_available;
    wire video_read_start;
    wire [AXI_ADDR_WIDTH-1:0] video_read_base;
    wire [10:0] video_read_used;
    wire video_read_valid;
    wire [47:0] video_read_pixel;
    wire video_read_complete;
    wire video_read_fault;
    frame_buffer #(
        .I_VID_WIDTH(96),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .WR_FIFO_DEPTH(WR_FIFO_DEPTH),
        .PIXEL_FIFO_DEPTH(1024),
        .MAX_VID_WIDTH(FB_IMG_W),
        .MAX_VID_HIGHT(FB_IMG_H),
        .EXPECTED_FRAME_BEATS(FB_IMG_W*FB_IMG_H/4),
        .START_ADDR(32'h00000000)
    ) checker0 (
        .axi_clk(core_clk),
        .rst_n(vid_rst_n),
        .i_clk(i_mipi_rx_pclk),
        .i_vs(sc_vs),
        .i_de(sc_de),
        .vin(fb_vin96),
        .o_clk(clk_225M),
        .stream_start(fb_stream_start),
        .stream_ready(fb_stream_ready),
        .stream_available(fb_stream_available),
        .stream_idle(fb_stream_idle),
        .pause(display_control_sync[0]),
        .display_start(raw_display_start),
        .raw_display_base(raw_display_base),
        .raw_display_available(raw_display_available),
        .service_start(video_read_start),
        .service_base(video_read_base),
        .service_used(video_read_used),
        .service_valid(video_read_valid),
        .service_pixel(video_read_pixel),
        .service_complete(video_read_complete),
        .service_fault(video_read_fault),
        .o_hs(fb_fast_href),
        .o_vs(fb_fast_vs),
        .o_de(fb_fast_de),
        .vout(fb_fast_data),
        .o_underflow(fb_fast_underflow),
        .awaddr(fb_axi_awaddr),
        .awlen(fb_axi_awlen),
        .awsize(fb_axi_awsize),
        .awburst(fb_axi_awburst),
        .awprot(fb_axi_awprot),
        .awcache(fb_axi_awcache),
        .awlock(fb_axi_awlock),
        .awvalid(fb_axi_awvalid),
        .awready(fb_axi_awready),
        .wdata(fb_axi_wdata),
        .wstrb(fb_axi_wstrb),
        .wlast(fb_axi_wlast),
        .wvalid(fb_axi_wvalid),
        .wready(fb_axi_wready),
        .bid({2'b00,fb_axi_bid}),
        .bvalid(fb_axi_bvalid),
        .bready(fb_axi_bready)
    );
    // DDR 保留 864×486 图像，高速读出允许暂停；缩放后以 25MHz 生成小图时序。
    // 小图经过原跨时钟桥后，以严格 gap9 节拍送入 CNN。
    cnn_bilinear_downscale #(
        .SRC_W(FB_IMG_W),
        .SRC_H(FB_IMG_H),
        .DST_W(CNN_IMG_W),
        .DST_H(CNN_IMG_H),
        .DUAL_CLOCK(1),
        .INPUT_GAP(5),
        .VIDEO_HT(2000),
        .VIDEO_VT(208),
        .VIDEO_HA(944),
        .VIDEO_VA(4),
        .FRAME_HZ(60)
    ) u_cnn_resize (
        .clk(clk_225M),
        .video_clk(CLK_25M),
        .rst_n(cnn_rst_n),
        .frame_abort(fb_fast_underflow),
        .enable(cnn_params_ready),
        .source_available(fb_stream_available),
        .source_idle(fb_stream_idle),
        .o_source_start(fb_stream_start),
        .o_source_ready(fb_stream_ready),
        .pre_img_vsync(fb_fast_vs),
        .pre_img_href(fb_fast_href),
        .pre_img_clken(fb_fast_de),
        .pre_img_data(fb_fast_data),
        .post_img_vsync(small_stream_vs),
        .post_img_href(small_stream_href),
        .post_img_clken(small_stream_valid),
        .post_img_data(small_stream_data),
        .o_frame_abort(small_stream_abort),
        .o_video_error(small_stream_error),
        .o_protocol_error()
    );

    // 缩小器已在225MHz域产生gap9和连续行有效，不再经过异步像素FIFO。
    assign cnn_small_vs = small_stream_vs;
    assign cnn_small_href = small_stream_href;
    assign cnn_small_valid = small_stream_valid;
    assign cnn_small_abort = small_stream_abort;
    assign cnn_small_data = small_stream_data;
    wire [AXI_ADDR_WIDTH - 1:0] wt_awaddr;
    wire [AXI_ADDR_WIDTH - 1:0] wt_araddr;
    wire [7:0] wt_awlen;
    wire [7:0] wt_arlen;
    wire [2:0] wt_awsize;
    wire [2:0] wt_arsize;
    wire [1:0] wt_awburst;
    wire [1:0] wt_arburst;
    wire [1:0] wt_bresp;
    wire [1:0] wt_rresp;
    wire wt_awvalid;
    wire wt_awready;
    wire wt_wvalid;
    wire wt_wready;
    wire wt_wlast;
    wire wt_bvalid;
    wire wt_bready;
    wire wt_arvalid;
    wire wt_arready;
    wire wt_rvalid;
    wire wt_rready;
    wire wt_rlast;
    wire [AXI_DATA_WIDTH - 1:0] wt_wdata;
    wire [AXI_DATA_WIDTH - 1:0] wt_rdata;
    wire [AXI_DATA_WIDTH / 8 - 1:0] wt_wstrb;

    generate
        begin : g_cnn_enabled
            cnn_top #(
                .H_DISP(CNN_IMG_W),
                .V_DISP(CNN_IMG_H),
                .AXI_ADDR_W(AXI_ADDR_WIDTH),
                .AXI_DATA_W(AXI_DATA_WIDTH)
            ) u_cnn (
                .clk(clk_225M),
                .rst_n(cnn_rst_n),
                .frame_abort(cnn_small_abort),
                .style_next_toggle(key_style_toggle),
                .axi_clk(core_clk),
                .axi_rst_n(arb_wr_rstn),
                .calib_done(cal_done),
                .boot_paddr(boot_paddr),
                .boot_psel(weight_boot_psel),
                .boot_penable(boot_penable),
                .boot_pwrite(boot_pwrite),
                .boot_pwdata(boot_pwdata),
                .boot_prdata(weight_boot_prdata),
                .boot_pready(weight_boot_pready),
                .boot_pslverror(weight_boot_pslverror),
                .pre_img_vsync(cnn_small_vs),
                .pre_img_href(cnn_small_href),
                .pre_img_clken(cnn_small_valid),
                .pre_img_data(cnn_input_data),
                .post_img_vsync(cnn_result_vs),
                .post_img_href(cnn_result_href),
                .post_img_valid(cnn_result_valid),
                .post_img_data(cnn_result_data),
                .o_ready(cnn_params_ready),
                .o_busy(),
                .o_error(),
                .o_weight_error(),
                .o_frame_abort(cnn_result_abort),
                .awaddr(wt_awaddr),
                .awlen(wt_awlen),
                .awsize(wt_awsize),
                .awburst(wt_awburst),
                .awvalid(wt_awvalid),
                .awready(wt_awready),
                .wdata(wt_wdata),
                .wstrb(wt_wstrb),
                .wlast(wt_wlast),
                .wvalid(wt_wvalid),
                .wready(wt_wready),
                .bvalid(wt_bvalid),
                .bresp(wt_bresp),
                .bready(wt_bready),
                .araddr(wt_araddr),
                .arlen(wt_arlen),
                .arsize(wt_arsize),
                .arburst(wt_arburst),
                .arvalid(wt_arvalid),
                .arready(wt_arready),
                .rdata(wt_rdata),
                .rlast(wt_rlast),
                .rvalid(wt_rvalid),
                .rresp(wt_rresp),
                .rready(wt_rready)
            );

        end
    endgenerate
    // Previous: 显示DDR保存256x144结果，已有双线性scanout按16:9直接放大到1080p。
    // 1080p 模式显示两幅 960×540 图像，上下各留 270 行黑边。
    // 720p 模式显示两幅 640×360 图像，上下各留 180 行黑边，均采用双线性采样。
    // 输出 DDR 保存 256×144×3 风格图或 864×486×3 原图，共用三个 0x134000 字节的存储区。
    // 输入帧缓存保持原 96 位打包及 0x4CE500 存储区间距，三个存储区均位于 16MiB 以下。
    // HDMI 使用 [0x01000000,0x0139C000) 地址区间，权重基址仍为 0x02000000。
    wire [AXI_ADDR_WIDTH - 1:0] out_awaddr;
    wire [AXI_ADDR_WIDTH - 1:0] out_araddr;
    wire [7:0] out_awlen;
    wire [7:0] out_arlen;
    wire [2:0] out_awsize;
    wire [2:0] out_arsize;
    wire [1:0] out_awburst;
    wire [1:0] out_arburst;
    wire out_awvalid;
    wire out_awready;
    wire out_wvalid;
    wire out_wready;
    wire out_wlast;
    wire out_bvalid;
    wire out_bready;
    wire [1:0] out_bresp;
    wire [AXI_DATA_WIDTH - 1:0] out_wdata;
    wire [AXI_DATA_WIDTH - 1:0] out_rdata;
    wire [AXI_DATA_WIDTH / 8 - 1:0] out_wstrb;
    wire out_arvalid;
    wire out_arready;
    wire out_rvalid;
    wire out_rready;
    wire out_rlast;
    wire [1:0] out_rresp;
    wire display_frame_written;
    reg first_display_frame;

    always @(posedge core_clk or negedge arb_wr_rstn) if (! arb_wr_rstn) first_display_frame <= 0;
    else if (display_frame_written) first_display_frame <= 1;
    assign led_first_frame = first_display_frame;
    assign led_camera_ready = camera_control [1] && ! camera_control [0];
    assign led_weights_ready = cnn_params_ready;
    // .IMG_W(CNN_IMG_W),.IMG_H(CNN_IMG_H),.DST_W(1920),.DST_H(1080),
    cnn_hdmi_framebuffer #(
        .IMG_W(CNN_IMG_W),
        .IMG_H(CNN_IMG_H),
        .DST_W(HDMI_VIEW_W),
        .DST_H(HDMI_VIEW_H),
        .H_ACTIVE(MAX_HRES),
        .H_SYNC(HSP),
        .H_BACK(HBP),
        .H_FRONT(HFP),
        .V_ACTIVE(MAX_VRES),
        .V_SYNC(VSP),
        .V_BACK(VBP),
        .V_FRONT(VFP),
        .AXI_WIDTH(AXI_DATA_WIDTH),
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .BASE_ADDR(32'h01000000),
        .FIFO_DEPTH(512),
        .BURST_BEATS(64),
        .RUNTIME_SELECT(1),
        .RAW_W(FB_IMG_W),
        .RAW_H(FB_IMG_H)
    ) u_fb_out (
        .rst_n(vid_rst_n),
        .wr_clk(clk_225M),
        .i_vs(display_vs),
        .i_href(display_href),
        .i_clken(display_valid),
        .i_data(display_data),
        .i_abort(display_abort),
        .axi_clk(core_clk),
        .i_pause(display_control_sync [0]),
        .i_select_raw(display_control_sync [1]),
        .i_camera_frame_toggle(camera_frame_toggle),
        .i_raw_frame_base(raw_display_base),
        .i_raw_frame_available(raw_display_available),
        .o_raw_frame_start(raw_display_start),
        .cnn_read_start(video_read_start),
        .cnn_read_base(video_read_base),
        .cnn_read_used(video_read_used),
        .cnn_read_valid(video_read_valid),
        .cnn_read_pixel(video_read_pixel),
        .cnn_read_complete(video_read_complete),
        .cnn_read_fault(video_read_fault),
        .awaddr(out_awaddr),
        .awlen(out_awlen),
        .awsize(out_awsize),
        .awburst(out_awburst),
        .awvalid(out_awvalid),
        .awready(out_awready),
        .wdata(out_wdata),
        .wstrb(out_wstrb),
        .wlast(out_wlast),
        .wvalid(out_wvalid),
        .wready(out_wready),
        .bvalid(out_bvalid),
        .bresp(out_bresp),
        .bready(out_bready),
        .araddr(out_araddr),
        .arlen(out_arlen),
        .arsize(out_arsize),
        .arburst(out_arburst),
        .arvalid(out_arvalid),
        .arready(out_arready),
        .rdata(out_rdata),
        .rvalid(out_rvalid),
        .rlast(out_rlast),
        .rresp(out_rresp),
        .rready(out_rready),
        .vid_clk(hdmi_tx_slow_clk),
        .o_vs(ch0_vs),
        .o_hs(ch0_hs),
        .o_de(ch0_de),
        .o_data(ch0_vout),
        .o_underflow(),
        .o_request_overflow(),
        .o_write_drop(),
        .o_write_error(),
        .o_read_error(),
        .o_frame_written(display_frame_written),
        .o_frame_available()
    );
    //=====================================================================================
    // 共用 DDR 控制器，输入与输出帧缓存使用独立地址区间。
    // 读主端口 m0：HDMI 输出帧缓存，优先级最高。
    // 读主端口 m1：原图输入帧缓存；m2：DDR 权重。
    // 写主端口 m0：摄像头帧缓存；m1：输出帧缓存；m2：软核加载的风格权重。
    // 两个仲裁器在 DDR 反压时保持有效地址不变。
    // 地址保持及事务归属状态在 DDR 核心时钟域内复位。
    // 读写仲裁模块均已加入工程文件列表。
    rst_n_piple #(
        .DLY(3)
    ) u_arb_wr_rst (
        .clk(core_clk),
        .rst_n_i(w_arstn),
        .rst_n_o(arb_wr_rstn)
    );

    // 读地址优先级在独立地址事务之间进行裁决。
    axi_rd_arb #(
        .AXI_ID_W(AXI_ID_WIDTH),
        .AXI_ADDR_W(AXI_ADDR_WIDTH),
        .AXI_DATA_W(AXI_DATA_WIDTH),
        .M0_ID(0),
        // HDMI 显示读
        .M1_ID(1),
        // CNN 输入读
        .M2_ID(2),
        // 读地址在被接收前保持稳定。
        .HOLD_ON_STALL(1)
    ) u_axi_rd_arb (
        .clk(core_clk),
        .rst_n(arb_wr_rstn),
        // slave侧 → u_ddr3_top
        .s_arid(s_axi_arid),
        .s_araddr(s_axi_araddr),
        .s_arlen(s_axi_arlen),
        .s_arsize(s_axi_arsize),
        .s_arburst(s_axi_arburst),
        .s_arlock(s_axi_arlock),
        .s_arcache(s_axi_arcache),
        .s_arprot(s_axi_arprot),
        .s_arvalid(s_axi_arvalid),
        .s_arready(s_axi_arready),
        .s_rid(s_axi_rid),
        .s_rdata(s_axi_rdata),
        .s_rresp(s_axi_rresp),
        .s_rlast(s_axi_rlast),
        .s_rvalid(s_axi_rvalid),
        .s_rready(s_axi_rready),
        // m0：HDMI 按行读出，优先级最高。
        .m0_arvalid(out_arvalid),
        .m0_araddr(out_araddr),
        .m0_arlen(out_arlen),
        .m0_arsize(out_arsize),
        .m0_arburst(out_arburst),
        .m0_arlock(1'b0),
        .m0_arcache(4'd3),
        .m0_arprot(3'd2),
        .m0_arready(out_arready),
        .m0_rvalid(out_rvalid),
        .m0_rid(),
        .m0_rdata(out_rdata),
        .m0_rresp(out_rresp),
        .m0_rlast(out_rlast),
        .m0_rready(out_rready),
        // m1：原图输入帧缓存读出通路。
        .m1_arvalid(1'b0),
        .m1_araddr(32'd0),
        .m1_arlen(8'd0),
        .m1_arsize(3'd4),
        .m1_arburst(2'd1),
        .m1_arlock(1'b0),
        .m1_arcache(4'd0),
        .m1_arprot(3'd0),
        .m1_arready(),
        .m1_rvalid(),
        .m1_rid(),
        .m1_rdata(),
        .m1_rresp(),
        .m1_rlast(),
        .m1_rready(1'b1),
        // m2: 权重回读，优先级低于显示和输入图像。
        .m2_arvalid(wt_arvalid),
        .m2_araddr(wt_araddr),
        .m2_arlen(wt_arlen),
        .m2_arsize(wt_arsize),
        .m2_arburst(wt_arburst),
        .m2_arlock(1'b0),
        .m2_arcache(4'd0),
        .m2_arprot(3'd0),
        .m2_arready(wt_arready),
        .m2_rvalid(wt_rvalid),
        .m2_rid(),
        .m2_rdata(wt_rdata),
        .m2_rresp(wt_rresp),
        .m2_rlast(wt_rlast),
        .m2_rready(wt_rready)
    );

    //---- 写通道仲裁 (AW/W/B): 轮询 + 整事务独占授权 ----
    axi_wr_arb #(
        .AXI_ID_W(AXI_ID_WIDTH),
        .AXI_ADDR_W(AXI_ADDR_WIDTH),
        .AXI_DATA_W(AXI_DATA_WIDTH),
        .M0_ID(0),
        // 预处理帧写 (checker0/u_fb_in 写侧)
        .M1_ID(1),
        // CNN 输出写
        // DDR测试权重写
        .M2_ID(2)
    ) u_axi_wr_arb (
        .clk(core_clk),
        .rst_n(arb_wr_rstn),
        // slave侧 → u_ddr3_top
        .s_awid(s_axi_awid),
        .s_awaddr(s_axi_awaddr),
        .s_awlen(s_axi_awlen),
        .s_awsize(s_axi_awsize),
        .s_awburst(s_axi_awburst),
        .s_awlock(s_axi_awlock),
        .s_awcache(s_axi_awcache),
        .s_awprot(s_axi_awprot),
        .s_awvalid(s_axi_awvalid),
        .s_awready(s_axi_awready),
        .s_wdata(s_axi_wdata),
        .s_wstrb(s_axi_wstrb),
        .s_wlast(s_axi_wlast),
        .s_wvalid(s_axi_wvalid),
        .s_wready(s_axi_wready),
        .s_bid(s_axi_bid),
        .s_bresp(s_axi_bresp),
        .s_bvalid(s_axi_bvalid),
        .s_bready(s_axi_bready),
        // m0: checker0 写侧 (摄像头/预处理帧写, 最终架构位置不变)
        .m0_awvalid(fb_axi_awvalid),
        .m0_awaddr(fb_axi_awaddr),
        .m0_awlen(fb_axi_awlen),
        .m0_awsize(fb_axi_awsize),
        .m0_awburst(fb_axi_awburst),
        .m0_awlock(fb_axi_awlock),
        .m0_awcache(fb_axi_awcache),
        .m0_awprot(fb_axi_awprot),
        .m0_awready(fb_axi_awready),
        .m0_wvalid(fb_axi_wvalid),
        .m0_wdata(fb_axi_wdata),
        .m0_wstrb(fb_axi_wstrb),
        .m0_wlast(fb_axi_wlast),
        .m0_wready(fb_axi_wready),
        .m0_bvalid(fb_axi_bvalid),
        .m0_bid(fb_axi_bid),
        .m0_bresp(fb_axi_bresp),
        .m0_bready(fb_axi_bready),
        // m1：将稀疏视频流写入输出帧缓存。
        .m1_awvalid(out_awvalid),
        .m1_awaddr(out_awaddr),
        .m1_awlen(out_awlen),
        .m1_awsize(out_awsize),
        .m1_awburst(out_awburst),
        .m1_awlock(1'b0),
        .m1_awcache(4'd3),
        .m1_awprot(3'd2),
        .m1_awready(out_awready),
        .m1_wvalid(out_wvalid),
        .m1_wdata(out_wdata),
        .m1_wstrb(out_wstrb),
        .m1_wlast(out_wlast),
        .m1_wready(out_wready),
        .m1_bvalid(out_bvalid),
        .m1_bid(),
        .m1_bresp(out_bresp),
        .m1_bready(out_bready),
        .m2_awvalid(wt_awvalid),
        .m2_awaddr(wt_awaddr),
        .m2_awlen(wt_awlen),
        .m2_awsize(wt_awsize),
        .m2_awburst(wt_awburst),
        .m2_awlock(1'b0),
        .m2_awcache(4'd0),
        .m2_awprot(3'd0),
        .m2_awready(wt_awready),
        .m2_wvalid(wt_wvalid),
        .m2_wdata(wt_wdata),
        .m2_wstrb(wt_wstrb),
        .m2_wlast(wt_wlast),
        .m2_wready(wt_wready),
        .m2_bvalid(wt_bvalid),
        .m2_bid(),
        .m2_bresp(wt_bresp),
        .m2_bready(wt_bready)
    );

    ddr3_top u_ddr3_top (
        .axi_clk(core_clk),
        .core_clk(core_clk),
        .sdram_clk(sdram_clk),
        .rx_cal_clk(rx_cal_clk),
        .tx_cal_clk(tx_cal_clk),
        .tx_cal_clk_90edge(tx_cal_clk_90edge),
        .rstn(w_arstn),
        .pll_shift(pll_shift),
        .pll_shift_sel(pll_shift_sel),
        .pll_shift_ena(pll_shift_ena),
        //DDR 物理总线
        .ddr_ck_hi(ddr_ck_hi),
        .ddr_ck_lo(ddr_ck_lo),
        .ddr_cke(ddr_cke),
        .ddr_reset_n(ddr_reset_n),
        .ddr_cs_n(ddr_cs_n),
        .ddr_ras_n(ddr_ras_n),
        .ddr_cas_n(ddr_cas_n),
        .ddr_we_n(ddr_we_n),
        .ddr_addr(ddr_addr),
        .ddr_ba(ddr_ba),
        .ddr_dqs_oe(ddr_dqs_oe),
        .ddr_dqs_oe_n(ddr_dqs_oe_n),
        .ddr_dq_oe(ddr_dq_oe),
        .ddr_dqs_in_hi(ddr_dqs_in_hi),
        .ddr_dqs_in_lo(ddr_dqs_in_lo),
        .ddr_dq_in_hi(ddr_dq_in_hi),
        .ddr_dq_in_lo(ddr_dq_in_lo),
        .ddr_dqs_out_hi(ddr_dqs_out_hi),
        .ddr_dqs_out_lo(ddr_dqs_out_lo),
        .ddr_dq_out_hi(ddr_dq_out_hi),
        .ddr_dq_out_lo(ddr_dq_out_lo),
        .ddr_dm_hi(ddr_dm_hi),
        .ddr_dm_lo(ddr_dm_lo),
        .ddr_odt(ddr_odt),
        // 存储器维护请求与应答接口
        .app_sr_req(1'b0),
        .app_ref_req(1'b0),
        .app_zq_req(1'b0),
        .app_sr_active(),
        .app_ref_ack(),
        .app_zq_ack(),
        // DDR 从接口：AXI 写地址通道
        .s_axi_awid(s_axi_awid),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst),
        .s_axi_awlock(s_axi_awlock),
        .s_axi_awcache(s_axi_awcache),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awqos(4'h0),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        // DDR 从接口：AXI 写数据通道
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        // DDR 从接口：AXI 写响应通道
        .s_axi_bid(s_axi_bid),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        // DDR 从接口：AXI 读地址通道
        .s_axi_arid(s_axi_arid),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arlen(s_axi_arlen),
        .s_axi_arsize(s_axi_arsize),
        .s_axi_arburst(s_axi_arburst),
        .s_axi_arlock(s_axi_arlock),
        .s_axi_arcache(s_axi_arcache),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arqos(4'h0),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        // DDR 从接口：AXI 读数据与响应通道
        .s_axi_rid(s_axi_rid),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rlast(s_axi_rlast),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        //DDR 校准诊断输出，当前不接入观察逻辑
        .wrlvl_dq_check(),
        .rd_level_dqs_check(),
        .init_cur_state(),
        .idelay_ld(),
        .mpr_rdlvl_dly(),
        .cal_done(cal_done)
    );

    // HDMI双线性读出与编码器同处148.5MHz域，直接使用显示framebuffer输出。
    // RGB888仍按{B,G,R}排列，不增加调试选择或额外时序延迟。
    wire [7:0] hdmi_tx_rdata;
    wire [7:0] hdmi_tx_gdata;
    wire [7:0] hdmi_tx_bdata;
    wire hdmi_tx_vs = ch0_vs;
    wire hdmi_tx_hs = ch0_hs;
    wire hdmi_tx_de = ch0_de;
    assign { hdmi_tx_bdata, hdmi_tx_gdata, hdmi_tx_rdata } = ch0_vout [23:0];
    //==============================================================================
    // 保留的 MIPI DSI 接口与复位控制
    //==============================================================================
    // 内部信号
    wire w_confdone;
    assign w_confdone = 1'b1;
    assign LCD_POWER = i_arstn;
    assign LCD_RST_P = ~ w_arstn;
    //~r_rst_cnt[23]; LCD复位先释放，然后再释放MIPI 的复位
    assign mipi_dp_clk_RST = ~ i_arstn;
    assign mipi_dp_data0_RST = ~ i_arstn;
    assign mipi_dp_data1_RST = ~ i_arstn;
    assign mipi_dp_data2_RST = ~ i_arstn;
    assign mipi_dp_data3_RST = ~ i_arstn;
    ////////////////////////////////////////////////////////////////
    reg [26:0] dly_cnt = 'd0;

    always @(posedge vid_clk_dvi2 or negedge w_arstn) begin
        if (! w_arstn) dly_cnt <= 'd0;
        else if (w_confdone) dly_cnt <= dly_cnt [26] ? dly_cnt:(dly_cnt + 1'b1);
        else dly_cnt <= 'd0;
    end
    assign vid_rst_n = dly_cnt [26];
    //=================================================================================
    //HDMI 编码与输出控制
    //=================================================================================
    assign tmds_tx_data0_TX_OE = 1'b1;
    assign tmds_tx_data1_TX_OE = 1'b1;
    assign tmds_tx_data2_TX_OE = 1'b1;
    assign tmds_tx_clk_TX_OE = 1'b1;
    assign tmds_tx_data0_TX_RST = 1'b0;
    assign tmds_tx_data1_TX_RST = 1'b0;
    assign tmds_tx_data2_TX_RST = 1'b0;
    assign tmds_tx_clk_TX_RST = 1'b0;
    wire [9:0] tmds_data0;
    wire [9:0] tmds_data1;
    wire [9:0] tmds_data2;
    wire [9:0] tmds_clk;
    hdmi_video_encoder #(
        .VIDEO_VIC(HDMI_VIC)
    ) dvi_encoder_m0 (
        .clk(hdmi_tx_slow_clk),
        .rst_p(~vid_rst_n),
        .rgb({hdmi_tx_rdata, hdmi_tx_gdata, hdmi_tx_bdata}),
        .de(hdmi_tx_de),
        .hs(hdmi_tx_hs),
        .vs(hdmi_tx_vs),
        .blue(tmds_data0),
        .green(tmds_data1),
        .red(tmds_data2),
        .clock_word(tmds_clk)
    );

    assign tmds_tx_clk_TX_DATA = ~ tmds_clk;
    assign tmds_tx_data0_TX_DATA = ~ tmds_data0;
    assign tmds_tx_data1_TX_DATA = ~ tmds_data1;
    assign tmds_tx_data2_TX_DATA = ~ tmds_data2;
endmodule
