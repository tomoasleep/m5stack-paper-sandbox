// ED2208-DOA (M5PaperColor) virtual panel emulator.
// Bridges Ruby stubs (emulator/src/stubs.rb) to a <canvas> that renders
// the 4bpp frame the driver would send over SPI to the real panel.
//
// Hooks called from Ruby via JS.global:
//   __epd_gpio_init(pin, dir)
//   __epd_gpio_write(pin, v)          // records DC/CS/RST pin states
//   __epd_gpio_read(pin)              // BUSY -> 1 (idle), BtnA -> UI state
//   __epd_spi_init(unit, frequency)
//   __epd_spi_write(hexString)        // hex-encoded bytes; DC decides cmd/data
//   __epd_i2c_write(addr, reg, val)   // M5PM1 register writes (logged)

const EPD = {
  W: 400,
  H: 600,
  PIN_DC: 43,
  PIN_CS: 44,
  PIN_RST: 12,
  PIN_BUSY: 11,
  PIN_BTN_A: 10,
};

const EPD_COLORS = {
  0: [0, 0, 0], // BLACK
  1: [255, 255, 255], // WHITE
  2: [255, 243, 56], // YELLOW
  3: [191, 0, 0], // RED
  5: [100, 64, 255], // BLUE
  6: [67, 138, 28], // GREEN
};

const CMD_NAMES = {
  0xAA: "CMDH (unlock)",
  0x00: "PSR (panel setting)",
  0x01: "PWR (power setting)",
  0x02: "POF (power off)",
  0x04: "PON (power on)",
  0x05: "CDI",
  0x06: "BTST (booster)",
  0x07: "DSLP (deep sleep)",
  0x08: "TCON",
  0x03: "PFS",
  0x0A: "M5PM1 WDT (via I2C)",
  0x30: "PLL?",
  0x50: "VCOM?",
  0x60: "TCON?",
  0x10: "DTM (frame data)",
  0x12: "DRF (refresh)",
  0x61: "TRES (resolution)",
  0xE3: "?",
  0x84: "?",
};

let gpioState = {}; // pin -> last written value
let pendingCommand = null;
let frameBuffer = new Uint8Array((EPD.W * EPD.H) / 2);
let framePos = 0;
let cmdLog = [];
let i2cLog = [];

function hexToBytes(hex) {
  const n = hex.length / 2;
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function toBytes(value) {
  // Ruby Integer auto-converts to JS number; arrays to JS Array.
  if (typeof value === "number") return new Uint8Array([value & 0xFF]);
  if (Array.isArray(value)) return new Uint8Array(value.map((v) => v & 0xFF));
  if (typeof value === "string") return hexToBytes(value);
  return new Uint8Array();
}

function log(line) {
  const el = document.getElementById("log");
  if (!el) return;
  cmdLog.push(line);
  if (cmdLog.length > 300) cmdLog.shift();
  el.textContent = cmdLog.join("\n");
  el.scrollTop = el.scrollHeight;
}

function logI2c(line) {
  i2cLog.push(line);
  if (i2cLog.length > 60) i2cLog.shift();
  const el = document.getElementById("i2clog");
  if (el) el.textContent = i2cLog.join("\n");
}

// --- GPIO bridge ---

window.__epd_gpio_init = function (pin, dir) {
  log(`GPIO init pin=${pin} dir=${dir === 1 ? "OUT" : "IN"}`);
};

window.__epd_gpio_write = function (pin, v) {
  gpioState[pin] = v;
  if (pin === EPD.PIN_RST) log(`RST -> ${v}`);
};

window.__epd_gpio_read = function (pin) {
  if (pin === EPD.PIN_BUSY) return 1; // always idle in emulation
  if (pin === EPD.PIN_BTN_A) return window.__epd_btn_a_pressed ? 0 : 1;
  return gpioState[pin] ?? 1;
};

// --- SPI bridge ---

window.__epd_spi_init = function (unit, frequency) {
  log(`SPI init ${unit} @ ${frequency} Hz`);
};

window.__epd_spi_write = function (hex) {
  const bytes = typeof hex === "string" ? hexToBytes(hex) : toBytes(hex);
  const dc = gpioState[EPD.PIN_DC] ?? 1;
  if (dc === 0) {
    // command
    pendingCommand = bytes[0];
    const name = CMD_NAMES[pendingCommand] ?? "";
    log(`CMD 0x${pendingCommand.toString(16).padStart(2, "0")} ${name}`);
    if (pendingCommand === 0x10) {
      framePos = 0; // restart frame accumulation
      log(`  frame transfer started (${bytes.length} data bytes expected next)`);
    }
  } else {
    // data
    if (pendingCommand === 0x10) {
      frameBuffer.set(bytes, framePos);
      framePos += bytes.length;
    } else if (pendingCommand === 0x12) {
      if (framePos > 0) {
        render();
        log(`  REFRESH: rendered ${framePos * 2} px (frame bytes: ${framePos})`);
      }
    } else if (pendingCommand === 0x61) {
      const w = (bytes[0] << 8) | bytes[1];
      const h = (bytes[2] << 8) | bytes[3];
      log(`  resolution: ${w}x${h}`);
    } else {
      log(`  data: ${Array.from(bytes.slice(0, 8)).map((b) => "0x" + b.toString(16).padStart(2, "0")).join(" ")}${bytes.length > 8 ? " ..." : ""}`);
    }
  }
};

// --- I2C bridge (M5PM1) ---

window.__epd_i2c_write = function (addr, reg, val) {
  logI2c(`M5PM1 reg 0x${reg.toString(16).padStart(2, "0")} <- 0x${val.toString(16).padStart(2, "0")} (addr 0x${addr.toString(16)})`);
  if (reg === 0x11 && (val & 1) === 1) log(">> EPD power enabled (M5PM1 GPIO0 high)");
};

// --- Rendering ---

function render() {
  const canvas = document.getElementById("epd");
  if (!canvas) return;
  const ctx = canvas.getContext("2d");
  const img = ctx.createImageData(EPD.W, EPD.H);
  const d = img.data;
  for (let i = 0; i < frameBuffer.length; i++) {
    const b = frameBuffer[i];
    const x = (i % (EPD.W / 2)) * 2;
    const y = Math.floor(i / (EPD.W / 2));
    paintPixel(d, x, y, b >> 4);
    paintPixel(d, x + 1, y, b & 0x0F);
  }
  ctx.putImageData(img, 0, 0);
  document.getElementById("status").textContent =
    `last refresh: ${new Date().toLocaleTimeString()} — ${framePos * 2} px`;
}

function paintPixel(d, x, y, colorIndex) {
  const c = EPD_COLORS[colorIndex] ?? EPD_COLORS[1];
  const off = (y * EPD.W + x) * 4;
  d[off] = c[0];
  d[off + 1] = c[1];
  d[off + 2] = c[2];
  d[off + 3] = 255;
}
