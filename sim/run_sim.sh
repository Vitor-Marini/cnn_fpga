#!/bin/sh
# Simula o sistema completo no Questa (Intel FPGA Starter Edition). Uso: ./run_sim.sh
set -e
cd "$(dirname "$0")"
Q=${QUESTA_BIN:-$HOME/altera_lite/25.1std/questa_fse/bin}
$Q/vlib work
$Q/vcom -quiet -2002 ../rtl/weights_pkg.vhd ../rtl/selftest_pkg.vhd ../rtl/selftest_rom.vhd ../rtl/uart_rx.vhd ../rtl/frame_rx.vhd \
  ../rtl/cnn_core.vhd ../rtl/seg7.vhd ../rtl/top.vhd tb_top.vhd
$Q/vsim -c -quiet tb_top -do "run -all; quit -f"
