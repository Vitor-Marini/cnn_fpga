-- Testbench do sistema completo: envia imagens MNIST pela UART (1 Mbaud, bit a bit) para o top
-- e confere LEDR contra a predicao do modelo inteiro em Python (bit-exatidao).
-- Testa tambem: lixo/sync falso antes do 1o quadro, quadro com checksum errado (deve ser ignorado)
-- e o estabilizador do display (so muda apos 3 inferencias iguais seguidas).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.selftest_pkg.all;

entity tb_top is end entity;

architecture sim of tb_top is
  constant TCLK : time := 20 ns;
  constant TBIT : time := 1 us;
  signal clk  : std_logic := '0';
  signal key  : std_logic_vector(1 downto 0) := "10";
  signal gpio : std_logic_vector(0 downto 0) := "1";
  signal sw   : std_logic_vector(3 downto 0) := "0000";
  signal hex0, hex1 : std_logic_vector(7 downto 0);
  signal ledr : std_logic_vector(9 downto 0);
  signal stop : boolean := false;
  type img_t is array (0 to 783) of integer;
begin
  clk <= not clk after TCLK / 2 when not stop;

  dut : entity work.top port map (MAX10_CLK1_50 => clk, KEY => key, SW => sw, GPIO => gpio, HEX0 => hex0, HEX1 => hex1, LEDR => ledr);

  process
    file fv : text open read_mode is "test_vectors.txt";
    variable l : line;
    variable img : img_t;
    variable expected, n, errors : integer := 0;
    variable cs : std_logic_vector(6 downto 0);
    variable prev : std_logic_vector(10 downto 0);

    procedure send(b : integer) is
      variable v : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(b, 8));
    begin
      gpio(0) <= '0'; wait for TBIT;
      for j in 0 to 7 loop gpio(0) <= v(j); wait for TBIT; end loop;
      gpio(0) <= '1'; wait for TBIT;
    end procedure;

    procedure send_frame(bad_checksum : boolean) is
    begin
      send(16#FF#);
      cs := (others => '0');
      for p in 0 to 783 loop
        send(img(p));
        cs := cs xor std_logic_vector(to_unsigned(img(p), 7));
      end loop;
      if bad_checksum then cs := not cs; end if;
      send(to_integer(unsigned(cs)));
      wait for 5 ms;  -- inferencia ~3.8 ms
    end procedure;

    function onehot(d : integer) return std_logic_vector is
      variable r : std_logic_vector(9 downto 0) := (others => '0');
    begin
      r(d) := '1'; return r;
    end function;
  begin
    wait for 200 ns; key(0) <= '1'; wait for 1 us;
    -- lixo + sync falso truncado: o receptor deve ressincronizar no proximo 0xFF
    send(16#12#); send(16#FF#); send(5); send(6); send(16#A0#);

    while not endfile(fv) loop
      readline(fv, l);
      for p in 0 to 783 loop read(l, img(p)); end loop;
      read(l, expected);
      for r in 1 to 3 loop send_frame(false); end loop;  -- estabilizador: 3 iguais seguidas
      if ledr /= onehot(expected) then
        report "quadro " & integer'image(n) & ": esperado " & integer'image(expected) severity error;
        errors := errors + 1;
      end if;
      if n = 0 then  -- quadro seguinte com checksum errado nao pode alterar o resultado
        readline(fv, l);
        for p in 0 to 783 loop read(l, img(p)); end loop;
        read(l, expected);
        prev := ledr & hex0(7);
        send_frame(true);
        if ledr & hex0(7) /= prev then
          report "quadro com checksum errado foi aceito" severity error;
          errors := errors + 1;
        end if;
        n := n + 1;
        prev := ledr & hex0(7);
        send_frame(false);  -- 1 quadro diferente sozinho nao pode mudar o display
        if ledr /= prev(10 downto 1) then
          report "estabilizador: 1 quadro isolado mudou o display" severity error;
          errors := errors + 1;
        end if;
        send_frame(false); send_frame(false);
        if ledr /= onehot(expected) then
          report "quadro " & integer'image(n) & ": esperado " & integer'image(expected) severity error;
          errors := errors + 1;
        end if;
      end if;
      n := n + 1;
    end loop;
    -- autoteste: SW escolhe a imagem gravada, KEY1 dispara; LEDR deve ser a predicao do modelo Python
    for s in 0 to 15 loop
      sw <= std_logic_vector(to_unsigned(s, 4));
      wait for 1 us; key(1) <= '0'; wait for 1 us; key(1) <= '1';
      wait for 5 ms;
      if ledr /= onehot(SELF_PRED(s)) then
        report "autoteste SW=" & integer'image(s) & ": esperado " & integer'image(SELF_PRED(s)) severity error;
        errors := errors + 1;
      end if;
      n := n + 1;
    end loop;
    report "FIM: " & integer'image(n) & " quadros, " & integer'image(errors) & " erros" severity note;
    stop <= true;
    wait;
  end process;
end architecture;
