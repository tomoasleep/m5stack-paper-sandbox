# Pure-Ruby Terminus font rendering (mirrors picoruby-bdffont's contract).
# Used by both the WASM emulator and the device bundle; when the real
# picoruby-terminus gem is loaded its module is simply opened again and the
# C-backed draw_terminus takes precedence.

module BDFFont
  def self.setup(_klass); end

  module Drawable
    # result: [height, total_width, widths, glyphs]
    # widths/glyphs are split in 32px chunks when a glyph is wider.
    def bdffont_draw_result(result, x, y)
      height = result[0]
      widths = result[2]
      glyphs = result[3]
      glyph_x = x
      i = 0
      while i < widths.size
        draw_bitmap(x: glyph_x, y: y, w: widths[i], h: height, data: glyphs[i])
        glyph_x += widths[i]
        i += 1
      end
      nil
    end

    def draw_text(fontname, x, y, text, scale = 1)
      font, name = fontname.to_s.split("_")
      if font == "terminus"
        draw_terminus(name, x, y, text, scale)
      else
        puts "Unsupported font: #{font}"
      end
      nil
    end
  end
end

module Terminus
  # Returns [scaled_h, total_width, widths, glyphs]; glyphs are
  # Arrays of Integer rows (bit w-1-x = pixel x), scale 1 only.
  def self.render(name, text, scale = 1)
    spec = TERMINUS_DATA[name]
    raise "Unknown terminus font: #{name}" unless spec
    w = spec[:w]
    h = spec[:h]
    glyphs = spec[:glyphs]
    widths = []
    glyphs_out = []
    total = 0
    i = 0
    n = text.size
    while i < n
      cp = text.getbyte(i)
      rows = glyphs[cp] || Array.new(h, 0)
      widths << w
      glyphs_out << rows
      total += w
      i += 1
    end
    [h, total, widths, glyphs_out]
  end

  module Drawable
    def draw_terminus(name, x, y, text, scale = 1)
      bdffont_draw_result(Terminus.render(name, text, scale), x, y)
    end
  end
end
