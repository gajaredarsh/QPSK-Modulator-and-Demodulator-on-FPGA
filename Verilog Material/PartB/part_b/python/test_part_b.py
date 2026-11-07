"""
test_part_b.py  (Part B)
Unit tests for channel.py and fixedpoint.py. The Python model is the reference the RTL is checked
against, so it has to be right first.

Run either way (from anywhere):
    python3 python/test_part_b.py        (plain python, no extra packages)
    pytest -v python/test_part_b.py      (if pytest is installed)
"""
import os
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import params
import channel
import fixedpoint


# ------------------------------------------------------------------ LFSR
def test_lfsr_fast_matches_reference():
    for seed in (1, 0x5CDF, 0xFFFF, 0x1234):
        n = 3000
        assert channel.lfsr_bits(n, seed) == channel.lfsr_bits_reference(n, seed)


def test_lfsr_is_maximal_length():
    states, _, _ = channel._lfsr_tables()
    assert len(set(states.tolist())) == channel.LFSR_PERIOD       # every non-zero state once


def test_lfsr_zero_seed_is_replaced():
    assert channel.lfsr_bits(50, 0) == channel.lfsr_bits(50, 1)


def test_byte_first_bit_is_msb():
    bits = channel.lfsr_bits_reference(8, 0x5CDF)
    assert channel.lfsr_byte_stream(1, 0x5CDF)[0] == int("".join(map(str, bits)), 2)


# ------------------------------------------------------------------ noise statistics
def test_raw_noise_range_mean_std():
    raw = channel.lfsr_noise_raw(channel.LFSR_PERIOD)              # one full period
    assert raw.min() >= -765 and raw.max() <= 765
    assert abs(raw.mean()) < 1.0
    assert abs(raw.std() - channel.NOISE_RAW_STD) < 1.0            # 181.02


def test_raw_noise_repeats_every_period():
    raw = channel.lfsr_noise_raw(channel.LFSR_PERIOD + 100)
    assert np.array_equal(raw[:100], raw[channel.LFSR_PERIOD:])


def test_seeds_are_nonzero_and_distinct():
    assert len(set(channel.NOISE_SEEDS)) == len(channel.NOISE_SEEDS) == channel.NOISE_K
    assert all(0 < s < 65536 for s in channel.NOISE_SEEDS)


# ------------------------------------------------------------------ gain table
def test_gain_zero_means_no_noise():
    assert not channel.noise_int(500, 0).any()


def test_gain_table_values_and_realized_ebn0():
    table = channel.gain_table()
    assert len(table) == 16 and all(0 < g < (1 << channel.NOISE_GAIN_BITS) for g in table)
    assert table == sorted(table, reverse=True)                    # more Eb/N0 = less noise
    for e, g in zip(channel.EBN0_TABLE_DB, table):
        assert abs(channel.realized_ebn0_db(g) - e) < 0.05


def test_widths_cover_worst_case():
    w = channel.noise_path_widths()
    assert w == {"raw": 11, "prod": 24, "noise": 16, "sum": 16}


def test_realized_noise_power_matches_ebn0():
    # noise std in the TX scale should be sigma_tx = 2047 * sqrt(4/EbN0)
    for e in (0, 6, 12):
        n = channel.noise_int(channel.LFSR_PERIOD, channel.noise_gain(e))
        want = params.DATAPATH_FULL_SCALE * np.sqrt(channel.noise_sigma2(e))
        assert abs(n.std() / want - 1) < 0.01


# ------------------------------------------------------------------ noise_int / awgn_int
def test_noise_int_matches_formula():
    raw = channel.lfsr_noise_raw(1000)
    assert np.array_equal(channel.noise_int(1000, 2902), (raw * 2902 + 128) >> 8)


def test_noise_int_rounds_half_up_and_floors_negative():
    # (raw*gain + 128) >> 8 is an arithmetic (floor) shift, like >>> in Verilog
    assert ((-1 * 1 + 128) >> 8) == 0 and ((-129 + 128) >> 8) == -1


def test_awgn_int_formula_and_noiseless_scaling():
    s = np.arange(-4096, 4096, 7, dtype=np.int64)
    r = channel.awgn_int(s, gain=0)
    assert np.array_equal(r, np.clip((s + 4) >> 3, -2048, 2047))   # no noise: just 2047 -> 255.9
    s2 = np.array([2047, -2047, 0])
    assert channel.awgn_int(s2, gain=0).tolist() == [256, -256, 0]


def test_awgn_int_ebn0_equals_gain_path():
    s = np.arange(2000, dtype=np.int64) - 1000
    assert np.array_equal(channel.awgn_int(s, ebn0_db=6), channel.awgn_int(s, gain=channel.noise_gain(6)))


def test_awgn_int_rejects_floats_and_missing_gain():
    for bad in (lambda: channel.awgn_int(np.array([0.5]), gain=0),
                lambda: channel.awgn_int(np.array([1, 2]))):
        try:
            bad()
        except (TypeError, ValueError):
            continue
        raise AssertionError("expected TypeError/ValueError")


def test_awgn_int_saturates_at_both_limits():
    s = np.full(20000, 4095, dtype=np.int64)
    r = channel.awgn_int(s, gain=8191)
    assert r.max() == 2047 and (r == 2047).sum() > 0
    r = channel.awgn_int(-s, gain=8191)
    assert r.min() == -2048 and (r == -2048).sum() > 0


def test_wide_output_is_sum_before_shift():
    s = np.arange(100, dtype=np.int64)
    r, wide = channel.awgn_int(s, gain=1000, return_wide=True)
    assert np.array_equal(wide, s + channel.noise_int(100, 1000))
    assert np.array_equal(r, np.clip((wide + 4) >> 3, -2048, 2047))


def test_per_sample_gain_array():
    n = 500
    s = np.arange(n, dtype=np.int64)
    g = np.where(np.arange(n) % 3 == 0, 5790, 0)
    r = channel.awgn_int(s, gain=g)
    raw = channel.lfsr_noise_raw(n)
    want = np.clip((s + ((raw * g + 128) >> 8) + 4) >> 3, -2048, 2047)
    assert np.array_equal(r, want)


# ------------------------------------------------------------------ fixedpoint
def test_saturate_limits_and_type_check():
    assert fixedpoint.saturate(np.array([-5000, -2048, 0, 2047, 5000]), 12).tolist() == [-2048, -2048, 0, 2047, 2047]
    try:
        fixedpoint.saturate(np.array([1.5]), 12)
    except TypeError:
        return
    raise AssertionError("saturate() must reject floats")


def test_to_int_and_clip_fraction():
    assert fixedpoint.to_int([1.0, -1.0, 0.5], 12, 8.0).tolist() == [256, -256, 128]
    assert fixedpoint.to_int([100.0], 12, 8.0).tolist() == [2047]
    assert fixedpoint.clip_fraction([0.0, 100.0], 12, 8.0) == 0.5


def test_signed_hex_roundtrip_all_values():
    with tempfile.TemporaryDirectory() as d:
        for bits in (1, 4, 11, 12, 13, 16):
            lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
            vals = np.arange(lo, hi + 1) if bits <= 13 else np.array([lo, -1, 0, 1, hi])
            fn = os.path.join(d, "x.hex")
            fixedpoint.write_hex(fn, vals, bits)
            assert np.array_equal(fixedpoint.read_hex(fn, bits), vals)


def test_hex_digit_count_and_twos_complement():
    assert fixedpoint.to_hex([-1, 5, -2048], 12) == ["fff", "005", "800"]
    assert fixedpoint.to_hex([-1], 13) == ["1fff"]


def test_unsigned_hex_reader_for_gain_and_seeds():
    with tempfile.TemporaryDirectory() as d:
        fn = os.path.join(d, "g.hex")
        gains = channel.gain_table()
        fixedpoint.write_hex(fn, gains, channel.NOISE_GAIN_BITS)
        assert fixedpoint.read_hex_unsigned(fn).tolist() == gains
        # the signed reader would wrongly make any gain >= 4096 negative (13 bit sign bit):
        assert (fixedpoint.read_hex(fn, channel.NOISE_GAIN_BITS) < 0).any()
        fn = os.path.join(d, "s.hex")
        fixedpoint.write_hex(fn, list(channel.NOISE_SEEDS), 16)
        assert fixedpoint.read_hex_unsigned(fn).tolist() == list(channel.NOISE_SEEDS)


# ------------------------------------------------------------------ generated files agree with the model
def test_generated_files_match_model_if_present():
    root = os.path.dirname(HERE)
    gh = os.path.join(root, "vectors", "noise_gain_table.hex")
    if os.path.exists(gh):
        assert fixedpoint.read_hex_unsigned(gh).tolist() == channel.gain_table()
    sh = os.path.join(root, "vectors", "noise_seeds.hex")
    if os.path.exists(sh):
        assert fixedpoint.read_hex_unsigned(sh).tolist() == list(channel.NOISE_SEEDS)
    rom = os.path.join(root, "rtl", "noise_gain_rom.v")
    if os.path.exists(rom):
        text = open(rom).read()
        for i, g in enumerate(channel.gain_table()):
            assert f"gain = {channel.NOISE_GAIN_BITS}'d{g};" in text


if __name__ == "__main__":
    tests = [(k, v) for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print("  ok  ", name)
        except Exception as e:                       # noqa: BLE001
            failed += 1
            print("  FAIL", name, "->", repr(e))
    print(f"\n{len(tests) - failed}/{len(tests)} Python tests passed")
    sys.exit(1 if failed else 0)
