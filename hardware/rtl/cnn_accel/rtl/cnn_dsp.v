// DSP24 乘法与累加封装，提供行为一致的通用仿真实现。
`timescale 1ns/1ps

// 用途：封装 8 位输入乘法与可选的 24 位累加，统一各计算单元的 DSP 接口。
// 原理：硬件分支使用 DSP24 原语，通用分支用寄存器与运算表达式匹配相同延迟、使能暂停和复位行为。
module cnn_dsp #(
    parameter integer LATENCY = 2,
    parameter integer SIGNED_INPUT = 0,
    parameter integer ACCUMULATE = 0
) (
    input clk,
    input ce,
    input rst,
    input [7:0] a,
    input [7:0] b,
    input signed [23:0] c,
    output signed [23:0] o,
    input first
);

`ifndef SYNTHESIS
    initial if (LATENCY < 0 || LATENCY > 2) $fatal(1, "cnn_dsp: LATENCY must be 0, 1 or 2");
`endif
    wire signed [23:0] product;
    wire signed [23:0] c_aligned;
    // first 与 A/B 同步，在首个乘积到达之前一拍清零累加寄存器 W。
    // 复位累加器时 A/B/P 流水继续填充；累加模式要求 LATENCY=2。
    reg first_delay;

    always @(posedge clk) if (ce) first_delay <= first;

    generate
        if (LATENCY == 0) begin : g_c0
            assign c_aligned = c;
        end else begin : g_cpipe
            reg signed [23:0] c1;

            always @(posedge clk or posedge rst) begin
                if (rst) c1 <= 0;
                else if (ce) c1 <= c;
            end
            if (LATENCY == 1) begin : g_one
                assign c_aligned = c1;
            end else begin : g_two
                reg signed [23:0] c2;

                always @(posedge clk or posedge rst) begin
                    if (rst) c2 <= 0;
                    else if (ce) c2 <= c1;
                end
                assign c_aligned = c2;
            end
        end
    endgenerate
`ifdef USE_EFX_DSP24
    // A/B 和乘积寄存器严格由 LATENCY 决定；单个 DSP 不使用级联。
    wire [23:0] product_raw;
    // 8x8 无符号乘积仅占 16bit，显式补零让综合器裁掉多余加法位。
    assign product = ACCUMULATE ? product_raw:(SIGNED_INPUT ? { { 8 { product_raw [15] } }, product_raw [15:0] }:{ 8'd0, product_raw [15:0] });
    EFX_DSP24 #(
        .A_REG(LATENCY >= 1),
        .B_REG(LATENCY >= 1),
        .C_REG(0),
        .P_REG(LATENCY == 2),
        .OP_REG(0),
        .W_REG(ACCUMULATE),
        .O_REG(0),
        .RST_SYNC(ACCUMULATE),
        .SIGNED(SIGNED_INPUT),
        .SHIFTER(0),
        .P_EXT("ALIGN_RIGHT"),
        .C_EXT("ALIGN_RIGHT"),
        .M_SEL("P"),
        .N_SEL(ACCUMULATE ? "W":"CONST0"),
        .W_SEL(ACCUMULATE ? "X":"P"),
        .CASCOUT_SEL("P"),
        .CLK_POLARITY(1),
        .CE_POLARITY(1),
        .RST_POLARITY(1),
        .SHIFT_ENA_POLARITY(1),
        .A_REG_USE_CE(LATENCY >= 1),
        .B_REG_USE_CE(LATENCY >= 1),
        .P_REG_USE_CE(LATENCY == 2),
        .A_REG_USE_RST(! ACCUMULATE && LATENCY >= 1),
        .B_REG_USE_RST(! ACCUMULATE && LATENCY >= 1),
        .P_REG_USE_RST(! ACCUMULATE && LATENCY == 2),
        .C_REG_USE_CE(0),
        .OP_REG_USE_CE(0),
        .W_REG_USE_CE(ACCUMULATE),
        .O_REG_USE_CE(0),
        .C_REG_USE_RST(0),
        .OP_REG_USE_RST(0),
        .W_REG_USE_RST(ACCUMULATE),
        .O_REG_USE_RST(0)
    ) u_dsp (
        .A(a),
        .B(b),
        .C(8'd0),
        .CASCIN(24'd0),
        .OP(2'b00),
        // Efinity 要求：全部寄存器关闭时，原语 CLK 必须接常量。
        .SHIFT_ENA(1'b0),
        .CLK((LATENCY == 0) ? 1'b0:clk),
        .CE((LATENCY == 0) ? 1'b0:ce),
        .RST((LATENCY == 0) ? 1'b0:(rst || (ACCUMULATE && first_delay))),
        .O(product_raw),
        .CASCOUT()
    );

`else
    // 通用 RTL 与原语使用相同流水位置，含使能暂停和复位行为。
    wire [7:0] a_value;
    wire [7:0] b_value;
    wire [15:0] prod16;

    generate
        if (LATENCY >= 1) begin : g_ab
            reg [7:0] a1;
            reg [7:0] b1;

            always @(posedge clk or posedge rst) begin
                if (rst) begin
                    a1 <= 0;
                    b1 <= 0;
                end else if (ce) begin
                    a1 <= a;
                    b1 <= b;
                end
            end
            assign a_value = a1;
            assign b_value = b1;
        end else begin : g_direct
            assign a_value = a;
            assign b_value = b;
        end
    endgenerate

    generate
        if (SIGNED_INPUT) begin : g_signed_product
            assign prod16 = $signed(a_value) * $signed(b_value);
        end else begin : g_unsigned_product
            assign prod16 = a_value * b_value;
        end
    endgenerate
    wire signed [23:0] aligned_product;

    generate
        if (LATENCY == 2) begin : g_p
            reg [15:0] p2;

            always @(posedge clk or posedge rst) begin
                if (rst) p2 <= 0;
                else if (ce) p2 <= prod16;
            end
            assign aligned_product = SIGNED_INPUT ? { { 8 { p2 [15] } }, p2 }:{ 8'd0, p2 };
        end else begin : g_pc
            assign aligned_product = SIGNED_INPUT ? { { 8 { prod16 [15] } }, prod16 }:{ 8'd0, prod16 };
        end
    endgenerate

    generate
        if (ACCUMULATE) begin : g_accumulate
            reg signed [23:0] accumulator;

            always @(posedge clk) if (rst || first_delay) accumulator <= 0;
            else if (ce) accumulator <= accumulator + aligned_product;
            assign product = accumulator;
        end else begin : g_multiply
            assign product = aligned_product;
        end
    endgenerate
`endif
    // 保留完整加数；结果按原接口的 24bit 二补码回绕，不在封装内饱和。
    assign o = product + c_aligned;
endmodule
