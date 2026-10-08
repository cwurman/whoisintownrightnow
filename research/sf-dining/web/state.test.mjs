import test from 'node:test';
import assert from 'node:assert/strict';
import { WidgetState, LRU, searchKey } from './state.js';

test('compound queries may enable several independent widgets', () => {
  const state = new WidgetState();
  state.apply({food: .95, space: .93, reviews: .96, menu: .02}, 'kebab with outdoor seating');
  assert.deepEqual(state.visible(), ['food', 'space', 'reviews']);
});
test('dead band keeps the current widget stable; distinct consecutive decisions can promote it', () => {
  const state = new WidgetState();
  state.apply({food: .72}, 'dum');
  assert.deepEqual(state.visible(), []);
  state.apply({food: .72}, 'dum');
  assert.deepEqual(state.visible(), []);
  state.apply({food: .74}, 'dumpl');
  assert.deepEqual(state.visible(), ['food']);
  state.apply({food: .5}, 'dumpling');
  assert.deepEqual(state.visible(), ['food']);
  state.apply({food: .1}, 'mediterranean');
  assert.deepEqual(state.visible(), []);
});
test('manual view survives small edits and releases on a substantial change', () => {
  const state = new WidgetState();
  state.choose('space', 'kebab with outdoor seating');
  state.onText('kebab with outdoor seatings');
  assert.equal(state.mode, 'space');
  state.onText('mediterranean food');
  assert.equal(state.mode, 'auto');
});
test('empty search resets automatic widgets', () => {
  const state = new WidgetState();
  state.apply({food: .99}, 'kebab');
  state.apply({food: .99}, '');
  assert.deepEqual(state.visible(), []);
});
test('search cache distinguishes all filters and normalizes case, whitespace and neighborhood order', () => {
  const key = searchKey({query:' KEBAB  food ', neighborhoods:['mission','castro'], scope:'nearby',sort:'relevance'});
  assert.equal(key, searchKey({query:'kebab food', neighborhoods:['castro','mission'], scope:'nearby',sort:'relevance'}));
  assert.notEqual(key, searchKey({query:'kebab food', neighborhoods:['castro','mission'], scope:'all',sort:'relevance'}));
  const cache = new LRU(2);
  cache.set('a', 1); cache.set('b', 2); cache.get('a'); cache.set('c', 3);
  assert.equal(cache.get('b'), undefined);
  assert.equal(cache.get('a'), 1);
});
