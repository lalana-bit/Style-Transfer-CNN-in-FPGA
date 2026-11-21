`timescale 1ns/1ps
// Dual-clock RAM, binary local pointers and two-flop Gray-pointer crossings.
// DEPTH must be a power of two, >= 4. Registered read data, no memory reset.
module cnn_pixel_async_fifo #(
 parameter WIDTH=27, DEPTH=2048, AW=$clog2(DEPTH)
)(
 input wire wr_clk,wr_rst_n,wr_en,
 input wire [WIDTH-1:0] wr_data,
 output reg full,
 output wire [AW:0] wr_usedw,
 input wire rd_clk,rd_rst_n,rd_en,
 output reg [WIDTH-1:0] rd_data,
 output reg empty,
 output wire [AW:0] rd_usedw
);
reg [WIDTH-1:0] mem [0:DEPTH-1];
reg [AW:0] wb,wg,rb,rg;
(* async_reg="true" *) reg [AW:0] rg_w0,rg_w1,wg_r0,wg_r1;
wire [AW:0] wn=wb+(wr_en && !full);
wire [AW:0] rn=rb+(rd_en && !empty);
wire [AW:0] wgn=(wn>>1)^wn, rgn=(rn>>1)^rn;
function [AW:0] gray_to_bin(input [AW:0] g);
 integer k;
 begin gray_to_bin[AW]=g[AW];
  for(k=AW-1;k>=0;k=k-1) gray_to_bin[k]=gray_to_bin[k+1]^g[k];
 end
endfunction
assign wr_usedw=wb-gray_to_bin(rg_w1);
assign rd_usedw=gray_to_bin(wg_r1)-rb;
always @(posedge wr_clk or negedge wr_rst_n)
 if(!wr_rst_n) begin wb<=0;wg<=0;full<=0;rg_w0<=0;rg_w1<=0;end
 else begin
  rg_w0<=rg;rg_w1<=rg_w0;wb<=wn;wg<=wgn;
  full<=(wgn=={~rg_w1[AW:AW-1],rg_w1[AW-2:0]});
 end
always @(posedge wr_clk)
 if(wr_rst_n && wr_en && !full) mem[wb[AW-1:0]]<=wr_data;
always @(posedge rd_clk or negedge rd_rst_n)
 if(!rd_rst_n) begin rb<=0;rg<=0;empty<=1;wg_r0<=0;wg_r1<=0;end
 else begin
  wg_r0<=wg;wg_r1<=wg_r0;rb<=rn;rg<=rgn;empty<=(rgn==wg_r1);
 end
always @(posedge rd_clk)
 if(rd_rst_n && rd_en && !empty) rd_data<=mem[rb[AW-1:0]];
endmodule
