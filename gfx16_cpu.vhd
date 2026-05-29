-- gfx16_cpu.vhd: top-level entity for the GFX16 CPU, implementing its simple single-cycle architecture
-- with a custom instruction set and memory-mapped IO for the board controls, LEDs, and framebuffer plotting.
-- Adapted from ic_15_build_mips_1/mips.vhd and ic_15_build_mips_1/mips_datapath.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity gfx16_cpu is
  generic (
    PC_RESET : integer := 41;
    MEM_FILE : string := "memfile.mem"
  );
  port (
    clk        : in  STD_LOGIC;
    reset      : in  STD_LOGIC;
    io_shape   : in  STD_LOGIC_VECTOR(15 downto 0);
    io_color   : in  STD_LOGIC_VECTOR(15 downto 0);
    io_speed   : in  STD_LOGIC_VECTOR(15 downto 0);
    io_keycode : in  STD_LOGIC_VECTOR(15 downto 0);
    io_leds    : out STD_LOGIC_VECTOR(15 downto 0);
    -- plot_en/clr_en and the coordinate and color outputs expose the framebuffer-write instructions
    -- directly as ports so the framebuffer module can sit outside the CPU.
    plot_en    : out STD_LOGIC;
    clr_en     : out STD_LOGIC;
    plot_x     : out STD_LOGIC_VECTOR(7 downto 0);
    plot_y     : out STD_LOGIC_VECTOR(6 downto 0);
    plot_color : out STD_LOGIC_VECTOR(15 downto 0)
  );
end entity;

architecture rtl of gfx16_cpu is
  -- this is the single cycle core for the fp3 demo.
  -- it keeps the datapath simple, then layers in just enough io glue
  -- for the board controls, leds, and framebuffer plot path.
  signal pc, pc_next, pc_plus_1 : unsigned(9 downto 0) := to_unsigned(PC_RESET, 10);

  signal instr : STD_LOGIC_VECTOR(15 downto 0);
  signal mem_data_raw : STD_LOGIC_VECTOR(15 downto 0);

  signal opcode : STD_LOGIC_VECTOR(3 downto 0);
  signal rd_addr, rs_addr : STD_LOGIC_VECTOR(2 downto 0);
  signal imm8 : STD_LOGIC_VECTOR(7 downto 0);
  signal offset6 : STD_LOGIC_VECTOR(5 downto 0);
  signal offset12 : STD_LOGIC_VECTOR(11 downto 0);

  signal reg_write, mem_read, mem_write, alu_src, reg_dst, mem_to_reg : STD_LOGIC;
  signal branch_eq, branch_lt, jump, plot, clr : STD_LOGIC;
  signal alu_op : STD_LOGIC_VECTOR(3 downto 0);

  signal reg_d_data, reg_s_data : STD_LOGIC_VECTOR(15 downto 0);
  signal wb_data : STD_LOGIC_VECTOR(15 downto 0);
  signal alu_b : STD_LOGIC_VECTOR(15 downto 0);
  signal alu_result : STD_LOGIC_VECTOR(15 downto 0);
  signal alu_zero, alu_lt : STD_LOGIC;

  signal imm8_zext : unsigned(15 downto 0);
  signal off6_sext : signed(9 downto 0);
  signal off12_sext : signed(9 downto 0);
  signal branch_taken : STD_LOGIC;
  signal r7_color_s : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
  signal data_addr_s : unsigned(9 downto 0);
  signal store_addr_s : unsigned(9 downto 0);
  signal load_data_s : STD_LOGIC_VECTOR(15 downto 0);
  signal io_leds_s : STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
  signal mem_we_s : STD_LOGIC;
  signal plot_x_in_range_s : STD_LOGIC;
  signal plot_y_in_range_s : STD_LOGIC;

  -- these addresses are treated as live board inputs and outputs instead of
  -- normal ram locations.
  constant IO_SHAPE_ADDR   : unsigned(9 downto 0) := to_unsigned(240, 10);
  constant IO_COLOR_ADDR   : unsigned(9 downto 0) := to_unsigned(241, 10);
  constant IO_SPEED_ADDR   : unsigned(9 downto 0) := to_unsigned(242, 10);
  constant IO_KEYCODE_ADDR : unsigned(9 downto 0) := to_unsigned(243, 10);
  constant IO_LED_ADDR     : unsigned(9 downto 0) := to_unsigned(244, 10);
begin
  -- breaks the instruction into named fields once so the rest of the core reads
  -- more like the isa description than raw bit slices.
  opcode <= instr(15 downto 12);
  rd_addr <= instr(11 downto 9);
  rs_addr <= instr(8 downto 6);
  imm8 <= instr(7 downto 0);
  offset6 <= instr(5 downto 0);
  offset12 <= instr(11 downto 0);

  imm8_zext <= unsigned(x"00" & imm8);
  off6_sext <= resize(signed(offset6), 10);
  off12_sext <= resize(signed(offset12), 10);

  pc_plus_1 <= pc + 1;
  branch_taken <= (branch_eq and alu_zero) or (branch_lt and alu_lt);
  data_addr_s <= unsigned(reg_s_data(9 downto 0));
  store_addr_s <= unsigned(reg_d_data(9 downto 0));

  -- loads from the io window read board state directly.
  -- stores to the led address are intercepted the same way.
  load_data_s <= io_shape when data_addr_s = IO_SHAPE_ADDR else
                 io_color when data_addr_s = IO_COLOR_ADDR else
                 io_speed when data_addr_s = IO_SPEED_ADDR else
                 io_keycode when data_addr_s = IO_KEYCODE_ADDR else
                 mem_data_raw;
  mem_we_s <= mem_write when store_addr_s /= IO_LED_ADDR else '0';
  plot_x_in_range_s <= '1' when signed(reg_d_data) >= to_signed(0, 16) and signed(reg_d_data) < to_signed(160, 16) else '0';
  plot_y_in_range_s <= '1' when signed(reg_s_data) >= to_signed(0, 16) and signed(reg_s_data) < to_signed(120, 16) else '0';

  -- starts from the normal fallthrough pc then does an override only when the
  -- branch or jump logic says this instruction should redirect control flow.
  process(pc_plus_1, branch_taken, jump, off6_sext, off12_sext)
  begin
    pc_next <= pc_plus_1;

    if branch_taken = '1' then
      pc_next <= unsigned(signed(pc_plus_1) + off6_sext);
    end if;

    if jump = '1' then
      pc_next <= unsigned(signed(pc_plus_1) + off12_sext);
    end if;
  end process;

  -- the explicit state here is small: the pc and the io facing latches.
  -- register writes themselves happen inside the regfile instance.
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        pc <= to_unsigned(PC_RESET, 10);
        r7_color_s <= (others => '0');
        io_leds_s <= (others => '0');
      else
        pc <= pc_next;
        if reg_write = '1' and rd_addr = "111" then
          r7_color_s <= wb_data;
        end if;
        if mem_write = '1' and store_addr_s = IO_LED_ADDR then
          io_leds_s <= reg_s_data;
        end if;
      end if;
    end if;
  end process;

  -- control unit
  ctrl_inst : entity work.control
    port map (
      opcode     => opcode,
      reg_write  => reg_write,
      mem_read   => mem_read,
      mem_write  => mem_write,
      alu_src    => alu_src,
      reg_dst    => reg_dst,
      mem_to_reg => mem_to_reg,
      branch_eq  => branch_eq,
      branch_lt  => branch_lt,
      jump       => jump,
      plot       => plot,
      clr        => clr,
      alu_op     => alu_op
    );
  -- register file
  rf_inst : entity work.regfile
    port map (
      clk => clk,
      we  => reg_write,
      ra1 => rd_addr,
      ra2 => rs_addr,
      wa  => rd_addr,
      wd  => wb_data,
      rd1 => reg_d_data,
      rd2 => reg_s_data
    );
  -- the alu needs to select between the second register file output and the immediate value extended to 16 bits.
  alu_b <= std_logic_vector(imm8_zext) when alu_src = '1' else reg_s_data;

  -- alu
  alu_inst : entity work.alu
    port map (
      a      => reg_d_data,
      b      => alu_b,
      op     => alu_op,
      result => alu_result,
      zero   => alu_zero,
      lt     => alu_lt
    );

  -- unified memory for instructions and data
  -- treats some addresses as special io locations and the rest as normal ram.
  mem_inst : entity work.imem16
    generic map (
      MEM_FILE   => MEM_FILE
    )
    port map (
      clk     => clk,
      a       => std_logic_vector(pc),
      rd      => instr,
      a_data  => reg_s_data(9 downto 0),
      rd_data => mem_data_raw,
      we      => mem_we_s,
      wa      => reg_d_data(9 downto 0),
      wd      => reg_s_data
    );

  wb_data <= load_data_s when mem_to_reg = '1' else alu_result;

  -- plot and clear stay combinational so the framebuffer sees the current
  -- instruction result immediately.
  io_leds <= io_leds_s;
  plot_en <= plot and plot_x_in_range_s and plot_y_in_range_s;
  clr_en <= clr;
  plot_x <= reg_d_data(7 downto 0) when plot_x_in_range_s = '1' else (others => '0');
  plot_y <= reg_s_data(6 downto 0) when plot_y_in_range_s = '1' else (others => '0');
  plot_color <= r7_color_s;
end architecture;