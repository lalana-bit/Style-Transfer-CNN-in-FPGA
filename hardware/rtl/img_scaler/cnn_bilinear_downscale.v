//==========================================================================
// cnn_bilinear_downscale : RGB888稀疏流双线性缩小，供CNN前处理使用
//--------------------------------------------------------------------------
// 输入来自gap>=9的桥接器，不反压输入。SRC_W>=2*DST_W时相邻水平任务
// 至少相隔18拍；一个流水DSP分时完成RGB水平/垂直插值，共14拍任务延迟。
// 求差、DSP输入、DSP乘积、舍入写回分级；每拍可发起一个通道运算，
// 增加延迟不降低吞吐率，输入采样/坐标更新不受计算状态阻塞。
// 仅保存一行水平缩放结果(3*DST_W个字节)。利用RGB分时计算按字节读写，
// 256宽时8bit*768可映射一个RAM10，避免24bit宽端口拆成两块RAM。
// 同步RAM读旧值后覆盖为当前行，
// 垂直插值使用上一源行和当前源行，未使用整帧缓存或DDR。
// 新增一行8bit*(3*DST_W)输出RAM，收齐一行后以固定gap9发出RGB888。
// 256宽时两行字节RAM各占一个RAM10；仍不使用整帧缓存或DDR。
// 输出RAM同一行循环复用：读端每9拍取一个像素，下一行计算至少18拍一个，
// 读端先读完旧地址再被新行覆盖，无需双缓冲。行间保留等待时间，HREF为电平。
//==========================================================================
`timescale 1ns/1ps
module cnn_bilinear_downscale #(
	parameter integer SRC_W=640, SRC_H=480,
	parameter integer DST_W=256, DST_H=256,
    parameter integer INPUT_GAP=9,DUAL_CLOCK=0,
    parameter integer VIDEO_CLK_HZ=25000000,FRAME_HZ=60,
    parameter integer VIDEO_HT=2000,VIDEO_VT=208,VIDEO_HA=944,VIDEO_VA=4
)(
	input clk,rst_n,
	input pre_img_vsync,pre_img_href,pre_img_clken,frame_abort,
	input [23:0] pre_img_data,
	output wire post_img_vsync,post_img_href,post_img_clken,
	output wire [23:0] post_img_data,
	output wire o_frame_abort,
	output wire o_protocol_error,
    input video_clk,enable,source_available,source_idle,
    output wire o_source_start,o_source_ready,o_video_error
);
    reg scaled_vs,core_abort,core_error;
    wire scaled_href,scaled_valid;
    wire [23:0] scaled_data;
    wire video_abort_event;
	localparam integer XW=$clog2(SRC_W+1),YW=$clog2(SRC_H+1);
	localparam integer DXW=(DST_W<2)?1:$clog2(DST_W+1);
	localparam integer DYW=(DST_H<2)?1:$clog2(DST_H+1);
	localparam integer SX=SRC_W*256/DST_W,RX=SRC_W*256%DST_W;
	localparam integer SY=SRC_H*256/DST_H,RY=SRC_H*256%DST_H;
	localparam integer XE=(DST_W<2)?1:$clog2(DST_W+1);
	localparam integer YE=(DST_H<2)?1:$clog2(DST_H+1);
	localparam integer RAW=$clog2(3*DST_W);
	localparam [2:0] IDLE=0,HORIZONTAL=1,MEMORY=2,VERTICAL=3,OUTPUT_PIXEL=4,
		H_DRAIN=5,V_DRAIN=6;
`ifndef SYNTHESIS
	initial if(DST_W<1 || DST_H<1 || SRC_W<2*DST_W || SRC_H<DST_H)
		$fatal(1,"cnn_bilinear_downscale: require SRC_W>=2*DST_W and SRC_H>=DST_H");
`endif
	reg vs_d,href_d,active;
	reg [XW-1:0] source_col;
	reg [YW-1:0] source_row;
	reg [DXW-1:0] horizontal_count;
	reg [DYW-1:0] output_row;
	reg [XW+7:0] xq;
	reg [YW+7:0] yq;
	reg [XE-1:0] x_error;
	reg [YE-1:0] y_error;
	reg [23:0] previous_pixel;
	reg [3:0] pixel_wait;
	wire raw_sof=pre_img_vsync && !vs_d;
	wire sof=raw_sof;
	wire eol=href_d && !pre_img_href;
	wire input_pixel=active && pre_img_href && pre_img_clken && !sof;
	wire [XW-1:0] left_x=xq>>8;
	wire [XW-1:0] right_x=(left_x==SRC_W-1)?left_x:left_x+1'b1;
	wire [YW-1:0] top_y=yq>>8;
	// 整数坐标不依赖上一行RAM，当前行直接作为垂直顶行，避免首帧旧值。
	wire [YW-1:0] needed_y=(yq[7:0]==0 || top_y==SRC_H-1)?top_y:top_y+1'b1;
	wire selected_row=output_row<DST_H && source_row==needed_y;
	wire fire=input_pixel && horizontal_count<DST_W && source_col==right_x;
	reg [2:0] state;
	reg [1:0] channel;
	reg [23:0] job_left,job_right,h_pixel,previous_line;
	reg [7:0] job_wx,job_wy;
	reg [RAW-1:0] job_base;
	reg job_emit,job_last,drop_href;
    reg [DXW-1:0] job_x;
	wire output_active;
	reg [3:0] output_phase;
	reg [DXW-1:0] output_col;
	reg [RAW-1:0] output_base;
	reg [23:0] output_pixel;
	wire row_ready=(state==OUTPUT_PIXEL && job_last);
	wire fault=(sof && (active || state!=IDLE || output_active)) ||
		(input_pixel && source_col>=SRC_W) ||
		(input_pixel && pixel_wait!=0) ||
		(eol && active && source_col!=SRC_W) || (fire && state!=IDLE) ||
		(row_ready && output_active);
	wire clear=frame_abort || sof || fault || video_abort_event;

	// 不复位/初始化RAM内容；有分数的垂直任务只在上一源行已写完后读取。
	reg [7:0] line_mem [0:3*DST_W-1];
	reg [7:0] line_q;
	reg [1:0] read_channel;
	reg read_valid;
	// 写回的通道标签跟随流水，不能使用此时已经切换到下一阶段的channel。
	wire [RAW-1:0] ram_address=job_base+result_channel;
	always @(posedge clk) begin
		if(!rst_n || clear) read_valid<=0;
		else begin
			read_valid<=result_valid && !result_vertical;
			if(result_valid && !result_vertical) begin
				line_q<=line_mem[ram_address];
				line_mem[ram_address]<=lerp_q;
				read_channel<=result_channel;
			end
			if(read_valid) previous_line[read_channel*8+:8]<=line_q;
		end
	end

	// 一个乘法器轮流处理三个字节，四级运算流水每拍可接受一次任务。
	// S0选通道/求差；S1 DSP输入寄存；S2 DSP乘积寄存；S3舍入写回。
	// base、符号、通道、方向标签与DSP延迟保持一致，valid清除即可丢弃中止任务。
	wire [23:0] lerp_u=(state==HORIZONTAL)?job_left:
		((job_wy==0)?h_pixel:previous_line);
	wire [23:0] lerp_v=(state==HORIZONTAL)?job_right:h_pixel;
	wire [7:0] u=lerp_u[channel*8+:8],v=lerp_v[channel*8+:8];
	wire [7:0] weight=(state==HORIZONTAL)?job_wx:job_wy;
	wire negative=(v<u);
	wire [7:0] magnitude=negative?(u-v):(v-u);
	wire issue=(state==HORIZONTAL || state==VERTICAL);
	reg [7:0] magnitude0,weight0,base0,base1,base2;
	reg negative0,negative1,negative2;
	reg vertical0,vertical1,vertical2;
	reg [1:0] channel0,channel1,channel2;
	reg [2:0] valid_pipe;
	wire result_valid=valid_pipe[2];
	wire result_vertical=vertical2;
	wire [1:0] result_channel=channel2;
	always @(posedge clk or negedge rst_n) begin
		if(!rst_n) valid_pipe<=0;
		else if(clear) valid_pipe<=0;
		else valid_pipe<={valid_pipe[1:0],issue};
	end
	// 数据寄存器不复位，valid为0时不被消费，减少复位扇出。
	always @(posedge clk) begin
		if(issue) begin
			magnitude0<=magnitude;weight0<=weight;base0<=u;negative0<=negative;
			channel0<=channel;vertical0<=(state==VERTICAL);
		end
		if(valid_pipe[0]) begin
			base1<=base0;negative1<=negative0;channel1<=channel0;vertical1<=vertical0;
		end
		if(valid_pipe[1]) begin
			base2<=base1;negative2<=negative1;channel2<=channel1;vertical2<=vertical1;
		end
	end
	wire signed [23:0] product;
	cnn_dsp #(.LATENCY(2)) u_lerp_dsp(
		.clk(clk),.ce(1'b1),.rst(1'b0),.a(magnitude0),.b(weight0),.c(24'sd0),.o(product));
	wire [16:0] base_round={1'b0,base2,8'd0}+17'd128;
	wire [16:0] rounded=negative2 ? base_round-{1'b0,product[15:0]}:
		base_round+{1'b0,product[15:0]};
	wire [7:0] lerp_q=rounded[15:8];
	// Payload is consumed only after all three horizontal results are valid.
	// It needs neither reset nor the coordinate/fault tree on its clock enable.
	// A stale result during abort is overwritten before the next vertical job.
	always @(posedge clk)
		if(result_valid && !result_vertical)
			h_pixel[result_channel*8+:8]<=lerp_q;

	// 输出行按字节写：三个垂直结果本来就连续三拍完成，避免24bit端口占两块RAM。
	// 同步读端用三拍取RGB，第四拍组包，第五拍输出；每9拍重复一次。
    generate if(!DUAL_CLOCK) begin:g_single_output
    reg output_active_q,scaled_href_q,scaled_valid_q;
    reg [23:0] scaled_data_q;
    assign output_active=output_active_q;
    assign scaled_href=scaled_href_q;assign scaled_valid=scaled_valid_q;assign scaled_data=scaled_data_q;
	reg [7:0] output_mem [0:3*DST_W-1];
	reg [7:0] output_q;
	wire output_write=result_valid && result_vertical;
	wire output_read=output_active_q && output_phase<=2;
	wire [RAW-1:0] output_address=output_base+output_phase[1:0];
	always @(posedge clk) begin
		if(rst_n && !clear) begin
			if(output_write) output_mem[ram_address]<=lerp_q;
			if(output_read) output_q<=output_mem[output_address];
		end
	end
	always @(posedge clk or negedge rst_n) begin
		if(!rst_n) begin
			output_active_q<=0;output_phase<=0;output_col<=0;output_base<=0;output_pixel<=0;
			scaled_href_q<=0;scaled_valid_q<=0;scaled_data_q<=0;drop_href<=0;
		end else begin
			scaled_valid_q<=0;
			if(drop_href) begin scaled_href_q<=0;drop_href<=0;end
			if(clear) begin
				output_active_q<=0;output_phase<=0;output_col<=0;output_base<=0;
				scaled_href_q<=0;drop_href<=0;
			end else begin
				if(row_ready) begin
					output_active_q<=1;output_phase<=0;output_col<=0;output_base<=0;
				end
				if(output_active_q) begin
					case(output_phase)
						1:output_pixel[7:0]<=output_q;
						2:output_pixel[15:8]<=output_q;
						3:output_pixel[23:16]<=output_q;
						4:begin
							scaled_data_q<=output_pixel;scaled_valid_q<=1;scaled_href_q<=1;
							if(output_col==DST_W-1) begin output_active_q<=0;drop_href<=1;end
							else begin output_col<=output_col+1'b1;output_base<=output_base+3;end
						end
						default:begin end
					endcase
					output_phase<=(output_phase==8)?0:output_phase+1'b1;
				end
			end
		end
	end

    end else begin:g_no_fast_output
        assign output_active=1'b0;
        assign scaled_href=1'b0;assign scaled_valid=1'b0;assign scaled_data=24'd0;
    end endgenerate

	always @(posedge clk or negedge rst_n) begin
		if(!rst_n) begin
			vs_d<=0;href_d<=0;active<=0;source_col<=0;source_row<=0;
			horizontal_count<=0;output_row<=0;xq<=0;yq<=0;x_error<=0;y_error<=0;
			previous_pixel<=0;pixel_wait<=0;state<=IDLE;channel<=0;job_left<=0;job_right<=0;
			job_wx<=0;job_wy<=0;job_base<=0;
			job_emit<=0;job_last<=0;
			scaled_vs<=0;
			core_abort<=0;core_error<=0;
		end else begin
			vs_d<=pre_img_vsync;href_d<=pre_img_href;
			scaled_vs<=0;core_abort<=0;
			if(clear) begin
				// 故障拒绝该帧；完整新帧重新建立坐标，不清行RAM。
				active<=sof && !frame_abort && !fault && !video_abort_event;
				source_col<=0;source_row<=0;horizontal_count<=0;output_row<=0;
				xq<=0;yq<=0;x_error<=0;y_error<=0;previous_pixel<=0;pixel_wait<=0;
				state<=IDLE;channel<=0;
				scaled_vs<=sof && !frame_abort && !fault;
				core_abort<=frame_abort || fault || video_abort_event;
				if(fault) core_error<=1;
			end else begin
				if(pixel_wait!=0) pixel_wait<=pixel_wait-1'b1;
				if(input_pixel) begin
					// 最小采样间隔9拍；过密输入拒绝整帧，不能静默计算错误。
					pixel_wait<=INPUT_GAP-1;
					previous_pixel<=pre_img_data;source_col<=source_col+1'b1;
					if(source_col==SRC_W-1 && source_row==SRC_H-1) active<=0;
				end
				if(eol && active) begin
					source_col<=0;source_row<=source_row+1'b1;
					horizontal_count<=0;xq<=0;x_error<=0;
					if(selected_row) begin
						output_row<=output_row+1'b1;
						yq<=yq+SY+((y_error+RY>=DST_H)?1'b1:1'b0);
						y_error<=(y_error+RY>=DST_H)?y_error+RY-DST_H:y_error+RY;
					end
				end
				if(fire) begin
					job_left<=(left_x==right_x)?pre_img_data:previous_pixel;
					job_right<=pre_img_data;job_wx<=xq[7:0];job_wy<=yq[7:0];
					job_base<=horizontal_count*3;job_x<=horizontal_count;job_emit<=selected_row;
					job_last<=(horizontal_count==DST_W-1);channel<=0;state<=HORIZONTAL;
					horizontal_count<=horizontal_count+1'b1;
					// 商+余数进位保证坐标精确，无像素时钟除法和累计截断漂移。
					xq<=xq+SX+((x_error+RX>=DST_W)?1'b1:1'b0);
					x_error<=(x_error+RX>=DST_W)?x_error+RX-DST_W:x_error+RX;
				end else case(state)
					HORIZONTAL:begin
						if(channel==2) begin channel<=0;state<=H_DRAIN;end
						else channel<=channel+1'b1;
					end
					H_DRAIN:begin end // 等待三个水平结果全部写回
					MEMORY:state<=job_emit?VERTICAL:IDLE;
					VERTICAL:begin
						if(channel==2) begin channel<=0;state<=V_DRAIN;end
						else channel<=channel+1'b1;
					end
					V_DRAIN:begin end // 等待三个垂直结果全部写回
					OUTPUT_PIXEL:begin
						// 像素已逐字节进入输出RAM；行末才启动独立gap9读端。
						state<=IDLE;
					end
					default:state<=IDLE;
				endcase
				if(result_valid) begin
					if(!result_vertical) begin
						if(result_channel==2) state<=MEMORY;
					end else begin
						if(result_channel==2) state<=OUTPUT_PIXEL;
					end
				end
			end
		end
	end
generate if(!DUAL_CLOCK) begin:g_single_clock
 assign post_img_vsync=scaled_vs;
 assign post_img_href=scaled_href;
 assign post_img_clken=scaled_valid;
 assign post_img_data=scaled_data;
 assign o_frame_abort=core_abort;
 assign o_protocol_error=core_error;
 assign video_abort_event=1'b0;
 assign o_source_start=1'b0;assign o_source_ready=1'b0;assign o_video_error=1'b0;
end else begin:g_dual_clock
 // Two complete output rows. Ownership crosses domains as Gray pointers;
 // the producer is stopped BEFORE reusing a row still owned by the reader.
 localparam BANK_AW=$clog2(2*DST_W);
 reg [7:0] red[0:2*DST_W-1],green[0:2*DST_W-1],blue[0:2*DST_W-1];
 reg [1:0] write_row,write_gray,read_row,read_gray;
  reg [1:0] read_g0,read_g1,write_g0,write_g1;
 wire rows_full=(write_gray==~read_g1);
 wire rows_empty=(read_gray==write_g1);
 wire [1:0] next_write=write_row+1'b1,next_read=read_row+1'b1;
 wire [BANK_AW-1:0] wa=write_row[0]*DST_W+job_x;
 reg request_toggle,fault_toggle;
  reg req0,req1,bad0,bad1;
 reg request_seen,bad_seen,request_pending,source_start,discard_source;
 reg core_abort_d,core_fault_toggle;
 wire source_quiet=source_idle && !active && state==IDLE && !request_pending;
 assign video_abort_event=bad1!=bad_seen;
 assign o_source_start=source_start;
 assign o_source_ready=discard_source || (active && pixel_wait==0 && !rows_full);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   write_row<=0;write_gray<=0;read_g0<=0;read_g1<=0;
   req0<=0;req1<=0;bad0<=0;bad1<=0;request_seen<=0;bad_seen<=0;
   request_pending<=0;source_start<=0;discard_source<=0;core_abort_d<=0;core_fault_toggle<=0;
  end else begin
   read_g0<=read_gray;read_g1<=read_g0;
   req0<=request_toggle;req1<=req0;bad0<=fault_toggle;bad1<=bad0;
   bad_seen<=bad1;source_start<=0;core_abort_d<=core_abort;
   if(core_abort && !core_abort_d) core_fault_toggle<=~core_fault_toggle;
   if(req1!=request_seen) begin request_seen<=req1;request_pending<=1;end
   if(request_pending && source_idle && source_available && !active && state==IDLE) begin
    source_start<=1;request_pending<=0;
   end
   if(raw_sof) discard_source<=0;
   else if(video_abort_event || core_abort) discard_source<=1;
   if(row_ready && !clear) begin
    write_row<=next_write;write_gray<=(next_write>>1)^next_write;
   end
  end
 end
 always @(posedge clk) if(rst_n && !clear) begin
  if(result_valid && result_vertical) begin
  case(result_channel)
   0:red[wa]<=lerp_q;
   1:green[wa]<=lerp_q;
   2:blue[wa]<=lerp_q;
  endcase
 end

 end
 // 在225MHz域用九拍使能模拟原25MHz光栅，不再跨域往返。
 // 行帧计数及分数帧尾沿用原逻辑；每个像素只发出一个时钟的valid。
 localparam PERIOD=VIDEO_CLK_HZ/FRAME_HZ,REM=VIDEO_CLK_HZ%FRAME_HZ;
 localparam TCW=$clog2(PERIOD+2),HCW=$clog2(VIDEO_HT),VCW=$clog2(VIDEO_VT+1);
 localparam FCW=(FRAME_HZ<2)?1:$clog2(FRAME_HZ);
 reg [3:0] tick_divider;
 wire video_tick=tick_divider==8;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)tick_divider<=0;
  else tick_divider<=video_tick ? 0 : tick_divider+1'b1;
 end
 reg available0,available1,idle0,idle1,enable0,enable1,cf0,cf1;
 reg cf_seen;
 reg [HCW-1:0] h;
 reg [VCW-1:0] v;
 reg [TCW-1:0] frame_tick;
 reg [FCW-1:0] fraction;
 reg extra_tick,video_active,video_bad,video_vs,video_abort;
 reg read_valid,read_valid_d,frame_pending,video_href;
 reg [DXW-1:0] emitted_x;
 reg [3:0] href_tail;
 reg [23:0] read_pixel,video_pixel;
 reg video_valid;
 wire period_done=frame_tick==PERIOD-1+extra_tick;
 wire start_video=(!video_active || period_done) && available1 && idle1 && enable1 && rows_empty;
 wire image_line=video_active && v>=VIDEO_VA && v<VIDEO_VA+DST_H;
 wire image_pixel=image_line && h>=VIDEO_HA && h<VIDEO_HA+DST_W;
 wire new_fault=video_active && !video_bad &&
     (!enable || frame_abort || core_abort || (video_tick && image_pixel && rows_empty));
 wire read_pixel_en=image_pixel && !video_bad && !new_fault;
 wire read_issue=video_tick && read_pixel_en;
 wire [BANK_AW-1:0] ra=read_row[0]*DST_W+h-VIDEO_HA;
 wire release_row=(read_pixel_en && h==VIDEO_HA+DST_W-1) ||
     ((video_bad || !video_active) && !rows_empty);
 assign post_img_vsync=video_vs;
 assign post_img_href=video_href;
 assign post_img_clken=video_valid;
 assign post_img_data=video_pixel;
 assign o_frame_abort=video_abort;
 assign o_video_error=video_bad;
 assign o_protocol_error=core_error;
 always @(posedge clk)begin
  if(read_issue)read_pixel<={blue[ra],green[ra],red[ra]};
  if(read_valid)video_pixel<=read_pixel;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   read_row<=0;read_gray<=0;write_g0<=0;write_g1<=0;
   available0<=0;available1<=0;idle0<=0;idle1<=0;enable0<=0;enable1<=0;cf0<=0;cf1<=0;cf_seen<=0;
   h<=0;v<=0;frame_tick<=0;fraction<=0;extra_tick<=0;video_active<=0;video_bad<=0;
   video_vs<=0;video_abort<=0;request_toggle<=0;fault_toggle<=0;read_valid<=0;read_valid_d<=0;video_valid<=0;
   frame_pending<=0;video_href<=0;emitted_x<=0;href_tail<=0;
  end else begin
   video_vs<=0;
   video_abort<=0;
   read_valid<=read_issue;
   read_valid_d<=read_valid && !video_bad && !new_fault;
   video_valid<=read_valid_d && !video_bad && !new_fault && enable;
   // 在首像素前一拍发帧头；所有像素均经过同样的流水，间隔严格为9拍。
   if(read_valid && frame_pending && !video_bad && !new_fault)begin
    video_vs<=1;
    frame_pending<=0;
   end
   if(href_tail!=0)begin
    href_tail<=href_tail-1'b1;
    if(href_tail==1)video_href<=0;
   end
   if(read_valid_d && !video_bad && !new_fault && enable)begin
    video_href<=1;
    if(emitted_x==DST_W-1)begin
     emitted_x<=0;
     href_tail<=9;
    end else emitted_x<=emitted_x+1'b1;
   end
   if(new_fault)begin
    video_bad<=1;
    video_abort<=1;
    fault_toggle<=~fault_toggle;
    frame_pending<=0;
    video_href<=0;
    href_tail<=0;
    emitted_x<=0;
   end
   if(video_tick)begin
    write_g0<=write_gray;
    write_g1<=write_g0;
    available0<=source_available;
    available1<=available0;
    idle0<=source_quiet;
    idle1<=idle0;
    enable0<=enable;
    enable1<=enable0;
    cf0<=core_fault_toggle;
    cf1<=cf0;
    cf_seen<=cf1;
    if(release_row)begin
     read_row<=next_read;
     read_gray<=(next_read>>1)^next_read;
    end
    if(start_video && enable)begin
     h<=0;
     v<=0;
     frame_tick<=0;
     video_active<=1;
     video_bad<=0;
     request_toggle<=~request_toggle;
     frame_pending<=1;
     emitted_x<=0;
     extra_tick<=fraction+REM>=FRAME_HZ;
     fraction<=(fraction+REM>=FRAME_HZ)?fraction+REM-FRAME_HZ:fraction+REM;
    end else if(video_active)begin
     if(period_done)begin
      video_active<=0;
      h<=0;
      v<=0;
     end else begin
      frame_tick<=frame_tick+1'b1;
      if(v<VIDEO_VT)begin
       if(h==VIDEO_HT-1)begin
        h<=0;
        v<=v+1'b1;
       end else h<=h+1'b1;
      end
     end
    end
   end
  end
 end
 `ifndef SYNTHESIS
 initial if(INPUT_GAP<5 || (SRC_W/DST_W)*INPUT_GAP<15 ||
            VIDEO_HA+DST_W>VIDEO_HT || VIDEO_VA+DST_H>VIDEO_VT ||
            VIDEO_HT*VIDEO_VT>PERIOD)
  $fatal(1,"dual-clock scaler: invalid source pacing or video raster");
 always @(posedge clk) if(rst_n && result_valid && result_vertical && rows_full && !clear)
  $fatal(1,"dual-clock scaler overwrote a row owned by the video reader");
 `endif
end endgenerate
endmodule
