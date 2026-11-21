// 公共缓存：同步数据与参数 RAM，以及不同接口的 FIFO。
`timescale 1ns/1ps

// 用途：使用块 RAM 缓冲窄通道数据，吸收上下游流水的短时速率差异。
// 原理：通过读写指针与占用计数管理同步 RAM，采用预取保持输出，利用 ready/valid 处理反压，不清零数据阵列。
module cnn_ram_fifo #(
    parameter W = 16,
    parameter D = 1024,
    parameter AW = $clog2(D)
) (
    input clk,
    input rst,
    input [W - 1:0] i_data,
    input i_valid,
    output i_ready,
    output reg [W - 1:0] o_data,
    output reg o_valid,
    input o_ready
);

    reg [AW - 1:0] wp;
    reg [AW - 1:0] rp;
    reg [AW:0] count;
    reg pending;
    wire [W - 1:0] rq;
    assign i_ready = count < D;
    wire push = i_valid && i_ready;
    wire read_issue = count != 0 && ! pending && (! o_valid || o_ready);

    // 非二次幂深度按已有RAM分段实现，避免旁路容量向上取整浪费。
    generate
        if (D > 512 && (D & (D - 1)) != 0) begin : g_split_storage
            cnn_sdp_ram #(
                .W(W),
                .D(D),
                .AW(AW)
            ) storage (
                .clk(clk),
                .we(push && !rst),
                .waddr(wp),
                .wdata(i_data),
                .re(read_issue && !rst),
                .raddr(rp),
                .rdata(rq)
            );
        end else begin : g_storage
            (* syn_ramstyle="block_ram" *)
            reg [W - 1:0] mem [0:D - 1];
            reg [W - 1:0] read_q;
            always @(posedge clk) begin
                if (push && !rst) mem[wp] <= i_data;
                if (read_issue && !rst) read_q <= mem[rp];
            end
            assign rq = read_q;
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            wp <= 0;
            rp <= 0;
            count <= 0;
            pending <= 0;
            o_valid <= 0;
        end else begin
            pending <= read_issue;
            if (push) wp <= (wp == D - 1) ? 0:wp + 1'b1;
            if (read_issue) rp <= (rp == D - 1) ? 0:rp + 1'b1;
            case ({ push, read_issue })
                2'b10:count <= count + 1'b1;
                2'b01:count <= count - 1'b1;
            endcase
            if (o_valid && o_ready) o_valid <= 0;
            if (pending) begin
                o_data <= rq;
                o_valid <= 1;
            end
        end
    end
endmodule

// 用途：为浅深度数据流提供带 ready/valid 接口的轻量 FIFO。
// 原理：写入时整体移动寄存链，按占用数选择最老数据；只复位计数，移位存储可映射为 SRL8。
module cnn_stream_fifo #(
    parameter W = 8,
    parameter AW = 2
) (
    input clk,
    input rst,
    input [W - 1:0] i_data,
    input i_valid,
    output i_ready,
    output [W - 1:0] o_data,
    output o_valid,
    input o_ready,
    output [AW:0] count
);

    localparam D = 1 << AW;
    reg [W - 1:0] sr [0:D - 1];
    reg [AW:0] cnt;
    wire we = i_valid && i_ready;
    wire re = o_valid && o_ready;
    wire [AW:0] ra = cnt - 1'b1;
    integer k;
    assign count = cnt;
    assign i_ready = (cnt != D);
    assign o_valid = (cnt != 0);
    assign o_data = sr [ra [AW - 1:0]];

    always @(posedge clk) if (we) begin
        sr [0] <= i_data;
        for (k = 1; k < D; k = k + 1) sr [k] <= sr [k - 1];
    end

    always @(posedge clk) if (rst) cnt <= 0;
    else cnt <= cnt + we - re;
endmodule

// 用途：为乘加引擎保存旁路字节或待输出结果，提供显式读写及空满状态。
// 原理：数据以移位寄存链存储，用占用计数定位队首；调用方根据 full/empty 控制读写，避免占用整块 RAM。
module cnn_shift_fifo #(
    parameter W = 8,
    parameter D = 16
) (
    input clk,
    input rst,
    input [W - 1:0] din,
    input we,
    // 满时须同拍 re 才能写
    input re,
    // 空时不得读
    output [W - 1:0] dout,
    // 最老元素（空时无意义）
    output empty,
    output full
);

    localparam AW = (D > 1) ? $clog2(D):1;
    reg [W - 1:0] sr [0:D - 1];
    reg [AW:0] cnt;
    integer k;

    always @(posedge clk) if (we) begin
        sr [0] <= din;
        for (k = 1; k < D; k = k + 1) sr [k] <= sr [k - 1];
    end
    wire [AW:0] ra = cnt - 1'b1;
    assign dout = sr [ra [AW - 1:0]];
    assign empty = (cnt == 0);
    assign full = (cnt == D);

    always @(posedge clk) if (rst) cnt <= 0;
    else cnt <= cnt + we - re;
endmodule

// 用途：提供一写一读的同步数据 RAM，供卷积行缓存等单元使用。
// 原理：读写由各自使能控制；必要时把非二次幂深度拆成两段，寄存段选择以维持相同读延迟并减少 RAM 浪费。
module cnn_sdp_ram #(
    parameter W = 32,
    parameter D = 1024,
    parameter AW = 10,
    parameter INIT = ""
) (
    input clk,
    input we,
    input [AW - 1:0] waddr,
    input [W - 1:0] wdata,
    input re,
    input [AW - 1:0] raddr,
    output [W - 1:0] rdata
);

    localparam SPLIT = (D > 512) && ((D & (D - 1)) != 0) && (INIT == "");

    generate
        if (SPLIT) begin : g_split
            localparam D0 = 1 << ($clog2(D) - 1);
            localparam A0 = $clog2(D0);
            localparam D1 = D - D0;
            reg [W - 1:0] m0 [0:D0 - 1];
            reg [W - 1:0] m1 [0:D1 - 1];
            reg [W - 1:0] q0;
            reg [W - 1:0] q1;
            reg sel;
            wire whi = (waddr >= D0);
            wire rhi = (raddr >= D0);
            wire [AW - 1:0] wa1 = waddr - D0;
            wire [AW - 1:0] ra1 = raddr - D0;

            always @(posedge clk) begin
                if (we && ! whi) m0 [waddr [A0 - 1:0]] <= wdata;
                if (we && whi) m1 [wa1] <= wdata;
                if (re) begin
                    q0 <= m0 [raddr [A0 - 1:0]];
                    q1 <= m1 [ra1];
                    sel <= rhi;
                end
            end
            assign rdata = sel ? q1:q0;
        end else begin : g_one
            reg [W - 1:0] mem [0:D - 1];
            reg [W - 1:0] q;
            initial if (INIT != "") $readmemh(INIT, mem);

            always @(posedge clk) begin
                if (we) mem [waddr] <= wdata;
                if (re) q <= mem [raddr];
            end
            assign rdata = q;
        end
    endgenerate
endmodule

// 用途：保存逐通道量化参数，避免浅参数表被综合为大量触发器。
// 原理：采用独立地址的同步写、同步读结构，并用块 RAM 属性约束存储实现。
module cnn_param_ram #(
    parameter integer DW = 16,
    parameter integer AW = 4,
    parameter integer DEPTH = 16
) (
    input clk,
    input we,
    input [AW - 1:0] wa,
    input [AW - 1:0] ra,
    input [DW - 1:0] din,
    output reg [DW - 1:0] dout
);

    (* syn_ramstyle="block_ram" *)
    reg [DW - 1:0] mem [0:DEPTH - 1];

    always @(posedge clk) if (we) mem [wa] <= din;

    always @(posedge clk) dout <= mem [ra];
endmodule
