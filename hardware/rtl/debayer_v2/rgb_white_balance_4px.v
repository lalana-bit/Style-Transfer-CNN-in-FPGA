`timescale 1ns/1ps
// 用途：去马赛克后对每拍四个 BGR 像素进行白平衡，像素 0 位于低位。
// 原理：Q14 增益乘法映射到 DSP，随后按原规则舍入饱和；保持两拍延迟。
module rgb_white_balance_4px #(
    parameter [15:0] GAIN_R_Q14 = 16'd17920,
    parameter [15:0] GAIN_G_Q14 = 16'd16320,
    parameter [15:0] GAIN_B_Q14 = 16'd22400,
    parameter integer BYPASS = 0
)(
    input wire clk, rst_n,
    input wire i_vs, i_hs, i_de, i_valid,
    input wire [95:0] i_data,
    output wire o_vs, o_hs, o_de, o_valid,
    output wire [95:0] o_data
);
    function [15:0] clamp_gain;
        input [15:0] gain;
        begin
            clamp_gain = (gain < 16'd6554) ? 16'd6554 :
                         ((gain > 16'd40960) ? 16'd40960 : gain);
        end
    endfunction
    localparam [15:0] GR = clamp_gain(GAIN_R_Q14);
    localparam [15:0] GG = clamp_gain(GAIN_G_Q14);
    localparam [15:0] GB = clamp_gain(GAIN_B_Q14);

    // 增益仍限制在原范围；加半个量化单位后右移，超出 8 位时饱和。
    function [7:0] finish_pixel;
        input [23:0] product;
        reg [24:0] rounded;
        begin
            rounded = ({1'b0, product} + 25'd8192) >> 14;
            finish_pixel = (rounded > 25'd255) ? 8'd255 : rounded[7:0];
        end
    endfunction

    reg [3:0] ctrl1 = 0, ctrl2 = 0;
    always @(posedge clk) begin
        if (!rst_n) begin ctrl1 <= 0; ctrl2 <= 0; end
        else begin ctrl1 <= {i_vs,i_hs,i_de,i_valid}; ctrl2 <= ctrl1; end
    end
    assign {o_vs,o_hs,o_de,o_valid} = ctrl2;
    genvar p;
    generate
        if (BYPASS) begin:g_bypass
            reg [95:0] raw1 = 0, raw2 = 0;
            always @(posedge clk) begin
                if (!rst_n) begin raw1 <= 0; raw2 <= 0; end
                else begin raw1 <= i_data; raw2 <= raw1; end
            end
            assign o_data = raw2;
        end else begin:g_balance
            for (p = 0; p < 4; p = p + 1) begin:g_pixel
                (* syn_use_dsp="yes" *) wire [23:0] product_r = i_data[p*24+:8] * GR;
                (* syn_use_dsp="yes" *) wire [23:0] product_g = i_data[p*24+8+:8] * GG;
                (* syn_use_dsp="yes" *) wire [23:0] product_b = i_data[p*24+16+:8] * GB;
                reg [23:0] mr = 0, mg = 0, mb = 0, balanced = 0;
                always @(posedge clk) begin
                    if (!rst_n) begin mr <= 0; mg <= 0; mb <= 0; balanced <= 0; end
                    else begin
                        mr <= product_r;
                        mg <= product_g;
                        mb <= product_b;
                        balanced <= {finish_pixel(mb),finish_pixel(mg),finish_pixel(mr)};
                    end
                end
                assign o_data[p*24+:24] = balanced;
            end
        end
    endgenerate
endmodule
