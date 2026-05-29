-- imem16_from_file.vhd: instruction memory for the GFX16 CPU, initialized from a hex (.mem) file at initialization time
-- Adapted from ic_15_build_mips_1/mips_mem.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;
use STD.TEXTIO.all;

entity imem16 is
  generic (
    MEM_FILE   : string := "memfile.mem"
  );
  port (
    clk     : in  STD_LOGIC;
    a       : in  STD_LOGIC_VECTOR(9 downto 0);
    rd      : out STD_LOGIC_VECTOR(15 downto 0);
    -- second read port (a_data/rd_data) and write port
    -- (we/wa/wd) so one unified memory serves both data and instructions.
    a_data  : in  STD_LOGIC_VECTOR(9 downto 0);
    rd_data : out STD_LOGIC_VECTOR(15 downto 0);
    we      : in  STD_LOGIC;
    wa      : in  STD_LOGIC_VECTOR(9 downto 0);
    wd      : in  STD_LOGIC_VECTOR(15 downto 0)
  );
end entity;

architecture behave of imem16 is
  constant ADDR_WIDTH : integer := 10;
  constant WORD_WIDTH : integer := 16;
  constant DEPTH : integer := 2 ** ADDR_WIDTH;
  subtype word_t is STD_LOGIC_VECTOR(WORD_WIDTH-1 downto 0);
  type ramtype is array (0 to DEPTH-1) of word_t;

  -- vivado evaluates this at elaboration time to prefill the ram.
  -- each nonblank line is treated as one 16 bit hex word.
  impure function InitRamFromFile(RamFileName : in string) return ramtype is
    file mem_file : TEXT open read_mode is RamFileName;
    variable ch : character;
    variable L : line;
    variable RAM : ramtype;
    variable idx : integer := 0;
    variable result : integer;
  begin
    for i in 0 to DEPTH-1 loop
      RAM(i) := (others => '0');
    end loop;

    while not endfile(mem_file) loop
      readline(mem_file, L);

      if L'length >= 4 then
        result := 0;
        for i in 1 to 4 loop
          read(L, ch);
          if '0' <= ch and ch <= '9' then
            result := result*16 + character'pos(ch) - character'pos('0');
          elsif 'a' <= ch and ch <= 'f' then
            result := result*16 + character'pos(ch) - character'pos('a') + 10;
          elsif 'A' <= ch and ch <= 'F' then
            result := result*16 + character'pos(ch) - character'pos('A') + 10;
          else
            report "format error in " & RamFileName & " at instruction index " & integer'image(idx)
              severity error;
          end if;
        end loop;

        if idx < DEPTH then
          RAM(idx) := std_logic_vector(to_unsigned(result, 16));
          idx := idx + 1;
        else
          report "Instruction memory overflow while loading " & RamFileName severity warning;
          exit;
        end if;
      end if;
    end loop;

    return RAM;
  end function;

  signal mem : ramtype := InitRamFromFile(MEM_FILE);
begin
  -- instruction fetch and data reads stay asynchronous so the single cycle cpu
  -- does not need an some extra wait state
  rd <= mem(to_integer(unsigned(a)));
  rd_data <= mem(to_integer(unsigned(a_data)));

  -- writes still happen on the clock edge so normal store operations behave like ram
  process(clk)
  begin
    if rising_edge(clk) then
      if we = '1' then
        mem(to_integer(unsigned(wa))) <= wd;
      end if;
    end if;
  end process;
end architecture;