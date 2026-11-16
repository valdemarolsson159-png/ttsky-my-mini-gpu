import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


async def send_instruction(dut, inst):
    """Skickar en 16-bitars instruktion (2 byte) under prog_mode."""
    high_byte = (inst >> 8) & 0xFF
    low_byte  = inst & 0xFF
    for byte in (high_byte, low_byte):
        dut.ui_in.value = byte
        await ClockCycles(dut.clk, 1)
        dut.uio_in.value = 0b00000011  # prog_mode=1, prog_write_en=1
        await ClockCycles(dut.clk, 1)
        dut.uio_in.value = 0b00000001  # prog_mode=1, prog_write_en=0
        await ClockCycles(dut.clk, 1)


@cocotb.test()
async def test_project(dut):
    dut._log.info("Startar test av tt_um_my_mini_gpu")

    clock = Clock(dut.clk, 20, unit="ns")
    cocotb.start_soon(clock.start())

    # Reset
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    # 1. Ladda program i prog_mode
    dut.uio_in.value = 0b00000001
    await ClockCycles(dut.clk, 1)

    await send_instruction(dut, 0x400F)  # PC 0: LOAD r0
    await send_instruction(dut, 0x440F)  # PC 1: LOAD r1
    await send_instruction(dut, 0x304F)  # PC 2: MUL r0 = r0 * r1
    await send_instruction(dut, 0x004F)  # PC 3: ADD r0 = r0 + r1
    await send_instruction(dut, 0x800F)  # PC 4: STORE r0
    await send_instruction(dut, 0xC000)  # PC 5: HALT

    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 2)

    # 2. Starta GPU (puls på uio_in bit 2)
    dut.uio_in.value = 0b00000100
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = 0

    # Vektor A: (2, 3, 4, 5)
    await ClockCycles(dut.clk, 1)
    for val in (2, 3, 4, 5):
        dut.ui_in.value = val
        await ClockCycles(dut.clk, 1)

    # Vektor B: (3, 4, 5, 6)
    await ClockCycles(dut.clk, 2)
    for val in (3, 4, 5, 6):
        dut.ui_in.value = val
        await ClockCycles(dut.clk, 1)

    dut.ui_in.value = 0

    # 3. Vänta tills done (uio_out bit 3) blir hög
    for _ in range(50):
        await ClockCycles(dut.clk, 1)
        if (int(dut.uio_out.value) >> 3) & 1:
            break

    assert ((int(dut.uio_out.value) >> 3) & 1) == 1, "GPU satte inte done-flaggan!"
    dut._log.info("SUCCESS! tt_um_my_mini_gpu klarade cocotb-testet!")
