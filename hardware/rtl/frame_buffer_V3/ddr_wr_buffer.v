
module ddr_wr_buffer#(
    parameter AXI_DATA_WIDTH = 512, //!AXI接口位宽
    parameter AXI_ADDR_WIDTH = 33,  //!AXI地址位宽
    parameter WR_FIFO_DEPTH	= 1024, //!Write fifo depth   
    parameter AXI_STRB_WIDTH = AXI_DATA_WIDTH/8,//!总共的字节数量，= AXI_DATA_WIDTH/8
    parameter BURST_LEN       = 8'd15
    
    
    )(
        
input 								        axi_clk,
input 								        rst_n,
input								        wr_start, // pulse signal 

input		[AXI_ADDR_WIDTH-1:0]	        start_addr,
input		[24:0]							total_burst_len,
input wire                                  bank_sw_ack	,
output   wire                                 bank_sw 		  ,
output		[7:0] test_cnt ,
input                                       wr_fifo_rst_p,
input										wr_fifo_wrclk,
input										wr_fifo_wren,
output										wr_fifo_wrfull,
input	 [AXI_DATA_WIDTH-1:0]		        wr_fifo_wrdata, 

output 	[5:0] 								awid,
output  [AXI_ADDR_WIDTH-1:0] 	            awaddr,
output  [8-1:0] 				awlen,
output  [2:0] 					            awsize,
output  [1:0] 								awburst,

output  									awlock,
output  reg 								awvalid = 'd0,
output  									awcobuf,
output  									awapcmd,
output  									awallstrb,
output  									awqos,
output  [3:0] 								awcache,
output [2:0]                                awprot,
input 										awready,


output  [AXI_DATA_WIDTH-1:0] 	            wdata,  
output  [AXI_STRB_WIDTH-1:0] 	            wstrb,
output  wire                                wlast,
output  reg									wvalid,
input 										wready,
input [5:0] 								bid,
input 										bvalid,
output  									bready,

output [33:0] addr_width_test,

output [7:0] test_BURST_LEN
);
assign test_BURST_LEN = BURST_LEN;
//=================================================================================

assign addr_width_test = AXI_ADDR_WIDTH;
    localparam WR_ADDR_SHIFT_BITS = $clog2(AXI_STRB_WIDTH);
    localparam MAX_BURST_LEN = 4096/(AXI_DATA_WIDTH/8);
    localparam WR_USEDW_WITH = $clog2(WR_FIFO_DEPTH); //!内部数据
    localparam AXSIZE_WTH = $clog2(AXI_DATA_WIDTH/8);//,//!内部数据

    //=============================================================
    //reg define 
    //=============================================================   
    
    
    reg	[AXI_ADDR_WIDTH-1:0] 			                    ddr_wr_addr 	= 'd0;
    
    wire										 			burst_add_en ;
    reg	[8-1:0]							    ddr_awlen = 0;
    reg	    	[1:0]							                start_sync = 'd0;
    reg [24:0]	burst_len_r   = 'd0;
   
    reg														burst_last = 'd0;      
    reg	[8-1:0] 						                    last_burst_cnt = 'd0;
    reg [8-1:0]                                             first_burst_cnt = 'd0;
    reg                                                     sync_r1 = 1'b0;
    reg                                                     sync_r0 = 1'b0;
    reg                                                     sync_r2 = 1'b0;
    reg                                                     sync_r3 = 1'b0;
    reg [24:0]                                              burst_num = 'd0;
    reg [24:0]                                              total_burst_num = 'd0;
    reg [AXI_ADDR_WIDTH-1:0]                                start_addr_r = 'd0;
    //=============================================================
    //wire define 
    //============================================================= 
    wire   [ WR_USEDW_WITH:0] 		wr_fifo_rdusedw;
wire [AXI_DATA_WIDTH-1:0]		wr_fifo_rddata;
wire							wr_fifo_rdempty;  
wire							wr_fifo_rden;
wire 							pos_sync;
wire [AXI_ADDR_WIDTH-1:0]  		nx_ddr_wr_addr;
wire axi_wr_clk = axi_clk;
// 地址尚未发出时允许装载新帧，已发出的AW/W/B事务必须完整收尾。
wire start_accept = pos_sync && total_burst_len!=0 && !frame_complete &&
                    (state==3'd0 || state==3'd1);
reg frame_complete=0,frame_aborted=0,response_wait=0;
(* async_reg="true" *) reg flush_meta=0,flush_sync=0;
reg flush_d=0;
always @(posedge axi_clk or negedge rst_n)
    if(!rst_n) begin flush_meta<=0;flush_sync<=0;flush_d<=0;end
    else begin flush_meta<=wr_fifo_rst_p;flush_sync<=flush_meta;flush_d<=flush_sync;end
// 本帧启动时的FIFO清理在配置流水期间发生；后续清理表示源帧已被替换。
wire frame_replaced = (pos_sync && !start_accept) ||
                      (flush_sync && !flush_d && !sync_r0 && !sync_r1 && !sync_r2 && !start_accept);

//=============================================================  
//RTL                                                     
//=============================================================  

DC_FIFO
# (
  	.FIFO_MODE  ( "Normal"    ), //"Normal"; //"ShowAhead"
    .DATA_WIDTH ( AXI_DATA_WIDTH ),
    .FIFO_DEPTH ( WR_FIFO_DEPTH   )
  ) u_wr_fifo(   
  //System Signal
  /*i*/.Reset   (!rst_n || wr_fifo_rst_p), 
  /*i*/.WrClk   (wr_fifo_wrclk		), 
  /*i*/.WrEn    (wr_fifo_wren		), 
  /*o*/.WrDNum  (	), 
  /*o*/.WrFull  (wr_fifo_wrfull 	), 
  /*i*/.WrData  (wr_fifo_wrdata 	), 
  /*i*/.RdClk   (axi_clk			), 
  /*i*/.RdEn    (wr_fifo_rden		), 
  /*o*/.RdDNum  (wr_fifo_rdusedw	), 
  /*o*/.RdEmpty (wr_fifo_rdempty	), 
  /*o*/.RdData  (wr_fifo_rddata		)  
);


always @( posedge axi_clk or negedge rst_n )
begin
    if( !rst_n )		start_sync <= 'd0;
    else 			start_sync <= {start_sync[0],wr_start};
end

assign pos_sync = start_sync[1:0] == 2'b01;
//each frame before have enogh time
always @( posedge axi_clk or negedge rst_n )
begin
	if( !rst_n ) begin
		sync_r0 <= 1'b0;
		sync_r1 <= 1'b0;
		sync_r2 <= 1'b0;
        sync_r3 <= 1'b0;
	end else begin 
		sync_r0 <= start_accept;
		sync_r1 <= sync_r0;
		sync_r2 <= sync_r1;
        sync_r3 <= sync_r2;
	end 
end

always @( posedge axi_clk or negedge rst_n )
begin
	if( !rst_n ) begin
		burst_len_r   <= 'd0;
        start_addr_r <= 'd0;
	end else begin
		burst_len_r   <= start_accept ? total_burst_len : burst_len_r ;
        start_addr_r <= start_accept ? start_addr:start_addr_r;
	end
end


  
// 突发长度为2的幂：按地址边界拆首段，再计算尾段和总段数。
// 先做大小判断再减法，0长度/不足一个突发的帧不再发生无符号下溢。
localparam integer BURST_SHIFT = $clog2(BURST_LEN+1);
wire [12-WR_ADDR_SHIFT_BITS:0] first_4k_burst_len = {1'b0,~start_addr_r[11:WR_ADDR_SHIFT_BITS]} + 1'b1;
wire [8:0] boundary_tail = first_4k_burst_len & BURST_LEN;
wire [8:0] first_words = (boundary_tail != 0) ? boundary_tail : (BURST_LEN+1);
wire [24:0] remaining_words = (burst_len_r > first_words) ? burst_len_r-first_words : 25'd0;
wire [24:0] remaining_last = (remaining_words != 0) ? remaining_words-1'b1 : 25'd0;
`ifndef SYNTHESIS
initial if(BURST_LEN<0 || BURST_LEN>255 || ((BURST_LEN+1)&BURST_LEN)!=0 ||
           (BURST_LEN+1)*(AXI_DATA_WIDTH/8)>4096)
    $fatal(1,"framebuffer: burst must be a power of two, <=256 beats and <=4 KiB");
`endif
always @(posedge axi_clk) begin
    if(burst_len_r == 0) begin
        first_burst_cnt <= 0; last_burst_cnt <= 0; burst_num <= 0;
    end else if(burst_len_r <= first_words) begin
        first_burst_cnt <= burst_len_r-1'b1;
        last_burst_cnt <= burst_len_r-1'b1;
        burst_num <= 1;
    end else begin
        first_burst_cnt <= first_words-1'b1;
        last_burst_cnt <= remaining_last & BURST_LEN;
        burst_num <= 2 + (remaining_last >> BURST_SHIFT);
    end
end

//=======================================================================================
//address process
reg addr_add_en = 'd0;
reg addr_add_last = 'd0;
reg [31:0] addr_cnt_num = 'd0;
always @(posedge axi_clk or negedge rst_n) 
begin
	if (!rst_n) 						                        ddr_wr_addr <= start_addr_r;//start_addr;
	else if(sync_r2)				                            ddr_wr_addr <= start_addr_r;//start_addr;//( pos_sync )
	else if( addr_add_en ) 				                        ddr_wr_addr <= nx_ddr_wr_addr;
end      
assign nx_ddr_wr_addr =  ddr_wr_addr + {(ddr_awlen+9'd1),{WR_ADDR_SHIFT_BITS{1'b0}}};
always @( posedge axi_clk or negedge rst_n )
begin
 	if( !rst_n )  							                    addr_cnt_num <= 'd0;
 	else if(sync_r2)					                        addr_cnt_num <= 'd0;//( pos_sync )
    // else if( addr_add_en & addr_add_last)                       addr_cnt_num <= 'd0;
 	else if( addr_add_en )					                    addr_cnt_num <= addr_cnt_num + 1'b1;
end 
always @( posedge axi_clk or negedge rst_n )
begin
	if( !rst_n )										        addr_add_last <= 1'b0;
	else if(sync_r2)						                    addr_add_last <= 1'b0;	//( pos_sync )	
	else if(addr_add_en && burst_num == addr_cnt_num+'d2  ) 	addr_add_last <= 1'b1;
    else if(addr_add_en && burst_num == addr_cnt_num+'d1  )     addr_add_last <= 1'b0;
end 

always @( posedge axi_clk or negedge rst_n )
begin
    if( !rst_n )                                                addr_add_en <= 1'b0;
    else if( awvalid & awready )                                addr_add_en <= 1'b1;
    else                                                        addr_add_en <= 1'b0;
end     


//=============================================================================================

//burst process
always @( posedge axi_clk or negedge rst_n )
begin
 	if( !rst_n )  							total_burst_num <= 'd0;
 	else if(sync_r2)					    total_burst_num <= 'd0;//( pos_sync )
    // else if( burst_add_en & burst_last)     total_burst_num <= 'd0;
 	else if( burst_add_en )					total_burst_num <= total_burst_num + 1'b1;
end 
always @( posedge axi_clk or negedge rst_n  )
begin
    if( !rst_n ) 								                ddr_awlen 	<= first_burst_cnt;//cfg_alen;
    else if( sync_r2 )						                    ddr_awlen 	<= first_burst_cnt;	 
    else if(burst_add_en && burst_num == total_burst_num+2)		ddr_awlen	<= last_burst_cnt;
    else if( burst_add_en )						                ddr_awlen 	<= BURST_LEN;//cfg_alen_r;	
end


always @( posedge axi_clk or negedge rst_n )
begin
	if( !rst_n )										            burst_last <= 1'b0;
	else if(sync_r2)						                    burst_last <= 1'b0;	//( pos_sync )	
	else if(burst_add_en && burst_num == total_burst_num+'d2  ) burst_last <= 1'b1;
    else if(burst_add_en && burst_num == total_burst_num+'d1 )  burst_last <= 1'b0;
end 
// 最后一笔W数据及对应B响应全部完成后，才把此bank发布给读侧。
assign bank_sw = frame_complete;
always @(posedge axi_clk or negedge rst_n) begin
    if(!rst_n) begin frame_complete<=0;frame_aborted<=0;response_wait<=0;end
    else begin
        response_wait <= (state==3'd4);
        if(bank_sw_ack) frame_complete<=0;
        if(start_accept) frame_aborted<=0;
        else if(frame_replaced && state!=3'd0) frame_aborted<=1;
        if(state==3'd4 && bvalid && bready && total_burst_num==burst_num &&
           !frame_aborted && !frame_replaced && !flush_sync)
            frame_complete<=1;
    end
end


//======================================================================================================
reg [2:0] state = 3'd0;
reg wr_req = 0;
always @(posedge axi_clk or negedge rst_n)
    if(!rst_n) wr_req<=0;
    else wr_req<=(wr_fifo_rdusedw > ddr_awlen);

always @(posedge axi_clk or negedge rst_n) begin
    if(!rst_n) begin state<=0;awvalid<=0;wvalid<=0;end
    else if(start_accept || sync_r0) begin state<=0;awvalid<=0;wvalid<=0;end
    else case(state)
        3'd0: begin
            awvalid<=0;wvalid<=0;
            if(sync_r2 && burst_len_r!=0) state<=3'd1;
        end
        3'd1: begin
            wvalid<=0;
            if(frame_replaced || frame_aborted) begin state<=0;awvalid<=0;end
            else if(wr_req && !flush_sync) begin state<=3'd2;awvalid<=1;end
        end
        3'd2: begin
            // 新帧到来不能撤销已经发出的AWVALID或改变其地址。
            if(awready) begin state<=3'd3;awvalid<=0;wvalid<=1;end
        end
        3'd3: begin
            awvalid<=0;
            if(burst_add_en) begin state<=3'd4;wvalid<=0;end
        end
        3'd4: begin
            // 逐突发等待B，沿用顶层单在途仲裁，无需新增响应计数RAM/FIFO。
            awvalid<=0;wvalid<=0;
            if(bvalid && bready)
                state <= (frame_aborted || frame_replaced || total_burst_num==burst_num) ? 3'd0:3'd1;
        end
        default: begin state<=0;awvalid<=0;wvalid<=0;end
    endcase
end
//======================================================================================================

reg [8:0] write_cnt = 0;
// 计数只在W握手时前进，背压期间WLAST保持；同时覆盖单拍突发。
assign wlast = (write_cnt == {1'b0,ddr_awlen});
always @(posedge axi_clk or negedge rst_n) begin
    if(!rst_n) write_cnt<=0;
    else if(sync_r3 || burst_add_en) write_cnt<=0;
    else if(wready && wvalid) write_cnt<=write_cnt+1'b1;
end

//============================================================================================================

assign burst_add_en = wlast & wvalid & wready;       
assign wr_fifo_rden = (awvalid & awready )||(wready && wvalid && !wlast );//write_cnt != 0);//(start_sync == 2'b01 
assign awaddr			= ddr_wr_addr;
assign awlen			= ddr_awlen;

assign wdata			= wr_fifo_rddata;
assign awlock 		= 2'b00;  
assign awapcmd 		= 1'b0;  
assign awcobuf 		= 1'b0;  
 
assign awallstrb 	= 1'b0;
assign awburst 		= 2'b01;
assign awsize  		= AXSIZE_WTH;
assign awid 		= 8'd0;
assign wstrb 		= {AXI_STRB_WIDTH{1'b1}};  
assign awqos        = 1'b0;
// 延后一拍接收B，使源FIFO复位的同步状态到达后再决定是否发布整帧。
assign bready       = (state==3'd4) && response_wait;
assign awprot       = 3'd2;
assign awcache 		= 4'd3; 
endmodule 
