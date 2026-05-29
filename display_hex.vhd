-- display_hex.vhd: drives the 4-digit 7-segment display on the board, showing a 16-bit input as 4 hex digits
-- Adapted from ic_15_build_mips_1/display_hex.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity display_hex is
  port (
    clk     : in  STD_LOGIC;
    x       : in  STD_LOGIC_VECTOR(15 downto 0);
    seg     : out STD_LOGIC_VECTOR(6 downto 0);
    an      : out STD_LOGIC_VECTOR(3 downto 0);
    dp      : out STD_LOGIC;
    LED     : out STD_LOGIC_VECTOR(3 downto 0);
    clk_div : out STD_LOGIC_VECTOR(28 downto 0)
  );
end entity;

architecture behave of display_hex is
  -- this is just a debug display helper.
  -- it scans four hex digits fast enough that the board looks steady even
  -- though only one digit is active at a time.
  function hex_to_7seg(d : STD_LOGIC_VECTOR(3 downto 0)) return STD_LOGIC_VECTOR is
  begin
    case d is
      when X"0" => return "1000000";
      when X"1" => return "1111001";
      when X"2" => return "0100100";
      when X"3" => return "0110000";
      when X"4" => return "0011001";
      when X"5" => return "0010010";
      when X"6" => return "0000010";
      when X"7" => return "1011000";
      when X"8" => return "0000000";
      when X"9" => return "0010000";
      when X"A" => return "0001000";
      when X"B" => return "0000011";
      when X"C" => return "1000110";
      when X"D" => return "0100001";
      when X"E" => return "0000110";
      when others => return "0001110";
    end case;
  end function;

  signal clkdiv_s : STD_LOGIC_VECTOR(28 downto 0) := (others => '0');
  signal s : STD_LOGIC_VECTOR(1 downto 0);
  signal digit : STD_LOGIC_VECTOR(3 downto 0);
begin
  process(clk)
  begin
    if rising_edge(clk) then
      clkdiv_s <= std_logic_vector(unsigned(clkdiv_s) + 1);
    end if;
  end process;

  s <= clkdiv_s(16 downto 15);

  -- picks the nibble that belongs on the currently active digit.
  process(x, s)
  begin
    case s is
      when "00" => digit <= x(3 downto 0);
      when "01" => digit <= x(7 downto 4);
      when "10" => digit <= x(11 downto 8);
      when others => digit <= x(15 downto 12);
    end case;
  end process;

  -- drives one anode low at a time to multiplex the four physical digits.
  process(s)
  begin
    case s is
      when "00" => an <= "1110";
      when "01" => an <= "1101";
      when "10" => an <= "1011";
      when others => an <= "0111";
    end case;
  end process;

  seg <= hex_to_7seg(digit);
  dp <= '1';
  LED <= digit;
  clk_div <= clkdiv_s;
end architecture;