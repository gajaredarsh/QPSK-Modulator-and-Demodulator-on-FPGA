# 100 MHz clock
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports {clk}]
create_clock -period 10.000 -name gclk [get_ports {clk}]

# Configuration voltage
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# Reset using button 0
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33} [get_ports {reset_btn}]

# Eb/N0 selection using switches 0 to 3
set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33} [get_ports {noise_switches[0]}]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports {noise_switches[1]}]
set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33} [get_ports {noise_switches[2]}]
set_property -dict {PACKAGE_PIN T2 IOSTANDARD LVCMOS33} [get_ports {noise_switches[3]}]

# Disable noise using switch 4
set_property -dict {PACKAGE_PIN T1 IOSTANDARD LVCMOS33} [get_ports {noise_off_switch}]

# FPGA UART transmit
set_property -dict {PACKAGE_PIN U11 IOSTANDARD LVCMOS33} [get_ports {uart_tx_pin}]