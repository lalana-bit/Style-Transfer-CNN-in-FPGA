// Static gamma lookup: two ROM copies supply three parallel RGB reads.
// No startup sweep, run-time table writes or extra arithmetic units.
module gamma_correction #(
    parameter DATA_WIDTH=10,
    parameter GAMMA_CURVE="2P2.mem"
)(
    input i_pclk,i_rstn,i_valid,i_hs,i_vs,
    input [DATA_WIDTH-1:0] i_red,i_green,i_blue,
    output [DATA_WIDTH-1:0] o_red,o_green,o_blue,
    output reg o_valid,o_hs,o_vs
);
    wire [9:0] addr_r,addr_g,addr_b;
    generate if(DATA_WIDTH==10) begin:g_10
        assign addr_r=i_red;assign addr_g=i_green;assign addr_b=i_blue;
    end else begin:g_8
        // Preserve the original module's 8-bit expansion/10-bit LUT mapping.
        assign addr_r={i_red,i_red[7:6]};
        assign addr_g={i_green,i_green[7:6]};
        assign addr_b={i_blue,i_blue[7:6]};
    end endgenerate
    wire [9:0] mapped_r,mapped_g,mapped_b;
    true_dual_port_ram #(
        .DATA_WIDTH(10),.ADDR_WIDTH(10),
        .WRITE_MODE_1("READ_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("TRUE"),.OUTPUT_REG_2("TRUE"),
        .RAM_INIT_FILE(GAMMA_CURVE)
    ) u_rg_rom (
        .clka(i_pclk),.clkb(i_pclk),.we1(1'b0),.we2(1'b0),
        .din1(10'b0),.din2(10'b0),.addr1(addr_r),.addr2(addr_g),
        .dout1(mapped_r),.dout2(mapped_g)
    );
    true_dual_port_ram #(
        .DATA_WIDTH(10),.ADDR_WIDTH(10),
        .WRITE_MODE_1("READ_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("TRUE"),.OUTPUT_REG_2("TRUE"),
        .RAM_INIT_FILE(GAMMA_CURVE)
    ) u_b_rom (
        .clka(i_pclk),.clkb(i_pclk),.we1(1'b0),.we2(1'b0),
        .din1(10'b0),.din2(10'b0),.addr1(addr_b),.addr2(10'b0),
        .dout1(mapped_b),.dout2()
    );
    reg valid_1p,hs_1p,vs_1p;
    always @(posedge i_pclk) begin
        if(!i_rstn) begin
            valid_1p<=0;hs_1p<=0;vs_1p<=0;
            o_valid<=0;o_hs<=0;o_vs<=0;
        end else begin
            valid_1p<=i_valid;hs_1p<=i_hs;vs_1p<=i_vs;
            o_valid<=valid_1p;o_hs<=hs_1p;o_vs<=vs_1p;
        end
    end
    generate if(DATA_WIDTH==10) begin:g_out10
        assign o_red=o_valid?mapped_r:10'b0;
        assign o_green=o_valid?mapped_g:10'b0;
        assign o_blue=o_valid?mapped_b:10'b0;
    end else begin:g_out8
        assign o_red=o_valid?mapped_r[9:2]:8'b0;
        assign o_green=o_valid?mapped_g[9:2]:8'b0;
        assign o_blue=o_valid?mapped_b[9:2]:8'b0;
    end endgenerate
`ifndef SYNTHESIS
    initial if(DATA_WIDTH!=8 && DATA_WIDTH!=10)
        $fatal(1,"gamma_correction supports DATA_WIDTH 8 or 10");
`endif
endmodule
