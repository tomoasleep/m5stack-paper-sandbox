# e6paper-sandbox

M5PaperColor 用のサンドボックス。名刺カードアプリを 2 形態で提供:

1. **Arduino + M5Unified** (`src/main.cpp`, PlatformIO) — オリジナル実装
2. **PicoRuby** (`picoruby/`, `emulator/`) — R2P2-ESP32 上で動く Ruby 版

## PicoRuby 版

### 構成

```
picoruby/
├── R2P2-ESP32/            # git submodule (ビルド基盤 + PicoRuby shell)
└── picoruby-ed2208/       # ED2208-DOA (M5PaperColor e-paper) ドライバ gem
    ├── mrbgem.rake
    ├── mrblib/ed2208.rb   # 純 Ruby ドライバ
    ├── sig/ed2208.rbs
    └── README.md
picoruby/app.rb            # 名刺アプリ (実機・エミュレータ共通)
emulator/                  # WASM エミュレーション環境
├── gen_assets.rb          # アバター/QR → 1bit ビットマップ (base64)
├── gen_font.rb            # Terminus BDF → Ruby glyph データ
├── src/stubs.rb           # GPIO/SPI/I2C/VRAM/BDFFont の Ruby 実装
├── src/gen_bundle.rb      # www/app_bundle.rb 生成
└── www/                   # index.html + epd_emulator.js + 生成物
test/
└── test_ed2208_logic.rb   # 変換ロジックのホストテスト
```

### WASM でローカル実行 (実機なしで検証)

```sh
cd emulator
npm install                      # @picoruby/wasm-wasi
ruby gen_assets.rb               # アバター/QR ビットマップ生成
ruby gen_font.rb                 # Terminus フォントデータ生成
ruby src/gen_bundle.rb           # バンドル生成
(cd www && python3 -m http.server 8642)
# ブラウザで http://localhost:8642 — 仮想 e-paper に描画される
# "BtnA (GPIO 10) — rotate" ボタンで縦横切替
```

`epd_emulator.js` が SPI/GPIO/I2C を横取りし、ED2208 のプロトコル
(0x10 フレーム転送 → 0x12 リフレッシュ) をパースして Canvas に描画する。

### 実機 (M5PaperColor) への書き込み

TODO: R2P2-ESP32 に esp32s3 + 16MB flash + OPI PSRAM の sdkconfig を追加し、
`storage/home/app.rb` として app.rb を焼く。ED2208 ドライバは gembox に
`picoruby-ed2208` を追加してビルドする。

### ハードウェアメモ (M5PaperColor)

- ESP32-S3R8 / 16MB flash / 8MB OPI PSRAM
- 4" E Ink Spectra 6 **ED2208-DOA** 400x600 (4bpp)
- SPI: CLK=G15, MOSI=G13, CS=G44, DC=G43, RST=G12, BUSY=G11 (4MHz)
- M5PM1 PMIC (I2C 0x6E @ G3/G2): GPIO0 = EPD 電源 enable
- ボタン: G10/G9/G1 (active low)

## Arduino 版 (オリジナル)

```sh
pio run -e m5stack-papercolor -t upload
```
