# e6paper business card app for PicoRuby (M5PaperColor / ED2208-DOA)
# Ported from src/main.cpp (Arduino + M5Unified).
#
# On R2P2-ESP32: placed at storage/home/app.rb, run on boot.
# On emulator: require lines are stripped and sources are concatenated
# by emulator/src/gen_bundle.rb.

require "ed2208"

LINKS = [
  ["Qiita",  "https://qiita.com/tomoasleep"],
  ["GitHub", "https://github.com/tomoasleep"],
  ["X",      "https://x.com/nemunemu3desu"],
  ["Blog",   "https://www.nemunemu3.dev/"],
]

BTN_A_PIN = 10 # M5PaperColor user buttons: GPIO 10/9/1, active low
EPD = {
  spi_unit: :"ESP32_SPI2_HOST",
  spi_freq: 4_000_000,
  sck_pin:  15,
  copi_pin: 13,
  i2c_unit: :"ESP32_I2C0",
  sda_pin:  3,
  scl_pin:  2,
  cs_pin:   44,
  dc_pin:   43,
  rst_pin:  12,
  busy_pin: 11,
}

# Draw a 1-bit packed bitmap (row_bytes/row, MSB = leftmost pixel) via
# VRAM#draw_bitmap, which takes rows as Integers limited to chunks.
# Chunk width must stay under 32: the device VM (MRB_INT32) cannot hold
# a 32-bit row, so 24 keeps one bit headroom.
def draw_bitmap_data(display, x, y, width, height, data, max_chunk = 24)
  row_bytes = (width + 7) / 8
  x0 = 0
  while x0 < width
    cw = max_chunk < (width - x0) ? max_chunk : (width - x0)
    rows = []
    yi = 0
    while yi < height
      row = 0
      xi = 0
      while xi < cw
        bit = (data.getbyte(yi * row_bytes + ((x0 + xi) / 8)) >> (7 - ((x0 + xi) % 8))) & 1
        row = (row << 1) | bit
        xi += 1
      end
      rows << row
      yi += 1
    end
    display.draw_bitmap(x: x + x0, y: y, w: cw, h: height, data: rows)
    x0 += cw
  end
  nil
end

def draw_qr(display, x, y)
  draw_bitmap_data(display, x, y, QR_QIITA_W, QR_QIITA_H, QR_QIITA_1BPP)
  display.draw_text("terminus_6x12", x, y + QR_QIITA_H + 8, "QR: Qiita", 1)
  nil
end

def draw_card(display, portrait)
  # VRAM convention: 0 = paper (white), 1 = ink (black) — same as uc8151.
  # set_rotation swaps the logical coordinate system (400x600 portrait,
  # 600x400 landscape) and reallocates the VRAM transposed into panel layout.
  display.set_rotation(portrait ? 0 : 90)
  width = display.instance_variable_get(:@width)
  display.fill(0)

  # Avatar
  draw_bitmap_data(display, 20, 20, AVATAR_W, AVATAR_H, AVATAR_1BPP)

  # Name / handle
  display.draw_text("terminus_16x32", 140, 30, "Tomoya Chiba", 1)
  display.draw_text("terminus_12x24", 140, portrait ? 80 : 90, "@tomoasleep", 1)

  # Links
  y = portrait ? 150 : 160
  step = portrait ? 40 : 60
  LINKS.each do |name, url|
    display.draw_text("terminus_12x24", 20, y, name, 1)
    display.draw_text("terminus_8x16", 120, portrait ? y + 3 : y, url, 1)
    y += step
  end

  # QR block centered (portrait) / right side (landscape)
  qr_w = QR_QIITA_W
  x = portrait ? (width - qr_w) / 2 : width - qr_w - 30
  draw_qr(display, x, portrait ? 320 : 160)

  display.update
  nil
end

def main
  spi = SPI.new(unit: EPD[:spi_unit], frequency: EPD[:spi_freq],
                sck_pin: EPD[:sck_pin], copi_pin: EPD[:copi_pin])
  i2c = I2C.new(unit: EPD[:i2c_unit], sda_pin: EPD[:sda_pin], scl_pin: EPD[:scl_pin])
  display = ED2208.new(spi: spi, i2c: i2c,
                       cs_pin: EPD[:cs_pin], dc_pin: EPD[:dc_pin],
                       rst_pin: EPD[:rst_pin], busy_pin: EPD[:busy_pin])

  portrait = true
  draw_card(display, portrait)

  btn_a = GPIO.new(BTN_A_PIN, GPIO::IN)
  loop do
    sleep_ms 50
    if btn_a.read == 0
      portrait = !portrait
      draw_card(display, portrait)
    end
  end
end

main
