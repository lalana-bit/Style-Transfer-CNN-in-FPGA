// 定点仿射辅助单元：为兼容量化分支提供单通道乘法、加法和移位。
`timescale 1ns/1ps

// 用途：为兼容量化分支提供单通道定点仿射计算，不负责统计图像均值或方差。
// 原理：流水执行输入乘 scale_a、加 bias_b、算术右移和饱和，同时等延迟传递帧、行及有效信号。
module cnn_affine #(
    parameter DATA_WIDTH = 8,
    // 输入/输出数据位宽（有符号 2's complement）
    parameter COEF_WIDTH = 16,
    // 归一化系数 A 位宽（有符号定点）
    parameter BIAS_WIDTH = 32,
    // 偏置 b 位宽（有符号定点）
    // 结果右移位数（定点对齐，>= 0）
    parameter SHIFT = 8
) (
    input clk,
    input rst_n,
    input pre_img_vsync,
    input pre_img_href,
    input pre_img_clken,
    input signed [DATA_WIDTH - 1:0] pre_img_data,
    // 归一化参数（上电初期由 DDR 读出/计算后输入，加载后可保持稳定）
    input signed [COEF_WIDTH - 1:0] scale_a,
    // y = A*x + b 中的 A
    input signed [BIAS_WIDTH - 1:0] bias_b,
    // y = A*x + b 中的 b
    output reg post_img_vsync,
    output reg post_img_href,
    output reg post_img_valid,
    output reg signed [DATA_WIDTH - 1:0] post_img_data
);

    localparam integer LAT = 3;
    // 流水总级数
    localparam integer PROD_W = DATA_WIDTH + COEF_WIDTH;
    // 乘积位宽
    localparam integer ACC_W = (PROD_W > BIAS_WIDTH ? PROD_W:BIAS_WIDTH) + 1;
    // 求和位宽(留 1bit 余量)
    // 输出饱和上下界（有符号 DATA_WIDTH 位）
    localparam signed [ACC_W - 1:0] OUT_MAX = (1 << (DATA_WIDTH - 1)) - 1;
    localparam signed [ACC_W - 1:0] OUT_MIN = - (1 << (DATA_WIDTH - 1));
    //===================================================================
    // [1] 乘：p = x * A      （1 级）
    //===================================================================
    reg signed [PROD_W - 1:0] prod_r;
    // 仅保持无效数据拍，不暂停控制链；连续有效时仍每拍接收一个像素。

    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) prod_r <= { PROD_W { 1'b0 } };
        else if (pre_img_href && pre_img_clken) prod_r <= pre_img_data * scale_a;
    end
    //===================================================================
    // [2] 加偏置：s = p + b  （1 级）
    //===================================================================
    reg signed [ACC_W - 1:0] sum_r;

    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) sum_r <= { ACC_W { 1'b0 } };
        else if (vld_d1) sum_r <= prod_r + bias_b;
    end
    //===================================================================
    // [3] 右移 + 饱和：y = clamp(s >>> SHIFT)   （输出级）
    //     与卷积模块一致采用算术右移（floor）；饱和防止结果回绕。
    //===================================================================
    wire signed [ACC_W - 1:0] shifted = sum_r >>> SHIFT;
    wire signed [DATA_WIDTH - 1:0] sat_result = (shifted > OUT_MAX) ? OUT_MAX [DATA_WIDTH - 1:0]:(shifted < OUT_MIN) ? OUT_MIN [DATA_WIDTH - 1:0]:shifted [DATA_WIDTH - 1:0];
    //===================================================================
    // 控制延迟链（LAT-1 级），再与数据同拍寄存到 post_*（第 LAT 级）
    //   valid 在输入侧即为 "href & clken"，随数据一起延迟，保证同拍。
    //===================================================================
    reg href_d1;
    reg href_d2;
    reg vld_d1;
    reg vld_d2;
    reg vsync_d1;
    reg vsync_d2;

    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) begin
            href_d1 <= 1'b0;
            href_d2 <= 1'b0;
            vld_d1 <= 1'b0;
            vld_d2 <= 1'b0;
            vsync_d1 <= 1'b0;
            vsync_d2 <= 1'b0;
        end else begin
            href_d1 <= pre_img_href;
            vld_d1 <= pre_img_href & pre_img_clken;
            vsync_d1 <= pre_img_vsync;
            href_d2 <= href_d1;
            vld_d2 <= vld_d1;
            vsync_d2 <= vsync_d1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (! rst_n) begin
            post_img_vsync <= 1'b0;
            post_img_href <= 1'b0;
            post_img_valid <= 1'b0;
            post_img_data <= { DATA_WIDTH { 1'b0 } };
        end else begin
            post_img_vsync <= vsync_d2;
            post_img_href <= href_d2;
            post_img_valid <= vld_d2;
            // 无效拍保持数据，valid/href/vsync 仍然每拍推进。
            if (vld_d2) post_img_data <= sat_result;
        end
    end
endmodule
