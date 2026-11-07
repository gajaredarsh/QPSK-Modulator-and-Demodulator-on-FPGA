import numpy as np
import matplotlib.pyplot as plt

iq = np.loadtxt("constellation.csv", delimiter=",", skiprows=1)
iq = iq[1:] / 2048.0  # Skip startup symbol and normalize

plt.scatter(iq[:, 0], iq[:, 1], s=4, alpha=0.4)
plt.axhline(0, color="gray", linewidth=0.5)
plt.axvline(0, color="gray", linewidth=0.5)
plt.xlabel("I")
plt.ylabel("Q")
plt.title("Verilog QPSK constellation — 4 dB")
plt.axis("equal")
plt.grid(True)
plt.show()
