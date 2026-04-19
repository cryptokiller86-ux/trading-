'use strict';

// ── State ────────────────────────────────────────────────────────────────────
const charts     = {};
const candleSeries = {};
const lineSeries   = {};
const prevPrices   = {};

// ── Init charts ──────────────────────────────────────────────────────────────
function initChart(assetKey) {
  const container = document.getElementById(`chart-${assetKey}`);
  if (!container) return;

  const chart = LightweightCharts.createChart(container, {
    layout: {
      background: { color: '#111621' },
      textColor:  '#6b7a99',
    },
    grid: {
      vertLines: { color: '#1e2a3d' },
      horzLines:  { color: '#1e2a3d' },
    },
    crosshair: {
      mode: LightweightCharts.CrosshairMode.Normal,
    },
    rightPriceScale: {
      borderColor: '#1e2a3d',
      scaleMargins: { top: 0.1, bottom: 0.1 },
    },
    timeScale: {
      borderColor: '#1e2a3d',
      timeVisible: true,
      secondsVisible: false,
    },
    handleScroll: true,
    handleScale:  true,
  });

  const cs = chart.addCandlestickSeries({
    upColor:          '#00d68f',
    downColor:        '#ff4d6d',
    borderUpColor:    '#00d68f',
    borderDownColor:  '#ff4d6d',
    wickUpColor:      '#00d68f',
    wickDownColor:    '#ff4d6d',
  });

  // EMA lines
  const ema9Line  = chart.addLineSeries({ color: '#f5c842',  lineWidth: 1, title: 'EMA9' });
  const ema21Line = chart.addLineSeries({ color: '#5b9df5',  lineWidth: 1, title: 'EMA21' });
  const ema50Line = chart.addLineSeries({ color: '#f7931a',  lineWidth: 1, title: 'EMA50' });

  charts[assetKey]      = chart;
  candleSeries[assetKey] = cs;
  lineSeries[assetKey]   = { ema9: ema9Line, ema21: ema21Line, ema50: ema50Line };

  // Responsive resize
  const resizeObs = new ResizeObserver(() => {
    chart.applyOptions({ width: container.clientWidth });
  });
  resizeObs.observe(container);
}

// ── Update chart ─────────────────────────────────────────────────────────────
function updateChart(assetKey, signal) {
  if (!charts[assetKey] || !signal.history || !signal.history.length) return;

  const cs   = candleSeries[assetKey];
  const lines = lineSeries[assetKey];
  const inds  = signal.indicators;

  // Candle data
  const candles = signal.history.map(h => ({
    time:  h.time,
    open:  h.open,
    high:  h.high,
    low:   h.low,
    close: h.close,
  }));
  cs.setData(candles);

  // Build EMA arrays from the last candle (approximate for chart display)
  // We only have the last indicator values, so we approximate trend lines
  // by building smooth lines ending at current indicator values
  const n = candles.length;
  if (inds && n > 1) {
    const ema9Data  = buildEMALine(candles, inds.ema9, n);
    const ema21Data = buildEMALine(candles, inds.ema21, n);
    const ema50Data = buildEMALine(candles, inds.ema50, n);
    lines.ema9.setData(ema9Data);
    lines.ema21.setData(ema21Data);
    lines.ema50.setData(ema50Data);
  }

  // Draw SL/TP/Entry price lines
  drawPriceLines(assetKey, signal);

  // Fit to content
  charts[assetKey].timeScale().fitContent();
}

function buildEMALine(candles, endValue, n) {
  // Linear interpolation from ~midpoint to current value (approximation for display)
  if (!endValue || n < 2) return [];
  const midVal = candles[Math.floor(n * 0.4)]?.close || endValue;
  return candles.map((c, i) => ({
    time:  c.time,
    value: midVal + (endValue - midVal) * (i / (n - 1)),
  }));
}

function drawPriceLines(assetKey, signal) {
  const chart = charts[assetKey];
  if (!chart) return;

  const dir     = signal.direction;
  const isLong  = dir === 'BUY';
  const isShort = dir === 'SELL';
  const isActive = isLong || isShort;

  // Remove previous price lines
  if (charts[`${assetKey}_lines`]) {
    charts[`${assetKey}_lines`].forEach(l => {
      try { candleSeries[assetKey].removePriceLine(l); } catch(e) {}
    });
  }

  if (!isActive) { charts[`${assetKey}_lines`] = []; return; }

  const lines = [];

  const addLine = (price, color, title, style) => {
    const pl = candleSeries[assetKey].createPriceLine({
      price, color, lineWidth: 1,
      lineStyle: style || LightweightCharts.LineStyle.Dashed,
      axisLabelVisible: true,
      title,
    });
    lines.push(pl);
  };

  addLine(signal.entry, '#5b9df5',  '● ENTRÉE', LightweightCharts.LineStyle.Solid);
  addLine(signal.sl,    '#ff6b6b',  '✖ SL',     LightweightCharts.LineStyle.Dotted);
  addLine(signal.tp1,   '#00c9a7',  '✔ TP1',    LightweightCharts.LineStyle.Dashed);
  addLine(signal.tp2,   '#00d68f',  '✔ TP2',    LightweightCharts.LineStyle.Dashed);

  charts[`${assetKey}_lines`] = lines;
}

// ── Render signal card ────────────────────────────────────────────────────────
function renderSignal(assetKey, signal) {
  if (!signal || signal.error) {
    setError(assetKey, signal?.error || 'Erreur de chargement');
    return;
  }

  const dir      = signal.direction;
  const isBuy    = dir === 'BUY';
  const isSell   = dir === 'SELL';
  const dirClass = isBuy ? 'buy' : isSell ? 'sell' : 'neutral';

  // -- Price with change --
  const entry     = signal.entry;
  const prevPrice = prevPrices[assetKey];
  const priceEl   = document.getElementById(`price-${assetKey}`);
  const changeEl  = document.getElementById(`change-${assetKey}`);

  if (priceEl) {
    const formatted = formatPrice(assetKey, entry);
    if (priceEl.textContent !== formatted) {
      priceEl.textContent = formatted;
      priceEl.classList.add('flash');
      setTimeout(() => priceEl.classList.remove('flash'), 700);
    }
  }

  if (changeEl && prevPrice) {
    const diff = entry - prevPrice;
    const pct  = (diff / prevPrice * 100).toFixed(2);
    changeEl.textContent = `${diff >= 0 ? '+' : ''}${formatPrice(assetKey, diff)} (${diff >= 0 ? '+' : ''}${pct}%)`;
    changeEl.className   = `asset-change ${diff >= 0 ? 'up' : 'down'}`;
  }
  prevPrices[assetKey] = entry;

  // -- Signal banner --
  const banner   = document.getElementById(`signal-banner-${assetKey}`);
  const dirEl    = document.getElementById(`signal-dir-${assetKey}`);
  const strengthEl = document.getElementById(`signal-strength-${assetKey}`);
  const timeEl   = document.getElementById(`signal-time-${assetKey}`);

  if (banner)   { banner.className   = `signal-banner ${dirClass}`; }
  if (dirEl)    { dirEl.textContent  = dir === 'NEUTRAL' ? 'NEUTRE' : dir; dirEl.className = `signal-dir ${dirClass}`; }
  if (strengthEl) {
    const s = signal.strength?.toLowerCase().replace('é', 'e').replace('é', 'e') || '';
    const label = signal.strength || '';
    const cls   = s === 'fort' ? 'fort' : s.includes('mod') ? 'modere' : 'faible';
    strengthEl.textContent = label;
    strengthEl.className   = `signal-strength ${cls}`;
  }
  if (timeEl) {
    const d = new Date(signal.generated_at);
    timeEl.textContent = `Généré ${d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })} UTC`;
  }

  // -- Levels --
  setText(`entry-${assetKey}`, formatPrice(assetKey, signal.entry));
  setText(`sl-${assetKey}`,    formatPrice(assetKey, signal.sl));
  setText(`tp1-${assetKey}`,   formatPrice(assetKey, signal.tp1));
  setText(`tp2-${assetKey}`,   formatPrice(assetKey, signal.tp2));
  setText(`rr1-${assetKey}`,   `R/R 1:${signal.risk_reward_tp1}`);
  setText(`rr2-${assetKey}`,   `R/R 1:${signal.risk_reward_tp2}`);
  setText(`risk-${assetKey}`,  `Risque: ${formatPrice(assetKey, signal.risk_pips)}`);

  // -- Indicators --
  renderIndicators(assetKey, signal.indicators, dir);

  // -- Reasons --
  renderReasons(assetKey, signal.reasons, dir);

  // -- Chart --
  updateChart(assetKey, signal);
}

function renderIndicators(assetKey, ind, dir) {
  if (!ind) return;
  const container = document.getElementById(`indicators-${assetKey}`);
  if (!container) return;

  const isBuy  = dir === 'BUY';
  const isSell = dir === 'SELL';

  const items = [
    {
      label: 'RSI (14)',
      value: `${ind.rsi}`,
      barPct: ind.rsi,
      barColor: ind.rsi < 30 ? '#00d68f' : ind.rsi > 70 ? '#ff4d6d' : '#5b9df5',
      cls: ind.rsi < 40 ? 'bullish' : ind.rsi > 60 ? 'bearish' : 'neutral',
    },
    {
      label: 'Stoch RSI',
      value: `${ind.stoch_rsi}`,
      barPct: ind.stoch_rsi,
      barColor: ind.stoch_rsi < 20 ? '#00d68f' : ind.stoch_rsi > 80 ? '#ff4d6d' : '#5b9df5',
      cls: ind.stoch_rsi < 25 ? 'bullish' : ind.stoch_rsi > 75 ? 'bearish' : 'neutral',
    },
    {
      label: 'MACD Hist',
      value: `${ind.macd_hist > 0 ? '+' : ''}${ind.macd_hist}`,
      barPct: 50 + Math.min(Math.abs(ind.macd_hist / (Math.abs(ind.macd_hist) + 0.001)) * 50, 50) * (ind.macd_hist >= 0 ? 1 : -1),
      barColor: ind.macd_hist > 0 ? '#00d68f' : '#ff4d6d',
      cls: ind.macd_hist > 0 ? 'bullish' : 'bearish',
    },
    {
      label: 'Tendance',
      value: ind.trend,
      cls: ind.trend === 'HAUSSIER' ? 'bullish' : ind.trend === 'BAISSIER' ? 'bearish' : 'neutral',
    },
    {
      label: 'EMA 9/21',
      value: `${formatPrice(assetKey, ind.ema9)} / ${formatPrice(assetKey, ind.ema21)}`,
      cls: ind.ema9 > ind.ema21 ? 'bullish' : 'bearish',
    },
    {
      label: 'Volume',
      value: `x${ind.vol_ratio}`,
      barPct: Math.min(ind.vol_ratio * 40, 100),
      barColor: ind.vol_ratio > 1.5 ? '#f5c842' : '#3d4f6e',
      cls: ind.vol_ratio > 1.5 ? 'bullish' : 'neutral',
    },
    {
      label: 'BB Upper',
      value: formatPrice(assetKey, ind.bb_upper),
      cls: 'neutral',
    },
    {
      label: 'BB Lower',
      value: formatPrice(assetKey, ind.bb_lower),
      cls: 'neutral',
    },
    {
      label: 'ATR (14)',
      value: formatPrice(assetKey, ind.atr),
      cls: 'neutral',
    },
  ];

  container.innerHTML = items.map(item => `
    <div class="ind-item">
      <div class="ind-label">${item.label}</div>
      <div class="ind-value ${item.cls}">${item.value}</div>
      ${item.barPct != null ? `
        <div class="ind-bar">
          <div class="ind-bar-fill" style="width:${Math.min(Math.max(item.barPct, 0), 100)}%;background:${item.barColor}"></div>
        </div>` : ''}
    </div>
  `).join('');
}

function renderReasons(assetKey, reasons, dir) {
  const container = document.getElementById(`reasons-${assetKey}`);
  if (!container || !reasons || !reasons.length) return;

  const cls = dir === 'BUY' ? 'buy-reason' : dir === 'SELL' ? 'sell-reason' : '';

  container.innerHTML = `
    <div class="reasons-title">Raisons du signal (${reasons.length} confluences)</div>
    <div class="reason-list">
      ${reasons.map(r => `<div class="reason-item ${cls}">${r}</div>`).join('')}
    </div>
  `;
}

// ── Helpers ──────────────────────────────────────────────────────────────────
function formatPrice(assetKey, value) {
  if (value == null || isNaN(value)) return '--';
  if (assetKey === 'BTC') {
    return new Intl.NumberFormat('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value) + ' $';
  }
  return new Intl.NumberFormat('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value) + ' $';
}

function setText(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}

function setError(assetKey, msg) {
  const dirEl = document.getElementById(`signal-dir-${assetKey}`);
  if (dirEl) { dirEl.textContent = 'ERREUR'; dirEl.className = 'signal-dir neutral'; }
  console.error(`[${assetKey}] ${msg}`);
}

// ── Force refresh ─────────────────────────────────────────────────────────────
async function forceRefresh(assetKey) {
  const btn = document.querySelector(`#section-${assetKey} .refresh-btn`);
  if (btn) { btn.style.transform = 'rotate(360deg)'; btn.disabled = true; }

  try {
    await fetch(`/api/refresh/${assetKey}`, { method: 'POST' });
    // Poll until new data arrives
    let attempts = 0;
    const poll = setInterval(async () => {
      attempts++;
      await fetchAndRender();
      if (attempts > 20) clearInterval(poll);
    }, 2000);
  } catch(e) {
    console.error('Refresh error:', e);
  } finally {
    setTimeout(() => {
      if (btn) { btn.style.transform = ''; btn.disabled = false; }
    }, 2000);
  }
}

// ── Main fetch loop ───────────────────────────────────────────────────────────
let firstLoad = true;
let consecutiveErrors = 0;

async function fetchAndRender() {
  try {
    const res  = await fetch('/api/signals');
    const data = await res.json();

    // Update server time
    if (data.server_time) {
      const d = new Date(data.server_time);
      const timeEl = document.getElementById('server-time');
      if (timeEl) timeEl.textContent = d.toUTCString().split(' ')[4] + ' UTC';
    }

    // Connection status
    const dot   = document.getElementById('conn-dot');
    const label = document.getElementById('conn-label');
    if (dot && label) {
      dot.className   = 'dot live';
      label.textContent = 'EN DIRECT';
    }

    consecutiveErrors = 0;

    const signals = data.signals || {};

    // Render each asset
    ['GOLD', 'BTC'].forEach(key => {
      if (signals[key]) renderSignal(key, signals[key]);
    });

    // Hide loading overlay on first successful load
    if (firstLoad && (signals.GOLD || signals.BTC)) {
      firstLoad = false;
      const overlay = document.getElementById('loading-overlay');
      if (overlay) {
        overlay.classList.add('hidden');
        setTimeout(() => overlay.remove(), 600);
      }
    }
  } catch(e) {
    consecutiveErrors++;
    console.error('Fetch error:', e);
    if (consecutiveErrors >= 3) {
      const dot   = document.getElementById('conn-dot');
      const label = document.getElementById('conn-label');
      if (dot && label) { dot.className = 'dot error'; label.textContent = 'Déconnecté'; }
    }
  }
}

// ── Boot ──────────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  initChart('GOLD');
  initChart('BTC');

  // Initial fetch
  fetchAndRender();

  // Poll every 30 seconds for live prices
  setInterval(fetchAndRender, 30_000);

  // Live clock
  setInterval(() => {
    const el = document.getElementById('server-time');
    if (el && el.textContent !== '--:--:-- UTC') {
      const now = new Date();
      el.textContent = now.toUTCString().split(' ')[4] + ' UTC';
    }
  }, 1000);
});
