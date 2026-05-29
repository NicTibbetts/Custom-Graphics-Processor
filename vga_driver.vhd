-- vga_driver.vhd: VGA driver for the GFX16 CPU, generating the appropriate sync signals
-- and translating framebuffer coordinates to scan coordinates for a 640x480 display.
-- VGA timing structure and 640x480 constants adapted from the class example ic_34_MIPS_IO/vga_sync.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity vga_driver is
  port (
    clk_25mhz : in  STD_LOGIC;
    -- fb_x/fb_y are framebuffer coordinates (0,0) to (160,119) that the VGA driver
    -- translates from the full 640x480 scan coordinates.
    fb_x      : out STD_LOGIC_VECTOR(7 downto 0);
    fb_y      : out STD_LOGIC_VECTOR(6 downto 0);
    -- frame_tick is for timing the CPU's frame updates to the monitor's vertical refresh.
    -- color_in is the 12-bit RGB color output from the framebuffer, which the VGA driver
    -- expands to 4 bits per channel and blanks to black outside the active video region.
    frame_tick : out STD_LOGIC;
    color_in  : in  STD_LOGIC_VECTOR(11 downto 0);
    -- RGB outputs are blanked to black outside the active video region,
    -- so the porch and sync intervals stay black.
    vga_hs    : out STD_LOGIC;
    vga_vs    : out STD_LOGIC;
    -- RGB outputs are 4 bits each, driven by the framebuffer color output.
    vga_r     : out STD_LOGIC_VECTOR(3 downto 0);
    vga_g     : out STD_LOGIC_VECTOR(3 downto 0);
    vga_b     : out STD_LOGIC_VECTOR(3 downto 0)
  );
end entity;

architecture rtl of vga_driver is
  -- the monitor still sees a normal 640x480 timing model.
  -- the framebuffer is only 160x120, so each of the framebuffer pixel expands to a
  -- 4x4 block on screen.
  -- Timing constants names from class example:
  -- HD=640, HF=16, HR=96, HB=48, VD=480, VF=10, VR=2, VB=33
  -- - Ours are easier to understand
  constant H_VISIBLE : integer := 640;
  constant H_FRONT : integer := 16;
  constant H_SYNC_PULSE : integer := 96;
  constant H_BACK : integer := 48;
  constant H_TOTAL : integer := H_VISIBLE + H_FRONT + H_SYNC_PULSE + H_BACK;

  constant V_VISIBLE : integer := 480;
  constant V_FRONT : integer := 10;
  constant V_SYNC_PULSE : integer := 2;
  constant V_BACK : integer := 33;
  constant V_TOTAL : integer := V_VISIBLE + V_FRONT + V_SYNC_PULSE + V_BACK;

  -- single clocked process updates the counters directly
  signal h_ctr : integer range 0 to H_TOTAL - 1 := 0;
  signal v_ctr : integer range 0 to V_TOTAL - 1 := 0;

  signal active_video : STD_LOGIC;
  -- Range includes 160 so the +2 prefetch offset still fits at the right edge.
  signal fb_x_i : integer range 0 to 160 := 0;
  signal fb_y_i : integer range 0 to 119 := 0;
begin
  -- generate the standard horizontal and vertical scan counters.
  process(clk_25mhz)
  begin
    if rising_edge(clk_25mhz) then
      if h_ctr = H_TOTAL - 1 then
        h_ctr <= 0;
        if v_ctr = V_TOTAL - 1 then
          v_ctr <= 0;
        else
          v_ctr <= v_ctr + 1;
        end if;
      else
        h_ctr <= h_ctr + 1;
      end if;
    end if;
  end process;

  active_video <= '1' when (h_ctr < H_VISIBLE and v_ctr < V_VISIBLE) else '0';

  -- sync is active-low ('0' during the sync pulse)
  vga_hs <= '0' when (h_ctr >= (H_VISIBLE + H_FRONT) and h_ctr < (H_VISIBLE + H_FRONT + H_SYNC_PULSE)) else '1';
  vga_vs <= '0' when (v_ctr >= (V_VISIBLE + V_FRONT) and v_ctr < (V_VISIBLE + V_FRONT + V_SYNC_PULSE)) else '1';

  -- translate visible scan coordinates back into framebuffer coordinates.
  process(active_video, h_ctr, v_ctr)
  begin
    if active_video = '1' then
      -- +2 accounts for the framebuffer read latency (2 cycles total).
      -- This keeps pixel data aligned with the current screen column.
      fb_x_i <= (h_ctr + 2) / 4;
      fb_y_i <= v_ctr / 4;
    else
      fb_x_i <= 0;
      fb_y_i <= 0;
    end if;
  end process;

  fb_x <= std_logic_vector(to_unsigned(fb_x_i, 8));
  fb_y <= std_logic_vector(to_unsigned(fb_y_i, 7));
  -- frame_tick fires once per frame at the first pixel of the vertical front porch
  frame_tick <= '1' when (h_ctr = 0 and v_ctr = V_VISIBLE) else '0';

  -- blank the rgb outputs outside active video so the porch and sync intervals stay black.
  process(active_video, color_in)
  begin
    if active_video = '1' then
      vga_r <= color_in(11 downto 8);
      vga_g <= color_in(7 downto 4);
      vga_b <= color_in(3 downto 0);
    else
      vga_r <= (others => '0');
      vga_g <= (others => '0');
      vga_b <= (others => '0');
    end if;
  end process;
end architecture;