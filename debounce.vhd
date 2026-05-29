-- debounce.vhd: debouncing logic for the GFX16 CPU's keyboard input
-- Adapted from ic_34_MIPS_IO/debounce.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity debounce is
  generic (
    counter_size : integer := 19
  );
  port (
    clk    : in  STD_LOGIC;
    button : in  STD_LOGIC;
    result : out STD_LOGIC
  );
end entity;

architecture rtl of debounce is
  -- buttons are asynchronous and noisy so first synchronize them and then wait
  -- for the level to stay changed long enough before accepting it.
  signal sync0_s : STD_LOGIC := '0';
  signal sync1_s : STD_LOGIC := '0';
  signal stable_s : STD_LOGIC := '0';
  signal counter_s : unsigned(counter_size downto 0) := (others => '0');
begin
  process(clk)
  begin
    if rising_edge(clk) then
      sync0_s <= button;
      sync1_s <= sync0_s;

      if sync1_s = stable_s then
        counter_s <= (others => '0');
      elsif counter_s(counter_size) = '1' then
        stable_s <= sync1_s;
        counter_s <= (others => '0');
      else
        counter_s <= counter_s + 1;
      end if;
    end if;
  end process;

  result <= stable_s;
end architecture;