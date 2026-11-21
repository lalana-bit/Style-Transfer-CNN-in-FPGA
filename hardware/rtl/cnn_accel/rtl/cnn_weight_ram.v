// 权重存储：10 位窄写、20 位宽读 RAM，以及成对和多通道权重组。
`timescale 1ns/1ps

// 用途：提供权重及紧凑量化参数使用的非对称 RAM，支持 10 位窄写和 20 位宽读。
// 原理：用 half 选择宽字中的前后半字；按深度划分 RAM10 存储组，寄存读组号后选出对应宽字。
module cnn_weight_ram #(
    parameter integer AW = 10,
    parameter integer DEPTH = 576
) (
    input clk,
    input we,
    input half,
    input [AW - 1:0] wa,
    input [AW - 1:0] ra,
    input [9:0] din,
    output [19:0] dout
);

`ifdef USE_EFX_RAM10
    localparam integer BANKS = (DEPTH + 511) / 512;
    localparam integer BW = (BANKS < 2) ? 1:$clog2(BANKS);
    wire [BANKS * 20 - 1:0] words;
    wire [AW + 8:0] write_ext = wa;
    wire [AW + 8:0] read_ext = ra;
    reg [BW - 1:0] read_bank;

    always @(posedge clk) read_bank <= read_ext >> 9;
    genvar rb;

    generate
        for (rb = 0; rb < BANKS; rb = rb + 1) begin : g_bank
            // 每块512个宽字；窄写地址最低位选择该宽字的前/后10bit。
            EFX_RAM10 #(
                .WRITE_WIDTH(10),
                .READ_WIDTH(20),
                .OUTPUT_REG(0),
                .WRITE_MODE("READ_FIRST")
            ) u_ram (
                .WCLK(clk),
                .WCLKE(1'b1),
                .WADDREN(1'b1),
                .WE({ 2 { we && (write_ext >> 9) == rb } }),
                .WADDR({ write_ext [8:0], half }),
                .WDATA(din),
                .RCLK(clk),
                .RE(1'b1),
                .RADDREN(1'b1),
                .RST(1'b0),
                .RADDR(read_ext [8:0]),
                .RDATA(words [rb * 20+:20])
            );

        end
    endgenerate
    assign dout = words [read_bank * 20+:20];
`else
    reg [19:0] mem [0:DEPTH - 1];
    reg [19:0] rq;

    always @(posedge clk) begin
        if (we) begin
            if (half) mem [wa] [19:10] <= din;
            else mem [wa] [9:0] <= din;
        end
        rq <= mem [ra];
    end
    assign dout = rq;
`endif
endmodule

// 用途：将两个 8 位权重打包存储，并以 16 位成对读出，供分组乘加使用。
// 原理：复用非对称权重 RAM，每个权重补两位后写入一个半字，读出时去掉补位；暂停读取时保持读地址。
module cnn_weight_pair #(
    parameter DEPTH = 72,
    parameter AW = $clog2(DEPTH)
) (
    input clk,
    input we,
    input half,
    input re,
    input [AW - 1:0] wa,
    input [AW - 1:0] ra,
    input [7:0] din,
    output [15:0] rdata
);

    generate if (DEPTH==144) begin : g_small_dw
        // 逐通道权重每个字节链均按地址升序装载，完整保留一拍同步读。
        cnn_weight_rows #(
            .LANES(2),
            .LOAD_GROUPS(1),
            .DEPTH(DEPTH),
            .AW(AW)
        ) storage(
            .clk(clk),
            .we(we),
            .re(re),
            .lane({4'd0,half}),
            .wa(wa),
            .ra(ra),
            .din(din),
            .rdata(rdata)
        );
    end else begin : g_bram
    wire [19:0] q;
    reg [AW - 1:0] held_ra;

    always @(posedge clk) if (re) held_ra <= ra;
    cnn_weight_ram #(
        .AW(AW),
        .DEPTH(DEPTH)
    ) u_ram (
        .clk(clk),
        .we(we),
        .half(half),
        .wa(wa),
        .ra(re ? ra:held_ra),
        .din({ 2'b0, din }),
        .dout(q)
    );

    assign rdata = { q [17:10], q [7:0] };
    end endgenerate
endmodule

// 用途：按计算通道并行提供一整组权重，支持扫描总线逐字节装载。
// 原理：深表按通道分银行，浅表按原扫描顺序装入字节SRL；同步读出所需权重向量。
module cnn_weight_rows #(
    parameter LANES = 8,
    parameter integer LOAD_GROUPS = 0,
    parameter DEPTH = 144,
    parameter AW = $clog2(DEPTH)
) (
    input clk,
    input we,
    input re,
    input [4:0] lane,
    input [AW - 1:0] wa,
    input [AW - 1:0] ra,
    input [7:0] din,
    output [LANES * 8 - 1:0] rdata
);

    generate if (LOAD_GROUPS > 0 && (DEPTH <= 36 || (LANES==2 && DEPTH==144) || (LANES==1 && (DEPTH==128 || DEPTH==256)))) begin : g_small
        // 浅权重表按已有 CO/CI/K 扫描顺序装入独立字节 SRL。
        // 存储顺序为输出组优先，读取时恢复原 MAC 地址；一拍读延迟与原 RAM 相同。
        localparam integer INPUTS = DEPTH / LOAD_GROUPS;
        reg [AW-1:0] held_ra;
        wire [AW-1:0] logical_ra = ra;
        wire [AW-1:0] physical_ra = DEPTH-1-((logical_ra % LOAD_GROUPS)*INPUTS + logical_ra/LOAD_GROUPS);
        always @(posedge clk) if (re) held_ra <= ra;
        genvar lane_index;
        for (lane_index=0; lane_index<LANES; lane_index=lane_index+1) begin : g_lane
            reg [7:0] q;
`ifdef USE_EFX_RAM10
            // 显式串联 SRL8，避免工具对非二次幂深度自动提取时的异常。
            localparam integer SEGMENTS=(DEPTH+7)/8;
            wire [SEGMENTS*8-1:0] taps;
            wire [SEGMENTS*8-1:0] chain;
            genvar segment,bit_index;
            for(segment=0;segment<SEGMENTS;segment=segment+1)begin : g_segment
                for(bit_index=0;bit_index<8;bit_index=bit_index+1)begin : g_bit
                    wire input_bit;
                    if(segment==0)assign input_bit=din[bit_index];
                    else assign input_bit=chain[(segment-1)*8+bit_index];
                    EFX_SRL8 shift(
                        .CLK(clk),
                        .CE(we && lane==lane_index),
                        .D(input_bit),
                        .A(~physical_ra[2:0]),
                        .Q(taps[segment*8+bit_index]),
                        .Q7(chain[segment*8+bit_index])
                    );
                end
            end
            // 原语 Q 输出取反，地址也按原语定义取反；对外仍是普通正逻辑同步读。
            always @(posedge clk) if(re) q<=~taps[(physical_ra>>3)*8+:8];
`else
            reg [7:0] bytes [0:DEPTH-1];
            integer index;
            always @(posedge clk) begin
                if (we && lane==lane_index) begin
                    for (index=DEPTH-1; index>0; index=index-1) bytes[index] <= bytes[index-1];
                    bytes[0] <= din;
                end
                if(re) q <= bytes[physical_ra];
            end
`endif
            assign rdata[lane_index*8+:8] = q;
`ifndef SYNTHESIS
            integer load_position=0;
            always @(posedge clk) if (we && lane==lane_index) begin
                if (wa !== AW'((load_position % INPUTS)*LOAD_GROUPS + load_position/INPUTS))
                    $fatal(1,"Small weight load order mismatch lane=%0d index=%0d address=%0d",lane_index,load_position,wa);
                load_position = (load_position==DEPTH-1) ? 0 : load_position+1;
            end
`endif
        end
    end else begin : g_bram
    reg [AW - 1:0] held_ra;

    always @(posedge clk) if (re) held_ra <= ra;
    genvar b;

        for (b = 0; b < (LANES + 1) / 2; b = b + 1) begin : g_bank
            wire [19:0] q;
            cnn_weight_ram #(
                .AW(AW),
                .DEPTH(DEPTH)
            ) mem (
                .clk(clk),
                .we(we && lane / 2 == b),
                .half(lane [0]),
                .wa(wa),
                .ra(re ? ra:held_ra),
                .din({ 2'b0, din }),
                .dout(q)
            );

            assign rdata [(2 * b) * 8+:8] = q [7:0];
            if (2 * b + 1 < LANES) assign rdata [(2 * b + 1) * 8+:8] = q [17:10];
        end
    end endgenerate
endmodule

// 用途：将多层 DW 的浅权重表合并，降低并行读口造成的 RAM 空洞。
// 原理：固定轮询各层的读时隙，窗口通过 ready/valid 等待；每个发起的样本仍执行完整 MAC。
module cnn_dw_weight_store #(
    parameter integer CLIENTS=4
)(
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire [CLIENTS-1:0] write_valid,
    input wire [CLIENTS*8-1:0] write_address,
    input wire [CLIENTS-1:0] write_half,
    input wire [CLIENTS*8-1:0] write_data,
    input wire [CLIENTS-1:0] read_valid,
    input wire [CLIENTS*8-1:0] read_address,
    output wire [CLIENTS-1:0] read_ready,
    output reg [CLIENTS-1:0] response_valid,
    output wire [15:0] response_data
);
    localparam integer CW=$clog2(CLIENTS);
    localparam integer DEPTH=CLIENTS*144;
    localparam integer AW=$clog2(DEPTH);
    reg [CW-1:0] phase;
    wire [CLIENTS-1:0] grant;
    reg [AW-1:0] wa;
    reg [AW-1:0] ra;
    reg half;
    reg [7:0] wd;
    wire [19:0] rq;
    genvar g;
    generate for(g=0;g<CLIENTS;g=g+1)begin : g_slot
        assign read_ready[g]=!clear && phase==g;
        assign grant[g]=read_ready[g] && read_valid[g];
    end endgenerate
    integer i;
    always @* begin
        wa = 0;
        ra = 0;
        half = 0;
        wd = 0;
        for(i=0;i<CLIENTS;i=i+1)begin
            wa=wa | ((i*144+write_address[i*8+:8]) & {AW{write_valid[i]}});
            ra=ra | ((i*144+read_address[i*8+:8]) & {AW{grant[i]}});
            half=half | (write_half[i] && write_valid[i]);
            wd=wd | (write_data[i*8+:8] & {8{write_valid[i]}});
        end
    end
    cnn_weight_ram #(
        .AW(AW),
        .DEPTH(DEPTH)
    ) storage(
        .clk(clk),
        .we(|write_valid),
        .half(half),
        .wa(wa),
        .ra(ra),
        .din({2'b0,wd}),
        .dout(rq)
    );
    assign response_data={rq[17:10],rq[7:0]};
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin phase<=0;response_valid<=0;end
        else if(clear)begin phase<=0;response_valid<=0;end
        else begin phase<=phase==CLIENTS-1 ? 0 : phase+1'b1;response_valid<=grant;end
    end
`ifndef SYNTHESIS
    integer writers;
    always @(posedge clk)if(rst_n)begin
        writers=0;
        for(integer c=0;c<CLIENTS;c=c+1)begin
            if(write_valid[c])begin
                writers=writers+1;
                if(write_address[c*8+:8]>=144)$fatal(1,"Shared DW write address out of range");
            end
            if(grant[c] && read_address[c*8+:8]>=144)$fatal(1,"Shared DW read address out of range");
        end
        if(writers>1)$fatal(1,"Shared DW write collision");
    end
`endif
endmodule

// 用途：集中存放四个标准卷积每银行最后128条双权重。
// 原理：轮转优先级只仲裁尾部请求；主表读取不竞争，响应同时提供客户端标签。
module cnn_tail_store (
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire [3:0] write_valid,
    input wire [19:0] write_lane,
    input wire [27:0] write_address,
    input wire [31:0] write_data,
    input wire [3:0] read_valid,
    input wire [27:0] read_address,
    output wire [3:0] read_ready,
    output reg [3:0] response_valid,
    output wire [63:0] response_data
);
    reg [1:0] priority_start;
    reg [3:0] grant;
    reg [1:0] selected;
    reg found;
    integer offset;
    integer index;
    always @* begin
        grant = 0;
        selected = 0;
        found = 0;
        for (offset=0; offset<4; offset=offset+1) begin
            index = (priority_start+offset)%4;
            if (!found && read_valid[index]) begin
                grant[index] = 1;
                selected = index;
                found = 1;
            end
        end
    end
    assign read_ready = clear ? 4'd0 : grant;
    wire [3:0] read_grant = read_ready & read_valid;
    reg [8:0] wa;
    reg [4:0] wl;
    reg [7:0] wd;
    integer i;
    always @* begin
        wa = 0;
        wl = 0;
        wd = 0;
        for (i=0; i<4; i=i+1) if (write_valid[i]) begin
            wa = i*128+write_address[i*7+:7];
            wl = write_lane[i*5+:5];
            wd = write_data[i*8+:8];
        end
    end
    wire [8:0] ra = {selected, read_address[selected*7+:7]};
    genvar bank;
    generate for (bank=0; bank<4; bank=bank+1) begin : g_bank
        wire [19:0] q;
        cnn_weight_ram #(
            .AW(9),
            .DEPTH(512)
        ) memory (
            .clk(clk),
            .we((|write_valid) && wl/2==bank),
            .half(wl[0]),
            .wa(wa),
            .ra(ra),
            .din({2'b0, wd}),
            .dout(q)
        );
        assign response_data[bank*16+:16] = {q[17:10], q[7:0]};
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            priority_start <= 0;
            response_valid <= 0;
        end else if (clear) begin
            priority_start <= 0;
            response_valid <= 0;
        end else begin
            response_valid <= read_grant;
            if (|read_grant) priority_start <= selected+1'b1;
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n && (write_valid & (write_valid-1'b1)) != 0)
        $fatal(1, "Tail weight writers collide");
`endif
endmodule
