`timescale 1ns / 1ps
// Fixed 1280x720 -> 864x486 bilinear scaler, 4 pixels/clock at both interfaces.
// Exact 40:27 coordinates on both axes (no cumulative Q8 step truncation).
// H: at most 3 samples/input beat. V: 4 samples/word. 7 RGB lerps = 21 DSP24.
// One 216 x 96-bit row: READ_FIRST write reads the previous row at the same address.
// Identical BGR byte order and frame/DE interface to scaler_line_96.
// i_hs covers a whole row including DE bubbles; >=2 idle clocks between rows.
// Keep i_vs high through the line/pipeline tail, as in the original pipeline.
module scaler_line_720p_96 (
    input wire i_clk, i_rst_n,
    input wire i_vs, i_hs, i_de,
    input wire [95:0] i_data,
    output reg o_vs, o_de,
    output wire o_href,
    output reg [95:0] o_data
);
reg r_hs_d, r_vs_d;
wire line_start = i_hs & ~r_hs_d;
wire line_end = ~i_hs & r_hs_d;
wire vs_rise = i_vs & ~r_vs_d;
wire vs_fall = ~i_vs & r_vs_d;
reg [3:0] r_hphase;
reg [5:0] r_row_phase;
reg [23:0] r_prev_last;

function [30:0] h_control;
    input [3:0] phase;
    begin case (phase)
        4'd0: h_control = 31'h7f69ed00;
        4'd1: h_control = 31'h000bb571;
        4'd2: h_control = 31'h75e78c68;
        4'd3: h_control = 31'h7d0954da;
        4'd4: h_control = 31'h000b1d4b;
        4'd5: h_control = 31'h7386f442;
        4'd6: h_control = 31'h7aa8bcb4;
        4'd7: h_control = 31'h000a8525;
        4'd8: h_control = 31'h71265c1c;
        4'd9: h_control = 31'h7848248e;
        default: h_control = 31'd0;
    endcase end
endfunction
function [8:0] v_control;
    input [5:0] phase;
    begin case (phase)
        6'd1: v_control = 9'h100;
        6'd2: v_control = 9'h17b;
        6'd3: v_control = 9'h1f6;
        6'd5: v_control = 9'h171;
        6'd6: v_control = 9'h1ed;
        6'd8: v_control = 9'h168;
        6'd9: v_control = 9'h1e3;
        6'd11: v_control = 9'h15e;
        6'd12: v_control = 9'h1da;
        6'd14: v_control = 9'h155;
        6'd15: v_control = 9'h1d0;
        6'd17: v_control = 9'h14b;
        6'd18: v_control = 9'h1c7;
        6'd20: v_control = 9'h142;
        6'd21: v_control = 9'h1bd;
        6'd23: v_control = 9'h138;
        6'd24: v_control = 9'h1b4;
        6'd26: v_control = 9'h12f;
        6'd27: v_control = 9'h1aa;
        6'd29: v_control = 9'h125;
        6'd30: v_control = 9'h1a1;
        6'd32: v_control = 9'h11c;
        6'd33: v_control = 9'h197;
        6'd35: v_control = 9'h112;
        6'd36: v_control = 9'h18e;
        6'd38: v_control = 9'h109;
        6'd39: v_control = 9'h184;
        default: v_control = 9'd0;
    endcase end
endfunction
wire [30:0] h_cfg = h_control(r_hphase);
wire [8:0] v_cfg = v_control(r_row_phase);

always @(posedge i_clk) begin
    if (!i_rst_n) begin
        r_hs_d<=0; r_vs_d<=0; r_hphase<=0; r_row_phase<=0; r_prev_last<=0;
    end else begin
        r_hs_d<=i_hs; r_vs_d<=i_vs;
        if (vs_rise || line_end) r_hphase<=0;
        else if (i_de) r_hphase <= (r_hphase==9) ? 4'd0 : r_hphase+1'b1;
        if (vs_rise) r_row_phase<=0;
        else if (line_end) r_row_phase <= (r_row_phase==39) ? 6'd0 : r_row_phase+1'b1;
        if (i_de) r_prev_last<=i_data[95:72];
    end
end

function [23:0] left_pixel;
    input [1:0] sel;
    input [95:0] cur;
    input [23:0] prev_last;
    begin case (sel)
        0: left_pixel=prev_last;
        1: left_pixel=cur[23:0];
        2: left_pixel=cur[47:24];
        default: left_pixel=cur[71:48];
    endcase end
endfunction
function [23:0] right_pixel;
    input [1:0] sel;
    input [95:0] cur;
    begin case (sel)
        0: right_pixel=cur[23:0];
        1: right_pixel=cur[47:24];
        2: right_pixel=cur[71:48];
        default: right_pixel=cur[95:72];
    endcase end
endfunction
wire [23:0] h_q[0:2];
wire [2:0] h_qv;
genvar lane;
generate for (lane=0;lane<3;lane=lane+1) begin:g_horizontal
    wire [1:0] sel=h_cfg[lane*10+8 +: 2];
    lerp_dsp24 u_h (
        .i_clk(i_clk),.i_rst_n(i_rst_n),.i_ce(i_de & ((lane<2) ? 1'b1 : h_cfg[30])),
        .i_u(left_pixel(sel,i_data,r_prev_last)),.i_v(right_pixel(sel,i_data)),
        .i_w(h_cfg[lane*10 +: 8]),.o_qv(h_qv[lane]),.o_q(h_q[lane])
    );
end endgenerate

// Assemble 2/3 horizontal results into one 4-pixel RAM word. No variable shifter.
reg [71:0] r_pending_data;
reg [1:0] r_pending;
reg [7:0] r_wcol;
wire w_we=h_qv[0] & (r_pending[1] | ((r_pending==1) & h_qv[2]));
reg [95:0] w_wdata;
always @* begin
    case(r_pending)
        1: w_wdata={h_q[2],h_q[1],h_q[0],r_pending_data[23:0]};
        2: w_wdata={h_q[1],h_q[0],r_pending_data[47:0]};
        default: w_wdata={h_q[0],r_pending_data};
    endcase
end
always @(posedge i_clk) begin
    if (!i_rst_n) begin
        r_pending<=0; r_pending_data<=0; r_wcol<=0;
    end else if (vs_rise || line_start) begin
        r_pending<=0; r_wcol<=0;
    end else if(h_qv[0]) begin
        if(w_we) r_wcol<=r_wcol+1'b1;
        case(r_pending)
            0: begin
                r_pending_data<={h_q[2],h_q[1],h_q[0]};
                r_pending<=h_qv[2] ? 2'd3 : 2'd2;
            end
            1: begin
                if(h_qv[2]) r_pending<=0;
                else begin
                    r_pending_data<={h_q[1],h_q[0],r_pending_data[23:0]};
                    r_pending<=3;
                end
            end
            2: begin
                r_pending_data[23:0]<=h_q[2];
                r_pending<=h_qv[2] ? 2'd1 : 2'd0;
            end
            3: begin
                r_pending_data[47:0]<={h_q[2],h_q[1]};
                r_pending<=h_qv[2] ? 2'd2 : 2'd1;
            end
        endcase
    end
end

reg r_emit;
reg [7:0] r_fy;
always @(posedge i_clk) begin
    if(!i_rst_n || vs_rise) begin r_emit<=0; r_fy<=0; end
    else if(line_start) begin r_emit<=v_cfg[8]; r_fy<=v_cfg[7:0]; end
end
// READ_FIRST returns the prior row before this clock overwrites the word.
// Only one memory port is used; horizontal results are already complete words.
// Explicit 512x20 SDP mode avoids automatic inference of ten 1024x10 blocks.
// READ_FIRST returns the previous row before overwriting this word.
wire [99:0] w_ram_in={4'd0,w_wdata};
wire [99:0] w_ram_out;
wire [95:0] w_top=w_ram_out[95:0];
genvar bank;
generate for(bank=0;bank<5;bank=bank+1) begin:g_line_ram
    EFX_RAM10 #(
        .READ_WIDTH(20),.WRITE_WIDTH(20),.WRITE_MODE("READ_FIRST"),.OUTPUT_REG(1'b0)
    ) u_ram (
        .WCLK(i_clk),.WCLKE(1'b1),.WE({2{w_we}}),.WADDREN(1'b1),
        .WDATA(w_ram_in[bank*20 +: 20]),.WADDR({1'b0,r_wcol}),
        .RCLK(i_clk),.RE(w_we),.RST(1'b0),.RADDREN(1'b1),
        .RADDR({1'b0,r_wcol}),.RDATA(w_ram_out[bank*20 +: 20])
    );
end endgenerate
// The legacy debayer emits one startup RGB row before its opposite Bayer
// row exists. Keep all frame/line pulses, but form output row 0 from the
// following, correctly reconstructed RGB row instead of the startup row.
reg first_output_row,first_output_d;
always @(posedge i_clk) begin
    if(!i_rst_n || vs_rise) begin first_output_row<=1;first_output_d<=0;end
    else begin
        first_output_d<=first_output_row;
        if(w_we && r_emit && r_wcol==215) first_output_row<=0;
    end
end
reg r_vvalid;
reg [95:0] r_bottom;
reg [7:0] r_fy_d;
always @(posedge i_clk) begin
    if(!i_rst_n) begin r_vvalid<=0; r_bottom<=0; r_fy_d<=0; end
    else begin r_vvalid<=w_we & r_emit; r_bottom<=w_wdata; r_fy_d<=r_fy; end
end
wire [95:0] v_top=first_output_d ? r_bottom : w_top;
wire [95:0] v_q;
wire [3:0] v_qv;
generate for(lane=0;lane<4;lane=lane+1) begin:g_vertical
    lerp_dsp24 u_v (
        .i_clk(i_clk),.i_rst_n(i_rst_n),.i_ce(r_vvalid),
        .i_u(v_top[lane*24 +: 24]),.i_v(r_bottom[lane*24 +: 24]),
        .i_w(r_fy_d),.o_qv(v_qv[lane]),.o_q(v_q[lane*24 +: 24])
    );
end endgenerate
always @(posedge i_clk) begin
    if(!i_rst_n) begin o_de<=0; o_data<=0; o_vs<=0; end
    else begin
        if(vs_rise) o_vs<=1;
        else if(vs_fall) o_vs<=0;
        o_de<=v_qv[0];
        if(v_qv[0]) o_data<=v_q;
    end
end
assign o_href=o_de;
endmodule
