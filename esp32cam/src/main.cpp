// ESP32-CAM (AI-Thinker, OV2640) -> imagem 28x28 estilo MNIST -> UART 1 Mbaud -> FPGA DE10-Lite.
//
// Pipeline: QVGA em escala de cinza -> ROI central 224x224 -> media 2x2 (112x112) -> tinta = fundo local - pixel
// (traco claro em fundo preto, como no MNIST; remove faixas de flicker e luz irregular) -> limiar -> maior
// componente conexa -> bounding box -> engrossa o traco -> cabe em 20x20 -> posiciona no 28x28 pelo centro
// de massa (igual ao pre-processamento original do MNIST).
//
// Protocolo: 0xFF | 784 bytes (0..127, linha a linha) | XOR dos 784 bytes. 0xFF nunca aparece nos dados.
#include <Arduino.h>
#include "esp_camera.h"

#define FPGA_TX_PIN   14     // livre quando o cartao SD nao e usado; evita os strapping pins 0/2/12/15
#define FPGA_BAUD     1000000
#define INK_IS_DARK   1      // 1: tinta escura em papel claro (caso comum). 0: traco claro em fundo escuro
#define BG_R          6      // raio da janela do fundo local, em celulas de 2x2 px (menor que as faixas de flicker)
#define THR_PCT       35     // e traco o que tiver tinta acima deste % da tinta maxima
#define MIN_INK       30     // tinta maxima abaixo disso: nao ha digito na cena, quadro nao e enviado
#define DEBUG_EVERY   10     // imprime o 28x28 em ASCII no monitor serial a cada N quadros (0 = nunca)

static const int ROI = 224, G = 112, CELL = ROI / G;   // 224/112 = 2
static HardwareSerial FPGA(1);
static uint8_t grid[G * G], bg[G * G], ink[G * G], crop[G * G];
static uint16_t *lab, *stk, *csize, *tmp;  // ~88 KB no heap: nao cabem na RAM estatica (.bss)
static uint8_t out[28][28];

static bool init_camera() {
  camera_config_t c = {};
  // pinagem AI-Thinker
  c.pin_pwdn = 32; c.pin_reset = -1; c.pin_xclk = 0;
  c.pin_sccb_sda = 26; c.pin_sccb_scl = 27;
  c.pin_d7 = 35; c.pin_d6 = 34; c.pin_d5 = 39; c.pin_d4 = 36;
  c.pin_d3 = 21; c.pin_d2 = 19; c.pin_d1 = 18; c.pin_d0 = 5;
  c.pin_vsync = 25; c.pin_href = 23; c.pin_pclk = 22;
  c.xclk_freq_hz = 20000000;
  c.ledc_timer = LEDC_TIMER_0; c.ledc_channel = LEDC_CHANNEL_0;
  c.pixel_format = PIXFORMAT_GRAYSCALE;
  c.frame_size = FRAMESIZE_QVGA;                       // 320x240
  c.fb_count = 2;
  c.fb_location = CAMERA_FB_IN_PSRAM;
  c.grab_mode = CAMERA_GRAB_LATEST;
  return esp_camera_init(&c) == ESP_OK;
}

// Filtro separavel (maximo ou media) com janela (2*BG_R+1)^2 e borda replicada.
static void filt(const uint8_t *src, uint8_t *dst, bool mx) {
  const int n = 2 * BG_R + 1;
  for (int y = 0; y < G; y++)
    for (int x = 0; x < G; x++) {
      int a = 0;
      for (int k = -BG_R; k <= BG_R; k++) { int v = src[y * G + constrain(x + k, 0, G - 1)]; a = mx ? max(a, v) : a + v; }
      tmp[y * G + x] = a;
    }
  for (int y = 0; y < G; y++)
    for (int x = 0; x < G; x++) {
      int a = 0;
      for (int k = -BG_R; k <= BG_R; k++) { int v = tmp[constrain(y + k, 0, G - 1) * G + x]; a = mx ? max(a, v) : a + v; }
      dst[y * G + x] = mx ? a : a / (n * n);
    }
}

// Retorna false se nao ha digito na cena.
static bool preprocess(const camera_fb_t *fb) {
  if (!lab) {
    uint16_t *mem = (uint16_t *)malloc((3 * G * G + G * G / 2 + 2) * sizeof(uint16_t));
    if (!mem) { Serial.println("sem memoria para o pre-processamento"); return false; }
    lab = mem; stk = mem + G * G; tmp = mem + 2 * G * G; csize = mem + 3 * G * G;
  }
  const int x0 = (fb->width - ROI) / 2, y0 = (fb->height - ROI) / 2;
  for (int gy = 0; gy < G; gy++)
    for (int gx = 0; gx < G; gx++) {
      int s = 0;
      for (int y = 0; y < CELL; y++)
        for (int x = 0; x < CELL; x++) s += fb->buf[(y0 + gy * CELL + y) * fb->width + x0 + gx * CELL + x];
      grid[gy * G + gx] = INK_IS_DARK ? s / (CELL * CELL) : 255 - s / (CELL * CELL);
    }

  // fundo = maximo local (o papel) suavizado; tinta = fundo - pixel. Remove faixas de flicker e luz irregular.
  filt(grid, ink, true);
  filt(ink, bg, false);
  int imax = 0;
  for (int i = 0; i < G * G; i++) { ink[i] = max(0, bg[i] - grid[i]); imax = max(imax, (int)ink[i]); }
  if (imax < MIN_INK) return false;
  const int thr = max(12, imax * THR_PCT / 100);

  // componentes conexas (4-vizinhos) do traco: ficam a maior e as com >= 20% dela (descarta pontos e bordas)
  memset(lab, 0, G * G * sizeof(uint16_t));
  int nlab = 0, big = 0;
  for (int i = 0; i < G * G; i++) {
    if (ink[i] <= thr || lab[i]) continue;
    int sp = 0, c = 0;
    stk[sp++] = i; lab[i] = ++nlab;
    while (sp) {
      const int p = stk[--sp], y = p / G, x = p % G;
      const int nb[4] = {p + G, p - G, p + 1, p - 1};
      const bool in[4] = {y < G - 1, y > 0, x < G - 1, x > 0};
      c++;
      for (int k = 0; k < 4; k++)
        if (in[k] && ink[nb[k]] > thr && !lab[nb[k]]) { lab[nb[k]] = nlab; stk[sp++] = nb[k]; }
    }
    csize[nlab] = c; big = max(big, c);
  }
  int bx0 = G, by0 = G, bx1 = -1, by1 = -1;
  for (int i = 0; i < G * G; i++) {
    const bool keep = lab[i] && csize[lab[i]] * 5 >= big;
    grid[i] = keep ? min(255, (ink[i] - thr) * 255 / max(1, imax - thr) + 64) : 0;
    if (keep) { const int x = i % G, y = i / G; bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y); }
  }
  if (bx1 < 0) return false;

  // engrossa o traco (max 3x3) dentro da caixa: caneta fina fica com a espessura dos tracos do MNIST
  const int bw = bx1 - bx0 + 1, bh = by1 - by0 + 1, bm = max(bw, bh);
  for (int y = 0; y < bh; y++)
    for (int x = 0; x < bw; x++) {
      int m = 0;
      for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++)
          if (y + dy >= 0 && y + dy < bh && x + dx >= 0 && x + dx < bw) m = max(m, (int)grid[(by0 + y + dy) * G + bx0 + x + dx]);
      crop[y * bw + x] = m;
    }

  // maior lado do digito -> 20 px (media de area)
  const int dw = max(1, (bw * 20 + bm / 2) / bm), dh = max(1, (bh * 20 + bm / 2) / bm);
  static uint8_t box[20][20];
  long m = 0, mxs = 0, mys = 0;
  for (int oy = 0; oy < dh; oy++)
    for (int ox = 0; ox < dw; ox++) {
      int sy0 = oy * bh / dh, sy1 = max(sy0 + 1, (oy + 1) * bh / dh);
      int sx0 = ox * bw / dw, sx1 = max(sx0 + 1, (ox + 1) * bw / dw);
      int s = 0;
      for (int y = sy0; y < sy1; y++)
        for (int x = sx0; x < sx1; x++) s += crop[y * bw + x];
      int v = s / ((sy1 - sy0) * (sx1 - sx0));
      box[oy][ox] = v;
      m += v; mxs += (long)v * ox; mys += (long)v * oy;
    }
  if (m == 0) return false;

  // posiciona de modo que o centro de massa caia no centro do 28x28
  int offx = constrain((int)lroundf(13.5f - (float)mxs / m), 0, 28 - dw);
  int offy = constrain((int)lroundf(13.5f - (float)mys / m), 0, 28 - dh);
  memset(out, 0, sizeof(out));
  for (int y = 0; y < dh; y++)
    for (int x = 0; x < dw; x++) out[offy + y][offx + x] = box[y][x] >> 1;  // 0..127
  return true;
}

static void send_frame() {
  uint8_t cs = 0;
  for (int i = 0; i < 784; i++) cs ^= (&out[0][0])[i];
  FPGA.write(0xFF);
  FPGA.write(&out[0][0], 784);
  FPGA.write(cs);
}

static void debug_print() {
  static const char *shade = " .:-=+*#%@";
  for (int y = 0; y < 28; y++) {
    char line[29];
    for (int x = 0; x < 28; x++) line[x] = shade[out[y][x] * 9 / 127];
    line[28] = 0;
    Serial.println(line);
  }
  Serial.println("----------------------------");
}

void setup() {
  Serial.begin(115200);
  FPGA.begin(FPGA_BAUD, SERIAL_8N1, -1, FPGA_TX_PIN);  // so TX
  while (!init_camera()) {
    Serial.println("falha ao iniciar a camera, tentando de novo...");
    delay(1000);
  }
  Serial.println("camera OK");
}

void loop() {
  static uint32_t n = 0;
  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb) return;
  if (Serial.available() && Serial.read() == 'd') {  // calibracao: 'd' no monitor envia o quadro cru 320x240
    Serial.printf("FRAME %d %d\n", fb->width, fb->height);
    Serial.write(fb->buf, fb->len);
  }
  bool ok = preprocess(fb);
  esp_camera_fb_return(fb);
  if (!ok) return;
  send_frame();
  if (DEBUG_EVERY && ++n % DEBUG_EVERY == 0) debug_print();
}
