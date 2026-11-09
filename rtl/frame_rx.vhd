-- Montagem de quadros: 0xFF | 784 pixels (0..127, linha a linha) | checksum (XOR dos pixels).
-- 0xFF nunca aparece nos dados, entao qualquer 0xFF ressincroniza na hora.
-- Buffer ping-pong (2 x 784 bytes em M9K): a UART escreve num banco enquanto a CNN le o outro.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity frame_rx is
  port (
    clk, rst   : in  std_logic;
    rx_data    : in  std_logic_vector(7 downto 0);
    rx_valid   : in  std_logic;
    cnn_busy   : in  std_logic;
    rd_addr    : in  unsigned(9 downto 0);          -- pixel 0..783 do quadro pronto
    rd_data    : out std_logic_vector(7 downto 0);  -- latencia de 1 ciclo
    start      : out std_logic;                     -- pulso: quadro valido entregue a CNN
    frame_ok   : out std_logic;                     -- pulso: checksum OK (mesmo se CNN ocupada)
    frame_bad  : out std_logic;                     -- pulso: checksum errado (depuracao)
    dbg_addr   : in  unsigned(9 downto 0);          -- depuracao: le o mesmo quadro que a CNN recebeu
    dbg_data   : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of frame_rx is
  type ram_t is array (0 to 2047) of std_logic_vector(7 downto 0);
  signal ram    : ram_t;
  signal wbank  : std_logic := '0';
  signal active : std_logic := '0';
  signal idx    : unsigned(9 downto 0) := (others => '0');
  signal csum   : std_logic_vector(6 downto 0) := (others => '0');
  signal we     : std_logic;
begin
  we <= '1' when rx_valid = '1' and active = '1' and rx_data(7) = '0' and idx < 784 else '0';

  ram_p : process (clk)
  begin
    if rising_edge(clk) then
      if we = '1' then
        ram(to_integer(wbank & idx)) <= rx_data;
      end if;
      rd_data <= ram(to_integer(not wbank & rd_addr));
      dbg_data <= ram(to_integer(not wbank & dbg_addr));
    end if;
  end process;

  ctrl_p : process (clk)
  begin
    if rising_edge(clk) then
      start <= '0'; frame_ok <= '0'; frame_bad <= '0';
      if rst = '1' then
        active <= '0'; wbank <= '0';
      elsif rx_valid = '1' then
        if rx_data = x"FF" then
          active <= '1'; idx <= (others => '0'); csum <= (others => '0');
        elsif active = '1' then
          if rx_data(7) = '1' then
            active <= '0';                       -- lixo: espera o proximo 0xFF
          elsif idx < 784 then
            idx  <= idx + 1;
            csum <= csum xor rx_data(6 downto 0);
          else
            active <= '0';
            if rx_data(6 downto 0) = csum then
              frame_ok <= '1';
              if cnn_busy = '0' then             -- CNN ocupada: quadro descartado
                start <= '1'; wbank <= not wbank;
              end if;
            else
              frame_bad <= '1';
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
