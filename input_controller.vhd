-- input_controller.vhd: takes the raw inputs from buttons, switches, and the keyboard.
-- turns them into four simple words for the CPU to read: shape, color, speed, and last keycode.
-- this keeps the CPU code clean and simple since it does not have to care about where the inputs came from or do any debouncing itself.

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity input_controller is
  port (
    clk          : in  STD_LOGIC;
    reset        : in  STD_LOGIC;
    btnU         : in  STD_LOGIC;
    btnL         : in  STD_LOGIC;
    btnR         : in  STD_LOGIC;
    btnD         : in  STD_LOGIC;
    sw           : in  STD_LOGIC_VECTOR(15 downto 0);
    ps2_clk      : in  STD_LOGIC;
    ps2_data     : in  STD_LOGIC;
    shape_word   : out STD_LOGIC_VECTOR(15 downto 0);
    color_word   : out STD_LOGIC_VECTOR(15 downto 0);
    speed_word   : out STD_LOGIC_VECTOR(15 downto 0);
    keycode_word : out STD_LOGIC_VECTOR(15 downto 0)
  );
end entity;

architecture rtl of input_controller is
  -- this block turns buttons, switches, and the keyboard into four simple
  -- memory mapped words so the cpu does not have to care where input came from.
  -- it just reads shape, color, speed, and last keycode.

  -- keep a small fallback palette for demos when the raw color switches are off.
  function palette_color(index : unsigned(2 downto 0)) return STD_LOGIC_VECTOR is
  begin
    case to_integer(index) is
      when 0 => return x"F000";
      when 1 => return x"0F00";
      when 2 => return x"00F0";
      when 3 => return x"FF00";
      when 4 => return x"0FF0";
      when 5 => return x"F0F0";
      when 6 => return x"FFF0";
      when others => return x"8880";
    end case;
  end function;

  signal btnU_db_s : STD_LOGIC;
  signal btnL_db_s : STD_LOGIC;
  signal btnR_db_s : STD_LOGIC;
  signal btnD_db_s : STD_LOGIC;
  signal btnU_prev_s : STD_LOGIC := '0';
  signal btnL_prev_s : STD_LOGIC := '0';
  signal btnR_prev_s : STD_LOGIC := '0';
  signal btnD_prev_s : STD_LOGIC := '0';

  signal ps2_code_new_s : STD_LOGIC;
  signal ps2_code_s : STD_LOGIC_VECTOR(7 downto 0);

  signal shape_sel_s : unsigned(1 downto 0) := (others => '0');
  signal speed_sel_s : unsigned(3 downto 0) := "0100";
  signal palette_idx_s : unsigned(2 downto 0) := (others => '0');
  signal last_keycode_s : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
  signal break_pending_s : STD_LOGIC := '0';
  signal extended_pending_s : STD_LOGIC := '0';
begin
  -- debounce first, then do edge detection. that keeps one physical press from
  -- turning into several shape or speed changes.
  debounce_btnU : entity work.debounce
    generic map (
      counter_size => 18
    )
    port map (
      clk    => clk,
      button => btnU,
      result => btnU_db_s
    );

  debounce_btnL : entity work.debounce
    generic map (
      counter_size => 18
    )
    port map (
      clk    => clk,
      button => btnL,
      result => btnL_db_s
    );

  debounce_btnR : entity work.debounce
    generic map (
      counter_size => 18
    )
    port map (
      clk    => clk,
      button => btnR,
      result => btnR_db_s
    );

  debounce_btnD : entity work.debounce
    generic map (
      counter_size => 18
    )
    port map (
      clk    => clk,
      button => btnD,
      result => btnD_db_s
    );

  keyboard_inst : entity work.ps2_keyboard
    generic map (
      clk_freq              => 100_000_000,
      debounce_counter_size => 8
    )
    port map (
      clk          => clk,
      ps2_clk      => ps2_clk,
      ps2_data     => ps2_data,
      ps2_code_new => ps2_code_new_s,
      ps2_code     => ps2_code_s
    );

  -- everything flows through next_* variables first so button and keyboard
  -- updates can be combined cleanly in one clocked block.
  process(clk)
    variable btnU_rise_v : boolean;
    variable btnL_rise_v : boolean;
    variable btnR_rise_v : boolean;
    variable btnD_rise_v : boolean;
    variable next_shape_v : unsigned(1 downto 0);
    variable next_speed_v : unsigned(3 downto 0);
    variable next_palette_v : unsigned(2 downto 0);
    variable next_key_v : STD_LOGIC_VECTOR(7 downto 0);
    variable break_v : STD_LOGIC;
    variable extended_v : STD_LOGIC;
  begin
    if rising_edge(clk) then
      btnU_rise_v := (btnU_db_s = '1' and btnU_prev_s = '0');
      btnL_rise_v := (btnL_db_s = '1' and btnL_prev_s = '0');
      btnR_rise_v := (btnR_db_s = '1' and btnR_prev_s = '0');
      btnD_rise_v := (btnD_db_s = '1' and btnD_prev_s = '0');

      btnU_prev_s <= btnU_db_s;
      btnL_prev_s <= btnL_db_s;
      btnR_prev_s <= btnR_db_s;
      btnD_prev_s <= btnD_db_s;

      if reset = '1' then
        shape_sel_s <= (others => '0');
        speed_sel_s <= "0100";
        palette_idx_s <= (others => '0');
        last_keycode_s <= (others => '0');
        break_pending_s <= '0';
        extended_pending_s <= '0';
      else
        next_shape_v := shape_sel_s;
        next_speed_v := speed_sel_s;
        next_palette_v := palette_idx_s;
        next_key_v := last_keycode_s;
        break_v := break_pending_s;
        extended_v := extended_pending_s;

        if btnL_rise_v then
          next_shape_v := next_shape_v - 1;
        end if;
        if btnR_rise_v then
          next_shape_v := next_shape_v + 1;
        end if;
        if btnU_rise_v then
          next_speed_v := next_speed_v + 1;
        end if;
        if btnD_rise_v then
          next_speed_v := next_speed_v - 1;
        end if;

        if ps2_code_new_s = '1' then
          if ps2_code_s = x"F0" then
            break_v := '1';
          elsif ps2_code_s = x"E0" then
            extended_v := '1';
          elsif break_v = '1' then
            break_v := '0';
            extended_v := '0';
          else
            next_key_v := ps2_code_s;

            -- ignore break codes as actions. only the make code should update
            -- the live demo controls.
            if extended_v = '1' then
              case ps2_code_s is
                when x"6B" => next_shape_v := next_shape_v - 1;
                when x"74" => next_shape_v := next_shape_v + 1;
                when x"75" => next_speed_v := next_speed_v + 1;
                when x"72" => next_speed_v := next_speed_v - 1;
                when others => null;
              end case;
              extended_v := '0';
            else
              case ps2_code_s is
                when x"16" => next_shape_v := to_unsigned(0, next_shape_v'length);
                when x"1E" => next_shape_v := to_unsigned(1, next_shape_v'length);
                when x"26" => next_shape_v := to_unsigned(2, next_shape_v'length);
                when x"25" => next_shape_v := to_unsigned(3, next_shape_v'length);
                when x"15" => next_palette_v := next_palette_v - 1;
                when x"24" => next_palette_v := next_palette_v + 1;
                when x"1D" => next_speed_v := next_speed_v + 1;
                when x"1B" => next_speed_v := next_speed_v - 1;
                when others => null;
              end case;
            end if;
          end if;
        end if;

        shape_sel_s <= next_shape_v;
        speed_sel_s <= next_speed_v;
        palette_idx_s <= next_palette_v;
        last_keycode_s <= next_key_v;
        break_pending_s <= break_v;
        extended_pending_s <= extended_v;
      end if;
    end if;
  end process;

  -- switches win for color whenever any high color bit is set.
  -- otherwise the palette index keeps the demo colorful without extra wiring
  shape_word <= std_logic_vector(to_unsigned(to_integer(shape_sel_s), 16));
  speed_word <= std_logic_vector(to_unsigned(to_integer(speed_sel_s), 16));
  keycode_word <= x"00" & last_keycode_s;
  color_word <= sw(15 downto 4) & "0000" when sw(15 downto 4) /= "000000000000" else palette_color(palette_idx_s);
end architecture;