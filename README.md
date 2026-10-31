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
├── gen_assets.rb          # アバター → 4bpp 6色ディザ / QR → 1bit (base64)
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
ruby gen_assets.rb               # アバター (4bpp 6色 FSディザ) / QR ビットマップ生成
ruby gen_font.rb                 # Terminus フォントデータ生成
ruby src/gen_bundle.rb           # バンドル生成
(cd www && python3 -m http.server 8642)
# ブラウザで http://localhost:8642 — 仮想 e-paper に描画される
# "BtnA (GPIO 10) — rotate" ボタンで縦横切替
```

`epd_emulator.js` が SPI/GPIO/I2C を横取りし、ED2208 のプロトコル
(0x10 フレーム転送 → 0x12 リフレッシュ) をパースして Canvas に描画する。

### 実機 (M5PaperColor) へのビルド & フラッシュ

**前提**

- ESP-IDF **v5.5.4** (`~/.espressif/v5.5.4/esp-idf`) — v6.0.1 は picoruby 側が非対応 (mbedtls API 変更 / `soc/i2c_periph.h` 移動)
- Ruby 3.4 (host mruby / mrbc ビルド用)。Ruby 4.0 は native gem のビルドに失敗する
- 実機 (M5PaperColor) を USB 接続 (例: `/dev/cu.usbmodem101`)

```sh
# 0. アセット & バンドル生成
#    - アバター → 4bpp カラーパレットビットマップ (6色, Floyd-Steinberg ディザ)
#    - QR → 1bit ビットマップ
#    - Terminus フォントデータ
#    - storage/home/app.rb (名刺アプリのデバイスバンドル)
ruby emulator/gen_assets.rb
ruby emulator/gen_font.rb
ruby emulator/src/gen_bundle.rb

# 1. ESP-IDF 環境 (v5.5.4)
cd picoruby/R2P2-ESP32
source ~/.espressif/v5.5.4/esp-idf/export.sh

# 2. 環境変数 (必須)
#    SDKCONFIG_DEFAULTS : PaperColor 用ボード設定 (esp32s3 / 16MB flash / OPI PSRAM)
#    CC                 : int32 mrbc をホストコンパイラでビルドするため
#                         (未指定だと esp-clang が拾われ RISC-V ELF になる)
#    PICORB_TASK_STACK_SIZE : app.rb のコンパイルで 8KB (デフォルト) では
#                         スタック不足になるため 32KB に
export SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfigs/m5stack_papercolor"
export CC=/usr/bin/clang
export PICORB_TASK_STACK_SIZE=32768

# 3. 初回セットアップのみ (sdkconfig 生成 + host mruby ビルド)
rake setup_papercolor

# 4. ビルド & フラッシュ (app.rb は storage.bin に焼かれる)
rake picoruby:build
idf.py -p /dev/cu.usbmodem101 flash

# 5. モニタ (終了は Ctrl-])
idf.py -p /dev/cu.usbmodem101 monitor
```

**Tips**

- **`.rb` を編集したのに反映されない**場合: gem mrblib の増分ビルドが効かないことがあるので
  `rm -rf components/picoruby-esp32/picoruby/build/esp32-picoruby` してから再ビルド
- アセット (画像/QR/フォント) を変えた場合のみ `emulator/gen_*.rb` と `emulator/src/gen_bundle.rb` を再実行
- フラッシュ後のシリアルログで `Loading app.rb` の後エラーがなければ正常。
  e-paper のリフレッシュには 15 秒前後かかる
- BtnA (GPIO 10) で縦横切替。横表示はデバイスを横向きに持って読む向き

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
