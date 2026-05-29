onbreak {quit -force}
onerror {quit -force}

asim -t 1ps +access +r +m+ -L xbip_utils_v3_0_10 -L xbip_pipe_v3_0_6 -L xbip_bram18k_v3_0_6 -L mult_gen_v12_0_16 -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib. xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {.udo}

run -all

endsim

quit -force
