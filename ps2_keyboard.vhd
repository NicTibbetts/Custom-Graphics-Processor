-- ps2_keyboard.vhd: receives scan codes from a keyboard, debouncing the input
-- and checking for valid start/stop/parity bits before sending new scan codes to the CPU
-- Adapted from ic_34_MIPS_IO/ps2_keyboard.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.all;

entity ps2_keyboard is
  generic (
    clk_freq              : integer := 50_000_000;
    debounce_counter_size : integer := 8
  );
  port (
    clk          : in  STD_LOGIC;
    ps2_clk      : in  STD_LOGIC;
    ps2_data     : in  STD_LOGIC;
    ps2_code_new : out STD_LOGIC;
    ps2_code     : out STD_LOGIC_VECTOR(7 downto 0)
  );
end entity;

architecture logic of ps2_keyboard is
  -- ps2 arrives asynchronously, so sample both lines into the fpga clock
  -- domain before doing the rest of the receive work.
  signal sync_ffs     : STD_LOGIC_VECTOR(1 downto 0);
  signal ps2_clk_int  : STD_LOGIC;
  signal ps2_data_int : STD_LOGIC;
  signal ps2_word     : STD_LOGIC_VECTOR(10 downto 0);
  signal error        : STD_LOGIC;
  signal count_idle   : integer range 0 to clk_freq / 18_000;
begin
  process(clk)
  begin
    if rising_edge(clk) then
      sync_ffs(0) <= ps2_clk;
      sync_ffs(1) <= ps2_data;
    end if;
  end process;

  debounce_ps2_clk : entity work.debounce
    generic map (
      counter_size => debounce_counter_size
    )
    port map (
      clk    => clk,
      button => sync_ffs(0),
      result => ps2_clk_int
    );

  debounce_ps2_data : entity work.debounce
    generic map (
      counter_size => debounce_counter_size
    )
    port map (
      clk    => clk,
      button => sync_ffs(1),
      result => ps2_data_int
    );

  -- the ps2 protocol shifts one data bit on each falling ps2 clock edge.
  process(ps2_clk_int)
  begin
    if ps2_clk_int'event and ps2_clk_int = '0' then
      ps2_word <= ps2_data_int & ps2_word(10 downto 1);
    end if;
  end process;

  error <= not (not ps2_word(0) and ps2_word(10) and (ps2_word(9) xor ps2_word(8) xor
       ps2_word(7) xor ps2_word(6) xor ps2_word(5) xor ps2_word(4) xor ps2_word(3) xor
       ps2_word(2) xor ps2_word(1)));

  -- once the line has been idle long enough and parity/start/stop look valid,
  -- publish the byte for one clock as a fresh scan code.
  process(clk)
  begin
    if rising_edge(clk) then
      if ps2_clk_int = '0' then
        count_idle <= 0;
      elsif count_idle /= clk_freq / 18_000 then
        count_idle <= count_idle + 1;
      end if;

      if count_idle = clk_freq / 18_000 and error = '0' then
        ps2_code_new <= '1';
        ps2_code <= ps2_word(8 downto 1);
      else
        ps2_code_new <= '0';
      end if;
    end if;
  end process;
end architecture;