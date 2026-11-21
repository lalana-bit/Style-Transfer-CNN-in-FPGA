//==============================================================================
// debayer_top_4to1 : 拜耳去马赛克顶层, 4 RAW/clk -> 4 RGB/clk
//
// 由 debayer_top_2to1 (2RAW -> 2RGB) 加宽而来, 三级流水结构不变:
//   rgb_gain_v2 (白平衡) -> line_buffer_v2 (双行乒乓) -> raw_to_rgb_v2 (插值)
//
// 用途: 直接挂接 CSI RX 域 (i_mipi_rx_pclk), 输入 4×RAW8/拍,
//       彻底取代 raw_gearbox_4to2 + debayer_top_2to1 链路 (无 CDC)。
//
// 输入:  raw_datax4_i[31:0] = {px3,px2,px1,px0}, px0=[7:0] 为本拍最左像素
//        (与 gearbox 输出的 gb_raw 打包序一致: 低字节在前)
// 输出:  rgb_datax4_o[95:0] = {B3,G3,R3, B2,G2,R2, B1,G1,R1, B0,G0,R0}
//        px0 在最低 24bit, 可直连 frame_buffer 写侧 (I_VID_WIDTH=96)
//        rgb_rout/gout/bout[31:0] 为 4 像素独立分量 (调试用)
//==============================================================================
module debayer_top_4to1
#(
	parameter	P_DEPTH	= 8,
	// 传感器拜耳图案: 0=GRBG, 1=GBRG, 2=RGGB, 3=BGGR
	// 实测判定: 绿物体显示为红 => 传感器为反对角G族(RGGB/BGGR);
	// IMX219 按内核驱动 SBGGR10 判定取 3=BGGR。若上板后变为单纯红蓝对调,
	// 改为 2=RGGB 即可。
	parameter	SENSOR_PATTERN	= 0,
	// Maximum camera line width, before scaling; four RAW pixels per word.
	parameter MAX_LINE_PIXELS = 1920
)
(
	input			in_pclk,
	input			in_rstn,
	
	input			raw_vs_i,
	input			raw_hs_i,
	input			raw_de_i,
	input			raw_valid_i,
	input	[P_DEPTH*4-1:0]	raw_datax4_i,
	input	[15:0]	r_gain,
	input	[15:0]	g_gain,
	input	[15:0]	b_gain,
	
	output			rgb_vs_o,
	output			rgb_hs_o,
	output			rgb_de_o,
	output			rgb_valid_o,
	output	[P_DEPTH*4-1:0]	rgb_rout,
	output	[P_DEPTH*4-1:0]	rgb_gout,
	output	[P_DEPTH*4-1:0]	rgb_bout,
	output	[P_DEPTH*4*3-1:0]	rgb_datax4_o
);

// 相位换算: 核默认模板 GRBG, 增益默认模板 GBRG。phase bit0/bit1 分别翻列/翻行。
//   SENSOR_PATTERN 0/1/2/3: 核相位 00/11/01/10, 增益相位 11/00/10/01
localparam	K_PHASE = (SENSOR_PATTERN == 1) ? 2'b11 :
                      (SENSOR_PATTERN == 2) ? 2'b01 :
                      (SENSOR_PATTERN == 3) ? 2'b10 : 2'b00;
localparam	G_PHASE = (SENSOR_PATTERN == 0) ? 2'b11 :
                      (SENSOR_PATTERN == 2) ? 2'b10 :
                      (SENSOR_PATTERN == 3) ? 2'b01 : 2'b00;

wire	        w_gain_vs;
wire	        w_gain_hs;
wire	        w_gain_de;
wire	        w_gain_valid;
wire	[P_DEPTH*4-1:0]	w_gain_data;

rgb_gain_v2
#(
	.P_DEPTH	(P_DEPTH	),
	.Q_WIDTH	(16		),
	.PHASE		(G_PHASE	)
)
inst_rgb_gain
(
	.i_pclk		(in_pclk		),
	.i_arstn	(in_rstn		),
	.i_hs		(raw_hs_i		),
	.i_vs		(raw_vs_i		),
	.i_de		(raw_de_i		),
	.i_valid	(raw_valid_i		),
	.i_data		(raw_datax4_i		),
	
	.gain_b 	(b_gain		),
	.gain_g 	(g_gain		),
	.gain_r 	(r_gain		),
	
	.o_hs		(w_gain_hs		),
	.o_vs		(w_gain_vs		),
	.o_de		(w_gain_de		),
	.o_valid	(w_gain_valid		),
	.o_data		(w_gain_data		)
);

// Round each ping-pong half to a power of two. 1920 pixels need 480 words,
// so 512 words per half suffice; larger cameras can override the parameter.
localparam LINE_WORDS = (MAX_LINE_PIXELS + 3) / 4;
localparam LINE_ADDR_WIDTH = (LINE_WORDS < 2) ? 1 : $clog2(LINE_WORDS);
`ifndef SYNTHESIS
initial if(MAX_LINE_PIXELS<1)
    $fatal(1,"debayer_top_4to1: MAX_LINE_PIXELS must be positive");
`endif

wire	        w_lb_hs;
wire	        w_lb_vs;
wire	        w_lb_de;
wire	        w_lb_valid;
wire	[P_DEPTH*4-1:0]	w_lb_p_11;
wire	[P_DEPTH*4-1:0]	w_lb_p_00;
wire	[P_DEPTH*4-1:0]	w_lb_p_01;

line_buffer_v2
#(
	.P_DEPTH	(P_DEPTH	),
	.PW		(P_DEPTH*4	),
	.X_CNT_WIDTH (LINE_ADDR_WIDTH)
)
inst_line_buffer_debayer
(
	.i_arstn	(in_rstn	),
	.i_pclk		(in_pclk	),
	
	.i_vsync	(w_gain_vs	),
	.i_hsync	(w_gain_hs	),
	.i_de		(w_gain_de	),
	.i_valid	(w_gain_valid	),
	.i_p		(w_gain_data	),
	
	.o_vsync	(w_lb_vs	),
	.o_hsync	(w_lb_hs	),
	.o_de		(w_lb_de	),
	.o_valid	(w_lb_valid	),
	.o_p_11		(w_lb_p_11	),
	.o_p_00		(w_lb_p_00	),
	.o_p_01		(w_lb_p_01	)
);

wire		w_debayer_hs;
wire		w_debayer_vs;
wire		w_debayer_de;
wire		w_debayer_valid;
wire	[10:0]	w_debayer_x;
wire	[10:0]	w_debayer_y;
wire	[P_DEPTH*4-1:0]	w_debayer_r;
wire	[P_DEPTH*4-1:0]	w_debayer_g;
wire	[P_DEPTH*4-1:0]	w_debayer_b;

raw_to_rgb_v2
#(
	.P_DEPTH	(P_DEPTH	),
	.PHASE		(K_PHASE	)
)
inst_raw_to_rgb
(
	.i_arstn	(in_rstn	),
	.i_pclk		(in_pclk	),
	
	.i_vsync	(w_lb_vs	),
	.i_hsync	(w_lb_hs	),
	.i_de		(w_lb_de	),
	.i_valid	(w_lb_valid	),
	.i_p_11		(w_lb_p_11	),
	.i_p_00		(w_lb_p_00	),
	.i_p_01		(w_lb_p_01	),
	
	.o_vsync	(w_debayer_vs	),
	.o_hsync	(w_debayer_hs	),
	.o_de		(w_debayer_de	),
	.o_valid	(w_debayer_valid	),
	.o_x_cnt	(w_debayer_x	),
	.o_y_cnt	(w_debayer_y	),
	.o_r		(w_debayer_r	),
	.o_g		(w_debayer_g	),
	.o_b		(w_debayer_b	)
);	

assign		rgb_vs_o 		= w_debayer_vs;	
assign		rgb_hs_o 		= w_debayer_hs;	
assign		rgb_de_o 		= w_debayer_de;	
assign		rgb_valid_o 		= w_debayer_valid;	
assign 		rgb_rout  		= w_debayer_r;
assign 		rgb_gout  		= w_debayer_g;
assign 		rgb_bout  		= w_debayer_b;

//{B3,G3,R3, B2,G2,R2, B1,G1,R1, B0,G0,R0}, px0 在最低 24bit
assign		rgb_datax4_o[23:0]  = {w_debayer_b[ 7:0], w_debayer_g[ 7:0], w_debayer_r[ 7:0]};
assign		rgb_datax4_o[47:24] = {w_debayer_b[15:8], w_debayer_g[15:8], w_debayer_r[15:8]};
assign		rgb_datax4_o[71:48] = {w_debayer_b[23:16],w_debayer_g[23:16],w_debayer_r[23:16]};
assign		rgb_datax4_o[95:72] = {w_debayer_b[31:24],w_debayer_g[31:24],w_debayer_r[31:24]};

endmodule
