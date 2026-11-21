// 参数分发器：拆分 32 位参数字，输出带段号的扫描总线。
`timescale 1ns/1ps

// 用途：将连续参数字转换为各卷积、量化及查找表模块需要的分段扫描数据。
// 原理：按 SEG_UNITS 和 SEG_TW 把 32 位字拆为 8/16/32 位单元，丢弃段尾填充，并同步广播段号和写使能。
module cnn_dispatch #(
    parameter integer SEG_NUM = 4,
    parameter [SEG_NUM * 16 - 1:0] SEG_UNITS = { 16'd8, 16'd4, 16'd6, 16'd10 },
    parameter [SEG_NUM * 2 - 1:0] SEG_TW = { 2'b00, 2'b10, 2'b01, 2'b00 },
    parameter integer RST_CYCLES = 4,
    //rd_rst脉冲宽度(clk数)
    //rd_rst后等FIFO复位退出的等待拍数
    parameter integer WAIT_CYCLES = 16
) (
    input wire clk,
    input wire rst_n,
    //加载控制
    input wire start,
    //高电平触发一次全序列分发(仅S_IDLE响应)
    output wire busy,
    output reg done,
    //全部段完成, 1拍脉冲
    output reg done_all,
    //完成粘滞标志(下次start清零, 供轮询)
    //DDR读通道(接 ddr_interface_efx 用户侧读口, rd_clk = clk)
    output wire rd_rst,
    //加载前脉冲: 清读FIFO + 读地址回卷到rd_beg_addr
    output reg rd_mem_enable,
    output wire rd_en,
    input wire [31:0] rd_data,
    input wire rd_valid,
    //权重广播总线(风格一: 单32bit总线, 低位对齐)
    output reg [31:0] wt_bus,
    //当前单元数值(高位按段类型补0)
    output reg wt_shift,
    //1=本拍wt_bus有效(顶层据此门控目标模块的shift)
    output reg [7:0] wt_seg,
    //当前段号(顶层shift解码的依据), 空闲=8'hFF
    //当前段单元位宽码(状态/校验用: 00/01/10)
    output reg [1:0] wt_typ
);

    //==================== 状态机 ====================
    localparam [2:0] S_IDLE = 3'd0;
    //等待start
    localparam [2:0] S_RST = 3'd1;
    //rd_rst脉冲(清读FIFO残留)
    localparam [2:0] S_WAIT = 3'd2;
    //等FIFO复位退出
    localparam [2:0] S_ADV = 3'd3;
    //载入/推进段参数(自动跳过空段)
    localparam [2:0] S_FETCH = 3'd4;
    //从FIFO取一个32bit词
    localparam [2:0] S_SPLIT = 3'd5;
    //拆拍发送(词内1单元/拍)
    localparam [2:0] S_DONE = 3'd6;
    //收尾: 停DDR读, 出done
    reg [2:0] state;
    reg [7:0] seg;
    //当前段号
    reg [15:0] rem;
    //本段剩余单元数(按单元计, 不按词计!)
    reg [1:0] typ;
    //本段单元位宽码
    reg [1:0] beat;
    //当前词内单元序号(0..3)
    reg [31:0] hold;
    //拆拍保持寄存器(当前正在拆的词)
    reg [15:0] word_units;
    //本词要发的单元数 = min(rem, 每词单元数)
    reg [7:0] rst_cnt;
    reg [7:0] wait_cnt;
    //调试计数器(TB/波形可见): 累计值, 跨加载轮次累加
    //每词单元数: 8bit段=4, 16bit段=2, 32bit段=1
    wire [2:0] upw = (typ == 2'b00) ? 3'd4:(typ == 2'b01) ? 3'd2:3'd1;
    //拆拍字段选择(小端): 第beat个单元位于hold的低位侧
    //  8bit段:  beat0=hold[7:0]   1=[15:8]  2=[23:16] 3=[31:24]
    // 16bit段:  beat0=hold[15:0]  1=[31:16]
    // 32bit段:  hold整体
    //注: 段尾词的高位PAD字节永远不会被beat选中 → 不上总线
    reg [31:0] field;

    always @ * begin
        case (typ)
            2'b00:field = { 24'd0, hold [8 * beat+:8] };
            2'b01:field = { 16'd0, hold [16 * beat+:16] };
            default:field = hold;
            //32 位字段
        endcase
    end
    //组合输出: rd_rst/rd_en 与状态严格同步(零延迟, 波形上与state完全重合)
    assign rd_rst = (state == S_RST);
    assign rd_en = (state == S_FETCH);
    assign busy = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (~ rst_n) begin
            state <= S_IDLE;
            done <= 1'b0;
            done_all <= 1'b0;
            rd_mem_enable <= 1'b0;
            wt_bus <= 32'd0;
            wt_shift <= 1'b0;
            wt_seg <= 8'hFF;
            wt_typ <= 2'b00;
            seg <= 8'd0;
            rem <= 16'd0;
            typ <= 2'b00;
            beat <= 2'd0;
            hold <= 32'd0;
            word_units <= 16'd0;
            rst_cnt <= 8'd0;
            wait_cnt <= 8'd0;
        end else begin
            //单拍信号每周期默认回零(只在有效状态/分支里抬高)
            done <= 1'b0;
            wt_shift <= 1'b0;
            case (state)
                //---------- 等待启动 ----------
                S_IDLE:begin
                    rd_mem_enable <= 1'b0;
                    wt_seg <= 8'hFF;
                    //空闲段号标记(波形上一眼可辨)
                    if (start) begin
                        seg <= 8'd0;
                        done_all <= 1'b0;
                        //清上一轮的完成标志
                        rst_cnt <= 8'd0;
                        state <= S_RST;
                    end
                end
                //---------- 清读FIFO(上次预取残留) ----------
                S_RST:begin
                    if (rst_cnt == RST_CYCLES - 1) begin
                        wait_cnt <= 8'd0;
                        state <= S_WAIT;
                    end else rst_cnt <= rst_cnt + 8'd1;
                end
                //---------- 等FIFO复位退出 ----------
                S_WAIT:begin
                    if (wait_cnt == WAIT_CYCLES - 1) begin
                        rd_mem_enable <= 1'b1;
                        //此后DDR侧开始按水位预取
                        state <= S_ADV;
                    end else wait_cnt <= wait_cnt + 8'd1;
                end
                //---------- 段推进: 载入参数, 跳过空段 ----------
                S_ADV:begin
                    rem <= SEG_UNITS [16 * seg+:16];
                    typ <= SEG_TW [2 * seg+:2];
                    wt_seg <= seg;
                    //段号与数据同源寄存 → 首拍前已稳定
                    wt_typ <= SEG_TW [2 * seg+:2];
                    if (SEG_UNITS [16 * seg+:16] == 16'd0) begin
                        if (seg == SEG_NUM - 1) state <= S_DONE;
                        //后面没有非空段了
                        else seg <= seg + 8'd1;
                        //空段: 直接看下一段
                    end else begin
                        beat <= 2'd0;
                        state <= S_FETCH;
                    end
                end
                //---------- 取词(rd_en已由组合逻辑拉高, 等FIFO给数) ----------
                S_FETCH:begin
                    if (rd_valid) begin
                        hold <= rd_data;
                        word_units <= (rem < upw) ? rem:{ 13'd0, upw };
                        //尾词=min(rem,每词单元数)
                        beat <= 2'd0;
                        state <= S_SPLIT;
                    end
                    //rd_valid=0则原地等待(FIFO断流/DDR延迟都会走到这里)
                end
                //---------- 拆拍发送(词内1单元/拍) ----------
                S_SPLIT:begin
                    wt_shift <= 1'b1;
                    wt_bus <= field;
                    //field由(beat,hold,typ)组合选择后寄存输出
                    rem <= rem - 16'd1;
                    if (beat == word_units - 16'd1) begin
                        //本词的单元发完
                        if (rem == 16'd1) begin
                            //这也是本段最后一个单元(rem减1后为0)
                            if (seg == SEG_NUM - 1) state <= S_DONE;
                            //全序列完成
                            else begin
                                seg <= seg + 8'd1;
                                //下一段
                                state <= S_ADV;
                            end
                        end else state <= S_FETCH;
                        //本段未完, 取下一词
                    end else beat <= beat + 2'd1;
                    //继续发本词下一单元
                end
                //---------- 收尾 ----------
                S_DONE:begin
                    rd_mem_enable <= 1'b0;
                    //停DDR读(自停: 计数驱动, 不依赖loaded)
                    done <= 1'b1;
                    done_all <= 1'b1;
                    state <= S_IDLE;
                end
                default:state <= S_IDLE;
            endcase
        end
    end
endmodule
