-- Top-level DE10-Lite: ESP32-CAM (UART 1 Mbaud em GPIO[0]) -> CNN -> HEX0 + LEDR.
--   HEX0     : digito reconhecido ("-" antes do primeiro resultado); pela camera so muda apos
--              STABLE_N inferencias seguidas iguais (evita o display pular com o papel em movimento)
--   HEX0 DP  : alterna a cada quadro recebido com checksum correto (diagnostico do link)
--   LEDR     : one-hot do digito
--   KEY[0]   : reset (ativo em 0)
--   Autoteste: SW[3..0] escolhe uma das 16 imagens MNIST gravadas na FPGA, KEY[1] roda a CNN nela;
--   HEX1 mostra o rotulo correto da imagem escolhida (ver docs/selftest_sw.png), so enquanto o
--   ultimo resultado for do autoteste; com a camera mandando quadros, fica apagado.
--   Depuracao: contadores e a ultima imagem recebida podem ser lidos pelo USB-Blaster (tools/jtag_monitor.tcl).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.selftest_pkg.all;

entity top is
  generic (
    CLKS_PER_BIT : positive := 50;  -- 50 MHz / 1 Mbaud
    STABLE_N     : positive := 3    -- ~0,3 s a ~10 quadros/s
  );
  port (
    MAX10_CLK1_50 : in  std_logic;
    KEY           : in  std_logic_vector(1 downto 0);
    SW            : in  std_logic_vector(3 downto 0);
    GPIO          : in  std_logic_vector(0 downto 0);  -- GPIO[0] = RX (TX da ESP32-CAM)
    HEX0          : out std_logic_vector(7 downto 0);  -- ativo em 0, bit 7 = DP
    HEX1          : out std_logic_vector(7 downto 0);
    LEDR          : out std_logic_vector(9 downto 0)
  );
end entity;

architecture rtl of top is
  signal clk : std_logic;
  signal rst_s, rx_s : std_logic_vector(1 downto 0) := "11";
  signal key1_s : std_logic_vector(2 downto 0) := "111";
  signal sw_s0, sw_s : std_logic_vector(3 downto 0) := (others => '0');
  signal rst : std_logic;
  signal rx_data, img_data, uart_img, self_img : std_logic_vector(7 downto 0);
  signal rx_valid, uart_start, self_start, start, frame_ok, frame_bad, busy, done : std_logic;
  signal dbg_addr : unsigned(9 downto 0);
  signal dbg_fm_addr : unsigned(10 downto 0);
  signal dbg_score_sel : unsigned(3 downto 0);
  signal dbg_data, dbg_fm_q : std_logic_vector(7 downto 0);
  signal dbg_score : signed(31 downto 0);
  signal freeze, rx_busy : std_logic;
  signal src_self : std_logic := '0';
  signal self_sel : unsigned(3 downto 0) := (others => '0');
  signal img_addr : unsigned(9 downto 0);
  signal digit, cand, shown : unsigned(3 downto 0) := (others => '0');
  signal cnt : natural range 0 to STABLE_N := 0;
  signal have, dp : std_logic := '0';
  signal seg, seg1 : std_logic_vector(6 downto 0);
  signal label_sw : unsigned(3 downto 0);
begin
  clk <= MAX10_CLK1_50;

  -- sincronizadores de 2 FF (entradas assincronas)
  process (clk)
  begin
    if rising_edge(clk) then
      rst_s <= rst_s(0) & not KEY(0);
      rx_s  <= rx_s(0) & GPIO(0);
      key1_s <= key1_s(1 downto 0) & KEY(1);
      sw_s0 <= SW; sw_s <= sw_s0;
    end if;
  end process;
  rst <= rst_s(1);

  u_rx : entity work.uart_rx
    generic map (CLKS_PER_BIT => CLKS_PER_BIT)
    port map (clk => clk, rst => rst, rx => rx_s(1), data => rx_data, valid => rx_valid);

  u_frame : entity work.frame_rx
    port map (clk => clk, rst => rst, rx_data => rx_data, rx_valid => rx_valid,
              cnn_busy => rx_busy, rd_addr => img_addr, rd_data => uart_img,
              start => uart_start, frame_ok => frame_ok, frame_bad => frame_bad,
              dbg_addr => dbg_addr, dbg_data => dbg_data);

  u_dbg : entity work.jtag_debug
    port map (clk => clk, rst => rst, rx_valid => rx_valid, frame_ok => frame_ok, frame_bad => frame_bad,
              done => done, digit => digit, shown => shown, pixel => dbg_data, fm_value => dbg_fm_q,
              score => dbg_score, pix_addr => dbg_addr, fm_addr => dbg_fm_addr, score_sel => dbg_score_sel,
              freeze => freeze);
  rx_busy <= busy or freeze;  -- congelado pelo monitor: quadros novos sao descartados

  -- autoteste: borda de descida de KEY[1] (repiques so repetem a mesma inferencia)
  self_start <= key1_s(2) and not key1_s(1) and not busy and not uart_start;
  start <= uart_start or self_start;

  process (clk)
  begin
    if rising_edge(clk) then
      if self_start = '1' then
        src_self <= '1'; self_sel <= unsigned(sw_s);
      elsif uart_start = '1' then
        src_self <= '0';
      end if;
    end if;
  end process;

  u_self : entity work.selftest_rom
    port map (clk => clk, sel => self_sel, addr => img_addr, q => self_img);
  img_data <= self_img when src_self = '1' else uart_img;

  u_cnn : entity work.cnn_core
    port map (clk => clk, rst => rst, start => start, busy => busy,
              img_addr => img_addr, img_data => img_data, done => done, digit => digit,
              dbg_fm_addr => dbg_fm_addr, dbg_fm_q => dbg_fm_q, dbg_score_sel => dbg_score_sel, dbg_score => dbg_score);

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        have <= '0'; dp <= '0'; cnt <= 0;
      else
        if done = '1' then
          if src_self = '1' then           -- autoteste: mostra na hora
            shown <= digit; have <= '1'; cnt <= 0;
          elsif digit = cand then
            if cnt < STABLE_N then cnt <= cnt + 1; end if;
            if cnt + 1 >= STABLE_N then shown <= digit; have <= '1'; end if;
          else
            cand <= digit; cnt <= 1;
            if STABLE_N = 1 then shown <= digit; have <= '1'; end if;
          end if;
        end if;
        if frame_ok = '1' then dp <= not dp; end if;
      end if;
    end if;
  end process;

  u_seg : entity work.seg7 port map (digit => shown, seg => seg);
  label_sw <= to_unsigned(SELF_LABEL(to_integer(unsigned(sw_s))), 4);
  u_seg1 : entity work.seg7 port map (digit => label_sw, seg => seg1);
  HEX1 <= '1' & seg1 when src_self = '1' else (others => '1');  -- só acende no autoteste
  HEX0 <= (not dp) & seg when have = '1' else (not dp) & "0111111";  -- "-"

  gen_led : for n in 0 to 9 generate
    LEDR(n) <= '1' when have = '1' and to_integer(shown) = n else '0';
  end generate;
end architecture;
