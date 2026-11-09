# Reconhecimento de dígitos em tempo real: ESP32-CAM → DE10-Lite (CNN em VHDL)

A ESP32-CAM captura a cena e pré-processa a imagem para 28×28 no estilo MNIST. Ela envia o quadro por UART a 1 Mbaud para a DE10-Lite (MAX 10 10M50DAF484C7G), que roda uma CNN INT8 em VHDL. O dígito aparece em **HEX0** e nos **LEDR** (um LED aceso por dígito).

## Resultados verificados

| Item | Resultado |
|---|---|
| Acurácia da rede em float (MNIST teste, 10k) | 97,4% |
| **Acurácia INT8 bit-exata com o RTL** (MNIST teste, 10k) | **97,42%** |
| Acurácia passando pelo pré-processamento da ESP32 (500 quadros sintéticos com papel claro, ruído, gradiente de luz e deslocamento) | 95,0% |
| Simulação Questa do sistema completo (UART real → CNN → LEDR, 20 imagens) | 20/20 iguais ao modelo Python, 0 erros |
| Quartus Prime Lite 25.1 | 584 LEs (1%), 158 kbit de M9K (9%), 2 multiplicadores de 9 bits |
| Timing (Slow 85 °C, 50 MHz) | setup slack +4,19 ns, hold +0,235 ns |
| Latência da inferência | ≈ 199 k ciclos ≈ **4 ms** |
| Transmissão de um quadro (786 bytes a 1 Mbaud) | 7,9 ms |

## Estrutura

```
train/train_quant.py   treino (numpy puro), quantização INT8, modelo inteiro de referência,
                       gera rtl/weights_pkg.vhd e sim/test_vectors.txt
rtl/uart_rx.vhd        receptor UART 8N1 (50 clk/bit)
rtl/frame_rx.vhd       sincronismo de quadro + checksum + buffer ping-pong 2×784 B (M9K)
rtl/cnn_core.vhd       motor CNN: FSM com 1 MAC; ROM de pesos FC em M9K
rtl/weights_pkg.vhd    pesos/biases INT8 (GERADO)
rtl/seg7.vhd           decodificador de 7 segmentos
rtl/top.vhd            top-level da DE10-Lite
sim/tb_top.vhd         testbench do sistema completo; sim/run_sim.sh roda no Questa
quartus/               projeto (.qpf/.qsf com pinagem, .sdc)
esp32cam/              firmware PlatformIO (platformio.ini, src/main.cpp)
```

## Arquitetura

**Rede.** A topologia é pequena e já consagrada (uma conv seguida de uma densa), e cabe com folga no MAX 10:

```
28×28×1 (0..127) → conv 3×3, 8 filtros (valid) → 26×26×8 → maxpool 2×2 → ReLU
→ >>8, saturação 0..127 → 13×13×8 = 1352 → densa 1352→10 → argmax
```

- **Pesos:** int8 com escala por tensor.
- **Acumuladores:** 32 bits.
- **Reescala:** a ativação intermediária é reescalada só com um *shift* (potência de 2, escolhido pelo script), sem nenhum multiplicador extra.
- **Desempate:** no argmax, o primeiro máximo vence, igual no Python e no VHDL.

**Hardware.** Uma FSM com um único MAC sequencial. Cada MAC leva 3 ciclos: endereço, espera da memória síncrona e acumulação. São cerca de 62 k MACs, ou seja, 4 ms por inferência, contra 7,9 ms só para receber o quadro. Paralelizar não traria ganho, porque o gargalo é a UART e a câmera.

Conv, maxpool e ReLU são fundidos. Para cada saída do pooling, o core calcula as 4 convoluções da janela 2×2 e guarda o máximo, então só o mapa de 1352 bytes vai para a RAM.

Uso de memória:
- **M9K (todas inferidas):**
  - imagem ping-pong: 2 blocos
  - mapa de características: 2 blocos
  - ROM com os 13 520 pesos da densa: 16 blocos
- **Lógica:** pesos da conv (72) e biases.

O buffer **ping-pong** permite que a UART receba o próximo quadro enquanto a CNN processa o anterior. Se um quadro chega completo com a CNN ainda ocupada, ele é descartado.

**Saídas da placa:**
- **HEX0:** mostra o dígito (ou "-" antes do primeiro resultado). Pela câmera, só muda depois de 3 inferências seguidas com o mesmo dígito (cerca de 0,3 s de imagem parada), para não pular enquanto o papel se move. No autoteste, mostra na hora.
- **Ponto decimal de HEX0:** alterna a cada quadro recebido com checksum correto. Serve de diagnóstico do link: piscando quer dizer que os dados estão chegando íntegros.
- **KEY0:** reset.

### Protocolo UART (ESP32 → FPGA)

| Byte | Conteúdo |
|---|---|
| 0 | `0xFF` (sincronismo) |
| 1..784 | pixels 0..127, linha a linha, fundo = 0, traço = claro (como no MNIST) |
| 785 | XOR dos 784 pixels (7 bits) |

- **Sincronismo:** os dados têm só 7 bits, então `0xFF` nunca aparece no meio do quadro. Qualquer `0xFF` ressincroniza o receptor na hora, sem perda de alinhamento.
- **Bytes inválidos:** um byte ≥ 0x80 fora do cabeçalho aborta o quadro.
- **Checksum:** um checksum errado descarta o quadro.
- **Formato e taxa:** 8N1 a 1 000 000 baud. A divisão 50 MHz / 1 Mbaud = 50 é exata, e a ESP32 gera 1 Mbaud com erro desprezível.

## Ligação física

| ESP32-CAM | DE10-Lite | Observação |
|---|---|---|
| GPIO14 (U1TXD) | GPIO[0] — header JP1 pino 1 (FPGA PIN_V10) | sinal 3,3 V ↔ banco 3,3 V: **ligação direta, sem conversor de nível** |
| GND | GND do JP1 (pino 12 ou 30) | **terra comum é obrigatório** |
| 5V | fonte 5 V/2 A separada (recomendado) ou JP1 pino 11 (5 V) | ver alerta abaixo |

```
 ESP32-CAM                    DE10-Lite JP1 (GPIO 2x20)
 ┌─────────┐                  ┌──────────────┐
 │  GPIO14 ├──────────────────┤ 1  GPIO[0]   │
 │     GND ├──────────────────┤ 12 GND       │
 │      5V ├──── fonte 5V ────┤ (GND comum)  │
 └─────────┘                  └──────────────┘
```

- **Pinos do JP1:** o esquemático da DE10-Lite confirma GPIO_0 no pino 1, 5 V (VCC5) no pino 11 e 3,3 V no pino 29. Os pinos 12 e 30 são GND pelo padrão Terasic, mas o texto do esquemático não mostra esse rótulo. Meça com multímetro antes de ligar, porque um erro aqui danifica a placa.
- **Alimentação da ESP32-CAM:** ela tem picos de centenas de mA (Wi-Fi e flash), o que pode causar *brownout*. Prefira uma fonte separada, sempre com o GND unido ao da FPGA.
- **Por que GPIO14:** GPIO14 fica livre quando o cartão SD não é usado. Os *strapping pins* 0, 2, 12 e 15 foram evitados. O UART0 (GPIO1/3) fica livre para upload e para o monitor serial.
- **Ruído no boot:** durante o boot a ESP32 pode emitir ruído no GPIO14. O protocolo descarta esse ruído (sem `0xFF` seguido de checksum válido, nada é aceito).

## Gerar os pesos (opcional — já estão em `rtl/weights_pkg.vhd`)

```sh
cd train && python3 train_quant.py     # só numpy; baixa o MNIST; ~1 min
```

O script imprime a acurácia INT8, que é bit-exata com o hardware. Depois regrava `rtl/weights_pkg.vhd` e `sim/test_vectors.txt`.

## Simulação (Questa – Intel FPGA Starter Edition)

```sh
sim/run_sim.sh      # espera: "FIM: 20 quadros, 0 erros"
```

O testbench manda bytes de lixo e um sincronismo falso, depois os quadros MNIST bit a bit a 1 Mbaud, e inclui um quadro com checksum errado. Cada resultado nos LEDR é comparado com a predição do modelo inteiro em Python.

## Quartus Prime Lite: compilar

**Pela GUI:**
1. *File → Open Project* → `quartus/cnn_mnist.qpf`. O projeto já define o dispositivo **10M50DAF484C7G**, os arquivos VHDL, o `.sdc` e toda a pinagem (conferida com o *DE10_LITE_Golden_Top* da Terasic).
2. *Processing → Start Compilation*.
3. Confira os relatórios:
   - *Timing Analyzer:* sem caminhos em vermelho.
   - *Fitter → RAM Summary:* `fc_rom` em **M9K**.

**Pela linha de comando:**
```sh
cd quartus && quartus_sh --flow compile cnn_mnist
```

Os arquivos gerados ficam em `quartus/output_files/cnn_mnist.sof` e `cnn_mnist.pof`.

O `.qsf` define `INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"` (*Single Uncompressed Image with Memory Initialization*). Sem esse modo, a ROM de pesos não é inicializada quando o FPGA carrega da flash interna.

Se você criar o projeto do zero em vez de usar o `.qpf`:
1. Adicione todos os `rtl/*.vhd` e o `quartus/cnn_mnist.sdc`.
2. Defina `top` como top-level.
3. Copie as atribuições de pino do `.qsf`.
4. Em *Device and Pin Options → Configuration*, escolha esse mesmo modo.

## Gravar a DE10-Lite

1. Ligue a placa pelo USB-Blaster (conector USB da placa). *Tools → Programmer* → *Hardware Setup* → **USB-Blaster**.
2. **Volátil (JTAG, perde ao desligar):** *Mode JTAG* → *Add File* `output_files/cnn_mnist.sof` → marque *Program/Configure* → *Start*. Na linha de comando:
   `quartus_pgm -m jtag -o "p;output_files/cnn_mnist.sof"`
3. **Permanente (flash interna CFM):** no Programmer, *Add File* `output_files/cnn_mnist.pof` → marque *Program/Configure* na linha do arquivo `.pof` → *Start*. Na linha de comando:
   `quartus_pgm -m jtag -o "pvb;output_files/cnn_mnist.pof"`
   Desligue e religue a placa: o FPGA carrega sozinho.

## Autoteste na placa (sem ESP32)

A FPGA guarda 16 imagens MNIST (`rtl/selftest_pkg.vhd`, gerado por `train/gen_selftest.py`).

1. Escolha a imagem com SW3..SW0. HEX1 mostra o dígito correto dela.
2. Aperte KEY1 para rodar a CNN.
3. Compare HEX0 com o mapa em `docs/selftest_sw.png`.

Resultado esperado:
- **SW 0–9:** o próprio dígito.
- **SW 10–14:** outras imagens, todas com HEX0 = HEX1.
- **SW 15:** um 5 que a rede erra. HEX0 deve mostrar **6**.

## Firmware ESP32-CAM (PlatformIO)

```sh
cd esp32cam
pio run                         # compila
pio run -t upload               # grava
pio device monitor              # monitor serial a 115200 (mostra o 28×28 em ASCII)
```

**Upload na ESP32-CAM sem placa-base USB (adaptador FTDI 3,3 V):**
1. Faça as ligações:
   - FTDI TX → U0R (GPIO3)
   - FTDI RX → U0T (GPIO1)
   - GND comum
   - **GPIO0 → GND**
2. Aperte RESET e rode `pio run -t upload`.
3. Depois do upload, **remova o jumper GPIO0–GND** e aperte RESET.

Com a placa-base *ESP32-CAM-MB*, basta o cabo USB.

**Ajustes no topo de `src/main.cpp`:**
- `INK_IS_DARK`: 1 para tinta escura em papel claro, 0 para traço claro em fundo escuro.
- `THR_PCT`: limiar entre fundo e traço.
- `MIN_CONTRAST`: abaixo dele, considera que não há dígito e não envia o quadro.
- `DEBUG_EVERY`: a cada quantos quadros imprime o 28×28 no monitor.

**Pré-processamento:**
1. QVGA em cinza.
2. ROI central de 224×224.
3. Média 4×4, resultando em 56×56.
4. Inversão.
5. Limiar e esticamento de contraste.
6. *Bounding box* do dígito.
7. Redimensionamento para caber em 20×20.
8. Posicionamento no 28×28 pelo **centro de massa**, como no MNIST original. Esse passo é o que mais pesa na acurácia com câmera real.

## Dicas de captura

- **Distância e enquadramento:** o dígito deve ocupar boa parte do **centro** da imagem (ROI de 224×224 dentro dos 320×240). Uma câmera a ~10–20 cm de um dígito de 3–5 cm funciona bem. Use o ASCII do monitor serial para alinhar.
- **Traço:** use caneta grossa (marcador) e traço contínuo. Traços finos somem na média 4×4.
- **Contraste:** o MNIST é **traço branco em fundo preto**. O firmware inverte a imagem, então use papel branco e tinta preta com `INK_IS_DARK 1`. Para dígitos claros em fundo escuro (tela, lousa), use `INK_IS_DARK 0`.
- **Iluminação:** use luz difusa e uniforme, sem sombra da própria câmera sobre o papel. Reflexos fortes viram "traço" depois da inversão. O LED de flash (GPIO4) não é usado porque ofusca o papel de perto.
- **Orientação:** coloque o dígito na vertical e de frente. A rede não é invariante a rotação acima de ~15°.
- **Um dígito por vez:** não deixe bordas de papel, dedos ou objetos escuros no ROI. A *bounding box* incluiria esses objetos.

## Referências consultadas

- [grant4001/MNIST_Classification_FPGA](https://github.com/grant4001/MNIST_Classification_FPGA): CNN de 7 camadas com câmera D8M em Cyclone IV (DE2-115), SystemVerilog, ponto fixo de 16 bits. Confirma a viabilidade de câmera, CNN e display em FPGA Intel. Aqui foi usada uma rede bem menor, em INT8, para caber folgado no MAX 10.
- [omarelhedaby/CNN-FPGA](https://github.com/omarelhedaby/CNN-FPGA): CNN estilo LeNet para MNIST em Zynq (Verilog).
- Pinagem: *DE10_LITE_Golden_Top*, que acompanha o Quartus (`quartus/common/devplatforms/DE10_LITE_Golden_Top`).

Nenhum código foi portado. As referências serviram para validar as escolhas de topologia e quantização.
