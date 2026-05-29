-- gfx16_cpu_testbench.vhd: testbench for the GFX16 CPU.
-- It runs a small self-test program that checks basic instruction functionality
-- and then issues a known pattern of plot and clr instructions that the testbench
-- can watch for to confirm the cpu is working correctly.

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity gfx16_cpu_testbench is
end entity;

architecture sim of gfx16_cpu_testbench is
  -- keep the board inputs quiet and let the tiny self-test program exercise the
  -- cpu without the full graphics demo around it.
  constant CLK_PERIOD : time := 20 ns;

  signal clk : STD_LOGIC := '0';
  signal reset : STD_LOGIC := '1';
  signal io_shape : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
  signal io_color : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
  signal io_speed : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
  signal io_keycode : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
  signal io_leds : STD_LOGIC_VECTOR(15 downto 0);
  signal plot_en : STD_LOGIC;
  signal clr_en : STD_LOGIC;
  signal plot_x : STD_LOGIC_VECTOR(7 downto 0);
  signal plot_y : STD_LOGIC_VECTOR(6 downto 0);
  signal plot_color : STD_LOGIC_VECTOR(15 downto 0);
  signal test_done : STD_LOGIC := '0';
begin
  clk <= not clk after CLK_PERIOD / 2;

  uut : entity work.gfx16_cpu
    generic map (
      PC_RESET => 1,
      MEM_FILE => "gfx16_cpu_test_program.mem"
    )
    port map (
      clk        => clk,
      reset      => reset,
      io_shape   => io_shape,
      io_color   => io_color,
      io_speed   => io_speed,
      io_keycode => io_keycode,
      io_leds    => io_leds,
      plot_en    => plot_en,
      clr_en     => clr_en,
      plot_x     => plot_x,
      plot_y     => plot_y,
      plot_color => plot_color
    );

  -- success should reach the known led code, issue clr, and request one plot
  -- at the expected coordinate with the expected color.
  stimulus_proc : process
  begin
    wait for 4 * CLK_PERIOD;
    reset <= '0';

    wait until io_leds = x"0055";
    report "CPU self-test reached success LED pattern" severity note;

    wait until clr_en = '1';
    report "CLR instruction observed" severity note;

    wait until plot_en = '1';
    assert plot_x = std_logic_vector(to_unsigned(10, 8))
      report "PLOT X coordinate mismatch" severity failure;
    assert plot_y = std_logic_vector(to_unsigned(12, 7))
      report "PLOT Y coordinate mismatch" severity failure;
    assert plot_color = x"000F"
      report "PLOT color mismatch" severity failure;

    report "gfx16_cpu_testbench passed" severity note;
    test_done <= '1';
    wait;
  end process;

  -- every explicit failure path in the asm test writes a different led code.
  -- watch for those and fail immediately so the cause stays obvious.
  failure_monitor_proc : process(clk)
  begin
    if rising_edge(clk) then
      if reset = '0' then
        case io_leds is
          when x"0011" =>
            assert false report "BEQ not-taken case failed" severity failure;
          when x"0012" =>
            assert false report "BEQ taken case failed" severity failure;
          when x"0013" =>
            assert false report "BLT not-taken case failed" severity failure;
          when x"0014" =>
            assert false report "BLT taken case failed" severity failure;
          when x"0015" =>
            assert false report "LOAD/STORE verification failed" severity failure;
          when others =>
            null;
        end case;
      end if;
    end if;
  end process;

  -- if none of the expected milestones happen quickly, the cpu likely got stuck.
  timeout_proc : process
  begin
    wait for 5 us;
    if test_done = '0' then
      assert false report "Timeout waiting for CPU self-test to complete" severity failure;
    end if;
    wait;
  end process;
end architecture;