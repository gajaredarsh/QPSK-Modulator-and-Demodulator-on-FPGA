import struct
from collections import deque
from functools import reduce
from operator import xor

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
import serial

PORT = "/dev/ttyUSB1"
BAUD = 115200
SCALE = 2048.0

port = serial.Serial(PORT, BAUD, timeout=0)
port.reset_input_buffer()

buffer = bytearray()
points = deque(maxlen=3000)
previous_total = None
previous_level = None
valid_packets = 0
bad_checksums = 0

fig, ax = plt.subplots(figsize=(7, 7))
scatter = ax.scatter([], [], s=5, alpha=0.4)
ax.plot([-1, -1, 1, 1], [-1, 1, -1, 1], "r+", markersize=12)
ax.axhline(0, color="gray", linewidth=0.5)
ax.axvline(0, color="gray", linewidth=0.5)
ax.set_xlim(-4, 4)
ax.set_ylim(-4, 4)
ax.set_aspect("equal")
ax.set_xlabel("I / 2048")
ax.set_ylabel("Q / 2048")
ax.grid(alpha=0.3)
ax.set_title("Waiting for FPGA packets…")

status = ax.text(
    0.02, 0.98, "", transform=ax.transAxes,
    va="top", fontsize=10,
    bbox=dict(facecolor="white", alpha=0.85)
)


def update(_):
    global previous_total, previous_level
    global valid_packets, bad_checksums

    buffer.extend(port.read(min(port.in_waiting, 8192)))

    while True:
        start = buffer.find(b"\xa5\x5a")

        if start < 0:
            # Preserve a possible first header byte across reads.
            buffer[:] = buffer[-1:] if buffer[-1:] == b"\xa5" else b""
            break

        del buffer[:start]

        if len(buffer) < 16:
            break

        packet = bytes(buffer[:16])
        checksum = reduce(xor, packet[2:15], 0)

        if checksum != packet[15]:
            bad_checksums += 1
            del buffer[0]
            continue

        del buffer[:16]
        i_value, q_value, total, errors, level = struct.unpack(
            "<hhIIB", packet[2:15]
        )

        if (
            previous_total is not None and total < previous_total
        ) or (
            previous_level is not None and level != previous_level
        ):
            points.clear()

        previous_total = total
        previous_level = level
        valid_packets += 1
        points.append((i_value / SCALE, q_value / SCALE))

        ber_text = f"{errors / total:.6g}" if total else "waiting"
        status.set_text(
            f"Noise setting: {level} dB\n"
            f"Total bits: {total:,}\n"
            f"Error bits: {errors:,}\n"
            f"BER: {ber_text}\n"
            f"Valid packets: {valid_packets:,}\n"
            f"Bad checksums: {bad_checksums:,}"
        )
        ax.set_title("FPGA QPSK — live constellation")

    if points:
        scatter.set_offsets(list(points))

    return scatter, status


animation = FuncAnimation(
    fig, update, interval=50, cache_frame_data=False
)

try:
    plt.show()
finally:
    port.close()
