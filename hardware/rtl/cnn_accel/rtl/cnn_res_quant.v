// 残差量化调度：深度卷积与逐点卷积共用量化器，并同步传递旁路数据。
`timescale 1ns/1ps

// 用途：让残差块的深度卷积和逐点卷积共用一套量化器，并保持旁路数据对齐。
// 原理：分阶段接收两路累加值，映射到两组通道参数；同时保存旁路字节和通道标签，按下游握手送出结果。
module cnn_res_quant #(
    parameter integer SHARED_QUANT = 0,
    parameter integer SHARED_PARAMS = 0,
    parameter CH = 16,
    parameter IN_ADAPTIVE = 0
) (
    input clk,
    input rst_n,
    input frame_abort,
    input a1_shift,
    input a2_shift,
    input [31:0] a1_data,
    input [31:0] a2_data,
    output loaded,
    input [23:0] dw_acc,
    input [23:0] pw_acc,
    input [7:0] dw_side,
    input [7:0] pw_side,
    input dw_valid,
    input pw_valid,
    output dw_ready,
    output pw_ready,
    output reg [15:0] dw_codes,
    output reg [15:0] dw_shortcut,
    output reg dw_qvalid,
    input dw_out_ready,
    output reg [7:0] branch,
    output reg [7:0] shortcut,
    output reg q_valid,
    input q_ready,
    output o_error,
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
    input wire [59:0] p_response_data
);

    reg phase;
    reg [$clog2(CH) - 1:0] accepted;
    wire ready;
    wire valid;
    wire [2 * CH * 9 - 1:0] result;
    wire dw_space = ! dw_qvalid || dw_out_ready;
    wire pw_space = ! q_valid || q_ready;
    assign dw_ready = ready && ! valid && ! phase && dw_space;
    assign pw_ready = ready && ! valid && phase && pw_space;
    wire take_dw = dw_valid && dw_ready;
    wire take_pw = pw_valid && pw_ready;
    reg tag_pw;
    reg [7:0] side;
    reg pair_half;
    reg [7:0] low_data;
    reg [7:0] low_side;
    cnn_quant #(
        .TRAINED_FORMAT(1),
        .SHARED_ARITH(SHARED_QUANT),
        .SHARED_PARAMS(SHARED_PARAMS),
        .MAC_TERMS(CH),
        .IN_ADAPTIVE(IN_ADAPTIVE),
        .STREAM_INPUT(1),
        .CH(2 * CH),
        .DATA_WIDTH(24),
        .OUTPUT_WIDTH(9),
        .SHIFT_BASE(32),
        .SHIFT_SPAN(15),
        .SIGNED_SECOND_HALF(1),
        .COEF_WIDTH(32)
    ) u_norm (
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
        .a_shift(a1_shift || a2_shift),
        .a_chain_in(a2_shift ? a2_data:a1_data),
        .a_chain_out(),
        .a_loaded(),
        .b_shift(1'b0),
        .b_chain_in(32'd0),
        .b_chain_out(),
        .b_loaded(),
        .bn_loaded(loaded),
        .pre_img_vsync(1'b0),
        .pre_img_href(take_dw || take_pw),
        .pre_img_clken(take_dw || take_pw),
        .pre_img_data({ { ((2 * CH - 1) * 24) { 1'b0 } }, (phase ? pw_acc:dw_acc) }),
        .post_img_vsync(),
        .post_img_href(),
        .post_img_valid(valid),
        .post_img_data(result),
        .frame_abort(frame_abort),
        .o_input_overflow(o_error),
        .o_frame_abort(),
        .o_stream_ready(ready)
    );

    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) begin
            phase <= 0;
            accepted <= 0;
            pair_half <= 0;
            dw_qvalid <= 0;
            q_valid <= 0;
        end else if (frame_abort) begin
            phase <= 0;
            accepted <= 0;
            pair_half <= 0;
            dw_qvalid <= 0;
            q_valid <= 0;
        end else begin
            if (dw_qvalid && dw_out_ready) dw_qvalid <= 0;
            if (q_valid && q_ready) q_valid <= 0;
            if (take_dw || take_pw) begin
                tag_pw <= phase;
                side <= phase ? pw_side:dw_side;
                if (accepted == CH - 1) begin
                    accepted <= 0;
                    phase <= ! phase;
                end else accepted <= accepted + 1'b1;
            end
            if (valid) begin
                if (tag_pw) begin
                    branch <= result [7:0];
                    shortcut <= side;
                    q_valid <= 1;
                end else begin
                    pair_half <= ! pair_half;
                    low_data <= result [7:0];
                    low_side <= side;
                    if (pair_half) begin
                        dw_codes <= { result [7:0], low_data };
                        dw_shortcut <= { side, low_side };
                        dw_qvalid <= 1;
                    end
                end
            end
        end
    end
`ifndef SYNTHESIS

    always @(posedge clk) if (rst_n && ! frame_abort && valid && ((tag_pw && ! pw_space) || (! tag_pw && ! dw_space))) $fatal(1, "SEP5 shared quantizer output overrun");
`endif
endmodule
