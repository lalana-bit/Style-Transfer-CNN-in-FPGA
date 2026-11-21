`timescale 1ns/1ps
// 用途：统一存储中间十个量化客户端的活动/备用 IN 系数。
// 原理：三个20位平面同拍读出一通道系数，按再量化前三拍的固定时隙预取；层内帧边界换区不变。
module cnn_param_store #(
    parameter integer CLIENTS=10,
    parameter integer STANDARD_FIRST=1
)(
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire [9:0] arithmetic_slot,
    input wire [CLIENTS-1:0] write_valid,
    input wire [CLIENTS*7-1:0] write_address,
    input wire [CLIENTS*2-1:0] write_field,
    input wire [CLIENTS*20-1:0] write_data,
    input wire [CLIENTS-1:0] read_valid,
    input wire [CLIENTS*7-1:0] read_address,
    output wire [CLIENTS-1:0] read_ready,
    output reg [CLIENTS-1:0] response_valid,
    output wire [59:0] response_data
);
    function integer span(input integer client);
        case(client)
            0:span=32;
            1:span=64;
            2:span=STANDARD_FIRST?64:128;
            3,4,5,6:span=128;
            7:span=32;
            8:span=16;
            9:span=64;
            default:span=0;
        endcase
    endfunction
    function integer base(input integer client);
        integer i;
        begin base=0;for(i=0;i<client;i=i+1)base=base+span(i);end
    endfunction
    localparam integer DEPTH=784;
    wire [CLIENTS-1:0] read_grant;
    reg [9:0] selected_ra;
    reg [9:0] selected_wa;
    reg [1:0] selected_field;
    reg [19:0] selected_data;
    wire write_enable=|write_valid;
    genvar g;
    generate for(g=0;g<CLIENTS;g=g+1)begin : g_slot
        assign read_ready[g]=!clear && arithmetic_slot[(g+7)%10];
        assign read_grant[g]=read_ready[g] && read_valid[g];
    end endgenerate
    integer client;
    always @* begin
        selected_ra=0;
        selected_wa=0;
        selected_field=0;
        selected_data=0;
        for(client=0;client<CLIENTS;client=client+1)begin
            selected_ra=selected_ra | ((base(client)+read_address[client*7+:7]) & {10{read_grant[client]}});
            selected_wa=selected_wa | ((base(client)+write_address[client*7+:7]) & {10{write_valid[client]}});
            selected_field=selected_field | (write_field[client*2+:2] & {2{write_valid[client]}});
            selected_data=selected_data | (write_data[client*20+:20] & {20{write_valid[client]}});
        end
    end
    generate for(g=0;g<3;g=g+1)begin : g_field
        cnn_sdp_ram #(
            .W(20),
            .D(DEPTH),
            .AW(10)
        ) memory(
            .clk(clk),
            .we(write_enable && selected_field==g),
            .waddr(selected_wa),
            .wdata(selected_data),
            .re(|read_grant),
            .raddr(selected_ra),
            .rdata(response_data[g*20+:20])
        );
    end endgenerate
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)response_valid<=0;
        else if(clear)response_valid<=0;
        else response_valid<=read_grant;
    end
`ifndef SYNTHESIS
    integer writes;
    always @(posedge clk)if(rst_n)begin
        writes=0;
        for(integer i=0;i<CLIENTS;i=i+1)begin
            if(write_valid[i])begin
                writes=writes+1;
                if(write_address[i*7+:7]>=span(i) || write_field[i*2+:2]>2)$fatal(1,"Parameter write address/field out of range");
            end
            if(read_grant[i] && read_address[i*7+:7]>=span(i))$fatal(1,"Parameter read address out of range");
        end
        if(writes>1)$fatal(1,"Concurrent shared parameter writers");
    end
`endif
endmodule
