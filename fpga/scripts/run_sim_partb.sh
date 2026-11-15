#!/bin/sh
# run_sim.sh (Part B)
# Runs Python tests and all Verilog testbenches.

set -e

# Run Python tests and generate test data
python3 python/test_part_b.py
python3 python/gen_part_b_vectors.py

mkdir -p sim
cd tb

fail=0

# Run each testbench one by one
for t in tb_gauss_noise tb_noise_scale tb_awgn_core tb_awgn_gainchange tb_awgn_rates tb_awgn_channel; do
    echo "== $t"
    iverilog -g2005 -Wall -I../rtl -s $t -o ../sim/$t.vvp $t.v ../rtl/*.v
    vvp -n ../sim/$t.vvp | tee ../sim/$t.log | grep -v '^VCD'
    grep -q '^PASS' ../sim/$t.log || fail=1
    grep -q 'FAIL\|MISMATCH' ../sim/$t.log && fail=1
done

# Show the final test results
if [ $fail -eq 0 ]; then echo; echo "ALL PART B TESTBENCHES PASSED"; else echo; echo "SOME TESTBENCHES FAILED"; exit 1; fi
