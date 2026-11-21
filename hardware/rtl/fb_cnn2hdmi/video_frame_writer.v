`timescale 1ns/1ps
// 用途：将 CNN 风格结果打包后写入 DDR，不再重复保存原画。
// 原理：每 16 个 RGB888 像素形成三拍 AXI128，预留 FIFO 空间后整组提交；
//       校验像素数量、首尾标志与 B 响应，只发布完整且无错误的结果帧。
module video_frame_writer #(
    parameter IMG_W = 256,
    parameter IMG_H = 144,
    parameter AXI_WIDTH = 128,
    parameter ADDR_WIDTH = 32,
    parameter FIFO_DEPTH = 512,
    parameter BURST_BEATS = 64
)(
    input wire wr_clk,
    input wire wr_rst_n,
    input wire i_sof,
    input wire i_valid,
    input wire i_abort,
    input wire [23:0] i_pixel,
    input wire i_pause,
    input wire axi_clk,
    input wire axi_rst_n,
    input wire [ADDR_WIDTH-1:0] frame_base,
    output wire frame_done,
    output reg write_error,
    output reg frame_drop,
    output wire [ADDR_WIDTH-1:0] awaddr,
    output wire [7:0] awlen,
    output wire awvalid,
    input wire awready,
    output wire [AXI_WIDTH-1:0] wdata,
    output wire [AXI_WIDTH/8-1:0] wstrb,
    output wire wlast,
    output wire wvalid,
    input wire wready,
    input wire bvalid,
    input wire [1:0] bresp,
    output wire bready
);
    localparam BYTES = AXI_WIDTH/8;
    localparam PIXELS = IMG_W*IMG_H;
    localparam WORDS = PIXELS*3/BYTES;
    localparam PCW = $clog2(PIXELS+1);
    localparam WCW = $clog2(WORDS+1);
    reg [3*AXI_WIDTH-1:0] pack;
    reg [$clog2(BYTES)-1:0] group_count;
    reg [PCW-1:0] pixel_count;
    reg [1:0] emit;
    reg half_word;
    reg group_reserved;
    reg capture;
    reg first_group;
    reg last_group;
    reg fault_toggle;
    wire fifo_full;
    wire fifo_empty;
    wire [$clog2(FIFO_DEPTH):0] wr_used;
    wire [$clog2(FIFO_DEPTH):0] rd_used;
    // 130 位令牌拆成两段 65 位，512 深度映射四块 RAM，利用率约 81.25%。
    // 一组共六拍写入，短于既有 gap9；DDR 字节排列和首尾标志完全不变。
    // 先锁存整组六个半字的空间许可，切断占用量到 FIFO 写指针的组合反馈。
    // 许可保持到整组提交完成；额外一拍仍小于相邻 gap9 像素的间隔。
    wire push = emit != 0 && group_reserved && !fifo_full;
    wire [AXI_WIDTH+1:0] token = {
        first_group && emit == 3,
        last_group && emit == 1,
        pack[3*AXI_WIDTH-1 -: AXI_WIDTH]
    };
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            pack <= 0;
            group_count <= 0;
            pixel_count <= 0;
            emit <= 0;
            half_word <= 0;
            group_reserved <= 0;
            capture <= 0;
            first_group <= 0;
            last_group <= 0;
            fault_toggle <= 0;
        end else begin
            if (emit == 3 && !half_word && !group_reserved && wr_used <= FIFO_DEPTH-6)
                group_reserved <= 1;
            if (push) begin
                half_word <= !half_word;
                if (half_word) begin
                    pack <= pack << AXI_WIDTH;
                    emit <= emit - 1'b1;
                    if (emit == 1) begin
                        first_group <= 0;
                        group_reserved <= 0;
                    end
                end
            end
            if (i_sof) begin
                if (capture || emit != 0) begin
                    capture <= 0;
                    fault_toggle <= ~fault_toggle;
                end else if (!i_pause && !i_abort) begin
                    capture <= 1;
                    group_count <= 0;
                    pixel_count <= 0;
                    first_group <= 1;
                    last_group <= 0;
                end
            end else if (capture && (i_abort || (i_valid && emit != 0 && !(push && emit == 1 && half_word)))) begin
                capture <= 0;
                fault_toggle <= ~fault_toggle;
            end else if (capture && i_valid) begin
                pack <= {pack[3*AXI_WIDTH-25:0],i_pixel};
                pixel_count <= pixel_count + 1'b1;
                if (group_count == BYTES-1) begin
                    group_count <= 0;
                    emit <= 3;
                    last_group <= pixel_count == PIXELS-1;
                end else group_count <= group_count + 1'b1;
                if (pixel_count == PIXELS-1) capture <= 0;
            end
        end
    end
    wire [(AXI_WIDTH+2)/2-1:0] fifo_data;
    wire fifo_pop;
    cnn_pixel_async_fifo #(
        .WIDTH((AXI_WIDTH+2)/2),
        .DEPTH(FIFO_DEPTH)
    ) words_fifo (
        .wr_clk(wr_clk),
        .wr_rst_n(wr_rst_n),
        .wr_en(push),
        .wr_data(half_word ? token[(AXI_WIDTH+2)/2-1:0] : token[AXI_WIDTH+1 -: (AXI_WIDTH+2)/2]),
        .full(fifo_full),
        .wr_usedw(wr_used),
        .rd_clk(axi_clk),
        .rd_rst_n(axi_rst_n),
        .rd_en(fifo_pop),
        .rd_data(fifo_data),
        .empty(fifo_empty),
        .rd_usedw(rd_used)
    );
    (* async_reg="true" *) reg [2:0] fault_sync;
    wire fault_event = fault_sync[2] != fault_sync[1];
    always @(posedge axi_clk or negedge axi_rst_n)
        if (!axi_rst_n) fault_sync <= 0;
        else fault_sync <= {fault_sync[1:0],fault_toggle};
    reg pending;
    reg held_valid;
    reg read_half;
    reg [(AXI_WIDTH+2)/2-1:0] first_half;
    reg [AXI_WIDTH+1:0] word;
    wire consume = wvalid && wready;
    assign fifo_pop = !fifo_empty && !held_valid && !pending;
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            pending <= 0;
            held_valid <= 0;
            read_half <= 0;
        end else begin
            pending <= fifo_pop;
            if (pending) begin
                read_half <= !read_half;
                if (read_half) begin
                    word <= {first_half,fifo_data};
                    held_valid <= 1;
                end else first_half <= fifo_data;
            end else if (consume) held_valid <= 0;
        end
    end
    localparam SEEK=0, PREPARE=1, ADDRESS=2, DATA=3, RESPONSE=4;
    reg [2:0] state;
    reg [ADDR_WIDTH-1:0] address;
    reg [WCW-1:0] sent;
    reg bad;
    reg started;
    reg [1:0] group_left;
    reg [1:0] burst_size;
    reg [1:0] beats_left;
    reg eof_burst;
    integer page_words;
    integer candidate;
    always @* begin
        page_words = (4096 - {20'd0,address[11:0]}) / BYTES;
        candidate = group_left;
        if (candidate > page_words) candidate = page_words;
    end
    assign frame_done = bvalid && bready && eof_burst && !bad && !fault_event && bresp == 0;
    assign awaddr = address;
    assign awlen = burst_size - 1'b1;
    assign awvalid = state == ADDRESS;
    assign wdata = word[AXI_WIDTH-1:0];
    assign wstrb = {BYTES{1'b1}};
    assign wvalid = state == DATA && held_valid;
    assign wlast = beats_left == 1;
    assign bready = state == RESPONSE;
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            state <= SEEK;
            address <= 0;
            sent <= 0;
            bad <= 0;
            started <= 0;
            group_left <= 0;
            burst_size <= 0;
            beats_left <= 0;
            eof_burst <= 0;
            write_error <= 0;
            frame_drop <= 0;
        end else begin
            if (fault_event) begin bad <= 1; frame_drop <= 1; end
            case (state)
                SEEK: if (held_valid && rd_used+2 >= 6) begin
                    group_left <= 3;
                    eof_burst <= 0;
                    if (word[AXI_WIDTH+1]) begin
                        address <= frame_base;
                        sent <= 0;
                        bad <= 0;
                        started <= 1;
                    end else if (!started) bad <= 1;
                    state <= PREPARE;
                end
                PREPARE: begin
                    burst_size <= candidate;
                    beats_left <= candidate;
                    eof_burst <= 0;
                    state <= ADDRESS;
                end
                ADDRESS: if (awready) state <= DATA;
                DATA: if (consume) begin
                    if (word[AXI_WIDTH+1] != (sent == 0) || word[AXI_WIDTH] != (sent == WORDS-1)) begin
                        bad <= 1;
                        frame_drop <= 1;
                    end
                    address <= address + BYTES;
                    sent <= sent + 1'b1;
                    group_left <= group_left - 1'b1;
                    beats_left <= beats_left - 1'b1;
                    if (beats_left == 1) begin
                        eof_burst <= word[AXI_WIDTH] && sent == WORDS-1;
                        state <= RESPONSE;
                    end
                end
                RESPONSE: if (bvalid) begin
                    if (bresp != 0) begin bad <= 1; write_error <= 1; frame_drop <= 1; end
                    if (eof_burst) started <= 0;
                    state <= group_left == 0 ? SEEK : PREPARE;
                end
            endcase
        end
    end
endmodule
