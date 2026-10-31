# picoruby-ed2208

E Ink **ED2208-DOA** driver for PicoRuby, targeting the
[M5PaperColor](https://shop.m5stack.com/products/m5paper-color-esp32s3-dev-kit)
(4.0" E Ink Spectra 6 panel, 400x600, 4bpp native frame).

Modeled after [picoruby-uc8151](https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-uc8151):
a pure-Ruby driver over `SPI` / `GPIO` / `I2C` / `VRAM` / `BDFFont`.

## Color convention

The panel natively has 6 colors (4bpp), but this driver currently renders in
**monochrome**. VRAM is 1-bit and follows the picoruby-uc8151 convention:

- `0` = paper (white)
- `1` = ink (black)

On `update`, the 1-bit VRAM page is expanded into the panel's 4bpp frame
(`ink -> 0x0`, `paper -> 0x1`). Color indices (BLACK/WHITE/YELLOW/RED/BLUE/GREEN)
are kept in the API for future color support.

## Usage

```ruby
require "ed2208"

spi = SPI.new(unit: :"ESP32_SPI2_HOST", frequency: 4_000_000,
              sck_pin: 15, copi_pin: 13)
i2c = I2C.new(unit: :"ESP32_I2C0", sda_pin: 3, scl_pin: 2)
display = ED2208.new(spi: spi, i2c: i2c,
                     cs_pin: 44, dc_pin: 43, rst_pin: 12, busy_pin: 11)

display.fill(0)                          # paper
display.draw_text("terminus_16x32", 10, 10, "Hello, M5PaperColor!")
display.draw_line(0, 40, 399, 40)
display.update                           # transfer frame + refresh
```

## Power sequencing

The e-paper rail is enabled through the **M5PM1 PMIC** (I2C `0x6E`):
GPIO0 is set output-push-pull-high, which powers the display (see
`power_on_epd`). The sequence mirrors M5GFX's `Panel_ED2208` init.

## Hardware notes (M5PaperColor)

| Signal | ESP32-S3 GPIO |
|---|---|
| SPI CLK / MOSI | G15 / G13 |
| CS / DC | G44 / G43 |
| RST / BUSY | G12 / G11 |
| M5PM1 I2C (SDA/SCL) | G3 / G2 |
| User buttons | G10, G9, G1 (active low) |

## API

- `ED2208.new(spi:, i2c:, cs_pin:, dc_pin:, rst_pin:, busy_pin:, w: 400, h: 600)`
- `update` — push VRAM to the panel and refresh (power cycle included)
- `fill(color)` — fill VRAM (`0` = paper, `1` = ink)
- VRAM::Delegatable primitives: `set_pixel`, `draw_bitmap`, `draw_line`,
  `draw_rect`, `draw_circle`, plus `BDFFont` text rendering when the
  `picoruby-terminus` gem is present.
- `ED2208.convert_1bpp_to_4bpp(data, width, ink, paper)` — pure function,
  unit-testable on a host interpreter (see `test/test_ed2208_logic.rb`).

## Status

- Verified with the WASM emulator in this repository
  (`emulator/`) against the M5GFX `Panel_ED2208` command sequence.
- SPI is driven in 4-wire mode (DC pin). M5GFX uses 3-wire (9-bit); if the
  panel rejects DC framing on hardware, a 9-bit packed transfer will be
  added as a fallback.
