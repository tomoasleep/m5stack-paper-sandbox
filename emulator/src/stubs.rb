# Emulation stubs for running the ED2208 driver + card app on PicoRuby.wasm.
#
# - GPIO / SPI are bridged to JavaScript (__epd_* hooks in epd_emulator.js).
#   SPI payloads are passed as hex strings to avoid the Ruby<->JS string
#   encoding loss (auto-conversion would treat bytes as UTF-8).
# - I2C (M5PM1 registers) is emulated in pure Ruby and logged to JS.
# - VRAM is a pure-Ruby re-implementation compatible with picoruby-vram's
#   1-bit horizontal layout (MONO_H), plus its VRAM::Delegatable module.

def sleep_ms(ms)
  # Cooperative wait via JS event loop; falls back to no-op outside WASM.
  if Object.const_defined?(:JS)
    JS.global[:console].log("sleep:#{ms} enter")
    JS.global[:Promise].new do |resolve|
      JS.global.setTimeout(ms) { resolve.call }
    end.await
    JS.global[:console].log("sleep:#{ms} exit")
  end
  nil
end

# --- GPIO bridge ---

class GPIO
  OUT = 1
  IN  = 0

  def initialize(pin, dir)
    @pin = pin
    @dir = dir
    JS.global[:__epd_gpio_init].call(pin, dir)
  end

  def write(v)
    # NOTE: in Ruby, 0 is truthy. Normalize explicitly for the JS bridge.
    JS.global[:__epd_gpio_write].call(@pin, v == 0 ? 0 : 1)
    nil
  end

  def read
    JS.global[:__epd_gpio_read].call(@pin)
  end
end

# --- SPI bridge (payloads as hex strings, DC state read on JS side) ---

EMU_HEX = %w(0 1 2 3 4 5 6 7 8 9 A B C D E F)

class SPI
  MSB_FIRST = 1
  LSB_FIRST = 0
  DATA_BITS = 8
  DEFAULT_FREQUENCY = 100_000

  def self.new(unit:, frequency: DEFAULT_FREQUENCY, sck_pin: -1, cipo_pin: -1,
               copi_pin: -1, cs_pin: -1, mode: 0, first_bit: MSB_FIRST)
    obj = allocate
    obj.instance_variable_set(:@unit, unit.to_s)
    obj.instance_variable_set(:@frequency, frequency)
    JS.global[:__epd_spi_init].call(unit.to_s, frequency)
    obj
  end

  attr_accessor :unit

  def write(data)
    if data.is_a?(String)
      hex = ""
      i = 0
      n = data.size
      while i < n
        b = data.getbyte(i)
        hex << EMU_HEX[b >> 4] << EMU_HEX[b & 0x0F]
        i += 1
      end
    else
      # single byte (Integer), e.g. a command byte
      hex = EMU_HEX[(data >> 4) & 0x0F] + EMU_HEX[data & 0x0F]
    end
    JS.global[:__epd_spi_write].call(hex)
    data.size
  end
end

# --- I2C (M5PM1 register model, pure Ruby) ---

EMU_PM1_REGS = {}

class I2C
  DEFAULT_FREQUENCY = 100_000
  DEFAULT_TIMEOUT = 500

  def initialize(unit:, frequency: DEFAULT_FREQUENCY, sda_pin: -1, scl_pin: -1, timeout: DEFAULT_TIMEOUT)
    @frequency = frequency
    @unit = unit.to_s
  end

  def write(i2c_adrs_7, *outputs, timeout: DEFAULT_TIMEOUT, nostop: false)
    if outputs.size >= 2
      reg = outputs[0]
      # last byte is the value for single-register writes
      val = outputs[-1]
      EMU_PM1_REGS[reg] = val
      JS.global[:__epd_i2c_write].call(i2c_adrs_7, reg, val)
    end
    outputs.size
  end

  def read(i2c_adrs_7, len, *outputs, timeout: DEFAULT_TIMEOUT)
    reg = outputs[0]
    (EMU_PM1_REGS[reg] || 0).chr * len
  end
end

# --- VRAM (pure Ruby, 1-bit horizontal layout like picoruby-vram MONO_H) ---

# --- VRAM (pure Ruby, 1-bit horizontal layout like picoruby-vram MONO_H) ---

class VRAM
  attr_accessor :name

  def initialize(w:, h:, cols: 1, rows: 1, layout: :horizontal, invert: false, rotate: 0)
    @w = w
    @h = h
    @invert = invert
    @rotate = rotate
    @row_bytes = (w + 7) / 8
    @buffer = "\x00".b * (@row_bytes * h)
  end

  def set_pixel(x, y, color = 1)
    return if x < 0 || x >= @w || y < 0 || y >= @h
    idx = y * @row_bytes + (x / 8)
    bit = 0x80 >> (x % 8)
    cur = @buffer.getbyte(idx)
    on = color != 0
    on = !on if @invert
    @buffer.setbyte(idx, on ? (cur | bit) : (cur & ~bit))
    nil
  end

  def get_pixel(x, y)
    return 0 if x < 0 || x >= @w || y < 0 || y >= @h
    bit = 0x80 >> (x % 8)
    px = (@buffer.getbyte(y * @row_bytes + (x / 8)) & bit) != 0 ? 1 : 0
    @invert ? 1 - px : px
  end

  def fill(color = 1)
    on = color != 0
    on = !on if @invert
    @buffer = (on ? "\xFF".b : "\x00".b) * (@row_bytes * @h)
    nil
  end

  # 1-bit bitmap rows as Array of Integer (C picoruby-vram compatible):
  # one entry per row, bit (w-1-x) = pixel x.
  def draw_bitmap(x:, y:, w:, h:, data:)
    yi = 0
    while yi < h && yi < data.size
      row = data[yi]
      xi = 0
      while xi < w
        set_pixel(x + xi, y + yi, (row >> (w - 1 - xi)) & 1)
        xi += 1
      end
      yi += 1
    end
    nil
  end

  def draw_line(x0, y0, x1, y1, color = 1)
    # Bresenham
    dx = (x1 - x0).abs
    dy = (y1 - y0).abs
    sx = x0 < x1 ? 1 : -1
    sy = y0 < y1 ? 1 : -1
    err = dx - dy
    loop do
      set_pixel(x0, y0, color)
      break if x0 == x1 && y0 == y1
      e2 = 2 * err
      if e2 > -dy
        err -= dy
        x0 += sx
      end
      if e2 < dx
        err += dx
        y0 += sy
      end
    end
    nil
  end

  def erase(x, y, w, h)
    yy = 0
    while yy < h
      xx = 0
      while xx < w
        set_pixel(x + xx, y + yy, 0)
        xx += 1
      end
      yy += 1
    end
    nil
  end

  def pages
    [[0, 0, @buffer]]
  end

  def dirty_pages
    pages
  end
end

module VRAM::Delegatable
  def set_pixel(x, y, color = 1)
    return if x < 0 || x >= @width || y < 0 || y >= @height
    @vram.set_pixel(x, y, color)
  end

  def draw_bitmap(x:, y:, w:, h:, data:)
    @vram.draw_bitmap(x: x, y: y, w: w, h: h, data: data)
    nil
  end

  def draw_bytes(x:, y:, w:, h:, data:)
    @vram.draw_bitmap(x: x, y: y, w: w, h: h, data: data)
    nil
  end

  def draw_line(x0, y0, x1, y1, color = 1)
    @vram.draw_line(x0, y0, x1, y1, color)
    nil
  end

  def draw_rect(x, y, w, h, color = 1, fill = false)
    if fill
      @vram.draw_rect(x, y, w, h, color)
    else
      draw_line(x,         y,         x + w - 1, y,         color)
      draw_line(x,         y + h - 1, x + w - 1, y + h - 1, color)
      draw_line(x,         y,         x,         y + h - 1, color)
      draw_line(x + w - 1, y,         x + w - 1, y + h - 1, color)
    end
    nil
  end

  def draw_circle(cx, cy, r, color = 1)
    x = r
    y = 0
    err = 1 - r
    while x >= y
      set_pixel(cx + x, cy + y, color)
      set_pixel(cx - x, cy + y, color)
      set_pixel(cx + x, cy - y, color)
      set_pixel(cx - x, cy - y, color)
      set_pixel(cx + y, cy + x, color)
      set_pixel(cx - y, cy + x, color)
      set_pixel(cx + y, cy - x, color)
      set_pixel(cx - y, cy - x, color)
      y += 1
      if err < 0
        err += 2 * y + 1
      else
        x -= 1
        err += 2 * (y - x) + 1
      end
    end
    nil
  end
end
