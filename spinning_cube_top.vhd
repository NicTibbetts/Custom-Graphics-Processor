-- spinning_cube_top.vhd: top-level module for the spinning cube demo.
-- connects the CPU, VGA driver, framebuffer, input controller, and display hex modules together
-- Adapted from ic_16_build_mips_2/mips_basys3.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity spinning_cube_top is
  port (
    CLK100MHZ : in  STD_LOGIC;
    btnC      : in  STD_LOGIC;
    btnU      : in  STD_LOGIC;
    btnL      : in  STD_LOGIC;
    btnR      : in  STD_LOGIC;
    btnD      : in  STD_LOGIC;
    sw        : in  STD_LOGIC_VECTOR(15 downto 0);
    -- PS/2 ports for keyboard input.
    PS2Clk    : in  STD_LOGIC;
    PS2Data   : in  STD_LOGIC;
    -- VGA output ports for the framebuffer display pipeline.
    vgaRed    : out STD_LOGIC_VECTOR(3 downto 0);
    vgaGreen  : out STD_LOGIC_VECTOR(3 downto 0);
    vgaBlue   : out STD_LOGIC_VECTOR(3 downto 0);
    Hsync     : out STD_LOGIC;
    Vsync     : out STD_LOGIC;
    -- LED is 16-bit, driven directly by the CPU's io_leds register.
    LED       : out STD_LOGIC_VECTOR(15 downto 0);
    seg       : out STD_LOGIC_VECTOR(6 downto 0);
    an        : out STD_LOGIC_VECTOR(3 downto 0);
    dp        : out STD_LOGIC
  );
end entity;

architecture rtl of spinning_cube_top is
  -- this top-level is mostly wiring.
  -- it derives the clocks, connects the cpu to the board-facing blocks,
  -- and routes a compact debug bus to the seven seg display.
  signal clk_div : unsigned(15 downto 0) := (others => '0');
  signal clk_25 : STD_LOGIC;
  signal cpu_clk : STD_LOGIC;

  signal plot_en_s : STD_LOGIC;
  signal clr_en_s : STD_LOGIC;
  signal plot_x_s : STD_LOGIC_VECTOR(7 downto 0);
  signal plot_y_s : STD_LOGIC_VECTOR(6 downto 0);
  signal plot_color_s : STD_LOGIC_VECTOR(15 downto 0);

  signal fb_x_s : STD_LOGIC_VECTOR(7 downto 0);
  signal fb_y_s : STD_LOGIC_VECTOR(6 downto 0);
  signal fb_color_s : STD_LOGIC_VECTOR(15 downto 0);
  signal frame_tick_s : STD_LOGIC;
  signal io_shape_s : STD_LOGIC_VECTOR(15 downto 0);
  signal io_color_s : STD_LOGIC_VECTOR(15 downto 0);
  signal io_speed_s : STD_LOGIC_VECTOR(15 downto 0);
  signal io_keycode_s : STD_LOGIC_VECTOR(15 downto 0);
  signal cpu_leds_s : STD_LOGIC_VECTOR(15 downto 0);
  signal display_bus_s : STD_LOGIC_VECTOR(15 downto 0);
begin
  -- divide the 100 mhz board clock down for vga timing and the demo cpu.
  process(CLK100MHZ)
  begin
    if rising_edge(CLK100MHZ) then
      clk_div <= clk_div + 1;
    end if;
  end process;

  clk_25 <= clk_div(1);
  -- keep the cpu several times faster than the scanout clock so it has time to
  -- finish drawing before the next frame swap.
  cpu_clk <= clk_div(3);
  -- show shape, speed and last keycode on the seven seg display as a compact
  -- live status readout.
  display_bus_s <= io_shape_s(3 downto 0) & io_speed_s(3 downto 0) & io_keycode_s(7 downto 0);

  input_inst : entity work.input_controller
    port map (
      clk        => CLK100MHZ,
      reset      => btnC,
      btnU       => btnU,
      btnL       => btnL,
      btnR       => btnR,
      btnD       => btnD,
      sw         => sw,
      ps2_clk    => PS2Clk,
      ps2_data   => PS2Data,
      shape_word => io_shape_s,
      color_word => io_color_s,
      speed_word => io_speed_s,
      keycode_word => io_keycode_s
    );

  cpu_inst : entity work.gfx16_cpu
    generic map (
      -- PC_RESET matches the data section size in spinning_cube.asm.
      -- This keeps execution starting at the first instruction word.
      PC_RESET => 398
    )
    port map (
      clk        => cpu_clk,
      reset      => btnC,
      io_shape   => io_shape_s,
      io_color   => io_color_s,
      io_speed   => io_speed_s,
      io_keycode => io_keycode_s,
      io_leds    => cpu_leds_s,
      plot_en    => plot_en_s,
      clr_en     => clr_en_s,
      plot_x     => plot_x_s,
      plot_y     => plot_y_s,
      plot_color => plot_color_s
    );

  framebuffer_inst : entity work.framebuffer
    port map (
      cpu_clk    => cpu_clk,
      vga_clk    => clk_25,
      we         => plot_en_s,
      clr        => clr_en_s,
      px         => plot_x_s,
      py         => plot_y_s,
      frame_tick => frame_tick_s,
      color_in   => plot_color_s,
      rx         => fb_x_s,
      ry         => fb_y_s,
      color_out  => fb_color_s
    );

  vga_inst : entity work.vga_driver
    port map (
      clk_25mhz => clk_25,
      fb_x      => fb_x_s,
      fb_y      => fb_y_s,
      frame_tick => frame_tick_s,
      color_in  => fb_color_s(15 downto 4),
      vga_hs    => Hsync,
      vga_vs    => Vsync,
      vga_r     => vgaRed,
      vga_g     => vgaGreen,
      vga_b     => vgaBlue
    );

  display_inst : entity work.display_hex
    port map (
      clk     => CLK100MHZ,
      x       => display_bus_s,
      seg     => seg,
      an      => an,
      dp      => dp,
      LED     => open,
      clk_div => open
    );

  LED <= cpu_leds_s;
end architecture;