#!/usr/bin/env python3
"""Price stats from stooq EOD history (free, no key).

Usage: python3 quote_hist.py TICKER [--symbol-suffix .us]
Prints JSON: last close, returns (1D/1M/YTD/1Y), 52w range, annualized vol,
max drawdown, SMA50/200, RSI14, beta vs S&P 500. Importable: get_stats(ticker).
"""
import io, json, socket, subprocess, sys
import numpy as np
import pandas as pd

# Half-configured IPv6 on this box makes every python HTTPS connect try AAAA
# first and stall ~15s (see edgar_facts.py). Force IPv4 for urllib3-based
# clients (requests / most yfinance transports); curl does happy-eyeballs.
try:
    import urllib3.util.connection as _u3conn
    _u3conn.allowed_gai_family = lambda: socket.AF_INET
except (ImportError, AttributeError):
    # Optional latency fix, not a requirement: without urllib3 (or on a version
    # whose internals moved) requests still work, just with the IPv6 stall.
    pass

TIMEOUT = 30


def fetch_stooq(symbol):
    url = f"https://stooq.com/q/d/l/?s={symbol}&i=d"
    # stooq bot-filters aggressively (TLS fingerprinting; escalates to a JS
    # challenge). curl sometimes passes; when it doesn't, we fall back. We do
    # NOT solve their challenge — that's their line, we respect it.
    p = subprocess.run(["curl", "-sfm", str(TIMEOUT), url], capture_output=True, text=True)
    if p.returncode != 0 or not p.stdout.strip() or p.stdout.lstrip().startswith("<"):
        raise RuntimeError(f"stooq unavailable for {symbol}")
    df = pd.read_csv(io.StringIO(p.stdout), parse_dates=["Date"]).set_index("Date")
    if df.empty or "Close" not in df:
        raise RuntimeError(f"stooq returned no data for {symbol}")
    return df


def fetch_yf(ticker):
    import yfinance as yf
    df = yf.Ticker(ticker).history(period="2y", auto_adjust=True)
    if df.empty or "Close" not in df:
        raise RuntimeError(f"yfinance returned no data for {ticker}")
    df.index = df.index.tz_localize(None)
    return df


def fetch(ticker, suffix=".us"):
    """Return (daily_df, source_label). yfinance primary, stooq fallback."""
    yf_sym = "^GSPC" if ticker == "^spx" else ticker.upper()
    try:
        return fetch_yf(yf_sym), f"yahoo daily ({yf_sym})"
    except Exception:
        sym = ticker.lower() if ticker.startswith("^") else ticker.lower() + suffix
        return fetch_stooq(sym), f"stooq EOD ({sym})"


def rsi(close, n=14):
    d = close.diff()
    up = d.clip(lower=0).ewm(alpha=1 / n, adjust=False).mean()
    dn = (-d.clip(upper=0)).ewm(alpha=1 / n, adjust=False).mean()
    rs = up / dn.replace(0, np.nan)
    return float((100 - 100 / (1 + rs)).iloc[-1])


def get_stats(ticker, suffix=".us"):
    # fetch() owns symbol normalization per source (yahoo wants bare upper,
    # stooq wants lower+suffix) — passing a pre-suffixed symbol here double-
    # suffixed the stooq fallback ("aapl.us.us") and 404'd yahoo ("AAPL.US").
    df, src = fetch(ticker, suffix)
    c = df["Close"]
    last, last_date = float(c.iloc[-1]), str(df.index[-1].date())
    yr = c[c.index >= c.index[-1] - pd.Timedelta(days=365)]
    ret = lambda n: float(c.iloc[-1] / c.iloc[-n - 1] - 1) if len(c) > n else None
    ytd = c[c.index.year == c.index[-1].year]
    logr = np.log(yr / yr.shift(1)).dropna()
    peak = yr.cummax()
    out = {
        "ticker": ticker.upper(), "source": src, "asof": last_date,
        "close": last,
        "ret_1d": ret(1), "ret_1m": ret(21),
        "ret_ytd": float(last / ytd.iloc[0] - 1) if len(ytd) > 1 else None,
        "ret_1y": ret(252),
        "hi_52w": float(yr.max()), "lo_52w": float(yr.min()),
        "off_high": float(last / yr.max() - 1),
        "vol_ann": float(logr.std() * np.sqrt(252)),
        "max_dd_1y": float((yr / peak - 1).min()),
        "sma50": float(c.rolling(50).mean().iloc[-1]) if len(c) >= 50 else None,
        "sma200": float(c.rolling(200).mean().iloc[-1]) if len(c) >= 200 else None,
        "rsi14": rsi(c),
    }
    try:
        spx = fetch("^spx")[0]["Close"]
        both = pd.concat([c, spx], axis=1, keys=["t", "m"]).dropna().tail(252)
        rt, rm = both["t"].pct_change().dropna(), both["m"].pct_change().dropna()
        aligned = pd.concat([rt, rm], axis=1).dropna()
        cov = np.cov(aligned.iloc[:, 0], aligned.iloc[:, 1])
        out["beta_1y_spx"] = float(cov[0, 1] / cov[1, 1])
    except Exception as e:
        out["beta_1y_spx"] = None
        out["beta_note"] = f"beta unavailable: {type(e).__name__}"
    return out


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    sfx = args[args.index("--symbol-suffix") + 1] if "--symbol-suffix" in args else ".us"
    print(json.dumps(get_stats(args[0], sfx), indent=2))
