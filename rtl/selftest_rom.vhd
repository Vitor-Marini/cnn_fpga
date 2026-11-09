-- ROM do autoteste: 16 imagens MNIST de 784 pixels (selftest_pkg). Latencia de 1 ciclo, como o frame_rx.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.selftest_pkg.all;

entity selftest_rom is
  port (
    clk  : in  std_logic;
    sel  : in  unsigned(3 downto 0);
    addr : in  unsigned(9 downto 0);
    q    : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of selftest_rom is
  type rom_t is array (0 to 16383) of std_logic_vector(7 downto 0);
  function to_rom(a : nat_array) return rom_t is
    variable r : rom_t := (others => (others => '0'));
  begin
    for i in a'range loop r(i) := std_logic_vector(to_unsigned(a(i), 8)); end loop;
    return r;
  end function;
  signal rom : rom_t := to_rom(SELF_IMG);
  attribute romstyle : string;
  attribute romstyle of rom : signal is "M9K";
begin
  process (clk)
  begin
    if rising_edge(clk) then
      q <= rom(to_integer(sel) * 784 + to_integer(addr));
    end if;
  end process;
end architecture;
