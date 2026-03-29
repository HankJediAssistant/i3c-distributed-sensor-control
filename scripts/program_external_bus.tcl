# I3C External Bus Demo - JTAG Programming Script
# Usage: vivado -mode batch -source scripts/program_external_bus.tcl

set bitstream "build/i3c_external_bus/i3c_external_bus.runs/impl_1/spartan7_i3c_external_bus_top.bit"

if {![file exists $bitstream]} {
    puts "ERROR: Bitstream not found: $bitstream"
    puts "Run scripts/build_external_bus.tcl first."
    exit 1
}

puts "============================================"
puts "Programming Cmod S7 with External Bus Demo"
puts "Bitstream: $bitstream"
puts "============================================"

puts "Opening hardware manager..."
open_hw_manager

puts "Connecting to hardware server..."
connect_hw_server

puts "Opening hardware target..."
open_hw_target

puts "Programming device..."
set_property PROGRAM.FILE $bitstream [current_hw_device]
program_hw_devices [current_hw_device]

puts "Closing connection..."
close_hw_target
disconnect_hw_server
close_hw_manager

puts "============================================"
puts "Programming complete!"
puts "============================================"
puts ""
puts "Pin connections required:"
puts "  DIP Pin 1 (L1) -> Controller SDA  ]"
puts "  DIP Pin 3 (M3) -> Target 0 SDA    ] --> Connect together + 2.2k to 3.3V"
puts "  DIP Pin 5 (M2) -> Target 1 SDA    ]"
puts ""
puts "  DIP Pin 2 (M4) -> Controller SCL  ]"
puts "  DIP Pin 4 (N2) -> Target 0 SCL    ] --> Connect together + 2.2k to 3.3V"
puts "  DIP Pin 6 (N1) -> Target 1 SCL    ]"
puts "============================================"

exit 0
