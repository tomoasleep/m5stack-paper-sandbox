#include <M5Unified.h>
#include <qrcode.h>
#include "qiita_icon_rgb565.h"

struct Link {
  const char* name;
  const char* url;
};

static const Link links[] = {
  {"Qiita",  "https://qiita.com/tomoasleep"},
  {"GitHub", "https://github.com/tomoasleep"},
  {"X",      "https://x.com/nemunemu3desu"},
  {"Blog",   "https://www.nemunemu3.dev/"},
};
static constexpr int linkCount = sizeof(links) / sizeof(links[0]);

static void drawQR(int x, int y, int scale, const char* url) {
  QRCode qrcode;
  uint8_t qrcodeData[qrcode_getBufferSize(4)];
  qrcode_initText(&qrcode, qrcodeData, 4, ECC_LOW, url);

  for (int row = 0; row < qrcode.size; row++) {
    for (int col = 0; col < qrcode.size; col++) {
      if (qrcode_getModule(&qrcode, col, row)) {
        M5.Display.fillRect(x + col * scale, y + row * scale, scale, scale, TFT_BLACK);
      }
    }
  }
}

static void drawMain() {
  M5.Display.fillScreen(TFT_WHITE);

  M5.Display.pushImage(20, 20, QIITA_ICON_W, QIITA_ICON_H, qiita_icon_rgb565);

  M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
  M5.Display.setTextSize(3);
  M5.Display.setCursor(140, 30);
  M5.Display.println("Tomoya Chiba");
  M5.Display.setTextSize(2);
  M5.Display.setCursor(140, 70);
  M5.Display.println("@tomoasleep");

  M5.Display.setTextSize(2);
  int y = 160;
  for (int i = 0; i < linkCount; i++) {
    M5.Display.setCursor(20, y);
    M5.Display.printf("%s", links[i].name);
    M5.Display.setTextSize(1);
    M5.Display.setCursor(120, y + 4);
    M5.Display.printf("%s", links[i].url);
    M5.Display.setTextSize(2);
    y += 40;
  }

  int qrY = 320;
  int qrScale = 3;
  int qrSize = 0;
  {
    QRCode qrcode;
    uint8_t qrcodeData[qrcode_getBufferSize(4)];
    qrcode_initText(&qrcode, qrcodeData, 4, ECC_LOW, links[0].url);
    qrSize = qrcode.size * qrScale;
  }
  int qrX = (M5.Display.width() - qrSize) / 2;
  drawQR(qrX, qrY, qrScale, links[0].url);

  M5.Display.setTextSize(1);
  M5.Display.setCursor(20, M5.Display.height() - 20);
  M5.Display.println("QR: Qiita");
  M5.Display.display();
}

void setup() {
  auto cfg = M5.config();
  cfg.clear_display = false;
  M5.begin(cfg);
  M5.Display.setRotation(0);
  M5.Display.setTextWrap(false);
  M5.Display.setAutoDisplay(false);
  drawMain();
}

void loop() {
  M5.update();
}
