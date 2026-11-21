// 残差块：逐通道 3×3 卷积、逐点 1×1 卷积及旁路数值转换查找表。
`timescale 1ns/1ps

// 用途：实现逐通道 3×3 加逐点 1×1 的深度可分离残差块。
// 原理：输入按通道串行化后依次经过两级卷积，共用量化器；查找表对齐主支路与旁路的数值范围，再相加输出。
module cnn_resblock #(
    parameter integer WINDOW_ROWS = 3,
    parameter integer PW_OUTPUT_STATIONARY = 0,
    parameter integer SHARED_QUANT = 0,
    parameter integer SHARED_PARAMS = 0,
    parameter integer SHARED_DW_WEIGHTS = 0,
    parameter integer CH = 16,
    parameter integer H_DISP = 64,
    parameter integer V_DISP = 36,
    parameter integer IN_ADAPTIVE = 0,
    parameter integer INPUT_WORDS = 2 * H_DISP * (CH / 2)
) (
    input clk,
    input rst_n,
    input frame_abort,
    input wt1_shift,
    input wt2_shift,
    input [7:0] wt1_data,
    input [7:0] wt2_data,
    input a1_shift,
    input a2_shift,
    input [31:0] a1_data,
    input [31:0] a2_data,
    input param_shift,
    input [7:0] param_data,
    input pre_img_vsync,
    input pre_img_href,
    input pre_img_clken,
    input [CH * 8 - 1:0] pre_img_data,
    output reg post_img_vsync,
    output reg post_img_valid,
    output post_img_href,
    output reg [CH * 8 - 1:0] post_img_data,
    output blk_loaded,
    output o_busy,
    output reg o_error,
    output reg o_frame_abort,
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
    output wire dw_write_valid,
    output wire [7:0] dw_write_address,
    output wire dw_write_half,
    output wire [7:0] dw_write_data,
    output wire dw_read_valid,
    output wire [7:0] dw_read_address,
    input wire dw_read_ready,
    input wire dw_response_valid,
    input wire [15:0] dw_response_data
);

    localparam CW = $clog2(CH);
    localparam XW = $clog2(H_DISP);
    localparam PCW = $clog2(H_DISP * V_DISP + 1);
    wire clear = frame_abort || pre_img_vsync;
    // 本地复位寄存器降低全局控制信号扇出；输入串行化逻辑
    // 保证帧头与首个数据向量之间至少间隔一个时钟周期。
    (* syn_preserve=1 *)
    reg data_rst;

    always @(posedge clk) data_rst <= ! rst_n || clear;
    reg active;
    reg row_open;
    reg first_emit_pending;
    reg [PCW - 1:0] input_pixels;
    reg [PCW - 1:0] output_pixels;
    reg [XW - 1:0] out_x;
    assign o_busy = active;
    assign post_img_href = (row_open || post_img_valid) && ! frame_abort;
    // ready/valid 流水暂停时，窄输入 FIFO 吸收突发数据。
    reg [CH * 8 - 1:0] serial;
    reg [$clog2(CH / 2 + 1) - 1:0] words_left;
    wire fifo_ready;
    wire fifo_valid;
    wire window_ready;
    wire [15:0] fifo_data;
    wire ser_free = (words_left == 0) || (words_left == 1 && fifo_ready);
    wire input_take = pre_img_href && pre_img_clken;
    wire bad_input = input_take && (! active || ! ser_free || input_pixels >= H_DISP * V_DISP);

    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) words_left <= 0;
        else if (clear) words_left <= 0;
        else begin
            if (words_left != 0 && fifo_ready) begin
                serial <= serial >> 16;
                words_left <= words_left - 1'b1;
            end
            if (input_take && ser_free && active) begin
                serial <= pre_img_data;
                words_left <= CH / 2;
            end
        end
    end
    // 层间只需吸收一个通道向量的短突发，浅缓存使用 SRL，避免占用块 RAM。
    generate
        if (INPUT_WORDS <= 32) begin : g_input_srl
            cnn_stream_fifo #(
                .W(16),
                .AW($clog2(INPUT_WORDS))
            ) u_input (
                .clk(clk),
                .rst(data_rst),
                .i_data(serial [15:0]),
                .i_valid(words_left != 0),
                .i_ready(fifo_ready),
                .o_data(fifo_data),
                .o_valid(fifo_valid),
                .o_ready(window_ready),
                .count()
            );
        end else begin : g_input_ram
            cnn_ram_fifo #(
                .W(16),
                .D(INPUT_WORDS)
            ) u_input (
                .clk(clk),
                .rst(data_rst),
                .i_data(serial [15:0]),
                .i_valid(words_left != 0),
                .i_ready(fifo_ready),
                .o_data(fifo_data),
                .o_valid(fifo_valid),
                .o_ready(window_ready)
            );
        end
    endgenerate

    wire [15:0] window_data;
    wire [3:0] window_tap;
    wire [7:0] window_group;
    wire window_valid;
    wire dw_ready;
    generate
        if (WINDOW_ROWS == 2) begin : g_two_row
            // 两行窗口保存历史行，新行经待提交列缓存参与计算后再覆盖旧行。
            cnn_dw_window #(
                .G(2),
                .NG(CH / 2),
                .W(H_DISP),
                .H(V_DISP)
            ) u_window (
                .clk(clk),
                .rst(data_rst),
                .i_data(fifo_data),
                .i_valid(fifo_valid),
                .i_ready(window_ready),
                .o_data(window_data),
                .o_tap(window_tap),
                .o_grp(window_group),
                .o_valid(window_valid),
                .o_ready(dw_ready)
            );
        end else begin : g_three_row
            // 三行环形窗口复用已有模块，避免待提交移位链及其选择器。
            cnn_conv_window #(
                .G(2),
                .NG(CH / 2),
                .W(H_DISP),
                .H(V_DISP)
            ) u_window (
                .clk(clk),
                .rst(data_rst),
                .i_data(fifo_data),
                .i_valid(fifo_valid),
                .i_ready(window_ready),
                .o_data(window_data),
                .o_tap(window_tap),
                .o_grp(window_group),
                .o_valid(window_valid),
                .o_ready(dw_ready)
            );
        end
    endgenerate

    // 深度卷积和逐点卷积权重各用一组成对 RAM10 存储。
    reg [CW - 1:0] dw_channel;
    reg [CW - 1:0] pw_channel;
    reg [CW - 1:0] pw_input;
    reg [3:0] dw_tap;
    reg dw_loaded;
    reg pw_loaded;

    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) begin
            dw_channel <= 0;
            dw_tap <= 0;
            dw_loaded <= 0;
            pw_channel <= 0;
            pw_input <= 0;
            pw_loaded <= 0;
        end else begin
            if (wt1_shift && ! dw_loaded) begin
                if (dw_tap == 8) begin
                    dw_tap <= 0;
                    if (dw_channel == CH - 1) dw_loaded <= 1;
                    else dw_channel <= dw_channel + 1'b1;
                end else dw_tap <= dw_tap + 1'b1;
            end
            if (wt2_shift && ! pw_loaded) begin
                if (pw_input == CH - 1) begin
                    pw_input <= 0;
                    if (pw_channel == CH - 1) pw_loaded <= 1;
                    else pw_channel <= pw_channel + 1'b1;
                end else pw_input <= pw_input + 1'b1;
            end
        end
    end
    wire [23:0] dw_acc;
    wire [23:0] pw_acc;
    wire [7:0] dw_side;
    wire [7:0] pw_side;
    wire dw_valid;
    wire pw_valid;
    wire dw_qready;
    wire pw_qready;
    cnn_dw_mac #(
        .SHARED_WEIGHTS(SHARED_DW_WEIGHTS),
        .G(2),
        .NG(CH / 2),
        .ACC_W(24)
    ) u_dw (
        .dw_write_valid(dw_write_valid),
        .dw_write_address(dw_write_address),
        .dw_write_half(dw_write_half),
        .dw_write_data(dw_write_data),
        .dw_read_valid(dw_read_valid),
        .dw_read_address(dw_read_address),
        .dw_read_ready(dw_read_ready),
        .dw_response_valid(dw_response_valid),
        .dw_response_data(dw_response_data),
        .clk(clk),
        .rst(data_rst),
        .w_we(wt1_shift && ! dw_loaded),
        .w_lane({ 4'd0, dw_channel [0] }),
        .w_addr(12 ' ((dw_channel >> 1) * 9 + dw_tap)),
        .w_data({ 24'd0, wt1_data }),
        .i_data(window_data),
        .i_tap(window_tap),
        .i_grp(window_group),
        .i_valid(window_valid),
        .i_ready(dw_ready),
        .o_acc(dw_acc),
        .o_side(dw_side),
        .o_last(),
        .o_valid(dw_valid),
        .o_ready(dw_qready)
    );

    wire [15:0] dw_codes;
    wire [15:0] dw_shortcut;
    wire dw_qvalid;
    wire pw_ready;
    wire dw_params;
    wire pw_params;
    wire dw_error;
    wire pw_error;
    generate
        if (PW_OUTPUT_STATIONARY) begin : g_pw_output_stationary
            cnn_pw_mac #(
                .CH(CH),
                .ACC_W(24)
            ) u_pw (
                .clk(clk),
                .rst(data_rst),
                .w_we(wt2_shift && !pw_loaded),
                .w_lane({4'd0, pw_input[0]}),
                .w_addr(12'((pw_input >> 1) * CH + pw_channel)),
                .w_data({24'd0, wt2_data}),
                .i_data(dw_codes),
                .i_side(dw_shortcut),
                .i_valid(dw_qvalid),
                .i_ready(pw_ready),
                .o_acc(pw_acc),
                .o_side(pw_side),
                .o_last(),
                .o_valid(pw_valid),
                .o_ready(pw_qready)
            );
        end else begin : g_pw_input_stationary
        cnn_dense_mac #(
            .G(2),
            .NI(CH / 2),
            .COUT(CH),
            .PE(1),
            .ACC_W(24),
            .SIDE_IN(1)
        ) u_pw (
            .clk(clk),
            .rst(data_rst),
            .w_we(wt2_shift && ! pw_loaded),
            .w_lane({ 4'd0, pw_input [0] }),
            .w_addr(12 ' ((pw_input >> 1) * CH + pw_channel)),
            .w_data({ 24'd0, wt2_data }),
            .i_data(dw_codes),
            .i_side(dw_shortcut),
            .i_valid(dw_qvalid),
            .i_ready(pw_ready),
            .o_acc(pw_acc),
            .o_side(pw_side),
            .o_last(),
            .o_valid(pw_valid),
            .o_ready(pw_qready)
        );
        end
    endgenerate

    wire [7:0] branch;
    wire [7:0] shortcut;
    wire q_valid;
    wire q_ready;
    wire shared_loaded;
    wire shared_error;
    assign dw_params = shared_loaded;
    assign pw_params = shared_loaded;
    assign dw_error = shared_error;
    assign pw_error = 1'b0;
    cnn_res_quant #(
        .SHARED_QUANT(SHARED_QUANT),
        .SHARED_PARAMS(SHARED_PARAMS),
        .CH(CH),
        .IN_ADAPTIVE(IN_ADAPTIVE)
    ) u_quant (
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
        .a1_shift(a1_shift),
        .a2_shift(a2_shift),
        .a1_data(a1_data),
        .a2_data(a2_data),
        .loaded(shared_loaded),
        .dw_acc(dw_acc),
        .pw_acc(pw_acc),
        .dw_side(dw_side),
        .pw_side(pw_side),
        .dw_valid(dw_valid),
        .pw_valid(pw_valid),
        .dw_ready(dw_qready),
        .pw_ready(pw_qready),
        .dw_codes(dw_codes),
        .dw_shortcut(dw_shortcut),
        .dw_qvalid(dw_qvalid),
        .dw_out_ready(pw_ready),
        .branch(branch),
        .shortcut(shortcut),
        .q_valid(q_valid),
        .q_ready(q_ready),
        .o_error(shared_error)
    );

    // 保持原残差整数转换约定，使用一张同步 1024×8 查找表。
    (* syn_ramstyle="block_ram" *)
    reg [7:0] conversion_lut [0:1023];
    reg [9:0] lut_load;
    reg lut_loaded;

    always @(posedge clk) if (param_shift && ! lut_loaded) conversion_lut [lut_load] <= param_data;

    always @(posedge clk or negedge rst_n) if (! rst_n) begin
        lut_load <= 0;
        lut_loaded <= 0;
    end else if (param_shift && ! lut_loaded) begin
        lut_load <= lut_load + 1'b1;
        if (lut_load == 1023) lut_loaded <= 1;
    end
    assign blk_loaded = dw_loaded && pw_loaded && dw_params && pw_params && lut_loaded;
    reg [2:0] add_state;
    reg [CW - 1:0] add_channel;
    reg [7:0] held_branch;
    reg [6:0] held_shortcut;
    reg signed [7:0] shortcut_value;
    reg signed [8:0] sum;
    reg [7:0] lookup;
    wire [9:0] lut_addr = (add_state == 4) ? { 1'b1, sum [8:0] }:((add_state == 2) ? { 2'b01, held_branch }:{ 3'b000, held_shortcut });

    always @(posedge clk) lookup <= conversion_lut [lut_addr];
    assign q_ready = add_state == 0;

    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) begin
            active <= 0;
            input_pixels <= 0;
            output_pixels <= 0;
            out_x <= 0;
            row_open <= 0;
            o_error <= 0;
            o_frame_abort <= 0;
            post_img_vsync <= 0;
            post_img_valid <= 0;
            add_state <= 0;
            add_channel <= 0;
            first_emit_pending <= 0;
        end else begin
            o_frame_abort <= 0;
            post_img_valid <= first_emit_pending;
            first_emit_pending <= 0;
            post_img_vsync <= 0;
            if (clear) begin
                active <= pre_img_vsync && ! frame_abort;
                input_pixels <= 0;
                output_pixels <= 0;
                out_x <= 0;
                row_open <= 0;
                add_state <= 0;
                add_channel <= 0;
                post_img_vsync <= 0;
                post_img_valid <= 0;
                first_emit_pending <= 0;
                if (pre_img_vsync && active && ! frame_abort) begin
                    o_error <= 1;
                    o_frame_abort <= 1;
                end
            end else begin
                if (input_take) input_pixels <= input_pixels + 1'b1;
                if (bad_input || dw_error || pw_error) begin
                    o_error <= 1;
                    o_frame_abort <= 1;
                end
                case (add_state)
                    0:if (q_valid) begin
                        held_branch <= branch;
                        held_shortcut <= shortcut [6:0];
                        add_state <= 1;
                    end
                    1:add_state <= 2;
                    2:begin
                        shortcut_value <= $signed(lookup);
                        add_state <= 3;
                    end
                    3:begin
                        sum <= $signed({ shortcut_value [7], shortcut_value }) + $signed({ lookup [7], lookup });
                        add_state <= 4;
                    end
                    4:add_state <= 5;
                    5:begin
                        post_img_data <= (post_img_data >> 8) | ({ { ((CH - 1) * 8) { 1'b0 } }, 1'b0, lookup [6:0] } << ((CH - 1) * 8));
                        add_state <= 0;
                        if (add_channel == CH - 1) begin
                            add_channel <= 0;
                            if (output_pixels == 0) begin
                                post_img_vsync <= 1;
                                first_emit_pending <= 1;
                            end else post_img_valid <= 1;
                            row_open <= out_x != H_DISP - 1;
                            out_x <= (out_x == H_DISP - 1) ? 0:out_x + 1'b1;
                            output_pixels <= output_pixels + 1'b1;
                            if (output_pixels == H_DISP * V_DISP - 1) active <= 0;
                        end else add_channel <= add_channel + 1'b1;
                    end
                endcase
            end
        end
    end
endmodule
