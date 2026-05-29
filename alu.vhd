-- alu.vhd: 16-bit ALU for the GFX16 CPU, supporting the operations needed for the instruction set
-- Adapted from ic_15_build_mips_1/mips_alu.vhd and ic_23_shifter/shift_left.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity alu is
  port (
    a      : in  STD_LOGIC_VECTOR(15 downto 0);
    b      : in  STD_LOGIC_VECTOR(15 downto 0);
    op     : in  STD_LOGIC_VECTOR(3 downto 0);
    result : out STD_LOGIC_VECTOR(15 downto 0);
    zero   : out STD_LOGIC;
    lt     : out STD_LOGIC
  );
end entity;

architecture rtl of alu is
  -- this alu stays small on purpose.
  -- because it only implements the basic integer and fixed point operations we designed for
  signal res_s : STD_LOGIC_VECTOR(15 downto 0);
begin
  -- every operation is combinational so the single cycle cpu can decode an
  -- instruction and use the result in the same step.
  process(a, b, op)
    variable prod32 : signed(31 downto 0);
  begin
    case op is
      when "0000" =>
        res_s <= std_logic_vector(unsigned(a) + unsigned(b));
      when "0001" =>
        res_s <= std_logic_vector(unsigned(a) - unsigned(b));
      when "0010" =>
        -- multiply as signed 8.8 fixed point and keep the middle bits so the
        -- product lands back in the same format.
        prod32 := signed(a) * signed(b);
        res_s <= std_logic_vector(prod32(23 downto 8));
      when "0011" =>
        res_s <= a and b;
      when "0100" =>
        res_s <= a or b;
      when "0101" =>
        -- SHL pattern derived from shift_left.vhd
        -- (shift_left(unsigned(a), shamt)). shift amount comes from b[7:0].
        res_s <= std_logic_vector(shift_left(unsigned(a), to_integer(unsigned(b(7 downto 0)))));
      when "0110" =>
        -- arithmetic (sign-extending) right shift via shift_right(signed(a), ...).
        res_s <= std_logic_vector(shift_right(signed(a), to_integer(unsigned(b(7 downto 0)))));
      when "0111" =>
        -- pass-through of b used for LDI (b = zero-extended immediate) and MOV (b = rs register value).
        res_s <= b;
      when others =>
        res_s <= (others => '0');
    end case;
  end process;

  -- zero comes from the computed result, while lt compares the original
  -- operands so branches can reuse it directly.
  result <= res_s;
  zero <= '1' when res_s = x"0000" else '0';
  lt <= '1' when signed(a) < signed(b) else '0';
end architecture;