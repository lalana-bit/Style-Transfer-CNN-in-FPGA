// 卷积窗口生成：复制边缘填充，并支持解码阶段的上采样取数。
`timescale 1ns/1ps

// 用途：为标准卷积生成按通道分组的 3×3 输入窗口，同时支持降采样和解码上采样。
// 原理：环形行 RAM 保存所需源行，按输出坐标、核位置和通道组取数；越界复制边缘，上采样时映射到最近邻源坐标。
module cnn_conv_window #(
    parameter G = 4,
    parameter NG = 6,
    parameter W = 160,
    parameter H = 120,
    parameter STRIDE = 1,
    parameter UP = 0,
    // 环形行数；UP=1 时 2 行即可（每个输出行最多用到 2 个输入行）
    parameter NR = 3
) (
    input clk,
    input rst,
    input [G * 8 - 1:0] i_data,
    input i_valid,
    output i_ready,
    output [G * 8 - 1:0] o_data,
    output [3:0] o_tap,
    output [7:0] o_grp,
    output o_valid,
    input o_ready
);

    localparam WO = UP ? 2 * W:(W + STRIDE - 1) / STRIDE;
    localparam HO = UP ? 2 * H:(H + STRIDE - 1) / STRIDE;
    localparam ROWW = W * NG;
    localparam DEPTH = NR * ROWW;
    localparam AW = $clog2(DEPTH);
    // ---------------- 读侧状态 ----------------
    localparam SXW = $clog2(2 * W + 2) + 1;
    localparam SYW = $clog2(2 * H + 2) + 1;
    localparam GW = (NG > 1) ? $clog2(NG):1;
    reg signed [SYW - 1:0] rd_oy;
    reg signed [SXW - 1:0] rd_ox;
    reg [GW - 1:0] rd_g;
    reg [1:0] rd_ky;
    reg [1:0] rd_kx;
    reg rd_done;
    reg signed [SYW - 1:0] rbase;
    // ky=0 对应的输入行（UP 时为 (oy-1)>>1）
    reg [$clog2(NR)-1:0] rbase_slot;
    // rbase mod NR（rbase=-1 时为 NR-1）
    reg signed [SXW - 1:0] cbase;
    // 普通：ox*S-1；UP：ox-1（放大域列）
    // ---------------- 写侧状态 ----------------
    reg [$clog2(H + 1) - 1:0] wr_row;
    reg [$clog2(W) - 1:0] wr_col;
    reg [GW - 1:0] wr_grp;
    reg [AW - 1:0] wr_addr;
    wire wr_done = (wr_row == H);
    // 写放行：wr_row 覆盖 wr_row-NR 所在槽位，需该行已不再被读侧使用
    wire signed [17:0] r_old = $signed({ 2'b0, wr_row }) - NR;
    wire signed [17:0] last_oy = UP ? (2 * r_old + 2):(STRIDE == 2 ? ((r_old + 1) >>> 1):(r_old + 1));
    wire signed [17:0] rd_cmin = UP ? ((rd_ox - 1) >>> 1):(rd_ox * STRIDE - 1);
    wire wr_ok = (wr_row < NR) || rd_done || (last_oy < rd_oy) || ((last_oy == rd_oy) && ($signed({ 2'b0, wr_col }) + 2 < rd_cmin));
    assign i_ready = ! wr_done && wr_ok;
    wire wr_fire = i_valid && i_ready;
    // 读放行：当前输出像素所需的最右下输入像素已写完
    wire signed [17:0] rmax_raw = UP ? ((rd_oy + 1) >>> 1):(rd_oy * STRIDE + 1);
    wire signed [17:0] cmax_raw = UP ? ((rd_ox + 1) >>> 1):(rd_ox * STRIDE + 1);
    wire signed [17:0] rmax = (rmax_raw > H - 1) ? H - 1:rmax_raw;
    wire signed [17:0] cmax = (cmax_raw > W - 1) ? W - 1:cmax_raw;
    wire avail = wr_done || ($signed({ 2'b0, wr_row }) > rmax) || (($signed({ 2'b0, wr_row }) == rmax) && ($signed({ 2'b0, wr_col }) > cmax));
    // 当前抽头的输入坐标
    wire [1:0] roff = UP ? (rd_oy [0] ? (rd_ky == 2 ? 2'd1:2'd0):(rd_ky == 0 ? 2'd0:2'd1)):rd_ky;
    wire signed [17:0] raw_iy = $signed(rbase) + $signed({ 1'b0, roff });
    wire signed [17:0] ux = $signed(cbase) + $signed({ 1'b0, rd_kx });
    wire signed [17:0] raw_ix = UP ? (ux >>> 1):ux;
    wire signed [17:0] iy = (raw_iy < 0) ? 0:((raw_iy >= H) ? H - 1:raw_iy);
    wire signed [17:0] ix = (raw_ix < 0) ? 0:((raw_ix >= W) ? W - 1:raw_ix);
    wire pad = 1'b0;
    wire [$clog2(NR):0] slot_sum = rbase_slot + roff;
    wire [$clog2(NR)-1:0] slot = (raw_iy < 0) ? 0:((raw_iy >= H) ? ((H - 1) % NR):((slot_sum >= NR) ? slot_sum - NR:slot_sum [$clog2(NR)-1:0]));
    wire [AW - 1:0] rd_addr = slot * ROWW + ix [15:0] * NG + rd_g;
    // 输出 FIFO 与读流水
    wire [3:0] ofc;
    reg p_valid;
    reg p_pad;
    reg [3:0] p_tap;
    reg [7:0] p_grp;
    wire can_issue = ! rd_done && avail && (ofc + p_valid < 3);
    wire [G * 8 - 1:0] rdata;
    // 当前网络的非负激活仅使用7位；逐字节去掉恒零高位后连续存储。
    wire [G * 7 - 1:0] packed_write;
    wire [G * 7 - 1:0] packed_read;
    genvar pack_lane;
    generate for (pack_lane=0;pack_lane<G;pack_lane=pack_lane+1) begin : pack_7bit
        assign packed_write[pack_lane*7+:7] = i_data[pack_lane*8+:7];
        assign rdata[pack_lane*8+:8] = {1'b0,packed_read[pack_lane*7+:7]};
    end endgenerate
    cnn_sdp_ram #(
        .W(G * 7),
        .D(DEPTH),
        .AW(AW)
    ) u_lb (
        .clk(clk),
        .we(wr_fire),
        .waddr(wr_addr),
        .wdata(packed_write),
        .re(can_issue),
        .raddr(rd_addr),
        .rdata(packed_read)
    );

    cnn_stream_fifo #(
        .W(G * 8 + 12),
        .AW(2)
    ) u_of (
        .clk(clk),
        .rst(rst),
        .i_data({ p_grp, p_tap, p_pad ? { (G * 8) { 1'b0 } }:rdata }),
        .i_valid(p_valid),
        .i_ready(),
        .o_data({ o_grp, o_tap, o_data }),
        .o_valid(o_valid),
        .o_ready(o_ready),
        .count(ofc [2:0])
    );

    assign ofc [3] = 1'b0;
    // 写侧

    always @(posedge clk) begin
        if (rst || (wr_done && rd_done)) begin
            wr_row <= 0;
            wr_col <= 0;
            wr_grp <= 0;
            wr_addr <= 0;
        end else if (wr_fire) begin
            wr_addr <= (wr_addr == DEPTH - 1) ? 0:wr_addr + 1'b1;
            if (wr_grp == NG - 1) begin
                wr_grp <= 0;
                if (wr_col == W - 1) begin
                    wr_col <= 0;
                    wr_row <= wr_row + 1'b1;
                end else wr_col <= wr_col + 1'b1;
            end else wr_grp <= wr_grp + 1'b1;
        end
    end
    // 读侧

    always @(posedge clk) begin
        p_valid <= can_issue;
        p_pad <= pad;
        p_tap <= rd_ky * 3 + rd_kx;
        p_grp <= rd_g;
        if (rst || (wr_done && rd_done)) begin
            rd_oy <= 0;
            rd_ox <= 0;
            rd_g <= 0;
            rd_ky <= 0;
            rd_kx <= 0;
            rd_done <= 0;
            rbase <= - 18'sd1;
            rbase_slot <= NR - 1;
            cbase <= - 18'sd1;
            p_valid <= 1'b0;
        end else if (can_issue) begin
            if (rd_kx != 2) rd_kx <= rd_kx + 1'b1;
            else begin
                rd_kx <= 0;
                if (rd_ky != 2) rd_ky <= rd_ky + 1'b1;
                else begin
                    rd_ky <= 0;
                    if (rd_g != NG - 1) rd_g <= rd_g + 1'b1;
                    else begin
                        rd_g <= 0;
                        // 下一个输出像素
                        if (rd_ox != WO - 1) begin
                            rd_ox <= rd_ox + 1;
                            cbase <= cbase + (UP ? 1:STRIDE);
                        end else begin
                            rd_ox <= 0;
                            cbase <= - 18'sd1;
                            if (rd_oy == HO - 1) rd_done <= 1'b1;
                            else begin
                                rd_oy <= rd_oy + 1;
                                // 更新 ky=0 行号及其槽位
                                if (UP) begin
                                    // rbase = (oy-1)>>1：当前 oy 为偶数时进入下一行 +1
                                    if (! rd_oy [0]) begin
                                        rbase <= rbase + 1;
                                        rbase_slot <= (rbase_slot == NR - 1) ? 2'd0:rbase_slot + 1'b1;
                                    end
                                end else begin
                                    rbase <= rbase + STRIDE;
                                    rbase_slot <= (rbase_slot + STRIDE >= NR) ? rbase_slot + STRIDE - NR:rbase_slot + STRIDE;
                                end
                            end
                        end
                    end
                end
            end
        end
    end
endmodule

// 用途：为深度卷积生成带核位置和通道组标签的 3×3 数据流。
// 原理：两行 RAM 配合待提交列缓存，避免新数据覆盖仍在使用的窗口；按扫描顺序取数，边界直接复制最近有效像素。
module cnn_dw_window #(
    parameter G = 4,
    parameter NG = 6,
    parameter W = 160,
    parameter H = 120,
    // 待提交列数（2 的幂，>= 4）
    parameter P = 4
) (
    input clk,
    input rst,
    input [G * 8 - 1:0] i_data,
    input i_valid,
    output i_ready,
    output [G * 8 - 1:0] o_data,
    output [3:0] o_tap,
    output [7:0] o_grp,
    output o_valid,
    input o_ready
);

    localparam ROWW = W * NG;
    localparam DEPTH = 2 * ROWW;
    localparam AW = $clog2(DEPTH);
    localparam PD = P * NG;
    localparam PDW = $clog2(PD);
    // 按实际例化的图像尺寸限制计数器位宽；有符号坐标
    // 还需表示 -1 和一像素复制边界，避免通用宽计数器
    // 在 RAM FIFO 读使能路径中形成较长的比较与进位链。
    localparam XW = (W > 1) ? $clog2(W):1;
    localparam YW = (H > 1) ? $clog2(H + 1):1;
    localparam SXW = $clog2(W + 1) + 1;
    localparam SYW = $clog2(H + 1) + 1;
    localparam GW = (NG > 1) ? $clog2(NG):1;
    localparam PNW = $clog2(W * NG + 1);
    // ---------------- 读侧状态 ----------------
    reg signed [SYW - 1:0] rd_oy;
    reg signed [SXW - 1:0] rd_ox;
    reg [GW - 1:0] rd_g;
    reg [1:0] rd_ky;
    reg [1:0] rd_kx;
    reg rd_done;
    // ---------------- 写侧 / 待提交缓冲 ----------------
    reg [YW - 1:0] wr_row;
    reg [XW - 1:0] wr_col;
    reg [GW - 1:0] wr_grp;
    wire wr_done = (wr_row == H);
    reg [G * 8 - 1:0] pa [0:PD - 1];
    // 待提交缓冲：提交读用的移位链（pa[0] 最新）
    reg [G * 8 - 1:0] pb [0:PD - 1];
    // 同内容，取窗读用
    reg [PNW - 1:0] pn;
    // prow 已写入缓冲的字数
    reg pact;
    // 缓冲中有未提交完的行
    reg signed [SYW - 1:0] prow;
    // 缓冲所属行（排空后保留为"最近提交行"，初值 -1）
    reg [XW:0] pwc;
    // prow 已完整写入缓冲的列数，包含 W
    reg [XW - 1:0] cm_col;
    // 下一待提交列
    reg [GW - 1:0] cm_grp;
    wire signed [17:0] rd_cmin = rd_ox - 1;
    wire signed [17:0] cmax_raw = rd_ox + 1;
    wire signed [17:0] cmax = (cmax_raw > W - 1) ? W - 1:cmax_raw;
    // 提交：该列已完整写入缓冲，且读侧已不再需要（读侧已离开 prow-1 输出行，或列 < ox-1）
    wire signed [17:0] oyb = prow - 1;
    wire rd_free = rd_done || (rd_oy > oyb) || ((rd_oy == oyb) && ($signed({ 2'b0, cm_col }) < rd_cmin));
    wire commit = pact && (cm_col < pwc) && rd_free;
    // 写侧放行：第 0 行直写 BRAM（提交占用写口时让行）；其余行写缓冲，需缓冲属于本行（或空闲）且未满
    wire row0 = (wr_row == 0);
    wire pend_ok = pact ? ((prow == $signed({ 2'b0, wr_row })) && (wr_col - cm_col < P)):1'b1;
    assign i_ready = ! wr_done && (row0 ? ! commit:pend_ok);
    wire wr_fire = i_valid && i_ready;
    // 读放行
    // 行 R（上/中行）在 BRAM 中且列 0..cmax 已就绪；依赖信号全部作为参数传入（保证组合逻辑敏感性）
    function mem_row_ok(input signed [17:0] R, input [15:0] wrow, input [15:0] wcol, input signed [17:0] prw, input pa, input [15:0] cmc, input signed [17:0] cmx);
        begin
            if (R < 0) mem_row_ok = 1'b1;
            else if (R == 0) mem_row_ok = (wrow > 0) || ($signed({ 2'b0, wcol }) > cmx);
            else mem_row_ok = (prw > R) || ((prw == R) && (! pa || $signed({ 2'b0, cmc }) > cmx));
        end
    endfunction
    wire signed [17:0] rb = rd_oy + 1;
    wire bot_ok = (rb >= H) || (pact && (prow == rb) && ($signed({ 2'b0, pwc }) > cmax));
    wire top_ok = mem_row_ok(rd_oy - 1, wr_row, wr_col, prow, pact, cm_col, cmax);
    wire mid_ok = mem_row_ok(rd_oy, wr_row, wr_col, prow, pact, cm_col, cmax);
    wire avail = top_ok && mid_ok && bot_ok;
    // 当前抽头
    wire signed [17:0] raw_iy = rd_oy + rd_ky - 1;
    wire signed [17:0] iy = (raw_iy < 0) ? 0:((raw_iy >= H) ? H - 1:raw_iy);
    wire signed [17:0] raw_ix = rd_ox + rd_kx - 1;
    wire signed [17:0] ix = (raw_ix < 0) ? 0:((raw_ix >= W) ? W - 1:raw_ix);
    wire pad = 1'b0;
    // 直接复制边缘像素填充，不设置填充模式开关
    wire from_pend = (rd_ky == 2) && (rd_oy + 1 < H);
    wire [AW - 1:0] rd_addr = iy [0] * ROWW + ix [15:0] * NG + rd_g;
    // 待提交缓冲的链上位置（只在实际使用时有效：提交时 / 取窗读下行且不补零时）
    wire [15:0] pos_t = pn - 1'b1 - (ix [15:0] * NG + rd_g);
    wire [15:0] pos_c = pn - 1'b1 - (cm_col * NG + cm_grp);
    // BRAM：写口在提交与第 0 行直写间复用
    wire [AW - 1:0] waddr = commit ? (prow [0] * ROWW + cm_col * NG + cm_grp):(wr_col * NG + wr_grp);
    wire [G * 8 - 1:0] wdata = commit ? pa [pos_c [PDW - 1:0]]:i_data;
    wire we = commit || (wr_fire && row0);
    wire [3:0] ofc;
    reg p_valid;
    reg p_pad;
    reg p_src;
    reg [3:0] p_tap;
    reg [7:0] p_grp;
    reg [G * 8 - 1:0] p_pdata;
    wire can_issue = ! rd_done && avail && (ofc + p_valid < 3);
    wire [G * 8 - 1:0] rdata;
    // 当前网络的非负激活仅使用7位；逐字节去掉恒零高位后连续存储。
    wire [G * 7 - 1:0] packed_write;
    wire [G * 7 - 1:0] packed_read;
    genvar pack_lane;
    generate for (pack_lane=0;pack_lane<G;pack_lane=pack_lane+1) begin : pack_7bit
        assign packed_write[pack_lane*7+:7] = wdata[pack_lane*8+:7];
        assign rdata[pack_lane*8+:8] = {1'b0,packed_read[pack_lane*7+:7]};
    end endgenerate
    cnn_sdp_ram #(
        .W(G * 7),
        .D(DEPTH),
        .AW(AW)
    ) u_lb (
        .clk(clk),
        .we(we),
        .waddr(waddr),
        .wdata(packed_write),
        .re(can_issue && ! from_pend),
        .raddr(rd_addr),
        .rdata(packed_read)
    );

    cnn_stream_fifo #(
        .W(G * 8 + 12),
        .AW(2)
    ) u_of (
        .clk(clk),
        .rst(rst),
        .i_data({ p_grp, p_tap, p_pad ? { (G * 8) { 1'b0 } }:(p_src ? p_pdata:rdata) }),
        .i_valid(p_valid),
        .i_ready(),
        .o_data({ o_grp, o_tap, o_data }),
        .o_valid(o_valid),
        .o_ready(o_ready),
        .count(ofc [2:0])
    );

    assign ofc [3] = 1'b0;
    wire frame_end = wr_done && rd_done && ! pact;
    // 待提交缓冲移位链（无复位，映射 SRL8）
    wire pwr = wr_fire && ! row0;
    integer k;

    always @(posedge clk) if (pwr) begin
        pa [0] <= i_data;
        pb [0] <= i_data;
        for (k = 1; k < PD; k = k + 1) begin
            pa [k] <= pa [k - 1];
            pb [k] <= pb [k - 1];
        end
    end
    // 写侧与提交

    always @(posedge clk) begin
        if (rst || frame_end) begin
            wr_row <= 0;
            wr_col <= 0;
            wr_grp <= 0;
            pn <= 0;
            pact <= 1'b0;
            prow <= - 18'sd1;
            pwc <= 0;
            cm_col <= 0;
            cm_grp <= 0;
        end else begin
            if (commit) begin
                if (cm_grp == NG - 1) begin
                    cm_grp <= 0;
                    if (cm_col == W - 1) begin
                        cm_col <= 0;
                        pact <= 1'b0;
                        // 本行提交完毕（prow 保留）
                    end else cm_col <= cm_col + 1'b1;
                end else cm_grp <= cm_grp + 1'b1;
            end
            if (wr_fire) begin
                if (! row0) begin
                    if (! pact || prow != $signed({ 2'b0, wr_row })) begin
                        // 新行进入缓冲
                        pact <= 1'b1;
                        prow <= $signed({ 2'b0, wr_row });
                        pwc <= 0;
                        pn <= 1;
                        cm_col <= 0;
                        cm_grp <= 0;
                    end else pn <= pn + 1'b1;
                    if (wr_grp == NG - 1) pwc <= wr_col + 1'b1;
                end
                if (wr_grp == NG - 1) begin
                    wr_grp <= 0;
                    if (wr_col == W - 1) begin
                        wr_col <= 0;
                        wr_row <= wr_row + 1'b1;
                    end else wr_col <= wr_col + 1'b1;
                end else wr_grp <= wr_grp + 1'b1;
            end
        end
    end
    // 读侧

    always @(posedge clk) begin
        p_valid <= can_issue;
        p_pad <= pad;
        p_src <= from_pend;
        p_pdata <= pb [pos_t [PDW - 1:0]];
        p_tap <= rd_ky * 3 + rd_kx;
        p_grp <= rd_g;
        if (rst || frame_end) begin
            rd_oy <= 0;
            rd_ox <= 0;
            rd_g <= 0;
            rd_ky <= 0;
            rd_kx <= 0;
            rd_done <= 0;
            p_valid <= 1'b0;
        end else if (can_issue) begin
            if (rd_kx != 2) rd_kx <= rd_kx + 1'b1;
            else begin
                rd_kx <= 0;
                if (rd_ky != 2) rd_ky <= rd_ky + 1'b1;
                else begin
                    rd_ky <= 0;
                    if (rd_g != NG - 1) rd_g <= rd_g + 1'b1;
                    else begin
                        rd_g <= 0;
                        if (rd_ox != W - 1) rd_ox <= rd_ox + 1;
                        else begin
                            rd_ox <= 0;
                            if (rd_oy == H - 1) rd_done <= 1'b1;
                            else rd_oy <= rd_oy + 1;
                        end
                    end
                end
            end
        end
    end
endmodule
