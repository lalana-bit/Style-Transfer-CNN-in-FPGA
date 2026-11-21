// CNN 总封装：连接 APB 控制、DDR 权重加载及流式计算核心。
`timescale 1ns/1ps
`include "cnn_config.vh"

// 用途：CNN 总封装，连接软核控制、权重加载、实例归一化接口和流式计算核心。
// 原理：通过跨时钟域握手协调各单元；切换权重时排空并复位计算核心及分发器，摄像头与显示继续运行。
module cnn_top #(
    parameter integer H_DISP = 256,
    parameter integer V_DISP = 256,
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_DATA_W = 128,
    parameter [AXI_ADDR_W - 1:0] WEIGHT_BASE_ADDR = `CANDY_TRAINED_BASE_ADDR
) (
    input clk,
    input rst_n,
    input axi_clk,
    input axi_rst_n,
    input calib_done,
    input frame_abort,
    input style_next_toggle,
    input [11:0] boot_paddr,
    input boot_psel,
    input boot_penable,
    input boot_pwrite,
    input [31:0] boot_pwdata,
    output [31:0] boot_prdata,
    output boot_pready,
    output boot_pslverror,
    input pre_img_vsync,
    input pre_img_href,
    input pre_img_clken,
    input [23:0] pre_img_data,
    output post_img_vsync,
    output post_img_href,
    output post_img_valid,
    output [23:0] post_img_data,
    output o_ready,
    output o_busy,
    output o_error,
    output o_weight_error,
    output o_frame_abort,
    output [AXI_ADDR_W - 1:0] awaddr,
    output [AXI_ADDR_W - 1:0] araddr,
    output [7:0] awlen,
    output [7:0] arlen,
    output [2:0] awsize,
    output [2:0] arsize,
    output [1:0] awburst,
    output [1:0] arburst,
    output awvalid,
    input awready,
    output [AXI_DATA_W - 1:0] wdata,
    output [AXI_DATA_W / 8 - 1:0] wstrb,
    output wvalid,
    output wlast,
    input wready,
    input bvalid,
    input [1:0] bresp,
    output bready,
    output arvalid,
    input arready,
    input [AXI_DATA_W - 1:0] rdata,
    input rvalid,
    input rlast,
    input [1:0] rresp,
    output rready
);

    wire [31:0] bus;
    wire [7:0] segment;
    wire shift;
    wire weights_done;
    wire core_ready;
    wire reload_request;
    wire reload_held;
    wire reload_block;
    wire core_rst_n;
    wire reload_abort;
    wire core_busy;
    wire core_abort;
    wire in_select = boot_paddr [11:8] == 4'h1;
    wire [31:0] weight_prdata;
    wire [31:0] in_prdata;
    wire weight_pready;
    wire weight_pslverror;
    wire in_pready;
    wire in_pslverror;
    wire in_cfg_we;
    wire [3:0] in_cfg_layer;
    wire [7:0] in_cfg_channel;
    wire signed [19:0] in_cfg_bias;
    wire [30:0] in_cfg_multiplier;
    wire [5:0] in_cfg_shift;
    wire in_frame_start;
    wire in_frame_end;
    wire in_frame_abort;
    wire [14:0] in_stat_valid;
    wire [359:0] in_stat_acc;
    wire [119:0] in_stat_channel;
    assign boot_prdata = in_select ? in_prdata:weight_prdata;
    assign boot_pready = in_select ? in_pready:weight_pready;
    assign boot_pslverror = in_select ? in_pslverror:weight_pslverror;
    cnn_in #(
        .PIXELS((H_DISP / 4) * (V_DISP / 4))
    ) in_control (
        .pclk(axi_clk),
        .prst_n(axi_rst_n),
        .paddr(boot_paddr [7:0]),
        .psel(boot_psel && in_select),
        .penable(boot_penable),
        .pwrite(boot_pwrite),
        .pwdata(boot_pwdata),
        .prdata(in_prdata),
        .pready(in_pready),
        .pslverror(in_pslverror),
        .clk(clk),
        .rst_n(core_rst_n),
        .core_busy(core_busy),
        .frame_start(in_frame_start),
        .frame_end(in_frame_end),
        .frame_abort(in_frame_abort),
        .stat_valid(in_stat_valid),
        .stat_acc(in_stat_acc),
        .stat_channel(in_stat_channel),
        .cfg_we(in_cfg_we),
        .cfg_layer(in_cfg_layer),
        .cfg_channel(in_cfg_channel),
        .cfg_bias(in_cfg_bias),
        .cfg_multiplier(in_cfg_multiplier),
        .cfg_shift(in_cfg_shift)
    );

    generate
        begin : g_style_reload
            (* ASYNC_REG="TRUE" *)
            reg reload_meta;
            (* ASYNC_REG="TRUE" *)
            reg reload_sync;
            reg reload_seen;
            reg held;
            reg [2:0] drain_guard;

            always @(posedge clk or negedge rst_n) if (! rst_n) begin
                reload_meta <= 0;
                reload_sync <= 0;
            end else begin
                reload_meta <= reload_request;
                reload_sync <= reload_meta;
            end
            // 立即停止送入数据并中止未完成的结果；
            // 等待原中止与排空逻辑完成后，仅复位 CNN 核心和参数分发器。
            // 摄像头、DDR、软核及 HDMI 继续运行。

            always @(posedge clk or negedge rst_n) if (! rst_n) begin
                reload_seen <= 0;
                held <= 0;
                drain_guard <= 0;
            end else begin
                reload_seen <= reload_sync;
                if (! reload_sync) begin
                    held <= 0;
                    drain_guard <= 0;
                end else if (drain_guard != 7) drain_guard <= drain_guard + 1'b1;
                else if (! core_busy) held <= 1;
            end
            assign reload_abort = reload_sync && ! reload_seen;
            assign reload_block = reload_sync || held;
            assign reload_held = held;
            // 在 CNN 时钟域异步置位复位、同步释放复位。
            (* ASYNC_REG="TRUE" *)
            reg [1:0] reset_release;
            wire local_rst_n = rst_n && ! held;

            always @(posedge clk or negedge local_rst_n) if (! local_rst_n) reset_release <= 0;
            else reset_release <= { reset_release [0], 1'b1 };
            assign core_rst_n = reset_release [1];
        end
    endgenerate
    cnn_weights #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_DATA_W(AXI_DATA_W),
        .BASE_ADDR(WEIGHT_BASE_ADDR)
    ) u_weights (
        .axi_clk(axi_clk),
        .axi_rst_n(axi_rst_n),
        .calib_done(calib_done),
        .cnn_clk(clk),
        .cnn_rst_n(core_rst_n),
        .reload_request(reload_request),
        .reload_held(reload_held),
        .style_next_toggle(style_next_toggle),
        .boot_paddr(boot_paddr),
        .boot_psel(boot_psel && ! in_select),
        .boot_penable(boot_penable),
        .boot_pwrite(boot_pwrite),
        .boot_pwdata(boot_pwdata),
        .boot_prdata(weight_prdata),
        .boot_pready(weight_pready),
        .boot_pslverror(weight_pslverror),
        .boot_params_ready(o_ready),
        .awaddr(awaddr),
        .awlen(awlen),
        .awsize(awsize),
        .awburst(awburst),
        .awvalid(awvalid),
        .awready(awready),
        .wdata(wdata),
        .wstrb(wstrb),
        .wvalid(wvalid),
        .wlast(wlast),
        .wready(wready),
        .bvalid(bvalid),
        .bresp(bresp),
        .bready(bready),
        .araddr(araddr),
        .arlen(arlen),
        .arsize(arsize),
        .arburst(arburst),
        .arvalid(arvalid),
        .arready(arready),
        .rdata(rdata),
        .rvalid(rvalid),
        .rlast(rlast),
        .rresp(rresp),
        .rready(rready),
        .wt_bus(bus),
        .wt_shift(shift),
        .wt_seg(segment),
        .o_done(weights_done),
        .o_error(o_weight_error)
    );

    cnn_core #(
        .H_DISP(H_DISP),
        .V_DISP(V_DISP)
    ) u_network (
        .clk(clk),
        .rst_n(core_rst_n),
        .frame_abort((frame_abort && ! reload_block) || reload_abort),
        .weights_done(weights_done && ! o_weight_error),
        .wt_bus(bus),
        .wt_seg(segment),
        .wt_shift(shift),
        .in_cfg_we(in_cfg_we),
        .in_cfg_layer(in_cfg_layer),
        .in_cfg_channel(in_cfg_channel),
        .in_cfg_bias(in_cfg_bias),
        .in_cfg_multiplier(in_cfg_multiplier),
        .in_cfg_shift(in_cfg_shift),
        .in_frame_start(in_frame_start),
        .in_frame_end(in_frame_end),
        .in_frame_abort(in_frame_abort),
        .in_stat_valid(in_stat_valid),
        .in_stat_acc(in_stat_acc),
        .in_stat_channel(in_stat_channel),
        .pre_img_vsync(pre_img_vsync && ! reload_block),
        .pre_img_href(pre_img_href && ! reload_block),
        .pre_img_clken(pre_img_clken && ! reload_block),
        .pre_img_data(pre_img_data),
        .post_img_vsync(post_img_vsync),
        .post_img_href(post_img_href),
        .post_img_valid(post_img_valid),
        .post_img_data(post_img_data),
        .o_ready(core_ready),
        .o_busy(core_busy),
        .o_error(o_error),
        .o_frame_abort(core_abort)
    );

    // 实例归一化在后台读取冻结的历史统计量，并写入备用系数区。
    // 统计读取和参数写入均不暂停视频桥接。
    assign o_ready = core_ready && ! o_weight_error && ! reload_block;
    assign o_busy = core_busy || reload_block;
    assign o_frame_abort = core_abort || reload_block;
endmodule
