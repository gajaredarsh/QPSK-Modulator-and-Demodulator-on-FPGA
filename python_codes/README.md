# Python model of the QPSK system: floating point vs fixed point

The code is split into two completely separate, self-contained folders, plus one script that
compares their results.

```
codes/
  floating_point/            ideal float chain (algorithm check, no bit widths)
    main_float.py            <- run this
    params.py  fixedpoint.py channel.py  tx_nco.py  rx_frontend.py  rx_backend_eval.py
    d_outputs/               float_ber_curve.png, float_constellations.png
  fixed_point/               integer chain with the exact widths the RTL uses
    main_fixed.py            <- run this
    params.py  fixedpoint.py channel.py  tx_nco.py  rx_frontend.py  rx_backend_eval.py
    d_outputs/               fixed_ber_curve.png, fixed_constellations.png,
                             golden/ (hex vectors for the Verilog testbench)
  compare_results.py         <- compares the two result files
  compare_outputs/           ber_comparison.png, scenario_comparison.png, report.txt
```

Neither folder imports anything from the other. `params.py` and `fixedpoint.py` are copies in
both folders; `compare_results.py` checks that the two copies are identical, so edit both
together.

## Requirements

Python 3, NumPy, SciPy, Matplotlib (`pip install numpy scipy matplotlib`).

## How to run

Run each script from inside its own folder:

```bash
cd floating_point && python3 main_float.py          # add --quick for a fast check
cd fixed_point    && python3 main_fixed.py          # add --quick for a fast check
```

The mains save no results file: they only write their plots (and, for fixed point, the golden
hex vectors). To compare the two chains, run from the codes folder:

```bash
python3 compare_results.py             # full run of both chains, then compare
python3 compare_results.py --quick     # quick versions (z-score limits not enforced)
python3 compare_results.py --verbose   # also show everything the two mains print
```

`compare_results.py` runs `main()` of both folders in memory (each in its own clean module
namespace, with plots and hex files switched off), takes the numbers they return and compares
them. Nothing is written except `compare_outputs/` (`ber_comparison.png`,
`scenario_comparison.png`, `report.txt`). It checks the BER sweep (no FIR and FIR) of both
chains against each other, against ideal theory and against the exact prediction, the shared
4 dB scenario (same bits, same noise: BER, bit disagreements, decision-value gap), the
LFSR-noise run, and that the integer accumulator never overflows. Exit code is 0 only if
everything passes.

## Background

On a computer we normally work in floating point, but real hardware uses fixed-point words.
Both versions of the chain are implemented here so the integer design can be shown to behave
like the ideal one.
