// 分组乘加引擎：分别处理标准卷积和逐通道卷积。
`timescale 1ns/1ps

// 用途：计算标准卷积或逐点卷积的输入通道与输出通道之间的乘加。
// 原理：以 G 个输入通道和 PE 个输出通道并行运算，按输入组及核位置分时累加，再按通道顺序串行输出结果。
module cnn_dense_mac #(
    parameter integer SHARED_TAIL = 0,
    parameter G = 4,
    parameter NI = 36,
    parameter COUT = 24,
    parameter PE = 4,
    parameter ACC_W = 26,
    parameter SIDE_IN = 0,
    parameter WFILE = ""
) (
    input clk,
    input rst,
    input w_we,
    // 权重写口（CPU 装载）
    input [4:0] w_lane,
    input [11:0] w_addr,
    input [31:0] w_data,
    input [G * 8 - 1:0] i_data,
    input [G * 8 - 1:0] i_side,
    input i_valid,
    output i_ready,
    output [ACC_W - 1:0] o_acc,
    output [7:0] o_side,
    output o_last,
    output o_valid,
    input o_ready,
    output wire t_write_valid,
    output wire [4:0] t_write_lane,
    output wire [6:0] t_write_address,
    output wire [7:0] t_write_data,
    output wire t_read_valid,
    output wire [6:0] t_read_address,
    input wire t_read_ready,
    input wire t_response_valid,
    input wire [63:0] t_response_data
);

    // U7×INT8的NI×G项和可用更窄的有符号数精确表示。
    // 只收窄内部部分和与输出队列，对外仍按ACC_W符号扩展。
    localparam NEED_W = 1 + $clog2(NI * G * 127 * 128);
    localparam SUM_W = (NEED_W < ACC_W) ? NEED_W : ACC_W;
    localparam NF = COUT / PE;
    localparam WD = NI * NF;
    localparam WAW = (WD > 1) ? $clog2(WD):1;
    localparam IW = (NI > 1) ? $clog2(NI):1;
    localparam FW = (NF > 1) ? $clog2(NF):1;
    localparam OCW = (COUT > 1) ? $clog2(COUT):1;
    localparam PW = (PE > 1) ? $clog2(PE):1;
    // ---- 第 0 级：取数并发出权重地址 ----
    reg [G * 8 - 1:0] x0;
    reg x0_v;
    reg [IW - 1:0] i0;
    reg [FW - 1:0] f0;
    wire s0_fire;
    wire s0_last_f = (f0 == NF - 1);
    wire stall;
    assign i_ready = ! stall && (! x0_v || s0_last_f);
    assign s0_fire = x0_v && ! stall;
    wire [WAW - 1:0] waddr = i0 * NF + f0;
    wire [PE * G * 8 - 1:0] wrow;
    wire [PE * G * 8 - 1:0] main_row;
    wire tail_mode = SHARED_TAIL && waddr >= 1024;
    wire output_stall;
    wire memory_stall = tail_mode && x0_v && !t_read_ready;
    reg previous_tail;
    reg [63:0] tail_hold;
    assign t_write_valid = SHARED_TAIL && w_we && w_addr >= 1024;
    assign t_write_lane = w_lane;
    assign t_write_address = w_addr[6:0];
    assign t_write_data = w_data[7:0];
    assign t_read_valid = SHARED_TAIL && !rst && tail_mode && x0_v && !output_stall;
    assign t_read_address = waddr;
    always @(posedge clk) begin
        if (rst) previous_tail <= 0;
        else if (s0_fire) previous_tail <= tail_mode;
        if (SHARED_TAIL && t_response_valid) tail_hold <= t_response_data;
    end
    assign wrow = (SHARED_TAIL && previous_tail) ?
                  (t_response_valid ? t_response_data : tail_hold) : main_row;


    generate
        if (G == 2 && PE == 1) begin : g_res_weights
            cnn_weight_pair #(
                .DEPTH(SHARED_TAIL ? 1024 : WD),
                .AW(SHARED_TAIL ? 10 : WAW)
            ) u_w (
                .clk(clk),
                .we(w_we && (!SHARED_TAIL || w_addr < 1024)),
                .half(w_lane [0]),
                .wa(w_addr [WAW - 1:0]),
                .din(w_data [7:0]),
                .re(s0_fire && !tail_mode),
                .ra(waddr),
                .rdata(main_row)
            );

        end else begin : g_codec_weights
            cnn_weight_rows #(
                .LOAD_GROUPS(NF),
                .LANES(G * PE),
                .DEPTH(SHARED_TAIL ? 1024 : WD),
                .AW(SHARED_TAIL ? 10 : WAW)
            ) u_w (
                .clk(clk),
                .we(w_we && (!SHARED_TAIL || w_addr < 1024)),
                .lane(w_lane),
                .wa(w_addr [WAW - 1:0]),
                .din(w_data [7:0]),
                .re(s0_fire && !tail_mode),
                .ra(waddr),
                .rdata(main_row)
            );

        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            x0_v <= 1'b0;
            i0 <= 0;
            f0 <= 0;
        end else begin
            if (i_valid && i_ready) begin
                x0 <= i_data;
                x0_v <= 1'b1;
                f0 <= 0;
            end else if (s0_fire) begin
                if (s0_last_f) x0_v <= 1'b0;
                else f0 <= f0 + 1'b1;
            end
            if (s0_fire && s0_last_f) i0 <= (i0 == NI - 1) ? 0:i0 + 1'b1;
        end
    end
    // ---- 第 1 级：乘法 ----
    reg [G * 8 - 1:0] x1;
    reg v1;
    reg first1;
    reg last1;
    reg [FW - 1:0] f1;
    wire signed [23:0] prod [0:PE * G - 1];
    reg v2;
    reg first2;
    reg last2;
    reg [FW - 1:0] f2;
    integer p;
    integer j;

    always @(posedge clk) begin
        if (rst) begin
            v1 <= 1'b0;
            v2 <= 1'b0;
        end else if (! stall) begin
            v1 <= s0_fire;
            x1 <= x0;
            f1 <= f0;
            first1 <= (i0 == 0);
            last1 <= (i0 == NI - 1);
            v2 <= v1;
            f2 <= f1;
            first2 <= first1;
            last2 <= last1;
        end
    end
    genvar dp;
    genvar dj;

    generate
        for (dp = 0; dp < PE; dp = dp + 1) begin : g_dp
            for (dj = 0; dj < G; dj = dj + 1) begin : g_dj
                cnn_dsp #(
                    .LATENCY(1),
                    .SIGNED_INPUT(1)
                ) u_dsp (
                    .clk(clk),
                    .ce(! stall),
                    .rst(rst),
                    .a({ 1'b0, x1 [dj * 8+:7] }),
                    .b(wrow [(dp * G + dj) * 8+:8]),
                    .c(24'sd0),
                    .o(prod [dp * G + dj]),
                    .first(1'b0)
                );

            end
        end
    endgenerate
    // ---- 第 2 级：求和并累加到环形累加器 ----
    reg signed [SUM_W - 1:0] psum [0:PE - 1];

    always @(*) begin
        for (p = 0; p < PE; p = p + 1) begin
            psum[p] = 0;
            for (j = 0; j < G; j = j + 1)
                psum[p] = psum[p] + prod[p*G+j];
        end
    end

    // 环形累加器：每个输入字按 f=0..NF-1 依次访问，恰好是长度 NF 的延迟线——
    // 队头 ring[0] 是本拍 f2 的旧值，新值写入队尾，每拍整体前移（无复位、只读队头，可映射 SRL8）
    reg  [PE*SUM_W-1:0] ring [0:NF-1];
    wire [PE*SUM_W-1:0] head = ring[0];
    reg  [PE*SUM_W-1:0] nrow;
    always @(*) for (p = 0; p < PE; p = p + 1) nrow [p * SUM_W+:SUM_W] = (first2 ? { SUM_W { 1'b0 } }:head [p * SUM_W+:SUM_W]) + psum [p];
    wire acc_en = v2 && ! stall;
    integer k;

    always @(posedge clk) if (acc_en) begin
        for (k = 0; k < NF - 1; k = k + 1) ring [k] <= ring [k + 1];
        ring [NF - 1] <= nrow;
    end
    // 旁路字节（1x1 残差层，要求 PE=1 且 NI*G=COUT）：输入字的 G 个 side 字节按通道顺序进 FIFO，
    // 输出时按通道顺序取用；深度 2*NI 覆盖"当前像素末字输出时，下一像素的前 NI-1 个字已到达"的最坏情况
    wire [G * 8 - 1:0] sd_q;
    wire sd_pop;

    generate
        if (SIDE_IN) begin : g_sd
            cnn_shift_fifo #(
                .W(G * 8),
                .D(2 * NI)
            ) u_sd (
                .clk(clk),
                .rst(rst),
                .din(i_side),
                .we(i_valid && i_ready),
                .re(sd_pop),
                .dout(sd_q),
                .empty(),
                .full()
            );

        end else begin : g_nsd
            assign sd_q = { (G * 8) { 1'b0 } };
        end
    endgenerate
    wire [7:0] sbyte = sd_q [(f2 % G) * 8+:8];
    // 输出 FIFO：末字的每一拍产出 PE 个通道终值，入队；读侧逐通道串行输出（深度 NF = 一个像素）
    localparam OW = PE * SUM_W + (SIDE_IN ? 8:0);
    wire of_we = v2 && last2 && ! stall;
    wire [OW - 1:0] of_d;
    wire [OW - 1:0] of_q;
    wire of_empty;
    wire of_full;
    wire of_pop;

    generate
        if (SIDE_IN) begin : g_ofs
            assign of_d = { sbyte, nrow };
        end else begin : g_of
            assign of_d = nrow;
        end
    endgenerate
    assign sd_pop = SIDE_IN && of_we && ((f2 % G == G - 1) || (f2 == NF - 1));
    cnn_shift_fifo #(
        .W(OW),
        .D(NF)
    ) u_of (
        .clk(clk),
        .rst(rst),
        .din(of_d),
        .we(of_we),
        .re(of_pop),
        .dout(of_q),
        .empty(of_empty),
        .full(of_full)
    );

    reg [OCW - 1:0] ocnt;
    // 输出通道号
    reg [PW - 1:0] pidx;
    // 当前 FIFO 元素内的 PE 序号
    assign o_valid = ! of_empty;
    assign o_acc = $signed(of_q [pidx * SUM_W+:SUM_W]);
    assign o_side = SIDE_IN ? of_q [OW - 1-:8]:8'd0;
    assign o_last = (ocnt == COUT - 1);
    assign of_pop = o_valid && o_ready && (pidx == PE - 1);
    // 输出 FIFO 满且本拍不出队时，末字的节拍停顿
    assign output_stall = v2 && last2 && of_full && !of_pop;
    assign stall = output_stall || memory_stall;

    always @(posedge clk) begin
        if (rst) begin
            ocnt <= 0;
            pidx <= 0;
        end else if (o_valid && o_ready) begin
            ocnt <= (ocnt == COUT - 1) ? 0:ocnt + 1'b1;
            pidx <= (pidx == PE - 1) ? 0:pidx + 1'b1;
        end
    end
endmodule

// 用途：计算各通道相互独立的 3×3 深度卷积，不进行跨通道求和。
// 原理：按通道组读取对应窗口与独立权重，利用 DSP 累加九个核位置，并依次输出通道累加值。
module cnn_dw_mac #(
    parameter G = 4,
    parameter integer SHARED_WEIGHTS = 0,
    parameter NG = 6,
    parameter ACC_W = 26,
    parameter WFILE = ""
) (
    input clk,
    input rst,
    input w_we,
    input [4:0] w_lane,
    input [11:0] w_addr,
    input [31:0] w_data,
    input [G * 8 - 1:0] i_data,
    input [3:0] i_tap,
    input [7:0] i_grp,
    input i_valid,
    output i_ready,
    output [ACC_W - 1:0] o_acc,
    output [7:0] o_side,
    output o_last,
    output o_valid,
    input o_ready,
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

    // 九个U7×INT8乘积的完整和需要19位，接口宽度保持不变。
    localparam SUM_W = (ACC_W < 19) ? ACC_W : 19;
    localparam WD = NG * 9;
    localparam WAW = $clog2(WD);
    wire stall;
    assign i_ready = !stall && (!SHARED_WEIGHTS || dw_read_ready);
    wire fire = i_valid && i_ready;
    wire [G * 8 - 1:0] wrow;
    assign dw_write_valid = SHARED_WEIGHTS && w_we;
    assign dw_write_address = w_addr[7:0];
    assign dw_write_half = w_lane[0];
    assign dw_write_data = w_data[7:0];
    assign dw_read_valid = SHARED_WEIGHTS && i_valid && !stall && !rst;
    assign dw_read_address = i_grp*9+i_tap;
    generate if(SHARED_WEIGHTS)begin : g_shared_weights
        // 公共读口的结果在一拍后对应本层样本；乘法级停顿时缓存此结果。
        reg [15:0] held_weights;
        always @(posedge clk)if(dw_response_valid)held_weights<=dw_response_data;
        assign wrow=dw_response_valid ? dw_response_data : held_weights;
`ifndef SYNTHESIS
        initial if(G!=2 || NG!=16)$fatal(1,"Shared DW weight geometry unsupported");
`endif
    end else begin : g_private_weights
    cnn_weight_pair #(
        .DEPTH(WD),
        .AW(WAW)
    ) u_w (
        .clk(clk),
        .we(w_we),
        .half(w_lane [0]),
        .wa(w_addr [WAW - 1:0]),
        .din(w_data [7:0]),
        .re(fire),
        .ra(WAW ' (i_grp * 9 + i_tap)),
        .rdata(wrow)
    );

    end endgenerate

    reg [G * 8 - 1:0] x1;
    reg [3:0] t1;
    reg [3:0] t2;
    reg [7:0] g1;
    reg [7:0] g2;
    reg v1;
    reg v2;
    wire signed [23:0] prod [0:G - 1];
    reg signed [SUM_W - 1:0] acc [0:G - 1];
    reg [G * 8 - 1:0] ctr;
    integer j;
    // 输出缓存
    reg signed [SUM_W - 1:0] obank [0:G - 1];
    reg [7:0] oside [0:G - 1];
    reg [7:0] ocnt;
    reg [7:0] ogrp;
    reg obusy;
    wire done_g = v2 && (t2 == 8) && ! stall;
    assign stall = v2 && (t2 == 8) && obusy && ! (o_ready && ocnt == G - 1);
    genvar dj;

    generate
        for (dj = 0; dj < G; dj = dj + 1) begin : g_dj
            cnn_dsp #(
                .LATENCY(1),
                .SIGNED_INPUT(1)
            ) u_dsp (
                .clk(clk),
                .ce(! stall),
                .rst(rst),
                .a({ 1'b0, x1 [dj * 8+:7] }),
                .b(wrow [dj * 8+:8]),
                .c(24'sd0),
                .o(prod [dj]),
                .first(1'b0)
            );

        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            v1 <= 1'b0;
            v2 <= 1'b0;
        end else if (! stall) begin
            v1 <= fire;
            x1 <= i_data;
            t1 <= i_tap;
            g1 <= i_grp;
            v2 <= v1;
            t2 <= t1;
            g2 <= g1;
            if (v1 && t1 == 4) ctr <= x1;
        end
    end

    always @(posedge clk) begin
        if (v2 && ! stall) for (j = 0; j < G; j = j + 1) acc [j] <= ((t2 == 0) ? 0:acc [j]) + prod [j];
    end
    assign o_valid = obusy;
    assign o_acc = $signed(obank [ocnt]);
    assign o_side = oside [ocnt];
    assign o_last = (ocnt == G - 1) && (ogrp == NG - 1);

    always @(posedge clk) begin
        if (rst) begin
            obusy <= 1'b0;
            ocnt <= 0;
        end else begin
            if (obusy && o_ready) begin
                if (ocnt == G - 1) begin
                    obusy <= 1'b0;
                    ocnt <= 0;
                end else ocnt <= ocnt + 1'b1;
            end
            if (done_g) begin
                for (j = 0; j < G; j = j + 1) begin
                    obank [j] <= acc [j] + prod [j];
                    oside [j] <= ctr [j * 8+:8];
                end
                ogrp <= g2;
                obusy <= 1'b1;
                ocnt <= 0;
            end
        end
    end
endmodule

// 用途：对残差块的1×1 PW逐个输出通道计算，保持原权重加载和流接口。
// 原理：缓存一像素的U7输入及旁路，重复读取输入向量；每通道连续累加，单结果寄存器接收回压。
module cnn_pw_mac #(
    parameter integer CH = 32,
    parameter integer ACC_W = 24
) (
    input clk,
    input rst,
    input w_we,
    input [4:0] w_lane,
    input [11:0] w_addr,
    input [31:0] w_data,
    input [15:0] i_data,
    input [15:0] i_side,
    input i_valid,
    output i_ready,
    output [ACC_W - 1:0] o_acc,
    output [7:0] o_side,
    output o_last,
    output o_valid,
    input o_ready
);
    localparam integer NI = CH / 2;
    localparam integer IW = $clog2(NI);
    localparam integer CW = $clog2(CH);
    localparam integer WD = NI * CH;
    localparam integer WAW = $clog2(WD);
    localparam integer NEED_W = 1 + $clog2(CH * 127 * 128);
    localparam integer SUM_W = (NEED_W < ACC_W) ? NEED_W : ACC_W;

    // 固定顺序移入，便于映射SRL；不复位存储体，完整收齐后才允许读取。
    reg [27:0] samples [0:NI - 1];
    reg [IW - 1:0] write_index;
    reg cached;
    wire capture = i_valid && i_ready;
    wire [27:0] packed_input = {i_side[14:8], i_side[6:0], i_data[14:8], i_data[6:0]};
    integer sample_index;
    always @(posedge clk) if (capture) begin
        samples[0] <= packed_input;
        for (sample_index = 1; sample_index < NI; sample_index = sample_index + 1)
            samples[sample_index] <= samples[sample_index - 1];
    end
    assign i_ready = !cached && !rst;

    reg [IW - 1:0] read_input;
    reg [CW - 1:0] read_channel;
    reg read_done;
    reg [27:0] sample_q;
    reg v1;
    reg v2;
    reg first1;
    reg first2;
    reg last1;
    reg last2;
    reg [IW - 1:0] input1;
    reg [CW - 1:0] channel1;
    reg [CW - 1:0] channel2;
    reg [6:0] side_hold;
    reg signed [SUM_W - 1:0] accumulator;
    reg signed [SUM_W - 1:0] result_acc;
    reg [6:0] result_side;
    reg result_last;
    reg result_valid;
    wire stall = v2 && last2 && result_valid && !o_ready;
    wire issue = cached && !read_done && !stall;
    wire [WAW - 1:0] read_address = WAW'(read_input * CH + read_channel);
    wire [15:0] weights;
    wire signed [23:0] product [0:1];
    wire signed [SUM_W - 1:0] pair_sum = product[0] + product[1];
    wire signed [SUM_W - 1:0] next_sum =
        (first2 ? {SUM_W{1'b0}} : accumulator) + pair_sum;
    wire release_pixel = result_valid && o_ready && result_last;

    // 地址仍为输入通道对×CH＋输出通道，与旧PW的加载映射逐字节一致。
    cnn_weight_pair #(
        .DEPTH(WD),
        .AW(WAW)
    ) u_w (
        .clk(clk),
        .we(w_we),
        .half(w_lane[0]),
        .re(issue),
        .wa(w_addr[WAW - 1:0]),
        .ra(read_address),
        .din(w_data[7:0]),
        .rdata(weights)
    );
    genvar lane;
    generate
        for (lane = 0; lane < 2; lane = lane + 1) begin : g_product
            cnn_dsp #(
                .LATENCY(1),
                .SIGNED_INPUT(1)
            ) u_dsp (
                .clk(clk),
                .ce(!stall),
                .rst(rst),
                .a({1'b0, sample_q[lane * 7+:7]}),
                .b(weights[lane * 8+:8]),
                .c(24'sd0),
                .o(product[lane]),
                .first(1'b0)
            );
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            cached <= 0;
            write_index <= 0;
            read_input <= 0;
            read_channel <= 0;
            read_done <= 0;
            v1 <= 0;
            v2 <= 0;
            result_valid <= 0;
        end else begin
            if (capture) begin
                write_index <= write_index + 1'b1;
                if (write_index == NI - 1) begin
                    cached <= 1;
                    read_input <= 0;
                    read_channel <= 0;
                    read_done <= 0;
                end
            end
            if (release_pixel) cached <= 0;
            if (result_valid && o_ready) result_valid <= 0;
            if (!stall) begin
                v1 <= issue;
                v2 <= v1;
                if (issue) begin
                    sample_q <= samples[NI - 1 - read_input];
                    first1 <= read_input == 0;
                    last1 <= read_input == NI - 1;
                    input1 <= read_input;
                    channel1 <= read_channel;
                    if (read_input == NI - 1) begin
                        read_input <= 0;
                        if (read_channel == CH - 1) read_done <= 1;
                        else read_channel <= read_channel + 1'b1;
                    end else read_input <= read_input + 1'b1;
                end
                first2 <= first1;
                last2 <= last1;
                channel2 <= channel1;
                // 重放输入时顺便抽取同编号旁路通道，不增加第二个缓存读口。
                if (v1 && input1 == (channel1 >> 1))
                    side_hold <= channel1[0] ? sample_q[27:21] : sample_q[20:14];
                if (v2) begin
                    accumulator <= next_sum;
                    if (last2) begin
                        result_acc <= next_sum;
                        result_side <= side_hold;
                        result_last <= channel2 == CH - 1;
                        result_valid <= 1;
                    end
                end
            end
        end
    end
    assign o_acc = $signed(result_acc);
    assign o_side = {1'b0, result_side};
    assign o_last = result_last;
    assign o_valid = result_valid;
`ifndef SYNTHESIS
    initial if (CH < 4 || (CH & (CH - 1)) != 0 || ACC_W < 19)
        $fatal(1, "cnn_pw_mac requires power-of-two CH >= 4 and valid accumulator width");
    always @(posedge clk) if (!rst && capture &&
        (i_data[7] || i_data[15] || i_side[7] || i_side[15]))
        $fatal(1, "cnn_pw_mac requires the existing U7 activation/shortcut contract");
`endif
endmodule

// 用途：缓存一个卷积窗口，按输出通道组连续完成输入通道及核位置的乘加。
// 原理：原权重地址保持不变；重读U7窗口换取单组累加器，末次读窗后即允许接收下一窗。
module cnn_output_mac #(
    parameter integer G = 2,
    parameter integer NI = 36,
    parameter integer COUT = 16,
    parameter integer PE = 4,
    parameter integer ACC_W = 24
) (
    input clk,
    input rst,
    input w_we,
    input [4:0] w_lane,
    input [11:0] w_addr,
    input [31:0] w_data,
    input [G * 8 - 1:0] i_data,
    input i_valid,
    output i_ready,
    output [ACC_W - 1:0] o_acc,
    output o_last,
    output o_valid,
    input o_ready
);
    localparam integer NF = COUT / PE;
    localparam integer IW = (NI > 1) ? $clog2(NI) : 1;
    localparam integer FW = (NF > 1) ? $clog2(NF) : 1;
    localparam integer PW = (PE > 1) ? $clog2(PE) : 1;
    localparam integer WD = NI * NF;
    localparam integer WAW = (WD > 1) ? $clog2(WD) : 1;
    localparam integer NEED_W = 1 + $clog2(NI * G * 127 * 128);
    localparam integer SUM_W = (NEED_W < ACC_W) ? NEED_W : ACC_W;
    reg [G * 7 - 1:0] samples [0:NI - 1];
    wire [G * 7 - 1:0] packed_input;
    genvar g;
    generate for (g = 0; g < G; g = g + 1) begin : g_input
        assign packed_input[g * 7+:7] = i_data[g * 8+:7];
    end endgenerate
    reg [IW - 1:0] write_index;
    reg cached;
    wire capture = i_valid && i_ready;
    assign i_ready = !cached && !rst;
    integer k;
    always @(posedge clk) if (capture) begin
        samples[0] <= packed_input;
        for (k = 1; k < NI; k = k + 1) samples[k] <= samples[k - 1];
    end
    reg [IW - 1:0] read_input;
    reg [FW - 1:0] read_group;
    reg [G * 7 - 1:0] sample_q;
    reg v1;
    reg v2;
    reg first1;
    reg first2;
    reg last1;
    reg last2;
    reg final1;
    reg final2;
    reg [PE * SUM_W - 1:0] accumulator;
    reg [PE * SUM_W - 1:0] result_acc;
    reg result_valid;
    reg result_last;
    reg [PW - 1:0] output_index;
    wire pop = result_valid && o_ready && output_index == PE - 1;
    wire stall = v2 && last2 && result_valid && !pop;
    wire issue = cached && !stall;
    wire [WAW - 1:0] read_address = WAW'(read_input * NF + read_group);
    wire [PE * G * 8 - 1:0] weights;
    wire signed [23:0] product [0:PE * G - 1];
    reg [PE * SUM_W - 1:0] next_acc;
    reg signed [SUM_W - 1:0] partial [0:PE - 1];
    integer p;
    integer j;
    cnn_weight_rows #(
        .LOAD_GROUPS(NF),
        .LANES(G * PE),
        .DEPTH(WD),
        .AW(WAW)
    ) u_w (
        .clk(clk),
        .we(w_we),
        .lane(w_lane),
        .wa(w_addr[WAW - 1:0]),
        .din(w_data[7:0]),
        .re(issue),
        .ra(read_address),
        .rdata(weights)
    );
    genvar dp;
    genvar dj;
    generate for (dp = 0; dp < PE; dp = dp + 1) begin : g_output
        for (dj = 0; dj < G; dj = dj + 1) begin : g_product
            cnn_dsp #(
                .LATENCY(1),
                .SIGNED_INPUT(1)
            ) u_dsp (
                .clk(clk),
                .ce(!stall),
                .rst(rst),
                .a({1'b0, sample_q[dj * 7+:7]}),
                .b(weights[(dp * G + dj) * 8+:8]),
                .c(24'sd0),
                .o(product[dp * G + dj]),
                .first(1'b0)
            );
        end
    end endgenerate
    always @(*) begin
        for (p = 0; p < PE; p = p + 1) begin
            partial[p] = 0;
            for (j = 0; j < G; j = j + 1)
                partial[p] = partial[p] + product[p * G + j];
            next_acc[p * SUM_W+:SUM_W] =
                (first2 ? {SUM_W{1'b0}} : accumulator[p * SUM_W+:SUM_W]) + partial[p];
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            cached <= 0;
            write_index <= 0;
            read_input <= 0;
            read_group <= 0;
            v1 <= 0;
            v2 <= 0;
            result_valid <= 0;
            output_index <= 0;
        end else begin
            if (capture) begin
                if (write_index == NI - 1) begin
                    write_index <= 0;
                    cached <= 1;
                    read_input <= 0;
                    read_group <= 0;
                end else write_index <= write_index + 1'b1;
            end
            if (result_valid && o_ready) begin
                if (output_index == PE - 1) begin
                    output_index <= 0;
                    result_valid <= 0;
                end else output_index <= output_index + 1'b1;
            end
            if (!stall) begin
                v1 <= issue;
                v2 <= v1;
                first2 <= first1;
                last2 <= last1;
                final2 <= final1;
                if (issue) begin
                    sample_q <= samples[NI - 1 - read_input];
                    first1 <= read_input == 0;
                    last1 <= read_input == NI - 1;
                    final1 <= read_group == NF - 1;
                    if (read_input == NI - 1) begin
                        read_input <= 0;
                        if (read_group == NF - 1) cached <= 0;
                        else read_group <= read_group + 1'b1;
                    end else read_input <= read_input + 1'b1;
                end
                if (v2) begin
                    accumulator <= next_acc;
                    if (last2) begin
                        result_acc <= next_acc;
                        result_last <= final2;
                        result_valid <= 1;
                        output_index <= 0;
                    end
                end
            end
        end
    end
    assign o_acc = $signed(result_acc[output_index * SUM_W+:SUM_W]);
    assign o_last = result_last && output_index == PE - 1;
    assign o_valid = result_valid;
`ifndef SYNTHESIS
    initial if (NF < 2 || COUT % PE || NI < 2 || PE < 2)
        $fatal(1, "Invalid output-major MAC grouping");
    always @(posedge clk) if (!rst && capture)
        for (integer c = 0; c < G; c = c + 1)
            if (i_data[c * 8 + 7]) $fatal(1, "Requires U7 activation");
`endif
endmodule
