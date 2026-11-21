`timescale 1ns/1ps
// Continuous data_tx pixels (25 MHz) -> independent CNN stream (225 MHz / DIV_N).
// SOF/EOL/EOF travel with pixels; no signal feeds back into DDR read scheduling.
module cnn_video_async_bridge #(
 parameter VID_WIDTH=24, IMG_W=640, IMG_H=480, DIV_N=9,
 parameter FIFO_DEPTH=2048, ENABLE_READY_GATE=0
)(
 input wire rst_n, wr_clk, i_vs, i_de,
 input wire [VID_WIDTH-1:0] i_data,
 input wire i_source_error, // data_tx underflow, wr_clk domain
 input wire rd_clk, params_ready,
 output reg o_vs, o_href, o_clken,
 output reg [VID_WIDTH-1:0] o_data,
 output reg o_frame_abort, o_underflow,
 output wire o_overflow, o_source_error, // sticky diagnostics, not stop latches
 output wire fifo_full, fifo_empty,
 output wire [$clog2(FIFO_DEPTH):0] wr_usedw, rd_usedw
);
localparam XW=(IMG_W<2)?1:$clog2(IMG_W);
localparam YW=(IMG_H<2)?1:$clog2(IMG_H);
localparam CW=(DIV_N<2)?1:$clog2(DIV_N);
localparam TW=VID_WIDTH+3;
wire wr_rst_n,rd_rst_n;
// Assert immediately even if a clock is stopped; release locally after 3 edges.
(* async_reg="true" *) reg [2:0] wr_rst_pipe=0,rd_rst_pipe=0;
always @(posedge wr_clk or negedge rst_n)
 if(!rst_n) wr_rst_pipe<=0;else wr_rst_pipe<={wr_rst_pipe[1:0],1'b1};
always @(posedge rd_clk or negedge rst_n)
 if(!rst_n) rd_rst_pipe<=0;else rd_rst_pipe<={rd_rst_pipe[1:0],1'b1};
assign wr_rst_n=wr_rst_pipe[2];
assign rd_rst_n=rd_rst_pipe[2];
wire ready_rd=ENABLE_READY_GATE ? params_ready : 1'b1;
(* async_reg="true" *) reg ready_w0,ready_w1;
always @(posedge wr_clk or negedge wr_rst_n)
 if(!wr_rst_n) begin ready_w0<=0;ready_w1<=0;end
 else begin ready_w0<=ready_rd;ready_w1<=ready_w0;end

reg vs_d,capture,sof_pending;
reg [XW-1:0] wx;
reg [YW-1:0] wy;
reg fault_toggle,overflow_w,source_error_w;
wire sof_rise=i_vs & ~vs_d;
wire last_x=(wx==IMG_W-1),last_y=(wy==IMG_H-1);
wire write_pixel=capture && i_de && !fifo_full && !i_source_error && ready_w1 && !sof_rise;
wire [TW-1:0] write_token={sof_pending,last_x,(last_x && last_y),i_data};
always @(posedge wr_clk or negedge wr_rst_n) begin
 if(!wr_rst_n) begin
  vs_d<=0;capture<=0;sof_pending<=0;wx<=0;wy<=0;
  fault_toggle<=0;overflow_w<=0;source_error_w<=0;
 end else begin
  vs_d<=i_vs;
  if(sof_rise) begin
   if(capture && !sof_pending) fault_toggle<=~fault_toggle;
   capture<=ready_w1;sof_pending<=1;wx<=0;wy<=0;
  end else if(capture && (i_source_error || !ready_w1 || (i_de && fifo_full))) begin
   capture<=0;fault_toggle<=~fault_toggle;
   if(i_source_error) source_error_w<=1;
   if(i_de && fifo_full) overflow_w<=1;
  end else if(write_pixel) begin
   sof_pending<=0;
   if(last_x) begin
    wx<=0;
    if(last_y) begin capture<=0;wy<=0;end
    else wy<=wy+1'b1;
   end else wx<=wx+1'b1;
  end
 end
end

wire [TW-1:0] fifo_data;
wire fifo_rden;
cnn_pixel_async_fifo #(.WIDTH(TW),.DEPTH(FIFO_DEPTH)) pixel_fifo (
 .wr_rst_n(wr_rst_n),.wr_clk(wr_clk),.wr_en(write_pixel),.wr_data(write_token),
 .full(fifo_full),.wr_usedw(wr_usedw),.rd_rst_n(rd_rst_n),.rd_clk(rd_clk),.rd_en(fifo_rden),
 .rd_data(fifo_data),.empty(fifo_empty),.rd_usedw(rd_usedw));

(* async_reg="true" *) reg fault_r0,fault_r1,overflow_r0,overflow_r1,error_r0,error_r1;
reg fault_seen,overflow_seen,error_seen;
wire fault_event=(fault_r1 ^ fault_seen) || (overflow_r1 && !overflow_seen) ||
                 (error_r1 && !error_seen);
assign o_overflow=overflow_r1;
assign o_source_error=error_r1;
always @(posedge rd_clk or negedge rd_rst_n) begin
 if(!rd_rst_n) begin
  fault_r0<=0;fault_r1<=0;fault_seen<=0;overflow_seen<=0;error_seen<=0;
  overflow_r0<=0;overflow_r1<=0;error_r0<=0;error_r1<=0;
 end else begin
  fault_r0<=fault_toggle;fault_r1<=fault_r0;fault_seen<=fault_r1;
  overflow_r0<=overflow_w;overflow_r1<=overflow_r0;
  error_r0<=source_error_w;error_r1<=error_r0;
  overflow_seen<=overflow_r1;error_seen<=error_r1;
 end
end

// One-word prefetch; sample Normal FIFO data one cycle after RdEn.
reg rd_pending,hold_valid;
reg [TW-1:0] token;
wire token_sof=token[VID_WIDTH+2],token_eol=token[VID_WIDTH+1],token_eof=token[VID_WIDTH];
localparam SEEK=3'd0,SOF=3'd1,SEND=3'd2,GAP=3'd3,FLUSH=3'd4;
reg [2:0] state;
reg [CW-1:0] cooldown;
reg frame_active,first_pixel,end_frame;
wire discard=hold_valid && ((state==FLUSH) || ((state==SEEK) && (!token_sof || !ready_rd)));
wire emit=(state==SEND) && hold_valid && (cooldown==0) && ready_rd &&
          !(token_sof && !first_pixel) && !fault_event;
wire consume=discard || emit;
assign fifo_rden=rd_rst_n && !fifo_empty && !hold_valid && !rd_pending;
always @(posedge rd_clk or negedge rd_rst_n) begin
 if(!rd_rst_n) begin rd_pending<=0;hold_valid<=0;token<=0;end
 else begin
  rd_pending<=fifo_rden;
  if(rd_pending) begin token<=fifo_data;hold_valid<=1;end
  else if(consume) hold_valid<=0;
 end
end

always @(posedge rd_clk or negedge rd_rst_n) begin
 if(!rd_rst_n) begin
  state<=SEEK;cooldown<=0;frame_active<=0;first_pixel<=0;end_frame<=0;
  o_vs<=0;o_href<=0;o_clken<=0;o_data<=0;o_frame_abort<=0;o_underflow<=0;
 end else begin
  o_vs<=0;o_clken<=0;o_frame_abort<=0;
  if(cooldown!=0) cooldown<=cooldown-1'b1;
  if(fault_event || !ready_rd) begin
   o_frame_abort<=frame_active;
   frame_active<=0;o_href<=0;state<=fault_event ? FLUSH : SEEK;first_pixel<=0;
  end else case(state)
   SEEK: begin
    o_href<=0;
    if(hold_valid && token_sof && cooldown==0) state<=SOF;
   end
   SOF: begin
    o_vs<=1;o_href<=0;frame_active<=1;first_pixel<=1;
    o_underflow<=0;state<=SEND;
   end
   SEND: begin
    if(hold_valid && token_sof && !first_pixel) begin
     o_frame_abort<=frame_active;frame_active<=0;o_href<=0;
     if(cooldown==0) state<=SOF;
    end else if(emit) begin
     o_data<=token[VID_WIDTH-1:0];o_clken<=1;o_href<=1;
     cooldown<=DIV_N-1;first_pixel<=0;
     if(token_eol) begin state<=GAP;end_frame<=token_eof;end
    end else if(o_href && cooldown==0 && fifo_empty && !hold_valid && !rd_pending)
     o_underflow<=1; // wait for this pixel, without halting DDR
   end
   GAP: if(cooldown==0) begin
    o_href<=0;
    if(end_frame) begin frame_active<=0;state<=SEEK;end
    else state<=SEND;
   end
   FLUSH: begin
    o_href<=0;
    if(fifo_empty && !hold_valid && !rd_pending) state<=SEEK;
   end
  endcase
 end
end
endmodule
