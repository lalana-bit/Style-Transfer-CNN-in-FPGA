// 流式卷积单元：通道分组计算，可选最近邻上采样，并完成整数再量化。
`timescale 1ns/1ps

// 用途：实现可配置的流式卷积层，包含参数加载、输入缓存、卷积计算和逐通道量化。
// 原理：串联 FIFO、窗口生成器、分组乘加及量化器，按 GI/GO/PE 调度；支持步长降采样和最近邻上采样取数。
module cnn_conv #(
    parameter integer SHARED_TAIL = 0,
    parameter integer OUTPUT_STATIONARY = 0,
    parameter integer SHARED_QUANT = 0,
    parameter integer SHARED_PARAMS = 0,
    parameter IN_ADAPTIVE = 0,
    parameter integer WINDOW_ROWS = 0,
    parameter integer SIGNED_OUTPUT = 0,
    parameter CI = 16,
    parameter CO = 16,
    parameter K = 3,
    parameter DW = 0,
    parameter STRIDE = 1,
    parameter UP = 0,
    parameter GI = 2,
    parameter GO = 2,
    parameter PE = 4,
    parameter W = 128,
    parameter H = 72,
    parameter IN_DEPTH = 0
) (
    input clk,
    input rst_n,
    input frame_start,
    input frame_abort,
    input wt_shift,
    input a_shift,
    input [7:0] wt_data,
    input [31:0] a_data,
    input [GI * 8 - 1:0] i_data,
    input i_valid,
    output i_ready,
    output reg [GO * 8 - 1:0] o_data,
    output reg o_valid,
    input o_ready,
    output loaded,
    output o_error,
    output o_fault,
    input in_cfg_we,
    input [7:0] in_cfg_channel,
    input signed [19:0] in_cfg_bias,
    input [30:0] in_cfg_multiplier,
    input [5:0] in_cfg_shift,
    output in_stat_valid,
    output [23:0] in_stat_acc,
    output [7:0] in_stat_channel,
    output wire q_request_valid,
    output wire [60:0] q_request_data,
    input wire q_request_ready,
    input wire q_response_valid,
    input wire [8:0] q_response_data,
    output wire p_write_valid,
    output wire [6:0] p_write_address,
    output wire [1:0] p_write_field,
    output wire [19:0] p_write_data,
    output wire p_read_valid,
    output wire [6:0] p_read_address,
    input wire p_read_ready,
    input wire p_response_valid,
    input wire [59:0] p_response_data,
    output wire t_write_valid,
    output wire [4:0] t_write_lane,
    output wire [6:0] t_write_address,
    output wire [7:0] t_write_data,
    output wire t_read_valid,
    output wire [6:0] t_read_address,
    input wire t_read_ready,
    input wire t_response_valid,
    input wire [63:0] t_response_data
);

    localparam NG = CI / GI;
    localparam TAPS = K * K;
    localparam NI = NG * TAPS;
    localparam NF = CO / PE;
    localparam COW = (CO > 1) ? $clog2(CO):1;
    localparam CIW = (CI > 1) ? $clog2(CI):1;
    wire clear = frame_start || frame_abort;
    (* syn_preserve=1 *)
    reg data_rst;

    always @(posedge clk) data_rst <= ! rst_n || clear;
    reg [COW - 1:0] load_co;
    reg [CIW - 1:0] load_ci;
    reg [3:0] load_tap;
    reg weights_loaded;

    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) begin
            load_co <= 0;
            load_ci <= 0;
            load_tap <= 0;
            weights_loaded <= 0;
        end else if (wt_shift && ! weights_loaded) begin
            if (load_tap == TAPS - 1) begin
                load_tap <= 0;
                if (load_ci == (DW ? 0:CI - 1)) begin
                    load_ci <= 0;
                    if (load_co == CO - 1) weights_loaded <= 1;
                    else load_co <= load_co + 1'b1;
                end else load_ci <= load_ci + 1'b1;
            end else load_tap <= load_tap + 1'b1;
        end
    end
    wire [GI * 8 - 1:0] input_data;
    wire input_valid;
    wire input_ready;

    generate
        if (IN_DEPTH > 0 && IN_DEPTH <= 16) begin : g_input_srl
            cnn_stream_fifo #(
                .W(GI * 8),
                .AW($clog2(IN_DEPTH))
            ) q (
                .clk(clk),
                .rst(data_rst),
                .i_data(i_data),
                .i_valid(i_valid),
                .i_ready(i_ready),
                .o_data(input_data),
                .o_valid(input_valid),
                .o_ready(input_ready),
                .count()
            );

        end else if (IN_DEPTH > 0) begin : g_input_fifo
            cnn_ram_fifo #(
                .W(GI * 8),
                .D(IN_DEPTH)
            ) q (
                .clk(clk),
                .rst(data_rst),
                .i_data(i_data),
                .i_valid(i_valid),
                .i_ready(i_ready),
                .o_data(input_data),
                .o_valid(input_valid),
                .o_ready(input_ready)
            );

        end else begin : g_direct
            assign input_data = i_data;
            assign input_valid = i_valid;
            assign i_ready = input_ready;
        end
    endgenerate
    wire [GI * 8 - 1:0] taps;
    wire [3:0] tap;
    wire [7:0] grp;
    wire tap_valid;
    wire tap_ready;

    generate
        if (K == 3) begin : g_window
            if (STRIDE == 1 && ! UP && WINDOW_ROWS != 3) begin : g_two_rows
                cnn_dw_window #(
                    .G(GI),
                    .NG(NG),
                    .W(W),
                    .H(H)
                ) swg (
                    .clk(clk),
                    .rst(data_rst),
                    .i_data(input_data),
                    .i_valid(input_valid),
                    .i_ready(input_ready),
                    .o_data(taps),
                    .o_tap(tap),
                    .o_grp(grp),
                    .o_valid(tap_valid),
                    .o_ready(tap_ready)
                );

            end else begin : g_stride_or_up
                cnn_conv_window #(
                    .G(GI),
                    .NG(NG),
                    .W(W),
                    .H(H),
                    .STRIDE(STRIDE),
                    .UP(UP),
                    .NR(UP ? ((WINDOW_ROWS > 0) ? WINDOW_ROWS : 2) : 3)
                ) swg (
                    .clk(clk),
                    .rst(data_rst),
                    .i_data(input_data),
                    .i_valid(input_valid),
                    .i_ready(input_ready),
                    .o_data(taps),
                    .o_tap(tap),
                    .o_grp(grp),
                    .o_valid(tap_valid),
                    .o_ready(tap_ready)
                );

            end
        end else begin : g_k1
            assign taps = input_data;
            assign tap_valid = input_valid;
            assign input_ready = tap_ready;
            assign tap = 0;
            assign grp = 0;
        end
    endgenerate
    wire [23:0] acc;
    wire mac_valid;
    wire mac_ready;
    wire [11:0] waddr = DW ? ((load_co / GI) * 9 + load_tap):(((load_ci / GI) * TAPS + load_tap) * NF + load_co / PE);
    wire [4:0] wlane = DW ? (load_co % GI):((load_co % PE) * GI + load_ci % GI);

    generate
        if (DW) begin : g_dw
            cnn_dw_mac #(
                .G(GI),
                .NG(NG),
                .ACC_W(24)
            ) mac (
                .clk(clk),
                .rst(data_rst),
                .w_we(wt_shift && ! weights_loaded),
                .w_lane(wlane),
                .w_addr(waddr),
                .w_data({ 24'd0, wt_data }),
                .i_data(taps),
                .i_tap(tap),
                .i_grp(grp),
                .i_valid(tap_valid),
                .i_ready(tap_ready),
                .o_acc(acc),
                .o_side(),
                .o_last(),
                .o_valid(mac_valid),
                .o_ready(mac_ready)
            );

        end else if (OUTPUT_STATIONARY) begin : g_output_major
            cnn_output_mac #(
                .G(GI),
                .NI(NI),
                .COUT(CO),
                .PE(PE),
                .ACC_W(24)
            ) mac (
                .clk(clk),
                .rst(data_rst),
                .w_we(wt_shift && !weights_loaded),
                .w_lane(wlane),
                .w_addr(waddr),
                .w_data({24'd0, wt_data}),
                .i_data(taps),
                .i_valid(tap_valid),
                .i_ready(tap_ready),
                .o_acc(acc),
                .o_last(),
                .o_valid(mac_valid),
                .o_ready(mac_ready)
            );

        end else begin : g_dense
            cnn_dense_mac #(
                .SHARED_TAIL(SHARED_TAIL),
                .G(GI),
                .NI(NI),
                .COUT(CO),
                .PE(PE),
                .ACC_W(24),
                .SIDE_IN(0)
            ) mac (
                .t_write_valid(t_write_valid),
                .t_write_lane(t_write_lane),
                .t_write_address(t_write_address),
                .t_write_data(t_write_data),
                .t_read_valid(t_read_valid),
                .t_read_address(t_read_address),
                .t_read_ready(t_read_ready),
                .t_response_valid(t_response_valid),
                .t_response_data(t_response_data),
                .clk(clk),
                .rst(data_rst),
                .w_we(wt_shift && ! weights_loaded),
                .w_lane(wlane),
                .w_addr(waddr),
                .w_data({ 24'd0, wt_data }),
                .i_data(taps),
                .i_side({ (GI * 8) { 1'b0 } }),
                .i_valid(tap_valid),
                .i_ready(tap_ready),
                .o_acc(acc),
                .o_side(),
                .o_last(),
                .o_valid(mac_valid),
                .o_ready(mac_ready)
            );

        end
    endgenerate
    wire qready;
    wire qvalid;
    wire params_loaded;
    wire qerror;
    wire qfault;
    wire [CO * 9 - 1:0] quant;
    wire space = ! o_valid || o_ready;
    assign mac_ready = qready && space;
    wire take = mac_valid && mac_ready;
    cnn_quant #(
        .TRAINED_FORMAT(1),
        .SHARED_ARITH(SHARED_QUANT),
        .SHARED_PARAMS(SHARED_PARAMS),
        .SIGNED_OUTPUT(SIGNED_OUTPUT),
        .MAC_TERMS(DW ? TAPS : CI * TAPS),
        .IN_ADAPTIVE(IN_ADAPTIVE),
        .STREAM_INPUT(1),
        .CH(CO),
        .DATA_WIDTH(24),
        .OUTPUT_WIDTH(9),
        .COEF_WIDTH(32),
        .SHIFT_BASE(32),
        .SHIFT_SPAN(15)
    ) requant (
        .p_write_valid(p_write_valid),
        .p_write_address(p_write_address),
        .p_write_field(p_write_field),
        .p_write_data(p_write_data),
        .p_read_valid(p_read_valid),
        .p_read_address(p_read_address),
        .p_read_ready(p_read_ready),
        .p_response_valid(p_response_valid),
        .p_response_data(p_response_data),
        .q_request_valid(q_request_valid),
        .q_request_data(q_request_data),
        .q_request_ready(q_request_ready),
        .q_response_valid(q_response_valid),
        .q_response_data(q_response_data),

        .in_cfg_we(in_cfg_we),
        .in_cfg_channel(in_cfg_channel),
        .in_cfg_bias(in_cfg_bias),
        .in_cfg_multiplier(in_cfg_multiplier),
        .in_cfg_shift(in_cfg_shift),
        .in_stat_valid(in_stat_valid),
        .in_stat_acc(in_stat_acc),
        .in_stat_channel(in_stat_channel),
        .clk(clk),
        .rst_n(rst_n),
        .frame_abort(data_rst),
        .a_shift(a_shift),
        .a_chain_in(a_data),
        .a_chain_out(),
        .a_loaded(),
        .b_shift(1'b0),
        .b_chain_in(32'd0),
        .b_chain_out(),
        .b_loaded(),
        .bn_loaded(params_loaded),
        .pre_img_vsync(1'b0),
        .pre_img_href(take),
        .pre_img_clken(take),
        .pre_img_data({ { ((CO - 1) * 24) { 1'b0 } }, acc }),
        .post_img_vsync(),
        .post_img_href(),
        .post_img_valid(qvalid),
        .post_img_data(quant),
        .o_input_overflow(qerror),
        .o_frame_abort(qfault),
        .o_stream_ready(qready)
    );

    localparam OW = (GO > 1) ? $clog2(GO):1;
    reg [OW - 1:0] byte_index;
    reg [GO * 8 - 1:0] pack_data;

    always @(posedge clk) begin
        if (data_rst) begin
            o_valid <= 0;
            byte_index <= 0;
        end else begin
            if (o_valid && o_ready) o_valid <= 0;
            if (qvalid) begin
                pack_data [byte_index * 8+:8] <= quant [7:0];
                if (byte_index == GO - 1) begin
                    o_data <= { quant [7:0], pack_data [(GO - 1) * 8 - 1:0] };
                    o_valid <= 1;
                    byte_index <= 0;
                end else byte_index <= byte_index + 1'b1;
            end
        end
    end
    assign loaded = weights_loaded && params_loaded;
    assign o_error = qerror;
    assign o_fault = qfault && ! clear && ! data_rst;
`ifndef SYNTHESIS
    initial if (CI % GI || CO % GO || (! DW && CO % PE) || GI * PE > 32 || GO < 2 || (DW && GI != 2)) $fatal(1, "Invalid codec grouping");

    always @(posedge clk) if (rst_n && ! clear && qvalid && byte_index == GO - 1 && ! space) $fatal(1, "Codec output pack overflow");
`endif
endmodule
