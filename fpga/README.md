# QPSK Modulator and Demodulator on FPGA

This project implements a QPSK transmitter, adjustable AWGN channel, coherent receiver, and bit-error counter on the Boolean Board. The design runs at 100 MHz on a Spartan-7 XC7S50 FPGA and sends received I/Q samples and BER counters to a computer over UART.

## Create the Vivado project

The project was developed with Vivado 2026.1 and requires Spartan-7 device support. Open a terminal where the `vivado` command is available.

From the **repository root**, run:

```bash
vivado -source fpga/scripts/create_project.tcl
```

If you are already **inside the `fpga/` folder**, run:

```bash
vivado -source scripts/create_project.tcl
```

The Tcl script creates `~/vivado/qpsk/qpsk.xpr`, adds the RTL, testbenches, constraints, and memory initialization files, and selects the following tops:

| Setting | Value |
| --- | --- |
| FPGA part | `xc7s50csga324-1` |
| Hardware top | `qpsk_top` |
| Simulation top | `tb_qpsk` |

Keep the `fpga/` source folder in place. The generated project references files in that folder. To reopen the project later, use the command below. Rerunning the creation script uses `-force` and can overwrite the existing project.

```bash
vivado ~/vivado/qpsk/qpsk.xpr
```

## Run the simulation

1. In Vivado, select **Run Simulation → Run Behavioral Simulation**.
2. In the **Tcl Console**, enter `run all`.
3. Read the final error count, total bits, and BER in the console.

The integrated testbench compares 50,000 QPSK symbols, corresponding to 100,000 bits. It also writes received I/Q samples to `constellation.csv` in the simulation working directory.

In the archived `tb/tb_qpsk.v`, the channel is set to nominal 8 dB and the UART packet is labeled 12 dB. Set both values to the desired level before collecting labeled results.

## Program the board

1. Select **Generate Bitstream** and allow synthesis and implementation to complete.
2. Connect and power the Boolean Board.
3. Open **Hardware Manager → Open Target → Auto Connect**.
4. Select the XC7S50, choose **Program Device**, and load `~/vivado/qpsk/qpsk.runs/impl_1/qpsk_top.bit`.

## View the live constellation and BER

Set `PORT` in `host/plot_live.py` to the board’s USB serial port. The default is `/dev/ttyUSB1` at 115200 baud. From `fpga/`, run:

```bash
python -m pip install pyserial matplotlib
python host/plot_live.py
```

The FPGA counts every eligible received symbol. The live plot displays the subset of I/Q samples transmitted over UART.

## Folder layout

| Folder | Contents |
| --- | --- |
| `rtl/` | Transmitter, channel, receiver, BER counter, UART, and board top |
| `tb/` | Module and full-chain testbenches |
| `vectors/` | Carrier lookup tables, FIR coefficients, and test vectors |
| `constraints/` | Boolean Board pin assignments and clock constraint |
| `scripts/` | Vivado project setup and verification scripts |
| `host/` | Python live constellation and BER viewer |
