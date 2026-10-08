import { WidgetState, LRU, searchKey } from './state.js';

const $ = selector => document.querySelector(selector);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const safeURL = value => { try { const url = new URL(value); return ['https:', 'http:'].includes(url.protocol) ? esc(url.href) : '#'; } catch { return '#'; } };
const icons = {
  heart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><path d="M20.5 5.7a5.3 5.3 0 0 0-7.5 0L12 6.8l-1.1-1.1a5.3 5.3 0 0 0-7.5 7.5L12 22l8.5-8.8a5.3 5.3 0 0 0 0-7.5Z" transform="translate(0 -1.5) scale(1 .94)"/></svg>',
  food: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><path d="M3 3v6c0 4 6 4 6 0V3M6 3v18M17 3v18M17 3c-6 4-5 10 0 10"/></svg>',
  space: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><path d="M3 21V9l9-7 9 7v12H3ZM9 21v-8h6v8"/></svg>',
  menu: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><rect x="5" y="2" width="14" height="20" rx="2"/><path d="M9 7h6M9 12h6M9 17h4"/></svg>',
  reviews: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><path d="M21 3H3v14h4v5l6-5h8V3ZM7 8h10M7 12h6"/></svg>',
};
const labels = {food: 'On the table', space: 'The space', menu: 'From the menu', reviews: 'What people say'};
const widget = new WidgetState();
const cache = new LRU(24);
const records = new Map();
const photos = new Map();
const cards = new Map();
let payload = null, sequence = 0, timer, controller, visibleCount = 12, savedOnly = false, toastTimer;
let saved = new Set();
try { saved = new Set(JSON.parse(localStorage.getItem('supper-saved-v1') || '[]').filter(id => typeof id === 'string')); } catch { /* Storage is optional. */ }

function options() { return {query: $('#query').value.trim(), scope: $('#scope').value, neighborhoods: [...document.querySelectorAll('[name=neighborhood]:checked')].map(el => el.value), sort: $('#sort').value}; }
function remember(results) { for (const r of results) { records.set(r.restaurant_id, r); for (const p of r.photos) photos.set(p.id, {...p, restaurant_name: r.name}); } }
function status(text, busy = false) { $('#status').textContent = text; $('#status').classList.toggle('busy', busy); }
function toast(text) { clearTimeout(toastTimer); $('#toast').textContent = text; $('#toast').hidden = false; toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 2600); }
function highlight(text) {
  const terms = (options().query.toLowerCase().match(/[\p{L}\p{N}]+/gu) || []).filter(t => t.length > 2 && !['with','and','the','for','food','some','that','menu','near','show'].includes(t));
  if (!terms.length) return esc(text);
  const pattern = new RegExp(`(${terms.map(t => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`, 'gi');
  return String(text).split(pattern).map((part, i) => i % 2 ? `<mark>${esc(part)}</mark>` : esc(part)).join('');
}
function photoCard(p, context = '') {
  return `<figure class="photo-card"><button class="photo-button" data-photo="${esc(p.id)}" aria-label="View photo: ${esc(p.caption.slice(0, 100))}"><img src="${safeURL(p.url)}" alt="${esc(p.caption)}" loading="lazy" referrerpolicy="no-referrer"><span class="photo-zoom" aria-hidden="true">↗</span></button><figcaption>${highlight(p.caption)}</figcaption>${context === 'detail' ? `<span class="photo-origin">${esc(p.author || 'Contributor')} · Google Maps</span>` : ''}</figure>`;
}
function reviewCard(review) {
  return `<blockquote class="review-widget"><p>“${highlight(review.text)}”</p><cite>${esc(review.author || 'Google reviewer')} <span>·</span> <a href="${safeURL(review.source_url)}" target="_blank" rel="noopener noreferrer">Google Maps ↗</a></cite></blockquote>`;
}

// Each registered widget consumes actual source records. Jev only chooses relevance and presentation.
const registry = {
  food: (r, manual) => gallery(r, 'food', manual),
  space: (r, manual) => gallery(r, 'space', manual),
  menu(r, manual) {
    const list = manual ? r.photos.filter(p => p.kind === 'menu') : r.modules.menu;
    if (!list.length) return '';
    const p = list.find(p => p.ocr) || list[0];
    return `<div class="menu-layout"><div>${photoCard(p)}</div><div class="menu-copy"><h4>A closer look at the menu</h4><pre>${highlight(p.ocr || p.caption)}</pre><p>${p.ocr ? 'Text read from a menu photo. Check the original for current items and prices.' : 'Open the photo to read the original menu.'}</p></div></div>`;
  },
  reviews(r, manual) { const list = manual ? r.reviews : r.modules.reviews; return list.length ? reviewCard(list[0]) : ''; },
};
function gallery(r, kind, manual) {
  const list = manual ? r.photos.filter(p => p.kind === kind) : r.modules[kind];
  return list.length ? `<div class="photo-grid">${list.slice(0, 3).map(p => photoCard(p)).join('')}</div>` : '';
}
function restaurantHTML(r) {
  const id = esc(r.restaurant_id);
  const cover = r.photos.find(p => p.kind === 'food') || r.photos[0];
  const enabled = widget.visible();
  const manual = widget.mode !== 'auto';
  const modules = enabled.map(kind => { const content = registry[kind](r, manual); return content ? `<section class="evidence-row" data-widget="${kind}" aria-label="${labels[kind]}"><div class="evidence-label">${icons[kind]}${labels[kind]}</div><div>${content}</div></section>` : ''; }).join('');
  const count = r.google_review_count?.toLocaleString() || '0';
  const subtitle = [r.category?.replace(/ restaurant$/i, ''), r.neighborhood?.replace('Mission District','Mission').replace('The Castro','Castro'), r.price_display].filter(Boolean).map(esc).join('<span class="meta-dot">·</span>');
  return `<div class="restaurant-top"><button class="cover${cover ? '' : ' no-photo'}" data-detail="${id}" aria-label="Explore ${esc(r.name)}">${cover ? `<img src="${safeURL(cover.url)}" alt="${esc(cover.caption)}" loading="lazy" referrerpolicy="no-referrer">` : '<span aria-hidden="true">✳</span>'}</button><div><h3><button class="restaurant-title" data-detail="${id}">${esc(r.name)}</button></h3><div class="restaurant-meta">${subtitle}</div><div class="restaurant-subline"><span class="rating"><span class="rating-star" aria-hidden="true">★</span>${esc(r.rating)}<span class="rating-count">(${count})</span></span>${r.matched_sources ? `<span class="match-note">${r.matched_sources} matching source${r.matched_sources === 1 ? '' : 's'}</span>` : ''}</div></div><div class="restaurant-actions"><button class="save-place" data-save="${id}" aria-label="${saved.has(r.restaurant_id) ? 'Unsave' : 'Save'} ${esc(r.name)}" aria-pressed="${saved.has(r.restaurant_id)}">${icons.heart}</button><button class="place-open" data-detail="${id}" aria-label="Details for ${esc(r.name)}">↗</button></div></div>${modules}<div class="evidence-footnote"><span>${r.photos.length} photo${r.photos.length === 1 ? '' : 's'} · ${r.reviews.length} review excerpts${r.match_type === 'partial' ? ' · Some search terms matched' : ''}</span><button data-detail="${id}">Explore this place ↗</button></div>`;
}
function render() {
  if (!payload) return;
  const rows = savedOnly ? payload.results.filter(r => saved.has(r.restaurant_id)) : payload.results;
  const displayed = rows.slice(0, visibleCount);
  const keep = new Set(displayed.map(r => r.restaurant_id));
  const active = document.activeElement;
  const focusSave = active?.dataset?.save;
  $('#results').querySelectorAll('.skeleton').forEach(el => el.remove());
  for (const [id, node] of cards) if (!keep.has(id)) { node.remove(); cards.delete(id); }
  for (const r of displayed) {
    let node = cards.get(r.restaurant_id);
    if (!node) { node = document.createElement('article'); node.className = 'restaurant'; node.dataset.id = r.restaurant_id; cards.set(r.restaurant_id, node); }
    const html = restaurantHTML(r);
    if (node._html !== html) { node.innerHTML = html; node._html = html; }
    $('#results').append(node);
  }
  if (focusSave) [...document.querySelectorAll('[data-save]')].find(el => el.dataset.save === focusSave)?.focus({preventScroll: true});
  $('#results').setAttribute('aria-busy', 'false');
  $('#empty-state').hidden = rows.length > 0;
  $('#empty-title').textContent = savedOnly ? 'A place for your next plans.' : 'No matches around here. Yet.';
  $('#empty-copy').textContent = savedOnly ? 'Tap the heart on a restaurant to keep it here. Your current search and filters still apply.' : 'Try a simpler craving, remove a neighborhood filter, or explore all of San Francisco.';
  $('#load-more').hidden = displayed.length >= rows.length;
  $('#result-count').textContent = `${rows.length} place${rows.length === 1 ? '' : 's'}`;
  $('#result-eyebrow').textContent = savedOnly ? 'KEEP A FEW GOOD PLACES' : options().query ? 'FOLLOW YOUR CRAVING' : 'AROUND YOUR CORNER';
  $('#result-title').textContent = savedOnly ? 'Your saved places.' : options().query ? 'A few places that fit.' : 'Good places, close by.';
  const visibleModules = new Set();
  for (const r of displayed) for (const kind of widget.visible()) if (registry[kind](r, widget.mode !== 'auto')) visibleModules.add(kind);
  $('#active-modules').innerHTML = [...visibleModules].map(kind => `<span>${{food:'Dish photos',space:'Space photos',menu:'Menu details',reviews:'Review excerpts'}[kind]}</span>`).join('');
  document.querySelectorAll('[data-view]').forEach(btn => btn.setAttribute('aria-pressed', String(btn.dataset.view === widget.mode)));
  $('#return-auto').hidden = widget.mode === 'auto';
  $('#saved-count').textContent = saved.size;
  $('#saved-button').setAttribute('aria-pressed', String(savedOnly));
}

function feedback(data) {
  if (!data.query) return status(savedOnly ? 'Saved on this browser. Ready when you are.' : 'A few neighborhood favorites to get you started.');
  if (data.status === 'jev') status('Ordered by the photos and reviews that fit your search.');
  else if (data.status === 'fallback') status('Showing local matches. Smart sorting is taking a break.');
  else status('Matches from restaurant details, photos, and reviews.');
}
function apply(data, id) {
  if (id !== sequence) return;
  payload = data;
  remember(data.results);
  widget.apply(data.signals, options().query);
  render();
  feedback(data);
}
function schedule(delay = 140) {
  const id = ++sequence;
  clearTimeout(timer);
  controller?.abort();
  widget.onText($('#query').value);
  visibleCount = 12;
  $('#clear-query').hidden = !$('#query').value;
  $('#search-shortcut').hidden = !!$('#query').value;
  $('#reset-filters').hidden = !options().neighborhoods.length && options().scope === 'nearby';
  status('Finding places for your craving…', true);
  $('#results').setAttribute('aria-busy', 'true');
  timer = setTimeout(() => runSearch(id), delay);
}
async function runSearch(id) {
  const current = options();
  const key = searchKey(current);
  const cached = cache.get(key);
  updateURL(current);
  if (cached) { apply(cached, id); return; }
  const ctrl = new AbortController();
  controller = ctrl;
  const qs = new URLSearchParams({q: current.query, scope: current.scope, sort: current.sort});
  current.neighborhoods.forEach(n => qs.append('neighborhood', n));
  try {
    const response = await fetch(`/api/search?${qs}`, {signal: ctrl.signal});
    if (!response.ok) throw new Error('search');
    const local = await response.json();
    if (id !== sequence) return;
    apply(local, id);
    if (!current.query || !local.results.length) { cache.set(key, local); return; }
    status('Found the places. Looking a little closer…', true);
    // A separate, longer pause avoids paying for each incomplete word while local matches appear quickly.
    await new Promise(resolve => setTimeout(resolve, 260));
    if (id !== sequence || ctrl.signal.aborted) return;
    const refined = await fetch('/api/rerank', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(current), signal: ctrl.signal});
    if (!refined.ok) throw new Error('rerank');
    const data = await refined.json();
    if (id !== sequence) return;
    if (data.status === 'jev') cache.set(key, data);
    apply(data, id);
  } catch (error) {
    if (id !== sequence || ctrl.signal.aborted) return;
    $('#results').setAttribute('aria-busy', 'false');
    if (payload && payload.query === current.query) { status('Showing local matches. Smart sorting is taking a break.'); }
    else { status('Couldn’t reach the local server. Press Enter to try again.'); $('#results').querySelectorAll('.skeleton').forEach(el => el.remove()); }
  }
}
function updateURL(current) {
  const p = new URLSearchParams();
  if (current.query) p.set('q', current.query);
  if (current.scope !== 'nearby') p.set('scope', current.scope);
  current.neighborhoods.forEach(n => p.append('neighborhood', n));
  if (current.sort !== 'relevance') p.set('sort', current.sort);
  history.replaceState(null, '', `${location.pathname}${p.size ? '?' + p : ''}`);
}
function query(text) { $('#query').value = text; savedOnly = false; schedule(0); $('#query').focus(); }
function reset() { document.querySelectorAll('[name=neighborhood]').forEach(el => { el.checked = false; }); $('#scope').value = 'nearby'; $('#query').value = ''; savedOnly = false; widget.reset(); schedule(0); }

function save(id) {
  saved.has(id) ? saved.delete(id) : saved.add(id);
  try { localStorage.setItem('supper-saved-v1', JSON.stringify([...saved])); } catch { toast('Saved for this visit. Browser storage is unavailable.'); }
  render();
}
async function showDetails(id) {
  let r = records.get(id);
  if (!r) {
    try { const response = await fetch(`/api/restaurant?id=${encodeURIComponent(id)}`); if (!response.ok) throw new Error(); r = await response.json(); remember([r]); }
    catch { toast('Couldn’t load this place. Please try again.'); return; }
  }
  $('#detail-content').innerHTML = `<div class="dialog-header"><div><h2 id="detail-title">${esc(r.name)}</h2><div class="detail-meta">${esc(r.category)} · ${esc(r.neighborhood)}<br><span class="rating-star" aria-hidden="true">★</span> ${esc(r.rating)} · ${r.google_review_count.toLocaleString()} Google ratings${r.price_display ? ' · ' + esc(r.price_display) : ''}<br>${esc(r.address)}</div></div><button class="dialog-close" data-close="details" aria-label="Close restaurant details">×</button></div><div class="detail-links"><a href="${safeURL(r.source_url)}" target="_blank" rel="noopener noreferrer">Open in Google Maps ↗</a>${r.website ? `<a href="${safeURL(r.website)}" target="_blank" rel="noopener noreferrer">Website ↗</a>` : ''}${r.phone ? `<a href="tel:${esc(r.phone.replace(/[^+0-9]/g, ''))}">Call ${esc(r.phone)}</a>` : ''}</div>${r.matched_evidence.length ? `<section class="detail-section"><h3>Why it came up</h3>${r.matched_evidence.slice(0, 3).map(e => `<div class="detail-evidence"><small>${esc({customer_review_excerpt:'Customer review',photo_vision_caption:'AI photo description',photo_source_caption:'Source photo description',photo_ocr:'Text read from a menu',restaurant_metadata:'Restaurant details'}[e.kind] || 'Source evidence')}</small>${highlight(e.text)}</div>`).join('')}</section>` : ''}${['food','space','menu','other'].map(kind => { const ps = r.photos.filter(p => p.kind === kind); return ps.length ? `<section class="detail-section"><h3>${{food:'Food & drink',space:'A feel for the place',menu:'Menus',other:'More photos'}[kind]}</h3><div class="photo-grid">${ps.map(p => photoCard(p, 'detail')).join('')}</div></section>` : ''; }).join('')}<section class="detail-section"><h3>From people who’ve been</h3>${r.reviews.map(reviewCard).join('')}</section><p class="detail-note">Photos and review excerpts collected from Google Maps in September 2026. Photo descriptions may be AI-generated and can contain errors. Menu items, prices, and other details may have changed.</p>`;
  if (!$('#details').open) $('#details').showModal();
  $('#details').scrollTop = 0;
}
function showPhoto(id) {
  const p = photos.get(id);
  if (!p) return;
  $('#lightbox-content').innerHTML = `<div class="lightbox-bar"><span>${esc(p.restaurant_name)}</span><button class="dialog-close" data-close="lightbox" aria-label="Close photo">×</button></div><div class="lightbox-frame"><img class="lightbox-image" src="${safeURL(p.url)}" alt="${esc(p.caption)}" referrerpolicy="no-referrer"></div><div class="lightbox-caption"><p>${highlight(p.caption)}</p><small>${esc(p.origin)} · Photo by ${esc(p.author || 'a Google Maps contributor')} · <a href="${safeURL(p.source_url)}" target="_blank" rel="noopener noreferrer">View source ↗</a></small>${p.uncertainties.length ? `<p><small>${esc(p.uncertainties.join(' '))}</small></p>` : ''}${p.ocr ? `<details><summary>Text read from this image</summary><div class="detail-evidence">${esc(p.ocr)}</div></details>` : ''}</div>`;
  if (!$('#lightbox').open) $('#lightbox').showModal();
}

$('#query').addEventListener('input', () => schedule());
$('#search-form').addEventListener('submit', event => { event.preventDefault(); schedule(0); });
$('#clear-query').addEventListener('click', () => query(''));
$('#scope').addEventListener('change', () => schedule(0));
$('#sort').addEventListener('change', () => schedule(0));
document.querySelectorAll('[name=neighborhood]').forEach(el => el.addEventListener('change', () => schedule(0)));
$('#reset-filters').addEventListener('click', () => { document.querySelectorAll('[name=neighborhood]').forEach(el => { el.checked = false; }); $('#scope').value = 'nearby'; schedule(0); });
$('#empty-reset').addEventListener('click', reset);
$('#load-more').addEventListener('click', () => { visibleCount += 12; render(); });
$('#return-auto').addEventListener('click', () => { widget.choose('auto', options().query); render(); });
$('#saved-button').addEventListener('click', () => { savedOnly = !savedOnly; visibleCount = 12; render(); feedback(payload || {query: ''}); });
document.addEventListener('click', event => {
  const button = event.target.closest('button');
  if (!button) return;
  if (button.dataset.query !== undefined) query(button.dataset.query);
  if (button.dataset.save) save(button.dataset.save);
  if (button.dataset.detail) showDetails(button.dataset.detail);
  if (button.dataset.photo) showPhoto(button.dataset.photo);
  if (button.dataset.close) document.getElementById(button.dataset.close).close();
  if (button.dataset.view) { widget.choose(button.dataset.view, options().query); render(); }
});
document.addEventListener('keydown', event => {
  if (event.key === '/' && !['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement.tagName) && !document.querySelector('dialog[open]')) { event.preventDefault(); $('#query').focus(); }
  if (event.key === 'Escape' && document.activeElement === $('#query') && !document.querySelector('dialog[open]')) query('');
});
document.addEventListener('error', event => { if (event.target.tagName === 'IMG') { event.target.parentElement.classList.add('image-error'); event.target.alt = 'This source photo is unavailable'; } }, true);
for (const dialog of document.querySelectorAll('dialog')) dialog.addEventListener('click', event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close(); } });
window.addEventListener('storage', event => { if (event.key === 'supper-saved-v1') { try { saved = new Set(JSON.parse(event.newValue || '[]')); render(); } catch {} } });

async function init() {
  const initial = new URLSearchParams(location.search);
  $('#query').value = (initial.get('q') || '').slice(0, 300);
  if (['nearby', 'focus', 'all'].includes(initial.get('scope'))) $('#scope').value = initial.get('scope');
  if (initial.get('sort') === 'rating') $('#sort').value = 'rating';
  document.querySelectorAll('[name=neighborhood]').forEach(el => { el.checked = initial.getAll('neighborhood').includes(el.value); });
  $('#saved-count').textContent = saved.size;
  try {
    const response = await fetch('/api/catalog');
    const data = await response.json();
    $('#catalog-count').textContent = data.restaurants;
    for (const [key, count] of Object.entries(data.neighborhoods)) $(`#count-${key}`).textContent = count;
  } catch { /* Search has its own recovery state. */ }
  schedule(0);
}
init();
