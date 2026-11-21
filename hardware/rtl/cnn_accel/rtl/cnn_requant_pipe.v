`timescale 1ns/1ps
// 用途：为编码器、五个残差块及前两级解码运算共用整数再量化流水线。
// 原理：十拍循环给九个客户端各一个固定时隙；寄存请求后流水执行完整乘法、
//       两级最近偶数舍入和饱和。每层保留参数RAM和IN双区提交，不改变权重格式。
module cnn_requant_pipe #(
    parameter integer CLIENTS = 9
)(
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire [CLIENTS-1:0] request_valid,
    input wire [CLIENTS*61-1:0] request_data,
    output wire [CLIENTS-1:0] request_ready,
    output wire [CLIENTS-1:0] response_valid,
    output wire [9:0] slot_state,
    output wire [8:0] response_data
);
    // 九个客户端时第十拍留空；卷积每通道最多十拍，残差原来的十拍接收间隔可以保持。
    localparam MAG_W = 23;
    localparam PW = MAG_W + 31;
    localparam RW = PW - 32 + 1;
    reg [9:0] slot;
    assign slot_state = slot;
    reg [CLIENTS-1:0] tag0;
    reg [CLIENTS-1:0] tag1;
    reg [CLIENTS-1:0] tag2;
    reg [CLIENTS-1:0] tag3;
    reg [60:0] selected;
    reg [60:0] arguments;
    reg [PW-1:0] product;
    reg [RW:0] prepared;
    reg [RW-1:0] rounded;
    reg [5:0] meta1;
    reg [5:0] meta2;
    reg [5:0] meta3;
    wire [CLIENTS-1:0] grant = request_valid & request_ready;
    wire issue = |grant;
    integer client;
    always @* begin
        selected = 0;
        for (client = 0; client < CLIENTS; client = client + 1)
            selected = selected | (request_data[client*61 +: 61] & {61{slot[client]}});
    end
    assign request_ready = clear ? 0 : slot[CLIENTS-1:0];
    assign response_valid = clear ? 0 : tag3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot <= 10'b1;
            tag0 <= 0;
            tag1 <= 0;
            tag2 <= 0;
            tag3 <= 0;
        end else if (clear) begin
            slot <= 10'b1;
            tag0 <= 0;
            tag1 <= 0;
            tag2 <= 0;
            tag3 <= 0;
        end else begin
            slot <= {slot[8:0],slot[9]};
            tag0 <= grant;
            tag1 <= tag0;
            tag2 <= tag1;
            tag3 <= tag2;
        end
    end

    function [RW:0] prepare_round;
        input [PW-1:0] value;
        input [3:0] shift;
        reg [RW-1:0] work;
        reg sticky;
        integer bit_index;
        begin
            work = value[PW-1:31];
            sticky = |value[30:0];
            for (bit_index = 0; bit_index < 2; bit_index = bit_index + 1) begin
                if (shift[bit_index]) begin
                    sticky = sticky || (|(work & (({{(RW-1){1'b0}},1'b1} << (1 << bit_index))-1)));
                    work = work >> (1 << bit_index);
                end
            end
            prepare_round = {sticky,work};
        end
    endfunction
    function [RW-1:0] finish_round;
        input [RW:0] value;
        input [3:0] shift;
        reg [RW-1:0] work;
        reg sticky;
        reg [RW-1:0] quotient;
        integer bit_index;
        begin
            work = value[RW-1:0];
            sticky = value[RW];
            for (bit_index = 2; bit_index < 4; bit_index = bit_index + 1) begin
                if (shift[bit_index]) begin
                    sticky = sticky || (|(work & (({{(RW-1){1'b0}},1'b1} << (1 << bit_index))-1)));
                    work = work >> (1 << bit_index);
                end
            end
            quotient = {1'b0,work[RW-1:1]};
            if (work[0] && (sticky || work[1])) quotient = quotient + 1'b1;
            finish_round = quotient;
        end
    endfunction

    // 请求寄存与乘法分开，避免九路参数选择器进入 DSP 乘法组合路径。
    // 参数布局：{有符号输出,负号,shift-32,multiplier[30:0],magnitude[23:0]}。
    always @(posedge clk) begin
        if (issue) arguments <= selected;
        if (|tag0) begin
            product <= arguments[MAG_W-1:0] * arguments[54:24];
            meta1 <= arguments[60:55];
        end
        if (|tag1) begin
            prepared <= prepare_round(product,meta1[3:0]);
            meta2 <= meta1;
        end
        if (|tag2) begin
            rounded <= finish_round(prepared,meta2[3:0]);
            meta3 <= meta2;
        end
    end
    wire [6:0] clipped_magnitude = rounded > 127 ? 7'd127 : rounded[6:0];
    wire [7:0] clipped = meta3[4] ?
        (meta3[5] ? -$signed({1'b0,clipped_magnitude}) : 8'd0) : {1'b0,clipped_magnitude};
    assign response_data = {clipped[7],clipped};
`ifndef SYNTHESIS
    initial if (CLIENTS != 9 && CLIENTS != 10) $fatal(1,"requant service requires nine or ten clients");
    always @(posedge clk) if (rst_n && !clear && issue && selected[23])
        $fatal(1,"shared requant magnitude exceeds validated 23-bit range");
`endif
endmodule

