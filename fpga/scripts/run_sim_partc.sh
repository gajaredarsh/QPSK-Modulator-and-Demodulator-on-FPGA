#!/bin/sh
# run_sim.sh (Part C)
# Runs all Part C testbenches using Icarus Verilog.
#
#   PARTA=/path/to/partA_rtl  PARTB=/path/to/part_b  [MODEL=/path/to/python_codes/fixed_point]  sh run_sim.sh
#
#   PARTA  Path to the Part A folder
#   PARTB  Path to the Part B folder
#   MODEL  Optional path to the Python model for generating test vectors

set -e

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
: "${PARTA:?set PARTA to the Part A folder}"
: "${PARTB:?set PARTB to the Part B folder}"

# Generate test vectors if the model path is given
if [ -n "$MODEL" ]; then
    python3 -I scripts/gen_rx_vectors.py --model "$MODEL" --partb "$PARTB/python" --parta "$PARTA"
fi

rm -rf sim; mkdir -p sim/inc
cd sim
ln -s ../vectors vectors
cp "$PARTA"/generated/lut_cos.hex "$PARTA"/generated/lut_sin.hex .
cp ../vectors/fir_coeffs.hex .

# Combine both parameter files to avoid include conflicts
{ echo '`ifndef QPSK_PARAMS_VH'; echo '`define QPSK_PARAMS_VH'
  grep -h '^`define' "$PARTA/generated/qpsk_params.vh" | grep -v QPSK_PARAMS_VH
  grep -h '^`define' "$PARTB/rtl/qpsk_params.vh"       | grep -v QPSK_PARAMS_VH
  echo '`endif'; } > inc/qpsk_params.vh

A_RTL="$PARTA/rtl/nco.v"
A_TX="$PARTA/rtl/nco.v $PARTA/rtl/prbs7_gen.v $PARTA/rtl/qpsk_mapper.v $PARTA/rtl/tx_mixer.v $PARTA/rtl/tx_top.v"
fail=0
check() { grep -q '^PASS' "$1" || fail=1; grep -q 'FAIL\|MISMATCH\|LATENCY\|COUNT' "$1" && fail=1; true; }

# Run the receiver tests with different modes
for m in 0 1 2; do
    echo "== tb_rx_frontend MODE=$m"
    iverilog -g2005 -I../rtl -I"$PARTA/generated" -Ptb_rx_frontend.MODE=$m -s tb_rx_frontend \
        -o t_rx$m.vvp ../tb/tb_rx_frontend.v ../rtl/*.v $A_RTL
    vvp -n t_rx$m.vvp | grep -v '^VCD\|finish called' | tee t_rx$m.log
    check t_rx$m.log
done

# Run the complete TX to RX chain test
chain() {
    echo "== tb_chain $1"
    iverilog -g2005 -Iinc -I../rtl -Ptb_chain.CLK_DIV=$2 -Ptb_chain.NOISE_OFF=$3 -Ptb_chain.LEVEL=$4 \
        "-Ptb_chain.ACC_I=\"vectors/chain_acc_i_$5.hex\"" "-Ptb_chain.ACC_Q=\"vectors/chain_acc_q_$5.hex\"" \
        -s tb_chain -o t_ch.vvp ../tb/tb_chain.v ../rtl/*.v $A_TX "$PARTB"/rtl/*.v
    vvp -n t_ch.vvp | grep -v '^VCD\|finish called' | tee t_ch.log
    check t_ch.log
}

chain "noise off, every clock"        1   1 6 off
chain "noise off, 1 Msample/s"        100 1 6 off
chain "6 dB, every clock"             1   0 6 L6
chain "6 dB, 1 Msample/s"             100 0 6 L6
chain "2 dB, 1 Msample/s"             100 0 2 L2

# Show the final test results
echo
if [ $fail -eq 0 ]; then echo "ALL PART C TESTBENCHES PASSED"; else echo "SOME PART C TESTBENCHES FAILED"; exit 1; fi
