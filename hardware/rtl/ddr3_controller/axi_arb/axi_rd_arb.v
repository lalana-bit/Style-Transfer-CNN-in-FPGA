`timescale 1ns / 1ps
// Three-master AXI read arbiter: priority m0 > m1 > m2, fixed IDs 0/1/2.
// In this project m0 is HDMI scanout, m1 is the input framebuffer, and m2
// is the reserved weight reader. Responses route per beat by RID; each
// master must observe AXI VALID/payload stability and its own RREADY.
// HOLD_ON_STALL=1 locks a selected AR until accepted, preventing a newly
// arriving higher-priority request from changing a stalled AXI address.
// Arbitration resumes at the next address transaction (not each R beat).
// This option adds four flops, no extra data-path latency; connect clk/rst_n.
// Default 0 preserves the original combinational interface for old callers.
// R routing stays combinational, supports different IDs outstanding, and
// drains unknown IDs. Unused masters: ARVALID=0, RREADY=1.
// Pure RTL; all AXI signals and the optional lock use the same core clock.
module axi_rd_arb #(
    parameter integer AXI_ID_W   = 4,     // = ddr3_parameter.vh 的 AXI_ID_WIDTH
    parameter integer AXI_ADDR_W = 32,    // = AXI_ADDR_WIDTH
    parameter integer AXI_DATA_W = 128,   // = AXI_DATA_WIDTH
    parameter integer M0_ID      = 0,     // m0 分配的 arid (HDMI读)
    parameter integer M1_ID      = 1,     // m1 分配的 arid (CNN输入读)
    parameter integer M2_ID      = 2, // m2 分配的 arid (权重读)
    parameter integer HOLD_ON_STALL = 0
 )(
    //==================== slave侧: 接 ddr3_top 的 AR/R ====================//
    output wire [AXI_ID_W-1:0]   s_arid,
    output wire [AXI_ADDR_W-1:0] s_araddr,
    output wire [7:0]            s_arlen,
    output wire [2:0]            s_arsize,
    output wire [1:0]            s_arburst,
    output wire                  s_arlock,
    output wire [3:0]            s_arcache,
    output wire [2:0]            s_arprot,
    output wire                  s_arvalid,
    input  wire                  s_arready,

    input  wire [AXI_ID_W-1:0]   s_rid,
    input  wire [AXI_DATA_W-1:0] s_rdata,
    input  wire [1:0]            s_rresp,
    input  wire                  s_rlast,
    input  wire                  s_rvalid,
    output wire                  s_rready,

    //==================== m0: 最高优先级 (HDMI 显示读) ====================//
    input  wire                  m0_arvalid,
    input  wire [AXI_ADDR_W-1:0] m0_araddr,
    input  wire [7:0]            m0_arlen,
    input  wire [2:0]            m0_arsize,
    input  wire [1:0]            m0_arburst,
    input  wire                  m0_arlock,
    input  wire [3:0]            m0_arcache,
    input  wire [2:0]            m0_arprot,
    output wire                  m0_arready,

    output wire                  m0_rvalid,
    output wire [AXI_ID_W-1:0]   m0_rid,
    output wire [AXI_DATA_W-1:0] m0_rdata,
    output wire [1:0]            m0_rresp,
    output wire                  m0_rlast,
    input  wire                  m0_rready,

    //==================== m1: 中优先级 (CNN 输入读) ====================//
    input  wire                  m1_arvalid,
    input  wire [AXI_ADDR_W-1:0] m1_araddr,
    input  wire [7:0]            m1_arlen,
    input  wire [2:0]            m1_arsize,
    input  wire [1:0]            m1_arburst,
    input  wire                  m1_arlock,
    input  wire [3:0]            m1_arcache,
    input  wire [2:0]            m1_arprot,
    output wire                  m1_arready,

    output wire                  m1_rvalid,
    output wire [AXI_ID_W-1:0]   m1_rid,
    output wire [AXI_DATA_W-1:0] m1_rdata,
    output wire [1:0]            m1_rresp,
    output wire                  m1_rlast,
    input  wire                  m1_rready,

    //==================== m2: 最低优先级 (权重读) ====================//
    input  wire                  m2_arvalid,
    input  wire [AXI_ADDR_W-1:0] m2_araddr,
    input  wire [7:0]            m2_arlen,
    input  wire [2:0]            m2_arsize,
    input  wire [1:0]            m2_arburst,
    input  wire                  m2_arlock,
    input  wire [3:0]            m2_arcache,
    input  wire [2:0]            m2_arprot,
    output wire                  m2_arready,

    output wire                  m2_rvalid,
    output wire [AXI_ID_W-1:0]   m2_rid,
    output wire [AXI_DATA_W-1:0] m2_rdata,
    output wire [1:0]            m2_rresp,
    output wire                  m2_rlast,
    input  wire                  m2_rready,
    input wire clk, rst_n // used only when HOLD_ON_STALL=1; appended for reuse
);

    //==================== ID 常量 ====================//
    localparam [AXI_ID_W-1:0] ID0 = M0_ID;
    localparam [AXI_ID_W-1:0] ID1 = M1_ID;
    localparam [AXI_ID_W-1:0] ID2 = M2_ID;

    //==================== AR 通道: 固定优先级 ====================//
    // 每拍组合裁决: m0请求则授予m0, 否则m1, 否则m2。
    // 高优先级master的下一次AR可立即插队(等价于突发边界抢占)。
    wire [2:0] normal_grant={~m0_arvalid & ~m1_arvalid & m2_arvalid,
                              ~m0_arvalid & m1_arvalid,m0_arvalid};
    wire [2:0] priority_grant;
    wire [2:0] grant;
    generate if(HOLD_ON_STALL) begin : held_address
        reg locked;
        reg [2:0] held;
        // 图像两路仍允许并发。权重请求到来时先排空已接收的读事务，
        // 再独占一个短读，直到其 RLAST 握手后才恢复图像读地址。
        // 避免控制器在长图像突发与单拍参数读交界处返回混合的数据拍。
        reg [7:0] outstanding;
        reg weight_active;
        wire address_taken = s_arvalid && s_arready;
        wire response_done = s_rvalid && s_rready && s_rlast;
        assign priority_grant = weight_active ? 3'b000 :
            (m2_arvalid ? ((outstanding == 0) ? 3'b100 : 3'b000) : normal_grant);
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                outstanding <= 0;
                weight_active <= 0;
            end else begin
                case ({address_taken, response_done})
                    2'b10: outstanding <= outstanding + 1'b1;
                    2'b01: outstanding <= outstanding - 1'b1;
                    default: begin end
                endcase
                if (address_taken && s_arid == ID2) weight_active <= 1;
                if (response_done && s_rid == ID2) weight_active <= 0;
            end
        end
`ifndef SYNTHESIS
        always @(posedge clk) if (rst_n) begin
            if (response_done && outstanding == 0 && !address_taken)
                $fatal(1, "AXI read response without outstanding address");
            if (address_taken && outstanding == 255 && !response_done)
                $fatal(1, "AXI outstanding counter overflow");
            if (address_taken && s_arid == ID2 && outstanding != 0)
                $fatal(1, "Weight read overlaps image response");
            if (address_taken && weight_active)
                $fatal(1, "Address accepted during isolated weight read");
        end
`endif
        always @(posedge clk or negedge rst_n)
            if(!rst_n) begin locked<=0;held<=0;end
            else if(s_arvalid && s_arready) locked<=0;
            else if(s_arvalid && !s_arready && !locked) begin locked<=1;held<=priority_grant;end
        // AXI VALID/address stay unchanged until the offered AR handshake.
        assign grant=locked ? held : priority_grant;
    end else begin : legacy_combinational
        assign priority_grant=normal_grant;
        assign grant=priority_grant;
    end endgenerate
    wire g0=grant[0],g1=grant[1],g2=grant[2];

    assign s_arvalid = g0 | g1 | g2;
    assign s_arid    = g0 ? ID0 : g1 ? ID1 : ID2;
    assign s_araddr  = g0 ? m0_araddr  : g1 ? m1_araddr  : m2_araddr;
    assign s_arlen   = g0 ? m0_arlen   : g1 ? m1_arlen   : m2_arlen;
    assign s_arsize  = g0 ? m0_arsize  : g1 ? m1_arsize  : m2_arsize;
    assign s_arburst = g0 ? m0_arburst : g1 ? m1_arburst : m2_arburst;
    assign s_arlock  = g0 ? m0_arlock  : g1 ? m1_arlock  : m2_arlock;
    assign s_arcache = g0 ? m0_arcache : g1 ? m1_arcache : m2_arcache;
    assign s_arprot  = g0 ? m0_arprot  : g1 ? m1_arprot  : m2_arprot;

    assign m0_arready = g0 & s_arready;
    assign m1_arready = g1 & s_arready;
    assign m2_arready = g2 & s_arready;

    //==================== R 通道: 按 s_rid 逐拍路由 ====================//
    // AXI允许不同ID的读数据交织返回, 每拍以rid为准分发;
    // 同ID事务内顺序由AXI协议保证, 本模块无需跟踪。
    wire r_own0 = (s_rid == ID0);
    wire r_own1 = (s_rid == ID1);
    wire r_own2 = (s_rid == ID2);

    // valid 门控路由; 数据/属性字段广播(未被选中的一侧valid=0, 数据无意义)
    assign m0_rvalid = s_rvalid & r_own0;
    assign m1_rvalid = s_rvalid & r_own1;
    assign m2_rvalid = s_rvalid & r_own2;

    assign m0_rid    = s_rid;
    assign m1_rid    = s_rid;
    assign m2_rid    = s_rid;
    assign m0_rdata  = s_rdata;
    assign m1_rdata  = s_rdata;
    assign m2_rdata  = s_rdata;
    assign m0_rresp  = s_rresp;
    assign m1_rresp  = s_rresp;
    assign m2_rresp  = s_rresp;
    assign m0_rlast  = s_rlast;
    assign m1_rlast  = s_rlast;
    assign m2_rlast  = s_rlast;

    // rready 取自当前数据归属的master; 未知ID丢弃(防死锁)
    assign s_rready = r_own0 ? m0_rready :
                      r_own1 ? m1_rready :
                      r_own2 ? m2_rready : 1'b1;

endmodule
