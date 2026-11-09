-- Receptor UART 8N1. CLKS_PER_BIT = f_clk / baud (50 MHz / 1 Mbaud = 50, divisao exata).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity uart_rx is
  generic (CLKS_PER_BIT : positive := 50);
  port (
    clk, rst : in  std_logic;
    rx       : in  std_logic;  -- ja sincronizado
    data     : out std_logic_vector(7 downto 0);
    valid    : out std_logic   -- pulso de 1 ciclo
  );
end entity;

architecture rtl of uart_rx is
  type st_t is (IDLE, START, BITS, STOP);
  signal st   : st_t := IDLE;
  signal cnt  : natural range 0 to CLKS_PER_BIT - 1 := 0;
  signal nbit : natural range 0 to 7 := 0;
  signal sh   : std_logic_vector(7 downto 0) := (others => '0');
begin
  data <= sh;

  process (clk)
  begin
    if rising_edge(clk) then
      valid <= '0';
      if rst = '1' then
        st <= IDLE;
      else
        case st is
          when IDLE =>
            cnt <= 0;
            if rx = '0' then st <= START; end if;
          when START =>  -- confere o meio do start bit
            if cnt = CLKS_PER_BIT / 2 then
              cnt <= 0; nbit <= 0;
              if rx = '0' then st <= BITS; else st <= IDLE; end if;
            else
              cnt <= cnt + 1;
            end if;
          when BITS =>
            if cnt = CLKS_PER_BIT - 1 then
              cnt <= 0;
              sh  <= rx & sh(7 downto 1);  -- LSB primeiro
              if nbit = 7 then st <= STOP; else nbit <= nbit + 1; end if;
            else
              cnt <= cnt + 1;
            end if;
          when STOP =>
            if cnt = CLKS_PER_BIT - 1 then
              st <= IDLE;
              valid <= rx;  -- descarta byte com erro de framing
            else
              cnt <= cnt + 1;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
