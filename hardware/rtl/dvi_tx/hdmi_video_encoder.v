`timescale 1ns/1ps

// 用途：传送RGB视频和每帧一包AVI信息，不包含音频、音频时钟恢复或数据岛FIFO。
// 原理：像素及同步整体延迟11拍，为视频开始前的8拍前导和2拍保护带留出时间。
// AVI在垂直消隐发送，包内容和BCH校验在编译期计算，视频数据不改变精度。
module hdmi_video_encoder #(
    parameter integer VIDEO_VIC = 4
) (
    input wire clk,
    input wire rst_p,
    input wire [23:0] rgb,
    input wire de,
    input wire hs,
    input wire vs,
    output wire [9:0] blue,
    output wire [9:0] green,
    output wire [9:0] red,
    output wire [9:0] clock_word
);
    function [7:0] bch;
        input [55:0] data;
        input integer length;
        reg [7:0] parity;
        integer i;
        begin
            parity = 0;
            for (i = 0; i < length; i = i + 1)
                parity = (parity >> 1) ^ ((parity[0] ^ data[i]) ? 8'h83 : 8'h00);
            bch = parity;
        end
    endfunction

    // 与原AVI字段保持一致：RGB、默认量化范围、无裁切、无像素重复。
    localparam [23:0] HEADER = 24'h0d0282;
    localparam [7:0] CHECKSUM = 8'h00 - 8'h82 - 8'h02 - 8'h0d - 8'h08 - VIDEO_VIC;
    localparam [55:0] PAYLOAD0 = {16'd0, 8'(VIDEO_VIC), 8'd0, 8'h08, 8'd0, CHECKSUM};
    localparam [31:0] HEADER_BCH = {bch({32'd0, HEADER}, 24), HEADER};
    localparam [63:0] SUB0_BCH = {bch(PAYLOAD0, 56), PAYLOAD0};

    reg [23:0] pixels [0:10];
    reg [10:0] de_delay;
    reg [10:0] hs_delay;
    reg [10:0] vs_delay;
    reg vs_previous;
    reg island_active;
    reg [6:0] island_tick;
    integer p;

    // 数据寄存器不复位；DE有效前流水中旧值不会被使用。
    always @(posedge clk) begin
        pixels[0] <= rgb;
        for (p = 1; p < 11; p = p + 1)
            pixels[p] <= pixels[p - 1];
    end

    always @(posedge clk) begin
        if (rst_p) begin
            de_delay <= 0;
            hs_delay <= 0;
            vs_delay <= 0;
            vs_previous <= 0;
            island_active <= 0;
            island_tick <= 0;
        end else begin
            de_delay <= {de_delay[9:0], de};
            hs_delay <= {hs_delay[9:0], hs};
            vs_delay <= {vs_delay[9:0], vs};
            vs_previous <= vs;
            if (vs && !vs_previous) begin
                island_active <= 1;
                island_tick <= 0;
            end else if (island_active) begin
                if (island_tick == 87)
                    island_active <= 0;
                else
                    island_tick <= island_tick + 1'b1;
            end
        end
    end

    wire video_guard = !de_delay[10] && (de_delay[9] || de_delay[8]);
    wire video_preamble = !de_delay[10] && !video_guard && (|de_delay[7:0]);
    wire island_preamble = island_active && island_tick >= 32 && island_tick < 40;
    wire island_guard = island_active && ((island_tick >= 40 && island_tick < 42) ||
                                           (island_tick >= 74 && island_tick < 76));
    wire island_data = island_active && island_tick >= 42 && island_tick < 74;
    wire [4:0] packet_index = island_tick - 7'd42;
    wire [5:0] even_bit = {packet_index, 1'b0};
    wire [5:0] odd_bit = {packet_index, 1'b1};
    wire [1:0] sync_bits = {vs_delay[10], hs_delay[10]};
    wire [2:0] mode = de_delay[10] ? 3'd1 : video_guard ? 3'd2 :
                      island_guard ? 3'd4 : island_data ? 3'd3 : 3'd0;
    wire [3:0] aux_blue = {packet_index != 0, HEADER_BCH[packet_index], sync_bits};
    wire [3:0] aux_green = {3'd0, SUB0_BCH[even_bit]};
    wire [3:0] aux_red = {3'd0, SUB0_BCH[odd_bit]};
    assign clock_word = 10'b1111100000;

    hdmi_tmds_channel #(.CHANNEL(0)) channel_blue (
        .clk(clk),
        .rst_p(rst_p),
        .video(pixels[10][7:0]),
        .control(sync_bits),
        .auxiliary(aux_blue),
        .mode(mode),
        .symbol(blue)
    );
    hdmi_tmds_channel #(.CHANNEL(1)) channel_green (
        .clk(clk),
        .rst_p(rst_p),
        .video(pixels[10][15:8]),
        .control({1'b0, video_preamble || island_preamble}),
        .auxiliary(aux_green),
        .mode(mode),
        .symbol(green)
    );
    hdmi_tmds_channel #(.CHANNEL(2)) channel_red (
        .clk(clk),
        .rst_p(rst_p),
        .video(pixels[10][23:16]),
        .control({1'b0, island_preamble}),
        .auxiliary(aux_red),
        .mode(mode),
        .symbol(red)
    );

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst_p && (island_guard || island_data || island_preamble) &&
            (de_delay[10] || video_guard || video_preamble))
            $fatal(1, "AVI island overlaps video");
    end
`endif
endmodule

// 用途：将一个RGB字节或控制/辅助字段编码成10位TMDS符号。
// 原理：先减少数据跳变，再按累计直流差选择反相；非视频阶段清零直流差。
// 编码表及包结构按HDMI 1.4定义实现；未包含串行器，继续使用原接口硬核。
module hdmi_tmds_channel #(
    parameter integer CHANNEL = 0
) (
    input wire clk,
    input wire rst_p,
    input wire [7:0] video,
    input wire [1:0] control,
    input wire [3:0] auxiliary,
    input wire [2:0] mode,
    output reg [9:0] symbol
);
    function [3:0] ones;
        input [7:0] data;
        integer i;
        begin
            ones = 0;
            for (i = 0; i < 8; i = i + 1)
                ones = ones + data[i];
        end
    endfunction

    function [9:0] control_symbol;
        input [1:0] value;
        begin
            case (value)
                0: control_symbol = 10'b1101010100;
                1: control_symbol = 10'b0010101011;
                2: control_symbol = 10'b0101010100;
                3: control_symbol = 10'b1010101011;
            endcase
        end
    endfunction

    function [9:0] terc4;
        input [3:0] value;
        begin
            case (value)
                0: terc4 = 10'b1010011100;
                1: terc4 = 10'b1001100011;
                2: terc4 = 10'b1011100100;
                3: terc4 = 10'b1011100010;
                4: terc4 = 10'b0101110001;
                5: terc4 = 10'b0100011110;
                6: terc4 = 10'b0110001110;
                7: terc4 = 10'b0100111100;
                8: terc4 = 10'b1011001100;
                9: terc4 = 10'b0100111001;
                10: terc4 = 10'b0110011100;
                11: terc4 = 10'b1011000110;
                12: terc4 = 10'b1010001110;
                13: terc4 = 10'b1001110001;
                14: terc4 = 10'b0101100011;
                15: terc4 = 10'b1011000011;
            endcase
        end
    endfunction

    wire [3:0] input_ones = ones(video);
    wire use_xnor = input_ones > 4 || (input_ones == 4 && !video[0]);
    reg [8:0] transition;
    reg signed [5:0] disparity;
    reg signed [5:0] next_disparity;
    reg [9:0] video_symbol;
    reg signed [5:0] balance;
    integer b;

    always @* begin
        transition[0] = video[0];
        for (b = 1; b < 8; b = b + 1)
            transition[b] = transition[b - 1] ^ video[b] ^ use_xnor;
        transition[8] = !use_xnor;
        balance = $signed({1'b0, ones(transition[7:0]), 1'b0}) - 6'sd8;
        if (disparity == 0 || balance == 0) begin
            video_symbol = {!transition[8], transition[8],
                            transition[8] ? transition[7:0] : ~transition[7:0]};
            next_disparity = disparity + (transition[8] ? balance : -balance);
        end else if ((disparity > 0 && balance > 0) || (disparity < 0 && balance < 0)) begin
            video_symbol = {1'b1, transition[8], ~transition[7:0]};
            next_disparity = disparity - balance + (transition[8] ? 6'sd2 : 6'sd0);
        end else begin
            video_symbol = {1'b0, transition[8], transition[7:0]};
            next_disparity = disparity + balance - (transition[8] ? 6'sd0 : 6'sd2);
        end
    end

    always @(posedge clk) begin
        if (rst_p) begin
            disparity <= 0;
            symbol <= 10'b1101010100;
        end else begin
            disparity <= mode == 1 ? next_disparity : 6'sd0;
            case (mode)
                1: symbol <= video_symbol;
                2: symbol <= CHANNEL == 1 ? 10'b0100110011 : 10'b1011001100;
                3: symbol <= terc4(auxiliary);
                4: symbol <= CHANNEL == 0 ? terc4({2'b11, control}) : 10'b0100110011;
                default: symbol <= control_symbol(control);
            endcase
        end
    end
endmodule
