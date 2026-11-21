// 实例归一化控制：采集统计量，通过 APB 邮箱在后台更新系数。
`timescale 1ns/1ps

// 用途：采集实例归一化所需的历史帧统计量，并提供软核读统计、写系数的接口。
// 原理：每次统计指定层一帧的逐通道累加和与平方和，经跨时钟域 APB 邮箱传递；软核在后台计算系数，不暂停视频。
module cnn_in #(
    parameter PIXELS = 2304,
    parameter CH = 32,
    parameter STAT_SHIFT = 8
) (
    input pclk,
    input prst_n,
    input [7:0] paddr,
    input psel,
    input penable,
    input pwrite,
    input [31:0] pwdata,
    output [31:0] prdata,
    output pready,
    output pslverror,
    input clk,
    input rst_n,
    input core_busy,
    input frame_start,
    input frame_end,
    input frame_abort,
    input [14:0] stat_valid,
    input [359:0] stat_acc,
    input [119:0] stat_channel,
    output reg cfg_we,
    output reg [3:0] cfg_layer,
    output reg [7:0] cfg_channel,
    output reg signed [19:0] cfg_bias,
    output reg [30:0] cfg_multiplier,
    output reg [5:0] cfg_shift
);

    reg [7:0] mail_addr;
    reg [31:0] mail_data;
    reg mail_write;
    reg request;
    reg acknowledge;
    reg [31:0] response;
    reg response_error;
    (* ASYNC_REG="TRUE" *)
    reg ack_meta;
    (* ASYNC_REG="TRUE" *)
    reg ack_sync;
    (* ASYNC_REG="TRUE" *)
    reg alive_meta;
    (* ASYNC_REG="TRUE" *)
    reg alive_sync;
    reg pending;
    reg complete;
    reg [31:0] response_p;
    reg error_p;
    assign pready = complete;
    assign prdata = response_p;
    assign pslverror = complete && error_p;

    always @(posedge pclk or negedge prst_n) begin
        if (! prst_n) begin
            request <= 0;
            pending <= 0;
            complete <= 0;
            ack_meta <= 0;
            ack_sync <= 0;
            alive_meta <= 0;
            alive_sync <= 0;
            response_p <= 0;
            error_p <= 0;
        end else begin
            alive_meta <= rst_n;
            alive_sync <= alive_meta;
            ack_meta <= acknowledge;
            ack_sync <= ack_meta;
            if (! alive_sync) begin
                request <= 0;
                pending <= 0;
                complete <= 0;
            end else begin
                if (! psel || ! penable) complete <= 0;
                if (psel && penable && ! pending && ! complete) begin
                    mail_addr <= paddr;
                    mail_data <= pwdata;
                    mail_write <= pwrite;
                    request <= ! request;
                    pending <= 1;
                end
                if (pending && ack_sync == request) begin
                    pending <= 0;
                    complete <= 1;
                    response_p <= response;
                    error_p <= response_error;
                end
            end
        end
    end
    // 三条统计通路只选择各自五层；APB邮箱、快照组装和系数写口共用。
    (* ASYNC_REG="TRUE" *) reg req_meta;
    (* ASYNC_REG="TRUE" *) reg req_sync;
    reg seen_request;
    reg reply_pending;
    reg [1:0] group_select;
    reg [3:0] layer [0:2];
    (* syn_preserve=1 *) reg [4:0] layer_pick [0:2];
    reg [2:0] arm;
    reg [2:0] release_snapshot;
    reg [2:0] cancel;
    reg [5:0] arm_channels;
    reg [$clog2(PIXELS * 16 + 1) - 1:0] arm_pixels;
    wire [2:0] armed;
    wire [2:0] capturing;
    wire [2:0] done;
    wire [2:0] errors;
    wire [2:0] held;
    wire [5:0] channels [0:2];
    wire [$clog2(PIXELS * 16 + 1) - 1:0] pixels [0:2];
    wire [$clog2(PIXELS * 128 + 1) - 1:0] samples [0:2];
    wire [31:0] initialized [0:2];
    wire [19:0] memory_q [0:2];
    wire [15:0] sample_frame [0:2];
    wire [23:0] done_time [0:2];
    reg [15:0] frame_number;
    reg [7:0] us_divider;
    reg [23:0] time_us;
    (* syn_preserve=1 *) reg abort_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin frame_number <= 0; us_divider <= 0; time_us <= 0; abort_q <= 0; end
        else begin
            abort_q <= frame_abort;
            if (frame_start) frame_number <= frame_number + 1'b1;
            if (us_divider == 224) begin us_divider <= 0; time_us <= time_us + 1'b1; end
            else us_divider <= us_divider + 1'b1;
        end
    end
    reg snapshot_request;
    reg [2:0] snapshot_step;
    reg [1:0] snapshot_group;
    reg [7:0] snapshot_base;
    reg snapshot_initialized;
    reg [7:0] read_channel;
    reg [39:0] qsum;
    reg [59:0] qsquare;
    reg qinitialized;
    wire snapshot_start = snapshot_request && !capturing[snapshot_group] && !cancel[snapshot_group] && snapshot_step == 0;
    wire snapshot_read = snapshot_start || (snapshot_step != 0 && snapshot_step < 5);
    wire [7:0] snapshot_ra = snapshot_start ? read_channel * 5 : snapshot_base + snapshot_step;
    wire snapshot_wait = snapshot_request || snapshot_step != 0;
    wire [19:0] snapshot_data = memory_q[snapshot_group];
    genvar g;
    generate for (g = 0; g < 3; g = g + 1) begin : g_stats
        reg signed [23:0] selected_acc;
        reg [7:0] selected_channel;
        wire selected_valid;
        integer i;
        assign selected_valid = |(stat_valid[g * 5+:5] & layer_pick[g]);
        always @* begin
            selected_acc = 0;
            selected_channel = 0;
            for (i = 0; i < 5; i = i + 1) begin
                selected_acc = selected_acc | (stat_acc[(g * 5 + i) * 24+:24] & {24{layer_pick[g][i]}});
                selected_channel = selected_channel | (stat_channel[(g * 5 + i) * 8+:8] & {8{layer_pick[g][i]}});
            end
        end
        cnn_in_stats #(.PIXELS(PIXELS), .CH(CH), .STAT_SHIFT(STAT_SHIFT)) stats (
            .clk(clk),
            .rst_n(rst_n),
            .frame_start(frame_start),
            .frame_end(frame_end),
            .frame_abort(abort_q),
            .arm(arm[g]),
            .release_snapshot(release_snapshot[g]),
            .cancel(cancel[g]),
            .arm_channels(arm_channels),
            .arm_pixels(arm_pixels),
            .selected_valid(selected_valid),
            .selected_acc(selected_acc),
            .selected_channel(selected_channel),
            .snapshot_re(snapshot_read && snapshot_group == g),
            .snapshot_ra(snapshot_ra),
            .memory_q(memory_q[g]),
            .armed(armed[g]),
            .capturing(capturing[g]),
            .done(done[g]),
            .error(errors[g]),
            .held(held[g]),
            .channels(channels[g]),
            .pixels(pixels[g]),
            .samples(samples[g]),
            .initialized_channels(initialized[g]),
            .frame_number(frame_number),
            .time_us(time_us),
            .sample_frame(sample_frame[g]),
            .done_time(done_time[g])
        );
    end endgenerate

    reg [7:0] staged_channel;
    reg signed [19:0] staged_bias;
    reg [30:0] staged_multiplier;
    reg [5:0] staged_shift;
    wire snapshot_invalidated =
        (frame_start && armed[snapshot_group]) ||
        (abort_q && (armed[snapshot_group] || capturing[snapshot_group]));
    wire valid_layer = (group_select == 0 && mail_data[11:8] < 5) ||
                       (group_select == 1 && mail_data[11:8] >= 5 && mail_data[11:8] < 10) ||
                       (group_select == 2 && mail_data[11:8] >= 10 && mail_data[11:8] < 15);
    integer r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_meta <= 0;
            req_sync <= 0;
            seen_request <= 0;
            reply_pending <= 0;
            acknowledge <= 0;
            response <= 0;
            response_error <= 0;
            group_select <= 0;
            arm <= 0;
            release_snapshot <= 0;
            cancel <= 0;
            snapshot_request <= 0;
            snapshot_step <= 0;
            snapshot_group <= 0;
            qinitialized <= 0;
            read_channel <= 0;
            arm_channels <= 8;
            arm_pixels <= PIXELS * 16;
            staged_channel <= 0;
            staged_bias <= 0;
            staged_multiplier <= 0;
            staged_shift <= 32;
            cfg_we <= 0;
            cfg_layer <= 0;
            cfg_channel <= 0;
            cfg_bias <= 0;
            cfg_multiplier <= 0;
            cfg_shift <= 32;
            for (r = 0; r < 3; r = r + 1) begin layer[r] <= r * 5; layer_pick[r] <= 1; end
        end else begin
            req_meta <= request;
            req_sync <= req_meta;
            arm <= 0;
            release_snapshot <= 0;
            cancel <= 0;
            cfg_we <= 0;
            if (snapshot_invalidated) begin
                snapshot_step <= 0;
                snapshot_request <= 0;
                qinitialized <= 0;
            end else if (snapshot_start) begin
                snapshot_request <= 0;
                snapshot_step <= 1;
                snapshot_base <= read_channel * 5;
                snapshot_initialized <= initialized[snapshot_group][read_channel];
            end else if (snapshot_step != 0) begin
                case (snapshot_step)
                    1: qsum[19:0] <= snapshot_data;
                    2: qsum[39:20] <= snapshot_data;
                    3: qsquare[19:0] <= snapshot_data;
                    4: qsquare[39:20] <= snapshot_data;
                    5: begin qsquare[59:40] <= snapshot_data; qinitialized <= snapshot_initialized; end
                endcase
                snapshot_step <= snapshot_step == 5 ? 0 : snapshot_step + 1'b1;
            end
            if (reply_pending && !snapshot_wait) begin
                if (!mail_write) case (mail_addr)
                    8'h0c: response <= qinitialized ? qsum[31:0] : 0;
                    8'h10: response <= qinitialized ? {{24{qsum[39]}}, qsum[39:32]} : 0;
                    8'h14: response <= qinitialized ? qsquare[31:0] : 0;
                    8'h18: response <= qinitialized ? {4'd0, qsquare[59:32]} : 0;
                endcase
                acknowledge <= seen_request;
                reply_pending <= 0;
            end
            if (req_sync != seen_request && !reply_pending) begin
                seen_request <= req_sync;
                reply_pending <= 1;
                response <= 0;
                response_error <= 0;
                if (mail_addr[1:0] != 0) response_error <= 1;
                else if (mail_write) case (mail_addr)
                    8'h00: case (mail_data[7:0])
                        1: if (!armed[group_select] && !capturing[group_select] && !held[group_select] && valid_layer) begin
                            arm[group_select] <= 1;
                            layer[group_select] <= mail_data[11:8];
                            layer_pick[group_select] <= 5'b1 << (mail_data[11:8] - group_select * 5);
                            case (mail_data[11:8])
                                0: begin arm_channels <= 8; arm_pixels <= PIXELS * 16; end
                                1: begin arm_channels <= 16; arm_pixels <= PIXELS * 4; end
                                13: begin arm_channels <= 16; arm_pixels <= PIXELS * 4; end
                                14: begin arm_channels <= 8; arm_pixels <= PIXELS * 16; end
                                default: begin arm_channels <= 32; arm_pixels <= PIXELS; end
                            endcase
                        end else response_error <= 1;
                        2: if (held[group_select] && done[group_select] && staged_multiplier != 0 &&
                               staged_shift >= 32 && staged_shift <= 47 && staged_channel < channels[group_select]) begin
                            cfg_we <= 1;
                            cfg_layer <= layer[group_select];
                            cfg_channel <= staged_channel;
                            cfg_bias <= staged_bias;
                            cfg_multiplier <= staged_multiplier;
                            cfg_shift <= staged_shift;
                        end else response_error <= 1;
                        3: if (!capturing[group_select] && !armed[group_select]) release_snapshot[group_select] <= 1;
                           else response_error <= 1;
                        4: if (!capturing[group_select]) begin
                            cancel[group_select] <= 1;
                            snapshot_group <= group_select;
                            snapshot_request <= 1;
                        end else response_error <= 1;
                        default: response_error <= 1;
                    endcase
                    8'h08: if (mail_data < CH && !capturing[group_select]) begin
                        read_channel <= mail_data[7:0];
                        snapshot_group <= group_select;
                        snapshot_request <= 1;
                    end else response_error <= 1;
                    8'h20: if (mail_data < CH) staged_channel <= mail_data[7:0]; else response_error <= 1;
                    8'h24: if ($signed(mail_data) >= -524288 && $signed(mail_data) <= 524287) staged_bias <= mail_data[19:0]; else response_error <= 1;
                    8'h28: if (mail_data != 0 && !mail_data[31]) staged_multiplier <= mail_data[30:0]; else response_error <= 1;
                    8'h2c: if (mail_data >= 32 && mail_data <= 47) staged_shift <= mail_data[5:0]; else response_error <= 1;
                    8'h3c: if (mail_data < 3) group_select <= mail_data[1:0]; else response_error <= 1;
                    default: response_error <= 1;
                endcase
                else case (mail_addr)
                    8'h04: response <= {22'd0, core_busy, layer[group_select], errors[group_select], held[group_select], capturing[group_select], done[group_select], armed[group_select]};
                    8'h08: response <= read_channel;
                    8'h0c, 8'h10, 8'h14, 8'h18: begin end
                    8'h1c: response <= pixels[group_select];
                    8'h30: response <= samples[group_select];
                    8'h34: response <= 32'h494e0003;
                    8'h38: response <= channels[group_select];
                    8'h3c: response <= group_select;
                    8'h40: response <= {16'd0, sample_frame[group_select]};
                    8'h44: response <= {16'd0, frame_number};
                    8'h48: response <= {8'd0, done_time[group_select]};
                    8'h4c: response <= {8'd0, time_us};
                    8'h50: response <= {13'd0, errors, 5'd0, done, 5'd0, (armed | capturing | held)};
                    default: response_error <= 1;
                endcase
            end
        end
    end
`ifndef SYNTHESIS
    initial if (CH != 32 || STAT_SHIFT != 8) $fatal(1, "IN groups require C32 and shift8");
    always @(posedge clk) if (rst_n && cfg_we && (!held[group_select] || !done[group_select]))
        $fatal(1, "IN write without complete snapshot");
`endif
endmodule

// 用途：采集一个已选层的完整帧，保存每通道40位和与60位平方和。
// 原理：每样本分五个20位RAM字读改写；三组各有独立RAM和平方乘法，共用外部快照读调度。
module cnn_in_stats #(
    parameter integer PIXELS = 2304,
    parameter integer CH = 32,
    parameter integer STAT_SHIFT = 8
) (
    input clk,
    input rst_n,
    input frame_start,
    input frame_end,
    input frame_abort,
    input arm,
    input release_snapshot,
    input cancel,
    input [5:0] arm_channels,
    input [$clog2(PIXELS * 16 + 1) - 1:0] arm_pixels,
    input selected_valid,
    input signed [23:0] selected_acc,
    input [7:0] selected_channel,
    input snapshot_re,
    input [$clog2(5 * CH) - 1:0] snapshot_ra,
    output reg [19:0] memory_q,
    output reg armed,
    output reg capturing,
    output reg done,
    output reg error,
    output reg held,
    output [5:0] channels,
    output [$clog2(PIXELS * 16 + 1) - 1:0] pixels,
    output [$clog2(PIXELS * 128 + 1) - 1:0] samples,
    output [CH - 1:0] initialized_channels,
    input [15:0] frame_number,
    input [23:0] time_us,
    output reg [15:0] sample_frame,
    output reg [23:0] done_time
);
    localparam AW = $clog2(5 * CH);
    localparam PW = $clog2(PIXELS * 16 + 1);
    localparam CW = $clog2(PIXELS * 128 + 1);
    localparam VW = 24 - STAT_SHIFT;
    (* syn_ramstyle="block_ram" *) reg [19:0] memory [0:5 * CH - 1];
    reg [CH - 1:0] initialized;
    reg [5:0] channel_count;
    reg [PW - 1:0] pixel_count;
    reg [CW - 1:0] sample_count;
    reg [CW - 1:0] expected_samples;
    reg [2:0] stat_step;
    reg [4:0] stat_channel;
    reg [AW - 1:0] stat_base;
    reg stat_initialized;
    reg signed [VW - 1:0] value;
    wire signed [2 * VW - 1:0] square_product = value * value;
    reg [37:0] square;
    reg carry;
    reg [19:0] addend;
    reg [3:0] drain;
    wire accept = capturing && selected_valid && !frame_start && !frame_abort &&
                  stat_step == 0 && selected_channel < channel_count;
    wire commit = stat_step == 5 && !frame_start && !frame_abort;
    wire stat_read = accept || (stat_step != 0 && stat_step < 5);
    wire [AW - 1:0] read_address = accept ? selected_channel * 5 : stat_base + stat_step;
    wire [AW - 1:0] write_address = stat_base + stat_step - 1'b1;
    wire complete_channels = channel_count == 8 ? (&initialized[7:0]) :
                             channel_count == 16 ? (&initialized[15:0]) : (&initialized);
    wire [20:0] sum = {1'b0, stat_initialized ? memory_q : 20'd0} + {1'b0, addend} +
                      ((stat_step == 2 || stat_step >= 4) && carry);
    assign channels = channel_count;
    assign pixels = pixel_count;
    assign samples = sample_count;
    assign initialized_channels = initialized;
    always @* begin
        case (stat_step)
            1: addend = {{(20 - VW){value[VW - 1]}}, value};
            2: addend = {20{value[VW - 1]}};
            3: addend = square[19:0];
            4: addend = {2'd0, square[37:20]};
            default: addend = 0;
        endcase
    end
    always @(posedge clk) begin
        if (stat_read || snapshot_re)
            memory_q <= memory[stat_read ? read_address : snapshot_ra];
        if (stat_step != 0 && !frame_start && !frame_abort)
            memory[write_address] <= sum[19:0];
        if (stat_step == 1) square <= {{(38 - 2 * VW){1'b0}}, square_product};
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed <= 0;
            capturing <= 0;
            done <= 0;
            error <= 0;
            held <= 0;
            drain <= 0;
            initialized <= 0;
            sample_count <= 0;
            expected_samples <= 0;
            channel_count <= 0;
            pixel_count <= 0;
            stat_step <= 0;
            carry <= 0;
            sample_frame <= 0;
            done_time <= 0;
        end else begin
            if (frame_start || frame_abort) begin
                stat_step <= 0;
                carry <= 0;
            end else if (accept) begin
                stat_step <= 1;
                stat_channel <= selected_channel[4:0];
                stat_base <= selected_channel * 5;
                value <= selected_acc >>> STAT_SHIFT;
                stat_initialized <= initialized[selected_channel];
                carry <= 0;
            end else if (stat_step != 0) begin
                carry <= sum[20];
                stat_step <= stat_step == 5 ? 0 : stat_step + 1'b1;
            end
            if (capturing && selected_valid && !frame_abort) begin
                if (accept) sample_count <= sample_count + 1'b1;
                else error <= 1;
            end
            if (commit) initialized[stat_channel] <= 1;
            if (arm) begin
                armed <= 1;
                done <= 0;
                error <= 0;
                channel_count <= arm_channels;
                pixel_count <= arm_pixels;
                case (arm_channels)
                    8: expected_samples <= CW'(arm_pixels) << 3;
                    16: expected_samples <= CW'(arm_pixels) << 4;
                    default: expected_samples <= CW'(arm_pixels) << 5;
                endcase
            end
            if (frame_start && armed) begin
                armed <= 0;
                capturing <= 1;
                done <= 0;
                held <= 1;
                initialized <= 0;
                sample_count <= 0;
                sample_frame <= frame_number + 1'b1;
            end
            if (frame_end && capturing) begin
                capturing <= 0;
                drain <= 6;
                done_time <= time_us;
            end
            if (drain != 0) begin
                drain <= drain - 1'b1;
                if (drain == 1) begin
                    done <= sample_count == expected_samples && complete_channels && !error;
                    if (sample_count != expected_samples || !complete_channels) error <= 1;
                end
            end
            if (release_snapshot) begin held <= 0; done <= 0; end
            if (cancel) begin
                drain <= 0;
                stat_step <= 0;
                carry <= 0;
                armed <= 0;
                held <= 0;
                done <= 0;
                error <= 0;
                initialized <= 0;
            end
            // 已冻结的完整快照不受随后视频帧或无关弃帧影响。
            if (frame_abort && (armed || capturing || drain != 0)) begin
                capturing <= 0;
                done <= 0;
                armed <= 0;
                held <= 0;
                drain <= 0;
                initialized <= 0;
                error <= 1;
            end
        end
    end
endmodule
