# Host-side test for the pure conversion logic in picoruby-ed2208
# Run: ruby test/test_ed2208_logic.rb
# The driver file requires R2P2 gems (spi/gpio/...), so strip those
# lines and eval the source. Pure functions don't need the gems.

src = File.read(File.expand_path("../picoruby/picoruby-ed2208/mrblib/ed2208.rb", __dir__))
src = src.split("\n").reject { |l| l =~ /^require / }.join("\n")

# Minimal stubs so the class body evaluates; pure functions don't use them.
module VRAM
  module Delegatable; end
end
module BDFFont
  def self.setup(_klass); end
end
Object.module_eval(src)

def assert_eq(actual, expected, label)
  if actual == expected
    puts "PASS #{label}"
  else
    puts "FAIL #{label}"
    puts "  expected: #{expected.inspect}"
    puts "  actual:   #{actual.inspect}"
    exit 1
  end
end

# --- build_4bpp_table ---
t = ED2208.build_4bpp_table
assert_eq(t.size, 256, "table size")
assert_eq(t[0xFF], ("\x00" * 4).b, "0xFF -> 8 ink nibbles (4 bytes)")
assert_eq(t[0x00], ("\x11" * 4).b, "0x00 -> 8 paper nibbles (4 bytes)")
assert_eq(t[0xAA], ("\x01" * 4).b, "0xAA alternates")

t_black_paper = ED2208.build_4bpp_table(ED2208::BLACK, ED2208::BLACK)
assert_eq(t_black_paper[0x00], ("\x00" * 4).b, "all-black paper maps clear -> 0x0")

t_custom = ED2208.build_4bpp_table(ED2208::RED, ED2208::WHITE)
assert_eq(t_custom[0xFF], ("\x33" * 4).b, "custom ink maps 1 -> 0x3")

# --- convert_1bpp_to_4bpp ---
# (Host Ruby needs explicit binary encoding; mruby strings are raw bytes.)

# Single row of 8 px: leftmost pixel ink, rest paper
row = "\x80".b
frame = ED2208.convert_1bpp_to_4bpp(row, 8)
assert_eq(frame, "\x01\x11\x11\x11".b, "8px row, leftmost ink")

# Two ink pixels at the right end
frame = ED2208.convert_1bpp_to_4bpp("\x03".b, 8)
assert_eq(frame, "\x11\x11\x11\x00".b, "8px row, rightmost two ink")

# Full ink row of 8 px
frame = ED2208.convert_1bpp_to_4bpp("\xFF".b, 8)
assert_eq(frame, "\x00\x00\x00\x00".b, "8px row all ink")

# 400-wide row: 50 input bytes -> 200 output bytes
row400 = ("\xFF" * 50).b
frame = ED2208.convert_1bpp_to_4bpp(row400, 400)
assert_eq(frame.size, 200, "400px row size")
assert_eq(frame, ("\x00" * 200).b, "400px row all ink")

# Two rows: row0 all paper, row1 all ink (width 8)
frame = ED2208.convert_1bpp_to_4bpp("\xFF\x00".b, 8)
assert_eq(frame, ("\x00" * 4 + "\x11" * 4).b, "two rows preserved")

# Round-trip sanity: alternating pattern
frame = ED2208.convert_1bpp_to_4bpp(("\xAA" * 50).b, 400)
expected = ("\x01" * 200).b
assert_eq(frame, expected, "400px alternating checker")

# --- blit_4bpp_to_frame ---
# Overlays a 4bpp color-index bitmap (hi nibble = left pixel) onto a 4bpp
# frame in panel layout, mapping logical coords through the rotation.
# Only pixels covered by the bitmap are replaced (overlay semantics).

# rotation 0: 2px bitmap [1, 0] at (0,0) onto all-paper frame
frame = ("\x11" * 8).b
ED2208.blit_4bpp_to_frame(frame, "\x10".b, 0, 0, 2, 1, 8, 2, 0)
assert_eq(frame, ("\x10" + "\x11" * 7).b, "blit rot0 overwrites covered pixels only")

# rotation 0: 4px bitmap [2,1,0,1]
frame = ("\x11" * 8).b
ED2208.blit_4bpp_to_frame(frame, "\x21".b + "\x01".b, 0, 0, 4, 1, 8, 2, 0)
assert_eq(frame, ("\x21\x01" + "\x11" * 6).b, "blit rot0 4px nibble packing")

# rotation 0: odd-width bitmap leaves trailing nibble untouched
frame = ("\x11" * 8).b
ED2208.blit_4bpp_to_frame(frame, "\x10".b + "\x20".b, 0, 0, 3, 1, 8, 2, 0)
assert_eq(frame, ("\x10\x21" + "\x11" * 6).b, "blit rot0 odd width keeps base nibble")

# rotation 90: logical (x,y) -> panel (y, disp_w-1-x); frame width = disp_h
# disp 4x4 -> panel 4x4, stride 2, 8 bytes. Base all-black so writes show.
# 2x2 bitmap: row0 = [1,0] -> 0x10, row1 = [0,2] -> 0x02
frame = ("\x00" * 8).b
ED2208.blit_4bpp_to_frame(frame, "\x10\x02".b, 0, 0, 2, 2, 4, 4, 90)
# (0,0)=1 -> panel (0,3) byte6 hi | (1,0)=0 -> (0,2) byte4 hi
# (0,1)=0 -> panel (1,3) byte6 lo | (1,1)=2 -> (1,2) byte4 lo
assert_eq(frame, ("\x00" * 4 + "\x02\x00\x10\x00").b, "blit rot90 transposed")

# rotation 180: logical (x,y) -> panel (disp_w-1-x, disp_h-1-y)
frame = ("\x00" * 8).b
ED2208.blit_4bpp_to_frame(frame, "\x10\x02".b, 0, 0, 2, 2, 4, 4, 180)
# (0,0)=1 -> (3,3) byte7 lo | (1,0)=0 -> (2,3) byte7 hi
# (0,1)=0 -> (3,2) byte5 lo | (1,1)=2 -> (2,2) byte5 hi
assert_eq(frame, ("\x00" * 5 + "\x20\x00\x01").b, "blit rot180 mirrored")

# rotation 270: logical (x,y) -> panel (disp_h-1-y, x)
frame = ("\x00" * 8).b
ED2208.blit_4bpp_to_frame(frame, "\x10\x02".b, 0, 0, 2, 2, 4, 4, 270)
# (0,0)=1 -> (3,0) byte1 lo | (1,0)=0 -> (3,1) byte3 lo
# (0,1)=0 -> (2,0) byte1 hi | (1,1)=2 -> (2,1) byte3 hi
assert_eq(frame, ("\x00\x01\x00\x20" + "\x00" * 4).b, "blit rot270 transposed other way")

# clipping: bitmap partially outside logical area is safely ignored
frame = ("\x11" * 8).b
ED2208.blit_4bpp_to_frame(frame, "\x21\x30".b, -2, 0, 4, 1, 8, 2, 0)
# colors [2,1,3,0] at x=-2: (-2),(-1) clipped; (0,0)=3 -> hi nib, (1,0)=0 -> lo nib
assert_eq(frame, ("\x30" + "\x11" * 7).b, "blit clips out-of-bounds pixels")

# offset placement: (4,1)=3, (5,1)=0 -> byte row1(+4) + bx4/2=2 -> frame[6] = 0x30
frame = ("\x11" * 8).b
ED2208.blit_4bpp_to_frame(frame, "\x30".b, 4, 1, 2, 1, 8, 2, 0)
assert_eq(frame, ("\x11" * 6 + "\x30" + "\x11").b, "blit at offset (4,1)")

puts "All tests passed."
