// AXI字转视频像素：仅缓存一个AXI字及不足一个像素的余数。
// 高位先出，保持原DDR打包顺序；按实际DataVal接收，允许FIFO返回存在延迟。
module vid_par2ser #(
    parameter I_VID_WIDTH=128, O_VID_WIDTH=48
)(
    input clk,rst_n,frame_period,rd_fifo_rdvalid,
    input [I_VID_WIDTH-1:0] rd_fifo_rddata,
    input rd_fifo_rdempty,
    output rd_fifo_rden,
    output tx_fifo_valid,
    input wr_fifo_full,
    output [O_VID_WIDTH-1:0] tx_fifo_wrdata
);
localparam CAP=I_VID_WIDTH+O_VID_WIDTH;
localparam CW=$clog2(CAP+1);
reg [CAP-1:0] bits_buffer;
reg [CW-1:0] bit_count=0;
reg pending=0,frame_d=0;
wire frame_start=frame_period && !frame_d;
wire emit=rst_n && bit_count>=O_VID_WIDTH && !wr_fifo_full && !frame_start;
// 在完整像素耗尽前不请求下一字，保证返回时余数小于一个像素。
assign rd_fifo_rden=rst_n && !frame_start && !pending && !rd_fifo_rdempty && bit_count<O_VID_WIDTH;
assign tx_fifo_valid=emit;
assign tx_fifo_wrdata=bits_buffer[CAP-1-:O_VID_WIDTH];
wire [CW-1:0] kept=emit?bit_count-O_VID_WIDTH:bit_count;
wire [CAP-1:0] shifted=emit?(bits_buffer<<O_VID_WIDTH):bits_buffer;
wire receive=rd_fifo_rdvalid && pending;
always @(posedge clk) begin
    // 数据不复位：空缓存时覆盖；有效bit计数决定哪些位可被消费。
    if(receive) bits_buffer<=(kept==0?{CAP{1'b0}}:shifted) | ({{O_VID_WIDTH{1'b0}},rd_fifo_rddata} << (CAP-I_VID_WIDTH-kept));
    else if(emit) bits_buffer<=shifted;
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin bit_count<=0;pending<=0;frame_d<=0;end
    else begin
        frame_d<=frame_period;
        if(frame_start) begin bit_count<=0;pending<=0;end
        else begin
            bit_count<=kept+(receive?I_VID_WIDTH:0);
            if(rd_fifo_rden) pending<=1;
            if(receive) pending<=0;
        end
    end
end
endmodule
