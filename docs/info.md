<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This project is a compact **4-core 8-bit SIMD Mini-GPU** (`tt_um_my_mini_gpu`) designed to fit on a single 1x1 Tiny Tapeout tile (~15,000 µm²).

The architecture consists of four main blocks:
- **SIMD Core (`SimdCore`):** 4 parallel 8-bit Processing Elements (`PE0`–`PE3`), each with two 8-bit general-purpose registers (`r0`, `r1`) and a shared ALU supporting `ADD`, `SUB`, `AND`, and a `3x3`-bit hardware multiplier (`MUL`).
- **Instruction RAM (`GpuInstructionRam`):** A programmable 6x16-bit instruction memory loaded over the 8-bit input bus before execution.
- **Dispatcher (`GpuDispatcher`):** Fetches and decodes 16-bit instructions, manages the program counter (`PC`), and applies per-core predication masks (`pe_mask`).
- **I/O Interface (`GpuIoInterface`):** A shared 32-bit shift register that streams 4-byte vectors between `ui_in` and the SIMD cores during `LOAD` and `STORE` operations, while simultaneously driving a direct 4-bit RGBI video output on `uio[7:4]`.

### Instruction Format (16-bit)
- `[15:14]` **Opcode:** `00` = ALU, `01` = LOAD, `10` = STORE, `11` = HALT
- `[13:12]` **ALU Op:** `00` = ADD, `01` = SUB, `10` = AND, `11` = MUL (3x3-bit)
- `[11:10]` **Destination Register (`waddr`):** `0` = `r0`, `1` = `r1`
- `[9:8]` **Source Register A (`raddr_a`):** `0` = `r0`, `1` = `r1`
- `[7:6]` **Source Register B (`raddr_b`):** `0` = `r0`, `1` = `r1`
- `[3:0]` **Core Mask (`pe_mask`):** Active-high enable mask for `PE3`..`PE0`

## How to test

1. **Program Upload:** Set `uio` (`prog_mode`) high (`1`). Send up to six 16-bit instructions (MSB first, then LSB) on `ui_in[7:0]`, pulsing `uio` (`prog_write_en`) high and low for each byte. Set `uio` back to `0` when finished.
2. **Start Execution:** Pulse `uio` (`start`) high for one clock cycle.
3. **Stream Vector Data:** When the GPU executes a `LOAD` instruction, stream 4 bytes (one per core) on `ui_in[7:0]`.
4. **Read Results:** During `STORE`, the 4 computed bytes appear sequentially on `uo_out[7:0]` and the lower 4 bits are output as 4-bit RGBI color signals on `uio[7:4]`. When `HALT` is reached, `uio` (`done`) goes high (`1`).

## External hardware

Optional external VGA resistor DAC connected to `uio[7:4]` (`R`, `G`, `B`, `Intensity`) together with an external `HSYNC`/`VSYNC` timing generator to display direct 16-color pixel output without microcontroller overhead.
