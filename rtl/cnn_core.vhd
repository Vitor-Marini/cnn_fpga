-- Motor de inferencia: 1 MAC sequencial, FSM.
--   conv3x3 (NF filtros) + maxpool2x2 + ReLU + (>>ACT_SHIFT, clamp 0..127) fundidos -> fmap 13x13xNF
--   dense (13*13*NF) -> 10 + argmax (primeiro maximo vence)
-- Cada MAC usa 3 ciclos (endereco, espera da memoria sincrona, acumula):
-- ~(48672 + 13520) * 3 ciclos ~= 3.8 ms a 50 MHz.
-- Bit-exato com int_forward() em train/train_quant.py.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.weights_pkg.all;

entity cnn_core is
  port (
    clk, rst : in  std_logic;
    start    : in  std_logic;
    busy     : out std_logic;
    img_addr : out unsigned(9 downto 0) := (others => '0');
    img_data : in  std_logic_vector(7 downto 0);  -- 1 ciclo apos img_addr
    done     : out std_logic;                     -- pulso
    digit    : out unsigned(3 downto 0)
  );
end entity;

architecture rtl of cnn_core is
  constant FM_N : natural := 169 * NF;

  -- ROM dos pesos FC no formato do template da Intel (sinal inicializado, profundidade 2^n) -> M9K
  type rom_t is array (0 to 16383) of std_logic_vector(7 downto 0);
  function to_rom(a : int_array) return rom_t is
    variable r : rom_t := (others => (others => '0'));
  begin
    for i in a'range loop r(i) := std_logic_vector(to_signed(a(i), 8)); end loop;
    return r;
  end function;
  signal fc_rom : rom_t := to_rom(FC_W);
  attribute romstyle : string;
  attribute romstyle of fc_rom : signal is "M9K";

  type fm_t is array (0 to FM_N - 1) of std_logic_vector(7 downto 0);
  signal fmap : fm_t;
  signal fm_we : std_logic := '0';
  signal fm_waddr, fm_raddr : natural range 0 to FM_N - 1 := 0;
  signal fm_wdata, fm_q, w_q : std_logic_vector(7 downto 0);
  signal w_addr : natural range 0 to 16383 := 0;

  type st_t is (IDLE, C_INIT, C_ADDR, C_WAIT, C_MAC, C_CMP, C_STORE,
                F_INIT, F_ADDR, F_WAIT, F_MAC, F_CMP, FIN);
  signal st : st_t := IDLE;
  signal f  : natural range 0 to NF - 1 := 0;
  signal py, px : natural range 0 to 12 := 0;
  signal d  : natural range 0 to 3 := 0;   -- posicao na janela de pooling (dy = d/2, dx = d mod 2)
  signal k  : natural range 0 to 8 := 0;   -- posicao no kernel (ky = k/3, kx = k mod 3)
  signal o  : natural range 0 to 9 := 0;
  signal i  : natural range 0 to FM_N - 1 := 0;
  signal acc, best : signed(31 downto 0) := (others => '0');
  signal digit_r   : unsigned(3 downto 0) := (others => '0');
begin
  busy <= '0' when st = IDLE else '1';

  mem_p : process (clk)
  begin
    if rising_edge(clk) then
      if fm_we = '1' then fmap(fm_waddr) <= fm_wdata; end if;
      fm_q <= fmap(fm_raddr);
    end if;
  end process;

  rom_p : process (clk)
  begin
    if rising_edge(clk) then
      w_q <= fc_rom(w_addr);
    end if;
  end process;

  fsm_p : process (clk)
    variable relu : signed(31 downto 0);
  begin
    if rising_edge(clk) then
      done  <= '0';
      fm_we <= '0';
      if rst = '1' then
        st <= IDLE;
      else
        case st is
          when IDLE =>
            if start = '1' then
              f <= 0; py <= 0; px <= 0; d <= 0; fm_waddr <= 0;
              st <= C_INIT;
            end if;

          -- ---------------- conv + pool + relu ----------------
          when C_INIT =>
            if fm_we = '1' then fm_waddr <= fm_waddr + 1; end if;  -- escrita do C_STORE ocorre neste ciclo
            acc <= to_signed(CONV_B(f), 32); k <= 0;
            st <= C_ADDR;
          when C_ADDR =>
            img_addr <= to_unsigned((2 * py + d / 2 + k / 3) * 28 + 2 * px + d mod 2 + k mod 3, 10);
            st <= C_WAIT;
          when C_WAIT =>
            st <= C_MAC;
          when C_MAC =>
            acc <= acc + resize(signed(img_data) * to_signed(CONV_W(f * 9 + k), 8), 32);
            if k = 8 then st <= C_CMP; else k <= k + 1; st <= C_ADDR; end if;
          when C_CMP =>
            if d = 0 or acc > best then best <= acc; end if;
            if d = 3 then st <= C_STORE; else d <= d + 1; st <= C_INIT; end if;
          when C_STORE =>
            if best < 0 then relu := (others => '0'); else relu := best; end if;
            relu := shift_right(relu, ACT_SHIFT);
            if relu > 127 then relu := to_signed(127, 32); end if;
            fm_wdata <= std_logic_vector(relu(7 downto 0));
            fm_we <= '1';
            d <= 0;
            if px < 12 then
              px <= px + 1; st <= C_INIT;
            else
              px <= 0;
              if py < 12 then
                py <= py + 1; st <= C_INIT;
              else
                py <= 0;
                if f < NF - 1 then f <= f + 1; st <= C_INIT;
                else o <= 0; w_addr <= 0; st <= F_INIT; end if;
              end if;
            end if;

          -- ---------------- dense + argmax ----------------
          when F_INIT =>
            acc <= to_signed(FC_B(o), 32); i <= 0;
            st <= F_ADDR;
          when F_ADDR =>
            fm_raddr <= i;
            st <= F_WAIT;
          when F_WAIT =>
            st <= F_MAC;
          when F_MAC =>
            acc <= acc + resize(signed(fm_q) * signed(w_q), 32);
            if w_addr < FC_W'high then w_addr <= w_addr + 1; end if;
            if i = FM_N - 1 then st <= F_CMP; else i <= i + 1; st <= F_ADDR; end if;
          when F_CMP =>
            if o = 0 or acc > best then best <= acc; digit_r <= to_unsigned(o, 4); end if;
            if o = 9 then st <= FIN; else o <= o + 1; st <= F_INIT; end if;
          when FIN =>
            digit <= digit_r; done <= '1';
            st <= IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
