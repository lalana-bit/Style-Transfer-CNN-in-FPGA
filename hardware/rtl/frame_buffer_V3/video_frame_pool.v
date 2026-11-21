`timescale 1ns/1ps
// 用途：统一管理原画 DDR 帧池，供采集、CNN 和显示共同使用。
// 原理：五个 DDR 槽位分别保护写入、最新完整帧、CNN 读帧、已读完帧和显示帧；
//       只轮换地址，不复制像素。写入收到最后一个 B 响应后才允许发布。
module video_frame_pool #(
    parameter ADDR_WIDTH = 32,
    parameter BASE_ADDR = 32'h00000000,
    parameter FRAME_STRIDE = 32'h00140000
)(
    input wire clk,
    input wire rst_n,
    input wire write_complete,
    output reg write_ack,
    output wire [ADDR_WIDTH-1:0] write_base,
    input wire input_request,
    output reg input_start,
    output reg [ADDR_WIDTH-1:0] input_base,
    output wire input_available,
    input wire input_complete,
    input wire input_fault,
    input wire display_start,
    input wire pause,
    output wire [ADDR_WIDTH-1:0] display_base,
    output wire display_available
);
    reg [2:0] write_bank;
    reg [2:0] latest_bank;
    reg [2:0] input_bank;
    reg [2:0] ready_bank;
    reg [2:0] display_bank;
    reg latest_valid;
    reg input_busy;
    reg input_bad;
    reg ready_valid;
    reg display_valid;
    reg fresh_frame;
    reg [2:0] free_bank;
    reg free_found;
    integer slot;
    wire publish = write_complete && !write_ack;
    wire [2:0] newest_bank = publish ? write_bank : latest_bank;
    wire newest_valid = publish || latest_valid;
    wire take_display = display_start && ready_valid && !pause;
    wire [2:0] shown_bank = take_display ? ready_bank : display_bank;

    // 五个槽位最多排除四个不同的读者/最新帧，因此采集始终有可写槽位。
    // 保守保留旧引用直到本拍结束，避免同拍完成、换帧产生读写竞争。
    always @* begin
        free_bank = write_bank;
        free_found = 0;
        for (slot = 4; slot >= 0; slot = slot - 1) begin
            if (slot != write_bank &&
                (!input_busy || slot != input_bank) &&
                (!ready_valid || slot != ready_bank) &&
                (!display_valid || slot != display_bank)) begin
                free_bank = slot;
                free_found = 1;
            end
        end
    end

    assign write_base = BASE_ADDR + write_bank * FRAME_STRIDE;
    assign input_available = fresh_frame;
    // 组合给出本次扫描将锁存的地址，与扫描器 START 拍一致。
    assign display_base = BASE_ADDR + shown_bank * FRAME_STRIDE;
    assign display_available = display_valid || take_display;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_bank <= 0;
            latest_bank <= 0;
            input_bank <= 0;
            ready_bank <= 0;
            display_bank <= 0;
            latest_valid <= 0;
            input_busy <= 0;
            input_bad <= 0;
            ready_valid <= 0;
            display_valid <= 0;
            fresh_frame <= 0;
            write_ack <= 0;
            input_start <= 0;
            input_base <= 0;
        end else begin
            write_ack <= write_complete;
            input_start <= 0;
            if (publish) begin
                latest_bank <= write_bank;
                latest_valid <= 1;
                fresh_frame <= 1;
                write_bank <= free_bank;
            end
            if (input_request && newest_valid) begin
                input_base <= BASE_ADDR + newest_bank * FRAME_STRIDE;
                input_bank <= newest_bank;
                input_busy <= 1;
                input_bad <= 0;
                input_start <= 1;
                // 同拍新到的完整帧已选走，不再重复当作新帧。
                fresh_frame <= 0;
            end
            if (input_fault) input_bad <= 1;
            if (input_complete && input_busy) begin
                if (!input_bad && !input_fault) begin
                    ready_bank <= input_bank;
                    ready_valid <= 1;
                end
                input_busy <= 0;
            end
            if (take_display) begin
                display_bank <= ready_bank;
                display_valid <= 1;
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n) begin
        if (publish && !free_found) $fatal(1, "raw pool has no free write slot");
        if ((input_busy && write_bank == input_bank) ||
            (ready_valid && write_bank == ready_bank) ||
            (display_valid && write_bank == display_bank))
            $fatal(1, "raw pool overwrites a referenced frame");
        if (input_request && input_busy) $fatal(1, "overlapping CNN frame reads");
    end
`endif
endmodule
