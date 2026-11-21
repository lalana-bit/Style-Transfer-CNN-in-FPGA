// 计算核心：前置卷积、编码器、五个残差块及两级卷积解码器。
`timescale 1ns/1ps
`include "cnn_config.vh"

// 用途：组织完整的前置卷积、编码、五级残差和解码网络，并管理帧启动与故障中止。
// 原理：串联六个卷积单元和五个残差块，层间使用数据握手，经过输入/输出查表后按原九拍节奏输出。
module cnn_core #(
    parameter integer H_DISP = 256,
    parameter integer V_DISP = 256
) (
    input clk,
    input rst_n,
    input frame_abort,
    input weights_done,
    input wt_shift,
    input [7:0] wt_seg,
    input [31:0] wt_bus,
    input pre_img_vsync,
    input pre_img_href,
    input pre_img_clken,
    input [23:0] pre_img_data,
    output reg post_img_vsync,
    output reg post_img_valid,
    output post_img_href,
    output reg [23:0] post_img_data,
    output o_ready,
    output o_busy,
    output o_error,
    output reg o_frame_abort,
    input in_cfg_we,
    input [3:0] in_cfg_layer,
    input [7:0] in_cfg_channel,
    input signed [19:0] in_cfg_bias,
    input [30:0] in_cfg_multiplier,
    input [5:0] in_cfg_shift,
    output in_frame_start,
    output in_frame_end,
    output in_frame_abort,
    output [14:0] in_stat_valid,
    output [359:0] in_stat_acc,
    output [119:0] in_stat_channel
);

`ifdef CNN_STANDARD_FIRST
    localparam integer STANDARD_FIRST = 1;
`else
    localparam integer STANDARD_FIRST = 0;
`endif
    localparam integer QUANT_CLIENTS = STANDARD_FIRST ? 10 : 9;
    localparam PIXELS = H_DISP * V_DISP;
    localparam PCW = $clog2(PIXELS + 1);
    localparam XW = $clog2(H_DISP);
    reg vs_d;
    reg active;
    reg error;
    reg row_open;
    reg first_pending;
    reg [5:0] abort_count;
    (* syn_preserve=1 *)
    reg abort_guard;
    reg [PCW - 1:0] input_count;
    reg [PCW - 1:0] pixel_count;
    reg [XW - 1:0] out_col;
    reg [23:0] first_pixel;
    wire abort_active = frame_abort || abort_guard;
    wire [5:0] codec_loaded;
    wire [5:0] codec_error;
    wire [5:0] codec_fault;
    wire [4:0] res_loaded;
    wire [4:0] res_busy;
    wire [4:0] res_error;
    wire [4:0] res_fault;
    reg input_loaded;
    reg output_loaded;
    reg [7:0] input_index;
    reg [6:0] output_index;
    // RGB沿gap9分三拍查表，每张表只需要一个同步读口。
    // 256字节输入查表按原扫描顺序保存到 SRL，保留一拍读延迟。
    // 输出仅128字节查表，复用字节 SRL 存储，保留原扫描与同步读节拍。
    reg [2:0] input_lookup_step;
    reg [23:0] input_pixel_hold;
    wire [7:0] input_lookup_q;
    reg [2:0] output_lookup_step;
    reg [23:0] output_pixel_hold;
    reg [15:0] output_partial;
    wire [7:0] output_lookup_q;
    reg output_first;
    reg output_last;
    wire output_lookup_valid = output_lookup_step == 4;
    wire [23:0] output_color = {output_lookup_q, output_partial};
    wire all_loaded = (& codec_loaded) && (& res_loaded) && input_loaded && output_loaded;
    // 每拍寄存参数就绪状态，避免跨层与门树进入帧启动和数据使能的高扇出路径。
    // 该寄存仅使启动就绪延后一个时钟周期。
    (* syn_preserve=1 *)
    reg all_loaded_q;

    always @(posedge clk or negedge rst_n) if (! rst_n) all_loaded_q <= 0;
    else all_loaded_q <= all_loaded;
    assign o_ready = all_loaded_q && weights_done && ! abort_active && ! o_frame_abort;
    assign o_busy = active || abort_active || post_img_valid || first_pending || o_frame_abort || output_lookup_step != 0;
    assign o_error = error || (| codec_error) || (| res_error);
    assign post_img_href = (row_open || post_img_valid) && ! abort_active;
    wire frame_head = pre_img_vsync && ! vs_d;
    wire start = frame_head && o_ready && ! active;
    assign in_frame_start = start;
    assign in_frame_end = pixel_fire && pixel_count == PIXELS - 1;
    assign in_frame_abort = abort_active || fault_now;
    wire [4:0] res_stv;
    wire [119:0] res_sta;
    wire [39:0] res_stc;
    wire data_clear = start || abort_active;
    localparam integer DW_CLIENTS=STANDARD_FIRST?3:5;
    wire [DW_CLIENTS-1:0] dw_write_valid;
    wire [DW_CLIENTS-1:0] dw_write_half;
    wire [DW_CLIENTS-1:0] dw_read_valid;
    wire [DW_CLIENTS-1:0] dw_read_ready;
    wire [DW_CLIENTS-1:0] dw_response_valid;
    wire [DW_CLIENTS*8-1:0] dw_write_address;
    wire [DW_CLIENTS*8-1:0] dw_write_data;
    wire [DW_CLIENTS*8-1:0] dw_read_address;
    wire [15:0] dw_response_data;
    cnn_dw_weight_store #(
        .CLIENTS(DW_CLIENTS)
    ) dw_weight_memory(
        .clk(clk),
        .rst_n(rst_n),
        .clear(data_clear),
        .write_valid(dw_write_valid),
        .write_address(dw_write_address),
        .write_half(dw_write_half),
        .write_data(dw_write_data),
        .read_valid(dw_read_valid),
        .read_address(dw_read_address),
        .read_ready(dw_read_ready),
        .response_valid(dw_response_valid),
        .response_data(dw_response_data)
    );

    // 每个标准残差的两层共享尾部128行，两个池合计8块RAM；主体1024行仍独立读取。
    wire [3:0] tail_write_valid;
    wire [19:0] tail_write_lane;
    wire [27:0] tail_write_address;
    wire [31:0] tail_write_data;
    wire [3:0] tail_read_valid;
    wire [27:0] tail_read_address;
    wire [3:0] tail_read_ready;
    wire [3:0] tail_response_valid;
    wire [127:0] tail_response_data;
    genvar tail_pair;
    generate for (tail_pair=0; tail_pair<2; tail_pair=tail_pair+1) begin : g_tail_pair
        wire [3:0] ready_pair;
        wire [3:0] response_pair;
        assign tail_read_ready[tail_pair*2+:2] = ready_pair[1:0];
        assign tail_response_valid[tail_pair*2+:2] = response_pair[1:0];
        cnn_tail_store tail_memory (
            .clk(clk),
            .rst_n(rst_n),
            .clear(data_clear),
            .write_valid({2'd0, tail_write_valid[tail_pair*2+:2]}),
            .write_lane({10'd0, tail_write_lane[tail_pair*10+:10]}),
            .write_address({14'd0, tail_write_address[tail_pair*14+:14]}),
            .write_data({16'd0, tail_write_data[tail_pair*16+:16]}),
            .read_valid({2'd0, tail_read_valid[tail_pair*2+:2]}),
            .read_address({14'd0, tail_read_address[tail_pair*14+:14]}),
            .read_ready(ready_pair),
            .response_valid(response_pair),
            .response_data(tail_response_data[tail_pair*64+:64])
        );
    end endgenerate

    wire [9:0] arithmetic_slot;
    wire [QUANT_CLIENTS-1:0] param_write_valid;
    wire [QUANT_CLIENTS*7-1:0] param_write_address;
    wire [QUANT_CLIENTS*2-1:0] param_write_field;
    wire [QUANT_CLIENTS*20-1:0] param_write_data;
    wire [QUANT_CLIENTS-1:0] param_read_valid;
    wire [QUANT_CLIENTS*7-1:0] param_read_address;
    wire [QUANT_CLIENTS-1:0] param_read_ready;
    wire [QUANT_CLIENTS-1:0] param_response_valid;
    wire [59:0] param_response_data;
    cnn_param_store #(
        .CLIENTS(QUANT_CLIENTS),
        .STANDARD_FIRST(STANDARD_FIRST)
    ) parameter_memory(
        .clk(clk),
        .rst_n(rst_n),
        .clear(data_clear),
        .arithmetic_slot(arithmetic_slot),
        .write_valid(param_write_valid),
        .write_address(param_write_address),
        .write_field(param_write_field),
        .write_data(param_write_data),
        .read_valid(param_read_valid),
        .read_address(param_read_address),
        .read_ready(param_read_ready),
        .response_valid(param_response_valid),
        .response_data(param_response_data)
    );

    // 输入/输出端保留独立量化器；中间九个客户端使用固定十拍时隙。
    wire [QUANT_CLIENTS-1:0] quant_request;
    wire [QUANT_CLIENTS*61-1:0] quant_arguments;
    wire [QUANT_CLIENTS-1:0] quant_grant;
    wire [QUANT_CLIENTS-1:0] quant_response;
    wire [8:0] quant_result;
    cnn_requant_pipe #(
        .CLIENTS(QUANT_CLIENTS)
    ) requant_service (
        .slot_state(arithmetic_slot),
        .clk(clk),
        .rst_n(rst_n),
        .clear(data_clear),
        .request_valid(quant_request),
        .request_data(quant_arguments),
        .request_ready(quant_grant),
        .response_valid(quant_response),
        .response_data(quant_result)
    );

    wire data_rst = ! rst_n || data_clear;
    reg in_valid;
    reg [23:0] in_data;
    wire input_ready;
    wire input_take = pre_img_href && pre_img_clken && active && ! abort_active && ! frame_head;
    wire input_fault = (in_valid && ! input_ready) ||
                       (input_take && (input_count >= PIXELS || input_lookup_step != 0)) ||
                       (frame_head && active);

    wire [7:0] input_lookup_address = (input_lookup_step == 1) ? input_pixel_hold[23:16] :
                                      (input_lookup_step == 2) ? input_pixel_hold[15:8] :
                                                                 input_pixel_hold[7:0];
    wire [6:0] output_lookup_address = (output_lookup_step == 1) ? output_pixel_hold[6:0] :
                                       (output_lookup_step == 2) ? output_pixel_hold[14:8] :
                                                                   output_pixel_hold[22:16];

    cnn_weight_rows #(
        .LANES(1),
        .LOAD_GROUPS(1),
        .DEPTH(256),
        .AW(8)
    ) input_table(
        .clk(clk),
        .we(wt_shift && wt_seg==`CNN_TRAINED_INPUT_SEG && !input_loaded),
        .re(input_lookup_step>=1 && input_lookup_step<=3),
        .lane(5'd0),
        .wa(input_index),
        .ra(input_lookup_address),
        .din(wt_bus[7:0]),
        .rdata(input_lookup_q)
    );

    cnn_weight_rows #(
        .LANES(1),
        .LOAD_GROUPS(1),
        .DEPTH(128),
        .AW(7)
    ) output_table(
        .clk(clk),
        .we(wt_shift && wt_seg==`CNN_TRAINED_OUTPUT_SEG && !output_loaded),
        .re(output_lookup_step>=1 && output_lookup_step<=3),
        .lane(5'd0),
        .wa(output_index),
        .ra(output_lookup_address),
        .din(wt_bus[7:0]),
        .rdata(output_lookup_q)
    );


    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) begin
            input_index <= 0;
            output_index <= 0;
            input_loaded <= 0;
            output_loaded <= 0;
            vs_d <= 0;
            in_valid <= 0;
            input_lookup_step <= 0;
            input_count <= 0;
        end else begin
            vs_d <= pre_img_vsync;
            if (wt_shift && wt_seg == `CNN_TRAINED_INPUT_SEG && ! input_loaded) begin
                input_index <= input_index + 1'b1;
                if (input_index == 255) input_loaded <= 1;
            end
            if (wt_shift && wt_seg == `CNN_TRAINED_OUTPUT_SEG && ! output_loaded) begin
                output_index <= output_index + 1'b1;
                if (output_index == 127) output_loaded <= 1;
            end
            in_valid <= 0;
            if (data_clear) begin
                input_lookup_step <= 0;
                input_count <= 0;
            end else begin
                if (input_take) begin
                    input_pixel_hold <= pre_img_data;
                    input_lookup_step <= 1;
                    input_count <= input_count + 1'b1;
                end else if (input_lookup_step != 0) begin
                    input_lookup_step <= (input_lookup_step == 4) ? 0 : input_lookup_step + 1'b1;
                end
                case (input_lookup_step)
                    2: in_data[7:0] <= input_lookup_q;
                    3: in_data[15:8] <= input_lookup_q;
                    4: begin
                        in_data[23:16] <= input_lookup_q;
                        in_valid <= 1;
                    end
                endcase
            end
        end
    end
    // 全分辨率 3→8 前置卷积。FIFO 吸收有效行突发数据，
    // 保留 2048 像素缓存吸收 gap9 有效行突发；中间层改用 16/32 字浅缓存。
    // 量化器按原时序依次处理每个像素的八个通道。
    wire [15:0] stem_data;
    wire stem_valid;
    wire stem_ready;
    cnn_conv #(
        .OUTPUT_STATIONARY(1),
        .IN_ADAPTIVE(1),
        .CI(3),
        .CO(8),
        .STRIDE(1),
        .GI(3),
        .GO(2),
        .PE(2),
        .W(H_DISP),
        .H(V_DISP),
        .IN_DEPTH(2048)
    ) stem (
        .in_cfg_we(in_cfg_we && in_cfg_layer == 0),
        .in_cfg_channel(in_cfg_channel),
        .in_cfg_bias(in_cfg_bias),
        .in_cfg_multiplier(in_cfg_multiplier),
        .in_cfg_shift(in_cfg_shift),
        .in_stat_valid(in_stat_valid [0]),
        .in_stat_acc(in_stat_acc [0+:24]),
        .in_stat_channel(in_stat_channel [0+:8]),
        .clk(clk),
        .rst_n(rst_n),
        .frame_start(start),
        .frame_abort(abort_active),
        .wt_shift(wt_shift && wt_seg == 0),
        .wt_data(wt_bus [7:0]),
        .a_shift(wt_shift && wt_seg == 1),
        .a_data(wt_bus),
        .i_data(in_data),
        .i_valid(in_valid),
        .i_ready(input_ready),
        .o_data(stem_data),
        .o_valid(stem_valid),
        .o_ready(stem_ready),
        .loaded(codec_loaded [0]),
        .o_error(codec_error [0]),
        .o_fault(codec_fault [0])
    );

    wire [15:0] enc1_data;
    wire enc1_valid;
    wire enc1_ready;
    cnn_conv #(
        .SHARED_QUANT(1),
        .SHARED_PARAMS(1),
        .IN_ADAPTIVE(1),
        .CI(8),
        .CO(16),
        .STRIDE(2),
        .GI(2),
        .GO(2),
        .PE(2),
        .W(H_DISP),
        .H(V_DISP),
        .IN_DEPTH(16)
    ) enc1 (
        .p_write_valid(param_write_valid[0]),
        .p_write_address(param_write_address[0*7+:7]),
        .p_write_field(param_write_field[0*2+:2]),
        .p_write_data(param_write_data[0*20+:20]),
        .p_read_valid(param_read_valid[0]),
        .p_read_address(param_read_address[0*7+:7]),
        .p_read_ready(param_read_ready[0]),
        .p_response_valid(param_response_valid[0]),
        .p_response_data(param_response_data),
        .q_request_valid(quant_request[0]),
        .q_request_data(quant_arguments[(0)*61 +: 61]),
        .q_request_ready(quant_grant[0]),
        .q_response_valid(quant_response[0]),
        .q_response_data(quant_result),

        .in_cfg_we(in_cfg_we && in_cfg_layer == 1),
        .in_cfg_channel(in_cfg_channel),
        .in_cfg_bias(in_cfg_bias),
        .in_cfg_multiplier(in_cfg_multiplier),
        .in_cfg_shift(in_cfg_shift),
        .in_stat_valid(in_stat_valid [1]),
        .in_stat_acc(in_stat_acc [24+:24]),
        .in_stat_channel(in_stat_channel [8+:8]),
        .clk(clk),
        .rst_n(rst_n),
        .frame_start(start),
        .frame_abort(abort_active),
        .wt_shift(wt_shift && wt_seg == 3),
        .wt_data(wt_bus [7:0]),
        .a_shift(wt_shift && wt_seg == 4),
        .a_data(wt_bus),
        .i_data(stem_data),
        .i_valid(stem_valid),
        .i_ready(stem_ready),
        .o_data(enc1_data),
        .o_valid(enc1_valid),
        .o_ready(enc1_ready),
        .loaded(codec_loaded [1]),
        .o_error(codec_error [1]),
        .o_fault(codec_fault [1])
    );

    wire [255:0] enc2_data;
    wire enc2_valid;
    wire enc2_ready;
    cnn_conv #(
        .SHARED_QUANT(1),
        .SHARED_PARAMS(1),
        .IN_ADAPTIVE(1),
        .CI(16),
        .CO(32),
        .STRIDE(2),
        .GI(2),
        .GO(32),
        .PE(2),
        .W(H_DISP / 2),
        .H(V_DISP / 2),
        .IN_DEPTH(16)
    ) enc2 (
        .p_write_valid(param_write_valid[1]),
        .p_write_address(param_write_address[1*7+:7]),
        .p_write_field(param_write_field[1*2+:2]),
        .p_write_data(param_write_data[1*20+:20]),
        .p_read_valid(param_read_valid[1]),
        .p_read_address(param_read_address[1*7+:7]),
        .p_read_ready(param_read_ready[1]),
        .p_response_valid(param_response_valid[1]),
        .p_response_data(param_response_data),
        .q_request_valid(quant_request[1]),
        .q_request_data(quant_arguments[(1)*61 +: 61]),
        .q_request_ready(quant_grant[1]),
        .q_response_valid(quant_response[1]),
        .q_response_data(quant_result),

        .in_cfg_we(in_cfg_we && in_cfg_layer == 2),
        .in_cfg_channel(in_cfg_channel),
        .in_cfg_bias(in_cfg_bias),
        .in_cfg_multiplier(in_cfg_multiplier),
        .in_cfg_shift(in_cfg_shift),
        .in_stat_valid(in_stat_valid [2]),
        .in_stat_acc(in_stat_acc [71:48]),
        .in_stat_channel(in_stat_channel [23:16]),
        .clk(clk),
        .rst_n(rst_n),
        .frame_start(start),
        .frame_abort(abort_active),
        .wt_shift(wt_shift && wt_seg == 6),
        .wt_data(wt_bus [7:0]),
        .a_shift(wt_shift && wt_seg == 7),
        .a_data(wt_bus),
        .i_data(enc1_data),
        .i_valid(enc1_valid),
        .i_ready(enc1_ready),
        .o_data(enc2_data),
        .o_valid(enc2_valid),
        .o_ready(enc2_ready),
        .loaded(codec_loaded [2]),
        .o_error(codec_error [2]),
        .o_fault(codec_fault [2])
    );

    // 保持残差块先接收帧头、再接收首个通道向量的时序约定。
    wire [5:0] rv;
    wire [5:0] rh;
    wire [5:0] re;
    wire [255:0] rd [0:5];
    reg first_vector;
    reg vector_pending;
    reg vector_vs;
    reg vector_valid;
    reg [255:0] vector_hold;
    reg [255:0] vector_data;
    wire first_res_ready;
    assign enc2_ready = ! vector_pending && ! abort_guard && first_res_ready;

    always @(posedge clk) begin
        if (data_rst) begin
            first_vector <= 1;
            vector_pending <= 0;
            vector_vs <= 0;
            vector_valid <= 0;
        end else begin
            vector_vs <= 0;
            vector_valid <= 0;
            if (vector_pending) begin
                vector_data <= vector_hold;
                vector_valid <= 1;
                vector_pending <= 0;
            end else if (enc2_valid && enc2_ready) begin
                if (first_vector) begin
                    vector_hold <= enc2_data;
                    vector_vs <= 1;
                    vector_pending <= 1;
                    first_vector <= 0;
                end else begin
                    vector_data <= enc2_data;
                    vector_valid <= 1;
                end
            end
        end
    end
    assign rv [0] = vector_vs;
    assign rh [0] = vector_valid;
    assign re [0] = vector_valid;
    assign rd [0] = vector_data;
    // 第二残差原先共用的槽位留空，其余九层仍使用原有十拍服务。
    assign quant_request[3] = 1'b0;
    assign quant_arguments[3*61+:61] = 61'd0;
    genvar b;

    generate
        for (b = 0; b < 5; b = b + 1) begin : g_residual
            if (STANDARD_FIRST && b == 0) begin : g_standard
                wire [1:0] stat_valid;
                wire [47:0] stat_acc;
                wire [15:0] stat_channel;
                wire [1:0] request_valid;
                wire [121:0] request_data;
                assign in_stat_valid[3] = stat_valid[0];
                assign in_stat_valid[4] = stat_valid[1];
                assign in_stat_acc[3*24+:24] = stat_acc[0+:24];
                assign in_stat_acc[4*24+:24] = stat_acc[24+:24];
                assign in_stat_channel[3*8+:8] = stat_channel[0+:8];
                assign in_stat_channel[4*8+:8] = stat_channel[8+:8];
                assign quant_request[2] = request_valid[0];
                assign quant_request[9] = request_valid[1];
                assign quant_arguments[2*61+:61] = request_data[0+:61];
                assign quant_arguments[9*61+:61] = request_data[61+:61];
                assign res_stv[0] = 1'b0;
                assign res_sta[0+:24] = 24'd0;
                assign res_stc[0+:8] = 8'd0;
                cnn_standard_resblock #(
                    .SHARED_TAIL(1),
                    .SHARED_PARAMS(1),
                    .SKIP_WORDS(2560),
                    .PE(4),
                    .CH(32),
                    .H_DISP(H_DISP / 4),
                    .V_DISP(V_DISP / 4)
                ) residual (
                    .t_write_valid(tail_write_valid[0+:2]),
                    .t_write_lane(tail_write_lane[0+:10]),
                    .t_write_address(tail_write_address[0+:14]),
                    .t_write_data(tail_write_data[0+:16]),
                    .t_read_valid(tail_read_valid[0+:2]),
                    .t_read_address(tail_read_address[0+:14]),
                    .t_read_ready(tail_read_ready[0+:2]),
                    .t_response_valid(tail_response_valid[0+:2]),
                    .t_response_data(tail_response_data[0+:64]),
                    .p_write_valid({param_write_valid[9],param_write_valid[2]}),
                    .p_write_address({param_write_address[63+:7],param_write_address[14+:7]}),
                    .p_write_field({param_write_field[18+:2],param_write_field[4+:2]}),
                    .p_write_data({param_write_data[180+:20],param_write_data[40+:20]}),
                    .p_read_valid({param_read_valid[9],param_read_valid[2]}),
                    .p_read_address({param_read_address[63+:7],param_read_address[14+:7]}),
                    .p_read_ready({param_read_ready[9],param_read_ready[2]}),
                    .p_response_valid({param_response_valid[9],param_response_valid[2]}),
                    .p_response_data(param_response_data),
                    .clk(clk),
                    .rst_n(rst_n),
                    .frame_abort(abort_active),
                    .wt1_shift(wt_shift && wt_seg == 9),
                    .wt2_shift(wt_shift && wt_seg == 12),
                    .wt_data(wt_bus[7:0]),
                    .a1_shift(wt_shift && wt_seg == 10),
                    .a2_shift(wt_shift && wt_seg == 13),
                    .a_data(wt_bus),
                    .param_shift(wt_shift && wt_seg == `CNN_TRAINED_RES_SEG),
                    .param_data(wt_bus[7:0]),
                    .pre_img_vsync(rv[0]),
                    .pre_img_href(rh[0]),
                    .pre_img_clken(re[0]),
                    .pre_img_data(rd[0]),
                    .input_ready(first_res_ready),
                    .post_img_vsync(rv[1]),
                    .post_img_href(rh[1]),
                    .post_img_valid(re[1]),
                    .post_img_data(rd[1]),
                    .blk_loaded(res_loaded[0]),
                    .o_busy(res_busy[0]),
                    .o_error(res_error[0]),
                    .o_frame_abort(res_fault[0]),
                    .in_cfg_we(in_cfg_we && (in_cfg_layer == 3 || in_cfg_layer == 4)),
                    .in_cfg_channel(in_cfg_channel + ((in_cfg_layer == 4) ? 8'd32 : 8'd0)),
                    .in_cfg_bias(in_cfg_bias),
                    .in_cfg_multiplier(in_cfg_multiplier),
                    .in_cfg_shift(in_cfg_shift),
                    .in_stat_valid(stat_valid),
                    .in_stat_acc(stat_acc),
                    .in_stat_channel(stat_channel),
                    .q_request_valid(request_valid),
                    .q_request_data(request_data),
                    .q_request_ready({quant_grant[9],quant_grant[2]}),
                    .q_response_valid({quant_response[9],quant_response[2]}),
                    .q_response_data(quant_result)
                );
            end else if (STANDARD_FIRST && b == 1) begin : g_standard
                wire [1:0] stat_valid;
                wire [47:0] stat_acc;
                wire [15:0] stat_channel;
                wire [1:0] request_valid;
                wire [121:0] request_data;
                assign in_stat_valid[5] = stat_valid[0];
                assign in_stat_valid[6] = stat_valid[1];
                assign in_stat_acc[5*24+:24] = stat_acc[0+:24];
                assign in_stat_acc[6*24+:24] = stat_acc[24+:24];
                assign in_stat_channel[5*8+:8] = stat_channel[0+:8];
                assign in_stat_channel[6*8+:8] = stat_channel[8+:8];
                assign res_stv[1] = 1'b0;
                assign res_sta[24+:24] = 24'd0;
                assign res_stc[8+:8] = 8'd0;
                // 第二标准块复用公共表原客户端3的128条空记录，独立再量化节拍保持。
                wire [1:0] local_grant;
                wire [1:0] local_response;
                wire [8:0] local_result;
                cnn_requant_pipe #(
                    .CLIENTS(10)
                ) local_requant (
                    .clk(clk),
                    .rst_n(rst_n),
                    .clear(data_clear),
                    .request_valid({8'd0, request_valid}),
                    .request_data({488'd0, request_data}),
                    .request_ready(local_grant),
                    .response_valid(local_response),
                    .response_data(local_result),
                    .slot_state()
                );
                wire [1:0] pw_valid;
                wire [13:0] pw_address;
                wire [3:0] pw_field;
                wire [39:0] pw_data;
                wire [1:0] pr_valid;
                wire [13:0] pr_address;
                wire [1:0] pr_ready;
                wire [1:0] pr_response;
                reg prefer_second;
                reg response_second;
                wire select_second = pr_valid[1] && (!pr_valid[0] || prefer_second);
                wire read_fire = param_read_valid[3] && param_read_ready[3];
                // 两层各64条记录：低半区conv1，高半区conv2；原活动/备用区各32条。
                assign param_write_valid[3] = |pw_valid;
                assign param_write_address[3*7+:7] = pw_valid[0] ? {1'b0, pw_address[5:0]} : {1'b1, pw_address[12:7]};
                assign param_write_field[3*2+:2] = pw_valid[0] ? pw_field[1:0] : pw_field[3:2];
                assign param_write_data[3*20+:20] = pw_valid[0] ? pw_data[19:0] : pw_data[39:20];
                assign param_read_valid[3] = |pr_valid;
                assign param_read_address[3*7+:7] = select_second ? {1'b1, pr_address[12:7]} : {1'b0, pr_address[5:0]};
                assign pr_ready = {param_read_ready[3] && select_second, param_read_ready[3] && !select_second};
                assign pr_response = {param_response_valid[3] && response_second, param_response_valid[3] && !response_second};
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        prefer_second <= 0;
                        response_second <= 0;
                    end else if (data_clear) begin
                        prefer_second <= 0;
                        response_second <= 0;
                    end else if (read_fire) begin
                        prefer_second <= !select_second;
                        response_second <= select_second;
                    end
                end
`ifndef SYNTHESIS
                always @(posedge clk) if (rst_n && pw_valid == 2'b11)
                    $fatal(1, "Two parameter writers at once");
`endif
                cnn_standard_resblock #(
                    .SHARED_TAIL(1),
                    .SHARED_PARAMS(1),
                    .SKIP_WORDS(2560),
                    .PE(4),
                    .CH(32),
                    .H_DISP(H_DISP / 4),
                    .V_DISP(V_DISP / 4)
                ) residual (
                    .t_write_valid(tail_write_valid[2+:2]),
                    .t_write_lane(tail_write_lane[10+:10]),
                    .t_write_address(tail_write_address[14+:14]),
                    .t_write_data(tail_write_data[16+:16]),
                    .t_read_valid(tail_read_valid[2+:2]),
                    .t_read_address(tail_read_address[14+:14]),
                    .t_read_ready(tail_read_ready[2+:2]),
                    .t_response_valid(tail_response_valid[2+:2]),
                    .t_response_data(tail_response_data[64+:64]),
                    .p_write_valid(pw_valid),
                    .p_write_address(pw_address),
                    .p_write_field(pw_field),
                    .p_write_data(pw_data),
                    .p_read_valid(pr_valid),
                    .p_read_address(pr_address),
                    .p_read_ready(pr_ready),
                    .p_response_valid(pr_response),
                    .p_response_data(param_response_data),

                    .clk(clk),
                    .rst_n(rst_n),
                    .frame_abort(abort_active),
                    .wt1_shift(wt_shift && wt_seg == 15),
                    .wt2_shift(wt_shift && wt_seg == 18),
                    .wt_data(wt_bus[7:0]),
                    .a1_shift(wt_shift && wt_seg == 16),
                    .a2_shift(wt_shift && wt_seg == 19),
                    .a_data(wt_bus),
                    .param_shift(wt_shift && wt_seg == `CNN_TRAINED_RES_SEG + 1),
                    .param_data(wt_bus[7:0]),
                    .pre_img_vsync(rv[1]),
                    .pre_img_href(rh[1]),
                    .pre_img_clken(re[1]),
                    .pre_img_data(rd[1]),
                    .input_ready(),
                    .post_img_vsync(rv[2]),
                    .post_img_href(rh[2]),
                    .post_img_valid(re[2]),
                    .post_img_data(rd[2]),
                    .blk_loaded(res_loaded[1]),
                    .o_busy(res_busy[1]),
                    .o_error(res_error[1]),
                    .o_frame_abort(res_fault[1]),
                    .in_cfg_we(in_cfg_we && (in_cfg_layer == 5 || in_cfg_layer == 6)),
                    .in_cfg_channel(in_cfg_channel + ((in_cfg_layer == 6) ? 8'd32 : 8'd0)),
                    .in_cfg_bias(in_cfg_bias),
                    .in_cfg_multiplier(in_cfg_multiplier),
                    .in_cfg_shift(in_cfg_shift),
                    .in_stat_valid(stat_valid),
                    .in_stat_acc(stat_acc),
                    .in_stat_channel(stat_channel),
                    .q_request_valid(request_valid),
                    .q_request_data(request_data),
                    .q_request_ready(local_grant),
                    .q_response_valid(local_response),
                    .q_response_data(local_result)
                );
            end else begin : g_separable
                if (b == 0) assign first_res_ready = 1'b1;
                assign in_stat_valid [3 + 2 * b] = res_stv [b] && res_stc [b * 8+:8] < 32;
                assign in_stat_valid [4 + 2 * b] = res_stv [b] && res_stc [b * 8+:8] >= 32;
                assign in_stat_acc [(3 + 2 * b) * 24+:24] = res_sta [b * 24+:24];
                assign in_stat_acc [(4 + 2 * b) * 24+:24] = res_sta [b * 24+:24];
                assign in_stat_channel [(3 + 2 * b) * 8+:8] = res_stc [b * 8+:8];
                assign in_stat_channel [(4 + 2 * b) * 8+:8] = res_stc [b * 8+:8] - 32;
                cnn_resblock #(
                    .PW_OUTPUT_STATIONARY(1),
                    .WINDOW_ROWS((b == 0 || (STANDARD_FIRST && b == 2)) ? 3 : 2),
                    .SHARED_QUANT(1),
                    .SHARED_PARAMS(1),
                    .SHARED_DW_WEIGHTS(1),
                    .IN_ADAPTIVE(1),
                    .CH(32),
                    .INPUT_WORDS(32),
                    .H_DISP(H_DISP / 4),
                    .V_DISP(V_DISP / 4)
                ) residual (
                    .dw_write_valid(dw_write_valid[STANDARD_FIRST?b-2:b]),
                    .dw_write_address(dw_write_address[(STANDARD_FIRST?b-2:b)*8+:8]),
                    .dw_write_half(dw_write_half[STANDARD_FIRST?b-2:b]),
                    .dw_write_data(dw_write_data[(STANDARD_FIRST?b-2:b)*8+:8]),
                    .dw_read_valid(dw_read_valid[STANDARD_FIRST?b-2:b]),
                    .dw_read_address(dw_read_address[(STANDARD_FIRST?b-2:b)*8+:8]),
                    .dw_read_ready(dw_read_ready[STANDARD_FIRST?b-2:b]),
                    .dw_response_valid(dw_response_valid[STANDARD_FIRST?b-2:b]),
                    .dw_response_data(dw_response_data),
                    .p_write_valid(param_write_valid[b+2]),
                    .p_write_address(param_write_address[(b+2)*7+:7]),
                    .p_write_field(param_write_field[(b+2)*2+:2]),
                    .p_write_data(param_write_data[(b+2)*20+:20]),
                    .p_read_valid(param_read_valid[b+2]),
                    .p_read_address(param_read_address[(b+2)*7+:7]),
                    .p_read_ready(param_read_ready[b+2]),
                    .p_response_valid(param_response_valid[b+2]),
                    .p_response_data(param_response_data),
                    .q_request_valid(quant_request[b+2]),
                    .q_request_data(quant_arguments[(b+2)*61 +: 61]),
                    .q_request_ready(quant_grant[b+2]),
                    .q_response_valid(quant_response[b+2]),
                    .q_response_data(quant_result),
    
                    .in_cfg_we(in_cfg_we && (in_cfg_layer == 3 + 2 * b || in_cfg_layer == 4 + 2 * b)),
                    .in_cfg_channel(in_cfg_channel + ((in_cfg_layer == 4 + 2 * b) ? 8'd32:8'd0)),
                    .in_cfg_bias(in_cfg_bias),
                    .in_cfg_multiplier(in_cfg_multiplier),
                    .in_cfg_shift(in_cfg_shift),
                    .in_stat_valid(res_stv [b]),
                    .in_stat_acc(res_sta [b * 24+:24]),
                    .in_stat_channel(res_stc [b * 8+:8]),
                    .clk(clk),
                    .rst_n(rst_n),
                    .frame_abort(abort_active),
                    .wt1_shift(wt_shift && wt_seg == 9 + 6 * b),
                    .wt1_data(wt_bus [7:0]),
                    .a1_shift(wt_shift && wt_seg == 10 + 6 * b),
                    .a1_data(wt_bus),
                    .wt2_shift(wt_shift && wt_seg == 12 + 6 * b),
                    .wt2_data(wt_bus [7:0]),
                    .a2_shift(wt_shift && wt_seg == 13 + 6 * b),
                    .a2_data(wt_bus),
                    .param_shift(wt_shift && wt_seg == `CNN_TRAINED_RES_SEG + b),
                    .param_data(wt_bus [7:0]),
                    .pre_img_vsync(rv [b]),
                    .pre_img_href(rh [b]),
                    .pre_img_clken(re [b]),
                    .pre_img_data(rd [b]),
                    .post_img_vsync(rv [b + 1]),
                    .post_img_href(rh [b + 1]),
                    .post_img_valid(re [b + 1]),
                    .post_img_data(rd [b + 1]),
                    .blk_loaded(res_loaded [b]),
                    .o_busy(res_busy [b]),
                    .o_error(res_error [b]),
                    .o_frame_abort(res_fault [b])
                );
            end

        end
    endgenerate
    reg [255:0] decoder_serial;
    reg [4:0] decoder_left;
    wire decoder_ready;
    wire decoder_free = (decoder_left == 0) || (decoder_left == 1 && decoder_ready);
    wire decoder_overflow = re [5] && ! decoder_free;

    always @(posedge clk) begin
        if (data_rst) decoder_left <= 0;
        else begin
            if (decoder_left != 0 && decoder_ready) begin
                decoder_serial <= decoder_serial >> 32;
                decoder_left <= decoder_left - 1'b1;
            end
            if (re [5] && decoder_free) begin
                decoder_serial <= rd [5];
                decoder_left <= 8;
            end
        end
    end
    // 先对64×36×32特征做最近邻上采样，再在128×72上执行32→16标准卷积。
    wire [31:0] pw_data;
    wire pw_valid;
    wire pw_ready;
    cnn_conv #(
        .SHARED_QUANT(1),
        .SHARED_PARAMS(1),
        .IN_ADAPTIVE(1),
        .CI(32),
        .CO(16),
        .K(3),
        .UP(1),
        .WINDOW_ROWS(6),
        .GI(4),
        .GO(4),
        .PE(4),
        .W(H_DISP / 4),
        .H(V_DISP / 4),
        .IN_DEPTH(8)
    ) decode_project (
        .p_write_valid(param_write_valid[7]),
        .p_write_address(param_write_address[7*7+:7]),
        .p_write_field(param_write_field[7*2+:2]),
        .p_write_data(param_write_data[7*20+:20]),
        .p_read_valid(param_read_valid[7]),
        .p_read_address(param_read_address[7*7+:7]),
        .p_read_ready(param_read_ready[7]),
        .p_response_valid(param_response_valid[7]),
        .p_response_data(param_response_data),
        .q_request_valid(quant_request[7]),
        .q_request_data(quant_arguments[(7)*61 +: 61]),
        .q_request_ready(quant_grant[7]),
        .q_response_valid(quant_response[7]),
        .q_response_data(quant_result),

        .in_cfg_we(in_cfg_we && in_cfg_layer == 13),
        .in_cfg_channel(in_cfg_channel),
        .in_cfg_bias(in_cfg_bias),
        .in_cfg_multiplier(in_cfg_multiplier),
        .in_cfg_shift(in_cfg_shift),
        .in_stat_valid(in_stat_valid [13]),
        .in_stat_acc(in_stat_acc [312+:24]),
        .in_stat_channel(in_stat_channel [104+:8]),
        .clk(clk),
        .rst_n(rst_n),
        .frame_start(start),
        .frame_abort(abort_active),
        .wt_shift(wt_shift && wt_seg == 39),
        .wt_data(wt_bus [7:0]),
        .a_shift(wt_shift && wt_seg == 40),
        .a_data(wt_bus),
        .i_data(decoder_serial [31:0]),
        .i_valid(decoder_left != 0),
        .i_ready(decoder_ready),
        .o_data(pw_data),
        .o_valid(pw_valid),
        .o_ready(pw_ready),
        .loaded(codec_loaded [3]),
        .o_error(codec_error [3]),
        .o_fault(codec_fault [3])
    );

    wire [15:0] dw_data;
    wire dw_valid;
    wire dw_ready;
    cnn_conv #(
        .SHARED_QUANT(1),
        .SHARED_PARAMS(1),
        .IN_ADAPTIVE(1),
        .CI(16),
        .CO(8),
        .UP(1),
        .GI(4),
        .GO(2),
        .PE(4),
        .W(H_DISP / 2),
        .H(V_DISP / 2),
        .IN_DEPTH(16)
    ) decode1 (
        .p_write_valid(param_write_valid[8]),
        .p_write_address(param_write_address[8*7+:7]),
        .p_write_field(param_write_field[8*2+:2]),
        .p_write_data(param_write_data[8*20+:20]),
        .p_read_valid(param_read_valid[8]),
        .p_read_address(param_read_address[8*7+:7]),
        .p_read_ready(param_read_ready[8]),
        .p_response_valid(param_response_valid[8]),
        .p_response_data(param_response_data),
        .q_request_valid(quant_request[8]),
        .q_request_data(quant_arguments[(8)*61 +: 61]),
        .q_request_ready(quant_grant[8]),
        .q_response_valid(quant_response[8]),
        .q_response_data(quant_result),

        .in_cfg_we(in_cfg_we && in_cfg_layer == 14),
        .in_cfg_channel(in_cfg_channel),
        .in_cfg_bias(in_cfg_bias),
        .in_cfg_multiplier(in_cfg_multiplier),
        .in_cfg_shift(in_cfg_shift),
        .in_stat_valid(in_stat_valid [14]),
        .in_stat_acc(in_stat_acc [336+:24]),
        .in_stat_channel(in_stat_channel [112+:8]),
        .clk(clk),
        .rst_n(rst_n),
        .frame_start(start),
        .frame_abort(abort_active),
        .wt_shift(wt_shift && wt_seg == 42),
        .wt_data(wt_bus [7:0]),
        .a_shift(wt_shift && wt_seg == 43),
        .a_data(wt_bus),
        .i_data(pw_data),
        .i_valid(pw_valid),
        .i_ready(pw_ready),
        .o_data(dw_data),
        .o_valid(dw_valid),
        .o_ready(dw_ready),
        .loaded(codec_loaded [4]),
        .o_error(codec_error [4]),
        .o_fault(codec_fault [4])
    );

    wire [23:0] out_word;
    wire out_valid;
    wire out_ready;
    cnn_conv #(
        .CI(8),
        .CO(3),
        .UP(0),
        .GI(2),
        .GO(3),
        .PE(3),
        .W(H_DISP),
        .H(V_DISP),
        .IN_DEPTH(8)
    ) head (
        .clk(clk),
        .rst_n(rst_n),
        .frame_start(start),
        .frame_abort(abort_active),
        .wt_shift(wt_shift && wt_seg == 45),
        .wt_data(wt_bus [7:0]),
        .a_shift(wt_shift && wt_seg == 46),
        .a_data(wt_bus),
        .i_data(dw_data),
        .i_valid(dw_valid),
        .i_ready(dw_ready),
        .o_data(out_word),
        .o_valid(out_valid),
        .o_ready(out_ready),
        .loaded(codec_loaded [5]),
        .o_error(codec_error [5]),
        .o_fault(codec_fault [5])
    );

    wire [23:0] shuffled;
    wire shuffle_valid;
    wire shuffle_ready;
    // 输出卷积内部按 {B,G,R} 打包，此处保持对外 RGB 通道顺序。
    assign shuffled = { out_word [7:0], out_word [15:8], out_word [23:16] };
    assign shuffle_valid = out_valid;
    assign out_ready = shuffle_ready;
    reg [3:0] output_pace;
    assign shuffle_ready = (output_pace == 0) && ! first_pending &&
                           output_lookup_step == 0 && ! abort_guard;
    wire pixel_fire = shuffle_valid && shuffle_ready;
    wire fault_now = (input_fault || decoder_overflow || (| codec_fault) || (| res_fault)) && ! abort_active;

    // 接收一个解码像素后连续读B、G、R；四拍后交给原帧/行控制。
    // 不改变权重表内容或通道顺序，只增加固定查表延迟。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) output_lookup_step <= 0;
        else if (data_clear) output_lookup_step <= 0;
        else begin
            if (pixel_fire) begin
                output_pixel_hold <= shuffled;
                output_first <= pixel_count == 0;
                output_last <= pixel_count == PIXELS - 1;
                output_lookup_step <= 1;
            end else if (output_lookup_step != 0) begin
                output_lookup_step <= (output_lookup_step == 4) ? 0 : output_lookup_step + 1'b1;
            end
            if (output_lookup_step == 2) output_partial[7:0] <= output_lookup_q;
            if (output_lookup_step == 3) output_partial[15:8] <= output_lookup_q;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) begin
            active <= 0;
            error <= 0;
            abort_count <= 0;
            abort_guard <= 0;
            o_frame_abort <= 0;
            post_img_vsync <= 0;
            post_img_valid <= 0;
            row_open <= 0;
            out_col <= 0;
            pixel_count <= 0;
            first_pending <= 0;
            output_pace <= 0;
        end else begin
            post_img_vsync <= 0;
            post_img_valid <= 0;
            o_frame_abort <= abort_active || fault_now;
            // abort_guard 每拍均等于 (abort_count!=0)，
            // 避免将六位计数器比较器直接放到全局复位路径中。
            if (frame_abort || fault_now) begin
                abort_count <= 48;
                abort_guard <= 1;
                active <= 0;
            end else if (abort_count != 0) begin
                abort_count <= abort_count - 1'b1;
                abort_guard <= abort_count != 1;
            end else begin
                abort_count <= 0;
                abort_guard <= 0;
            end
            if (fault_now) error <= 1;
            if (data_clear) begin
                row_open <= 0;
                out_col <= 0;
                pixel_count <= 0;
                first_pending <= 0;
                output_pace <= 0;
                if (start && ! fault_now) active <= 1;
            end else begin
                if (output_pace != 0) output_pace <= output_pace - 1'b1;
                if (first_pending) begin
                    post_img_valid <= 1;
                    post_img_data <= first_pixel;
                    first_pending <= 0;
                    row_open <= 1;
                    out_col <= 1;
                end
                if (pixel_fire) begin
                    output_pace <= 8;
                    pixel_count <= pixel_count + 1'b1;
                end
                if (output_lookup_valid) begin
                    if (output_first) begin
                        first_pixel <= output_color;
                        post_img_vsync <= 1;
                        first_pending <= 1;
                    end else begin
                        post_img_data <= output_color;
                        post_img_valid <= 1;
                        if (out_col == H_DISP - 1) begin
                            out_col <= 0;
                            row_open <= 0;
                        end else begin
                            out_col <= out_col + 1'b1;
                            row_open <= 1;
                        end
                    end
                    if (output_last) active <= 0;
                end
            end
            // 故障立即禁止本次输出；abort_guard 在下一拍清理数据状态，
            // 避免故障组合树直接驱动所有像素寄存器的使能。
            // 清理期间不接收新的有效像素。
            if (fault_now) begin
                post_img_valid <= 0;
                post_img_vsync <= 0;
            end
        end
    end
`ifndef SYNTHESIS
    initial if (H_DISP < 8 || V_DISP < 8 || H_DISP % 4 || V_DISP % 4) $fatal(1, "Codec16 requires dimensions divisible by four");

    always @(posedge clk) if (rst_n && ! abort_active && pixel_fire && pixel_count >= PIXELS) $fatal(1, "Codec16 excess pixel");

    always @(posedge clk) if (rst_n && abort_guard !== (abort_count != 0)) $fatal(1, "Codec16 abort guard invariant");
`endif
endmodule
