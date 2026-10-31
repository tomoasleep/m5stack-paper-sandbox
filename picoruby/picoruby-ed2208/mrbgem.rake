MRuby::Gem::Specification.new('picoruby-ed2208') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Tomoya Chiba'
  spec.summary = 'E Ink ED2208-DOA (M5PaperColor) e-paper driver'

  spec.add_dependency 'picoruby-spi', default: true
  spec.add_dependency 'picoruby-gpio', default: true
  spec.add_dependency 'picoruby-i2c', default: true
  spec.add_dependency 'picoruby-vram', default: true
  spec.add_dependency 'picoruby-bdffont', default: true
end
