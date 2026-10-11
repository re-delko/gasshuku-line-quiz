// 3画面（参加者・管理・スクリーン）で共有する設定と処理

// ===== 接続設定（セットアップ時にここだけ書き換える） =====
const CONFIG = {
  SUPABASE_URL: 'https://rhmbazbplrtibqrryfnl.supabase.co',
  SUPABASE_KEY: 'sb_publishable_3nio0KJcZficuiblQluOqA_WrP6j4Y1', // Supabase の Settings → API Keys → Publishable key
  LIFF_ID: '2010842935-ecpZbK4y',
};
const LIFF_URL = `https://liff.line.me/${CONFIG.LIFF_ID}`;

const sb = window.supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_KEY);

const REACTIONS = [
  { kind: 'clap', emoji: '👏' },
  { kind: 'party', emoji: '🎉' },
  { kind: 'laugh', emoji: '😂' },
  { kind: 'heart', emoji: '❤️' },
];
const reactionEmoji = kind => (REACTIONS.find(r => r.kind === kind) || { emoji: '✨' }).emoji;

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
// 改行を残して表示する
const escBr = s => esc(s).replace(/\n/g, '<br>');

// クイズの4択：色と形（色だけに頼らず形でも見分けられるようにする）
const SHAPES = [
  { name: 'さんかく', color: '#E5322D', svg: '<svg viewBox="0 0 40 40"><path d="M20 5 L36 34 H4 Z"/></svg>' },
  { name: 'ひしがた', color: '#1B6FD8', svg: '<svg viewBox="0 0 40 40"><path d="M20 3 L37 20 L20 37 L3 20 Z"/></svg>' },
  { name: 'まる', color: '#E6A100', svg: '<svg viewBox="0 0 40 40"><circle cx="20" cy="20" r="16"/></svg>' },
  { name: 'しかく', color: '#1E9E54', svg: '<svg viewBox="0 0 40 40"><rect x="5" y="5" width="30" height="30" rx="3"/></svg>' },
];

// 紙吹雪（発表・ビンゴ・1位のとき）
function confetti(n = 80) {
  const box = document.createElement('div');
  box.className = 'confetti';
  const colors = ['#F23C08', '#FFB703', '#1B6FD8', '#1E9E54', '#E5322D', '#ffffff'];
  for (let i = 0; i < n; i++) {
    const c = document.createElement('i');
    c.style.left = Math.random() * 100 + '%';
    c.style.background = colors[i % colors.length];
    c.style.animationDelay = Math.random() * 0.8 + 's';
    c.style.animationDuration = 2.2 + Math.random() * 1.6 + 's';
    c.style.transform = `rotate(${Math.random() * 360}deg)`;
    box.appendChild(c);
  }
  document.body.appendChild(box);
  setTimeout(() => box.remove(), 4500);
}

// 数字を0から数え上げて見せる
function countUp(el, to, ms = 900) {
  const t0 = performance.now();
  const step = t => { const k = Math.min(1, (t - t0) / ms); el.textContent = Math.round(to * (1 - Math.pow(1 - k, 3))).toLocaleString(); if (k < 1) requestAnimationFrame(step); };
  requestAnimationFrame(step);
}

// 表彰台（上位3人。並びは 2位・1位・3位）
function podiumHtml(rank) {
  const top = [rank[1], rank[0], rank[2]];
  const cls = ['p2', 'p1', 'p3'], no = [2, 1, 3];
  return `<div class="podium">${top.map((r, i) => r ? `<div class="pod ${cls[i]}"><div class="pod-name">${esc(r.name)}</div>
    <div class="pod-score">${r.score.toLocaleString()}点</div><div class="pod-bar"><span>${no[i]}</span></div></div>` : '<div class="pod"></div>').join('')}</div>`;
}

// 発表までの残り秒（表彰・重大発表の溜め）
// 端末の時計のずれは、サーバーの時刻（live.server_now）で補正する
let clockOffset = 0;
const syncClock = serverNow => { if (serverNow) clockOffset = new Date(serverNow).getTime() - Date.now(); };
const secondsUntil = iso => Math.max(0, Math.ceil((new Date(iso).getTime() - Date.now() - clockOffset) / 1000));

// 端末の合鍵（この端末で1回だけ作る乱数。承認されると、これで中身を読めるようになる）
function deviceKey() {
  let k = null;
  try { k = localStorage.getItem('gasshuku_key'); } catch (e) {}
  if (!k || k.length < 32) {
    const b = new Uint8Array(24); crypto.getRandomValues(b);
    k = Array.from(b, x => x.toString(16).padStart(2, '0')).join('');
    try { localStorage.setItem('gasshuku_key', k); } catch (e) {}
  }
  return k;
}

// 関数を呼ぶ（失敗したら Error を投げる）
async function call(fn, args) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}

// 「変わった」という合図を受け取る（中身は届かないので、受け取ったら関数で読み直す）
// 通信が切れても追いつけるよう、15秒ごとにも読み直す
function onPulse(handler) {
  sb.channel('pulse')
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'pulse' }, ({ new: r }) => handler(r.topic, r.info || {}))
    .subscribe();
  setInterval(() => handler('poll', {}), 15000);
}

// まとめて何度も呼ばれたときに、最後の1回だけ実行する
function debounce(fn, ms = 300) {
  let t = null;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}

// ビンゴ：人ごと・回ごとに決まった並びのカードを作る（列ごとに B:1-15 … O:61-75、中央は FREE）
function bingoCard(memberId, seed) {
  let h = 2166136261;
  for (const ch of `${memberId}:${seed}`) h = Math.imul(h ^ ch.charCodeAt(0), 16777619);
  const rand = () => ((h = Math.imul(h ^ (h >>> 15), 2246822507) ^ Math.imul(h ^ (h >>> 13), 3266489909)) >>> 0) / 4294967296;
  const cols = [];
  for (let c = 0; c < 5; c++) {
    const pool = Array.from({ length: 15 }, (_, i) => c * 15 + i + 1);
    for (let i = pool.length - 1; i > 0; i--) { const j = Math.floor(rand() * (i + 1)); [pool[i], pool[j]] = [pool[j], pool[i]]; }
    cols.push(pool.slice(0, 5));
  }
  const grid = [];
  for (let r = 0; r < 5; r++) grid.push(cols.map(col => col[r]));
  grid[2][2] = 0; // FREE
  return grid;
}
function bingoLines(grid, drawn) {
  const hit = (r, c) => grid[r][c] === 0 || drawn.includes(grid[r][c]);
  let lines = 0;
  for (let i = 0; i < 5; i++) {
    if ([0, 1, 2, 3, 4].every(j => hit(i, j))) lines++;
    if ([0, 1, 2, 3, 4].every(j => hit(j, i))) lines++;
  }
  if ([0, 1, 2, 3, 4].every(i => hit(i, i))) lines++;
  if ([0, 1, 2, 3, 4].every(i => hit(i, 4 - i))) lines++;
  return lines;
}
