//==============================================================================
// raw_to_rgb_v2 : 拜耳插值, 4 RAW 像素/clk 并行版
//
// 由 raw_to_rgb (2px/clk, LEGACY=1) 加宽而来。窗口结构与 v1 完全同构:
//
//   行方向 (垂直): line_buffer_v2 提供
//     i_p_11 = 第 N-2 行 (上上行), i_p_00 = 第 N-1 行 (输出行),
//     i_p_01 = 第 N   行 (当前输入行, 下行)
//   组方向 (水平): 窗口寄存器 0P/1P/2P = 组 x/x-1/x-2 (每拍一组4像素),
//     输出对应组 x-1 的 4 个像素, 整体比输入滞后 2 拍 (o_de 为 2P 延迟)。
//
//   3x3 邻域 (输出像素位于中央 *):
//     i_p_11:  a_left  a_own  a_right     (上行,   N-2)
//     i_p_00:  c_left [c_own] c_right     (输出行, N-1)
//     i_p_01:  b_left  b_own  b_right     (下行,   N)
//   组内越界: k=0 的左邻取 2P 组 pos3; k=3 的右邻取 0P 组 pos0。
//
// 插值核 (与 v1 逐比特一致, 按 GRBG 邻域展开; 注意 rgb_gain_v2 的增益
// 图案按 GBRG 映射, R/B 增益相对插值核是互换的 —— 原版即如此, 保留):
//   输出行偶 (v1 的 r_y_cnt[0]==1 分支, 输入行 N 为奇):
//     偶列 G: R=(水平均值), G=自身, B=(垂直均值)
//     奇列 R: R=自身,       G=(4邻均值),  B=(4对角均值)
//   输出行奇 (v1 的 r_y_cnt[0]==0 分支):
//     偶列 B: R=(4对角均值), G=(4邻均值), B=自身
//     奇列 G: R=(垂直均值),  G=自身,      B=(水平均值)
//
// Boundary behavior: retain vertical/line-tail scheduling; prime the left edge.
//   - 帧首: 第0行输入时三行全部用 i_p_01 (垂直钳位), 第1行输入时上行
//     钳位到 i_p_00 => 输出帧第0行发两次、最后一行不发 (行数守恒);
//   - Line start: replicate the first real RAW group into 1P/2P, retaining Bayer parity.
//   - 行尾: 输出组0..G-2, 每行比输入少最后一组 (与 v1 少 2px 同构)。
//
// 与 v1 的唯一结构性差异: 窗口移位/装载/组计数全部用 i_valid 门控
// (v1 移位不门控, 依赖 valid==de 无气泡)。valid==de 时行为与 v1 等价,
// 若上游 valid 存在气泡, v2 仍保持窗口对齐 (v1 会错位)。
//==============================================================================
module raw_to_rgb_v2
#(
	parameter	P_DEPTH			= 8,
	// [V7.7 相位校正] 传感器图案相位: bit0=列奇偶翻转, bit1=行奇偶翻转。
	// 本核默认模板 GRBG(对角G); 传感器为反对角G族时必须翻转:
	//   PHASE=2'b01 -> 模板 RGGB   PHASE=2'b10 -> 模板 BGGR
	// IMX219 实测为反对角G族(绿显示为红 => G 位点不重合), 按内核驱动 SBGGR10
	// 判定 BGGR => PHASE=2'b10。默认 2'b00 保持 v1 逐比特等价(回归TB可用)。
	parameter	PHASE			= 2'b00
)
(
	input			i_arstn,
	input			i_pclk,
	
	input			i_vsync,
	input			i_hsync,
	input			i_de,
	input			i_valid,
	input	[P_DEPTH*4-1:0]	i_p_11,
	input	[P_DEPTH*4-1:0]	i_p_00,	
	input	[P_DEPTH*4-1:0]	i_p_01,
	
	output			o_vsync,
	output			o_hsync,
	output			o_de,
	output			o_valid,
	output	[10:0]	o_x_cnt,
	output	[10:0]	o_y_cnt,
	output	[P_DEPTH*4-1:0]	o_r,
	output	[P_DEPTH*4-1:0]	o_g,	
	output	[P_DEPTH*4-1:0]	o_b
);

localparam	PW	= P_DEPTH*4;

// 按索引取组内第 idx 个像素 (idx*P_DEPTH +: P_DEPTH)
function [P_DEPTH-1:0] f_px;
	input	[PW-1:0]	grp;
	input	[1:0]		idx;
	begin
		f_px = grp[idx*P_DEPTH +: P_DEPTH];
	end
endfunction

//--------------------------------------------------------------------------
// 同步信号 2 拍流水 (与 v1 相同)
//--------------------------------------------------------------------------
reg	r_vsync_1P;
reg	r_hsync_1P;
reg	r_de_1P;
reg	r_valid_1P;
reg	r_vsync_2P;
reg	r_hsync_2P;
reg	r_de_2P;
reg	r_valid_2P;

always@(posedge i_pclk)
begin
	if (~i_arstn)
	begin
		r_vsync_1P		<= 1'b0;
		r_hsync_1P		<= 1'b0;
		r_de_1P			<= 1'b0;	
		r_valid_1P		<= 1'b0;	
		r_vsync_2P		<= 1'b0;
		r_hsync_2P		<= 1'b0;
		r_de_2P			<= 1'b0;	
		r_valid_2P		<= 1'b0;	
	end else begin
		r_vsync_1P		<= i_vsync;
		r_hsync_1P		<= i_hsync;
		r_de_1P			<= i_de;
		r_valid_1P		<= i_valid;
		r_vsync_2P		<= r_vsync_1P;
		r_hsync_2P		<= r_hsync_1P;
		r_de_2P			<= r_de_1P;
		r_valid_2P		<= r_valid_1P;
	end
end 

//--------------------------------------------------------------------------
// 行尾去抖 [气泡修复]: v1 依赖 gearbox 提供无气泡 de, v2 直挂 CSI,
// 行内 de 可能有短气泡 —— 原来的 "DE 下降沿" 判定会把气泡当行尾:
//   y_cnt 假翻转 (整帧核相位错) + x_cnt 假清零 (窗口被当行首清 1P/2P
//   => 输出全零组 = 4 黑像素条纹)。改为 de 拉低 >= 8 拍才判定真行尾。
//--------------------------------------------------------------------------
reg	[2:0]			r_de_low_cnt;
reg				r_de_seen;
reg				r_line_end;

always@(posedge i_pclk)
begin
	if (~i_arstn) begin
		r_de_low_cnt	<= 3'd0;
		r_de_seen	<= 1'b0;
		r_line_end	<= 1'b0;
	end else begin
		r_line_end	<= 1'b0;			//默认单拍脉冲
		if (i_de) begin
			r_de_low_cnt	<= 3'd0;
			r_de_seen	<= 1'b1;
		end else begin
			if (r_de_low_cnt != 3'd7)
				r_de_low_cnt <= r_de_low_cnt + 1'b1;
			if (r_de_low_cnt == 3'd7 && r_de_seen) begin
				r_line_end	<= 1'b1;	//低电平已 8 拍且本行有数据 => 真行尾
				r_de_seen	<= 1'b0;	//长消隐期间不重复触发
			end
		end
	end
end

//--------------------------------------------------------------------------
// 行/组计数 (v1: y_cnt 在 DE 下降沿+1, vs 下降沿清零;
//           x_cnt 这里改为 valid 门控, valid==de 时与 v1 等价)
//--------------------------------------------------------------------------
reg	[10:0]			r_x_cnt;
reg	[10:0]			r_x_cnt_1P;
reg	[10:0]			r_x_cnt_2P;
reg	[10:0]			r_y_cnt;
reg	[10:0]			r_y_cnt_1P;
reg	[10:0]			r_y_cnt_2P;

always@(posedge i_pclk)
begin
	if (~i_arstn)
		r_y_cnt	<= 11'b0;
	else if (!i_vsync && r_vsync_1P)		//vs 下降沿
		r_y_cnt	<= 11'b0;
	else if (r_line_end)			//去抖行尾 [气泡修复] (原: DE 下降沿)
		r_y_cnt <= r_y_cnt + 1'b1;
end 

always@(posedge i_pclk)
begin
	if (~i_arstn)
		r_x_cnt <= 11'b0;
	else if (r_line_end)			//仅真行尾清零 [气泡修复] (原: !i_de, 气泡会假清零)
		r_x_cnt	<= 11'b0;
	else if (i_valid)
		r_x_cnt	<= r_x_cnt + 1'b1;
end

always@(posedge i_pclk)
begin
	if (~i_arstn) begin 
		r_x_cnt_1P			<= 11'b0;
		r_x_cnt_2P			<= 11'b0;
	end else begin
		r_x_cnt_1P			<= r_x_cnt;
		r_x_cnt_2P          <= r_x_cnt_1P;
	end
end 

always@(posedge i_pclk)
begin
	if (~i_arstn) begin 
		r_y_cnt_1P			<= 11'b0;
		r_y_cnt_2P			<= 11'b0;
	end else begin 
		r_y_cnt_1P			<= r_y_cnt;
		r_y_cnt_2P          <= r_y_cnt_1P;
	end 
end 

//--------------------------------------------------------------------------
// 3x3 窗口寄存器: 每行(上/中/下) × 3 个组延迟(0P/1P/2P) × 4 像素
// 行输入的 LEGACY 钳位与 v1 一致 (在装载时刻选择):
//   N==0 : 上行/中行都用 i_p_01 (第0行)
//   N==1 : 上行用 i_p_00       (钳到第0行)
//--------------------------------------------------------------------------
reg	[PW-1:0]	r_a_0P;		// 上行  (N-2) 组 x
reg	[PW-1:0]	r_a_1P;		//        组 x-1
reg	[PW-1:0]	r_a_2P;		//        组 x-2
reg	[PW-1:0]	r_c_0P;		// 中行  (N-1) 组 x
reg	[PW-1:0]	r_c_1P;		//        组 x-1
reg	[PW-1:0]	r_c_2P;		//        组 x-2
reg	[PW-1:0]	r_b_0P;		// 下行  (N)   组 x
reg	[PW-1:0]	r_b_1P;		//        组 x-1
reg	[PW-1:0]	r_b_2P;		//        组 x-2

// For the first real output row (N=1), mirror RAW row 1 above row 0.
// Repeating RAW row 0 vertically changes the Bayer colour phase.
wire [PW-1:0]	w_a_in = (r_y_cnt == 11'd0) ? i_p_01 :
	                   (r_y_cnt == 11'd1) ? i_p_01 : i_p_11;
wire [PW-1:0]	w_c_in = (r_y_cnt == 11'd0) ? i_p_01 : i_p_00;
wire [PW-1:0]	w_b_in = i_p_01;

always@(posedge i_pclk)
begin
	if (~i_arstn)
	begin
		r_a_0P <= {PW{1'b0}};
		r_a_1P <= {PW{1'b0}};
		r_a_2P <= {PW{1'b0}};
		r_c_0P <= {PW{1'b0}};
		r_c_1P <= {PW{1'b0}};
		r_c_2P <= {PW{1'b0}};
		r_b_0P <= {PW{1'b0}};
		r_b_1P <= {PW{1'b0}};
		r_b_2P <= {PW{1'b0}};
	end
	else if (i_valid)
	begin
		r_a_0P	<= w_a_in;
		r_c_0P	<= w_c_in;
		r_b_0P	<= w_b_in;
		if (r_x_cnt == 11'd0) begin
			// Fill the live startup window from real edge pixels, without shifting valid/HS.
			r_a_1P	<= w_a_in;
			r_a_2P	<= w_a_in;
			r_c_1P	<= w_c_in;
			r_c_2P	<= w_c_in;
			r_b_1P	<= w_b_in;
			r_b_2P	<= w_b_in;
		end else begin
			r_a_1P	<= r_a_0P;
			r_a_2P	<= r_a_1P;
			r_c_1P	<= r_c_0P;
			r_c_2P	<= r_c_1P;
			r_b_1P	<= r_b_0P;
			r_b_2P	<= r_b_1P;
		end
	end
end 

//--------------------------------------------------------------------------
// 4 路并行插值核 (完全展开, 每像素的邻域选择均为常量)
// 输出行奇偶沿用 v1 判据: r_y_cnt[0] (输入行 N 奇偶, 输出行 = N-1)
//--------------------------------------------------------------------------
genvar k;
generate
for (k=0; k<4; k=k+1) begin : g_px
	localparam [1:0] KP = k;

	//输出行 (中行 c=1P 组) 像素自身及左右邻
	wire [P_DEPTH-1:0] w_c_own   = f_px(r_c_1P, KP);
	wire [P_DEPTH-1:0] w_c_left  = (KP == 2'd0) ? f_px(r_c_2P, 2'd3) : f_px(r_c_1P, KP - 2'd1);
	wire [P_DEPTH-1:0] w_c_right = (KP == 2'd3) ? f_px(r_c_0P, 2'd0) : f_px(r_c_1P, KP + 2'd1);
	//上行 (a) 同列及左右邻
	wire [P_DEPTH-1:0] w_a_own   = f_px(r_a_1P, KP);
	wire [P_DEPTH-1:0] w_a_left  = (KP == 2'd0) ? f_px(r_a_2P, 2'd3) : f_px(r_a_1P, KP - 2'd1);
	wire [P_DEPTH-1:0] w_a_right = (KP == 2'd3) ? f_px(r_a_0P, 2'd0) : f_px(r_a_1P, KP + 2'd1);
	//下行 (b) 同列及左右邻
	wire [P_DEPTH-1:0] w_b_own   = f_px(r_b_1P, KP);
	wire [P_DEPTH-1:0] w_b_left  = (KP == 2'd0) ? f_px(r_b_2P, 2'd3) : f_px(r_b_1P, KP - 2'd1);
	wire [P_DEPTH-1:0] w_b_right = (KP == 2'd3) ? f_px(r_b_0P, 2'd0) : f_px(r_b_1P, KP + 2'd1);

	//公共部分和
	wire [P_DEPTH  :0] w_hsum = w_c_left  + w_c_right;		//水平 2 点和
	wire [P_DEPTH  :0] w_vsum = w_a_own   + w_b_own;		//垂直 2 点和
	wire [P_DEPTH+1:0] w_nsum = w_c_left  + w_c_right + w_a_own + w_b_own;	//4 邻和
	wire [P_DEPTH+1:0] w_dsum = w_a_left  + w_a_right + w_b_left + w_b_right;	//4 对角和

	//按 (输出行奇偶, 列奇偶) 选核, 均值 = 和>>1 / 和>>2 (低位截断, 与 v1 相同):
	//  输出行偶 (r_y_cnt[0]==1, 对应 v1 该分支):
	//    偶列 G: R=水平均值  G=自身      B=垂直均值
	//    奇列 R: R=自身      G=4邻均值   B=对角均值
	//  输出行奇 (r_y_cnt[0]==0):
	//    偶列 B: R=对角均值  G=4邻均值   B=自身
	//    奇列 G: R=垂直均值  G=自身      B=水平均值
	// [V7.7] 奇偶均经 PHASE 异或, 实现传感器图案相位校正
	wire		krow = r_y_cnt[0] ^ PHASE[1];
	wire		kcol = KP[0]   ^ PHASE[0];

	wire [P_DEPTH-1:0] w_r_k = krow ?
			(kcol ? w_c_own : (w_hsum >> 1)) :
			(kcol ? (w_vsum >> 1) : (w_dsum >> 2));

	wire [P_DEPTH-1:0] w_g_k = krow ?
			(kcol ? (w_nsum >> 2) : w_c_own) :
			(kcol ? w_c_own : (w_nsum >> 2));

	wire [P_DEPTH-1:0] w_b_k = krow ?
			(kcol ? (w_dsum >> 2) : (w_vsum >> 1)) :
			(kcol ? (w_hsum >> 1) : w_c_own);

	reg	[P_DEPTH-1:0]	r_r_k;
	reg	[P_DEPTH-1:0]	r_g_k;
	reg	[P_DEPTH-1:0]	r_b_k;

	always@(posedge i_pclk)
	begin
		if (~i_arstn) begin
			r_r_k	<= {P_DEPTH{1'b0}};
			r_g_k	<= {P_DEPTH{1'b0}};
			r_b_k	<= {P_DEPTH{1'b0}};
		end
		else if (!r_de_1P) begin
			//DE 无效窗口清零 (与 v1 相同)
			r_r_k	<= {P_DEPTH{1'b0}};
			r_g_k	<= {P_DEPTH{1'b0}};
			r_b_k	<= {P_DEPTH{1'b0}};
		end
		else if (r_valid_1P) begin
			r_r_k	<= w_r_k;
			r_g_k	<= w_g_k;
			r_b_k	<= w_b_k;
		end
	end
end
endgenerate

assign	o_vsync	= r_vsync_2P;
assign	o_hsync	= r_hsync_2P;
assign	o_de	= r_de_2P;
assign	o_valid	= r_valid_2P;
assign	o_x_cnt	= r_x_cnt_2P;	
assign	o_y_cnt	= r_y_cnt_2P;
assign	o_r		= {g_px[3].r_r_k, g_px[2].r_r_k, g_px[1].r_r_k, g_px[0].r_r_k};
assign	o_g		= {g_px[3].r_g_k, g_px[2].r_g_k, g_px[1].r_g_k, g_px[0].r_g_k};
assign	o_b		= {g_px[3].r_b_k, g_px[2].r_b_k, g_px[1].r_b_k, g_px[0].r_b_k};

endmodule
