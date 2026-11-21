`timescale 1ns/1ps
// 用途：以两层32通道标准3×3卷积实现一个残差块。
// 原理：两层各占共享量化服务的一个时隙；原输入经窄旁路FIFO延迟，按通道与第二层有符号输出相加。
module cnn_standard_resblock #(
    parameter integer SHARED_TAIL = 0,
    parameter integer CH = 32,
    parameter integer SHARED_PARAMS = 0,
    parameter integer H_DISP = 64,
    parameter integer V_DISP = 36,
    parameter integer PE = 8,
    parameter integer SKIP_WORDS = 4096
) (
    input clk,
    input rst_n,
    input frame_abort,
    input wt1_shift,
    input wt2_shift,
    input [7:0] wt_data,
    input a1_shift,
    input a2_shift,
    input [31:0] a_data,
    input param_shift,
    input [7:0] param_data,
    input pre_img_vsync,
    input pre_img_href,
    input pre_img_clken,
    input [CH*8-1:0] pre_img_data,
    output input_ready,
    output reg post_img_vsync,
    output reg post_img_valid,
    output post_img_href,
    output reg [CH*8-1:0] post_img_data,
    output blk_loaded,
    output o_busy,
    output reg o_error,
    output reg o_frame_abort,
    input in_cfg_we,
    input [7:0] in_cfg_channel,
    input signed [19:0] in_cfg_bias,
    input [30:0] in_cfg_multiplier,
    input [5:0] in_cfg_shift,
    output [1:0] in_stat_valid,
    output [47:0] in_stat_acc,
    output [15:0] in_stat_channel,
    output [1:0] q_request_valid,
    output [121:0] q_request_data,
    input [1:0] q_request_ready,
    input [1:0] q_response_valid,
    input [8:0] q_response_data,
    output wire [1:0] p_write_valid,
    output wire [13:0] p_write_address,
    output wire [3:0] p_write_field,
    output wire [39:0] p_write_data,
    output wire [1:0] p_read_valid,
    output wire [13:0] p_read_address,
    input wire [1:0] p_read_ready,
    input wire [1:0] p_response_valid,
    input wire [59:0] p_response_data,
    output wire [1:0] t_write_valid,
    output wire [9:0] t_write_lane,
    output wire [13:0] t_write_address,
    output wire [15:0] t_write_data,
    output wire [1:0] t_read_valid,
    output wire [13:0] t_read_address,
    input wire [1:0] t_read_ready,
    input wire [1:0] t_response_valid,
    input wire [63:0] t_response_data
);
    localparam CW = $clog2(CH);
    localparam XW = $clog2(H_DISP);
    localparam PCW = $clog2(H_DISP*V_DISP+1);
    localparam SCW = $clog2(SKIP_WORDS+1);
    wire clear = frame_abort || pre_img_vsync;
    (* syn_preserve=1 *) reg data_rst;
    always @(posedge clk) data_rst <= !rst_n || clear;
    reg active;
    reg row_open;
    reg first_emit_pending;
    reg [PCW-1:0] input_pixels;
    reg [PCW-1:0] output_pixels;
    reg [XW-1:0] out_x;
    assign o_busy = active;
    assign post_img_href = (row_open || post_img_valid) && !frame_abort;

    // 每个向量拆成16个双通道字；主路与旁路只在两端都可接收时同时写入。
    reg [CH*8-1:0] serial;
    reg [$clog2(CH/2+1)-1:0] words_left;
    wire conv1_ready;
    wire skip_write_ready;
    wire fifo_ready = conv1_ready && skip_write_ready;
    wire ser_free = words_left == 0 || (words_left == 1 && fifo_ready);
    wire input_take = pre_img_href && pre_img_clken;
    reg [SCW-1:0] skip_count;
    assign input_ready = !frame_abort && ser_free && skip_count < SKIP_WORDS-CH/2-4;
    wire bad_input = input_take && (!active || !ser_free || input_pixels >= H_DISP*V_DISP);
    wire fork_take = words_left != 0 && fifo_ready;
    wire skip_pop;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            words_left <= 0;
            skip_count <= 0;
        end else if(clear) begin
            words_left <= 0;
            skip_count <= 0;
        end else begin
            if(fork_take) begin
                serial <= serial >> 16;
                words_left <= words_left-1'b1;
            end
            if(input_take && ser_free && active) begin
                serial <= pre_img_data;
                words_left <= CH/2;
            end
            case({fork_take,skip_pop})
                2'b10: skip_count <= skip_count+1'b1;
                2'b01: skip_count <= skip_count-1'b1;
            endcase
        end
    end
    wire [13:0] skip_word;
    wire skip_valid;
    cnn_ram_fifo #(
        .W(14),
        .D(SKIP_WORDS)
    ) bypass_fifo (
        .clk(clk),
        .rst(data_rst),
        .i_data({serial[14:8],serial[6:0]}),
        .i_valid(words_left != 0 && conv1_ready),
        .i_ready(skip_write_ready),
        .o_data(skip_word),
        .o_valid(skip_valid),
        .o_ready(skip_pop)
    );
    wire [15:0] hidden_data;
    wire hidden_valid;
    wire hidden_ready;
    wire [15:0] branch_data;
    wire branch_valid;
    wire branch_ready;
    wire [1:0] conv_loaded;
    wire [1:0] conv_error;
    wire [1:0] conv_fault;
    cnn_conv #(
        .SHARED_TAIL(SHARED_TAIL),
        .SHARED_QUANT(1),
        .SHARED_PARAMS(SHARED_PARAMS),
        .IN_ADAPTIVE(1),
        .CI(CH),
        .CO(CH),
        .GI(2),
        .GO(2),
        .PE(PE),
        .W(H_DISP),
        .H(V_DISP),
        .IN_DEPTH(16),
        .WINDOW_ROWS(3),
        .SIGNED_OUTPUT(0)
    ) conv1 (
        .t_write_valid(t_write_valid[0]),
        .t_write_lane(t_write_lane[0+:5]),
        .t_write_address(t_write_address[0+:7]),
        .t_write_data(t_write_data[0+:8]),
        .t_read_valid(t_read_valid[0]),
        .t_read_address(t_read_address[0+:7]),
        .t_read_ready(t_read_ready[0]),
        .t_response_valid(t_response_valid[0]),
        .t_response_data(t_response_data),
        .p_write_valid(p_write_valid[0]),
        .p_write_address(p_write_address[0+:7]),
        .p_write_field(p_write_field[0+:2]),
        .p_write_data(p_write_data[0+:20]),
        .p_read_valid(p_read_valid[0]),
        .p_read_address(p_read_address[0+:7]),
        .p_read_ready(p_read_ready[0]),
        .p_response_valid(p_response_valid[0]),
        .p_response_data(p_response_data),
        .clk(clk),
        .rst_n(rst_n),
        .frame_start(pre_img_vsync),
        .frame_abort(frame_abort),
        .wt_shift(wt1_shift),
        .wt_data(wt_data),
        .a_shift(a1_shift),
        .a_data(a_data),
        .i_data(serial[15:0]),
        .i_valid(words_left != 0 && skip_write_ready),
        .i_ready(conv1_ready),
        .o_data(hidden_data),
        .o_valid(hidden_valid),
        .o_ready(hidden_ready),
        .loaded(conv_loaded[0]),
        .o_error(conv_error[0]),
        .o_fault(conv_fault[0]),
        .in_cfg_we(in_cfg_we && in_cfg_channel < CH),
        .in_cfg_channel(in_cfg_channel % CH),
        .in_cfg_bias(in_cfg_bias),
        .in_cfg_multiplier(in_cfg_multiplier),
        .in_cfg_shift(in_cfg_shift),
        .in_stat_valid(in_stat_valid[0]),
        .in_stat_acc(in_stat_acc[0+:24]),
        .in_stat_channel(in_stat_channel[0+:8]),
        .q_request_valid(q_request_valid[0]),
        .q_request_data(q_request_data[0+:61]),
        .q_request_ready(q_request_ready[0]),
        .q_response_valid(q_response_valid[0]),
        .q_response_data(q_response_data)
    );

    cnn_conv #(
        .SHARED_TAIL(SHARED_TAIL),
        .SHARED_QUANT(1),
        .SHARED_PARAMS(SHARED_PARAMS),
        .IN_ADAPTIVE(1),
        .CI(CH),
        .CO(CH),
        .GI(2),
        .GO(2),
        .PE(PE),
        .W(H_DISP),
        .H(V_DISP),
        .IN_DEPTH(16),
        .WINDOW_ROWS(2),
        .SIGNED_OUTPUT(1)
    ) conv2 (
        .t_write_valid(t_write_valid[1]),
        .t_write_lane(t_write_lane[5+:5]),
        .t_write_address(t_write_address[7+:7]),
        .t_write_data(t_write_data[8+:8]),
        .t_read_valid(t_read_valid[1]),
        .t_read_address(t_read_address[7+:7]),
        .t_read_ready(t_read_ready[1]),
        .t_response_valid(t_response_valid[1]),
        .t_response_data(t_response_data),
        .p_write_valid(p_write_valid[1]),
        .p_write_address(p_write_address[7+:7]),
        .p_write_field(p_write_field[2+:2]),
        .p_write_data(p_write_data[20+:20]),
        .p_read_valid(p_read_valid[1]),
        .p_read_address(p_read_address[7+:7]),
        .p_read_ready(p_read_ready[1]),
        .p_response_valid(p_response_valid[1]),
        .p_response_data(p_response_data),
        .clk(clk),
        .rst_n(rst_n),
        .frame_start(pre_img_vsync),
        .frame_abort(frame_abort),
        .wt_shift(wt2_shift),
        .wt_data(wt_data),
        .a_shift(a2_shift),
        .a_data(a_data),
        .i_data(hidden_data),
        .i_valid(hidden_valid),
        .i_ready(hidden_ready),
        .o_data(branch_data),
        .o_valid(branch_valid),
        .o_ready(branch_ready),
        .loaded(conv_loaded[1]),
        .o_error(conv_error[1]),
        .o_fault(conv_fault[1]),
        .in_cfg_we(in_cfg_we && in_cfg_channel >= CH),
        .in_cfg_channel(in_cfg_channel % CH),
        .in_cfg_bias(in_cfg_bias),
        .in_cfg_multiplier(in_cfg_multiplier),
        .in_cfg_shift(in_cfg_shift),
        .in_stat_valid(in_stat_valid[1]),
        .in_stat_acc(in_stat_acc[24+:24]),
        .in_stat_channel(in_stat_channel[8+:8]),
        .q_request_valid(q_request_valid[1]),
        .q_request_data(q_request_data[61+:61]),
        .q_request_ready(q_request_ready[1]),
        .q_response_valid(q_response_valid[1]),
        .q_response_data(q_response_data)
    );

    // 第二层按两个通道输出；旁路同步取同一像素的两个原始通道。
    reg branch_half;
    wire [7:0] branch = branch_data[branch_half*8+:8];
    wire [7:0] shortcut = {1'b0,skip_word[branch_half*7+:7]};
    wire q_valid = branch_valid && skip_valid;
    wire q_ready;
    wire consume = q_valid && q_ready;
    assign branch_ready = consume && branch_half;
    assign skip_pop = consume && branch_half;
    always @(posedge clk) begin
        if(data_rst) branch_half <= 0;
        else if(consume) branch_half <= !branch_half;
    end
    wire dw_error = conv_error[0] || conv_fault[0];
    wire pw_error = conv_error[1] || conv_fault[1];
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
    assign blk_loaded = (&conv_loaded) && lut_loaded;
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
