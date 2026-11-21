`timescale 1ns / 1ps
//==============================================================================
// lerp_dsp24.v -- EFX_DSP24 原语的三通道 8bit 线性插值单元 (2 拍流水)
//
// 功能: q = (u*(256-w) + v*w + 128) >> 8     逐字节独立, 字节序 {B,G,R} 保持
//       (与原 scaler_line_96.f_lerp / tb 黄金模型 g_herp 逐位一致)
//
// DSP 映射 (代数恒等式变形, 每通道 1 个 DSP 完成"乘+加"):
//   t = u*(256-w) + v*w + 128
//     = w*(v-u+256) + (u-w)*256 + 128                  -- 整数域恒等
//   令 d = v-u+256 (9b 无符号 [1,511]), dh=d[8], dl=d[7:0]:
//     t = w*dl + (dh*w + u - w)*256 + 128
//       = w*dl + C,   C = (m << 8) + 128,  m = dh ? u : (u-w)   (9b 有符号)
//   => EFX_DSP24: A = w (8b), B = dl (8b), C[7:0] 经 C 端口 (8b) 输入,
//      C[23:8] 在 fabric 加法器中补回, O = A*B + C (mod 2^24), 结果字节 = O[15:8]
//      (CASCIN 在单 DSP 模式下只能接 GND/CASCOUT, 不能作数据输入)
//      (t ∈ [0,65408] 无符号, 24b 回绕不损失; C ∈ [-65152,65408] 有符号)
//
// 原语配置与 cnn_accel/rtl/cnn_dsp.v 已验证模板完全一致:
//   全寄存器旁路(组合), SIGNED(0), OP=2'b00 (P+C), M_SEL="P", N_SEL="C"。
//
// 流水 (2 拍, 吞吐 1 lerp/clk):
//   t   : i_ce=1, 窗口 mux/加减组合完成, 锁存 DSP 输入 (A/B/C)
//   t+1 : EFX_DSP24 组合乘加 (专用硬块)
//   t+2 : o_q/o_qv 有效
//   原 "mux+乘+加+截位" 单拍长路径被切成两短拍, 乘加全部进 DSP。
//
// 仿真: iverilog 加宏 -DEFX_DSP_MODEL 用行为模型;
//       综合(Efinity)不定义宏 -> 直接例化 EFX_DSP24 原语。
//==============================================================================

//------------------------------------------------------------------------------
// efx_dsp24_mac : 单通道 O = A*B + C (全组合)
//   A/B 为 8bit 无符号, C 为 24bit 有符号(补码), 加法按 mod 2^24 回绕
//------------------------------------------------------------------------------
module efx_dsp24_mac (
	input  wire               i_clk,   // 保留兼容接口，组合原语CLK须接常量
	input  wire [7:0]         a,       // 乘数 (无符号)
	input  wire [7:0]         b,       // 被乘数 (无符号)
	input  wire signed [23:0] c,       // 累加输入; 本模块只使用低 8bit C[7:0]
	output wire signed [23:0] o        // = a*b + C[7:0] (mod 2^24)
);

`ifdef EFX_DSP_MODEL
	//---- 仿真行为模型 ----
	wire [15:0] prod = a * b;
	assign o = $signed({8'b0, prod}) + c[7:0];
`else
	//---- 综合实现: 易灵思 DSP24 原语 (单 DSP, CASCIN 接地) ----
	EFX_DSP24 #(
		.A_REG(0), .B_REG(0), .C_REG(0), .P_REG(0), .OP_REG(0),
		.W_REG(0), .O_REG(0),
		.RST_SYNC(0),
		.SIGNED(0),
		.P_EXT("ALIGN_RIGHT"), .C_EXT("ALIGN_RIGHT"),
		.M_SEL("P"), .N_SEL("C"), .W_SEL("X"), .CASCOUT_SEL("W"),
		.CLK_POLARITY(1), .CE_POLARITY(1), .RST_POLARITY(1),
		.SHIFT_ENA_POLARITY(1),
		.A_REG_USE_CE(0), .B_REG_USE_CE(0), .C_REG_USE_CE(0),
		.OP_REG_USE_CE(0), .P_REG_USE_CE(0), .W_REG_USE_CE(0),
		.O_REG_USE_CE(0),
		.A_REG_USE_RST(0), .B_REG_USE_RST(0), .C_REG_USE_RST(0),
		.OP_REG_USE_RST(0), .P_REG_USE_RST(0), .W_REG_USE_RST(0),
		.O_REG_USE_RST(0)
	) u_dsp (
		.A(a),
		.B(b),
		.C(c[7:0]),        // 原语 C 端口为 8bit
		.CASCIN(24'd0),    // 单 DSP 模式必须接地 (GND)
		.OP(2'b00),        // 00 = P + C (累加模式)
		.SHIFT_ENA(1'b0),  // SHIFTER=0 时必须 disable shifter
		.CLK(1'b0),        // 无内部寄存器时Efinity要求禁用CLK，不影响外部两拍流水
		.CE(1'b0),         // 原语寄存器全部旁路；有效使能由外部流水寄存器控制
		.RST(1'b0),        // 无内部寄存器, 复位不参与功能
		.O(o),
		.CASCOUT()
	);
`endif

endmodule

//------------------------------------------------------------------------------
// lerp_dsp24 : 三通道 (B,G,R) 流水化线性插值, 延迟 2 拍
//   i_ce 拍锁存输入; o_qv 与 o_q 同拍有效, 每个锁存拍恰产生一个 o_qv 脉冲
//------------------------------------------------------------------------------
module lerp_dsp24 (
	input  wire        i_clk,
	input  wire        i_rst_n,
	input  wire        i_ce,     // 本拍 i_u/i_v/i_w 有效
	input  wire [23:0] i_u,      // 左/顶像素 {B,G,R}
	input  wire [23:0] i_v,      // 右/底像素 {B,G,R}
	input  wire [7:0]  i_w,      // 插值权重 0..255 (0=取u, 255≈取v)
	output reg         o_qv,     // 结果有效 (i_ce 后 2 拍)
	output reg  [23:0] o_q       // 插值结果 {B,G,R}
);

//---- S1: DSP 输入计算 (恒等式: t = w*dl + C) ----
// d = v-u+256 ∈ [1,511]: dh=1 (v>=u) 时 dl=v-u; dh=0 时 dl=v-u+256
wire [8:0] d_b = {1'b0, i_v[23:16]} - {1'b0, i_u[23:16]} + 9'd256;
wire [8:0] d_g = {1'b0, i_v[15:8]}  - {1'b0, i_u[15:8]}  + 9'd256;
wire [8:0] d_r = {1'b0, i_v[7:0]}   - {1'b0, i_u[7:0]}   + 9'd256;
// m = dh ? u : (u-w)  (9b 有符号; dh=1 时 C = (u<<8)+128)
wire [8:0] m_b = d_b[8] ? {1'b0, i_u[23:16]} : ({1'b0, i_u[23:16]} - {1'b0, i_w});
wire [8:0] m_g = d_g[8] ? {1'b0, i_u[15:8]}  : ({1'b0, i_u[15:8]}  - {1'b0, i_w});
wire [8:0] m_r = d_r[8] ? {1'b0, i_u[7:0]}   : ({1'b0, i_u[7:0]}   - {1'b0, i_w});

reg [7:0]         r_a;                      // A = w (三通道共享)
reg [7:0]         r_bb, r_bg, r_br;         // B = dl
reg signed [23:0] r_cb, r_cg, r_cr;         // C 符号扩展 (低字节恒 8'h80)
reg               r_qv1;

always @(posedge i_clk) begin
	if (!i_rst_n) begin
		r_a   <= 8'd0;
		r_bb  <= 8'd0;  r_bg  <= 8'd0;  r_br  <= 8'd0;
		r_cb  <= 24'sd0; r_cg  <= 24'sd0; r_cr  <= 24'sd0;
		r_qv1 <= 1'b0;
	end else begin
		r_qv1 <= i_ce;
		if (i_ce) begin
			r_a   <= i_w;
			r_bb  <= d_b[7:0];
			r_bg  <= d_g[7:0];
			r_br  <= d_r[7:0];
			r_cb  <= {{7{m_b[8]}}, m_b, 8'h80};
			r_cg  <= {{7{m_g[8]}}, m_g, 8'h80};
			r_cr  <= {{7{m_r[8]}}, m_r, 8'h80};
		end
	end
end

//---- S2: DSP 低 8bit 乘加 + fabric 高位补回 + 输出寄存 ----
wire signed [23:0] o_b, o_g, o_r;

efx_dsp24_mac u_b (.i_clk(i_clk), .a(r_a), .b(r_bb), .c(r_cb), .o(o_b));
efx_dsp24_mac u_g (.i_clk(i_clk), .a(r_a), .b(r_bg), .c(r_cg), .o(o_g));
efx_dsp24_mac u_r (.i_clk(i_clk), .a(r_a), .b(r_br), .c(r_cr), .o(o_r));

// C[23:8] 在 fabric 中补回 (左移 8 位: r_cb[23:8] 代表 m*256)
wire signed [23:0] c_high_b = { {8{r_cb[23]}}, r_cb[23:8] };
wire signed [23:0] c_high_g = { {8{r_cg[23]}}, r_cg[23:8] };
wire signed [23:0] c_high_r = { {8{r_cr[23]}}, r_cr[23:8] };
wire signed [23:0] fb_b = o_b + (c_high_b <<< 8);
wire signed [23:0] fb_g = o_g + (c_high_g <<< 8);
wire signed [23:0] fb_r = o_r + (c_high_r <<< 8);

always @(posedge i_clk) begin
	if (!i_rst_n) begin
		o_qv <= 1'b0;
		o_q  <= 24'd0;
	end else begin
		o_qv <= r_qv1;
		if (r_qv1)
			o_q <= {fb_b[15:8], fb_g[15:8], fb_r[15:8]};
	end
end

endmodule
