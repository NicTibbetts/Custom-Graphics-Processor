-- framebuffer.vhd
-- Stores the color of every pixel on screen so the CPU can build a frame independently of what the VGA controller is currently displaying.
--
-- The assembly code now explicitly clears the back page before drawing each frame,
-- with a loop writing 0x0000 to all 19,200 pixels (x: 0–159, y: 0–119) after each clr.
--
-- Memory Limit Workaround for Basys 3:
-- A full 640x480 frame at 16-bit color needs ~4.7 Mb per page, which is far beyond the Basys 3's 1.8 Mb of Block RAM.
-- This design runs at 160x120 (quarter resolution), which needs only ~300 Kb per page.
-- The VGA driver scales each framebuffer pixel up to a 4x4 block of screen pixels, so the output still fills the full display.
--
-- Double Buffering:
-- Two pages of memory (page 0 and page 1) keep the display tear-free. One page is the "front" (VGA is reading it)
-- while the CPU draws into the other "back" page. When the CPU finishes a frame it asserts clr to request a page flip;
-- the pages swap at the next vertical blanking interval (frame_tick).
-- References (double-buffer structure and vsync-gated swap):
--   https://projectf.io/posts/animated-shapes/
--   https://github.com/projf/projf-explore/tree/main/graphics/animated-shapes
-- Reference (basic BRAM write port + VGA read port structure):
--   https://github.com/fcayci/xilinx_vga_framebuffer_ip_core
--
-- Clock Domain Crossing (CDC):
-- The CPU (cpu_clk) and VGA controller (vga_clk) run on independent clocks. Signals crossing between domains use 2-flip-flop
-- synchronizer chains to prevent metastability. The flip request uses a toggle signal so it is never missed regardless of clock speed ratios.
-- Reference (2-FF synchronizer and clock domain crossing):
--   https://nandland.com/lesson-14-crossing-clock-domains/
-- Reference (toggle-based CDC for pulses of unknown clock ratio):
--   https://fpgacpu.ca/fpga/CDC_Pulse_Synchronizer_2phase.html

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity framebuffer is
  port (
    -- CPU and VGA clocks (independent)
    cpu_clk    : in  STD_LOGIC;  -- CPU clock; all writes are synchronised to this
    vga_clk    : in  STD_LOGIC;  -- 25 MHz VGA pixel clock; reads are synchronised to this
    -- write enable and page flip signal
    we         : in  STD_LOGIC;  -- write enable: write color_in at (px, py) on the back page
    clr        : in  STD_LOGIC;  -- page-flip request: CPU finished drawing; swap pages
    -- CPU write coordinates
    px         : in  STD_LOGIC_VECTOR(7 downto 0);  -- write X coordinate (0-159)
    py         : in  STD_LOGIC_VECTOR(6 downto 0);  -- write Y coordinate (0-119)
    -- frame tick and color input
    frame_tick : in  STD_LOGIC;  -- single-cycle pulse from VGA at start of vertical blanking (the gap between frames)
    color_in   : in  STD_LOGIC_VECTOR(15 downto 0); -- 16-bit RGB color from CPU to write
    -- VGA read coordinates
    rx         : in  STD_LOGIC_VECTOR(7 downto 0);
    ry         : in  STD_LOGIC_VECTOR(6 downto 0);
    -- color at (rx, ry); valid one cycle after rx/ry
    color_out  : out STD_LOGIC_VECTOR(15 downto 0)
  );
end entity;

architecture rtl of framebuffer is
  constant FB_WIDTH  : integer := 160; -- quarter of 640 for memory savings; VGA driver scales each pixel to 4x4 block
  constant FB_HEIGHT : integer := 120; -- quarter of 480 for memory savings; ^^
  constant FB_SIZE   : integer := FB_WIDTH * FB_HEIGHT; -- 19200 pixels per page

  -- 1D pixel arrays; synthesis infers Block RAM from this pattern.
  -- Each array holds one full page of 16-bit color values in row-major order.
  type fb_ram_t is array (0 to FB_SIZE - 1) of STD_LOGIC_VECTOR(15 downto 0);
  signal fb_page_0 : fb_ram_t := (others => (others => '0'));
  signal fb_page_1 : fb_ram_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of fb_page_0 : signal is "block";
  attribute ram_style of fb_page_1 : signal is "block";

  -- front_page: which page VGA is reading ('0'=page 0, '1'=page 1). VGA domain.
  signal front_page : STD_LOGIC := '0';
  -- write_page: which page the CPU is writing (always the back page). CPU domain.
  signal write_page : STD_LOGIC := '1';
  -- ^^ Reference (front/back page selection via a single flag): https://projectf.io/posts/animated-shapes/

  -- Toggle-based CDC: flip this bit each time the CPU requests a page swap.
  -- A toggle is used instead of a pulse so the VGA domain never misses the request.
  signal swap_req_toggle_cpu : STD_LOGIC := '0';
  -- Which page the CPU wants to make the new front page (set when clr fires).
  signal swap_target_cpu     : STD_LOGIC := '0';

  -- 2-FF (flip-flop) synchronizer for swap_req_toggle_cpu -> VGA domain.
  signal swap_req_meta_vga  : STD_LOGIC := '0';
  signal swap_req_sync_vga  : STD_LOGIC := '0';
  signal swap_req_prev_vga  : STD_LOGIC := '0';  -- previous cycle value for edge detection
  signal swap_pending_vga   : STD_LOGIC := '0';  -- '1' when a flip is waiting for frame_tick

  -- 2-FF (flip-flop) synchronizer for swap_target_cpu -> VGA domain.
  signal swap_target_meta_vga : STD_LOGIC := '0';
  signal swap_target_sync_vga : STD_LOGIC := '0';

  signal frame_tick_prev_vga : STD_LOGIC := '0';  -- previous frame_tick for rising-edge detection

  -- BRAM read outputs (one-cycle latency: result appears the cycle after the address is applied).
  signal page_0_read_s : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
  signal page_1_read_s : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');

  -- Convert (x, y) to a flat 1D array index (row-major order).
  function fb_addr(x : integer; y : integer) return integer is
  begin
    return (y * FB_WIDTH) + x;
  end function;

begin

  -- CPU WRITE PROCESS
  -- clr=1: request page flip (priority over we). we=1: write color_in at (px, py). On clr: record which page to flip to, toggle the swap request signal (CDC toggle pattern),
  -- and switch write_page to the other buffer immediately so the CPU can start drawing the next frame without waiting for the VGA-side flip to complete.
  process(cpu_clk)
    variable px_i : integer;
    variable py_i : integer;
    variable idx  : integer;
  begin
    if rising_edge(cpu_clk) then
      if clr = '1' then
        swap_target_cpu     <= write_page;
        swap_req_toggle_cpu <= not swap_req_toggle_cpu; -- toggle signals the VGA domain
        write_page          <= not write_page;
      elsif we = '1' then
        px_i := to_integer(unsigned(px));
        py_i := to_integer(unsigned(py));
        if px_i < FB_WIDTH and py_i < FB_HEIGHT then
          idx := fb_addr(px_i, py_i);
          if write_page = '0' then
            fb_page_0(idx) <= color_in;
          else
            fb_page_1(idx) <= color_in;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- VGA READ PROCESS
  -- Each cycle: (1) output the color read last cycle, (2) issue the next BRAM read,
  -- (3) synchronize the CPU flip request and perform the swap at frame_tick. Steps 1 and 2 are offset by one cycle due to BRAM read latency.
  process(vga_clk)
    variable rx_i : integer;
    variable ry_i : integer;
    variable idx  : integer;
  begin
    if rising_edge(vga_clk) then

      -- STEP 1: Output the color that BRAM returned for last cycle's address.
      if front_page = '0' then
        color_out <= page_0_read_s;
      else
        color_out <= page_1_read_s;
      end if;

      -- STEP 2: Apply the new read address; result will be ready next cycle.
      rx_i := to_integer(unsigned(rx));
      ry_i := to_integer(unsigned(ry));
      if rx_i < FB_WIDTH and ry_i < FB_HEIGHT then
        idx := fb_addr(rx_i, ry_i);
        page_0_read_s <= fb_page_0(idx);
        page_1_read_s <= fb_page_1(idx);
      else
        -- Outside framebuffer (blanking region): output black next cycle.
        page_0_read_s <= (others => '0');
        page_1_read_s <= (others => '0');
      end if;

      -- STEP 3: 2-FF (flip-flop) synchronizer - bring the CPU toggle into the VGA domain.
      swap_req_meta_vga    <= swap_req_toggle_cpu;
      swap_req_sync_vga    <= swap_req_meta_vga;
      swap_target_meta_vga <= swap_target_cpu;
      swap_target_sync_vga <= swap_target_meta_vga;
      -- ^^ Reference: https://nandland.com/lesson-14-crossing-clock-domains/

      -- Edge detection: any change in the synced toggle means a new flip was requested.
      if swap_req_sync_vga /= swap_req_prev_vga then
        swap_pending_vga <= '1';
      end if;
      swap_req_prev_vga <= swap_req_sync_vga;
      -- ^^ Reference (toggle edge detection pattern): https://fpgacpu.ca/fpga/CDC_Pulse_Synchronizer_2phase.html

      -- Perform the flip on the rising edge of frame_tick (vertical blanking interval). Waiting for frame_tick ensures the swap is tear-free.
      if frame_tick = '1' and frame_tick_prev_vga = '0' and swap_pending_vga = '1' then
        front_page       <= swap_target_sync_vga;
        swap_pending_vga <= '0';
      end if;
      -- ^^ Reference (vsync-gated swap): https://projectf.io/posts/animated-shapes/

      frame_tick_prev_vga <= frame_tick;
    end if;
  end process;
end architecture;