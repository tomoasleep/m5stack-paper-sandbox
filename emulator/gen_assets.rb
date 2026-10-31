#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate assets for the e6paper PicoRuby port.
# Outputs Ruby string literals (raw byte strings, base64-encoded) into
# emulator/www/assets.rb
#
# - avatar: include/avatar_png.h -> 4bpp color-index bitmap on the 6-color
#           ED2208 palette (Floyd-Steinberg dithered, hi nibble = left px)
# - QR:     Qiita URL, version 4, ECC_LOW, 3x module scale (99x99), 1-bit

require "chunky_png"
require "rqrcode"
require "zlib"

ROOT = File.expand_path("..", __dir__)
OUT = File.join(ROOT, "emulator", "www", "assets.rb")

def extract_avatar_png
  src = File.read(File.join(ROOT, "include", "avatar_png.h"))
  m = src.match(/avatar_png\s*PROGMEM\[\]\s*=\s*\{(.*?)\};/m)
  raise "avatar_png[] not found in avatar_png.h" unless m
  bytes = m[1].scan(/0x[0-9a-fA-F]+/).map { |s| s.to_i(16) }.pack("C*")
  raise "PNG signature missing" unless bytes[0..7] == "\x89PNG\r\n\x1a\n".b
  bytes
end

def png_dimensions(png)
  # IHDR: width/height at offsets 16/20
  [png[16, 4].unpack1("N"), png[20, 4].unpack1("N")]
end

# Minimal PNG decoder for 8-bit RGB/RGBA non-interlaced images (sufficient
# for the avatar asset) using zlib inflate + standard per-row filters.
def decode_png(png)
  width = png[16, 4].unpack1("N")
  height = png[20, 4].unpack1("N")
  color_type = png[25]

  idat = String.new
  pos = 8
  while pos < png.size
    len = png[pos, 4].unpack1("N")
    type = png[pos + 4, 4]
    idat << png[pos + 8, len] if type == "IDAT"
    pos += 12 + len
  end

  channels = color_type == 6 ? 4 : 3
  bpp = channels
  stride = width * bpp
  raw = Zlib::Inflate.inflate(idat)
  rows = []
  prev = Array.new(stride, 0)
  off = 0
  height.times do
    filter = raw[off].ord
    line = raw[off + 1, stride].bytes
    off += 1 + stride
    line.each_with_index do |b, x|
      a = x >= bpp ? line[x - bpp] : 0
      b_prev = prev[x]
      c = x >= bpp ? prev[x - bpp] : 0
      v =
        case filter
        when 0 then b
        when 1 then (b + a) & 0xFF
        when 2 then (b + b_prev) & 0xFF
        when 3 then (b + ((a + b_prev) / 2)) & 0xFF
        when 4
          p = a + b_prev - c
          pa = (p - a).abs
          pb = (p - b_prev).abs
          pc = (p - c).abs
          (b + (pa <= pb && pa <= pc ? a : pb <= pc ? b_prev : c)) & 0xFF
        else raise "bad filter #{filter}"
        end
      line[x] = v
    end
    rows << line
    prev = line
  end
  [width, height, rows, channels]
end

def bitmap_1bit(width, height, &pixel_at)
  row_bytes = (width + 7) / 8
  data = Array.new(height * row_bytes, 0)
  height.times do |y|
    width.times do |x|
      next unless pixel_at.call(x, y)
      data[y * row_bytes + x / 8] |= 0x80 >> (x % 8)
    end
  end
  data.pack("C*")
end

# Output byte arrays as Base64 string literals: raw \xNN escapes are
# invalid UTF-8 and break under MRB_UTF8_STRING when calling String#ord.
require "base64"

# Pure-Ruby base64 decoder shared by device and emulator (no gem dependency).
# Uses getbyte/setbyte because decoded bytes may be invalid UTF-8.
B64_HELPER = <<~'RUBY'
  def _decode_b64(s)
    table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    bytes = []
    i = 0
    n = s.size
    while i < n
      c0 = table.index(s[i])
      break if c0.nil?
      c1 = i + 1 < n ? table.index(s[i + 1]) : nil
      c2 = i + 2 < n ? table.index(s[i + 2]) : nil
      c3 = i + 3 < n ? table.index(s[i + 3]) : nil
      if c1 && c2 && c3
        bytes << ((c0 << 2) | (c1 >> 4))
        bytes << (((c1 & 0xF) << 4) | (c2 >> 2))
        bytes << (((c2 & 0x3) << 6) | c3)
        i += 4
      elsif c1 && c2
        bytes << ((c0 << 2) | (c1 >> 4))
        bytes << (((c1 & 0xF) << 4) | (c2 >> 2))
        i += 3
      elsif c1
        bytes << ((c0 << 2) | (c1 >> 4))
        i += 2
      else
        i += 1
      end
    end
    out = "\x00" * bytes.size
    j = 0
    while j < bytes.size
      out.setbyte(j, bytes[j])
      j += 1
    end
    out
  end
RUBY

# --- Avatar ---
png = extract_avatar_png
w, h, rows, ch = decode_png(png)
puts "avatar PNG: #{w}x#{h}, color_type channels=#{ch}"

# --- 6-color EPD palette (panel native 4bpp indices, same values as M5GFX) ---
EPD_PALETTE = [
  [0, 0, 0, 0],       # BLACK  -> 0
  [255, 255, 255, 1], # WHITE  -> 1
  [255, 243, 56, 2],  # YELLOW -> 2
  [191, 0, 0, 3],     # RED    -> 3
  [100, 64, 255, 5],  # BLUE   -> 5
  [67, 138, 28, 6],   # GREEN  -> 6
]
PALETTE_MAP = EPD_PALETTE.each_with_object({}) { |(r, g, b, i), m| m[i] = [r, g, b] }

def nearest_index(r, g, b)
  best = 1
  min = Float::INFINITY
  EPD_PALETTE.each do |pr, pg, pb, i|
    d = (r - pr)**2 + (g - pg)**2 + (b - pb)**2
    if d < min
      min = d
      best = i
    end
  end
  best
end

# Floyd-Steinberg error diffusion with serpentine scan.
# Returns per-pixel palette indices (row-major Array of Arrays).
def dither_fs(width, height, src, channels)
  buf = Array.new(height) do |y|
    Array.new(width) do |x|
      [src[y][x * channels].to_f, src[y][x * channels + 1].to_f, src[y][x * channels + 2].to_f]
    end
  end
  out = Array.new(height) { Array.new(width, 1) }
  height.times do |y|
    ltr = y.even?
    x = ltr ? 0 : width - 1
    while x >= 0 && x < width
      r = buf[y][x][0].clamp(0, 255)
      g = buf[y][x][1].clamp(0, 255)
      b = buf[y][x][2].clamp(0, 255)
      idx = nearest_index(r.round, g.round, b.round)
      out[y][x] = idx
      pr, pg, pb = PALETTE_MAP[idx]
      er = r - pr
      eg = g - pg
      eb = b - pb
      fwd = ltr ? 1 : -1
      [[0, fwd, 7], [1, -fwd, 3], [1, 0, 5], [1, fwd, 1]].each do |dy, dx, wt|
        ny = y + dy
        nx = x + dx * fwd
        next if nx < 0 || nx >= width || ny >= height
        buf[ny][nx][0] += er * wt / 16.0
        buf[ny][nx][1] += eg * wt / 16.0
        buf[ny][nx][2] += eb * wt / 16.0
      end
      x += fwd
    end
  end
  out
end

# Pack palette indices into 4bpp rows: 2px/byte, hi nibble = left pixel.
def pack_4bpp(indices, width, height)
  row_bytes = (width + 1) / 2
  data = Array.new(height * row_bytes, 0)
  height.times do |y|
    width.times do |x|
      i = y * row_bytes + x / 2
      data[i] |= (indices[y][x] & 0x0F) << (x.odd? ? 0 : 4)
    end
  end
  data.pack("C*")
end

avatar_idx = dither_fs(w, h, rows, ch)
avatar_4bpp = pack_4bpp(avatar_idx, w, h)
puts "avatar 4bpp: #{avatar_4bpp.size} bytes (row=#{(w + 1) / 2})"

# Preview PNG (1:1 palette render) for visual inspection
require "chunky_png"
preview = ChunkyPNG::Image.new(w, h)
h.times do |y|
  w.times do |x|
    r, g, b = PALETTE_MAP[avatar_idx[y][x]]
    preview[x, y] = ChunkyPNG::Color.rgb(r, g, b)
  end
end
preview.save(File.expand_path("tmp/avatar_4bpp_preview.png", __dir__))

# --- QR code (version 4, ECC LOW, scale 3) ---
url = "https://qiita.com/tomoasleep"
qrcode = RQRCode::QRCode.new(url, size: 4, level: :l)
modules = qrcode.modules.size
scale = 3
size = modules * scale
qr = bitmap_1bit(size, size) do |x, y|
  qrcode.modules[y / scale][x / scale]
end
puts "QR bitmap: #{qr.size} bytes (#{size}x#{size}, modules=#{modules})"

File.binwrite(File.expand_path("tmp/qr_qiita_1bpp.bin", __dir__), qr)

File.write(OUT, <<~RUBY)
  # Generated by emulator/gen_assets.rb -- do not edit manually.
  # QR: 1-bit bitmap, avatar: 4bpp color-index bitmap (6-color EPD palette,
  # Floyd-Steinberg dithered), horizontal packing, hi nibble = left pixel.
  # Stored as Base64 literals: byte-escaped literals would be invalid UTF-8.

  #{B64_HELPER}

  AVATAR_4BPP_B64 = "#{Base64.strict_encode64(avatar_4bpp)}"
  AVATAR_W = #{w}
  AVATAR_H = #{h}
  AVATAR_4BPP = _decode_b64(AVATAR_4BPP_B64)

  QR_QIITA_1BPP_B64 = "#{Base64.strict_encode64(qr)}"
  QR_QIITA_W = #{size}
  QR_QIITA_H = #{size}
  QR_QIITA_1BPP = _decode_b64(QR_QIITA_1BPP_B64)
RUBY
puts "wrote #{OUT}"
