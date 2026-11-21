`timescale 1ns/1ps
// 用途：为 HDMI 原画/风格行缓存及 CNN 输入提供公共 DDR 读服务。
// 原理：复用一个 AXI 突发引擎和 RGB888 解包器；按整行预留 CNN FIFO 空间，
//       HDMI 有界优先；CNN 使用短突发，在完整 RGB 组边界保存进度后让出端口。
module video_ddr_read_service #(
    parameter IMG_W = 256,
    parameter IMG_H = 144,
    parameter RAW_W = 864,
    parameter RAW_H = 486,
    parameter AXI_WIDTH = 128,
    parameter ADDR_WIDTH = 32,
    parameter BURST_BEATS = 64,
    parameter CNN_FIFO_DEPTH = 1024,
    parameter XW = $clog2(RAW_W+1),
    parameter YW = $clog2(RAW_H+1),
    parameter EW = 8,
    parameter REQ_W = EW+4+YW
)(
    input wire clk,
    input wire rst_n,
    input wire request_empty,
    input wire [REQ_W-1:0] request_data,
    output wire request_pop,
    input wire frame_available,
    input wire raw_frame_available,
    input wire [ADDR_WIDTH-1:0] frame_base,
    input wire [ADDR_WIDTH-1:0] raw_frame_base,
    output wire display_start,
    output wire display_valid,
    output wire [23:0] display_pixel,
    output wire [XW-1:0] display_column,
    output wire [2:0] display_bank,
    output reg display_done,
    output reg [YW-1:0] display_row,
    output reg [EW-1:0] display_epoch,
    input wire cnn_start,
    input wire [ADDR_WIDTH-1:0] cnn_base,
    input wire [10:0] cnn_used,
    output wire cnn_valid,
    output wire [47:0] cnn_pixel,
    output reg cnn_complete,
    output reg cnn_fault,
    output reg read_error,
    output wire [ADDR_WIDTH-1:0] araddr,
    output wire [7:0] arlen,
    output wire arvalid,
    input wire arready,
    input wire [AXI_WIDTH-1:0] rdata,
    input wire rvalid,
    input wire rlast,
    input wire [1:0] rresp,
    output wire rready
);
    localparam BYTES = AXI_WIDTH/8;
    localparam WCW = $clog2(RAW_W*3/BYTES+1);
    localparam BCW = $clog2(BURST_BEATS+1);
    localparam IDLE=0, GET=1, START=2, PREPARE=3, ADDRESS=4, DATA=5, DRAIN=6;
    reg [2:0] state;
    reg [REQ_W-1:0] request;
    reg cnn_row_active;
    reg cnn_active;
    reg cnn_bad;
    reg cnn_resume;
    reg [ADDR_WIDTH-1:0] cnn_resume_address;
    reg [WCW-1:0] cnn_resume_words;
    reg [XW-1:0] cnn_resume_column;
    reg [ADDR_WIDTH-1:0] cnn_address;
    reg [YW-1:0] cnn_row;
    reg [1:0] display_streak;
    reg [ADDR_WIDTH-1:0] address;
    reg [WCW-1:0] words_left;
    reg [BCW-1:0] burst_size;
    reg [BCW-1:0] beats_left;
    reg [159:0] unpack;
    (* syn_ramstyle="registers", syn_srlstyle="srl" *) reg [127:0] word_fifo [0:7];
    reg [3:0] queued_words;
    wire [2:0] word_head = queued_words[2:0] - 1'b1;
    wire [127:0] oldest_word = word_fifo[word_head];
    reg [1:0] group_words;
    reg group_ready;
    reg [$clog2(BYTES+1)-1:0] pixels_left;
    reg [XW-1:0] column;
    reg [XW-1:0] row_width;
    reg row_bad;
    wire row_side = request[YW+2];
    wire [1:0] row_slot = request[YW+1:YW];
    wire [YW-1:0] row = request[YW-1:0];
    wire [XW-1:0] cnn_width = RAW_W;
    wire [XW-1:0] cnn_remaining = cnn_resume ? cnn_width-cnn_resume_column : cnn_width;
    wire cnn_room = cnn_used <= CNN_FIFO_DEPTH - cnn_remaining/2;
    wire choose_cnn = cnn_active && cnn_room && (request_empty || display_streak == 3);
    wire emit_pixel = pixels_left != 0;
    wire [23:0] pixel = unpack[159 -: 24];
    integer candidate;
    integer page_words;
    always @* begin
        candidate = words_left;
        if (candidate > BURST_BEATS) candidate = BURST_BEATS;
        // CNN 可在完整 RGB 组边界让出端口，不让整行长事务拖延 HDMI。
        if (cnn_row_active && candidate > 24) candidate = 24;
        if (cnn_row_active && !request_empty && group_words != 0 && candidate > 3-group_words)
            candidate = 3-group_words;
        page_words = (4096 - {20'd0,address[11:0]}) / BYTES;
        if (candidate > page_words) candidate = page_words;
    end
    assign request_pop = state == IDLE && !request_empty && !choose_cnn;
    assign display_start = state == START && !cnn_row_active && request[YW+3];
    assign display_valid = emit_pixel && !cnn_row_active;
    assign display_pixel = pixel;
    assign display_column = column;
    assign display_bank = row_side ? 3 + row_slot : row_slot;
    assign cnn_valid = emit_pixel && cnn_row_active;
    assign cnn_pixel = unpack[159 -: 48];
    assign araddr = address;
    assign arlen = burst_size - 1'b1;
    assign arvalid = state == ADDRESS;
    assign rready = state == DATA && !group_ready;

    // 两组 RGB 数据的接收、输出时序保持原样，仅改变存储组织。
    // AXI128 字存入按时间排列的 SRL 队列，最早的字由当前占用量选取。
    // 一组 16 像素通过 160 位寄存器连续输出，在跨 AXI 字处同拍拼入下一字。
    // 不改变 group_ready 或 RREADY 的控制条件，也不增加像素间隔。
    wire start_group = group_ready && pixels_left == 0;
    wire first_join = emit_pixel && (cnn_row_active ? pixels_left == 14 : pixels_left == 12);
    wire second_join = emit_pixel && (cnn_row_active ? pixels_left == 8 : pixels_left == 7);
    wire pop_word = start_group || first_join || second_join;
    wire push_word = rvalid && rready;
    integer word_index;
    always @(posedge clk) begin
        if (push_word) begin
            for (word_index = 7; word_index > 0; word_index = word_index - 1)
                word_fifo[word_index] <= word_fifo[word_index - 1];
            word_fifo[0] <= rdata;
        end
        if (emit_pixel) unpack <= cnn_row_active ? unpack << 48 : unpack << 24;
        if (start_group) unpack <= {oldest_word,32'd0};
        if (first_join) begin
            if (cnn_row_active) unpack <= {unpack[111 -: 32],oldest_word};
            else unpack <= {unpack[135 -: 8],oldest_word,24'd0};
        end
        if (second_join) begin
            if (cnn_row_active) unpack <= {unpack[111 -: 16],oldest_word,16'd0};
            else unpack <= {unpack[135 -: 16],oldest_word,16'd0};
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) queued_words <= 0;
        else if (state == START) queued_words <= 0;
        else begin
            case ({push_word,pop_word})
                2'b10: queued_words <= queued_words + 1'b1;
                2'b01: queued_words <= queued_words - 1'b1;
                default: begin end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            request <= 0;
            cnn_row_active <= 0;
            cnn_active <= 0;
            cnn_bad <= 0;
            cnn_resume <= 0;
            cnn_resume_address <= 0;
            cnn_resume_words <= 0;
            cnn_resume_column <= 0;
            cnn_address <= 0;
            cnn_row <= 0;
            display_streak <= 0;
            address <= 0;
            words_left <= 0;
            burst_size <= 0;
            beats_left <= 0;
            group_words <= 0;
            group_ready <= 0;
            pixels_left <= 0;
            column <= 0;
            row_width <= 0;
            row_bad <= 0;
            display_done <= 0;
            display_row <= 0;
            display_epoch <= 0;
            cnn_complete <= 0;
            cnn_fault <= 0;
            read_error <= 0;
        end else begin
            display_done <= 0;
            cnn_complete <= 0;
            cnn_fault <= 0;
            if (cnn_start) begin
                cnn_active <= 1;
                cnn_address <= cnn_base;
                cnn_row <= 0;
                cnn_bad <= 0;
                cnn_resume <= 0;
            end
            if (emit_pixel) begin
                pixels_left <= pixels_left - (cnn_row_active ? 2 : 1);
                column <= column + (cnn_row_active ? 2 : 1);
            end
            if (group_ready && pixels_left == 0) begin
                pixels_left <= BYTES;
                group_ready <= 0;
            end
            case (state)
                IDLE: begin
                    if (choose_cnn) begin
                        cnn_row_active <= 1;
                        display_streak <= 0;
                        state <= START;
                    end else if (request_pop) begin
                        cnn_row_active <= 0;
                        if (display_streak != 3) display_streak <= display_streak + 1'b1;
                        state <= GET;
                    end
                end
                GET: begin
                    request <= request_data;
                    state <= START;
                end
                START: begin
                    if (cnn_row_active || (row_side ? frame_available : raw_frame_available)) begin
                        address <= cnn_row_active ? cnn_address :
                            (row_side ? frame_base + row*IMG_W*3 : raw_frame_base + row*RAW_W*3);
                        words_left <= cnn_row_active ? cnn_width*3/BYTES :
                            (row_side ? IMG_W*3/BYTES : RAW_W*3/BYTES);
                        row_width <= cnn_row_active ? cnn_width : (row_side ? IMG_W : RAW_W);
                        group_words <= 0;
                        group_ready <= 0;
                        pixels_left <= 0;
                        column <= 0;
                        if (cnn_row_active && cnn_resume) begin
                            address <= cnn_resume_address;
                            words_left <= cnn_resume_words;
                            column <= cnn_resume_column;
                            cnn_resume <= 0;
                        end
                        row_bad <= 0;
                        state <= PREPARE;
                    end else state <= IDLE;
                end
                PREPARE: begin
                    burst_size <= candidate;
                    beats_left <= candidate;
                    state <= ADDRESS;
                end
                ADDRESS: if (arready) state <= DATA;
                DATA: if (rvalid && rready) begin
                    if (group_words == 2) begin
                        group_words <= 0;
                        group_ready <= 1;
                    end else group_words <= group_words + 1'b1;
                    words_left <= words_left - 1'b1;
                    beats_left <= beats_left - 1'b1;
                    address <= address + BYTES;
                    if (rresp != 0 || rlast != (beats_left == 1)) begin
                        row_bad <= 1;
                        read_error <= 1;
                        if (cnn_row_active) begin
                            cnn_bad <= 1;
                            cnn_fault <= 1;
                        end
                    end
                    if (beats_left == 1) state <= DRAIN;
                end
                DRAIN: begin
                    if (words_left != 0) begin
                        if (cnn_row_active && !request_empty && group_words == 0) begin
                            if (pixels_left == 0 && !group_ready) begin
                                cnn_resume <= 1;
                                cnn_resume_address <= address;
                                cnn_resume_words <= words_left;
                                cnn_resume_column <= column;
                                state <= IDLE;
                            end
                        end else state <= PREPARE;
                    end
                    else if (pixels_left == 0 && !group_ready && column == row_width) begin
                        if (cnn_row_active) begin
                            cnn_address <= cnn_address + cnn_width*3;
                            cnn_row <= cnn_row + 1'b1;
                            if (cnn_row == RAW_H-1) begin
                                cnn_active <= 0;
                                cnn_complete <= 1;
                            end
                        end else if (!row_bad) begin
                            display_done <= 1;
                            display_row <= row;
                            display_epoch <= request[REQ_W-1 -: EW];
                        end
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n) begin
        if (pop_word && queued_words == 0) $fatal(1, "SRL word queue underflow");
        if (push_word && !pop_word && queued_words == 8) $fatal(1, "SRL word queue overflow");
    end
    initial begin
        if (AXI_WIDTH != 128 || RAW_W%BYTES || IMG_W%BYTES || CNN_FIFO_DEPTH*2 < RAW_W)
            $fatal(1, "unsupported shared DDR geometry");
    end
    always @(posedge clk) if (rst_n && cnn_start && cnn_active)
        $fatal(1, "CNN read request overlaps active frame");
`endif
endmodule
