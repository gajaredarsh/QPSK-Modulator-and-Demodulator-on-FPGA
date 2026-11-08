# Rebuilds the Vivado project from the repo sources.
# Usage (from anywhere):  vivado -source fpga/scripts/create_project.tcl
set script_dir [file dirname [file normalize [info script]]]
set fpga_dir   [file normalize "$script_dir/.."]
set proj_dir   [file normalize "$::env(HOME)/vivado/qpsk"]

create_project qpsk $proj_dir -part xc7s50csga324-1 -force

# RTL (all subfolders) and the parameter header
add_files -norecurse [glob $fpga_dir/rtl/*/*.v]
add_files -norecurse [glob $fpga_dir/rtl/include/*.vh]
set_property file_type {Verilog Header} [get_files *.vh]
set_property include_dirs [list $fpga_dir/rtl/include] [get_filesets sources_1]
set_property include_dirs [list $fpga_dir/rtl/include] [get_filesets sim_1]

# ROM/LUT files that the RTL loads with $readmemh (needed for synthesis)
add_files -norecurse [list \
  $fpga_dir/vectors/lut_cos.hex \
  $fpga_dir/vectors/lut_sin.hex \
  $fpga_dir/vectors/fir_coeffs.hex]

# Testbenches and constraints
add_files -fileset sim_1 -norecurse [glob $fpga_dir/tb/*.v]
add_files -fileset constrs_1 -norecurse $fpga_dir/constraints/boolean.xdc

set_property top qpsk_top [get_filesets sources_1]
set_property top tb_qpsk  [get_filesets sim_1]
update_compile_order -fileset sources_1

# Absolute ROM paths so synthesis finds the .hex files wherever the project lives
set vec [file normalize "$fpga_dir/vectors"]
set gen [list COS_FILE=\"$vec/lut_cos.hex\" SIN_FILE=\"$vec/lut_sin.hex\" COEF_FILE=\"$vec/fir_coeffs.hex\"]
set_property generic $gen [get_filesets sources_1]
