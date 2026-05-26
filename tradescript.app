import { useState, useRef, useCallback, useEffect } from "react";

// ─── TIER CONFIG ──────────────────────────────────────────────────────────────
const FREE_SCAN_LIMIT = 3;
const PRO_MONTHLY_PRICE = "$9";

// ─── PROMPTS ──────────────────────────────────────────────────────────────────
const CHART_PROMPT = `You are an elite prop desk quant analyst AND trading coach. Analyze ALL visible chart elements: VWAP, EMA/SMA crossovers, MACD, RSI, Bollinger Bands, ATR, OBV, ADX, Fibonacci, order book walls, volume profile, support/resistance, candlestick patterns, correlated symbols (DXY, NQ, Gold, Oil, ETH etc).

CRITICAL: Your entire response must be a single raw JSON object. No preamble, no explanation, no markdown, no backticks. Start with { and end with }. Never write anything outside the JSON.

CHART COMPLEXITY SCORING (chart_health 0-100):
- Plain candles only = 10-25
- Price + 1-2 basic indicators = 26-45
- Price + 3-4 indicators = 46-65
- Price + 5-6 indicators + volume = 66-80
- Full stack (7+ indicators, order book, correlated assets) = 81-100

Confidence MUST reflect chart_health — bare chart cannot exceed 55% confidence.

Respond ONLY in this exact JSON, no markdown, no preamble:
{
  "instrument": "symbol or UNKNOWN",
  "timeframe": "e.g. 5m",
  "current_price": "price string",
  "bias": "LONG or SHORT or NEUTRAL",
  "confidence": 0-100,
  "chart_health": 0-100,
  "chart_level": "BEGINNER or INTERMEDIATE or ADVANCED or PRO",
  "entry": "price string",
  "stop": "price string",
  "target1": "price string",
  "target2": "price string",
  "rr": "e.g. 1:2.4",
  "setup_type": "e.g. VWAP Reclaim, Support Bounce, Trend Continuation",
  "key_levels": ["level1","level2","level3"],
  "indicators": {
    "macd": "Bullish / Bearish / Neutral / Not visible",
    "rsi": "~value or Not visible",
    "atr": "value or Not visible",
    "bbands": "Squeeze / Expanding / Upper break / Lower break / Not visible",
    "obv": "Confirming / Diverging / Not visible",
    "adx": "value or Not visible",
    "vwap": "Price above / Price below / At VWAP / Not visible",
    "ema": "Bullish cross / Bearish cross / Flat / Not visible",
    "fib": "Key level near price or Not visible"
  },
  "missing_indicators": [
    {"name": "indicator name", "why": "one sentence on what it would reveal on THIS specific chart"}
  ],
  "correlated": [
    {"symbol": "DXY/NQ/Gold/Oil/ETH etc", "reading": "one sentence on what it shows"}
  ],
  "reasoning": "3-4 punchy trader sentences. Beginner chart = plain English. Pro chart = trader jargon. Be specific about price levels.",
  "beginner_tip": "If BEGINNER or INTERMEDIATE: one encouraging plain-English sentence. Otherwise null.",
  "invalidation": ["condition 1", "condition 2"],
  "market_session": "Asia / London / NY / NY-London Overlap / After Hours"
}`;

const MACRO_PROMPT = `You are a senior macro trading analyst. Today is Friday May 22 2026, UTC: {UTC_TIME}.
Analyze the current macro environment for: {CONTEXT}
Consider: Fed/FOMC policy, DXY trend, Nasdaq/S&P risk sentiment, BTC ETF flows, geopolitical risks, oil/energy, scheduled events today.
Active session — Asia: 00-09 UTC, London: 07-16 UTC, NY: 13-22 UTC.
CRITICAL: Respond with ONLY a raw JSON object. Start with { and end with }. No text outside the JSON.
{
  "macro_score": integer -100 to 100,
  "macro_label": "RISK ON or RISK OFF or NEUTRAL",
  "session_note": "active session and volatility implication",
  "headlines": [
    {"title": "concise headline", "impact": "BULLISH or BEARISH or NEUTRAL", "detail": "1-2 sentences on trading implication"}
  ],
  "macro_summary": "2-3 punchy sentences on macro picture and how it affects this trade",
  "key_events_today": ["event to watch"]
}`;

// ─── API ──────────────────────────────────────────────────────────────────────
const callClaude = async (messages, system) => {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: "claude-sonnet-4-20250514", max_tokens: 1200, system, messages }),
  });
  const data = await res.json();
  if (data.error) throw new Error(`API: ${data.error.message}`);
  if (!data.content) throw new Error(`No response (status ${res.status})`);
  const raw = data.content.filter(b => b.type === "text").map(b => b.text).join("");
  return raw.replace(/```json\s*/gi, "").replace(/```\s*/g, "").trim();
};
const parseJSON = s => {
  if (!s) return null;
  // Try direct parse first
  try { return JSON.parse(s); } catch {}
  // Extract first {...} block, handling nested braces
  try {
    const start = s.indexOf('{');
    if (start === -1) return null;
    let depth = 0, end = -1;
    for (let i = start; i < s.length; i++) {
      if (s[i] === '{') depth++;
      else if (s[i] === '}') { depth--; if (depth === 0) { end = i; break; } }
    }
    if (end !== -1) return JSON.parse(s.slice(start, end + 1));
  } catch {}
  return null;
};

// ─── SCAN LIMIT (per session, resets on reload — swap for localStorage in prod) ─
const getScanData = () => {
  const today = new Date().toDateString();
  const raw = window._tsScans || { date: today, count: 0 };
  if (raw.date !== today) return { date: today, count: 0 };
  return raw;
};

// Check if returning from successful Stripe payment
const checkStripeSuccess = () => {
  const params = new URLSearchParams(window.location.search);
  if (params.get("pro") === "success") {
    window._tsIsPro = true;
    // Clean URL
    window.history.replaceState({}, "", window.location.pathname);
    return true;
  }
  return window._tsIsPro === true;
};
const incrementScans = () => {
  const d = getScanData();
  window._tsScans = { ...d, count: d.count + 1 };
};
const getScansUsed = () => getScanData().count;

// ─── HISTORY ─────────────────────────────────────────────────────────────────
const loadHistory = () => Array.isArray(window._tsHistory) ? window._tsHistory : [];
const saveHistory = entry => {
  const h = loadHistory();
  h.unshift(entry);
  window._tsHistory = h.slice(0, 50);
};

// ─── DESIGN TOKENS ────────────────────────────────────────────────────────────
const C = {
  green:"#00e676", red:"#ff1744", yellow:"#ffd740", blue:"#5b9bd5",
  dim:"#2a4a5a", dimmer:"#1a3040", bg:"#060a0d", bg2:"#080d12", bg3:"#0d1a24",
  text:"#c8d8e8", textMid:"#7a9ab0", textDim:"#4a6a7a",
  proGold:"#f0b429", proGoldDim:"#6a4a10",
};
const biasColor  = b => b==="LONG"?C.green:b==="SHORT"?C.red:C.yellow;
const confColor  = c => c>=70?C.green:c>=45?C.yellow:C.red;
const impactColor= i => i==="BULLISH"?C.green:i==="BEARISH"?C.red:C.yellow;
const macroColor = s => s>20?C.green:s<-20?C.red:C.yellow;
const MONO = "'IBM Plex Mono','Courier New',monospace";
const BEBAS= "'Bebas Neue',sans-serif";

// ─── TWITTER CARD ─────────────────────────────────────────────────────────────
// Free tier Twitter card — simplified, branded
const doExportCardFree = (signal) => {
  const cv = document.createElement("canvas");
  cv.width = 1200; cv.height = 628;
  const ctx = cv.getContext("2d");

  // Background
  ctx.fillStyle = "#060a0d"; ctx.fillRect(0, 0, 1200, 628);

  // Grid
  ctx.strokeStyle = "rgba(0,230,118,0.03)"; ctx.lineWidth = 1;
  for(let x=0;x<1200;x+=40){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,628);ctx.stroke();}
  for(let y=0;y<628;y+=40){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(1200,y);ctx.stroke();}

  const bc = signal.bias==="LONG"?"#00e676":signal.bias==="SHORT"?"#ff1744":"#ffd740";

  // Accent bar
  ctx.fillStyle = bc; ctx.fillRect(0, 0, 6, 628);

  // Header
  ctx.font = "13px monospace"; ctx.fillStyle = "rgba(0,230,118,0.25)";
  ctx.fillText("TRADESCRIPT  ·  SIGNAL DECODER", 36, 42);

  // Instrument + timeframe
  ctx.font = "16px monospace"; ctx.fillStyle = "#2a5a7a";
  ctx.fillText(`${signal.instrument||""}  ·  ${signal.timeframe||""}  ·  ${signal.market_session||""}`, 36, 72);

  // Big BIAS
  ctx.font = "bold 110px monospace"; ctx.fillStyle = bc;
  ctx.fillText(signal.bias, 36, 200);

  // Setup type
  ctx.font = "15px monospace"; ctx.fillStyle = "#3a6a5a";
  ctx.fillText((signal.setup_type||"").toUpperCase(), 36, 228);

  // Confidence bar
  const conf = signal.confidence || 0;
  const confC = conf>=70?"#00e676":conf>=45?"#ffd740":"#ff1744";
  ctx.fillStyle = "#0d1a24"; ctx.fillRect(36, 246, 320, 6);
  ctx.fillStyle = confC; ctx.fillRect(36, 246, 320*(conf/100), 6);
  ctx.font = "11px monospace"; ctx.fillStyle = confC;
  ctx.fillText(`${conf}% CONFIDENCE`, 36, 270);

  // Price levels grid
  const levels = [
    {l:"ENTRY",    v:signal.entry,   c:"#5b9bd5"},
    {l:"STOP",     v:signal.stop,    c:"#ff1744"},
    {l:"TARGET 1", v:signal.target1, c:"#00e676"},
    {l:"TARGET 2", v:signal.target2, c:"#00c853"},
    {l:"R:R",      v:signal.rr,      c:"#ffd740"},
  ];
  levels.forEach(({l,v,c},i) => {
    const x = 36 + i*230;
    ctx.font = "10px monospace"; ctx.fillStyle = "#2a4a5a"; ctx.fillText(l, x, 312);
    ctx.font = "bold 22px monospace"; ctx.fillStyle = c; ctx.fillText(v||"—", x, 340);
  });

  // Divider
  ctx.strokeStyle = "rgba(255,255,255,0.05)"; ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(36,362); ctx.lineTo(1164,362); ctx.stroke();

  // Reasoning — word wrap
  ctx.font = "13px monospace"; ctx.fillStyle = "#6a8a9a";
  const words = (signal.reasoning||"").split(" ");
  let line = "", y = 394;
  for(const w of words) {
    const test = line + w + " ";
    if(ctx.measureText(test).width > 740 && line) {
      ctx.fillText(line.trim(), 36, y); line = w + " "; y += 22;
    } else line = test;
    if(y > 490) { ctx.fillText(line.trim()+"…", 36, y); break; }
  }
  if(y <= 490 && line) ctx.fillText(line.trim(), 36, y);

  // Right panel — upgrade CTA
  ctx.fillStyle = "#07100a";
  ctx.fillRect(820, 362, 344, 224);
  ctx.strokeStyle = "#00e67622"; ctx.lineWidth=1;
  ctx.strokeRect(820, 362, 344, 224);

  ctx.font = "10px monospace"; ctx.fillStyle = "#1a4030"; ctx.fillText("WANT MORE?", 844, 392);
  ctx.font = "bold 18px monospace"; ctx.fillStyle = "#00e676"; ctx.fillText("UPGRADE TO PRO", 844, 420);
  ctx.font = "11px monospace"; ctx.fillStyle = "#3a6a4a";
  const proFeatures = ["✓ Full indicator breakdown","✓ Live macro context","✓ Chart health score","✓ Unlimited scans","✓ Win rate tracking"];
  proFeatures.forEach((f,i) => ctx.fillText(f, 844, 448 + i*24));

  // Affiliate links row
  ctx.fillStyle = "#0a0c08";
  ctx.fillRect(0, 548, 1200, 48);
  ctx.font = "11px monospace"; ctx.fillStyle = "#2a5a7a";
  ctx.fillText("tradescript.app", 36, 578);
  ctx.fillStyle = "#2962ff";
  ctx.fillText("TradingView Pro ↗", 220, 578);
  ctx.fillStyle = "#00bcd4";
  ctx.fillText("Gemini Exchange ↗", 440, 578);
  ctx.fillStyle = "#f0b429";
  ctx.fillText("Captain Crypto Super Slots ↗", 660, 578);

  // Footer
  ctx.font = "9px monospace"; ctx.fillStyle = "rgba(0,230,118,0.12)";
  ctx.fillText("NOT FINANCIAL ADVICE  ·  FOR ENTERTAINMENT ONLY", 36, 614);

  const url = cv.toDataURL("image/png");
  const a = document.createElement("a");
  a.href = url; a.download = `signal-${signal.instrument||"chart"}-free-${Date.now()}.png`;
  a.click();
};

const doExportCard = (signal, macro) => {
  const cv = document.createElement("canvas");
  cv.width=1200; cv.height=628;
  const ctx = cv.getContext("2d");
  ctx.fillStyle="#060a0d"; ctx.fillRect(0,0,1200,628);
  ctx.strokeStyle="rgba(0,230,118,0.035)"; ctx.lineWidth=1;
  for(let x=0;x<1200;x+=40){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,628);ctx.stroke();}
  for(let y=0;y<628;y+=40){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(1200,y);ctx.stroke();}
  ctx.fillStyle=biasColor(signal.bias); ctx.fillRect(0,0,5,628);
  ctx.font="12px monospace"; ctx.fillStyle="rgba(0,230,118,0.3)";
  ctx.fillText("TRADESCRIPT  ·  SIGNAL DECODER PRO",30,38);
  ctx.font="16px monospace"; ctx.fillStyle="#2a5a7a";
  ctx.fillText(`${signal.instrument}  ·  ${signal.timeframe}  ·  ${signal.market_session}`,30,66);
  ctx.font="bold 100px monospace"; ctx.fillStyle=biasColor(signal.bias);
  ctx.fillText(signal.bias,30,185);
  ctx.font="14px monospace"; ctx.fillStyle="#3a6a5a";
  ctx.fillText((signal.setup_type||"").toUpperCase(),30,212);
  ctx.fillStyle="#0d1a24"; ctx.fillRect(30,228,300,5);
  ctx.fillStyle=confColor(signal.confidence); ctx.fillRect(30,228,300*signal.confidence/100,5);
  ctx.font="11px monospace"; ctx.fillStyle=confColor(signal.confidence);
  ctx.fillText(`CONFIDENCE ${signal.confidence}%  ·  CHART HEALTH ${signal.chart_health||"?"}%`,30,252);
  const lvls=[{l:"ENTRY",v:signal.entry,c:"#5b9bd5"},{l:"STOP",v:signal.stop,c:"#ff1744"},{l:"TP1",v:signal.target1,c:"#00e676"},{l:"TP2",v:signal.target2,c:"#00c853"},{l:"R:R",v:signal.rr,c:"#ffd740"}];
  lvls.forEach(({l,v,c},i)=>{
    const x=30+i*228;
    ctx.font="10px monospace"; ctx.fillStyle="#2a4a5a"; ctx.fillText(l,x,295);
    ctx.font="bold 22px monospace"; ctx.fillStyle=c; ctx.fillText(v||"—",x,323);
  });
  ctx.strokeStyle="rgba(255,255,255,0.05)"; ctx.lineWidth=1;
  ctx.beginPath();ctx.moveTo(30,345);ctx.lineTo(1170,345);ctx.stroke();
  ctx.font="13px monospace"; ctx.fillStyle="#6a8a9a";
  const words=(signal.reasoning||"").split(" ");
  let line="",y=374;
  for(const w of words){
    const t=line+w+" ";
    if(ctx.measureText(t).width>700&&line){ctx.fillText(line.trim(),30,y);line=w+" ";y+=22;}
    else line=t;
    if(y>470)break;
  }
  if(line)ctx.fillText(line.trim(),30,y);
  if(macro){
    ctx.fillStyle="#070c10";ctx.fillRect(770,345,400,240);
    ctx.strokeStyle=`${macroColor(macro.macro_score)}22`;ctx.strokeRect(770,345,400,240);
    ctx.font="10px monospace";ctx.fillStyle="#1a3040";ctx.fillText("MACRO",792,372);
    ctx.font="bold 28px monospace";ctx.fillStyle=macroColor(macro.macro_score);
    ctx.fillText(macro.macro_label,792,404);
    (macro.headlines||[]).slice(0,3).forEach((h,i)=>{
      const iy=434+i*38;
      ctx.font="10px monospace";ctx.fillStyle=impactColor(h.impact);ctx.fillText(h.impact,792,iy);
      ctx.font="11px monospace";ctx.fillStyle="#4a6a7a";ctx.fillText((h.title||"").slice(0,45),792,iy+16);
    });
  }
  ctx.font="10px monospace";ctx.fillStyle="rgba(0,230,118,0.15)";
  ctx.fillText("NOT FINANCIAL ADVICE  ·  ENTERTAINMENT ONLY  ·  TRADESCRIPT PRO",30,606);
  ctx.fillStyle="rgba(240,180,41,0.5)";ctx.fillText("tradescript.app",1040,606);
  const url=cv.toDataURL("image/png");
  const a=document.createElement("a");a.href=url;a.download=`signal-${signal.instrument}-${Date.now()}.png`;a.click();
};

// ─── SUB-COMPONENTS ───────────────────────────────────────────────────────────

const IndicatorPill = ({label,value}) => {
  if(!value||value==="Not visible")return null;
  const pos=value.includes("Bull")||value.includes("above")||value.includes("Confirm");
  const neg=value.includes("Bear")||value.includes("below")||value.includes("Diverg")||value.includes("break");
  const c=pos?C.green:neg?C.red:C.yellow;
  return(
    <div style={{border:`1px solid ${c}22`,padding:"7px 11px",minWidth:90}}>
      <div style={{fontSize:9,color:C.dim,letterSpacing:".12em",marginBottom:3}}>{label}</div>
      <div style={{fontSize:11,color:c,fontWeight:600}}>{value.length>18?value.slice(0,18)+"…":value}</div>
    </div>
  );
};

const ScoreBar = ({label,value,subtitle}) => (
  <div>
    <div style={{display:"flex",justifyContent:"space-between",alignItems:"baseline",marginBottom:6}}>
      <span style={{fontSize:9,color:C.dim,letterSpacing:".14em"}}>{label}</span>
      <span style={{fontSize:32,fontWeight:700,color:confColor(value??50),fontFamily:BEBAS,lineHeight:1}}>{value??0}%</span>
    </div>
    <div style={{height:6,background:C.bg3}}>
      <div style={{height:"100%",width:`${value??0}%`,background:confColor(value??50),transition:"width 1.2s cubic-bezier(.4,0,.2,1)"}}/>
    </div>
    {subtitle&&<div style={{fontSize:9,color:confColor(value??50),marginTop:5,letterSpacing:".08em"}}>{subtitle}</div>}
  </div>
);

// Pro lock overlay for blurred sections
const ProLock = ({onUpgrade, label="PRO FEATURE"}) => (
  <div style={{position:"relative",overflow:"hidden",borderRadius:2}}>
    <div style={{filter:"blur(4px)",pointerEvents:"none",userSelect:"none",opacity:.4}}>
      <div style={{height:80,background:C.bg3,borderRadius:2}}/>
    </div>
    <div style={{position:"absolute",inset:0,display:"flex",flexDirection:"column",alignItems:"center",justifyContent:"center",background:"rgba(6,10,13,.85)",border:`1px solid ${C.proGold}33`,borderRadius:2}}>
      <div style={{fontSize:14,marginBottom:6}}>⭐</div>
      <div style={{fontSize:9,color:C.proGold,letterSpacing:".15em",marginBottom:8}}>{label}</div>
      <button onClick={onUpgrade} style={{background:C.proGold,border:"none",color:"#060a0d",fontFamily:MONO,fontSize:11,fontWeight:600,padding:"6px 16px",cursor:"pointer",letterSpacing:".1em"}}>
        UPGRADE TO PRO
      </button>
    </div>
  </div>
);

// Inline SVG logos — no external image dependencies
const LogoTradingView = ({size=28}) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
    <rect width="24" height="24" rx="4" fill="#2962FF"/>
    <path d="M4 17l4-8 3 5 2-3 3 4" stroke="white" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
    <circle cx="18" cy="8" r="2" fill="white"/>
  </svg>
);

const LogoGemini = ({size=28}) => (
  <svg width={size} height={size*0.37} viewBox="0 0 120 44" fill="none" xmlns="http://www.w3.org/2000/svg">
    <path d="M0 22C0 9.85 9.85 0 22 0C28.6 0 34.5 2.7 38.8 7L34 11.8C31 8.8 26.7 7 22 7C13.7 7 7 13.7 7 22C7 30.3 13.7 37 22 37C29.5 37 35.7 31.6 36.8 24.5H22V17.5H44V22C44 34.15 34.15 44 22 44C9.85 44 0 34.15 0 22Z" fill="white"/>
    <path d="M120 22C120 34.15 110.15 44 98 44C91.4 44 85.5 41.3 81.2 37L86 32.2C89 35.2 93.3 37 98 37C106.3 37 113 30.3 113 22C113 13.7 106.3 7 98 7C90.5 7 84.3 12.4 83.2 19.5H98V26.5H76V22C76 9.85 85.85 0 98 0C110.15 0 120 9.85 120 22Z" fill="white"/>
    <rect x="49" y="1" width="7" height="42" fill="white"/>
    <rect x="64" y="1" width="7" height="42" fill="white"/>
  </svg>
);

const CC_LOGO_SM = "data:image/png;base64,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";
const CC_LOGO_LG = "data:image/png;base64,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";
const LogoCaptainCrypto = ({size=28}) => (
  <img src={CC_LOGO_SM} width={size} height={size} style={{objectFit:"cover",borderRadius:4}} alt="Captain Crypto Super Slots"/>
);

const ADS = [
  {
    label: "CHART SMARTER",
    headline: "TradingView Pro — the platform serious traders use",
    cta: "Get TradingView →",
    url: "https://www.tradingview.com/pricing/?share_your_love=maxresults4u",
    color: "#2962ff",
    Logo: LogoTradingView,
    bg: "#1e3a8a",
  },
  {
    label: "TRADE CRYPTO",
    headline: "Gemini Exchange — secure, regulated, trusted",
    cta: "Open Free Account →",
    url: "https://exchange.gemini.com/register?referral=9nllwes7&type=referral",
    color: "#00bcd4",
    Logo: LogoGemini,
    bg: "#0a2a30",
  },
  {
    label: "LEARN TO TRADE",
    headline: "Captain Crypto Super Slots — play free sweepstakes crypto slots!",
    cta: "Visit Captain Crypto →",
    url: "https://www.captaincryptosuperslots.com",
    color: "#f0b429",
    Logo: LogoCaptainCrypto,
    bg: "#1a1200",
  },
];

const AdBanner = () => {
  const [idx, setIdx] = useState(0);
  const [vis, setVis] = useState(true);
  useEffect(() => {
    const t = setInterval(() => {
      setVis(false);
      setTimeout(() => { setIdx(i => (i+1) % ADS.length); setVis(true); }, 400);
    }, 5000);
    return () => clearInterval(t);
  }, []);
  const ad = ADS[idx];
  return (
    <div style={{background:"#070c10",border:`1px solid ${C.bg3}`,margin:"12px 0",overflow:"hidden",position:"relative"}}>
      <div style={{position:"absolute",top:0,left:0,right:0,height:2,background:C.bg3}}>
        <div key={idx} style={{height:"100%",background:ad.color,opacity:.5,animation:"adprogress 5s linear forwards"}}/>
      </div>
      <div style={{padding:"12px 16px",display:"flex",alignItems:"center",gap:14,opacity:vis?1:0,transition:"opacity .4s ease"}}>
        <div style={{fontSize:9,color:C.dimmer,letterSpacing:".12em",whiteSpace:"nowrap"}}>AD</div>
        <div style={{flexShrink:0,display:"flex",alignItems:"center",justifyContent:"center",background:ad.bg,padding:"6px 10px",borderRadius:4,minWidth:52}}>
          <ad.Logo size={24}/>
        </div>
        <div style={{flex:1,minWidth:0}}>
          <div style={{fontSize:9,color:ad.color,letterSpacing:".14em",marginBottom:3}}>{ad.label}</div>
          <div style={{fontSize:12,color:C.textMid}}>{ad.headline}</div>
        </div>
        <a href={ad.url} target="_blank" rel="noopener noreferrer" style={{flexShrink:0,background:"transparent",border:`1px solid ${ad.color}66`,color:ad.color,fontFamily:MONO,fontSize:11,padding:"7px 14px",textDecoration:"none",letterSpacing:".08em",whiteSpace:"nowrap"}}>
          {ad.cta}
        </a>
        <div style={{display:"flex",gap:4,flexShrink:0}}>
          {ADS.map((_,i)=>(
            <div key={i} onClick={()=>{setVis(false);setTimeout(()=>{setIdx(i);setVis(true);},400);}}
              style={{width:6,height:6,borderRadius:"50%",cursor:"pointer",background:i===idx?ad.color:C.bg3,border:`1px solid ${i===idx?ad.color:C.dim}`,transition:"all .3s"}}/>
          ))}
        </div>
      </div>
    </div>
  );
};

// Scan counter dots
const ScanDots = ({used, limit}) => (
  <div style={{display:"flex",alignItems:"center",gap:6}}>
    <div style={{fontSize:9,color:C.dim,letterSpacing:".1em",marginRight:2}}>FREE SCANS</div>
    {Array.from({length:limit}).map((_,i)=>(
      <div key={i} style={{width:8,height:8,borderRadius:"50%",background:i<used?C.green:C.bg3,border:`1px solid ${i<used?C.green:C.dim}`,transition:"all .3s"}}/>
    ))}
    <div style={{fontSize:9,color:i=>i<used?C.green:C.dim}}>{used}/{limit}</div>
  </div>
);

// ── STRIPE CONFIG ─────────────────────────────────────────────────────────────
const STRIPE_PUBLISHABLE_KEY = "pk_live_51TGzihDtJJ3jOyamdCVXAYKoDBzeLr8bqcMw6tYwKLk4T2fWA6RoUUwKb89jLtjauQ9ByfYRzyjJNV6siz0pmToI00iCCuHp9Y";
const STRIPE_PRICE_ID = "price_1TZuviDtJJ3jOyam7RFBscnq";

// Stripe checkout — opens hosted checkout session
const openStripeCheckout = async (email = "") => {
  try {
    // Load Stripe.js dynamically if not already loaded
    if (!window.Stripe) {
      await new Promise((resolve, reject) => {
        const s = document.createElement("script");
        s.src = "https://js.stripe.com/v3/";
        s.onload = resolve;
        s.onerror = reject;
        document.head.appendChild(s);
      });
    }
    const stripe = window.Stripe(STRIPE_PUBLISHABLE_KEY);
    const result = await stripe.redirectToCheckout({
      lineItems: [{ price: STRIPE_PRICE_ID, quantity: 1 }],
      mode: "subscription",
      successUrl: window.location.href + "?pro=success",
      cancelUrl: window.location.href + "?pro=cancelled",
      customerEmail: email || undefined,
    });
    if (result.error) {
      alert("Payment error: " + result.error.message);
    }
  } catch (err) {
    console.error("Stripe error:", err);
    alert("Could not open checkout. Please try again.");
  }
};

// Upgrade modal
const UpgradeModal = ({onClose, trigger, onUpgrade}) => (
  <div style={{position:"fixed",inset:0,background:"rgba(0,0,0,.85)",zIndex:100,display:"flex",alignItems:"center",justifyContent:"center",padding:20}}>
    <div style={{background:C.bg2,border:`1px solid ${C.proGold}44`,maxWidth:480,width:"100%",padding:"32px"}}>
      <div style={{fontFamily:BEBAS,fontSize:42,color:C.proGold,lineHeight:1,marginBottom:4}}>UPGRADE TO PRO</div>
      <div style={{fontSize:11,color:C.dim,letterSpacing:".1em",marginBottom:20}}>TRADESCRIPT SIGNAL DECODER PRO</div>

      {trigger==="limit" && (
        <div style={{background:"#0a0e08",border:`1px solid ${C.green}22`,padding:"10px 14px",marginBottom:20,fontSize:12,color:"#5a8a6a"}}>
          You've used all {FREE_SCAN_LIMIT} free scans today. Resets at midnight — or upgrade for unlimited.
        </div>
      )}

      <div style={{marginBottom:24}}>
        {[
          {free:true,  label:"Basic signal — bias, entry, stop, targets"},
          {free:true,  label:`${FREE_SCAN_LIMIT} scans per day`},
          {free:true,  label:"Last 3 signals in history"},
          {free:false, label:"Full indicator breakdown (MACD, RSI, ATR, OBV…)"},
          {free:false, label:"Chart health score + coaching"},
          {free:false, label:"Missing indicators recommendations"},
          {free:false, label:"Full macro context + live session analysis"},
          {free:false, label:"Unlimited scans, unlimited history"},
          {free:false, label:"Win rate tracking"},
          {free:false, label:"Twitter / X signal card export"},
          {free:false, label:"No ads"},
        ].map((item,i)=>(
          <div key={i} style={{display:"flex",gap:10,padding:"7px 0",borderBottom:`1px solid ${C.bg3}`,alignItems:"center"}}>
            <span style={{fontSize:12,color:item.free?C.dim:C.proGold,minWidth:16}}>{item.free?"○":"★"}</span>
            <span style={{fontSize:12,color:item.free?C.dim:C.text}}>{item.label}</span>
            {!item.free&&<span style={{fontSize:9,color:C.proGold,border:`1px solid ${C.proGold}44`,padding:"1px 6px",marginLeft:"auto",letterSpacing:".1em"}}>PRO</span>}
          </div>
        ))}
      </div>

      {/* Email input for Stripe */}
      <div style={{marginBottom:10}}>
        <input
          id="stripe-email"
          type="email"
          placeholder="your@email.com (optional — for receipt)"
          style={{width:"100%",background:"#080d12",border:`1px solid ${C.dim}44`,color:C.text,fontFamily:MONO,fontSize:12,padding:"10px 14px",outline:"none",letterSpacing:".05em"}}
        />
      </div>
      {/* Stripe payment button */}
      <div style={{display:"flex",gap:10,alignItems:"center",marginBottom:12}}>
        <button
          onClick={()=>{ const e=document.getElementById("stripe-email")?.value||""; openStripeCheckout(e); }}
          style={{flex:1,background:C.proGold,border:"none",color:"#060a0d",fontFamily:MONO,fontSize:13,fontWeight:600,padding:"14px",cursor:"pointer",letterSpacing:".1em",display:"flex",alignItems:"center",justifyContent:"center",gap:10}}>
          <span>💳</span> GET PRO — {PRO_MONTHLY_PRICE}/mo
        </button>
        <button onClick={onClose} style={{background:"transparent",border:`1px solid ${C.dim}`,color:C.dim,fontFamily:MONO,fontSize:11,padding:"14px 16px",cursor:"pointer"}}>
          LATER
        </button>
      </div>
      {/* Demo mode — remove in production */}
      <button onClick={onUpgrade} style={{width:"100%",background:"transparent",border:`1px solid ${C.dim}22`,color:C.dimmer,fontFamily:MONO,fontSize:10,padding:"8px",cursor:"pointer",marginBottom:12,letterSpacing:".08em"}}>
        DEMO: activate pro without payment (remove in production)
      </button>
      <div style={{fontSize:9,color:C.dimmer,textAlign:"center",letterSpacing:".08em"}}>
        Secure payment via Stripe · Cancel anytime · Not financial advice
      </div>
      <div style={{display:"flex",justifyContent:"center",gap:16,marginTop:10}}>
        <span style={{fontSize:9,color:C.dimmer}}>🔒 SSL encrypted</span>
        <span style={{fontSize:9,color:C.dimmer}}>✓ Stripe secured</span>
        <span style={{fontSize:9,color:C.dimmer}}>✓ Cancel anytime</span>
      </div>
    </div>
  </div>
);

const HistoryRow = ({item, onOutcome, onAmount}) => {
  const bc = biasColor(item.signal?.bias);
  const cc = confColor(item.signal?.confidence);
  const hasOutcome = item.outcome && item.outcome !== "—";
  const pnlColor = item.pnl > 0 ? C.green : item.pnl < 0 ? C.red : C.dim;

  return (
    <div style={{borderBottom:`1px solid ${C.bg3}`}}>
      {/* Main row */}
      <div style={{padding:"10px 12px",display:"flex",alignItems:"center",gap:10}}>
        <div style={{width:3,height:40,background:bc,flexShrink:0}}/>
        <div style={{flex:1,minWidth:0}}>
          <div style={{display:"flex",gap:8,alignItems:"baseline"}}>
            <span style={{fontSize:12,fontWeight:600,color:bc}}>{item.signal?.bias}</span>
            <span style={{fontSize:11,color:C.textMid}}>{item.signal?.instrument}</span>
            <span style={{fontSize:10,color:C.dim}}>{item.signal?.timeframe}</span>
            <span style={{fontSize:10,color:C.dim}}>· {item.signal?.setup_type}</span>
          </div>
          <div style={{fontSize:10,color:C.dim,marginTop:2}}>
            Entry {item.signal?.entry} → TP1 {item.signal?.target1} · R:R {item.signal?.rr}
          </div>
          <div style={{fontSize:9,color:C.dimmer,marginTop:2}}>{item.ts}</div>
        </div>
        <div style={{fontSize:11,color:cc,minWidth:32,textAlign:"right"}}>{item.signal?.confidence}%</div>

        {/* Outcome buttons or result */}
        {!item.outcome ? (
          <div style={{display:"flex",gap:4,flexShrink:0}}>
            {[["WIN",C.green],["LOSS",C.red]].map(([label,c])=>(
              <button key={label} onClick={()=>onOutcome(item.id, label)}
                style={{background:"transparent",border:`1px solid ${c}44`,color:c,fontSize:10,padding:"4px 8px",cursor:"pointer",fontFamily:MONO,minWidth:36}}>
                {label}
              </button>
            ))}
          </div>
        ) : (
          <div style={{display:"flex",flexDirection:"column",alignItems:"center",gap:2,flexShrink:0}}>
            <div style={{fontSize:12,fontWeight:600,color:item.outcome==="WIN"?C.green:item.outcome==="LOSS"?C.red:C.dim,minWidth:40,textAlign:"center"}}>
              {item.outcome}
            </div>
            {item.pnl !== undefined && item.pnl !== null && item.pnl !== 0 && (
              <div style={{fontSize:11,color:pnlColor,fontWeight:600}}>
                {item.pnl >= 0 ? "+" : "-"}${Math.abs(item.pnl).toLocaleString()}
              </div>
            )}
          </div>
        )}
      </div>

      {/* P&L input row — shows after outcome set, before amount entered */}
      {item.outcome && item.pnl === undefined && (
        <div style={{padding:"8px 12px 10px 26px",background:"#060e08",display:"flex",alignItems:"center",gap:10}}>
          <div style={{fontSize:10,color:item.outcome==="WIN"?C.green:C.red}}>
            {item.outcome==="WIN" ? "How much did you WIN?" : "How much did you LOSE?"}
          </div>
          <div style={{display:"flex",alignItems:"center",gap:6}}>
            <span style={{fontSize:12,color:C.dim}}>$</span>
            <input
              type="number"
              placeholder="0.00"
              min="0"
              step="0.01"
              onKeyDown={e => {
                if(e.key==="Enter" && e.target.value) {
                  const amt = parseFloat(e.target.value);
                  onAmount(item.id, item.outcome==="WIN" ? amt : -amt);
                  e.target.value="";
                }
              }}
              style={{
                background:"#080d12",border:`1px solid ${item.outcome==="WIN"?C.green+"44":C.red+"44"}`,
                color:C.text,fontFamily:MONO,fontSize:12,padding:"5px 10px",width:120,outline:"none"
              }}
            />
            <button
              onClick={e=>{
                const input = e.target.previousSibling;
                if(input.value){
                  const amt=parseFloat(input.value);
                  onAmount(item.id, item.outcome==="WIN" ? amt : -amt);
                  input.value="";
                }
              }}
              style={{background:"transparent",border:`1px solid ${C.dim}44`,color:C.dim,fontFamily:MONO,fontSize:10,padding:"5px 10px",cursor:"pointer"}}>
              LOG ↵
            </button>
          </div>
          <div style={{fontSize:9,color:C.dimmer}}>or press Enter</div>
        </div>
      )}
    </div>
  );
};

// ─── MAIN ─────────────────────────────────────────────────────────────────────
export default function SignalDecoder() {
  const [isPro, setIsPro]           = useState(checkStripeSuccess);
  const [showUpgrade, setShowUpgrade] = useState(false);
  const [upgradeReason, setUpgradeReason] = useState("feature");
  const [image, setImage]           = useState(null);
  const [imageBase64, setImageBase64] = useState(null);
  const [imageMime, setImageMime]   = useState("image/png");
  const [signal, setSignal]         = useState(null);
  const [macro, setMacro]           = useState(null);
  const [phase, setPhase]           = useState("idle");
  const [error, setError]           = useState(null);
  const [dragging, setDragging]     = useState(false);
  const [tab, setTab]               = useState("signal");
  const [history, setHistory]       = useState(loadHistory);
  const [scansUsed, setScansUsed]   = useState(getScansUsed);
  const [showPostScanPrompt, setShowPostScanPrompt] = useState(false);
  const [bankroll, setBankroll]     = useState(null);
  const [bankrollInput, setBankrollInput] = useState("");
  const [showBankrollSet, setShowBankrollSet] = useState(false);
  const fileRef = useRef();

  const openUpgrade = (reason="feature") => { setUpgradeReason(reason); setShowUpgrade(true); };
  const activatePro = () => { setIsPro(true); setShowUpgrade(false); }; // swap with real payment in prod

  const processFile = useCallback((file) => {
    if(!file||!file.type.startsWith("image/"))return;
    const reader=new FileReader();
    reader.onload=e=>{
      const d=e.target.result;
      setImage(d); setImageBase64(d.split(",")[1]); setImageMime(file.type||"image/png");
      setSignal(null); setMacro(null); setError(null); setShowPostScanPrompt(false);
    };
    reader.readAsDataURL(file);
  },[]);

  const onDrop = useCallback((e)=>{
    e.preventDefault(); setDragging(false); processFile(e.dataTransfer.files[0]);
  },[processFile]);

  const analyze = async () => {
    if(!imageBase64)return;
    // Check scan limit for free users
    if(!isPro && scansUsed >= FREE_SCAN_LIMIT){ openUpgrade("limit"); return; }

    setPhase("analyzing"); setError(null); setSignal(null); setMacro(null); setShowPostScanPrompt(false);

    try {
      const utcTime = new Date().toUTCString();
      const [chartRaw, macroRaw] = await Promise.all([
        callClaude([{role:"user",content:[
          {type:"image",source:{type:"base64",media_type:imageMime,data:imageBase64}},
          {type:"text",text:"Analyze this trading chart and return the JSON signal."}
        ]}], CHART_PROMPT),
        callClaude([{role:"user",content:"Analyze the current macro environment and return the JSON."}],
          MACRO_PROMPT.replace("{UTC_TIME}",utcTime).replace("{CONTEXT}","General crypto/futures market")),
      ]);

      let chartResult = parseJSON(chartRaw);
      if(!chartResult) {
        // Retry with stricter instruction
        const retryRaw = await callClaude([{
          role:"user",
          content:[
            {type:"image",source:{type:"base64",media_type:imageMime,data:imageBase64}},
            {type:"text",text:"Return ONLY a raw JSON object for this chart. No explanation, no markdown, no backticks. Start your response with { and end with }."}
          ]
        }], CHART_PROMPT);
        chartResult = parseJSON(retryRaw);
      }
      if(!chartResult) throw new Error("Analysis returned unexpected format — please try again");
      const macroResult = parseJSON(macroRaw);

      setSignal(chartResult); setMacro(macroResult); setPhase("done"); setTab("signal");

      // increment scan count
      incrementScans();
      const newCount = getScansUsed();
      setScansUsed(newCount);

      // save history (free: last 3, pro: unlimited)
      const entry={id:Date.now(),ts:new Date().toLocaleString(),signal:chartResult,macro:macroResult,outcome:null};
      saveHistory(entry);
      const h=loadHistory();
      setHistory(isPro?h:h.slice(0,3));

      // show post-scan upgrade prompt for free users
      if(!isPro) setShowPostScanPrompt(true);

    } catch(err){
      console.error(err);
      setError((err?.message||String(err)));
      setPhase("idle");
    }
  };

  const markOutcome = (id, outcome) => {
    const h = loadHistory().map(item => item.id===id ? {...item, outcome, pnl: outcome==="—" ? 0 : undefined} : item);
    window._tsHistory = h;
    setHistory(isPro ? h : h.slice(0,3));
  };

  const markAmount = (id, amount) => {
    const h = loadHistory().map(item => item.id===id ? {...item, pnl: amount} : item);
    window._tsHistory = h;
    setHistory(isPro ? h : h.slice(0,3));
    // update bankroll
    setBankroll(prev => prev !== null ? Math.max(0, prev + amount) : null);
  };

  const setBankrollAmount = () => {
    const val = parseFloat(bankrollInput);
    if(!isNaN(val) && val > 0) {
      setBankroll(val);
      setShowBankrollSet(false);
      setBankrollInput("");
    }
  };

  const resetBankroll = () => { setBankroll(null); setBankrollInput(""); };

  const wins=history.filter(h=>h.outcome==="WIN").length;
  const losses=history.filter(h=>h.outcome==="LOSS").length;
  const total=wins+losses;
  const winRate=total>0?Math.round(wins/total*100):null;
  const isAnalyzing=phase==="analyzing";
  const scansLeft = Math.max(0, FREE_SCAN_LIMIT - scansUsed);

  return(
    <div style={{background:C.bg,minHeight:"100vh",fontFamily:MONO,color:C.text}}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600&family=Bebas+Neue&display=swap');
        *{box-sizing:border-box;margin:0;padding:0}
        ::-webkit-scrollbar{width:3px}::-webkit-scrollbar-thumb{background:#1a3040}
        .dz{border:1px solid #1a2a38;cursor:pointer;background:#080d12;transition:all .2s}
        .dz:hover,.dz.drag{border-color:#00e676!important;background:#08120a!important}
        .btn{background:transparent;border:1px solid;font-family:'IBM Plex Mono',monospace;font-size:11px;letter-spacing:.12em;padding:9px 20px;cursor:pointer;transition:all .15s;text-transform:uppercase}
        .btn-g{border-color:#00e676;color:#00e676}.btn-g:hover{background:#00e676;color:#060a0d}
        .btn-g:disabled{border-color:#1a3040;color:#1a3040;cursor:not-allowed;background:transparent!important}
        .btn-gold{border-color:#f0b429;color:#f0b429}.btn-gold:hover{background:#f0b429;color:#060a0d}
        .btn-d{border-color:#2a4a5a;color:#4a6a7a}.btn-d:hover{border-color:#4a6a7a;color:#8aaabb}
        .tab-btn{background:transparent;border:none;border-bottom:2px solid transparent;font-family:'IBM Plex Mono',monospace;font-size:11px;letter-spacing:.1em;padding:8px 16px;cursor:pointer;color:#2a4a5a;transition:all .15s;text-transform:uppercase}
        .tab-btn.active{color:#00e676;border-bottom-color:#00e676}
        .tab-btn:hover:not(.active){color:#c8d8e8}
        @keyframes fadeUp{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
        @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
        @keyframes scanline{0%{left:-50%}100%{left:110%}}
        @keyframes blink{0%,100%{opacity:1}50%{opacity:0}}
        @keyframes shimmer{0%{left:-100%}100%{left:200%}}
        .fade-up{animation:fadeUp .35s ease forwards}
        .pulse{animation:pulse 1.2s ease-in-out infinite}
        .blink{animation:blink 1s step-end infinite}
        .scanbar{position:relative;height:1px;background:#0d1a24;overflow:hidden}
        .scanbar::after{content:'';position:absolute;top:0;height:100%;width:50%;background:linear-gradient(90deg,transparent,#00e676,transparent);animation:scanline 1.2s linear infinite}
        .layout{display:grid;grid-template-columns:1fr 340px;gap:1px;background:#0d1a24}
        @media(max-width:860px){.layout{grid-template-columns:1fr}}
        .section{margin-bottom:22px}
        .sh{font-size:9px;letter-spacing:.18em;color:#1a3040;text-transform:uppercase;margin-bottom:10px;padding-bottom:6px;border-bottom:1px solid #0d1a24}
        .grid4{display:grid;grid-template-columns:repeat(4,1fr);gap:1px;background:#0d1a24}
        .grid4>div{background:#080d12;padding:12px 14px;text-align:center}
        .ind-wrap{display:flex;flex-wrap:wrap;gap:5px}
        .warn{padding:7px 10px;border-left:2px solid #ff1744;color:#ff8899;font-size:11px;margin:4px 0;background:rgba(255,23,68,.04)}
        .pro-badge{background:#f0b42922;border:1px solid #f0b42944;color:#f0b429;font-size:9px;padding:2px 8px;letter-spacing:.12em;vertical-align:middle}
        @keyframes adprogress{from{width:0%}to{width:100%}}
        @keyframes shimmer{0%{transform:translateX(-100%)}100%{transform:translateX(400%)}}
        @keyframes adprogress{from{width:0%}to{width:100%}}
        @keyframes shimmer{0%{transform:translateX(-100%)}100%{transform:translateX(400%)}}
      `}</style>

      {/* scanlines */}
      <div style={{position:"fixed",inset:0,background:"repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,230,118,.007) 2px,rgba(0,230,118,.007) 4px)",pointerEvents:"none",zIndex:0}}/>

      {/* Upgrade modal */}
      {showUpgrade && <UpgradeModal onClose={()=>setShowUpgrade(false)} trigger={upgradeReason} onUpgrade={activatePro}/>}

      <div style={{position:"relative",zIndex:1,maxWidth:1300,margin:"0 auto",padding:"28px 20px"}}>

        {/* ── HEADER ── */}
        <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-end",marginBottom:20}}>
          <div>
            <div style={{fontSize:9,color:"#1a4030",letterSpacing:".2em",marginBottom:4}}>TRADESCRIPT // SIGNAL DECODER</div>
            <div style={{display:"flex",alignItems:"center",gap:12}}>
              <div style={{fontFamily:BEBAS,fontSize:46,color:C.green,lineHeight:1,letterSpacing:".04em"}}>SIGNAL DECODER</div>
              {isPro
                ? <span style={{fontFamily:BEBAS,fontSize:18,color:C.proGold,border:`1px solid ${C.proGold}55`,padding:"2px 10px",letterSpacing:".1em"}}>PRO</span>
                : <span style={{fontFamily:BEBAS,fontSize:14,color:C.dim,border:`1px solid ${C.dim}44`,padding:"2px 8px",letterSpacing:".1em"}}>FREE</span>
              }
            </div>
            <div style={{fontSize:10,color:"#6a9ab8",marginTop:3,letterSpacing:".1em"}}>
              {isPro?"PARALLEL ANALYSIS · FULL INDICATORS · MACRO · UNLIMITED SCANS · EXPORT":"BASIC SIGNAL ANALYSIS · UPGRADE FOR FULL INDICATORS & MACRO"}
            </div>
          </div>
          <div style={{display:"flex",flexDirection:"column",alignItems:"flex-end",gap:8}}>
            {/* Tier toggle / upgrade CTA */}
            {!isPro?(
              <div style={{display:"flex",flexDirection:"column",alignItems:"flex-end",gap:6}}>
                <button className="btn btn-gold" onClick={()=>openUpgrade("header")} style={{fontSize:11,padding:"7px 16px"}}>
                  ⭐ UPGRADE TO PRO — {PRO_MONTHLY_PRICE}/mo
                </button>
                {/* scan dots */}
                <div style={{display:"flex",alignItems:"center",gap:5}}>
                  <span style={{fontSize:9,color:C.dim,letterSpacing:".1em"}}>TODAY</span>
                  {Array.from({length:FREE_SCAN_LIMIT}).map((_,i)=>(
                    <div key={i} style={{width:8,height:8,borderRadius:"50%",background:i<scansUsed?C.green:C.bg3,border:`1px solid ${i<scansUsed?C.green:C.dim}`}}/>
                  ))}
                  <span style={{fontSize:9,color:scansLeft===0?C.red:C.dim}}>{scansLeft} left</span>
                </div>
              </div>
            ):(
              <div style={{display:"flex",flexDirection:"column",alignItems:"flex-end",gap:4}}>
                {winRate!==null&&<div style={{textAlign:"right"}}><div style={{fontFamily:BEBAS,fontSize:32,color:winRate>=60?C.green:winRate>=45?C.yellow:C.red,lineHeight:1}}>{winRate}%</div><div style={{fontSize:9,color:C.dim}}>WIN RATE · {total} GRADED</div></div>}
                <button className="btn btn-d" onClick={()=>setIsPro(false)} style={{fontSize:9,padding:"4px 10px"}}>demo free mode</button>
              </div>
            )}
          </div>
        </div>

        {/* ── UPLOAD ── */}
        <div
          className={`dz ${dragging?"drag":""}`}
          style={{padding:image?"12px 16px":"24px",textAlign:image?"left":"center",marginBottom:10}}
          onDragOver={e=>{e.preventDefault();setDragging(true);}}
          onDragLeave={()=>setDragging(false)}
          onDrop={onDrop}
          onClick={()=>!image&&fileRef.current.click()}
        >
          {image?(
            <div style={{display:"flex",alignItems:"center",gap:14}}>
              <img src={image} alt="" style={{height:64,width:112,objectFit:"cover",opacity:.8}}/>
              <div>
                <div style={{fontSize:11,color:C.green,marginBottom:3}}>■ chart loaded</div>
                <div style={{fontSize:10,color:C.dim,cursor:"pointer",textDecoration:"underline"}} onClick={e=>{e.stopPropagation();fileRef.current.click();}}>swap image</div>
              </div>
              {!isPro&&scansLeft===0&&(
                <div style={{marginLeft:"auto",background:"#0a0800",border:`1px solid ${C.red}33`,padding:"8px 14px"}}>
                  <div style={{fontSize:10,color:C.red}}>Daily limit reached</div>
                  <button onClick={()=>openUpgrade("limit")} style={{background:"transparent",border:"none",color:C.proGold,fontSize:10,cursor:"pointer",fontFamily:MONO,padding:0,marginTop:3}}>Upgrade for unlimited →</button>
                </div>
              )}
            </div>
          ):(
            <>
              <div style={{fontSize:24,opacity:.12,marginBottom:6}}>⬡</div>
              <div style={{fontSize:11,color:C.dim,letterSpacing:".12em"}}>DROP CHART SCREENSHOT</div>
              <div style={{fontSize:10,color:"#5a7a8a",marginTop:3}}>png · jpg · webp · any platform · beginner or pro charts welcome</div>
            </>
          )}
        </div>
        <input ref={fileRef} type="file" accept="image/*" style={{display:"none"}} onChange={e=>processFile(e.target.files[0])}/>

        {/* ── CONTROLS ── */}
        <div style={{display:"flex",gap:8,alignItems:"center",flexWrap:"wrap",marginBottom:10}}>
          <button className="btn btn-g" disabled={!image||isAnalyzing||(!isPro&&scansLeft===0)} onClick={analyze}>
            {isAnalyzing?"DECODING…":"DECODE SIGNAL ↗"}
          </button>
          {isPro&&signal&&<button className="btn btn-gold" onClick={()=>doExportCard(signal,macro)}>EXPORT CARD ↓</button>}
          {!isPro&&signal&&(
            <button className="btn btn-d" onClick={()=>doExportCardFree(signal)} title="Share to Twitter">
              SHARE CARD ↓
            </button>
          )}
          {signal&&<button className="btn btn-d" onClick={()=>{setImage(null);setImageBase64(null);setSignal(null);setMacro(null);setPhase("idle");setShowPostScanPrompt(false);}}>RESET</button>}
          {isAnalyzing&&(
            <div style={{display:"flex",alignItems:"center",gap:8,fontSize:10,color:"#2a6a4a"}}>
              <span className="pulse" style={{width:6,height:6,borderRadius:"50%",background:C.green,display:"inline-block"}}/>
              chart + macro running in parallel…
            </div>
          )}
        </div>
        {isAnalyzing&&<div className="scanbar" style={{marginBottom:10}}/>}
        {error&&<div style={{border:`1px solid ${C.red}`,padding:"10px 14px",color:"#ff8899",fontSize:11,marginBottom:10}}>✗ {error}</div>}

        {/* Ad banner (free only, between upload and results) */}
        {!isPro&&signal&&<AdBanner/>}

        {/* Post-scan upgrade prompt (free only) */}
        {!isPro&&showPostScanPrompt&&signal&&(
          <div className="fade-up" style={{background:"#0a0c08",border:`1px solid ${C.proGold}33`,padding:"14px 18px",marginBottom:10,display:"flex",alignItems:"center",justifyContent:"space-between",gap:16}}>
            <div>
              <div style={{fontSize:11,color:C.proGold,fontWeight:600,marginBottom:3}}>
                ⭐ Unlock the full picture
              </div>
              <div style={{fontSize:11,color:C.dim}}>
                You're missing: full indicator breakdown, macro context, chart health coaching
                {scansLeft===0?`, and you've used all ${FREE_SCAN_LIMIT} free scans today.`:"."}</div>
            </div>
            <div style={{display:"flex",gap:8,flexShrink:0}}>
              <button className="btn btn-gold" onClick={()=>openUpgrade("post_scan")} style={{padding:"7px 14px",fontSize:11}}>GET PRO</button>
              <button className="btn btn-d" onClick={()=>setShowPostScanPrompt(false)} style={{padding:"7px 10px",fontSize:11}}>✕</button>
            </div>
          </div>
        )}

        {/* ── TABS ── */}
        {(signal||history.length>0)&&(
          <div style={{borderBottom:`1px solid ${C.bg3}`,marginBottom:1,display:"flex",gap:0}}>
            {signal&&<button className={`tab-btn ${tab==="signal"?"active":""}`} onClick={()=>setTab("signal")}>signal</button>}
            {signal&&<button className={`tab-btn ${tab==="macro"?"active":""}`} onClick={()=>{ if(!isPro){openUpgrade("macro");return;} setTab("macro"); }}>
              macro {!isPro&&<span className="pro-badge" style={{marginLeft:4}}>PRO</span>}
            </button>}
            <button className={`tab-btn ${tab==="history"?"active":""}`} onClick={()=>setTab("history")}>
              history {history.length>0?`(${history.length})`:""}
            </button>
          </div>
        )}

        {/* ── SIGNAL TAB ── */}
        {signal&&tab==="signal"&&(
          <div className="fade-up layout">
            {/* LEFT */}
            <div style={{background:C.bg2,padding:"22px"}}>

              {/* Bias */}
              <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start",marginBottom:14}}>
                <div>
                  <div style={{fontFamily:BEBAS,fontSize:76,color:biasColor(signal.bias),lineHeight:1}}>{signal.bias}</div>
                  <div style={{fontSize:9,color:C.dim,letterSpacing:".12em",marginTop:1}}>{(signal.setup_type||"").toUpperCase()}</div>
                </div>
                <div style={{textAlign:"right"}}>
                  <div style={{fontSize:24,fontWeight:600,color:C.text}}>{signal.current_price}</div>
                  <div style={{fontSize:9,color:C.dim,letterSpacing:".1em"}}>{signal.instrument} · {signal.timeframe}</div>
                  <div style={{fontSize:10,color:"#5a8aaa",marginTop:2}}>{signal.market_session}</div>
                </div>
              </div>

              {/* Confidence — always visible */}
              <div style={{background:C.bg,border:`1px solid ${C.bg3}`,padding:"16px",marginBottom:18,display:"grid",gridTemplateColumns:isPro?"1fr 1fr":"1fr",gap:20}}>
                <ScoreBar
                  label="SIGNAL CONFIDENCE"
                  value={signal.confidence}
                  subtitle={signal.confidence>=70?"HIGH CONVICTION":signal.confidence>=45?"MODERATE — proceed with caution":"LOW — add more indicators to your chart"}
                />
                {isPro&&(
                  <ScoreBar
                    label="CHART HEALTH"
                    value={signal.chart_health}
                    subtitle={`${signal.chart_level||"UNKNOWN"} CHART`}
                  />
                )}
                {!isPro&&(
                  <div style={{display:"flex",alignItems:"center",gap:10,padding:"8px 12px",background:"#0a0c08",border:`1px solid ${C.proGold}22`}}>
                    <div style={{flex:1}}>
                      <div style={{fontSize:9,color:C.proGold,letterSpacing:".1em",marginBottom:2}}>CHART HEALTH SCORE</div>
                      <div style={{fontSize:11,color:C.dim}}>See how strong your chart setup is</div>
                    </div>
                    <button onClick={()=>openUpgrade("chart_health")} style={{background:"transparent",border:`1px solid ${C.proGold}55`,color:C.proGold,fontFamily:MONO,fontSize:10,padding:"5px 10px",cursor:"pointer"}}>PRO ↗</button>
                  </div>
                )}
              </div>

              {/* Beginner tip — pro only */}
              {isPro&&signal.beginner_tip&&(
                <div style={{background:"#060e08",border:"1px solid #1a3a22",padding:"11px 14px",marginBottom:18,display:"flex",gap:10}}>
                  <span style={{fontSize:14,flexShrink:0}}>💡</span>
                  <div>
                    <div style={{fontSize:9,color:"#2a6a3a",letterSpacing:".12em",marginBottom:3}}>WHAT THIS MEANS FOR YOU</div>
                    <div style={{fontSize:12,color:"#5a9a6a",lineHeight:1.6}}>{signal.beginner_tip}</div>
                  </div>
                </div>
              )}

              {/* Price levels — always visible */}
              <div className="section">
                <div className="sh">price levels</div>
                <div className="grid4">
                  {[
                    {label:"ENTRY",val:signal.entry,color:C.blue},
                    {label:"STOP LOSS",val:signal.stop,color:C.red},
                    {label:"TARGET 1",val:signal.target1,color:C.green},
                    {label:"TARGET 2",val:signal.target2,color:"#00c853"},
                  ].map(({label,val,color})=>(
                    <div key={label}>
                      <div style={{fontSize:8,color:C.dimmer,letterSpacing:".1em",marginBottom:5}}>{label}</div>
                      <div style={{fontSize:15,fontWeight:600,color}}>{val||"—"}</div>
                    </div>
                  ))}
                </div>
                <div style={{background:C.bg2,padding:"9px 14px",borderTop:`1px solid ${C.bg3}`,display:"flex",justifyContent:"space-between",alignItems:"center"}}>
                  <span style={{fontSize:9,color:C.dim,letterSpacing:".12em"}}>RISK / REWARD</span>
                  <span style={{fontSize:20,fontWeight:600,color:C.yellow,fontFamily:BEBAS}}>{signal.rr||"—"}</span>
                </div>
              </div>

              {/* Indicators — pro only */}
              {isPro?(
                <div className="section">
                  <div className="sh">indicators detected</div>
                  <div className="ind-wrap">
                    {Object.entries({MACD:signal.indicators?.macd,RSI:signal.indicators?.rsi,VWAP:signal.indicators?.vwap,Bollinger:signal.indicators?.bbands,ATR:signal.indicators?.atr,OBV:signal.indicators?.obv,ADX:signal.indicators?.adx,EMA:signal.indicators?.ema,Fibonacci:signal.indicators?.fib}).map(([k,v])=><IndicatorPill key={k} label={k} value={v}/>)}
                  </div>
                </div>
              ):(
                <div className="section">
                  <div className="sh">indicators detected <span className="pro-badge" style={{marginLeft:6}}>PRO</span></div>
                  <ProLock onUpgrade={()=>openUpgrade("indicators")} label="FULL INDICATOR BREAKDOWN"/>
                </div>
              )}

              {/* Missing indicators — pro only */}
              {isPro&&signal.missing_indicators?.length>0&&(
                <div className="section">
                  <div className="sh" style={{color:"#6a5a10",borderColor:"#2a2010"}}>add these to strengthen your signal</div>
                  {signal.missing_indicators.map((m,i)=>(
                    <div key={i} style={{display:"flex",gap:10,padding:"9px 11px",background:C.bg,border:"1px solid #1a2010",marginBottom:5}}>
                      <div style={{width:5,height:5,background:C.yellow,borderRadius:"50%",marginTop:5,flexShrink:0}}/>
                      <div>
                        <div style={{fontSize:11,fontWeight:600,color:C.yellow,marginBottom:2}}>{m.name}</div>
                        <div style={{fontSize:11,color:"#5a6a4a",lineHeight:1.5}}>{m.why}</div>
                      </div>
                    </div>
                  ))}
                </div>
              )}

              {/* Reasoning — always visible */}
              <div className="section">
                <div className="sh">trade thesis</div>
                <div style={{fontSize:12,color:C.textMid,lineHeight:1.8,paddingLeft:12,borderLeft:"2px solid #1a3040"}}>{signal.reasoning}</div>
              </div>

              {/* Correlated + Key levels + Invalidation — pro only */}
              {isPro&&signal.correlated?.length>0&&(
                <div className="section">
                  <div className="sh">correlated assets</div>
                  {signal.correlated.map((c,i)=>(
                    <div key={i} style={{display:"flex",gap:12,padding:"7px 11px",border:"1px solid #1a2a38",marginBottom:5,fontSize:11}}>
                      <span style={{color:"#4a8fa8",fontWeight:600,minWidth:44}}>{c.symbol}</span>
                      <span style={{color:C.textDim}}>{c.reading}</span>
                    </div>
                  ))}
                </div>
              )}
              {signal.key_levels?.length>0&&(
                <div className="section">
                  <div className="sh">key levels</div>
                  <div style={{display:"flex",flexWrap:"wrap",gap:5}}>
                    {signal.key_levels.map((l,i)=><span key={i} style={{border:"1px solid #1a2a38",padding:"3px 10px",fontSize:11,color:C.textDim}}>{l}</span>)}
                  </div>
                </div>
              )}
              {signal.invalidation?.length>0&&(
                <div className="section">
                  <div className="sh">invalidation</div>
                  {signal.invalidation.map((w,i)=><div key={i} className="warn">⚠ {w}</div>)}
                </div>
              )}
            </div>

            {/* RIGHT sidebar */}
            <div style={{background:C.bg2,borderLeft:`1px solid ${C.bg3}`,padding:"22px"}}>
              <div className="sh">macro snapshot {!isPro&&<span className="pro-badge" style={{marginLeft:4}}>PRO</span>}</div>
              {isPro&&macro?(
                <div>
                  <div style={{background:C.bg,border:`1px solid ${macroColor(macro.macro_score)}1a`,padding:"14px",marginBottom:14}}>
                    <div style={{fontSize:9,color:C.dim,letterSpacing:".12em",marginBottom:4}}>MARKET SENTIMENT</div>
                    <div style={{fontFamily:BEBAS,fontSize:32,color:macroColor(macro.macro_score),lineHeight:1}}>{macro.macro_label}</div>
                    <div style={{height:4,background:C.bg3,marginTop:8}}>
                      <div style={{height:"100%",width:`${Math.abs(macro.macro_score)}%`,background:macroColor(macro.macro_score),transition:"width 1s"}}/>
                    </div>
                    <div style={{fontSize:9,color:macroColor(macro.macro_score),marginTop:4}}>{macro.macro_score>0?"+":""}{macro.macro_score} / 100</div>
                  </div>
                  <div style={{fontSize:11,color:C.textDim,lineHeight:1.6,marginBottom:14,paddingLeft:10,borderLeft:"2px solid #1a2a38"}}>{macro.session_note}</div>
                  {macro.headlines?.slice(0,3).map((h,i)=>(
                    <div key={i} style={{padding:"8px 0",borderBottom:`1px solid ${C.bg3}`,display:"flex",gap:8}}>
                      <div style={{fontSize:9,color:impactColor(h.impact),border:`1px solid ${impactColor(h.impact)}33`,padding:"2px 6px",whiteSpace:"nowrap",height:"fit-content",marginTop:1}}>{h.impact}</div>
                      <div style={{fontSize:11,color:"#8aabb8"}}>{h.title}</div>
                    </div>
                  ))}
                  <button className="tab-btn active" style={{marginTop:12,fontSize:10,padding:"6px 0"}} onClick={()=>setTab("macro")}>see full macro →</button>
                </div>
              ):(
                <div style={{background:"#080c10",border:`1px solid ${C.proGold}22`,padding:"20px",textAlign:"center"}}>
                  <div style={{fontSize:11,color:C.proGold,marginBottom:8}}>⭐ Macro Context</div>
                  <div style={{fontSize:11,color:C.dim,lineHeight:1.6,marginBottom:14}}>Live session analysis, risk-on/off score, and market-moving headlines — tailored to your trade.</div>
                  <button className="btn btn-gold" onClick={()=>openUpgrade("macro")} style={{width:"100%",padding:"10px"}}>UNLOCK WITH PRO</button>
                </div>
              )}

              {/* Captain Crypto link — always visible */}
              <div style={{marginTop:20,padding:"14px",background:C.bg,border:`1px solid ${C.bg3}`}}>
                <div style={{fontSize:9,color:C.dimmer,letterSpacing:".1em",marginBottom:8}}>LEARN TO TRADE</div>
                <div style={{fontSize:12,color:C.textMid,marginBottom:10,lineHeight:1.5}}>Want to understand these signals better?</div>
                <a href="https://www.tradingview.com/pricing/?share_your_love=maxresults4u" target="_blank" rel="noopener noreferrer" style={{display:"block",fontSize:11,color:C.blue,textDecoration:"none",padding:"6px 0",borderBottom:`1px solid ${C.bg3}`}}>→ TradingView Pro — best charting platform</a>
                <a href="https://exchange.gemini.com/register?referral=9nllwes7&type=referral" target="_blank" rel="noopener noreferrer" style={{display:"block",fontSize:11,color:C.blue,textDecoration:"none",padding:"6px 0",borderBottom:`1px solid ${C.bg3}`}}>→ Gemini Exchange — get started free</a>
                <a href="https://www.captaincryptosuperslots.com" target="_blank" rel="noopener noreferrer" style={{display:"flex",alignItems:"center",gap:8,fontSize:11,color:C.yellow,textDecoration:"none",padding:"8px 0"}}>
                  <img src="data:image/png;base64,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" width={24} height={24} style={{borderRadius:3,objectFit:"cover"}} alt=""/>
                  Captain Crypto Super Slots ↗
                </a>
              </div>
            </div>
          </div>
        )}

        {/* ── MACRO TAB (pro) ── */}
        {tab==="macro"&&macro&&isPro&&(
          <div className="fade-up" style={{background:C.bg2,padding:"22px"}}>
            <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:20,marginBottom:20}}>
              <div style={{background:C.bg,border:`1px solid ${macroColor(macro.macro_score)}22`,padding:"16px"}}>
                <div style={{fontSize:9,color:C.dim,letterSpacing:".12em",marginBottom:6}}>MARKET SENTIMENT</div>
                <div style={{fontFamily:BEBAS,fontSize:42,color:macroColor(macro.macro_score),lineHeight:1}}>{macro.macro_label}</div>
                <div style={{height:5,background:C.bg3,marginTop:10}}>
                  <div style={{height:"100%",width:`${Math.abs(macro.macro_score)}%`,background:macroColor(macro.macro_score),transition:"width 1s"}}/>
                </div>
                <div style={{fontSize:9,color:macroColor(macro.macro_score),marginTop:5}}>Score: {macro.macro_score>0?"+":""}{macro.macro_score}</div>
              </div>
              <div style={{background:C.bg,border:`1px solid ${C.bg3}`,padding:"16px"}}>
                <div style={{fontSize:9,color:C.dim,letterSpacing:".12em",marginBottom:8}}>ACTIVE SESSION</div>
                <div style={{fontSize:12,color:C.textMid,lineHeight:1.7}}>{macro.session_note}</div>
              </div>
            </div>
            {macro.key_events_today?.length>0&&(
              <div className="section">
                <div className="sh">today's events</div>
                {macro.key_events_today.map((e,i)=>(
                  <div key={i} style={{fontSize:11,color:C.textDim,padding:"5px 0",borderBottom:`1px solid ${C.bg3}`}}>
                    <span style={{color:C.yellow,marginRight:8}}>▸</span>{e}
                  </div>
                ))}
              </div>
            )}
            <div className="section">
              <div className="sh">headlines</div>
              {macro.headlines?.map((h,i)=>(
                <div key={i} style={{padding:"11px 0",borderBottom:`1px solid ${C.bg3}`,display:"flex",gap:10}}>
                  <div style={{fontSize:9,color:impactColor(h.impact),border:`1px solid ${impactColor(h.impact)}33`,padding:"2px 6px",whiteSpace:"nowrap",height:"fit-content",marginTop:2}}>{h.impact}</div>
                  <div>
                    <div style={{fontSize:12,color:"#9ab8c8",fontWeight:500,marginBottom:3}}>{h.title}</div>
                    <div style={{fontSize:11,color:C.textDim,lineHeight:1.5}}>{h.detail}</div>
                  </div>
                </div>
              ))}
            </div>
            <div className="section">
              <div className="sh">macro summary</div>
              <div style={{fontSize:12,color:C.textMid,lineHeight:1.8,paddingLeft:12,borderLeft:"2px solid #1a3040"}}>{macro.macro_summary}</div>
            </div>
          </div>
        )}

        {/* ── HISTORY TAB ── */}
        {tab==="history"&&(()=>{
          const gradedPnl = history.filter(h=>h.pnl!==undefined&&h.pnl!==null&&h.outcome!=="—");
          const totalPnl = gradedPnl.reduce((sum,h)=>sum+(h.pnl||0),0);
          const startBank = bankroll !== null ? bankroll - totalPnl : null;
          const bankrollColor = bankroll!==null ? (bankroll > (startBank||0) ? C.green : bankroll < (startBank||0) ? C.red : C.dim) : C.dim;
          const pnlColor = totalPnl > 0 ? C.green : totalPnl < 0 ? C.red : C.dim;
          return (
          <div className="fade-up" style={{background:C.bg2}}>

            {/* ── BANKROLL CHALLENGE HEADER ── */}
            <div style={{background:"#060e0a",borderBottom:`1px solid #1a3a22`,padding:"16px 20px"}}>
              <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start",gap:16,flexWrap:"wrap"}}>
                <div>
                  <div style={{fontFamily:BEBAS,fontSize:11,color:"#2a6a3a",letterSpacing:".2em",marginBottom:4}}>BANKROLL CHALLENGE</div>
                  {bankroll === null ? (
                    <div>
                      {!showBankrollSet ? (
                        <button onClick={()=>setShowBankrollSet(true)}
                          style={{background:"transparent",border:`1px solid ${C.green}44`,color:C.green,fontFamily:MONO,fontSize:11,padding:"7px 16px",cursor:"pointer",letterSpacing:".1em"}}>
                          + SET STARTING BANKROLL
                        </button>
                      ) : (
                        <div style={{display:"flex",alignItems:"center",gap:8}}>
                          <span style={{fontSize:14,color:C.dim}}>$</span>
                          <input
                            type="number" placeholder="e.g. 10000" value={bankrollInput}
                            onChange={e=>setBankrollInput(e.target.value)}
                            onKeyDown={e=>e.key==="Enter"&&setBankrollAmount()}
                            autoFocus
                            style={{background:"#080d12",border:`1px solid ${C.green}44`,color:C.text,fontFamily:MONO,fontSize:13,padding:"7px 12px",width:160,outline:"none"}}
                          />
                          <button onClick={setBankrollAmount}
                            style={{background:C.green,border:"none",color:"#060a0d",fontFamily:MONO,fontSize:11,fontWeight:600,padding:"7px 14px",cursor:"pointer"}}>
                            START ↵
                          </button>
                          <button onClick={()=>{setShowBankrollSet(false);setBankrollInput("");}}
                            style={{background:"transparent",border:`1px solid ${C.dim}44`,color:C.dim,fontFamily:MONO,fontSize:11,padding:"7px 10px",cursor:"pointer"}}>✕</button>
                        </div>
                      )}
                    </div>
                  ) : (
                    <div style={{display:"flex",alignItems:"baseline",gap:6}}>
                      <div style={{fontFamily:BEBAS,fontSize:42,color:bankrollColor,lineHeight:1}}>
                        ${bankroll.toLocaleString("en-US",{minimumFractionDigits:0,maximumFractionDigits:2})}
                      </div>
                      <div style={{fontSize:11,color:C.dim}}>current bankroll</div>
                    </div>
                  )}
                </div>

                {/* Stats grid */}
                {bankroll !== null && (
                  <div style={{display:"flex",gap:1,background:C.bg3}}>
                    {[
                      {label:"STARTING",val:`$${(startBank||0).toLocaleString("en-US",{minimumFractionDigits:0,maximumFractionDigits:0})}`,color:C.dim},
                      {label:"TOTAL P&L",val:`${totalPnl>=0?"+":""}$${Math.abs(totalPnl).toLocaleString("en-US",{minimumFractionDigits:0,maximumFractionDigits:2})}`,color:pnlColor},
                      {label:"RETURN",val:startBank>0?`${((totalPnl/startBank)*100).toFixed(1)}%`:"—",color:pnlColor},
                      {label:"WIN RATE",val:winRate!=null?`${winRate}%`:"—",color:winRate>=60?C.green:winRate>=45?C.yellow:C.red},
                    ].map(({label,val,color})=>(
                      <div key={label} style={{background:C.bg2,padding:"10px 16px",textAlign:"center",minWidth:80}}>
                        <div style={{fontSize:8,color:C.dimmer,letterSpacing:".12em",marginBottom:3}}>{label}</div>
                        <div style={{fontSize:16,fontWeight:700,color,fontFamily:BEBAS}}>{val}</div>
                      </div>
                    ))}
                    <div style={{background:C.bg2,padding:"10px 12px",display:"flex",alignItems:"center"}}>
                      <button onClick={()=>{if(window.confirm("Reset bankroll challenge? This won't delete your signal history."))resetBankroll();}}
                        style={{background:"transparent",border:`1px solid ${C.dim}33`,color:C.dimmer,fontFamily:MONO,fontSize:9,padding:"4px 8px",cursor:"pointer"}}>RESET</button>
                    </div>
                  </div>
                )}
              </div>

              {/* Bankroll bar */}
              {bankroll !== null && startBank > 0 && (
                <div style={{marginTop:12}}>
                  <div style={{height:4,background:C.bg3,borderRadius:0}}>
                    <div style={{
                      height:"100%",
                      width:`${Math.min(100,Math.max(0,(bankroll/startBank)*100))}%`,
                      background:bankrollColor,
                      transition:"width 1s ease"
                    }}/>
                  </div>
                  <div style={{display:"flex",justifyContent:"space-between",fontSize:9,color:C.dimmer,marginTop:4}}>
                    <span>$0</span>
                    <span style={{color:bankrollColor}}>{((bankroll/startBank)*100).toFixed(1)}% of starting bankroll</span>
                    <span>${(startBank).toLocaleString("en-US",{maximumFractionDigits:0})}</span>
                  </div>
                </div>
              )}
            </div>

            {/* Stat bar (wins/losses) */}
            {total > 0 && (
              <div style={{display:"grid",gridTemplateColumns:"repeat(3,1fr)",gap:1,background:C.bg3,borderBottom:`1px solid ${C.bg3}`}}>
                {[
                  {label:"TOTAL SCANS",val:history.length,color:C.text},
                  {label:"WINS",val:wins,color:C.green},
                  {label:"LOSSES",val:losses,color:C.red},
                ].map(({label,val,color})=>(
                  <div key={label} style={{background:C.bg2,padding:"10px 14px",textAlign:"center"}}>
                    <div style={{fontSize:8,color:C.dim,letterSpacing:".14em",marginBottom:3}}>{label}</div>
                    <div style={{fontSize:20,fontWeight:700,color,fontFamily:BEBAS}}>{val}</div>
                  </div>
                ))}
              </div>
            )}

            {!isPro&&(
              <div style={{padding:"10px 16px",background:"#0a0c08",borderBottom:`1px solid ${C.bg3}`,display:"flex",alignItems:"center",justifyContent:"space-between"}}>
                <div style={{fontSize:11,color:C.dim}}>Showing last 3 signals · <span style={{color:C.proGold}}>Pro unlocks full history</span></div>
                <button className="btn btn-gold" onClick={()=>openUpgrade("history")} style={{fontSize:10,padding:"5px 12px"}}>UPGRADE</button>
              </div>
            )}

            {history.length===0?(
              <div style={{padding:"40px",textAlign:"center",fontSize:11,color:C.dimmer}}>
                No signals yet — decode your first chart to start the challenge
              </div>
            ):(
              <div>
                <div style={{padding:"8px 12px",fontSize:9,color:C.dimmer,letterSpacing:".12em",borderBottom:`1px solid ${C.bg3}`,display:"flex",justifyContent:"space-between"}}>
                  <span>SIGNAL HISTORY · MARK WIN/LOSS · LOG $ AMOUNT TO TRACK BANKROLL</span>
                </div>
                {history.map(item=>(
                  <HistoryRow
                    key={item.id}
                    item={item}
                    onOutcome={markOutcome}
                    onAmount={markAmount}
                  />
                ))}
              </div>
            )}
          </div>
        );})()}

        <a href="https://www.captaincryptosuperslots.com" target="_blank" rel="noopener noreferrer"
          style={{
            display:"flex", alignItems:"center", gap:20,
            background:"linear-gradient(135deg,#0a0800 0%,#1a1000 50%,#0a0600 100%)",
            border:"1px solid #f0b42944",
            marginTop:16, padding:"14px 24px",
            textDecoration:"none", cursor:"pointer",
            position:"relative", overflow:"hidden",
          }}>
          <div style={{position:"absolute",top:0,left:"-100%",width:"30%",height:"100%",background:"linear-gradient(90deg,transparent,rgba(240,180,41,0.08),transparent)",animation:"shimmer 3s linear infinite",pointerEvents:"none"}}/>
          <img
            src="data:image/png;base64,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"
            height={60}
            style={{objectFit:"contain",flexShrink:0,borderRadius:4}}
            alt="Captain Crypto Super Slots"
          />
          <div style={{flex:1}}>
            <div style={{fontFamily:BEBAS,fontSize:26,color:"#f0b429",lineHeight:1,letterSpacing:".06em"}}>
              THE CAPTAIN CRYPTO SUPER SLOTS
            </div>
            <div style={{fontSize:12,color:"#c8a040",marginTop:4,letterSpacing:".06em"}}>
              Play FREE sweepstakes crypto slots — Bitcoin, Ethereum & more ⚡
            </div>
          </div>
          <div style={{flexShrink:0,background:"#f0b429",color:"#060a0d",fontFamily:MONO,fontSize:12,fontWeight:700,padding:"10px 20px",letterSpacing:".1em",whiteSpace:"nowrap"}}>
            PLAY FREE NOW ↗
          </div>
        </a>
        <div style={{fontSize:9,color:"#2a4a5a",marginTop:8,letterSpacing:".07em"}}>
          NOT FINANCIAL ADVICE · ENTERTAINMENT ONLY · TRADESCRIPT<span className="blink">_</span>
        </div>
      </div>
    </div>
  );
}
