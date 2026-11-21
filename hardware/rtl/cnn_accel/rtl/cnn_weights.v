// 权重链路：上电预载四套风格到独立 DDR 段，运行时只切换读地址并重新分发。
`timescale 1ns/1ps
`include "cnn_config.vh"

// 用途：接收软核送来的权重，将其写入 DDR，并完成回读校验与跨时钟域传输。
// 原理：复用原 AXI 通路预存权重及 IN 参数；切换时排空核心、选择 DDR 段、CRC 回读分发，不再覆盖 DDR。
module cnn_weights #(
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_DATA_W = 128,
    parameter [AXI_ADDR_W - 1:0] BASE_ADDR = `CANDY_TRAINED_BASE_ADDR
) (
    input axi_clk,
    input axi_rst_n,
    input calib_done,
    input style_next_toggle,
    output reg reload_request,
    input reload_held,
    input cnn_clk,
    input cnn_rst_n,
    input [11:0] boot_paddr,
    input boot_psel,
    input boot_penable,
    input boot_pwrite,
    input [31:0] boot_pwdata,
    input boot_params_ready,
    output reg [31:0] boot_prdata,
    output boot_pready,
    output boot_pslverror,
    output [AXI_ADDR_W - 1:0] awaddr,
    output [AXI_ADDR_W - 1:0] araddr,
    output [7:0] awlen,
    output [7:0] arlen,
    output [2:0] awsize,
    output [2:0] arsize,
    output [1:0] awburst,
    output [1:0] arburst,
    output awvalid,
    input awready,
    output [AXI_DATA_W - 1:0] wdata,
    output [AXI_DATA_W / 8 - 1:0] wstrb,
    output wvalid,
    output wlast,
    input wready,
    input bvalid,
    input [1:0] bresp,
    output bready,
    output arvalid,
    input arready,
    input [AXI_DATA_W - 1:0] rdata,
    input rvalid,
    input rlast,
    input [1:0] rresp,
    output rready,
    output [31:0] wt_bus,
    output wt_shift,
    output [7:0] wt_seg,
    output o_done,
    output o_error
);

    localparam integer SEG_NUM = `CNN_TRAINED_SEG_NUM;
    localparam integer WORDS = `CANDY_TRAINED_ROM_WORDS;
    localparam [SEG_NUM * 16 - 1:0] SEG_UNITS = `CNN_TRAINED_SEG_UNITS;
    localparam [SEG_NUM * 2 - 1:0] SEG_TYPES = `CNN_TRAINED_SEG_TYPES;
    localparam integer LANES = AXI_DATA_W / 32;
    localparam integer LW = (LANES < 2) ? 1:$clog2(LANES);
    localparam integer BYTES = AXI_DATA_W / 8;
    localparam integer BEATS = (WORDS + LANES - 1) / LANES;
    // 每个 128KiB 段依次保存原扫描包和 400 条、每条 8 字节的 IN 参数。
    localparam integer AFFINE_BYTES = 3200;
    localparam integer CACHE_WORDS = WORDS + AFFINE_BYTES / 4;
    localparam integer CACHE_BEATS = (CACHE_WORDS + LANES - 1) / LANES;
    localparam integer BW = $clog2(CACHE_BEATS + 1);
    reg [2:0] bank_select;
    reg [4:0] bank_valid;
    // IN 读取复用原读保持寄存器，既不新增 RAM，也不进入权重分发器。
    reg affine_read;
    reg affine_ready;
    reg affine_return_idle;
    localparam [3:0] IDLE = 0;
    localparam [3:0] BUILD = 1;
    localparam [3:0] AW = 2;
    localparam [3:0] W = 3;
    localparam [3:0] B = 4;
    localparam [3:0] WAIT_READ = 5;
    localparam [3:0] AR = 6;
    localparam [3:0] R = 7;
    localparam [3:0] ACK = 8;
    localparam [3:0] DONE = 9;
    localparam [3:0] ERROR = 10;
    localparam [3:0] WAIT_COMMIT = 11;
    localparam [3:0] CRC = 12;
    localparam [3:0] QUIESCE = 13;
    reg [3:0] state;
    reg initialized;
    reg beat_final;
    reg error_axi;
    reg [LW - 1:0] pack_lane;
    reg [BW - 1:0] write_index;
    reg [BW - 1:0] read_index;
    reg [AXI_DATA_W - 1:0] write_hold;
    reg [AXI_DATA_W - 1:0] read_hold;
    reg block_request;
    localparam integer WCW = $clog2(CACHE_WORDS + 1);
    localparam integer CCW = $clog2(AXI_DATA_W);
    reg [WCW - 1:0] received_words;
    reg size_valid;
    reg crc_valid;
    reg cpu_write_done;
    reg verified;
    reg [31:0] expected_crc;
    reg [31:0] crc_value;
    reg [CCW - 1:0] crc_bit;
    (* ASYNC_REG="TRUE" *)
    reg params_meta;
    (* ASYNC_REG="TRUE" *)
    reg params_sync;
    (* ASYNC_REG="TRUE" *)
    reg verified_meta;
    (* ASYNC_REG="TRUE" *)
    reg verified_sync;
    // 按键请求及核心暂停确认使用稳定电平跨时钟域传递。
    (* ASYNC_REG="TRUE" *)
    reg held_meta;
    (* ASYNC_REG="TRUE" *)
    reg held_sync;
    (* ASYNC_REG="TRUE" *)
    reg style_next_meta;
    (* ASYNC_REG="TRUE" *)
    reg style_next_sync;

    always @(posedge axi_clk or negedge axi_rst_n) if (! axi_rst_n) begin
        style_next_meta <= 0;
        style_next_sync <= 0;
    end else begin
        style_next_meta <= style_next_toggle;
        style_next_sync <= style_next_meta;
    end
    wire [31:0] crc_next = (crc_value >> 1) ^ ((crc_value [0] ^ write_hold [0]) ? 32'hedb88320:32'd0);
    wire cpu_tx_ready = state == BUILD && ! error_axi && received_words < CACHE_WORDS && calib_done;
    wire apb_access = boot_psel && boot_penable;
    reg apb_bad;
    assign boot_pready = 1'b1;
    assign boot_pslverror = apb_access && apb_bad;

    always @ * begin
        boot_prdata = 0;
        apb_bad = 0;
        begin
            if (boot_paddr [1:0] != 0) apb_bad = 1;
            else if (boot_pwrite) begin
                case (boot_paddr)
                    12'h004:case (boot_pwdata)
                        32'd1:if (state != IDLE || ! calib_done || ! size_valid || ! crc_valid || error_axi) apb_bad = 1;
                        32'd2:if (state != IDLE || ! bank_valid[bank_select] || ! crc_valid || ! calib_done || error_axi) apb_bad = 1;
                        // 帧中止期间，核心就绪信号可能短暂拉低；
                        // 此时仍可通过排空状态安全地重新加载。
                        32'd3:if (state != DONE || ! verified || error_axi) apb_bad = 1;
                        32'd4:if (state != WAIT_COMMIT || ! cpu_write_done || received_words != CACHE_WORDS || error_axi) apb_bad = 1;
                        default:apb_bad = 1;
                    endcase
                    12'h008:if (state != IDLE || error_axi || boot_pwdata != CACHE_WORDS * 4) apb_bad = 1;
                    12'h00c:if (! cpu_tx_ready) apb_bad = 1;
                    12'h010:if (state != IDLE || error_axi) apb_bad = 1;
                    12'h030:if (state != IDLE || error_axi || boot_pwdata > 4) apb_bad = 1;
                    12'h034:if ((state != IDLE && state != DONE) || ! bank_valid[bank_select] ||
                        error_axi || boot_pwdata >= AFFINE_BYTES || (boot_pwdata & (BYTES - 1)) != 0) apb_bad = 1;
                    default:apb_bad = 1;
                endcase
            end else begin
                case (boot_paddr)
                    12'h000:boot_prdata = { 20'd0, bank_valid, affine_ready, (reload_request && held_sync && state == IDLE), error_axi, (params_sync && verified && ! error_axi && ! reload_request), cpu_write_done, cpu_tx_ready, calib_done };
                    12'h004:boot_prdata = 0;
                    12'h008:boot_prdata = size_valid ? CACHE_WORDS * 4:0;
                    12'h010:boot_prdata = expected_crc;
                    12'h014:boot_prdata = received_words * 4;
                    12'h018:boot_prdata = { 31'd0, style_next_sync };
                    12'h030:boot_prdata = { 29'd0, bank_select };
                    12'h034:boot_prdata = { 31'd0, affine_ready };
                    12'h040, 12'h044, 12'h048, 12'h04c:begin
                        boot_prdata = read_hold[boot_paddr[3:2] * 32+:32];
                        if (! affine_ready) apb_bad = 1;
                    end
                    default:apb_bad = 1;
                endcase
            end
        end
    end
    wire rd_rst;
    wire rd_mem_enable;
    wire rd_en;
    reg [31:0] rd_data;
    reg rd_valid;
    wire distrib_done_all;
    reg load_started;
    (* ASYNC_REG="TRUE" *)
    reg initialized_meta;
    (* ASYNC_REG="TRUE" *)
    reg initialized_sync;
    (* ASYNC_REG="TRUE" *)
    reg error_meta;
    (* ASYNC_REG="TRUE" *)
    reg error_sync;
    (* ASYNC_REG="TRUE" *)
    reg request_meta;
    (* ASYNC_REG="TRUE" *)
    reg request_sync;
    reg request_seen;
    reg block_available;
    reg response_sent;
    reg block_ack;
    reg [AXI_DATA_W - 1:0] read_buffer;
    reg [LW - 1:0] word_lane;
    wire [31:0] legacy_bus;
    wire legacy_shift;
    wire [7:0] legacy_seg;
    (* ASYNC_REG="TRUE" *)
    reg ack_meta;
    (* ASYNC_REG="TRUE" *)
    reg ack_sync;
    (* ASYNC_REG="TRUE" *)
    reg enable_meta;
    (* ASYNC_REG="TRUE" *)
    reg enable_sync;
    assign awaddr = BASE_ADDR + { 12'd0, bank_select, 17'd0 } + write_index * BYTES;
    assign araddr = BASE_ADDR + { 12'd0, bank_select, 17'd0 } + read_index * BYTES;
    assign awlen = 0;
    assign arlen = 0;
    assign awsize = $clog2(BYTES);
    assign arsize = $clog2(BYTES);
    assign awburst = 2'b01;
    assign arburst = 2'b01;
    assign awvalid = state == AW;
    assign wvalid = state == W;
    assign wlast = 1'b1;
    assign wdata = write_hold;
    assign wstrb = { AXI_DATA_W / 8 { 1'b1 } };
    assign bready = state == B;
    assign arvalid = state == AR;
    assign rready = state == R;
    assign o_done = distrib_done_all && verified_sync && ! error_sync;
    assign wt_bus = legacy_bus;
    assign wt_shift = legacy_shift;
    assign wt_seg = legacy_seg;
    assign o_error = error_sync;
`ifndef SYNTHESIS
    initial if (AXI_DATA_W < 32 || AXI_DATA_W % 32 || (BYTES & (BYTES - 1)) || BASE_ADDR % BYTES) $fatal(1, "cnn_weights: invalid AXI width or base alignment");
    initial if (AXI_DATA_W != 128 || BASE_ADDR % 131072 || CACHE_WORDS * 4 > 131072) $fatal(1, "cnn_weights: invalid cache layout");
    initial if (WORDS % LANES) $fatal(1, "cnn_weights: image must align to AXI beats");
`endif

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (! axi_rst_n) begin
            state <= IDLE;
            bank_select <= 0;
            bank_valid <= 0;
            affine_read <= 0;
            affine_ready <= 0;
            affine_return_idle <= 0;
            initialized <= 0;
            beat_final <= 0;
            error_axi <= 0;
            pack_lane <= 0;
            write_index <= 0;
            read_index <= 0;
            write_hold <= 0;
            read_hold <= 0;
            block_request <= 0;
            ack_meta <= 0;
            ack_sync <= 0;
            enable_meta <= 0;
            enable_sync <= 0;
            received_words <= 0;
            size_valid <= 0;
            crc_valid <= 0;
            cpu_write_done <= 0;
            verified <= 0;
            expected_crc <= 0;
            crc_value <= 32'hffffffff;
            crc_bit <= 0;
            params_meta <= 0;
            params_sync <= 0;
            reload_request <= 0;
            held_meta <= 0;
            held_sync <= 0;
        end else begin
            ack_meta <= block_ack;
            ack_sync <= ack_meta;
            enable_meta <= rd_mem_enable;
            enable_sync <= enable_meta;
            params_meta <= boot_params_ready;
            params_sync <= params_meta;
            held_meta <= reload_held;
            held_sync <= held_meta;
            case (state)
                IDLE:state <= IDLE;
                BUILD:if (apb_access && boot_pwrite && boot_paddr == 12'h00c && ! apb_bad) begin
                    write_hold [pack_lane * 32+:32] <= boot_pwdata;
                    received_words <= received_words + 1'b1;
                    if (pack_lane == LANES - 1) begin
                        pack_lane <= 0;
                        beat_final <= received_words == CACHE_WORDS - 1;
                        state <= AW;
                    end else pack_lane <= pack_lane + 1'b1;
                end
                AW:if (awready) state <= W;
                W:if (wready) state <= B;
                B:if (bvalid) begin
                    if (bresp != 0 || error_axi) begin
                        error_axi <= 1;
                        state <= ERROR;
                    end else if (beat_final) begin
                        bank_valid[bank_select] <= 1;
                        cpu_write_done <= 1;
                        state <= WAIT_COMMIT;
                    end else begin
                        write_index <= write_index + 1'b1;
                        write_hold <= 0;
                        state <= BUILD;
                    end
                end
                // 等待分发器退出读复位才预取，避免第一数据拍被rd_rst丢弃。
                WAIT_READ:if (enable_sync) state <= AR;
                AR:if (arready) state <= R;
                R:if (rvalid) begin
                    if (rresp != 0 || ! rlast) begin
                        error_axi <= 1;
                        state <= ERROR;
                    end else begin
                        read_hold <= rdata;
                        write_hold <= rdata;
                        crc_bit <= 0;
                        if (affine_read) begin
                            affine_read <= 0;
                            affine_ready <= 1;
                            state <= affine_return_idle ? IDLE : DONE;
                        end else state <= CRC;
                    end
                end
                // 每拍计算一个反射 CRC 位，复用原写数据保持寄存器。
                CRC:begin
                    crc_value <= crc_next;
                    write_hold <= write_hold >> 1;
                    if (crc_bit == AXI_DATA_W - 1) begin
                        if (read_index == BEATS - 1 && (crc_next ^ 32'hffffffff) != expected_crc) begin
                            error_axi <= 1;
                            state <= ERROR;
                        end else begin
                            if (read_index == BEATS - 1) verified <= 1;
                            block_request <= ~ block_request;
                            state <= ACK;
                        end
                    end else crc_bit <= crc_bit + 1'b1;
                end
                ACK:if (ack_sync == block_request) begin
                    if (read_index == BEATS - 1) state <= DONE;
                    else begin
                        read_index <= read_index + 1'b1;
                        state <= AR;
                    end
                end
                DONE:state <= DONE;
                QUIESCE:if (held_sync && ! enable_sync && ! params_sync && ! ack_sync) begin
                    // DONE 状态已无在途 AXI 事务；CNN 侧复位
                    // 在开始下一次传输前清除分发器及应答状态。
                    state <= IDLE;
                    initialized <= 0;
                    verified <= 0;
                    cpu_write_done <= 0;
                    received_words <= 0;
                    size_valid <= 0;
                    crc_valid <= 0;
                    read_index <= 0;
                    write_index <= 0;
                    pack_lane <= 0;
                    block_request <= 0;
                    crc_value <= 32'hffffffff;
                end
                WAIT_COMMIT:state <= WAIT_COMMIT;
                ERROR:state <= ERROR;
                default:state <= IDLE;
            endcase
            if (apb_access && boot_pwrite && ! apb_bad) begin
                case (boot_paddr)
                    12'h008:size_valid <= 1;
                    12'h010:begin
                        expected_crc <= boot_pwdata;
                        crc_valid <= 1;
                    end
                    12'h030:begin
                        bank_select <= boot_pwdata[2:0];
                        affine_ready <= 0;
                    end
                    12'h034:begin
                        read_index <= BEATS + (boot_pwdata >> $clog2(BYTES));
                        affine_read <= 1;
                        affine_ready <= 0;
                        affine_return_idle <= state == IDLE;
                        state <= AR;
                    end
                    12'h004:if (boot_pwdata == 1) begin
                        state <= BUILD;
                        received_words <= 0;
                        pack_lane <= 0;
                        write_index <= 0;
                        cpu_write_done <= 0;
                        verified <= 0;
                        crc_value <= 32'hffffffff;
                        bank_valid[bank_select] <= 0;
                        affine_ready <= 0;
                    end else if (boot_pwdata == 2) begin
                        read_index <= 0;
                        crc_value <= 32'hffffffff;
                        verified <= 0;
                        affine_ready <= 0;
                        initialized <= 1;
                        reload_request <= 0;
                        state <= WAIT_READ;
                    end else if (boot_pwdata == 4) begin
                        // 仅结束预载，不启动 CNN；下一套风格可继续写入另一段。
                        state <= IDLE;
                        size_valid <= 0;
                        crc_valid <= 0;
                        received_words <= 0;
                    end else begin
                        reload_request <= 1;
                        state <= QUIESCE;
                    end
                    default:begin
                    end
                endcase
            end
            // 即使发生协议错误，也要排空已接收的 AXI 事务，
            // 避免共享 DDR 仲裁器停留在无人继续处理的事务上。
            if (error_axi && state != AW && state != W && state != B && state != AR && state != R) state <= ERROR;
            if (apb_access && apb_bad) begin
                error_axi <= 1;
            end
        end
    end
    wire start_load = initialized_sync && ! load_started && ! error_sync;
    cnn_dispatch #(
        .SEG_NUM(SEG_NUM),
        .SEG_UNITS(SEG_UNITS),
        .SEG_TW(SEG_TYPES)
    ) u_distrib (
        .clk(cnn_clk),
        .rst_n(cnn_rst_n),
        .start(start_load),
        .busy(),
        .done(),
        .done_all(distrib_done_all),
        .rd_rst(rd_rst),
        .rd_mem_enable(rd_mem_enable),
        .rd_en(rd_en),
        .rd_data(rd_data),
        .rd_valid(rd_valid),
        .wt_bus(legacy_bus),
        .wt_shift(legacy_shift),
        .wt_seg(legacy_seg),
        .wt_typ()
    );

    always @(posedge cnn_clk or negedge cnn_rst_n) begin
        if (! cnn_rst_n) begin
            initialized_meta <= 0;
            initialized_sync <= 0;
            error_meta <= 0;
            error_sync <= 0;
            verified_meta <= 0;
            verified_sync <= 0;
            request_meta <= 0;
            request_sync <= 0;
            request_seen <= 0;
            block_available <= 0;
            response_sent <= 0;
            block_ack <= 0;
            read_buffer <= 0;
            word_lane <= 0;
            rd_data <= 0;
            rd_valid <= 0;
            load_started <= 0;
        end else begin
            initialized_meta <= initialized;
            initialized_sync <= initialized_meta;
            error_meta <= error_axi;
            error_sync <= error_meta;
            verified_meta <= verified;
            verified_sync <= verified_meta;
            request_meta <= block_request;
            request_sync <= request_meta;
            rd_valid <= 0;
            if (start_load) load_started <= 1;
            if (rd_rst) begin
                block_available <= 0;
                response_sent <= 0;
                word_lane <= 0;
                request_seen <= request_sync;
                block_ack <= request_sync;
            end else begin
                if (request_sync != request_seen) begin
                    // read_hold已保持两个CNN时钟，并保持到本数据拍全部消费。
                    read_buffer <= read_hold;
                    request_seen <= request_sync;
                    block_available <= 1;
                    word_lane <= 0;
                end
                if (! rd_en) response_sent <= 0;
                if (rd_en && block_available && ! response_sent) begin
                    rd_data <= read_buffer [word_lane * 32+:32];
                    rd_valid <= 1;
                    response_sent <= 1;
                    if (word_lane == LANES - 1) begin
                        block_available <= 0;
                        block_ack <= request_seen;
                    end else word_lane <= word_lane + 1'b1;
                end
                // 最后一AXI拍的填充词不上权重总线，但仍需确认以释放读事务。
                if (distrib_done_all && block_available) begin
                    block_available <= 0;
                    block_ack <= request_seen;
                end
            end
        end
    end
endmodule
