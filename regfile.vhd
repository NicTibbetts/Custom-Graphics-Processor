-- regfile.vhd: register file for the GFX16 CPU, with 8 registers of 16 bits each.
-- writes are synchronous because the register file is updated in the same step as the instruction execution, so we want to avoid a read/write conflict when an instruction writes to a register and then reads from it in the same cycle.
-- reads are combinational so the instruction can read register values in the same cycle as the instruction
-- Adapted from ic_16_build_mips_2/mips_register_file.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity regfile is
  port (
    clk : in  STD_LOGIC;
    we  : in  STD_LOGIC;
    -- 3 bits for 8 registers.
    ra1 : in  STD_LOGIC_VECTOR(2 downto 0);
    ra2 : in  STD_LOGIC_VECTOR(2 downto 0);
    wa  : in  STD_LOGIC_VECTOR(2 downto 0);
    wd  : in  STD_LOGIC_VECTOR(15 downto 0);
    rd1 : out STD_LOGIC_VECTOR(15 downto 0);
    rd2 : out STD_LOGIC_VECTOR(15 downto 0)
  );
end entity;

architecture rtl of regfile is
  -- keep the register file intentionally simple: eight 16bit registers
  -- synchronous writes, and combinational reads.
  type reg_array_t is array (0 to 7) of STD_LOGIC_VECTOR(15 downto 0);
  signal regs : reg_array_t := (others => (others => '0'));
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if we = '1' then
        -- no hardwired zero register, all eight registers are writable.
        regs(to_integer(unsigned(wa))) <= wd;
      end if;
    end if;
  end process;

  -- reads are combinational (outside the clocked process) so our single-cycle CPU
  -- can use the read result in the same cycle as the instruction fetch.
  rd1 <= regs(to_integer(unsigned(ra1)));
  rd2 <= regs(to_integer(unsigned(ra2)));
end architecture;