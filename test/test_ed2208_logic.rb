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

puts "All tests passed."
