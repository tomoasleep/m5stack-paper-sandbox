require "spi"
require "gpio"
require "i2c"
require "vram"
require "bdffont"

# Driver for the E Ink ED2208-DOA TCON used on M5PaperColor
# (4.0" E Ink Spectra 6 panel, 400x600, 4bpp native frame).
#
# This driver renders in monochrome: a 1-bit VRAM page is expanded
# into the 4bpp frame format (nibble = color index) on update.
# Color indices are kept in the API so color support can be added later.
#
# Power sequencing requires the M5PM1 PMIC (I2C 0x6E): its GPIO0
# enables the e-paper power rail. Performed in power_on_epd.
class ED2208
  include VRAM::Delegatable

  BDFFont.setup(self)

  # Panel native 4bpp color indices
  BLACK  = 0x0
  WHITE  = 0x1
  YELLOW = 0x2
  RED    = 0x3
  BLUE   = 0x5
  GREEN  = 0x6

  # ED2208 commands
  CMDH = 0xAA # Command header (unlock)
  PSR  = 0x00 # Panel setting
  POF  = 0x02 # Power off
  PON  = 0x04 # Power on
  BTST = 0x06 # Booster soft start
  DTM  = 0x10 # Data start transmission
  DRF  = 0x12 # Display refresh
  DSLP = 0x07 # Deep sleep
  TRES = 0x61 # Resolution setting

  M5PM1_ADDR = 0x6E

  # @param spi  [SPI] pre-initialized SPI (cs_pin: -1, hardware CS disabled)
  # @param i2c  [I2C] pre-initialized I2C used for the M5PM1 PMIC
  def initialize(spi:, i2c:, cs_pin:, dc_pin:, rst_pin:, busy_pin:, w: 400, h: 600, rotation: 0)
    @panel_w = w
    @panel_h = h
    @rotation = rotation
    @spi  = spi
    @i2c  = i2c
    @cs   = GPIO.new(cs_pin,   GPIO::OUT)
    @dc   = GPIO.new(dc_pin,   GPIO::OUT)
    @rst  = GPIO.new(rst_pin,  GPIO::OUT)
    @busy = GPIO.new(busy_pin, GPIO::IN)
    @bpp4_table = ED2208.build_4bpp_table
    rebuild_vram
    power_on_epd
    reset
    init_display
  end

  # Logical width/height follow the rotation; the internal VRAM buffer
  # is transposed by picoruby-vram (rotate=90/270) so its raw bytes stay
  # in panel layout (panel_w x panel_h).
  def set_rotation(deg)
    @rotation = deg
    rebuild_vram
    nil
  end

  private def rebuild_vram
    if @rotation == 90 || @rotation == 270
      @width = @panel_h
      @height = @panel_w
    else
      @width = @panel_w
      @height = @panel_h
    end
    @row_bytes_1bpp = (@panel_w + 7) / 8
    @frame_size_4bpp = @panel_w * @panel_h / 2
    @vram = VRAM.new(w: @width, h: @height, cols: 1, rows: 1,
                     layout: :horizontal, invert: false, rotate: @rotation)
    @vram.name = "ED2208"
  end

  # Convert a 1-bit horizontal-packed bitmap into a 4bpp frame.
  # Pure function so it can be unit-tested on a host interpreter.
  # Uses getbyte/setbyte: strings may carry invalid-UTF-8 bytes under
  # MRB_UTF8_STRING, so ord/chr are unsafe for binary data.
  # VRAM convention (same as picoruby-uc8151): bit 1 = ink, bit 0 = paper.
  # @param data [String] 1-bit packed rows, MSB = leftmost pixel
  # @param width [Integer] pixels per row (rows implied by data size)
  # @param ink [Integer] 4bpp color index for set bits
  # @param paper [Integer] 4bpp color index for clear bits
  # @return [String] frame where each nibble is a color index
  def self.convert_1bpp_to_4bpp(data, width, ink = BLACK, paper = WHITE)
    table = build_4bpp_table(ink, paper)
    row_bytes = (width + 7) / 8
    row_out = width / 2
    height = data.size / row_bytes
    frame = "\x00" * (row_out * height)
    y = 0
    while y < height
      j = y * row_out
      i = y * row_bytes
      row_end = i + row_bytes
      while i < row_end
        tb = table[data.getbyte(i)]
        frame.setbyte(j, tb.getbyte(0))
        frame.setbyte(j + 1, tb.getbyte(1))
        frame.setbyte(j + 2, tb.getbyte(2))
        frame.setbyte(j + 3, tb.getbyte(3))
        i += 1
        j += 4
      end
      y += 1
    end
    frame
  end

  # 256-entry lookup: 1-bit byte -> 4 bytes of 4bpp (8 nibbles).
  # Each source bit becomes a nibble: 1 -> ink, 0 -> paper.
  def self.build_4bpp_table(ink = BLACK, paper = WHITE)
    ink = ink & 0x0F
    paper = paper & 0x0F
    Array.new(256) do |b|
      s = "\x00\x00\x00\x00"
      j = 0
      i = 7
      while i >= 0
        hi = ((b >> i) & 1) == 1 ? ink : paper
        lo = ((b >> (i - 1)) & 1) == 1 ? ink : paper
        s.setbyte(j, (hi << 4) | lo)
        j += 1
        i -= 2
      end
      s
    end
  end

  # Overlay a 4bpp color-index bitmap onto a 4bpp frame, mapping logical
  # display coords through the rotation into panel layout. Pure function so
  # it can be unit-tested on a host interpreter. Only pixels covered by the
  # bitmap are replaced; the rest of the frame keeps its color.
  # Rotation convention matches picoruby-vram (rotate=90: panel (x,y) =
  # (ly, disp_w-1-lx)); the frame is disp_h wide when rotated 90/270.
  # @param frame [String] 4bpp frame, panel layout (frame_w/2 bytes per row)
  # @param data [String] 4bpp bitmap rows, 2px/byte, hi nibble = left pixel
  # @param x [Integer] logical x of the bitmap's left edge
  # @param y [Integer] logical y of the bitmap's top edge
  # @param bw [Integer] bitmap width in pixels
  # @param bh [Integer] bitmap height in pixels
  # @param disp_w [Integer] logical display width (after rotation)
  # @param disp_h [Integer] logical display height (after rotation)
  # @param rotation [Integer] 0, 90, 180 or 270
  # @return [String] the same frame, mutated in place
  def self.blit_4bpp_to_frame(frame, data, x, y, bw, bh, disp_w, disp_h, rotation)
    frame_w = (rotation == 90 || rotation == 270) ? disp_h : disp_w
    stride = frame_w / 2
    bmp_row_bytes = (bw + 1) / 2
    dy = 0
    while dy < bh
      ly = y + dy
      if ly >= 0 && ly < disp_h
        dx = 0
        while dx < bw
          lx = x + dx
          if lx >= 0 && lx < disp_w
            b = data.getbyte(dy * bmp_row_bytes + (dx >> 1))
            c = (dx & 1) == 0 ? (b >> 4) : (b & 0x0F)
            case rotation
            when 90 then bx = ly;              by = disp_w - 1 - lx
            when 180 then bx = disp_w - 1 - lx; by = disp_h - 1 - ly
            when 270 then bx = disp_h - 1 - ly; by = lx
            else bx = lx; by = ly
            end
            fi = by * stride + (bx >> 1)
            old = frame.getbyte(fi)
            if (bx & 1) == 0
              frame.setbyte(fi, (old & 0x0F) | (c << 4))
            else
              frame.setbyte(fi, (old & 0xF0) | c)
            end
          end
          dx += 1
        end
      end
      dy += 1
    end
    frame
  end

  # Send the VRAM contents to the panel and refresh it.
  # VRAM convention (same as picoruby-uc8151): bit 1 = ink (black),
  # bit 0 = paper (white). With rotation, the VRAM buffer is already
  # transposed into panel layout by picoruby-vram.
  # Color bitmaps queued via draw_bitmap_4bpp are overlaid onto the
  # expanded 4bpp frame before transfer, then the queue is cleared.
  def update
    data = @vram.pages[0][2]
    frame = ED2208.convert_1bpp_to_4bpp(data, @panel_w, BLACK)
    if @pending_4bpp
      i = 0
      n = @pending_4bpp.size
      while i < n
        bm = @pending_4bpp[i]
        ED2208.blit_4bpp_to_frame(frame, bm[:data], bm[:x], bm[:y],
                                  bm[:w], bm[:h], @width, @height, @rotation)
        i += 1
      end
      @pending_4bpp = nil
    end
    _exec_transfer(frame)
    _turn_on_display
  end

  # Queue a 4bpp color-index bitmap (2px/byte, hi nibble = left pixel,
  # nibbles are panel color indices) to be drawn at logical (x, y).
  # Applied on top of the 1-bit VRAM at the next #update; the queue is
  # consumed there, so re-queue after each refresh (e.g. on rotation).
  def draw_bitmap_4bpp(x:, y:, w:, h:, data:)
    (@pending_4bpp ||= []) << { x: x, y: y, w: w, h: h, data: data }
    nil
  end

  def fill(color = WHITE)
    @vram.fill(color)
  end

  private

  # M5PM1 (PMIC) register helpers. GPIO0 = EPD power enable.
  private def pm1_read_reg(reg)
    @i2c.read(M5PM1_ADDR, 1, reg).ord
  end

  private def pm1_write_reg(reg, val)
    @i2c.write(M5PM1_ADDR, reg, val)
  end

  private def pm1_bit_off(reg, mask)
    pm1_write_reg(reg, pm1_read_reg(reg) & (~mask & 0xFF))
  end

  private def pm1_bit_on(reg, mask)
    pm1_write_reg(reg, pm1_read_reg(reg) | mask)
  end

  # Power-up the e-paper rail via M5PM1 GPIO0 (see M5GFX init sequence).
  private def power_on_epd
    pm1_write_reg(0x0A, 0x00)                    # WDT_CNT = 0 (disable watchdog)
    pm1_bit_off(0x16, 0b11 | (0b11 << 3))        # gpio0/gpio3 -> GPIO function
    pm1_bit_on(0x10, 1 | (1 << 3))               # gpio0/gpio3 -> output mode
    pm1_bit_off(0x13, 1 | (1 << 3))              # gpio0/gpio3 -> push-pull
    pm1_bit_on(0x11, 1 | (1 << 3))               # gpio0/gpio3 -> output high
    pm1_write_reg(0x09, 0x00)                    # I2C idle sleep disable
    sleep_ms 100
  end

  private def reset
    @rst.write(1)
    sleep_ms 20
    @rst.write(0)
    sleep_ms 2
    @rst.write(1)
    sleep_ms 200
    busy_wait
  end

  # BUSY pin: LOW = busy, HIGH = idle
  private def busy_wait(timeout_ms = 20000)
    deadline = timeout_ms
    sleep_ms 10
    while @busy.read == 0 && deadline > 0
      sleep_ms 10
      deadline -= 10
    end
    sleep_ms 200 if deadline > 0
    deadline > 0
  end

  # Send command byte in its own CS transaction (DC=0).
  private def command(cmd)
    @dc.write(0)
    @cs.write(0)
    @spi.write(cmd)
    @cs.write(1)
  end

  # Send data bytes while keeping CS low across chunks (DC=1).
  private def send_data_chunked(data)
    @dc.write(1)
    @cs.write(0)
    i = 0
    while i < data.size
      chunk_size = (data.size - i) < 1024 ? (data.size - i) : 1024
      @spi.write(data[i, chunk_size]) # steep:ignore
      i += 1024
    end
    @cs.write(1)
  end

  private def init_display
    @cs.write(1)
    # Unlock + register init (from M5GFX Panel_ED2208 command list)
    command(CMDH); send_data_chunked("\x49\x55\x20\x08\x09\x18")
    command(0x01); send_data_chunked("\x3F")
    command(PSR);  send_data_chunked("\x5F\x69")
    command(0x05); send_data_chunked("\x40\x1F\x1F\x2C")
    command(0x08); send_data_chunked("\x6F\x1F\x1F\x22")
    command(0x06); send_data_chunked("\x6F\x1F\x17\x17")
    command(0x03); send_data_chunked("\x03\x54\x00\x44")
    command(0x60); send_data_chunked("\x02\x00")
    command(0x30); send_data_chunked("\x08")
    command(0x50); send_data_chunked("\x3F")
    command(0xE3); send_data_chunked("\x2F")
    command(0x84); send_data_chunked("\x01")
    # Resolution: width (MSB first) then height
    command(TRES)
    res = "\x00\x00\x00\x00"
    res.setbyte(0, (@width >> 8) & 0xFF)
    res.setbyte(1, @width & 0xFF)
    res.setbyte(2, (@height >> 8) & 0xFF)
    res.setbyte(3, @height & 0xFF)
    send_data_chunked(res)
  end

  private def _exec_transfer(frame)
    command(DTM)
    send_data_chunked(frame)
  end

  private def _turn_on_display
    command(PON)
    busy_wait
    sleep_ms 200

    command(BTST); send_data_chunked("\x6F\x1F\x17\x27")
    sleep_ms 200

    command(DRF); send_data_chunked("\x00")
    busy_wait

    command(POF); send_data_chunked("\x00")
    busy_wait
    sleep_ms 200
  end
end
