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

const WEEK = ['日', '月', '火', '水', '木', '金', '土'];
function fmtDate(d) {
  const [y, m, day] = d.split('-').map(Number);
  const w = WEEK[new Date(y, m - 1, day).getDay()];
  return `${m}/${day}（${w}）`;
}
const hhmm = t => (t || '').slice(0, 5);

// 日程を日付ごとにまとめ、いま進行中の行に印を付ける
function groupSchedule(items, now = new Date()) {
  const sorted = [...items].sort((a, b) => (a.date + a.start_time).localeCompare(b.date + b.start_time));
  const groups = [];
  for (const it of sorted) {
    const start = new Date(`${it.date}T${hhmm(it.start_time)}:00`);
    const end = it.end_time ? new Date(`${it.date}T${hhmm(it.end_time)}:00`) : new Date(start.getTime() + 30 * 60000);
    const row = { ...it, isNow: now >= start && now < end };
    let g = groups.find(x => x.date === it.date);
    if (!g) groups.push(g = { date: it.date, items: [] });
    g.items.push(row);
  }
  return groups;
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
