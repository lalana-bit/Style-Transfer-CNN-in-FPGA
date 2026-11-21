`timescale 1ns/1ps
// 用途：摄像头原画只写一次 DDR，由统一帧池分配采集/CNN/显示地址。
// 原理：保留原有 96→128 位打包和采集写引擎；公共 DDR 服务成对返回 RGB48，
//       经双时钟 FIFO 在 225 MHz 域按下游 ready 生成逐行稀疏数据。
module frame_buffer #(
    parameter I_VID_WIDTH = 96,
    parameter AXI_DATA_WIDTH = 128,
    parameter AXI_ADDR_WIDTH = 32,
    parameter WR_FIFO_DEPTH = 512,
    parameter PIXEL_FIFO_DEPTH = 1024,
    parameter MAX_VID_WIDTH = 864,
    parameter MAX_VID_HIGHT = 486,
    parameter EXPECTED_FRAME_BEATS = MAX_VID_WIDTH*MAX_VID_HIGHT/4,
    parameter START_ADDR = 32'h00000000
)(
    input wire axi_clk,
    input wire rst_n,
    input wire i_clk,
    input wire i_vs,
    input wire i_de,
    input wire [I_VID_WIDTH-1:0] vin,
    input wire o_clk,
    input wire stream_start,
    input wire stream_ready,
    output wire stream_available,
    output wire stream_idle,
    input wire pause,
    input wire display_start,
    output wire [AXI_ADDR_WIDTH-1:0] raw_display_base,
    output wire raw_display_available,
    output wire service_start,
    output wire [AXI_ADDR_WIDTH-1:0] service_base,
    input wire service_valid,
    input wire [47:0] service_pixel,
    input wire service_complete,
    input wire service_fault,
    output wire [10:0] service_used,
    output wire o_hs,
    output reg o_vs,
    output wire o_de,
    output wire [23:0] vout,
    output wire o_underflow,
    output wire [AXI_ADDR_WIDTH-1:0] awaddr,
    output wire [7:0] awlen,
    output wire [2:0] awsize,
    output wire [1:0] awburst,
    output wire [2:0] awprot,
    output wire [3:0] awcache,
    output wire awlock,
    output wire awvalid,
    input wire awready,
    output wire [AXI_DATA_WIDTH-1:0] wdata,
    output wire [AXI_DATA_WIDTH/8-1:0] wstrb,
    output wire wlast,
    output wire wvalid,
    input wire wready,
    input wire [5:0] bid,
    input wire bvalid,
    output wire bready
);
    wire wr_rst_n;
    wire axi_rst_n;
    wire rd_rst_n;
    rst_n_piple #(.DLY(3)) capture_reset (
        .clk(i_clk),
        .rst_n_i(rst_n),
        .rst_n_o(wr_rst_n)
    );
    rst_n_piple #(.DLY(3)) service_reset (
        .clk(axi_clk),
        .rst_n_i(rst_n),
        .rst_n_o(axi_rst_n)
    );
    rst_n_piple #(.DLY(3)) stream_reset (
        .clk(o_clk),
        .rst_n_i(rst_n),
        .rst_n_o(rd_rst_n)
    );

    wire fifo_write;
    wire [AXI_DATA_WIDTH-1:0] fifo_word;
    wire frame_start;
    wire frame_stable;
    wire fifo_reset;
    wire [31:0] frame_words;
    vid_rx_align_v1 #(
        .I_VID_WIDTH(I_VID_WIDTH),
        .AXI_DDR_WIDTH(AXI_DATA_WIDTH),
        .EXPECTED_FRAME_BEATS(EXPECTED_FRAME_BEATS)
    ) capture_pack (
        .clk(i_clk),
        .rst_n(wr_rst_n),
        .i_vs(i_vs),
        .i_hs(1'b0),
        .i_de(i_de),
        .vin(vin),
        .fifo_wr_en(fifo_write),
        .fifo_wr_data(fifo_word),
        .frame_start(frame_start),
        .fifo_rst_p(fifo_reset),
        .frame_stable(frame_stable),
        .ddr_frame_len(frame_words)
    );
    wire [AXI_ADDR_WIDTH-1:0] write_base;
    wire write_complete;
    wire write_ack;
    ddr_wr_buffer #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .WR_FIFO_DEPTH(WR_FIFO_DEPTH),
        .BURST_LEN(127)
    ) capture_writer (
        .axi_clk(axi_clk),
        .rst_n(axi_rst_n),
        .wr_start(frame_start && frame_stable),
        .start_addr(write_base),
        .total_burst_len(frame_words),
        .bank_sw_ack(write_ack),
        .bank_sw(write_complete),
        .wr_fifo_rst_p(fifo_reset),
        .wr_fifo_wrclk(i_clk),
        .wr_fifo_wren(fifo_write),
        .wr_fifo_wrdata(fifo_word),
        .awaddr(awaddr),
        .awlen(awlen),
        .awsize(awsize),
        .awburst(awburst),
        .awcache(awcache),
        .awlock(awlock),
        .awvalid(awvalid),
        .awprot(awprot),
        .awready(awready),
        .wdata(wdata),
        .wstrb(wstrb),
        .wlast(wlast),
        .wvalid(wvalid),
        .wready(wready),
        .bid(bid),
        .bvalid(bvalid),
        .bready(bready)
    );

    reg period;
    (* async_reg="true" *) reg [2:0] request_sync;
    (* async_reg="true" *) reg pause_meta;
    (* async_reg="true" *) reg pause_sync;
    wire available_axi;
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            request_sync <= 0;
            pause_meta <= 0;
            pause_sync <= 0;
        end else begin
            request_sync <= {request_sync[1:0],period};
            pause_meta <= pause;
            pause_sync <= pause_meta;
        end
    end
    video_frame_pool #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .BASE_ADDR(START_ADDR)
    ) raw_pool (
        .clk(axi_clk),
        .rst_n(axi_rst_n),
        .write_complete(write_complete),
        .write_ack(write_ack),
        .write_base(write_base),
        .input_request(request_sync[1] && !request_sync[2]),
        .input_start(service_start),
        .input_base(service_base),
        .input_available(available_axi),
        .input_complete(service_complete),
        .input_fault(service_fault),
        .display_start(display_start),
        .pause(pause_sync),
        .display_base(raw_display_base),
        .display_available(raw_display_available)
    );

    wire pixel_full;
    wire pixel_empty;
    wire pixel_pop;
    wire [47:0] pixel_data;
    wire [$clog2(PIXEL_FIFO_DEPTH):0] fifo_used;
    assign service_used = fifo_used;
    cnn_pixel_async_fifo #(
        .WIDTH(48),
        .DEPTH(PIXEL_FIFO_DEPTH)
    ) input_pixels (
        .wr_clk(axi_clk),
        .wr_rst_n(axi_rst_n),
        .wr_en(service_valid),
        .wr_data(service_pixel),
        .full(pixel_full),
        .wr_usedw(fifo_used),
        .rd_clk(o_clk),
        .rd_rst_n(rd_rst_n),
        .rd_en(pixel_pop),
        .rd_data(pixel_data),
        .empty(pixel_empty),
        .rd_usedw()
    );
    (* async_reg="true" *) reg [1:0] available_sync;
    reg fault_toggle;
    (* async_reg="true" *) reg [2:0] fault_sync;
    always @(posedge axi_clk or negedge axi_rst_n)
        if (!axi_rst_n) fault_toggle <= 0;
        else if (service_fault) fault_toggle <= ~fault_toggle;
    always @(posedge o_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            available_sync <= 0;
            fault_sync <= 0;
        end else begin
            available_sync <= {available_sync[0],available_axi};
            fault_sync <= {fault_sync[1:0],fault_toggle};
        end
    end
    assign stream_available = available_sync[1];
    assign o_underflow = fault_sync[2] != fault_sync[1];

    localparam XW=$clog2(MAX_VID_WIDTH+1), YW=$clog2(MAX_VID_HIGHT+1);
    localparam IDLE=0, START=1, ROW=2, EOL=3, TAIL=4;
    reg [2:0] state;
    reg [5:0] guard_count;
    reg [XW-1:0] column;
    reg [YW-1:0] row;
    reg pending;
    reg [1:0] held_count;
    reg [47:0] held_pixel;
    wire consume = state == ROW && stream_ready && held_count != 0;
    // 一拍 RAM 返回先锁存再消费；ready 撤销时完整保留像素和帧状态。
    assign pixel_pop = state == ROW && !pixel_empty && held_count == 0 && !pending;
    assign stream_idle = state == IDLE;
    assign o_hs = state == ROW;
    assign o_de = consume;
    assign vout = held_pixel[47:24];
    always @(posedge o_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            pending <= 0;
            held_count <= 0;
        end else begin
            pending <= pixel_pop;
            if (pending) begin
                held_pixel <= pixel_data;
                held_count <= 2;
            end else if (consume) begin
                held_count <= held_count - 1'b1;
                held_pixel <= held_pixel << 24;
            end
        end
    end
    always @(posedge o_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            state <= IDLE;
            period <= 0;
            o_vs <= 0;
            guard_count <= 0;
            column <= 0;
            row <= 0;
        end else begin
            o_vs <= 0;
            case (state)
                IDLE: if (stream_start && available_sync[1]) begin
                    period <= 1;
                    o_vs <= 1;
                    state <= START;
                    guard_count <= 0;
                    column <= 0;
                    row <= 0;
                end
                START: if (guard_count == 15) begin
                    guard_count <= 0;
                    state <= ROW;
                end else guard_count <= guard_count + 1'b1;
                ROW: if (consume) begin
                    if (column == MAX_VID_WIDTH-1) begin
                        column <= 0;
                        guard_count <= 0;
                        if (row == MAX_VID_HIGHT-1) begin
                            state <= TAIL;
                            period <= 0;
                        end else begin
                            row <= row + 1'b1;
                            state <= EOL;
                        end
                    end else column <= column + 1'b1;
                end
                EOL: if (guard_count == 2) begin
                    guard_count <= 0;
                    state <= ROW;
                end else guard_count <= guard_count + 1'b1;
                TAIL: if (guard_count == 31) state <= IDLE;
                      else guard_count <= guard_count + 1'b1;
                default: state <= IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    always @(posedge axi_clk) if (axi_rst_n && service_valid && pixel_full)
        $fatal(1, "reserved CNN pixel FIFO overflow");
`endif
endmodule
