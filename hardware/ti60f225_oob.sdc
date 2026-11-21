# PLL Constraints
#################
# PLL Constraints
#################

create_clock -period 2.500 -name tx_cal_clk_90edge [get_ports {tx_cal_clk_90edge}]
create_clock -period 2.500 -name sdram_clk [get_ports {sdram_clk}]
create_clock -period 2.500 -name rx_cal_clk [get_ports {rx_cal_clk}]
create_clock -period 2.500 -name tx_cal_clk [get_ports {tx_cal_clk}]
create_clock -period 10.000 -name clk_100m [get_ports {clk_100m}]
create_clock -period 13.468 -name vid_clk_dvi2 [get_ports {vid_clk_dvi2}]
# HDMI pixel clock selected by the top-level HDMI_1080P parameter.
create_clock -period 13.468 -name hdmi_tx_slow_clk [get_ports {hdmi_tx_slow_clk}]
create_clock -period 18.519 -name fb [get_ports {fb}]
# HDMI DDR serializer runs at 5x pixel frequency, with 90-degree phase.
create_clock -waveform {0.673 2.020} -period 2.694 -name hdmi_tx_fast_clk [get_ports {hdmi_tx_fast_clk}]
create_clock -period 10.000 -name core_clk [get_ports {core_clk}]
create_clock -waveform {1.000 2.000} -period 2.000 -name i_mipi_txc_sclk [get_ports {i_mipi_txc_sclk}]
create_clock -waveform {0.500 1.500} -period 2.000 -name i_mipi_txd_sclk [get_ports {i_mipi_txd_sclk}]
create_clock -period 8.000 -name i_mipi_tx_pclk [get_ports {i_mipi_tx_pclk}]
create_clock -period 20.000 -name i_mipi_rx_pclk [get_ports {i_mipi_rx_pclk}]
create_clock -period 4.444 -name clk_225M [get_ports {clk_225M}]


create_clock -period 10.000 -name i_cam_ck_CLKOUT [get_ports {i_cam_ck_CLKOUT}]

create_clock -period 100.000 -name jtag_inst1_TCK [get_ports {jtag_inst1_TCK}]
set_clock_groups -asynchronous -group {jtag_inst1_TCK} -group {core_clk}

set_clock_groups -exclusive  -group {i_mipi_rx_pclk} -group {jtag_inst1_TCK}
set_clock_groups -exclusive -group {core_clk} -group {tx_cal_clk} -group {i_mipi_tx_pclk} -group {vid_clk_dvi2} -group {i_mipi_rx_pclk} -group {sdram_clk} -group {rx_cal_clk}
set_clock_groups -exclusive -group {i_mipi_tx_pclk}    -group {i_mipi_rx_pclk}

#set_clock_groups -exclusive -group {i_sysclk} -group {jtag_inst1_TCK}                       2.500           -0.197           (R-R)

#set_clock_groups -exclusive -group {i_sysclk_div_2} -group {jtag_inst1_TCK}

#set_clock_groups -exclusive -group {jtag_inst1_TCK} -group {i_hbramClk_fb i_hbramClk_cal i_hbramClk_cal i_hbramClk90} -group {io_systemClk} -group {i_mipi_rx_pclk} -group {i_mipi_tx_pclk i_mipi_clk i_mipi_txc_sclk i_mipi_txd_sclk}

# GPIO Constraints
####################

# JTAG Constraints
####################
# create_clock -period <USER_PERIOD> -name jtag_inst1_TCK [get_ports {jtag_inst1_TCK}]
set_output_delay -clock jtag_inst1_TCK -max 1.519 [get_ports {jtag_inst1_TDO}]
set_output_delay -clock jtag_inst1_TCK -min 0.495 [get_ports {jtag_inst1_TDO}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.144 [get_ports {jtag_inst1_CAPTURE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.077 [get_ports {jtag_inst1_CAPTURE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.759 [get_ports {jtag_inst1_RESET}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.401 [get_ports {jtag_inst1_RESET}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.234 [get_ports {jtag_inst1_SEL}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.025 [get_ports {jtag_inst1_SEL}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.176 [get_ports {jtag_inst1_UPDATE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.074 [get_ports {jtag_inst1_UPDATE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.197 [get_ports {jtag_inst1_SHIFT}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.055 [get_ports {jtag_inst1_SHIFT}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 1.190 [get_ports {jtag_inst1_DRCK}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.620 [get_ports {jtag_inst1_DRCK}]
# JTAG Constraints (extra... not used by current Efinity debug tools)
# create_clock -period <USER_PERIOD> -name jtag_inst1_DRCK [get_ports {jtag_inst1_DRCK}]
# set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.169 [get_ports {jtag_inst1_RUNTEST}]
# set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.066 [get_ports {jtag_inst1_RUNTEST}]
# Create separate clock groups for JTAG clocks. Remove DRCK clock from the list below if it is not defined.
# set_clock_groups -asynchronous -group {jtag_inst1_TCK jtag_inst1_DRCK}
# JTAG Constraints (extra... not used by current Efinity debug tools)
# Create separate clock groups for JTAG clocks. Remove DRCK clock from the list below if it is not defined.


# HSIO GPIO Constraints
#########################
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~95}] -max 0.302 [get_ports {ddr_addr[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~95}] -min -0.140 [get_ports {ddr_addr[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~36}] -max 0.302 [get_ports {ddr_addr[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~36}] -min -0.140 [get_ports {ddr_addr[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~70}] -max 0.302 [get_ports {ddr_addr[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~70}] -min -0.140 [get_ports {ddr_addr[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~50~1}] -max 0.302 [get_ports {ddr_addr[3]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~50~1}] -min -0.140 [get_ports {ddr_addr[3]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~25}] -max 0.302 [get_ports {ddr_addr[4]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~25}] -min -0.140 [get_ports {ddr_addr[4]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~142~1}] -max 0.302 [get_ports {ddr_addr[5]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~142~1}] -min -0.140 [get_ports {ddr_addr[5]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~59}] -max 0.302 [get_ports {ddr_addr[6]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~59}] -min -0.140 [get_ports {ddr_addr[6]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~110}] -max 0.302 [get_ports {ddr_addr[7]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~110}] -min -0.140 [get_ports {ddr_addr[7]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~26}] -max 0.302 [get_ports {ddr_addr[8]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~26}] -min -0.140 [get_ports {ddr_addr[8]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~127}] -max 0.302 [get_ports {ddr_addr[9]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~127}] -min -0.140 [get_ports {ddr_addr[9]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~138}] -max 0.302 [get_ports {ddr_addr[10]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~138}] -min -0.140 [get_ports {ddr_addr[10]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~60}] -max 0.302 [get_ports {ddr_addr[11]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~60}] -min -0.140 [get_ports {ddr_addr[11]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~35}] -max 0.302 [get_ports {ddr_addr[12]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~35}] -min -0.140 [get_ports {ddr_addr[12]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~71}] -max 0.302 [get_ports {ddr_addr[13]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~71}] -min -0.140 [get_ports {ddr_addr[13]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~109}] -max 0.302 [get_ports {ddr_addr[14]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~109}] -min -0.140 [get_ports {ddr_addr[14]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~143~1}] -max 0.302 [get_ports {ddr_addr[15]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~143~1}] -min -0.140 [get_ports {ddr_addr[15]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~74~1}] -max 0.302 [get_ports {ddr_ba[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~74~1}] -min -0.140 [get_ports {ddr_ba[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~132~1}] -max 0.302 [get_ports {ddr_ba[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~132~1}] -min -0.140 [get_ports {ddr_ba[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~126}] -max 0.302 [get_ports {ddr_ba[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~126}] -min -0.140 [get_ports {ddr_ba[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~49}] -max 0.302 [get_ports {ddr_cas_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~49}] -min -0.140 [get_ports {ddr_cas_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~149}] -max 0.302 [get_ports {ddr_ck_lo ddr_ck_hi}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~149}] -min -0.140 [get_ports {ddr_ck_lo ddr_ck_hi}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~123~1}] -max 0.302 [get_ports {ddr_cke[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~123~1}] -min -0.140 [get_ports {ddr_cke[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~95~1}] -max 0.302 [get_ports {ddr_cs_n[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~95~1}] -min -0.140 [get_ports {ddr_cs_n[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~131~1}] -max 0.302 [get_ports {ddr_dm_lo[0] ddr_dm_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~131~1}] -min -0.140 [get_ports {ddr_dm_lo[0] ddr_dm_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~83~1}] -max 0.302 [get_ports {ddr_dm_lo[1] ddr_dm_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~83~1}] -min -0.140 [get_ports {ddr_dm_lo[1] ddr_dm_hi[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~73~1}] -max 0.302 [get_ports {ddr_odt[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~73~1}] -min -0.140 [get_ports {ddr_odt[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~48}] -max 0.302 [get_ports {ddr_ras_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~48}] -min -0.140 [get_ports {ddr_ras_n}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {ddr_reset_n}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {ddr_reset_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~94}] -max 0.302 [get_ports {ddr_we_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~94}] -min -0.140 [get_ports {ddr_we_n}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~148~1}] -max 0.476 [get_ports {ddr_dq_in_lo[0] ddr_dq_in_hi[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~148~1}] -min 0.276 [get_ports {ddr_dq_in_lo[0] ddr_dq_in_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -max 0.302 [get_ports {ddr_dq_out_lo[0] ddr_dq_out_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -min -0.140 [get_ports {ddr_dq_out_lo[0] ddr_dq_out_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -max 0.302 [get_ports {ddr_dq_oe[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -min -0.140 [get_ports {ddr_dq_oe[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~157~1}] -max 0.476 [get_ports {ddr_dq_in_lo[1] ddr_dq_in_hi[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~157~1}] -min 0.276 [get_ports {ddr_dq_in_lo[1] ddr_dq_in_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -max 0.302 [get_ports {ddr_dq_out_lo[1] ddr_dq_out_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -min -0.140 [get_ports {ddr_dq_out_lo[1] ddr_dq_out_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -max 0.302 [get_ports {ddr_dq_oe[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -min -0.140 [get_ports {ddr_dq_oe[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~164~1}] -max 0.476 [get_ports {ddr_dq_in_lo[2] ddr_dq_in_hi[2]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~164~1}] -min 0.276 [get_ports {ddr_dq_in_lo[2] ddr_dq_in_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -max 0.302 [get_ports {ddr_dq_out_lo[2] ddr_dq_out_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -min -0.140 [get_ports {ddr_dq_out_lo[2] ddr_dq_out_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -max 0.302 [get_ports {ddr_dq_oe[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -min -0.140 [get_ports {ddr_dq_oe[2]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~149~1}] -max 0.476 [get_ports {ddr_dq_in_lo[3] ddr_dq_in_hi[3]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~149~1}] -min 0.276 [get_ports {ddr_dq_in_lo[3] ddr_dq_in_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -max 0.302 [get_ports {ddr_dq_out_lo[3] ddr_dq_out_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -min -0.140 [get_ports {ddr_dq_out_lo[3] ddr_dq_out_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -max 0.302 [get_ports {ddr_dq_oe[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -min -0.140 [get_ports {ddr_dq_oe[3]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~189~1}] -max 0.476 [get_ports {ddr_dq_in_lo[4] ddr_dq_in_hi[4]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~189~1}] -min 0.276 [get_ports {ddr_dq_in_lo[4] ddr_dq_in_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -max 0.302 [get_ports {ddr_dq_out_lo[4] ddr_dq_out_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -min -0.140 [get_ports {ddr_dq_out_lo[4] ddr_dq_out_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -max 0.302 [get_ports {ddr_dq_oe[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -min -0.140 [get_ports {ddr_dq_oe[4]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~156~1}] -max 0.476 [get_ports {ddr_dq_in_lo[5] ddr_dq_in_hi[5]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~156~1}] -min 0.276 [get_ports {ddr_dq_in_lo[5] ddr_dq_in_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -max 0.302 [get_ports {ddr_dq_out_lo[5] ddr_dq_out_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -min -0.140 [get_ports {ddr_dq_out_lo[5] ddr_dq_out_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -max 0.302 [get_ports {ddr_dq_oe[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -min -0.140 [get_ports {ddr_dq_oe[5]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~165~1}] -max 0.476 [get_ports {ddr_dq_in_lo[6] ddr_dq_in_hi[6]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~165~1}] -min 0.276 [get_ports {ddr_dq_in_lo[6] ddr_dq_in_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -max 0.302 [get_ports {ddr_dq_out_lo[6] ddr_dq_out_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -min -0.140 [get_ports {ddr_dq_out_lo[6] ddr_dq_out_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -max 0.302 [get_ports {ddr_dq_oe[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -min -0.140 [get_ports {ddr_dq_oe[6]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~188~1}] -max 0.476 [get_ports {ddr_dq_in_lo[7] ddr_dq_in_hi[7]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~188~1}] -min 0.276 [get_ports {ddr_dq_in_lo[7] ddr_dq_in_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -max 0.302 [get_ports {ddr_dq_out_lo[7] ddr_dq_out_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -min -0.140 [get_ports {ddr_dq_out_lo[7] ddr_dq_out_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -max 0.302 [get_ports {ddr_dq_oe[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -min -0.140 [get_ports {ddr_dq_oe[7]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~82~1}] -max 0.476 [get_ports {ddr_dq_in_lo[8] ddr_dq_in_hi[8]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~82~1}] -min 0.276 [get_ports {ddr_dq_in_lo[8] ddr_dq_in_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -max 0.302 [get_ports {ddr_dq_out_lo[8] ddr_dq_out_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -min -0.140 [get_ports {ddr_dq_out_lo[8] ddr_dq_out_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -max 0.302 [get_ports {ddr_dq_oe[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -min -0.140 [get_ports {ddr_dq_oe[8]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~39~1}] -max 0.476 [get_ports {ddr_dq_in_lo[9] ddr_dq_in_hi[9]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~39~1}] -min 0.276 [get_ports {ddr_dq_in_lo[9] ddr_dq_in_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -max 0.302 [get_ports {ddr_dq_out_lo[9] ddr_dq_out_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -min -0.140 [get_ports {ddr_dq_out_lo[9] ddr_dq_out_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -max 0.302 [get_ports {ddr_dq_oe[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -min -0.140 [get_ports {ddr_dq_oe[9]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~22~1}] -max 0.476 [get_ports {ddr_dq_in_lo[10] ddr_dq_in_hi[10]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~22~1}] -min 0.276 [get_ports {ddr_dq_in_lo[10] ddr_dq_in_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -max 0.302 [get_ports {ddr_dq_out_lo[10] ddr_dq_out_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -min -0.140 [get_ports {ddr_dq_out_lo[10] ddr_dq_out_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -max 0.302 [get_ports {ddr_dq_oe[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -min -0.140 [get_ports {ddr_dq_oe[10]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~92~1}] -max 0.476 [get_ports {ddr_dq_in_lo[11] ddr_dq_in_hi[11]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~92~1}] -min 0.276 [get_ports {ddr_dq_in_lo[11] ddr_dq_in_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -max 0.302 [get_ports {ddr_dq_out_lo[11] ddr_dq_out_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -min -0.140 [get_ports {ddr_dq_out_lo[11] ddr_dq_out_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -max 0.302 [get_ports {ddr_dq_oe[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -min -0.140 [get_ports {ddr_dq_oe[11]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~23~1}] -max 0.476 [get_ports {ddr_dq_in_lo[12] ddr_dq_in_hi[12]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~23~1}] -min 0.276 [get_ports {ddr_dq_in_lo[12] ddr_dq_in_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -max 0.302 [get_ports {ddr_dq_out_lo[12] ddr_dq_out_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -min -0.140 [get_ports {ddr_dq_out_lo[12] ddr_dq_out_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -max 0.302 [get_ports {ddr_dq_oe[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -min -0.140 [get_ports {ddr_dq_oe[12]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~38~1}] -max 0.476 [get_ports {ddr_dq_in_lo[13] ddr_dq_in_hi[13]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~38~1}] -min 0.276 [get_ports {ddr_dq_in_lo[13] ddr_dq_in_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -max 0.302 [get_ports {ddr_dq_out_lo[13] ddr_dq_out_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -min -0.140 [get_ports {ddr_dq_out_lo[13] ddr_dq_out_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -max 0.302 [get_ports {ddr_dq_oe[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -min -0.140 [get_ports {ddr_dq_oe[13]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~11~1}] -max 0.476 [get_ports {ddr_dq_in_lo[14] ddr_dq_in_hi[14]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~11~1}] -min 0.276 [get_ports {ddr_dq_in_lo[14] ddr_dq_in_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -max 0.302 [get_ports {ddr_dq_out_lo[14] ddr_dq_out_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -min -0.140 [get_ports {ddr_dq_out_lo[14] ddr_dq_out_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -max 0.302 [get_ports {ddr_dq_oe[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -min -0.140 [get_ports {ddr_dq_oe[14]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~12~1}] -max 0.476 [get_ports {ddr_dq_in_lo[15] ddr_dq_in_hi[15]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~12~1}] -min 0.276 [get_ports {ddr_dq_in_lo[15] ddr_dq_in_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -max 0.302 [get_ports {ddr_dq_out_lo[15] ddr_dq_out_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -min -0.140 [get_ports {ddr_dq_out_lo[15] ddr_dq_out_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -max 0.302 [get_ports {ddr_dq_oe[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -min -0.140 [get_ports {ddr_dq_oe[15]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~172~1}] -max 0.476 [get_ports {ddr_dqs_in_lo[0] ddr_dqs_in_hi[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~172~1}] -min 0.276 [get_ports {ddr_dqs_in_lo[0] ddr_dqs_in_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -max 0.302 [get_ports {ddr_dqs_out_lo[0] ddr_dqs_out_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -min -0.140 [get_ports {ddr_dqs_out_lo[0] ddr_dqs_out_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -max 0.302 [get_ports {ddr_dqs_oe[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -min -0.140 [get_ports {ddr_dqs_oe[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~175~1}] -max 0.302 [get_ports {ddr_dqs_oe_n[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~175~1}] -min -0.140 [get_ports {ddr_dqs_oe_n[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~30~1}] -max 0.476 [get_ports {ddr_dqs_in_lo[1] ddr_dqs_in_hi[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~30~1}] -min 0.276 [get_ports {ddr_dqs_in_lo[1] ddr_dqs_in_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -max 0.302 [get_ports {ddr_dqs_out_lo[1] ddr_dqs_out_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -min -0.140 [get_ports {ddr_dqs_out_lo[1] ddr_dqs_out_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -max 0.302 [get_ports {ddr_dqs_oe[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -min -0.140 [get_ports {ddr_dqs_oe[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~33~1}] -max 0.302 [get_ports {ddr_dqs_oe_n[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~33~1}] -min -0.140 [get_ports {ddr_dqs_oe_n[1]}]

# LVDS Tx Constraints
#######################
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -max 0.435 [get_ports {tmds_tx_clk_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -min -0.140 [get_ports {tmds_tx_clk_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -max 0.435 [get_ports {tmds_tx_clk_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -min -0.140 [get_ports {tmds_tx_clk_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -max 0.483 [get_ports {tmds_tx_clk_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -min -0.175 [get_ports {tmds_tx_clk_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -max 0.435 [get_ports {tmds_tx_data0_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -min -0.140 [get_ports {tmds_tx_data0_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -max 0.435 [get_ports {tmds_tx_data0_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -min -0.140 [get_ports {tmds_tx_data0_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -max 0.483 [get_ports {tmds_tx_data0_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -min -0.175 [get_ports {tmds_tx_data0_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -max 0.435 [get_ports {tmds_tx_data1_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -min -0.140 [get_ports {tmds_tx_data1_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -max 0.435 [get_ports {tmds_tx_data1_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -min -0.140 [get_ports {tmds_tx_data1_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -max 0.483 [get_ports {tmds_tx_data1_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -min -0.175 [get_ports {tmds_tx_data1_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -max 0.435 [get_ports {tmds_tx_data2_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -min -0.140 [get_ports {tmds_tx_data2_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -max 0.435 [get_ports {tmds_tx_data2_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -min -0.140 [get_ports {tmds_tx_data2_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -max 0.483 [get_ports {tmds_tx_data2_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -min -0.175 [get_ports {tmds_tx_data2_TX_RST}]

# MIPI RX Lane Constraints
############################
# 
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.604 [get_ports {cam_d0_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min 0.070 [get_ports {cam_d0_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.362 [get_ports {cam_d0_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min -0.140 [get_ports {cam_d0_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.725 [get_ports {cam_d0_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min 0.420 [get_ports {cam_d0_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.560 [get_ports {cam_d0_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min 0.325 [get_ports {cam_d0_HS_IN[*]}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.604 [get_ports {cam_d1_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min 0.070 [get_ports {cam_d1_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.362 [get_ports {cam_d1_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min -0.140 [get_ports {cam_d1_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.725 [get_ports {cam_d1_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min 0.420 [get_ports {cam_d1_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.560 [get_ports {cam_d1_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min 0.325 [get_ports {cam_d1_HS_IN[*]}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.604 [get_ports {cam_d2_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min 0.070 [get_ports {cam_d2_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.362 [get_ports {cam_d2_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min -0.140 [get_ports {cam_d2_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.725 [get_ports {cam_d2_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min 0.420 [get_ports {cam_d2_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.560 [get_ports {cam_d2_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min 0.325 [get_ports {cam_d2_HS_IN[*]}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.604 [get_ports {cam_d3_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min 0.070 [get_ports {cam_d3_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.362 [get_ports {cam_d3_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min -0.140 [get_ports {cam_d3_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.725 [get_ports {cam_d3_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min 0.420 [get_ports {cam_d3_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.560 [get_ports {cam_d3_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min 0.325 [get_ports {cam_d3_HS_IN[*]}]

# MIPI TX Lane Constraints
############################
set_output_delay -clock i_mipi_txd_sclk -reference_pin [get_ports {i_mipi_txd_sclk~CLKOUT~39~322}] -max 0.435 [get_ports {mipi_dp_clk_HS_OUT[*]}]
set_output_delay -clock i_mipi_txd_sclk -reference_pin [get_ports {i_mipi_txd_sclk~CLKOUT~39~322}] -min -0.140 [get_ports {mipi_dp_clk_HS_OUT[*]}]
set_output_delay -clock i_mipi_txd_sclk -reference_pin [get_ports {i_mipi_txd_sclk~CLKOUT~39~322}] -max 0.362 [get_ports {mipi_dp_clk_RST}]
set_output_delay -clock i_mipi_txd_sclk -reference_pin [get_ports {i_mipi_txd_sclk~CLKOUT~39~322}] -min -0.140 [get_ports {mipi_dp_clk_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~63~322}] -max 0.435 [get_ports {mipi_dp_data0_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~63~322}] -min -0.140 [get_ports {mipi_dp_data0_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~63~322}] -max 0.362 [get_ports {mipi_dp_data0_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~63~322}] -min -0.140 [get_ports {mipi_dp_data0_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~71~322}] -max 0.435 [get_ports {mipi_dp_data1_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~71~322}] -min -0.140 [get_ports {mipi_dp_data1_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~71~322}] -max 0.362 [get_ports {mipi_dp_data1_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~71~322}] -min -0.140 [get_ports {mipi_dp_data1_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~55~322}] -max 0.435 [get_ports {mipi_dp_data2_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~55~322}] -min -0.140 [get_ports {mipi_dp_data2_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~55~322}] -max 0.362 [get_ports {mipi_dp_data2_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~55~322}] -min -0.140 [get_ports {mipi_dp_data2_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~31~322}] -max 0.435 [get_ports {mipi_dp_data3_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~31~322}] -min -0.140 [get_ports {mipi_dp_data3_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~31~322}] -max 0.362 [get_ports {mipi_dp_data3_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~31~322}] -min -0.140 [get_ports {mipi_dp_data3_RST}]


# CNN_TIMING_PATCH_BEGIN
# Parameter CDC shared by trained ROM and legacy scan modes.
# Load after board clock definitions. Only first synchronizer stages are cut.
set_false_path -from [get_clocks core_clk] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/initialized_meta~FF|D}]
set_false_path -from [get_clocks core_clk] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/error_meta~FF|D}]
set_false_path -from [get_clocks core_clk] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/request_meta~FF|D}]
set_false_path -from [get_clocks core_clk] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/verified_meta~FF|D}]
set_false_path -from [get_clocks clk_225M] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/ack_meta~FF|D}]
set_false_path -from [get_clocks clk_225M] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/enable_meta~FF|D}]
set_false_path -from [get_clocks clk_225M] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/params_meta~FF|D}]
# read_hold stays stable until all four words have been consumed and ACK returns.
# CNN samples after the two-stage request synchronizer; bound delay and skew.
set_max_delay -from [get_pins {g_cnn_enabled.u_cnn/u_weights/read_hold[*]~FF|CLK}] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/read_buffer[*]~FF|D}] 8.000
set_false_path -hold -from [get_pins {g_cnn_enabled.u_cnn/u_weights/read_hold[*]~FF|CLK}] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/read_buffer[*]~FF|D}]
set_bus_skew -from [get_pins {g_cnn_enabled.u_cnn/u_weights/read_hold[*]~FF|CLK}] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/read_buffer[*]~FF|D}] 8.000

create_clock -period 40.000 -name CLK_25M [get_ports {CLK_25M}]

set_false_path -from [get_clocks vid_clk_dvi2] -to [get_pins {cnn_reset_pipe[*]~FF|SR   u_fb_out/wr_reset[*]~FF|SR u_fb_out/axi_reset[*]~FF|SR u_fb_out/vid_reset[*]~FF|SR}]

set_max_delay -from [get_clocks {CLK_25M clk_225M core_clk hdmi_tx_slow_clk}] -to [get_pins {  u_fb_out/writer/words_fifo/rg_w0[*]~FF|D u_fb_out/writer/words_fifo/wg_r0[*]~FF|D u_fb_out/scanout/requests/rg_w0[*]~FF|D u_fb_out/scanout/requests/wg_r0[*]~FF|D}] 4.444
set_false_path -hold -from [get_clocks {CLK_25M clk_225M core_clk hdmi_tx_slow_clk}] -to [get_pins {  u_fb_out/writer/words_fifo/rg_w0[*]~FF|D u_fb_out/writer/words_fifo/wg_r0[*]~FF|D u_fb_out/scanout/requests/rg_w0[*]~FF|D u_fb_out/scanout/requests/wg_r0[*]~FF|D}]
set_bus_skew -from [get_clocks {CLK_25M clk_225M core_clk hdmi_tx_slow_clk}] -to [get_pins {  u_fb_out/writer/words_fifo/rg_w0[*]~FF|D u_fb_out/writer/words_fifo/wg_r0[*]~FF|D u_fb_out/scanout/requests/rg_w0[*]~FF|D u_fb_out/scanout/requests/wg_r0[*]~FF|D}] 4.444

set_false_path -to [get_pins {    u_fb_out/writer/fault_sync[0]~FF|D u_fb_out/scanout/ready_meta[*]~FF|D u_fb_out/scanout/available_meta[*]~FF|D}]

set_max_delay -from [get_clocks core_clk] -to [get_pins {u_fb_out/scanout/*cached_y*~FF|D u_fb_out/scanout/*cached_epoch*~FF|D}] 12.000
set_false_path -hold -from [get_clocks core_clk] -to [get_pins {u_fb_out/scanout/*cached_y*~FF|D u_fb_out/scanout/*cached_epoch*~FF|D}]
set_bus_skew -from [get_clocks core_clk] -to [get_pins {u_fb_out/scanout/*cached_y*~FF|D u_fb_out/scanout/*cached_epoch*~FF|D}] 12.000

set_false_path -from [get_clocks vid_clk_dvi2] -to [get_pins {checker0/stream_reset/*|D}]

# CNN_TIMING_PATCH_END

# DUAL_CLOCK_SCALER_BEGIN
# Two-row ownership uses Gray pointers. Bound propagation/skew to the faster
# clock period; hold is asynchronous only at the FIRST synchronizer stage.
# Single-bit request/fault/ready signals use two-stage synchronizers.
set_false_path -to [get_pins {      checker0/available_sync[0]~FF|D checker0/request_sync[0]~FF|D checker0/fault_sync[0]~FF|D}]
# Asynchronous assertion / locally synchronized release: constrain only the
# reset synchronizers, not the datapath registers they protect.
# 公共 DDR 服务在 core_clk 写 RGB24 FIFO，在 clk_225M 域读取。
# Gray 指针只约束第一级同步器的传播和偏斜；保留后续同步级的时序检查。
set_max_delay -from [get_clocks {core_clk clk_225M}] -to [get_pins {checker0/input_pixels/rg_w0[*]~FF|D checker0/input_pixels/wg_r0[*]~FF|D}] 4.444
set_false_path -hold -from [get_clocks {core_clk clk_225M}] -to [get_pins {checker0/input_pixels/rg_w0[*]~FF|D checker0/input_pixels/wg_r0[*]~FF|D}]
set_bus_skew -from [get_pins {checker0/input_pixels/*|CLK}] -to [get_pins {checker0/input_pixels/rg_w0[*]~FF|D checker0/input_pixels/wg_r0[*]~FF|D}] 4.444

# 字符状态邮箱：仅第一级同步触发器接收异步信号，后续同步级保持时序检查。
set_false_path -to [get_pins {u_fb_out/osd_request_sync[0]~FF|D u_fb_out/osd_ack_sync[0]~FF|D u_fb_out/switch_ready_sync[0]~FF|D}]
# 24位数据先写入并保持，通知经过三级视频时钟同步后才采样，确认返回前不覆盖。
# 只约束该握手数据总线的最大延迟和偏斜，不放宽 CNN/HDMI 同步计算路径。
set_max_delay -from [get_pins {u_fb_out/osd_mailbox[*]~FF|CLK}] -to [get_pins {u_fb_out/osd_pending[*]~FF|D}] 12.000
set_false_path -hold -from [get_pins {u_fb_out/osd_mailbox[*]~FF|CLK}] -to [get_pins {u_fb_out/osd_pending[*]~FF|D}]
set_bus_skew -from [get_pins {u_fb_out/osd_mailbox[*]~FF|CLK}] -to [get_pins {u_fb_out/osd_pending[*]~FF|D}] 12.000
# DUAL_CLOCK_SCALER_END

# BUTTON_CONTROL_BEGIN
# Mechanical inputs are asynchronous. Cut only the first sampling stages.
set_false_path -from [get_ports {key_i[*]}] -to [get_pins {key_meta[*]~FF|D}]
set_false_path -to [get_pins {key_reset_pipe[*]~FF|SR}]
set_false_path -from [get_clocks CLK_25M] -to [get_pins {display_control_meta[*]~FF|D g_cnn_enabled.u_cnn/u_weights/style_next_meta~FF|D}]
# BUTTON_CONTROL_END

# STYLE_RELOAD_BEGIN
# Cut only asynchronous first-stage samples; synchronize/reset-release stage 2 stays timed.
set_false_path -from [get_clocks core_clk] -to [get_pins {g_cnn_enabled.u_cnn/g_style_reload.reload_meta~FF|D}]
set_false_path -from [get_clocks clk_225M] -to [get_pins {g_cnn_enabled.u_cnn/u_weights/held_meta~FF|D}]
set_false_path -to [get_pins {g_cnn_enabled.u_cnn/g_style_reload.reset_release[*]~FF|SR}]
# STYLE_RELOAD_END

# Status LEDs are asynchronous human-visible outputs.
set_false_path -to [get_ports {led_status led_camera_ready led_weights_ready led_first_frame}]

# 显示模式经过两级视频时钟同步，再在帧边界锁存；只放开第一级异步采样。
set_false_path -from [get_clocks clk_225M] -to [get_pins {u_fb_out/scanout/fullscreen_meta~FF|D}]

# Two-digit CAM/CNN event notification CDC: cut ONLY first sampling stage.
set_false_path -to [get_pins {u_fb_out/cam_sync[0]~FF|D u_fb_out/cnn_sync[0]~FF|D}]

# Read-request FIFO payload: written before its Gray write pointer crosses
# two core-clock synchronizers; the payload is held until read acknowledgement.
# Bound ONLY this FIFO data bus, not synchronous HDMI or CNN datapaths.
set_max_delay -from [get_clocks hdmi_tx_slow_clk] -to [get_pins {u_fb_out/scanout/req_data[*]~FF|D}] 8.000
set_false_path -hold -from [get_clocks hdmi_tx_slow_clk] -to [get_pins {u_fb_out/scanout/req_data[*]~FF|D}]

# Adaptive-IN mailbox: cut only first synchronizer flops, retaining later timing.
set_false_path -to [get_pins {g_cnn_enabled.u_cnn/in_control/req_meta~FF|D g_cnn_enabled.u_cnn/in_control/ack_meta~FF|D g_cnn_enabled.u_cnn/in_control/alive_meta~FF|D}]
# The payloads remain stable until acknowledgement; bound only these buses.
set_max_delay -from [get_pins {g_cnn_enabled.u_cnn/in_control/mail_addr[*]~FF|CLK g_cnn_enabled.u_cnn/in_control/mail_data[*]~FF|CLK g_cnn_enabled.u_cnn/in_control/mail_write~FF|CLK}] -to [get_clocks clk_225M] 8.000
set_false_path -hold -from [get_pins {g_cnn_enabled.u_cnn/in_control/mail_addr[*]~FF|CLK g_cnn_enabled.u_cnn/in_control/mail_data[*]~FF|CLK g_cnn_enabled.u_cnn/in_control/mail_write~FF|CLK}] -to [get_clocks clk_225M]
set_max_delay -from [get_pins {g_cnn_enabled.u_cnn/in_control/response[*]~FF|CLK g_cnn_enabled.u_cnn/in_control/response_error~FF|CLK}] -to [get_clocks core_clk] 8.000
set_false_path -hold -from [get_pins {g_cnn_enabled.u_cnn/in_control/response[*]~FF|CLK g_cnn_enabled.u_cnn/in_control/response_error~FF|CLK}] -to [get_clocks core_clk]


# 暂停状态由225MHz域进入帧池AXI域；只切除第一级同步器。
set_false_path -from [get_clocks clk_225M] -to [get_pins {checker0/pause_meta~FF|D}]
