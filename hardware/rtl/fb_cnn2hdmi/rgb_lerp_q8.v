`timescale 1ns/1ps
// Portable RGB888 interpolation, independently for each byte/channel:
// q = round((u*(256-w) + v*w)/256), w=0..255.
// Three registered stages, throughput one pixel/clock, one unsigned 8x8
// DSP multiply per channel. Split v-u into an unsigned low byte and its
// negative carry, avoiding magnitude selection and a final add/subtract mux.
module rgb_lerp_q8 (
 input wire clk,rst_n,i_valid,
 input wire [23:0] i_u,i_v,input wire [7:0] i_w,
 output wire o_valid,output wire [23:0] o_q
);
reg [2:0] valid_pipe;
always @(posedge clk or negedge rst_n)
 if(!rst_n) valid_pipe<=0;else valid_pipe<={valid_pipe[1:0],i_valid};
assign o_valid=valid_pipe[2];
genvar c;
generate for(c=0;c<3;c=c+1) begin : channel
 reg [7:0] difference_low,weight,q;
 reg signed [8:0] base0,base1;
 reg [15:0] product;
 wire signed [8:0] difference=$signed({1'b0,i_v[c*8 +:8]})-$signed({1'b0,i_u[c*8 +:8]});
 // v-u = difference_low - 256*difference[8]. Hence the upper correction
 // is u-w for a negative difference, or u otherwise; one 8x8 DSP suffices.
 // The complete weighted sum stays in [128,65408].
 wire signed [17:0] sum=$signed({base1[8],base1,8'h80})+$signed({2'b00,product});
 always @(posedge clk) begin
  if(i_valid) begin
   difference_low<=difference[7:0];
   base0<=difference[8] ? $signed({1'b0,i_u[c*8 +:8]})-$signed({1'b0,i_w}) : $signed({1'b0,i_u[c*8 +:8]});
   weight<=i_w;
  end
  if(valid_pipe[0]) begin product<=difference_low*weight;base1<=base0;end
  if(valid_pipe[1]) q<=sum[15:8];
 end
 assign o_q[c*8 +:8]=q;
end endgenerate
endmodule
