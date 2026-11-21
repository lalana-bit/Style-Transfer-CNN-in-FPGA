`timescale 1ns / 1ps
//==================================================================
// AXI4三路写仲裁，单模块实现，沿用原轮询和整事务授权结构。
// m0：输入图像写；m1：CNN图像写；m2：权重写。
// AW背压时保持授权；AW握手后锁定W/B归属，直到B握手。
// 同时只允许一笔在途写事务，完成后从下一路开始公平轮询。
// 未使用的master应将awvalid、wvalid置0，不可悬空。
//==================================================================
module axi_wr_arb #(
    parameter integer AXI_ID_W   = 4,     // = ddr3_parameter.vh 的 AXI_ID_WIDTH
    parameter integer AXI_ADDR_W = 32,    // = AXI_ADDR_WIDTH
    parameter integer AXI_DATA_W = 128,   // = AXI_DATA_WIDTH
    parameter integer M0_ID      = 0,     // m0 分配的 awid (预处理帧写)
    parameter integer M2_ID = 2, // m2: 权重写入
    parameter integer M1_ID      = 1      // m1 分配的 awid (CNN输出写)
)(
    input  wire                  clk,     // core_clk (axi_clk)
    input  wire                  rst_n,   // core_clk 域同步复位(低有效)

    //==================== slave侧: 接 ddr3_top 的 AW/W/B ====================//
    output wire [AXI_ID_W-1:0]   s_awid,
    output wire [AXI_ADDR_W-1:0] s_awaddr,
    output wire [7:0]            s_awlen,
    output wire [2:0]            s_awsize,
    output wire [1:0]            s_awburst,
    output wire                  s_awlock,
    output wire [3:0]            s_awcache,
    output wire [2:0]            s_awprot,
    output wire                  s_awvalid,
    input  wire                  s_awready,

    output wire [AXI_DATA_W-1:0]   s_wdata,
    output wire [AXI_DATA_W/8-1:0] s_wstrb,
    output wire                    s_wlast,
    output wire                    s_wvalid,
    input  wire                    s_wready,

    input  wire [AXI_ID_W-1:0]   s_bid,
    input  wire [1:0]            s_bresp,
    input  wire                  s_bvalid,
    output wire                  s_bready,

    //==================== m0: 预处理帧写 ====================//
    input  wire                  m0_awvalid,
    input  wire [AXI_ADDR_W-1:0] m0_awaddr,
    input  wire [7:0]            m0_awlen,
    input  wire [2:0]            m0_awsize,
    input  wire [1:0]            m0_awburst,
    input  wire                  m0_awlock,
    input  wire [3:0]            m0_awcache,
    input  wire [2:0]            m0_awprot,
    output wire                  m0_awready,

    input  wire                  m0_wvalid,
    input  wire [AXI_DATA_W-1:0] m0_wdata,
    input  wire [AXI_DATA_W/8-1:0] m0_wstrb,
    input  wire                  m0_wlast,
    output wire                  m0_wready,

    output wire                  m0_bvalid,
    output wire [AXI_ID_W-1:0]   m0_bid,
    output wire [1:0]            m0_bresp,
    input  wire                  m0_bready,

    //==================== m1: CNN 输出写 ====================//
    input  wire                  m1_awvalid,
    input  wire [AXI_ADDR_W-1:0] m1_awaddr,
    input  wire [7:0]            m1_awlen,
    input  wire [2:0]            m1_awsize,
    input  wire [1:0]            m1_awburst,
    input  wire                  m1_awlock,
    input  wire [3:0]            m1_awcache,
    input  wire [2:0]            m1_awprot,
    output wire                  m1_awready,

    input  wire                  m1_wvalid,
    input  wire [AXI_DATA_W-1:0] m1_wdata,
    input  wire [AXI_DATA_W/8-1:0] m1_wstrb,
    input  wire                  m1_wlast,
    output wire                  m1_wready,

    output wire                  m1_bvalid,
    output wire [AXI_ID_W-1:0]   m1_bid,
    output wire [1:0]            m1_bresp,
    input  wire                  m1_bready,

    //==================== m2: 权重写入 ====================//
    input  wire                  m2_awvalid,
    input  wire [AXI_ADDR_W-1:0] m2_awaddr,
    input  wire [7:0]            m2_awlen,
    input  wire [2:0]            m2_awsize,
    input  wire [1:0]            m2_awburst,
    input  wire                  m2_awlock,
    input  wire [3:0]            m2_awcache,
    input  wire [2:0]            m2_awprot,
    output wire                  m2_awready,

    input  wire                  m2_wvalid,
    input  wire [AXI_DATA_W-1:0] m2_wdata,
    input  wire [AXI_DATA_W/8-1:0] m2_wstrb,
    input  wire                  m2_wlast,
    output wire                  m2_wready,

    output wire                  m2_bvalid,
    output wire [AXI_ID_W-1:0]   m2_bid,
    output wire [1:0]            m2_bresp,
    input  wire                  m2_bready
);

    // 单个在途写事务：AW握手锁定归属，直到B握手才释放。
    localparam [AXI_ID_W-1:0] ID0=M0_ID, ID1=M1_ID, ID2=M2_ID;
    reg own_v,aw_hold;
    reg [1:0] own_m,last_m,aw_hold_m;
    reg [1:0] grant;
    wire request=m0_awvalid || m1_awvalid || m2_awvalid;
    // 从上次完成事务的下一路开始扫描，三路持续请求时按0→1→2轮询。
    always @* begin
        grant=0;
        case(last_m)
            0: if(m1_awvalid) grant=1; else if(m2_awvalid) grant=2;
            1: if(m2_awvalid) grant=2; else if(m0_awvalid) grant=0; else grant=1;
            default: if(m0_awvalid) grant=0; else if(m1_awvalid) grant=1; else grant=2;
        endcase
    end
    wire [1:0] selected=aw_hold ? aw_hold_m:grant;
    // AW背压期间保持授权不变；在途期间禁止再次发出AW。
    assign s_awvalid=!own_v && request;
    assign s_awid=selected==0 ? ID0:selected==1 ? ID1:ID2;
    assign s_awaddr=selected==0 ? m0_awaddr:selected==1 ? m1_awaddr:m2_awaddr;
    assign s_awlen=selected==0 ? m0_awlen:selected==1 ? m1_awlen:m2_awlen;
    assign s_awsize=selected==0 ? m0_awsize:selected==1 ? m1_awsize:m2_awsize;
    assign s_awburst=selected==0 ? m0_awburst:selected==1 ? m1_awburst:m2_awburst;
    assign s_awlock=selected==0 ? m0_awlock:selected==1 ? m1_awlock:m2_awlock;
    assign s_awcache=selected==0 ? m0_awcache:selected==1 ? m1_awcache:m2_awcache;
    assign s_awprot=selected==0 ? m0_awprot:selected==1 ? m1_awprot:m2_awprot;
    assign m0_awready=!own_v && selected==0 && s_awready;
    assign m1_awready=!own_v && selected==1 && s_awready;
    assign m2_awready=!own_v && selected==2 && s_awready;

    // W仅允许已握手AW的事务通过，避免AW停顿时出现提前写入。
    assign s_wvalid=own_v && (own_m==0 ? m0_wvalid:own_m==1 ? m1_wvalid:m2_wvalid);
    assign s_wdata=own_m==0 ? m0_wdata:own_m==1 ? m1_wdata:m2_wdata;
    assign s_wstrb=own_m==0 ? m0_wstrb:own_m==1 ? m1_wstrb:m2_wstrb;
    assign s_wlast=own_m==0 ? m0_wlast:own_m==1 ? m1_wlast:m2_wlast;
    assign m0_wready=own_v && own_m==0 && s_wready;
    assign m1_wready=own_v && own_m==1 && s_wready;
    assign m2_wready=own_v && own_m==2 && s_wready;

    // B响应按原始master ID返回；第三路使用独立ID2，不再重映射。
    assign m0_bvalid=own_v && own_m==0 && s_bid==ID0 && s_bvalid;
    assign m0_bid=s_bid;
    assign m0_bresp=s_bresp;
    assign m1_bvalid=own_v && own_m==1 && s_bid==ID1 && s_bvalid;
    assign m1_bid=s_bid;
    assign m1_bresp=s_bresp;
    assign m2_bvalid=own_v && own_m==2 && s_bid==ID2 && s_bvalid;
    assign m2_bid=s_bid;
    assign m2_bresp=s_bresp;
    assign s_bready=own_v && (own_m==0 ? m0_bready:own_m==1 ? m1_bready:m2_bready);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            own_v<=0; own_m<=0; last_m<=2; aw_hold<=0; aw_hold_m<=0;
        end else begin
            if(s_awvalid && s_awready) begin
                own_v<=1; own_m<=selected; aw_hold<=0;
            end else if(s_awvalid && !aw_hold) begin
                aw_hold<=1; aw_hold_m<=grant;
            end
            if(own_v && s_bvalid && s_bready) begin
                own_v<=0; last_m<=own_m;
            end
        end
    end
endmodule
