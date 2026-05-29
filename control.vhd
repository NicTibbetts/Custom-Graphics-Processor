-- control.vhd: control unit for the GFX16 CPU, generating control signals based on the opcode of the current instruction
-- Adapted from ic_16_build_mips_2/mips_controller.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.all;

entity control is
  port (
    opcode     : in  STD_LOGIC_VECTOR(3 downto 0);
    reg_write  : out STD_LOGIC;
    mem_read   : out STD_LOGIC;
    mem_write  : out STD_LOGIC;
    alu_src    : out STD_LOGIC;
    reg_dst    : out STD_LOGIC;
    mem_to_reg : out STD_LOGIC;
    branch_eq  : out STD_LOGIC;
    branch_lt  : out STD_LOGIC;
    jump       : out STD_LOGIC;
    -- plot and clr drive the framebuffer directly from the control unit
    -- for the graphics-specific instructions.
    plot       : out STD_LOGIC;
    clr        : out STD_LOGIC;
    alu_op     : out STD_LOGIC_VECTOR(3 downto 0)
  );
end entity;

architecture rtl of control is
begin
  -- this decoder is the whole control unit for the single cycle machine
  -- each opcode maps straight to the handful of control lines needed for one
  -- cycle of work.
  process(opcode)
  begin
    -- start from a safe do nothing defaults so an unexpected opcode does not
    -- accidentally write state.
    reg_write  <= '0';
    mem_read   <= '0';
    mem_write  <= '0';
    alu_src    <= '0';
    reg_dst    <= '1';
    mem_to_reg <= '0';
    branch_eq  <= '0';
    branch_lt  <= '0';
    jump       <= '0';
    plot       <= '0';
    clr        <= '0';
    alu_op     <= "0000";

    case opcode is
      when "0000" =>
        reg_write <= '1';
        alu_op <= "0000";
      when "0001" =>
        reg_write <= '1';
        alu_op <= "0001";
      when "0010" =>
        reg_write <= '1';
        alu_op <= "0010";
      when "0011" =>
        reg_write <= '1';
        alu_op <= "0011";
      when "0100" =>
        reg_write <= '1';
        alu_op <= "0100";
      when "0101" =>
        reg_write <= '1';
        alu_src <= '1';
        alu_op <= "0101";
      when "0110" =>
        reg_write <= '1';
        alu_src <= '1';
        alu_op <= "0110";
      when "0111" =>
        reg_write <= '1';
        alu_src <= '1';
        alu_op <= "0111";
      when "1000" =>
        reg_write <= '1';
        alu_op <= "0111";
      when "1001" =>
        reg_write <= '1';
        mem_read <= '1';
        mem_to_reg <= '1';
      when "1010" =>
        mem_write <= '1';
      when "1011" =>
        branch_eq <= '1';
        alu_op <= "0001";
      when "1100" =>
        branch_lt <= '1';
        alu_op <= "0001";
      when "1101" =>
        jump <= '1';
      when "1110" =>
        plot <= '1';
      when "1111" =>
        clr <= '1';
      when others =>
        null;
    end case;
  end process;
end architecture;