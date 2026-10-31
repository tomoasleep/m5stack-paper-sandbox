# picoruby-ed2208

E Ink **ED2208-DOA** driver for PicoRuby, targeting the
[M5PaperColor](https://shop.m5stack.com/products/m5paper-color-esp32s3-dev-kit)
(4.0" E Ink Spectra 6 panel, 400x600, 4bpp native frame).

Modeled after [picoruby-uc8151](https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-uc8151):
a pure-Ruby driver over `SPI` / `GPIO` / `I2C` / `VRAM` / `BDFFont`.

## Color convention

The panel natively has **6 colors** (4bpp color-index frame; E Ink Spectra 6
has no grayscale waveforms — shades are simulated with dithering, the same
approach M5GFX takes). The driver keeps a 1-bit VRAM for text and shapes,
following the picoruby-uc8151 convention:

- `0` = paper (white)
- `1` = ink (black)

On `update`, the 1-bit VRAM page is expanded into the panel's 4bpp frame
(`ink -> 0x0`, `paper -> 0x1`), then any color bitmaps queued via
`draw_bitmap_4bpp` are overlaid.

### Color bitmaps

```ruby
# data: 4bpp packed rows, 2px/byte, hi nibble = left pixel.
# Nibbles are panel color indices: 0=black 1=white 2=yellow 3=red 5=blue 6=green
# (0x4 and 0x7 are unused by the panel).
display.draw_bitmap_4bpp(x: 20, y: 20, w: 100, h: 100, data: AVATAR_4BPP)
display.update
```

The queue is consumed by `update` (logical coordinates are mapped through
the current rotation), so re-queue bitmaps before every refresh, e.g. after
`set_rotation`. Pre-dithered assets can be generated with
`emulator/gen_assets.rb` (Floyd-Steinberg to the 6-color palette).

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
- `update` — push VRAM (+ queued color bitmaps) to the panel and refresh
  (power cycle included)
- `fill(color)` — fill VRAM (`0` = paper, `1` = ink)
- `draw_bitmap_4bpp(x:, y:, w:, h:, data:)` — queue a 4bpp color-index
  bitmap (2px/byte, hi nibble = left) overlaid at the next `update`
- VRAM::Delegatable primitives: `set_pixel`, `draw_bitmap`, `draw_line`,
  `draw_rect`, `draw_circle`, plus `BDFFont` text rendering when the
  `picoruby-terminus` gem is present.
- `ED2208.convert_1bpp_to_4bpp(data, width, ink, paper)` — pure function,
  unit-testable on a host interpreter (see `test/test_ed2208_logic.rb`).
- `ED2208.blit_4bpp_to_frame(frame, data, x, y, w, h, disp_w, disp_h, rotation)`
  — pure function overlaying a 4bpp bitmap onto a frame (rotation-aware).

## Status

- Verified with the WASM emulator in this repository
  (`emulator/`) against the M5GFX `Panel_ED2208` command sequence.
- SPI is driven in 4-wire mode (DC pin). M5GFX uses 3-wire (9-bit); if the
  panel rejects DC framing on hardware, a 9-bit packed transfer will be
  added as a fallback.
