"""
compare_results.py
Compares the FIXED-POINT chain with the FLOATING-POINT chain of the QPSK golden model.

the files written are in compare_outputs/.

What is compared
    1. both folders use identical params.py / fixedpoint.py
    2. BER sweep, no FIR and FIR: fixed vs float vs ideal theory vs exact prediction (z-scores)
    3. the shared 4 dB scenario (same bits, same noise): BER, bit disagreements, decision values
    4. hardware-style LFSR noise run vs the exact prediction
    5. integer datapath health: accumulator never overflows, input clipping

Exit code 0 = every check passed, 1 = at least one failed.
"""

import contextlib
import importlib
import io
import math
import os
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
FIX_DIR = os.path.join(HERE, "fixed_point")
FLT_DIR = os.path.join(HERE, "floating_point")
OUT_DIR = os.path.join(HERE, "compare_outputs")

QUICK = "--quick" in sys.argv
VERBOSE = "--verbose" in sys.argv

FAILS = []


def check(ok, label, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f"  ({detail})" if detail else ""))
    if not ok:
        FAILS.append(label)


# small statistics helpers (no imports from the simulation code)

def z_vs_expected(errors, bits, p):
    # Binomial z-score of a measured error count against an expected BER.
    mean = bits * p
    sd = math.sqrt(bits * p * (1 - p))
    return (errors - mean) / sd


def z_two_sample(e1, n1, e2, n2):
    # Unpaired two-proportion z-score (conservative: the two runs share bits and noise).
    p1, p2 = e1 / n1, e2 / n2
    p = (e1 + e2) / (n1 + n2)
    sd = math.sqrt(p * (1 - p) * (1 / n1 + 1 / n2))
    return 0.0 if sd == 0 else (p1 - p2) / sd


def theory_ber(ebn0_db):
    return 0.5 * math.erfc(math.sqrt(10 ** (ebn0_db / 10)))      # Q(sqrt(2 Eb/N0))


def ebn0_for_ber(ber):
    # Eb/N0 (dB) at which ideal QPSK theory gives this BER (bisection).
    lo, hi = -10.0, 30.0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        if theory_ber(mid) > ber:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def same_file(a, b):
    with open(a, "rb") as fa, open(b, "rb") as fb:
        return fa.read() == fb.read()


# run the two mains in memory (no files written by them)

LOCAL_MODULES = ("params", "fixedpoint", "channel", "tx_nco", "rx_frontend", "rx_backend_eval",
                 "main_fixed", "main_float")


def run_main(folder, module):
    # Import `module` from `folder` in a clean namespace, run main() and return its numbers.
    for k in LOCAL_MODULES:
        sys.modules.pop(k, None)
    sys.path.insert(0, folder)
    out = sys.stdout if VERBOSE else io.StringIO()
    try:
        mod = importlib.import_module(module)
        mod.QUICK = QUICK
        mod.SAVE_FILES = False
        print(f">>> running {os.path.basename(folder)}/{module}.py main()" + ("  (quick)" if QUICK else ""))
        with contextlib.redirect_stdout(out):
            return mod.main()
    except AssertionError as e:
        if not VERBOSE:
            print(out.getvalue())
        print(f"{module}: one of its own checks failed: {e}")
        sys.exit(1)
    finally:
        sys.path.remove(folder)


# the comparison

def main():
    fx = run_main(FIX_DIR, "main_fixed")
    fl = run_main(FLT_DIR, "main_float")
    os.makedirs(OUT_DIR, exist_ok=True)

    print("FIXED-POINT vs FLOATING-POINT comparison")

    # 1. same configuration 
    print("\n 1. Both folders use the same configuration")
    for name in ("params.py", "fixedpoint.py"):
        a, b = os.path.join(FIX_DIR, name), os.path.join(FLT_DIR, name)
        check(same_file(a, b), f"{name} identical in both folders")
    check(np.array_equal(fx["ebn0"], fl["ebn0"]), "same Eb/N0 grid", str(fx["ebn0"].tolist()))
    statistical = not QUICK
    if not statistical:
        print("  (quick mode: statistical z-score limits are reported but not enforced)")

    ebn0 = fx["ebn0"]

    # 2. BER sweep
    print("\n 2. BER vs Eb/N0 (sweep)")
    print(f"{'Eb/N0':>6s} | {'float':>9s} {'fixed':>9s} {'ratio':>6s} {'z(f-x)':>7s} | "
        f"{'theory':>9s} {'exact':>9s} | {'z fl/exact':>10s} {'z fx/exact':>10s}")
    for label, kn, ke in (("no FIR", "no_fir", "exact_no_fir"), ("FIR", "fir", "exact_fir")):
        print(f"  [{label}]")
        for k, e in enumerate(ebn0):
            e_fl, n_fl = fl[f"err_{kn}"][k], fl[f"bits_{kn}"][k]
            e_fx, n_fx = fx[f"err_{kn}"][k], fx[f"bits_{kn}"][k]
            b_fl, b_fx = e_fl / n_fl, e_fx / n_fx
            zff = z_two_sample(e_fl, n_fl, e_fx, n_fx)
            exact = fl[ke][k]
            z_fl = z_vs_expected(e_fl, n_fl, exact)
            z_fx = z_vs_expected(e_fx, n_fx, exact)
            print(f"{e:6.1f} | {b_fl:9.3e} {b_fx:9.3e} {b_fx / b_fl:6.3f} {zff:7.2f} | "
                f"{fl['theory'][k]:9.3e} {exact:9.3e} | {z_fl:10.2f} {z_fx:10.2f}")
            if statistical:
                check(abs(zff) < 4, f"{label} @ {e:g} dB: fixed and float BER agree", f"z={zff:.2f}")
                check(abs(z_fx) < 4, f"{label} @ {e:g} dB: fixed BER matches the exact prediction",
                      f"z={z_fx:.2f}")

    print("\n  Implementation loss of the integer chain (Eb/N0 shift, FIR chain):")
    loss = []
    for k, e in enumerate(ebn0):
        d = ebn0_for_ber(fl["ber_fir"][k]) - ebn0_for_ber(fx["ber_fir"][k])
        loss.append(d)
        print(f"    {e:4.1f} dB: {d:+.3f} dB   (positive = fixed-point is worse; both runs use the same "
            f"bits and noise)")
    if statistical:
        check(abs(np.mean(loss)) < 0.1, "mean implementation loss is below 0.1 dB",
              f"mean {np.mean(loss):+.3f} dB")

    # 3. shared scenario 
    print(f"\n 3. Shared scenario at {fl['scen_ebn0']:g} dB (same bits, same noise) ")
    check(np.array_equal(fl["scen_bits_tx"], fx["scen_bits_tx"]), "both chains sent the same bits")
    ber_fl, ber_fx = fl["scen_ber"], fx["scen_ber"]
    rel = abs(ber_fx - ber_fl) / ber_fl
    print(f"  BER float {ber_fl:.5f} | BER fixed {ber_fx:.5f} | relative difference {rel * 100:.2f}%")
    check(rel < 0.05, "BER within 5% of each other", f"{rel * 100:.2f}%")

    rx_fl, rx_fx = fl["scen_bits_rx"], fx["scen_bits_rx"]
    n = min(len(rx_fl), len(rx_fx))
    disagree = int(np.sum(rx_fl[:n] != rx_fx[:n]))
    print(f"  decoded bits that differ between the chains: {disagree} of {n} ({100 * disagree / n:.3f}%)")

    # decision values, each already divided by its own noiseless level, so 1.0 = clean symbol
    I_fl, Q_fl = fl["scen_I"][1:-1].astype(float), fl["scen_Q"][1:-1].astype(float)
    I_fx, Q_fx = fx["scen_I"][1:-1].astype(float), fx["scen_Q"][1:-1].astype(float)
    m = min(len(I_fl), len(I_fx))
    gap = np.concatenate([I_fl[:m] - I_fx[:m], Q_fl[:m] - Q_fx[:m]])
    corr = np.corrcoef(np.concatenate([I_fl[:m], Q_fl[:m]]), np.concatenate([I_fx[:m], Q_fx[:m]]))[0, 1]
    rms = np.sqrt(np.mean(gap ** 2))
    print(f"  decision values (clean symbol = 1.0): RMS gap {rms:.4f} | "
        f"max |gap| {np.abs(gap).max():.4f} | correlation {corr:.6f}")
    check(rms < 0.05, "RMS gap of decision values below 0.05", f"{rms:.4f}")
    check(corr > 0.999, "decision values correlate better than 0.999", f"{corr:.6f}")

    # 4. LFSR noise run
    print("\n 4. Hardware-style LFSR noise run (2 dB, short)")
    exact = fl["lfsr_exact"]
    for name, d in (("float", fl), ("fixed", fx)):
        b = d["lfsr_ber"]
        r = abs(b - exact) / exact
        print(f"  {name}: BER {b:.4f} | exact prediction {exact:.4f} | off by {r * 100:.1f}%")
        check(r < 0.20, f"{name} LFSR-noise BER within 20% of the exact prediction", f"{r * 100:.1f}%")

    # 5. integer datapath health 
    print("\n 5. Integer datapath health ")
    acc_bits = fx["acc_bits"]
    limit = (1 << (acc_bits - 1)) - 1
    print(f"  accumulator width {acc_bits} bit | max |accumulator| seen {fx['acc_max']} | limit {limit}")
    check(fx["acc_max"] <= limit, "integrate-and-dump accumulator never overflows")
    print(f"  receiver input clipping fraction {fx['clip_fraction']:.2e}")
    check(fx["clip_fraction"] < 1e-3, "receiver input clipping below 0.1%")
    print(f"  noiseless decision level: float {fl['noiseless_level']:g} | "
        f"fixed {fx['noiseless_level']:g} (scaling only; decision values above are normalized)")

    # plot
    fine = np.arange(ebn0.min(), ebn0.max() + 0.01, 0.25)
    fig, ax = plt.subplots(figsize=(7, 5))
    ax.semilogy(fine, [theory_ber(e) for e in fine], "k-", lw=1, label="theory Q(sqrt(2Eb/N0))")
    ax.semilogy(ebn0, fl["exact_fir"], "b--", lw=1, label="exact prediction, FIR")
    ax.semilogy(ebn0, fl["ber_no_fir"], "o", mfc="none", color="tab:blue", label="float, no FIR")
    ax.semilogy(ebn0, fx["ber_no_fir"], "x", color="tab:red", label="fixed, no FIR")
    ax.semilogy(ebn0, fl["ber_fir"], "s", mfc="none", color="tab:green", label="float, FIR")
    ax.semilogy(ebn0, fx["ber_fir"], "+", ms=9, color="tab:orange", label="fixed, FIR")
    ax.set_xlabel("Eb/N0 (dB)")
    ax.set_ylabel("BER")
    ax.set_title("QPSK: floating point vs fixed point")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_DIR, "ber_comparison.png"), dpi=150)
    plt.close(fig)

    fig, axes = plt.subplots(1, 2, figsize=(9, 4))
    k = min(2000, m)
    axes[0].scatter(I_fl[:k], Q_fl[:k], s=3, alpha=0.5, label="float")
    axes[0].scatter(I_fx[:k], Q_fx[:k], s=3, alpha=0.5, label="fixed")
    axes[0].set_title("decision values (normalized)")
    axes[0].set_aspect("equal")
    axes[0].legend()
    axes[1].hist(gap, bins=80)
    axes[1].set_title("float - fixed decision gap")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_DIR, "scenario_comparison.png"), dpi=150)
    plt.close(fig)

    print("\nplots saved in compare_outputs/")
    print("ALL COMPARISON CHECKS PASSED" if not FAILS else f"{len(FAILS)} CHECK(S) FAILED:")
    for f in FAILS:
        print(f"   - {f}")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
