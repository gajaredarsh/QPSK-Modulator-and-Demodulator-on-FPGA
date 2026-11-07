# Part B: noise channel (Verilog + Python)

Adds noise to the TX mixer output so the receiver can be tested at a chosen Eb/N0.
It does exactly what `channel.awgn_int()` does in Python, and the testbenches prove it number by number.

## Folders
- `python/`  `channel.py`, `fixedpoint.py` (the repo versions), `params.py` (copy so the script runs alone;
  the team `params.py` is the master), `gen_part_b_vectors.py` and `test_part_b.py` (25 Python unit tests)
- `rtl/`     the Verilog. `qpsk_params.vh` and `noise_gain_rom.v` are GENERATED, do not edit them by hand
- `tb/`      six self-checking testbenches (they print PASS or FAIL)
- `vectors/` golden `.hex` files made by `gen_part_b_vectors.py` from the Python model

## Run
    sh run_sim.sh          (needs python3 + numpy and Icarus Verilog, run from this folder)

`run_sim.sh` runs the Python tests, regenerates the vectors, then every testbench; it stops with an error if any
of them fails. The Python tests alone: `python3 python/test_part_b.py` (or `pytest -v python/`).

## Use in Vivado
- Add everything in `rtl/` as design sources and set `rtl/` as an include directory
  (or mark `qpsk_params.vh` as Global Include), because every module does `include "qpsk_params.vh"`.
- Testbenches read `../vectors/*.hex`, so run the simulation from the `tb/` folder
  (or change the paths at the top of each testbench).

## The block the rest of the design uses: awgn_channel
| port | width | meaning |
|---|---|---|
| clk, rst | 1 | 100 MHz, synchronous active-high reset |
| in_valid | 1 | sample enable from the TX (one pulse per sample) |
| s_tx | 13 signed | TX mixer output, 2047 = amplitude 1.0 |
| level | 4 | Eb/N0 from the switches, level n = n dB (0..15). Synchronise it in top.v |
| noise_off | 1 | 1 = no noise, r_rx = (s_tx + 4) >>> 3 |
| out_valid | 1 | high for every output sample |
| r_rx | 12 signed | RX word, 256 = amplitude 1.0 (saturated to -2048..2047) |
| wide | 16 signed | sum before the shift, for debugging |

Latency: an input accepted at rising edge N (in_valid = 1 and s_tx present) gives out_valid / r_rx / wide
after rising edge N+5. That is 6 registered stages when the edge N itself is counted as the first one, so when
the BER comparator (Part D) delays its reference bits, delay them by 6 clocks. Tested exactly at every clock, at
1 Msample/s, in bursts, and with a changing gain. Inside: `gauss_noise` 2 clocks, `noise_scale` 2 clocks,
add 1, shift/clip 1.

The gain travels with its sample: `level` / `noise_off` (or `gain` on `awgn_core`) may change at any time, every
sample is scaled with the gain it entered with (`tb_awgn_gainchange`). Still synchronise/debounce the switches
in top.v, because a switch that changes in the middle of a clock edge is a metastability problem, not a timing one.

The noise is the same after every reset and repeats every 65535 samples. It is a Gaussian approximation
(sum of six bytes from six LFSRs), not true Gaussian noise.
