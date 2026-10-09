const sb = supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const TZ = 'Asia/Bangkok';
const fmtTime = iso => iso ? new Date(iso).toLocaleTimeString('en-GB', {timeZone:TZ, hour12:false, hour:'2-digit', minute:'2-digit', second:'2-digit', fractionalSecondDigits:3}) : '–';
const fmtDate = iso => iso ? new Date(iso).toLocaleDateString('en-GB', {timeZone:TZ}) : '';
const fmtDT = iso => iso ? new Date(iso).toLocaleString('en-GB', {timeZone:TZ, hour12:false, dateStyle:'short', timeStyle:'medium'}) : '';
const debounce = (f, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => f(...a), ms); }; };
const byName = (a, b) => a.name.localeCompare(b.name, 'th');
function toast(msg, bad) {
  const t = document.createElement('div');
  t.className = 'toast' + (bad ? ' bad' : '');
  t.setAttribute('role', 'status');
  t.textContent = msg;
  document.body.append(t);
  setTimeout(() => t.remove(), 4500);
}
