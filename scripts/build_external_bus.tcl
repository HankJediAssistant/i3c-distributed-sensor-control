# I3C External Bus Demo - Vivado Build Script
# Target: Digilent Cmod S7 (XC7S25-1CSGA225)
# Usage: vivado -mode batch -source scripts/build_external_bus.tcl

set project_name "i3c_external_bus"
set project_dir "build/${project_name}"
set part "xc7s25csga225-1"
set top_module "spartan7_i3c_external_bus_top"

# I3C SDR rate override.  Default 4 MHz to match prior bitstream behavior.
# Overrides via env: I3C_SDR_HZ=8000000 vivado -mode batch -source ...
if {[info exists env(I3C_SDR_HZ)]} {
    set i3c_sdr_hz $env(I3C_SDR_HZ)
} else {
    set i3c_sdr_hz 4000000
}
puts "I3C_SDR_HZ override: $i3c_sdr_hz"

# RTL source files
set rtl_files [list \
    rtl/i3c_phy.v \
    rtl/i3c_bus_engine.v \
    rtl/i3c_ctrl_ccc.v \
    rtl/i3c_ctrl_daa.v \
    rtl/i3c_ctrl_direct_ccc.v \
    rtl/i3c_ctrl_entdaa.v \
    rtl/i3c_ctrl_inventory.v \
    rtl/i3c_known_target_hub.v \
    rtl/i3c_ctrl_policy.v \
    rtl/i3c_ctrl_scheduler.v \
    rtl/i3c_ctrl_top.v \
    rtl/i3c_ctrl_txn_layer.v \
    rtl/i3c_sdr_controller.v \
    rtl/i3c_target_ccc.v \
    rtl/i3c_target_daa.v \
    rtl/i3c_target_top.v \
    rtl/i3c_target_transport.v \
    rtl/uart_rx.v \
    rtl/uart_tx.v \
    rtl/uart_dual_target_lab_cmd_handler.v \
    rtl/fpga_test/i3c_demo_rate_tick.v \
    rtl/fpga_test/i3c_dual_target_lab_controller.v \
    rtl/fpga_test/i3c_sensor_frame_gen.v \
    rtl/fpga_test/i3c_sensor_gpio_target_demo.v \
    rtl/fpga_test/i3c_sensor_target_demo.v \
    rtl/fpga_test/i3c_sensor_controller_demo.v \
    rtl/fpga_test/spartan7_i3c_external_bus_top.v \
]

set xdc_file "constraints/spartan7_i3c_external_bus.xdc"

puts "============================================"
puts "I3C External Bus FPGA Build"
puts "Part: $part"
puts "Top: $top_module"
puts "============================================"

# Create project directory
file mkdir $project_dir

# Create project
create_project $project_name $project_dir -part $part -force

# Add RTL sources
foreach f $rtl_files {
    if {[file exists $f]} {
        add_files -norecurse $f
        puts "Added: $f"
    } else {
        puts "WARNING: File not found: $f"
    }
}

# Add constraints
if {[file exists $xdc_file]} {
    add_files -fileset constrs_1 -norecurse $xdc_file
    puts "Added constraints: $xdc_file"
} else {
    puts "ERROR: Constraints file not found: $xdc_file"
    exit 1
}

# Set top module
set_property top $top_module [current_fileset]

# Pass I3C_SDR_HZ as a Verilog generic to the top module
set_property generic "I3C_SDR_HZ=$i3c_sdr_hz" [current_fileset]

# Update compile order
update_compile_order -fileset sources_1

puts "============================================"
puts "Running Synthesis..."
puts "============================================"

# Run synthesis
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

puts "============================================"
puts "Running Implementation..."
puts "============================================"

# Run implementation
launch_runs impl_1 -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}

puts "============================================"
puts "Generating Bitstream..."
puts "============================================"

# Generate bitstream
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set bitstream "${project_dir}/${project_name}.runs/impl_1/${top_module}.bit"
if {[file exists $bitstream]} {
    puts "============================================"
    puts "BUILD SUCCESSFUL!"
    puts "Bitstream: $bitstream"
    puts "============================================"
} else {
    puts "ERROR: Bitstream not generated!"
    exit 1
}

close_project
exit 0
