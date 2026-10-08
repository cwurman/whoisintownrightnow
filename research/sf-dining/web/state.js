export const KINDS = ['food', 'space', 'menu', 'reviews'];
export const normalize = text => text.trim().toLowerCase().replace(/\s+/g, ' ');

export function editRatio(a, b) {
  a = normalize(a); b = normalize(b);
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const next = [i];
    for (let j = 1; j <= b.length; j++) next[j] = Math.min(next[j - 1] + 1, prev[j] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    prev = next;
  }
  return prev[b.length] / Math.max(a.length, b.length, 1);
}

export class WidgetState {
  constructor() { this.reset(); }
  reset() { this.enabled = new Set(); this.pending = {}; this.mode = 'auto'; this.forcedText = ''; this.lastText = ''; }
  choose(mode, text) { this.mode = mode; this.forcedText = normalize(text); }
  onText(text) {
    if (this.mode !== 'auto' && editRatio(this.forcedText, text) > .3) this.mode = 'auto';
    if (!normalize(text)) { this.enabled.clear(); this.pending = {}; }
  }
  apply(signals, text) {
    this.onText(text);
    if (!normalize(text)) return;
    for (const kind of KINDS) {
      const probability = signals[kind] ?? 0;
      const on = this.enabled.has(kind);
      const change = on ? probability <= .35 : probability >= .68;
      if (!change) { delete this.pending[kind]; continue; }
      const prior = this.pending[kind];
      const count = prior ? prior.count + (prior.text !== normalize(text) ? 1 : 0) : 1;
      this.pending[kind] = { count, text: normalize(text) };
      if (probability >= .85 || probability <= .15 || count >= 2) {
        on ? this.enabled.delete(kind) : this.enabled.add(kind);
        delete this.pending[kind];
      }
    }
    this.lastText = normalize(text);
  }
  visible() { return this.mode === 'auto' ? [...this.enabled] : this.mode === 'compact' ? [] : [this.mode]; }
}

export class LRU {
  constructor(limit = 80) { this.limit = limit; this.values = new Map(); }
  get(key) { const value = this.values.get(key); if (value) { this.values.delete(key); this.values.set(key, value); } return value; }
  set(key, value) { this.values.delete(key); this.values.set(key, value); while (this.values.size > this.limit) this.values.delete(this.values.keys().next().value); }
}

export function searchKey(options) {
  return JSON.stringify({ ...options, query: normalize(options.query), neighborhoods: [...options.neighborhoods].sort() });
}
