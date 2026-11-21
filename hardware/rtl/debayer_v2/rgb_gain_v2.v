//==============================================================================
// rgb_gain_v2 : 白平衡增益, 4 RAW 像素/clk 并行版
//
// 由 rgb_gain_v1 (2px/clk) 加宽而来, 逐像素行为与 v1 完全一致:
//   - Q8.8 定点增益, 饱和到 P_DEPTH 位
//   - 行奇偶 r_line_cnt 与 v1 同源: vs 下降沿清零, DE 下降沿翻转
//   - 增益图案沿用 v1 (按 GBRG 假设; 注意 raw_to_rgb_v2 的插值核按 GRBG
//     取邻域, 两者 R/B 相对 v1 即是互换的, v2 原样保留以保证输出一致):
//       偶数行: 偶列=Gb(gain_g)  奇列=B (gain_b)
//       奇数行: 偶列=R (gain_r)  奇列=Gr(gain_g)
//
// 输入  i_data : {px3,px2,px1,px0}, px0=[7:0] 为本拍最左(最先)像素
// 输出  o_data : 同序, 同步信号延迟 1 拍 (与 v1 相同)
//==============================================================================
module rgb_gain_v2
#(
	parameter	P_DEPTH			= 8,
	parameter	Q_WIDTH			= 16,	// Q8.8定点
	// [V7.7 相位校正] 与 raw_to_rgb_v2/PHASE 配套但取值不同:
	// 本模块默认位点模板 GBRG, raw_to_rgb_v2 默认 GRBG (两者 R/B 位点互换, 历史如此)。
	//   传感器 RGGB => 本模块 PHASE=2'b10 (行翻转)
	//   传感器 BGGR => 本模块 PHASE=2'b01 (列翻转)
	parameter	PHASE			= 2'b00
)
(
	input               i_pclk,
	input               i_arstn,

	input 		        i_hs,
	input               i_vs,
	input				i_de,
	input				i_valid,
	input [P_DEPTH*4-1:0]  		i_data,

	input [Q_WIDTH-1:0]	gain_r,
	input [Q_WIDTH-1:0]	gain_g,
	input [Q_WIDTH-1:0]	gain_b,

	output  reg             o_hs,
	output	reg				o_vs,
	output	reg				o_de,
	output	reg				o_valid,
	output  reg [P_DEPTH*4-1:0]  	o_data
);

reg				r_hs_1P;
reg				r_de_1P;
reg				r_vs_1P;
reg				r_valid_1P;
reg				r_line_cnt;

//同步信号打一拍
always@(posedge i_pclk)
begin
	if (!i_arstn) begin
		r_hs_1P		<= 1'b0;
		r_de_1P		<= 1'b0;
		r_vs_1P		<= 1'b0;
		r_valid_1P	<= 1'b0;
	end else begin
		r_hs_1P		<= i_hs;
		r_de_1P		<= i_de;
		r_vs_1P		<= i_vs;
		r_valid_1P	<= i_valid;
	end
end

//行尾去抖 [气泡修复]: CSI 行内 de 可能有短气泡, 原 "DE 下降沿" 翻转会把
//气泡当行尾 -> 行奇偶错 -> 增益图案错位。改为 de 拉低 >= 8 拍才翻转。
reg	[2:0]	r_de_low_cnt;
reg		r_de_seen;
reg		r_line_end;

always @( posedge i_pclk )
begin
	if( !i_arstn ) begin
		r_de_low_cnt	<= 3'd0;
		r_de_seen	<= 1'b0;
		r_line_end	<= 1'b0;
	end else begin
		r_line_end	<= 1'b0;		//默认单拍脉冲
		if (i_de) begin
			r_de_low_cnt	<= 3'd0;
			r_de_seen	<= 1'b1;
		end else begin
			if (r_de_low_cnt != 3'd7)
				r_de_low_cnt <= r_de_low_cnt + 1'b1;
			if (r_de_low_cnt == 3'd7 && r_de_seen) begin
				r_line_end	<= 1'b1;
				r_de_seen	<= 1'b0;
			end
		end
	end
end

//行标记切换
always @( posedge i_pclk )
begin
	if( !i_arstn )
		r_line_cnt <= 'd0;
	else if (r_vs_1P && !i_vs)
		r_line_cnt	<= 1'b0;
	else if(r_line_end)		//去抖行尾 (原: r_valid_1P && r_de_1P && !i_de)
		r_line_cnt 	<= ~r_line_cnt;
end

wire [P_DEPTH*4-1:0] w_data_filtered;

genvar gi;
generate
for (gi=0; gi<4; gi=gi+1) begin : g_gain
	//按 (行奇偶, 列奇偶) 选择通道增益, 图案与 rgb_gain_v1 一致 (经 PHASE 校正)
	wire gl = r_line_cnt ^ PHASE[1];
	wire gc = gi[0]      ^ PHASE[0];
	wire [Q_WIDTH-1:0] w_gain = gl ? (gc ? gain_g : gain_r)
	                               : (gc ? gain_b : gain_g);

	wire [Q_WIDTH+P_DEPTH-1:0] w_mul = i_data[gi*P_DEPTH +: P_DEPTH] * w_gain;

	//Q8.8 右移8位 + 饱和 (与 v1 相同: 仅支持 Q_WIDTH=16)
	wire [P_DEPTH-1:0] w_sat = (|w_mul[Q_WIDTH+P_DEPTH-1:P_DEPTH+8]) ?
	                           {P_DEPTH{1'b1}} : w_mul[P_DEPTH+7:8];

	assign w_data_filtered[gi*P_DEPTH +: P_DEPTH] = w_sat;
end
endgenerate

always @( posedge i_pclk )
begin
	o_hs	<= i_hs;
	o_de	<= i_de;
	o_vs	<= i_vs;
	o_valid	<= i_valid;
	o_data	<= w_data_filtered;
end

endmodule
