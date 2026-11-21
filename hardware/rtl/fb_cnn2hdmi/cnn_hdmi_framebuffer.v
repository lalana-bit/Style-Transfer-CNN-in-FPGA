`timescale 1ns/1ps
// 用途：保存原画与风格图，输出分屏或风格全屏，并显示双帧率。
// 原理：沿用原 DDR 帧缓存、双线性采样和帧率统计；实测CAM/CNN完整帧率，信息握手跨域后在帧边界更新。
module cnn_hdmi_framebuffer #(
 parameter IMG_W=256,IMG_H=144,DST_W=960,DST_H=540,
 parameter H_ACTIVE=1920,H_SYNC=44,H_BACK=148,H_FRONT=88,
 parameter V_ACTIVE=1080,V_SYNC=5,V_BACK=36,V_FRONT=4,
 parameter AXI_WIDTH=128,ADDR_WIDTH=32,BASE_ADDR=32'h01000000,FIFO_DEPTH=128,BURST_BEATS=16,
 parameter integer FPS_REF_HZ=100000000,parameter RUNTIME_SELECT=1,RAW_W=864,RAW_H=486
)(
 input wire rst_n,wr_clk,i_vs,i_href,i_clken,i_abort,input wire [23:0] i_data,
 input wire i_pause,i_select_raw,
 input wire [ADDR_WIDTH-1:0] i_raw_frame_base,
 input wire i_raw_frame_available,
 output wire o_raw_frame_start,
 input wire cnn_read_start,
 input wire [ADDR_WIDTH-1:0] cnn_read_base,
 input wire [10:0] cnn_read_used,
 output wire cnn_read_valid,
 output wire [47:0] cnn_read_pixel,
 output wire cnn_read_complete,
 output wire cnn_read_fault,
 input wire i_camera_frame_toggle,
 input wire axi_clk,
 output wire [ADDR_WIDTH-1:0] awaddr,output wire [7:0] awlen,output wire [2:0] awsize,output wire [1:0] awburst,
 output wire awvalid,input wire awready,output wire [AXI_WIDTH-1:0] wdata,output wire [AXI_WIDTH/8-1:0] wstrb,
 output wire wlast,wvalid,input wire wready,input wire bvalid,input wire [1:0] bresp,output wire bready,
 output wire [ADDR_WIDTH-1:0] araddr,output wire [7:0] arlen,output wire [2:0] arsize,output wire [1:0] arburst,
 output wire arvalid,input wire arready,input wire [AXI_WIDTH-1:0] rdata,input wire rvalid,rlast,input wire [1:0] rresp,output wire rready,
 input wire vid_clk,output wire o_vs,o_hs,o_de,output wire [47:0] o_data,
 output wire o_underflow,o_request_overflow,o_write_drop,o_write_error,o_read_error,o_frame_written,o_frame_available
);
localparam RAW_STRIDE=((RAW_W*RAW_H*3+4095)/4096)*4096,STYLE_STRIDE=((IMG_W*IMG_H*3+4095)/4096)*4096;
localparam STYLE_BASE=BASE_ADDR+3*RAW_STRIDE;
(* async_reg="true" *)reg [2:0] wr_reset=0,axi_reset=0,vid_reset=0;
always @(posedge wr_clk or negedge rst_n)if(!rst_n)wr_reset<=0;else wr_reset<={wr_reset[1:0],1'b1};
always @(posedge axi_clk or negedge rst_n)if(!rst_n)axi_reset<=0;else axi_reset<={axi_reset[1:0],1'b1};
always @(posedge vid_clk or negedge rst_n)if(!rst_n)vid_reset<=0;else vid_reset<={vid_reset[1:0],1'b1};
wire wr_rst_n=wr_reset[2],axi_rst_n=axi_reset[2],vid_rst_n=vid_reset[2];
assign awsize=$clog2(AXI_WIDTH/8);assign arsize=$clog2(AXI_WIDTH/8);assign awburst=1;assign arburst=1;
wire [1:0] commit,available;wire read_frame_start;
wire [ADDR_WIDTH-1:0] write_base[0:1],read_base[0:1];
genvar b;
generate for(b=0;b<1;b=b+1)begin:banks
 localparam STRIDE=b?RAW_STRIDE:STYLE_STRIDE,BASE=b?BASE_ADDR:STYLE_BASE;
 reg [1:0] write_bank,read_bank,pending_bank;
 reg pending_valid,display_valid;
 reg [1:0] next_write,next_read,next_pending;reg next_pending_valid,next_display_valid;
 always @*begin
  next_write=write_bank;next_read=read_bank;next_pending=pending_bank;next_pending_valid=pending_valid;next_display_valid=display_valid;
  if(commit[b])begin next_pending=write_bank;next_pending_valid=1;next_write=pending_valid?pending_bank:3-write_bank-read_bank;end
  if(read_frame_start && next_pending_valid)begin next_read=next_pending;next_pending_valid=0;next_display_valid=1;end
 end
 always @(posedge axi_clk or negedge axi_rst_n)
  if(!axi_rst_n)begin write_bank<=0;read_bank<=1;pending_bank<=2;pending_valid<=0;display_valid<=0;end
  else begin write_bank<=next_write;read_bank<=next_read;pending_bank<=next_pending;pending_valid<=next_pending_valid;display_valid<=next_display_valid;end
 assign write_base[b]=BASE+write_bank*STRIDE;assign read_base[b]=BASE+next_read*STRIDE;assign available[b]=next_display_valid;
end endgenerate
assign commit[1]=1'b0;
assign available[1]=i_raw_frame_available;
assign read_base[1]=i_raw_frame_base;
assign o_raw_frame_start=read_frame_start;
assign o_frame_written=commit[0];
assign o_frame_available=available[0];
video_frame_writer #(
 .IMG_W(IMG_W),
 .IMG_H(IMG_H),
 .AXI_WIDTH(AXI_WIDTH),
 .ADDR_WIDTH(ADDR_WIDTH),
 .FIFO_DEPTH(FIFO_DEPTH),
 .BURST_BEATS(BURST_BEATS)
) writer (
 .wr_clk(wr_clk),
 .wr_rst_n(wr_rst_n),
 .i_sof(i_vs),
 .i_valid(i_href && i_clken),
 .i_abort(i_abort),
 .i_pixel(i_data),
 .i_pause(i_pause),
 .axi_clk(axi_clk),
 .axi_rst_n(axi_rst_n),
 .frame_base(write_base[0]),
 .frame_done(commit[0]),
 .write_error(o_write_error),
 .frame_drop(o_write_drop),
 .awaddr(awaddr),
 .awlen(awlen),
 .awvalid(awvalid),
 .awready(awready),
 .wdata(wdata),
 .wstrb(wstrb),
 .wlast(wlast),
 .wvalid(wvalid),
 .wready(wready),
 .bvalid(bvalid),
 .bresp(bresp),
 .bready(bready)
);
wire scan_vs,scan_hs,scan_de;wire [47:0] scan_data;
hdmi_nn_scanout #(.IMG_W(IMG_W),.IMG_H(IMG_H),.DST_W(DST_W),.DST_H(DST_H),.H_ACTIVE(H_ACTIVE),.H_SYNC(H_SYNC),.H_BACK(H_BACK),.H_FRONT(H_FRONT),.V_ACTIVE(V_ACTIVE),.V_SYNC(V_SYNC),.V_BACK(V_BACK),.V_FRONT(V_FRONT),.AXI_WIDTH(AXI_WIDTH),.ADDR_WIDTH(ADDR_WIDTH),.BURST_BEATS(BURST_BEATS),.RAW_W(RAW_W),.RAW_H(RAW_H)) scanout(
 .axi_clk(axi_clk),.axi_rst_n(axi_rst_n),.frame_available(available[0]),.raw_frame_available(available[1]),.frame_base(read_base[0]),.raw_frame_base(read_base[1]),.frame_start(read_frame_start),.frame_raw(i_select_raw),
 .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),.rdata(rdata),.rvalid(rvalid),.rlast(rlast),.rresp(rresp),.rready(rready),
 .cnn_read_start(cnn_read_start),
 .cnn_read_base(cnn_read_base),
 .cnn_read_used(cnn_read_used),
 .cnn_read_valid(cnn_read_valid),
 .cnn_read_pixel(cnn_read_pixel),
 .cnn_read_complete(cnn_read_complete),
 .cnn_read_fault(cnn_read_fault),
 .vid_clk(vid_clk),.vid_rst_n(vid_rst_n),.o_vs(scan_vs),.o_hs(scan_hs),.o_de(scan_de),.o_data(scan_data),.underflow(o_underflow),.request_overflow(o_request_overflow),.read_error(o_read_error));
// Count completed CNN packets independently of HDMI refresh and pause.
localparam CW=$clog2(IMG_W*IMG_H+1),TW=$clog2(FPS_REF_HZ);
reg [CW-1:0] cnn_pixels;reg cnn_active,cnn_toggle;
always @(posedge wr_clk or negedge wr_rst_n)
 if(!wr_rst_n)begin cnn_pixels<=0;cnn_active<=0;cnn_toggle<=0;end
 else if(i_abort)begin cnn_pixels<=0;cnn_active<=0;end
 else if(i_vs)begin cnn_pixels<=0;cnn_active<=1;end
 else if(cnn_active && i_href && i_clken)begin
  cnn_pixels<=cnn_pixels+1'b1;if(cnn_pixels==IMG_W*IMG_H-1)begin cnn_active<=0;cnn_toggle<=~cnn_toggle;end
 end
(* async_reg="true" *)reg [2:0] cam_sync,cnn_sync;reg cam_seen,cnn_seen;
reg [TW-1:0] fps_timer;reg [7:0] cam_count,cnn_count;
(* syn_preserve="true" *) reg [15:0] fps_sample;
function [7:0] increment(input [7:0] q);
 begin increment=q==8'h99 ? q :(q[3:0]==9?{q[7:4]+4'd1,4'd0}:q+8'd1);end
endfunction
wire [7:0] cam_next=cam_sync[2]!=cam_seen?increment(cam_count):cam_count;
wire [7:0] cnn_next=cnn_sync[2]!=cnn_seen?increment(cnn_count):cnn_count;
always @(posedge axi_clk or negedge axi_rst_n)
 if(!axi_rst_n)begin cam_sync<=0;cnn_sync<=0;cam_seen<=0;cnn_seen<=0;fps_timer<=0;cam_count<=0;cnn_count<=0;fps_sample<=0;end
 else begin
  cam_sync<={cam_sync[1:0],i_camera_frame_toggle};cnn_sync<={cnn_sync[1:0],cnn_toggle};cam_seen<=cam_sync[2];cnn_seen<=cnn_sync[2];
  if(fps_timer==FPS_REF_HZ-1)begin fps_timer<=0;cam_count<=0;cnn_count<=0;fps_sample<={cam_next,cnn_next};end
  else begin fps_timer<=fps_timer+1'b1;cam_count<=cam_next;cnn_count<=cnn_next;end
 end
// 状态邮箱：源数据保持到视频域确认，快速更新只合并中间值，不丢失最终结果。
reg [15:0] osd_mailbox;
reg osd_request;
reg osd_acknowledge;
(* async_reg="true" *) reg [1:0] osd_ack_sync;
wire [15:0] osd_latest = fps_sample;
always @(posedge axi_clk or negedge axi_rst_n) begin
    if (!axi_rst_n) begin
        osd_mailbox <= 0;
        osd_request <= 0;
        osd_ack_sync <= 0;
    end else begin
        osd_ack_sync <= {osd_ack_sync[0], osd_acknowledge};
        if (osd_request == osd_ack_sync[1] && osd_mailbox != osd_latest) begin
            osd_mailbox <= osd_latest;
            osd_request <= ~osd_request;
        end
    end
end
(* async_reg="true" *) reg [2:0] osd_request_sync;
reg [15:0] osd_pending;
reg [15:0] osd_display;
reg scan_vs_d;
reg scan_de_d;
reg [$clog2(H_ACTIVE+1)-1:0] osd_x;
reg [$clog2(V_ACTIVE+1)-1:0] osd_y;
wire [15:0] fps_display = osd_display[15:0];
always @(posedge vid_clk or negedge vid_rst_n) begin
    if (!vid_rst_n) begin
        osd_request_sync <= 0;
        osd_acknowledge <= 0;
        osd_pending <= 0;
        osd_display <= 0;
        scan_vs_d <= 0;
        scan_de_d <= 0;
        osd_x <= 0;
        osd_y <= 0;
    end else begin
        osd_request_sync <= {osd_request_sync[1:0], osd_request};
        if (osd_request_sync[2] != osd_acknowledge) begin
            osd_pending <= osd_mailbox;
            osd_acknowledge <= osd_request_sync[2];
        end
        scan_vs_d <= scan_vs;
        scan_de_d <= scan_de;
        if (scan_vs && !scan_vs_d) osd_display <= osd_pending;
        if (scan_vs) begin
            osd_x <= 0;
            osd_y <= 0;
        end else begin
            if (scan_de) osd_x <= osd_x + 1'b1;
            else osd_x <= 0;
            if (scan_de_d && !scan_de) osd_y <= osd_y + 1'b1;
        end
    end
end
function [4:0] fps_font_row(input [4:0] glyph,input [2:0] row);
 reg [34:0] p;
 begin
 case(glyph)
 0:p={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
 1:p={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
 2:p={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
 3:p={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
 4:p={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
 5:p={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
 6:p={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
 7:p={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
 8:p={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
 9:p={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
 10:p={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111}; // C
 11:p={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001}; // A
 12:p={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001}; // M
 13:p={5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001}; // N
 14:p={5'b00000,5'b00100,5'b00100,5'b00000,5'b00100,5'b00100,5'b00000};
 default:p=0;
 endcase
 case(row)0:fps_font_row=p[34:30];1:fps_font_row=p[29:25];2:fps_font_row=p[24:20];3:fps_font_row=p[19:15];4:fps_font_row=p[14:10];5:fps_font_row=p[9:5];6:fps_font_row=p[4:0];default:fps_font_row=0;endcase
 end
endfunction
localparam FPS_X=H_ACTIVE-224;
wire [7:0] tx=osd_x-(FPS_X+8);wire [6:0] ty=osd_y-24;wire second_line=ty[5];
wire [7:0] digits=second_line?fps_display[7:0]:fps_display[15:8];reg [4:0] glyph;
always @*case(tx[7:5])0:glyph=10;1:glyph=second_line?13:11;2:glyph=second_line?13:12;3:glyph=14;4:glyph={1'b0,digits[7:4]};5:glyph={1'b0,digits[3:0]};default:glyph=15;endcase
wire [4:0] font=fps_font_row(glyph,ty[4:2]);wire [2:0] col=tx[4:2];
wire dot=osd_x>=FPS_X+8 && osd_x<FPS_X+200 && osd_y>=24 && osd_y<88 && col>=1 && col<=5 && font[5-col];
reg ov,oh,od;reg [23:0] out;
always @(posedge vid_clk or negedge vid_rst_n)
 if(!vid_rst_n)begin ov<=0;oh<=0;od<=0;out<=0;end
 else begin ov<=scan_vs;oh<=scan_hs;od<=scan_de;out<=dot?24'hffffff:scan_data[23:0];end
assign o_vs=ov;assign o_hs=oh;assign o_de=od;assign o_data={24'd0,out};
endmodule
