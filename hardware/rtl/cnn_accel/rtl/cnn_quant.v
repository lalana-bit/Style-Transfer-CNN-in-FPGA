// 逐通道整数再量化，支持运行时更新实例归一化系数。
`timescale 1ns/1ps

// 用途：完成逐通道整数再量化，并应用运行时更新的实例归一化仿射系数。
// 原理：训练格式下计算加偏置、乘系数、移位、最近偶数舍入及饱和输出；IN 系数写入备用区，在本层帧边界切换。
module cnn_quant #(
    parameter integer TRAINED_FORMAT = 0,
    parameter integer SHARED_ARITH = 0,
    parameter integer SHARED_PARAMS = 0,
    // 卷积项数仅用于内部精确位宽推导；0保留通用接口的完整计算范围。
    parameter integer MAC_TERMS = 0,
    parameter integer H_DISP = 1,
    parameter integer IN_ADAPTIVE = 0,
    parameter integer STREAM_INPUT = 0,
    // 窄通道 ready/valid 流接口；原向量接口保持兼容
    parameter integer SHIFT_BASE = 38,
    parameter integer SHIFT_SPAN = 2,
    parameter integer SIGNED_OUTPUT = 0,
    parameter integer SIGNED_SECOND_HALF = 0,
    parameter integer CH = 8,
    // 通道数（cnn_affine 逐点，IC=OC=CH）
    parameter integer DATA_WIDTH = 9,
    // 每通道输入/输出位宽（有符号）
    parameter integer OUTPUT_WIDTH = DATA_WIDTH,
    parameter integer COEF_WIDTH = 16,
    // 系数 A 位宽（Q0.8）
    parameter integer BIAS_WIDTH = 32,
    // 偏置 b 位宽（Q0.8）
    parameter integer SHIFT = 8,
    // BN 去量化移位
    parameter integer SERIAL = 0,
    // 1=一套乘加流水按通道复用，输入间隔须>=CH+4
    parameter integer PARAM_RAM = 0,
    // 串行模式：独立同步RAM存A/B，预取保持原流水延迟
    parameter integer ENABLE_ABORT = 0
) (
    input clk,
    input rst_n,
    // ---- A 参数扫描链 ----
    input a_shift,
    input signed [COEF_WIDTH - 1:0] a_chain_in,
    output signed [COEF_WIDTH - 1:0] a_chain_out,
    output a_loaded,
    // ---- b 参数扫描链 ----
    input b_shift,
    input signed [BIAS_WIDTH - 1:0] b_chain_in,
    output signed [BIAS_WIDTH - 1:0] b_chain_out,
    output b_loaded,
    // ---- 两链均就绪 ----
    output bn_loaded,
    // ---- 稀疏像素流 ----
    input pre_img_vsync,
    input pre_img_href,
    input pre_img_clken,
    input signed [CH * DATA_WIDTH - 1:0] pre_img_data,
    output post_img_vsync,
    output post_img_href,
    output post_img_valid,
    output signed [CH * OUTPUT_WIDTH - 1:0] post_img_data,
    input frame_abort,
    output o_input_overflow,
    output o_frame_abort,
    output o_stream_ready,
    input in_cfg_we,
    input [7:0] in_cfg_channel,
    input signed [19:0] in_cfg_bias,
    input [30:0] in_cfg_multiplier,
    input [5:0] in_cfg_shift,
    output in_stat_valid,
    output [23:0] in_stat_acc,
    output [7:0] in_stat_channel,
    output wire q_request_valid,
    output wire [60:0] q_request_data,
    input wire q_request_ready,
    input wire q_response_valid,
    input wire [8:0] q_response_data,
    output wire p_write_valid,
    output wire [6:0] p_write_address,
    output wire [1:0] p_write_field,
    output wire [19:0] p_write_data,
    output wire p_read_valid,
    output wire [6:0] p_read_address,
    input wire p_read_ready,
    input wire p_response_valid,
    input wire [59:0] p_response_data
);

    generate
        if (TRAINED_FORMAT) begin : g_trained
            localparam integer CW = (CH < 2) ? 1:$clog2(CH);
            // A 参数链：每个通道依次为 32 位 bias、multiplier、shift。
            // B 参数链：本层的 32 位 qmin、qmax、ReLU6 上限。
            localparam integer SHIFT_W = (SHIFT_SPAN < 1) ? 1:$clog2(SHIFT_SPAN + 1);
            localparam integer PARAM_W = 47 + ((SHIFT_SPAN == 0) ? 0:SHIFT_W);
            // 每通道三个不超过 20 位的参数字共用一块 RAM10，
            // 避免使用 47～49 位的浅宽表；读取仍使用原有状态时序。
            localparam integer PAW = $clog2(6 * CH);
            // 完整通道组先写入尚未生效的紧凑参数区。
            // 输出仅三通道的静态参数表用小寄存器表，避免不到200位数据独占 RAM。
            localparam PARAM_STYLE = (!IN_ADAPTIVE && CH<=3) ? "registers" : "block_ram";
            (* syn_ramstyle=PARAM_STYLE *)
            reg [19:0] params [0:6 * CH - 1];
            reg [1:0] active_bank;
            reg [1:0] pending_bank;
            // frame_abort 同时作为本层帧头及弃帧时的数据清理脉冲。
            // 只在本层执行数据清理时切换参数区，
            // 有效推理期间保持当前参数区不变。
            // 备用参数区使用独立 RAM 写端口；
            // 保持原有 0～8 状态推理节拍和外部参数格式。
            reg [19:0] params_q;
            reg [19:0] tail_word;
            reg [PAW - 1:0] tail_addr;
            reg [CW-1:0] tail_channel;
            reg tail_pending;
            reg tail_last;
            reg load_complete;
            reg signed [19:0] load_bias;
            reg [14:0] load_multiplier_high;
            reg [30:0] multiplier_q;
            reg [CW - 1:0] load_channel;
            reg [1:0] load_field;
            reg a_ld;
            reg [1:0] dynamic_state;
            reg [7:0] dynamic_channel;
            reg [19:0] dynamic_bias;
            reg [30:0] dynamic_multiplier;
            reg [3:0] dynamic_shift;

            always @(posedge clk or negedge rst_n) if (! rst_n) begin
                dynamic_state <= 0;
                active_bank <= 0;
                pending_bank <= 0;
            end else if (IN_ADAPTIVE) begin
                if (frame_abort) begin
                    active_bank <= active_bank ^ pending_bank;
                    pending_bank <= 0;
                end
                if (dynamic_state != 0) begin
                    dynamic_state <= dynamic_state == 3 ? 0:dynamic_state + 1'b1;
                    if (dynamic_state == 3 && (dynamic_channel == CH - 1 || (SIGNED_SECOND_HALF && dynamic_channel == CH / 2 - 1))) pending_bank [dynamic_half] <= 1;
                end else if (in_cfg_we && a_ld && ! pending_bank [cfg_half]) begin
                    dynamic_state <= 1;
                    dynamic_channel <= in_cfg_channel;
                    dynamic_bias <= in_cfg_bias;
                    dynamic_multiplier <= in_cfg_multiplier;
                    dynamic_shift <= in_cfg_shift - 32;
                end
            end
            wire [SHIFT_W - 1:0] load_shift = a_chain_in [5:0] - SHIFT_BASE;
            wire param_take = a_shift && ! a_ld && ! load_complete;
            wire param_we = tail_pending || (param_take && load_field != 0);
            wire [PAW - 1:0] param_wa = tail_pending ? tail_addr:load_channel * 3 + load_field;
            wire [19:0] param_wd = tail_pending ? tail_word:((load_field == 1) ? { 4'd0, a_chain_in [15:0] }:{ { (5 - SHIFT_W) { 1'b0 } }, load_shift, load_multiplier_high });
            wire dynamic_we = IN_ADAPTIVE && dynamic_state != 0;
            wire dynamic_half = SIGNED_SECOND_HALF && dynamic_channel >= CH / 2;
            wire cfg_half = SIGNED_SECOND_HALF && in_cfg_channel >= CH / 2;
            wire [PAW - 1:0] combined_wa = dynamic_we ? dynamic_channel * 3 + dynamic_state - 1 + ((! active_bank [dynamic_half]) ? 3 * CH:0):param_wa;
            wire [19:0] combined_wd = dynamic_we ? (dynamic_state == 1 ? dynamic_bias:(dynamic_state == 2 ? { 4'd0, dynamic_multiplier [15:0] }:{ 1'b0, dynamic_shift, dynamic_multiplier [30:16] })):param_wd;

            always @(posedge clk) begin
                if (!SHARED_PARAMS && (dynamic_we || param_we)) params [combined_wa] <= combined_wd;
                if (param_take) case (load_field)
                    0:load_bias <= a_chain_in [19:0];
                    1:load_multiplier_high <= a_chain_in [30:16];
                    2:begin
                        tail_word <= load_bias;
                        tail_addr <= load_channel * 3;
                        tail_channel <= load_channel;
                    end
                endcase
            end

            always @(posedge clk or negedge rst_n) begin
                if (! rst_n) begin
                    load_channel <= 0;
                    load_field <= 0;
                    a_ld <= 0;
                    tail_pending <= 0;
                    tail_last <= 0;
                    load_complete <= 0;
                end else begin
                    tail_pending <= param_take && load_field == 2;
                    if (tail_pending && tail_last) a_ld <= 1;
                    if (param_take) begin
                        if (load_field == 2) begin
                            load_field <= 0;
                            tail_last <= load_channel == CH - 1;
                            if (load_channel == CH - 1) load_complete <= 1;
                            else load_channel <= load_channel + 1'b1;
                        end else load_field <= load_field + 1'b1;
                    end
                end
            end
            // 导出工具检查固定输出范围，以及所有有效 ReLU6 上限均不小于 127。
            // 扫描镜像保留 B 段以兼容权重格式，运行时无需额外存储。
            assign a_chain_out = a_chain_in;
            assign b_chain_out = b_chain_in;
            assign a_loaded = a_ld;
            assign b_loaded = 1'b1;
            assign bn_loaded = a_ld;
            // 本层只保留参数读取和通道状态，共享模式在状态4发出乘法请求。
            assign q_request_valid = SHARED_ARITH && state == 4 && !frame_abort;
            assign q_request_data = SHARED_ARITH ? {
                (SIGNED_OUTPUT || (SIGNED_SECOND_HALF && channel >= CH/2)),
                negative,params_q[18:15],params_q[14:0],multiplier_q[15:0],
                {{(24-ARITH_W){1'b0}},magnitude}
            } : 61'd0;
            wire response_fault = SHARED_ARITH && state == 8 && !q_response_valid && !frame_abort;
            reg [3:0] state;
            assign o_stream_ready = (state == 0) && ! frame_abort;
            reg [CW - 1:0] channel;
            reg [CH * DATA_WIDTH - 1:0] pixel;
            reg [CH * OUTPUT_WIDTH - 1:0] result;
            // bias仍是完整有符号20位；最坏负值为-N×127×128-2^19。
            // 外部累加值与IN统计接口保留24位，内部再量化不丢失有效位。
            localparam integer NEED_W = (MAC_TERMS > 0) ?
                                       1 + $clog2(MAC_TERMS * 127 * 128 + 524288) : DATA_WIDTH;
            localparam integer ARITH_W = (NEED_W < DATA_WIDTH) ? NEED_W : DATA_WIDTH;
            localparam integer PW = ARITH_W + 31;
            localparam integer RW = PW - SHIFT_BASE + 1;
            reg [ARITH_W - 1:0] magnitude;
            reg [SHIFT_W - 1:0] shift_q;
            reg negative;
            reg [PW - 1:0] product;
            reg result_valid;
            reg overflow;
            reg [$clog2(H_DISP + 1) - 1:0] column;
            wire take = pre_img_href && pre_img_clken;
            assign in_stat_valid = IN_ADAPTIVE && take && state == 0 && ! frame_abort;
            assign in_stat_acc = pre_img_data [23:0];
            assign in_stat_channel = channel;
            wire collision = take && state != 0 && ! frame_abort;
            wire signed [19:0] bias_q = SHARED_PARAMS ? p_response_data[19:0] : params_q[19:0];
            wire [30:0] mult_q = multiplier_q;
            // 每处理一个通道便移位一次向量，避免宽总线的可变选择器。
            wire signed [ARITH_W - 1:0] biased = $signed(pixel [DATA_WIDTH - 1:0]) + bias_q;
            // 使用 DSP 计算完整无符号乘积，
            // 避免共用 16×16 乘法器后再用逻辑拼接四个部分积。
            // 保持 0～8 状态及对外时序不变。

            always @(posedge clk) if (!SHARED_ARITH && state == 5) product <= magnitude * mult_q;
            wire read_half = SIGNED_SECOND_HALF && channel >= CH / 2;
            wire [PAW - 1:0] param_ra = channel * 3 + ((state == 2) ? 1:((state == 3) ? 2:0)) + ((IN_ADAPTIVE && active_bank [read_half]) ? 3 * CH:0);

            always @(posedge clk) begin
                if (!SHARED_PARAMS && state >= 1 && state <= 3) params_q <= params[param_ra];
                if (SHARED_PARAMS && state == 2) params_q <= p_response_data[59:40];
            end
            // 系数在再量化时隙前三拍读出，保持原来的乘法授权和输出时刻。
            assign p_write_valid = SHARED_PARAMS && (dynamic_we || param_we);
            assign p_write_address = dynamic_we ? dynamic_channel + ((!active_bank[dynamic_half]) ? CH : 0) : (tail_pending ? tail_channel : load_channel);
            assign p_write_field = dynamic_we ? dynamic_state-1'b1 : (tail_pending ? 2'd0 : load_field);
            assign p_write_data = combined_wd;
            assign p_read_valid = SHARED_PARAMS && state == 1 && !frame_abort;
            assign p_read_address = channel + ((IN_ADAPTIVE && active_bank[read_half]) ? CH : 0);
`ifndef SYNTHESIS
            always @(posedge clk) if (rst_n && SHARED_PARAMS && state == 2 && !frame_abort && !p_response_valid)
                $fatal(1,"Shared parameter response missing");
`endif

            always @(posedge clk) begin
                if (!SHARED_PARAMS && state == 3) multiplier_q [15:0] <= params_q [15:0];
                if (!SHARED_PARAMS && state == 4) multiplier_q [30:16] <= params_q [14:0];
                if (SHARED_PARAMS && state == 2) multiplier_q <= {p_response_data[54:40],p_response_data[35:20]};
            end
            // bias 存在第 0 字；shift 使用 multiplier 第 2 字的空余位。

            always @(posedge clk) if (state == 4) begin
                if (SHIFT_SPAN == 0) shift_q <= 0;
                else shift_q <= params_q >> 15;
            end
            // 将可变移位分配到原先空闲的状态 6 和 7。
            // 保留保护位及所有舍弃位的粘滞信息，正确处理恰好位于中点的舍入。
            localparam integer ROUND_SPLIT = ($clog2(SHIFT_SPAN + 1) + 1) / 2;
            reg [RW:0] round_prepared;
            function [RW:0] prepare_round;
                input [PW - 1:0] value;
                input [SHIFT_W - 1:0] offset;
                reg [RW - 1:0] work;
                reg sticky;
                integer bit_index;
                begin
                    work = value [PW - 1:SHIFT_BASE - 1];
                    sticky = | value [SHIFT_BASE - 2:0];
                    for (bit_index = 0; bit_index < ROUND_SPLIT; bit_index = bit_index + 1) if (offset [bit_index]) begin
                        sticky = sticky || (| (work & (({ { (RW - 1) { 1'b0 } }, 1'b1 } << (1 << bit_index)) - 1)));
                        work = work >> (1 << bit_index);
                    end
                    prepare_round = { sticky, work };
                end
            endfunction
            function [RW - 1:0] round_magnitude;
                input [RW:0] prepared;
                input [SHIFT_W - 1:0] offset;
                reg [RW - 1:0] work;
                reg sticky;
                reg [RW - 1:0] quotient;
                integer bit_index;
                begin
                    work = prepared [RW - 1:0];
                    sticky = prepared [RW];
                    for (bit_index = ROUND_SPLIT; bit_index < $clog2(SHIFT_SPAN + 1); bit_index = bit_index + 1) if (offset [bit_index]) begin
                        sticky = sticky || (| (work & (({ { (RW - 1) { 1'b0 } }, 1'b1 } << (1 << bit_index)) - 1)));
                        work = work >> (1 << bit_index);
                    end
                    quotient = { 1'b0, work [RW - 1:1] };
                    if (work [0] && (sticky || work [1])) quotient = quotient + 1'b1;
                    round_magnitude = quotient;
                end
            endfunction
            reg [RW - 1:0] rounded;

            always @(posedge clk) begin
                if (!SHARED_ARITH && state == 6) round_prepared <= prepare_round(product, shift_q);
                if (!SHARED_ARITH && state == 7) rounded <= round_magnitude(round_prepared, shift_q);
            end
            wire [6:0] clipped_magnitude = (rounded > 127) ? 7'd127:rounded [6:0];
            wire [7:0] clipped = negative ? ((SIGNED_OUTPUT || (SIGNED_SECOND_HALF && channel >= CH / 2)) ? - $signed({ 1'b0, clipped_magnitude }):8'd0):{ 1'b0, clipped_magnitude };

            wire [OUTPUT_WIDTH-1:0] result_word = SHARED_ARITH ?
                q_response_data : $signed({clipped[7],clipped});
            always @(posedge clk or negedge rst_n) begin
                if (! rst_n) begin
                    state <= 0;
                    channel <= 0;
                    result_valid <= 0;
                    overflow <= 0;
                    column <= 0;
                end else begin
                    result_valid <= 0;
                    if (frame_abort) begin
                        state <= 0;
                        channel <= 0;
                        column <= 0;
                    end else begin
                        if (result_valid) column <= (column == H_DISP - 1) ? 0:column + 1'b1;
                        if (collision || response_fault) overflow <= 1;
                        if (take && state == 0) begin
                            pixel <= STREAM_INPUT ? { { ((CH - 1) * DATA_WIDTH) { 1'b0 } }, pre_img_data [DATA_WIDTH - 1:0] }:pre_img_data;
                            if (! STREAM_INPUT) channel <= 0;
                            state <= 1;
                        end
                        case (state)
                            1:if (!SHARED_PARAMS || p_read_ready) state <= 2;
                            2:begin
                                magnitude <= biased [ARITH_W - 1] ? - biased:biased;
                                negative <= biased [ARITH_W - 1];
                                pixel <= pixel >> DATA_WIDTH;
                                state <= 3;
                            end
                            3:state <= 4;
                            4:if (!SHARED_ARITH || q_request_ready) state <= 5;
                            5:state <= 6;
                            6:state <= 7;
                            7:state <= 8;
                            8:begin
                                result <= STREAM_INPUT ? { { ((CH - 1) * OUTPUT_WIDTH) { 1'b0 } }, result_word }:(result >> OUTPUT_WIDTH) | ({ { (CH * OUTPUT_WIDTH - OUTPUT_WIDTH) { 1'b0 } }, result_word } << ((CH - 1) * OUTPUT_WIDTH));
                                if (STREAM_INPUT) begin
                                    result_valid <= 1;
                                    state <= 0;
                                    channel <= (channel == CH - 1) ? 0:channel + 1'b1;
                                end else if (channel == CH - 1) begin
                                    result_valid <= 1;
                                    state <= 0;
                                end else begin
                                    channel <= channel + 1'b1;
                                    state <= 1;
                                end
                            end
                        endcase
                    end
                end
            end
`ifndef SYNTHESIS

            always @(posedge clk) if (rst_n && IN_ADAPTIVE && in_cfg_we && (dynamic_state != 0 || pending_bank [cfg_half] || ! a_ld)) $fatal(1, "IN coefficient mailbox overwrite before frame commit");
`endif
            assign post_img_vsync = pre_img_vsync && ! frame_abort;
            assign post_img_href = (column != 0 || result_valid) && ! frame_abort;
            assign post_img_valid = result_valid && ! frame_abort;
            assign post_img_data = result;
            assign o_input_overflow = overflow;
            assign o_frame_abort = frame_abort || collision || response_fault;
`ifndef SYNTHESIS
            initial if (SHARED_ARITH && (!STREAM_INPUT || (ARITH_W>23 && (MAC_TERMS<=0 || MAC_TERMS*127*128+524288>=8388608)) || SHIFT_BASE!=32 || SHIFT_SPAN!=15 || OUTPUT_WIDTH!=9))
                $fatal(1,"unsupported shared quantization format");
            always @(posedge clk) if (rst_n && response_fault)
                $fatal(1,"shared requant response missing or misrouted");
`endif
        end else begin : g_fixed
            assign p_write_valid=0;
            assign p_write_address=0;
            assign p_write_field=0;
            assign p_write_data=0;
            assign p_read_valid=0;
            assign p_read_address=0;
            assign q_request_valid=0;
            assign q_request_data=0;
            assign in_stat_valid = 0;
            assign in_stat_acc = 0;
            assign in_stat_channel = 0;
            assign o_stream_ready = 1'b1;
            //===================================================================
            // [1] A 链加载（升序直写：第 k 拍 -> areg[k]）
            //===================================================================
            reg signed [COEF_WIDTH - 1:0] areg [0:CH - 1];
            reg [$clog2(CH + 1) - 1:0] acnt;
            reg a_ld;
            // 加载计数与参数存储分离：仅复位有效标志，RAM不需要逐字清零。

            always @(posedge clk or negedge rst_n) begin
                if (! rst_n) begin
                    acnt <= 0;
                    a_ld <= 0;
                end else if (a_shift && ! a_ld) begin
                    if (acnt == CH - 1) a_ld <= 1;
                    acnt <= acnt + 1'b1;
                end
            end
            if (! (SERIAL && PARAM_RAM)) begin : g_a_ff
                genvar ca;
                for (ca = 0; ca < CH; ca = ca + 1) begin : g_word

                    always @(posedge clk or negedge rst_n) if (! rst_n) areg [ca] <= 0;
                    else if (a_shift && ! a_ld && acnt == ca) areg [ca] <= a_chain_in;
                end
            end
            assign a_chain_out = a_chain_in;
            // 直通（与 conv 链一致）
            assign a_loaded = a_ld;
            //===================================================================
            // [2] b 链加载（升序直写：第 k 拍 -> breg[k]）
            //===================================================================
            reg signed [BIAS_WIDTH - 1:0] breg [0:CH - 1];
            reg [$clog2(CH + 1) - 1:0] bcnt;
            reg b_ld;

            always @(posedge clk or negedge rst_n) begin
                if (! rst_n) begin
                    bcnt <= 0;
                    b_ld <= 0;
                end else if (b_shift && ! b_ld) begin
                    if (bcnt == CH - 1) b_ld <= 1;
                    bcnt <= bcnt + 1'b1;
                end
            end
            if (! (SERIAL && PARAM_RAM)) begin : g_b_ff
                genvar cb;
                for (cb = 0; cb < CH; cb = cb + 1) begin : g_word

                    always @(posedge clk or negedge rst_n) if (! rst_n) breg [cb] <= 0;
                    else if (b_shift && ! b_ld && bcnt == cb) breg [cb] <= b_chain_in;
                end
            end
            assign b_chain_out = b_chain_in;
            // 直通（与 conv 链一致）
            assign b_loaded = b_ld;
            assign bn_loaded = a_ld & b_ld;
            //===================================================================
            // [3] 逐通道 cnn_affine 例化
            //===================================================================
            wire signed [DATA_WIDTH - 1:0] n_data [0:CH - 1];
            wire [CH - 1:0] n_vsync;
            wire [CH - 1:0] n_href;
            wire [CH - 1:0] n_valid;
            genvar g;
            if (SERIAL) begin : g_serial
                localparam integer CW = (CH < 2) ? 1:$clog2(CH);
                localparam integer LAT = CH + 4;
                localparam integer PW = DATA_WIDTH + COEF_WIDTH;
                localparam integer SW = ((PW > BIAS_WIDTH) ? PW:BIAS_WIDTH) + 1;
                localparam signed [SW - 1:0] MX = (1 << (DATA_WIDTH - 1)) - 1;
                localparam signed [SW - 1:0] MN = - (1 << (DATA_WIDTH - 1));
                wire abort_req = ENABLE_ABORT ? frame_abort:1'b0;
                reg busy;
                reg issuing;
                reg overflow;
                reg [CW - 1:0] channel;
                reg [CW - 1:0] tag0;
                reg [CW - 1:0] tag1;
                reg [CW - 1:0] tag2;
                wire signed [COEF_WIDTH - 1:0] param_a;
                wire signed [BIAS_WIDTH - 1:0] param_b;
                if (PARAM_RAM) begin : g_prefetch
                    // 空闲时预读通道0；发起通道n的同沿预读n+1，无额外输入停顿。
                    wire [CW - 1:0] next_ch = issuing && channel != CH - 1 ? channel + 1'b1:0;
                    cnn_param_ram #(
                        .DW(COEF_WIDTH),
                        .AW(CW),
                        .DEPTH(CH)
                    ) u_a (
                        .clk(clk),
                        .we(a_shift && ! a_ld),
                        .wa(acnt [CW - 1:0]),
                        .din(a_chain_in),
                        .ra(next_ch),
                        .dout(param_a)
                    );

                    cnn_param_ram #(
                        .DW(BIAS_WIDTH),
                        .AW(CW),
                        .DEPTH(CH)
                    ) u_b (
                        .clk(clk),
                        .we(b_shift && ! b_ld),
                        .wa(bcnt [CW - 1:0]),
                        .din(b_chain_in),
                        .ra(next_ch),
                        .dout(param_b)
                    );

                end else begin : g_param_direct
                    assign param_a = areg [channel];
                    assign param_b = breg [channel];
                end
                reg valid0;
                reg valid1;
                reg valid2;
                reg [CH * DATA_WIDTH - 1:0] pixel;
                reg [CH * DATA_WIDTH - 1:0] result;
                reg signed [DATA_WIDTH - 1:0] x0;
                reg signed [COEF_WIDTH - 1:0] a0;
                reg signed [BIAS_WIDTH - 1:0] b0;
                reg signed [BIAS_WIDTH - 1:0] b1;
                reg signed [PW - 1:0] product;
                reg signed [SW - 1:0] sum;
                reg [LAT - 1:0] vs_pipe;
                reg [LAT - 1:0] href_pipe;
                reg output_valid;
                wire take = pre_img_href && pre_img_clken;
                wire collision = take && busy && ! abort_req;
                wire signed [SW - 1:0] shifted = sum >>> SHIFT;
                wire [DATA_WIDTH - 1:0] saturated = (shifted > MX) ? MX [DATA_WIDTH - 1:0]:(shifted < MN) ? MN [DATA_WIDTH - 1:0]:shifted [DATA_WIDTH - 1:0];
                assign o_input_overflow = overflow;
                assign o_frame_abort = abort_req | collision;
                assign post_img_vsync = vs_pipe [LAT - 1] & ~ o_frame_abort;
                assign post_img_href = href_pipe [LAT - 1] & ~ o_frame_abort;
                assign post_img_valid = output_valid & ~ o_frame_abort;
                assign post_img_data = result;
                // 顺序通道天然按0..CH-1输出，移位拼装代替逐通道译码写使能。
                // 无效期间result可变化，valid到达时全部通道已就位；输入gap不变。

                always @(posedge clk) if (valid2 && ! abort_req && ! collision) result <= (result >> DATA_WIDTH) | ({ { (CH * DATA_WIDTH - DATA_WIDTH) { 1'b0 } }, saturated } << ((CH - 1) * DATA_WIDTH));

                always @(posedge clk or negedge rst_n) begin
                    if (! rst_n) begin
                        busy <= 0;
                        issuing <= 0;
                        channel <= 0;
                        valid0 <= 0;
                        valid1 <= 0;
                        valid2 <= 0;
                        vs_pipe <= 0;
                        href_pipe <= 0;
                        output_valid <= 0;
                        overflow <= 0;
                    end else begin
                        if (collision) overflow <= 1;
                        if (abort_req || collision) begin
                            busy <= 0;
                            issuing <= 0;
                            channel <= 0;
                            valid0 <= 0;
                            valid1 <= 0;
                            valid2 <= 0;
                            vs_pipe <= 0;
                            href_pipe <= 0;
                            output_valid <= 0;
                        end else begin
                            vs_pipe <= { vs_pipe [LAT - 2:0], pre_img_vsync };
                            href_pipe <= { href_pipe [LAT - 2:0], pre_img_href };
                            valid0 <= issuing;
                            valid1 <= valid0;
                            valid2 <= valid1;
                            output_valid <= 0;
                            if (take && ! busy) begin
                                pixel <= pre_img_data;
                                busy <= 1;
                                issuing <= 1;
                                channel <= 0;
                            end
                            if (issuing) begin
                                // 选择先寄存，避免通道MUX与DSP乘法处于同一组合路径。
                                x0 <= pixel [DATA_WIDTH - 1:0];
                                pixel <= pixel >> DATA_WIDTH;
                                a0 <= param_a;
                                b0 <= param_b;
                                tag0 <= channel;
                                if (channel == CH - 1) issuing <= 0;
                                else channel <= channel + 1'b1;
                            end
                            if (valid0) begin
                                product <= x0 * a0;
                                b1 <= b0;
                                tag1 <= tag0;
                            end
                            if (valid1) begin
                                sum <= product + b1;
                                tag2 <= tag1;
                            end
                            if (valid2) begin
                                if (tag2 == CH - 1) begin
                                    output_valid <= 1;
                                    busy <= 0;
                                end
                            end
                        end
                    end
                end
            end else begin : g_parallel
                for (g = 0; g < CH; g = g + 1) begin : g_norm
                    cnn_affine #(
                        .DATA_WIDTH(DATA_WIDTH),
                        .COEF_WIDTH(COEF_WIDTH),
                        .BIAS_WIDTH(BIAS_WIDTH),
                        .SHIFT(SHIFT)
                    ) u_norm (
                        .clk(clk),
                        .rst_n(rst_n),
                        .pre_img_vsync(pre_img_vsync),
                        .pre_img_href(pre_img_href),
                        .pre_img_clken(pre_img_clken),
                        .pre_img_data(pre_img_data [g * DATA_WIDTH+:DATA_WIDTH]),
                        .scale_a(areg [g]),
                        .bias_b(breg [g]),
                        .post_img_vsync(n_vsync [g]),
                        .post_img_href(n_href [g]),
                        .post_img_valid(n_valid [g]),
                        .post_img_data(n_data [g])
                    );

                end
                for (g = 0; g < CH; g = g + 1) begin : g_pack
                    assign post_img_data [g * DATA_WIDTH+:DATA_WIDTH] = n_data [g];
                end
                // ---- 控制信号：全通道同源，取 ch0 ----
                assign post_img_vsync = n_vsync [0];
                assign post_img_href = n_href [0];
                assign post_img_valid = n_valid [0];
                assign o_input_overflow = 1'b0;
                assign o_frame_abort = 1'b0;
            end
        end
    endgenerate
endmodule
