-- Depuracao pelo cabo USB-Blaster (JTAG), sem pinos extras: In-System Sources and Probes da Intel.
-- O PC (tools/jtag_monitor.tcl) escreve um endereco de pixel na "source" e le a "probe":
--   probe( 7: 0) pixel [addr] do ultimo quadro entregue a CNN
--   probe(11: 8) digito da ultima inferencia     probe(15:12) digito no HEX0 (apos o estabilizador)
--   probe(31:16) quadros com checksum OK         probe(47:32) quadros com checksum errado
--   probe(63:48) bytes recebidos pela UART       probe(79:64) inferencias concluidas
-- Contadores de 16 bits dao a volta; o PC olha as diferencas.
-- Na simulacao o altsource_probe fica sem modelo (componente sem ligacao): so a parte de depuracao nao e simulada.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity jtag_debug is
  port (
    clk, rst   : in  std_logic;
    rx_valid, frame_ok, frame_bad, done : in std_logic;
    digit, shown : in unsigned(3 downto 0);
    pixel      : in  std_logic_vector(7 downto 0);
    pix_addr   : out unsigned(9 downto 0)
  );
end entity;

architecture rtl of jtag_debug is
  component altsource_probe
    generic (
      sld_auto_instance_index : string := "YES"; sld_instance_index : natural := 0;
      instance_id : string := "NONE"; probe_width : natural := 1; source_width : natural := 1;
      source_initial_value : string := "0"; enable_metastability : string := "NO";
      lpm_type : string := "altsource_probe");
    port (
      probe      : in  std_logic_vector(probe_width - 1 downto 0);
      source     : out std_logic_vector(source_width - 1 downto 0);
      source_clk : in  std_logic := '0');
  end component;

  signal n_bytes, n_ok, n_bad, n_done : unsigned(15 downto 0) := (others => '0');
  signal probe  : std_logic_vector(79 downto 0);
  signal source : std_logic_vector(9 downto 0);
begin
  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        n_bytes <= (others => '0'); n_ok <= (others => '0'); n_bad <= (others => '0'); n_done <= (others => '0');
      else
        if rx_valid = '1' then n_bytes <= n_bytes + 1; end if;
        if frame_ok = '1' then n_ok <= n_ok + 1; end if;
        if frame_bad = '1' then n_bad <= n_bad + 1; end if;
        if done = '1' then n_done <= n_done + 1; end if;
      end if;
    end if;
  end process;

  probe <= std_logic_vector(n_done) & std_logic_vector(n_bytes) & std_logic_vector(n_bad) & std_logic_vector(n_ok)
           & std_logic_vector(shown) & std_logic_vector(digit) & pixel;
  pix_addr <= unsigned(source);

  u_issp : altsource_probe
    generic map (instance_id => "CNN", probe_width => 80, source_width => 10, enable_metastability => "YES")
    port map (probe => probe, source => source, source_clk => clk);
end architecture;
