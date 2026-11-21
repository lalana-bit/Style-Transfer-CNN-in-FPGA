`timescale 1ns/1ps
// 共用一个DDR读口和双线性插值流水，帧边界选择分屏或风格全屏。
// 分屏左原画、右风格；全屏直接将风格图插值到HDMI有效区，不串联放大。
module hdmi_nn_scanout #(
 parameter IMG_W=256,IMG_H=144,DST_W=960,DST_H=540,
 parameter H_ACTIVE=1920,H_SYNC=44,H_BACK=148,H_FRONT=88,
 parameter V_ACTIVE=1080,V_SYNC=5,V_BACK=36,V_FRONT=4,
 parameter AXI_WIDTH=128,ADDR_WIDTH=32,BURST_BEATS=16,RAW_W=864,RAW_H=486
)(
 input wire axi_clk,axi_rst_n,frame_available,raw_frame_available,
 input wire [ADDR_WIDTH-1:0] frame_base,raw_frame_base,output wire frame_start,
 output wire [ADDR_WIDTH-1:0] araddr,output wire [7:0] arlen,output wire arvalid,input wire arready,
 input wire [AXI_WIDTH-1:0] rdata,input wire rvalid,rlast,input wire [1:0] rresp,output wire rready,
 input wire vid_clk,vid_rst_n,output wire o_vs,o_hs,o_de,output wire [47:0] o_data,
 output reg underflow,request_overflow,output wire read_error,input wire frame_raw,
 input wire cnn_read_start,
 input wire [ADDR_WIDTH-1:0] cnn_read_base,
 input wire [10:0] cnn_read_used,
 output wire cnn_read_valid,
 output wire [47:0] cnn_read_pixel,
 output wire cnn_read_complete,
 output wire cnn_read_fault
);
localparam RAW_SHRINK_X=RAW_W>DST_W,RAW_SHRINK_Y=RAW_H>DST_H;
localparam BYTES=AXI_WIDTH/8,XW=$clog2(RAW_W+1),YW=$clog2(RAW_H+1),EW=8,REQ_W=EW+4+YW;
localparam HT=H_ACTIVE+H_SYNC+H_BACK+H_FRONT,VT=V_ACTIVE+V_SYNC+V_BACK+V_FRONT;
localparam HA=H_SYNC+H_BACK,VA=V_SYNC+V_BACK,LEFT=HA+(H_ACTIVE-2*DST_W)/2,TOP=VA+(V_ACTIVE-DST_H)/2;
reg [$clog2(HT)-1:0] h;reg [$clog2(VT)-1:0] v;reg [EW-1:0] epoch;
reg [XW+7:0] xq[0:1];reg [YW+7:0] yq[0:1];
reg [$clog2(DST_W):0] xe[0:1];reg [$clog2(DST_H):0] ye[0:1];reg [1:0] slot[0:1];
wire [XW-1:0] sx[0:1];wire [YW-1:0] sy[0:1];wire [YW+7:0] next_y[0:1];wire [1:0] next_slot[0:1];wire advance[0:1],advance_two[0:1];
wire new_frame=h==0 && v==0;
// frame_raw沿用既有端口名，现在表示风格全屏请求；只在帧开始锁存模式。
(* async_reg="true" *) reg fullscreen_meta,fullscreen_sync;
reg fullscreen_active;
always @(posedge vid_clk or negedge vid_rst_n) begin
 if(!vid_rst_n)begin fullscreen_meta<=0;fullscreen_sync<=0;fullscreen_active<=0;end
 else begin
  fullscreen_meta<=frame_raw;
  fullscreen_sync<=fullscreen_meta;
  if(new_frame)fullscreen_active<=fullscreen_sync;
 end
end
wire image_line=fullscreen_active ? (v>=VA && v<VA+V_ACTIVE) : (v>=TOP && v<TOP+DST_H);
wire raw_pixel=!fullscreen_active && image_line && h>=LEFT && h<LEFT+DST_W;
wire style_pixel=image_line && (fullscreen_active ? (h>=HA && h<HA+H_ACTIVE) : (h>=LEFT+DST_W && h<LEFT+2*DST_W));
wire image_pixel=raw_pixel || style_pixel;wire side=style_pixel;
wire [1:0] pre_side=(h>=3); // First six blanking clocks preload three rows per stream.
wire initial_request=v==0 && h<6;
// A shrinking raw viewport can consume two source rows per output line.
// Refill its released rows immediately after the left viewport, leaving the
// right viewport/blanking interval to fetch the next bottom row before use.
wire raw_second=RAW_SHRINK_Y && h==LEFT+DST_W+1;
wire raw_request=!fullscreen_active && (RAW_SHRINK_Y ?
 (image_line && ((h==LEFT+DST_W && advance[0] && sy[0]+3<RAW_H) ||
                (raw_second && advance_two[0] && sy[0]+4<RAW_H))) :
 (h==HT-2 && image_line && advance[0] && sy[0]+3<RAW_H));
wire style_request=h==HT-1 && image_line && advance[1] && sy[1]+3<IMG_H;
wire request=initial_request || raw_request || style_request;
wire req_side=initial_request?(h>=3):style_request;
wire [1:0] req_slot=initial_request?((h>=3)?h-3:h):((raw_request && raw_second)?(slot[0]==2?0:slot[0]+1'b1):slot[req_side]);
wire [YW-1:0] req_y=initial_request?((h>=3)?h-3:h):sy[req_side]+3+((raw_request && raw_second)?1'b1:1'b0);
wire [EW-1:0] req_epoch=new_frame?epoch+1'b1:epoch;
wire req_full,req_empty,req_pop;wire [REQ_W-1:0] req_data;
cnn_pixel_async_fifo #(.WIDTH(REQ_W),.DEPTH(8)) requests(
 .wr_clk(vid_clk),.wr_rst_n(vid_rst_n),.wr_en(request && !req_full),.wr_data({req_epoch,new_frame,req_side,req_slot,req_y}),.full(req_full),.wr_usedw(),
 .rd_clk(axi_clk),.rd_rst_n(axi_rst_n),.rd_en(req_pop),.rd_data(req_data),.empty(req_empty),.rd_usedw());
genvar a;
generate for(a=0;a<2;a=a+1)begin:coordinates
 localparam W=a?IMG_W:RAW_W,H=a?IMG_H:RAW_H;
 localparam SX=W*256/DST_W,RX=W*256%DST_W,SY=H*256/DST_H,RY=H*256%DST_H;
 localparam FULL_SX=W*256/H_ACTIVE,FULL_RX=W*256%H_ACTIVE;
 localparam FULL_SY=H*256/V_ACTIVE,FULL_RY=H*256%V_ACTIVE;
 // 两套步进均为编译期常量，模式只选择常量，不产生运行时除法器。
 wire full_view=a && fullscreen_active;
 wire [XW+7:0] step_x=full_view?FULL_SX:SX;
 wire [YW+7:0] step_y=full_view?FULL_SY:SY;
 wire [$clog2(H_ACTIVE+1):0] remainder_x=full_view?FULL_RX:RX;
 wire [$clog2(V_ACTIVE+1):0] remainder_y=full_view?FULL_RY:RY;
 wire [$clog2(H_ACTIVE+1):0] target_w=full_view?H_ACTIVE:DST_W;
 wire [$clog2(V_ACTIVE+1):0] target_h=full_view?V_ACTIVE:DST_H;
 assign sx[a]=xq[a]>>8;
 assign sy[a]=yq[a]>>8;
 assign next_y[a]=yq[a]+step_y+((ye[a]+remainder_y>=target_h)?1'b1:1'b0);
 assign advance_two[a]=(H>DST_H) && ((next_y[a]>>8)==sy[a]+2);
 assign next_slot[a]=slot[a]==2?0:slot[a]+1'b1;
 assign advance[a]=(next_y[a]>>8)!=sy[a];
 always @(posedge vid_clk or negedge vid_rst_n)
  if(!vid_rst_n)begin xq[a]<=0;yq[a]<=0;xe[a]<=0;ye[a]<=0;slot[a]<=0;end
  else begin
   if(new_frame)begin yq[a]<=0;ye[a]<=0;slot[a]<=0;end
   else if(h==HT-1 && image_line && (a || !fullscreen_active))begin yq[a]<=next_y[a];ye[a]<=(ye[a]+remainder_y>=target_h)?ye[a]+remainder_y-target_h:ye[a]+remainder_y;if(advance[a])slot[a]<=advance_two[a]?(slot[a]==0?2:slot[a]-1'b1):next_slot[a];end
   if(a?style_pixel:raw_pixel)begin xq[a]<=xq[a]+step_x+((xe[a]+remainder_x>=target_w)?1'b1:1'b0);xe[a]<=(xe[a]+remainder_x>=target_w)?xe[a]+remainder_x-target_w:xe[a]+remainder_x;end
   else begin xq[a]<=0;xe[a]<=0;end
  end
end endgenerate
always @(posedge vid_clk or negedge vid_rst_n)
 if(!vid_rst_n)begin h<=0;v<=0;epoch<=0;request_overflow<=0;end
 else begin
  if(h==HT-1)begin h<=0;v<=v==VT-1?0:v+1'b1;end else h<=h+1'b1;
  if(new_frame)epoch<=epoch+1'b1;if(request && req_full)request_overflow<=1;
 end
// 显示与 CNN 共用一套突发读取和 RGB 解包硬件，扫描行 RAM 保持原样。
wire emit_pixel;
wire [23:0] pixel;
wire [XW-1:0] column;
wire [2:0] bank;
wire row_done;
wire [YW-1:0] row_done_y;
wire [EW-1:0] row_done_epoch;
reg [5:0] ready_toggle;
reg [YW-1:0] ready_y[0:5];
reg [EW-1:0] ready_epoch[0:5];
integer k;
always @(posedge axi_clk or negedge axi_rst_n) begin
 if(!axi_rst_n)begin
  ready_toggle<=0;
  for(k=0;k<6;k=k+1)begin ready_y[k]<=0;ready_epoch[k]<=0;end
 end else if(row_done)begin
  ready_toggle[bank]<=~ready_toggle[bank];
  ready_y[bank]<=row_done_y;
  ready_epoch[bank]<=row_done_epoch;
 end
end
video_ddr_read_service #(
 .IMG_W(IMG_W),
 .IMG_H(IMG_H),
 .RAW_W(RAW_W),
 .RAW_H(RAW_H),
 .AXI_WIDTH(AXI_WIDTH),
 .ADDR_WIDTH(ADDR_WIDTH),
 .BURST_BEATS(BURST_BEATS)
) read_service (
 .clk(axi_clk),
 .rst_n(axi_rst_n),
 .request_empty(req_empty),
 .request_data(req_data),
 .request_pop(req_pop),
 .frame_available(frame_available),
 .raw_frame_available(raw_frame_available),
 .frame_base(frame_base),
 .raw_frame_base(raw_frame_base),
 .display_start(frame_start),
 .display_valid(emit_pixel),
 .display_pixel(pixel),
 .display_column(column),
 .display_bank(bank),
 .display_done(row_done),
 .display_row(row_done_y),
 .display_epoch(row_done_epoch),
 .cnn_start(cnn_read_start),
 .cnn_base(cnn_read_base),
 .cnn_used(cnn_read_used),
 .cnn_valid(cnn_read_valid),
 .cnn_pixel(cnn_read_pixel),
 .cnn_complete(cnn_read_complete),
 .cnn_fault(cnn_read_fault),
 .read_error(read_error),
 .araddr(araddr),
 .arlen(arlen),
 .arvalid(arvalid),
 .arready(arready),
 .rdata(rdata),
 .rvalid(rvalid),
 .rlast(rlast),
 .rresp(rresp),
 .rready(rready)
);
(* async_reg="true" *)reg [5:0] ready_meta,ready_sync;reg [5:0] ready_seen,slot_valid;
reg [YW-1:0] cached_y[0:5];reg [EW-1:0] cached_epoch[0:5];
(* async_reg="true" *)reg [1:0] available_meta,available_sync;reg [1:0] available_axi;
always @(posedge axi_clk or negedge axi_rst_n)if(!axi_rst_n)available_axi<=0;else available_axi<={frame_available,raw_frame_available};
integer j;
always @(posedge vid_clk or negedge vid_rst_n)
 if(!vid_rst_n)begin ready_meta<=0;ready_sync<=0;ready_seen<=0;slot_valid<=0;available_meta<=0;available_sync<=0;for(j=0;j<6;j=j+1)begin cached_y[j]<=0;cached_epoch[j]<=0;end end
 else begin
  ready_meta<=ready_toggle;ready_sync<=ready_meta;ready_seen<=ready_sync;available_meta<=available_axi;available_sync<=available_meta;
  for(j=0;j<6;j=j+1)if(ready_sync[j]!=ready_seen[j])begin cached_y[j]<=ready_y[j];cached_epoch[j]<=ready_epoch[j];slot_valid[j]<=1;end
 end
wire [2:0] top_bank=side?3+slot[1]:slot[0],bottom_bank=side?3+next_slot[1]:next_slot[0];
wire [YW-1:0] source_y=sy[side];wire last_row=source_y==(side?IMG_H:RAW_H)-1;
wire top_ready=slot_valid[top_bank] && cached_y[top_bank]==source_y && cached_epoch[top_bank]==epoch;
wire bottom_ready=slot_valid[bottom_bank] && cached_y[bottom_bank]==source_y+1 && cached_epoch[bottom_bank]==epoch;
wire row_valid=top_ready && (last_row || yq[side][7:0]==0 || bottom_ready);
// One read per source pixel, rather than two reads per display pixel. A
// sliding left/right pair permits six ordinary single-read row RAMs.
wire [23:0] right_q[0:5],left_q[0:5];
generate for(a=0;a<6;a=a+1)begin:line_slot
 localparam S=a>=3,W=S?IMG_W:RAW_W;
 if(S==0 && RAW_SHRINK_X) begin:packed_raw
 // Two adjacent RGB pixels per 48-bit word. The source advances <=2 pixels
 // per output, hence its pair address advances <=1: one RAM read/clock is
 // sufficient for both bilinear neighbours, with the same stored bit count.
 localparam PW=W/2;
 reg [47:0] mem[0:PW-1];reg [47:0] q,left_hold;
 reg [23:0] even_pixel;reg [XW-2:0] previous_pair;
 reg parity_d,last_d;
 wire pre0=image_line && h==LEFT-2,pre1=image_line && h==LEFT-1;
 wire [XW-2:0] pair_x=sx[0]>>1;
 wire [XW-2:0] right_pair=(pair_x>=PW-1)?PW-1:pair_x+1'b1;
 wire [XW-2:0] ra=pre0?0:(pre1?1:right_pair);
 always @(posedge axi_clk)if(axi_rst_n && emit_pixel && bank==a)begin
  if(!column[0])even_pixel<=pixel;
  else mem[column>>1]<={pixel,even_pixel};
 end
 always @(posedge vid_clk)begin
  if(pre0 || pre1 || raw_pixel)q<=mem[ra];
  if(pre1)begin left_hold<=q;previous_pair<=0;end
  else if(raw_pixel)begin if(pair_x!=previous_pair)left_hold<=q;previous_pair<=pair_x;end
  parity_d<=sx[0][0];last_d<=sx[0]>=W-1;
 end
 assign left_q[a]=parity_d?left_hold[47:24]:left_hold[23:0];
 assign right_q[a]=parity_d?(last_d?left_hold[47:24]:q[23:0]):left_hold[47:24];
 end else begin:ordinary_row
 reg [23:0] mem[0:W-1];reg [23:0] q,left_hold;reg [XW-1:0] previous_x;
 wire [$clog2(HT)-1:0] viewport_left=(S && fullscreen_active)?HA:LEFT+S*DST_W;
 wire pre0=image_line && h==viewport_left-2,pre1=image_line && h==viewport_left-1;
 wire active_pixel=S?style_pixel:raw_pixel;
 wire [XW-1:0] right_x=(sx[S]>=W-1)?W-1:sx[S]+1'b1;
 wire [XW-1:0] ra=pre0?0:(pre1?1:right_x);
 always @(posedge axi_clk)if(axi_rst_n && emit_pixel && bank==a)mem[column]<=pixel;
 always @(posedge vid_clk)begin
  if(pre0 || pre1 || active_pixel)q<=mem[ra];
  if(pre1)begin left_hold<=q;previous_x<=0;end
  else if(active_pixel)begin if(sx[S]!=previous_x)left_hold<=q;previous_x<=sx[S];end
 end
 assign right_q[a]=q;assign left_q[a]=left_hold;
 end
end endgenerate
reg [2:0] top_d,bottom_d;reg [7:0] wx_d,wy_pipe[0:3];reg sample_valid;
reg [6:0] vs_pipe,hs_pipe,de_pipe;
always @(posedge vid_clk or negedge vid_rst_n)
 if(!vid_rst_n)begin top_d<=0;bottom_d<=0;wx_d<=0;sample_valid<=0;vs_pipe<=0;hs_pipe<=0;de_pipe<=0;underflow<=0;for(j=0;j<4;j=j+1)wy_pipe[j]<=0;end
 else begin
  top_d<=top_bank;bottom_d<=last_row?top_bank:bottom_bank;wx_d<=xq[side][7:0];wy_pipe[0]<=yq[side][7:0];for(j=1;j<4;j=j+1)wy_pipe[j]<=wy_pipe[j-1];
  sample_valid<=image_pixel && available_sync[side] && row_valid;
  vs_pipe<={vs_pipe[5:0],v<V_SYNC};hs_pipe<={hs_pipe[5:0],h<H_SYNC};de_pipe<={de_pipe[5:0],h>=HA && h<HA+H_ACTIVE && v>=VA && v<VA+V_ACTIVE};
  if(image_pixel && available_sync[side] && !row_valid)underflow<=1;
 end
wire [23:0] ht,hb,result;wire hv,bv,rv;
rgb_lerp_q8 horizontal_top(.clk(vid_clk),.rst_n(vid_rst_n),.i_valid(sample_valid),.i_u(left_q[top_d]),.i_v(right_q[top_d]),.i_w(wx_d),.o_valid(hv),.o_q(ht));
rgb_lerp_q8 horizontal_bottom(.clk(vid_clk),.rst_n(vid_rst_n),.i_valid(sample_valid),.i_u(left_q[bottom_d]),.i_v(right_q[bottom_d]),.i_w(wx_d),.o_valid(bv),.o_q(hb));
rgb_lerp_q8 vertical(.clk(vid_clk),.rst_n(vid_rst_n),.i_valid(hv && bv),.i_u(ht),.i_v(wy_pipe[3]==0?ht:hb),.i_w(wy_pipe[3]),.o_valid(rv),.o_q(result));
assign o_vs=vs_pipe[6];assign o_hs=hs_pipe[6];assign o_de=de_pipe[6];assign o_data=rv?{24'd0,result}:48'd0;
`ifndef SYNTHESIS
initial if(2*DST_W>H_ACTIVE || DST_H>V_ACTIVE || RAW_W>2*DST_W || RAW_H>2*DST_H || IMG_W>DST_W || RAW_W%BYTES || IMG_W%BYTES)$fatal(1,"Unsupported dual viewport geometry");
`endif
endmodule
