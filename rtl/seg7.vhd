-- Decodificador hexadecimal para 7 segmentos, ativo em 0 (seg(0)=a ... seg(6)=g).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity seg7 is
  port (digit : in unsigned(3 downto 0); seg : out std_logic_vector(6 downto 0));
end entity;

architecture rtl of seg7 is
begin
  with to_integer(digit) select seg <=
    "1000000" when 0, "1111001" when 1, "0100100" when 2, "0110000" when 3,
    "0011001" when 4, "0010010" when 5, "0000010" when 6, "1111000" when 7,
    "0000000" when 8, "0010000" when 9, "1111111" when others;
end architecture;
