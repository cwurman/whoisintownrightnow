import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildQuestions, mapAnswers, placeSpans, resolveLocalTime, titleSpans, validateInput } from '../supabase/functions/draft-hang/draft.ts';
import { boundedJSON, createHandler } from '../supabase/functions/draft-hang/handler.ts';

const now = new Date('2026-09-25T19:00:00Z');
const input = validateInput({ transcript: "Let's get dinner at Lucia tonight at 8 PM for 90 minutes, four people total.",
  timeZone: 'America/Los_Angeles', recordedAt: now.toISOString(), locale: 'en_US', placeCandidates: ['Lucia'] }, now);
const questions = buildQuestions(input);
const choice = (key: string, confidence = .98, probability = .99) => ({ type: 'choice', choice: key, confidence,
  probabilities: { [key]: probability, none: 1 - probability } });
const complete = { title: choice('span_0'), place: choice('span_0'), mode: choice('scheduled'), day: choice('2026-09-25'),
  hour: choice('20'), minute: choice('0'), duration: choice('90'), group: choice('4') };

test('finite candidates preserve spoken names without enumerating arbitrary locations', () => {
  assert.deepEqual(placeSpans(input), ['Lucia']);
  assert.equal(titleSpans(input.transcript)[0], 'get dinner');
  for (const q of Object.values(questions)) { assert.ok(Object.keys(q.criteria).length <= 255); assert.ok(q.criteria.none); }
  assert.equal(questions.day.criteria['2026-09-25'], 'Friday, September 25, 2026');
});
test('a complete confident draft resolves dates in the recording timezone', () => {
  const draft = mapAnswers(input, questions, { answers: complete }, now);
  assert.equal(draft.title, 'Get dinner'); assert.equal(draft.placeName, 'Lucia');
  assert.equal(draft.startsAt, '2026-09-26T03:00:00.000Z'); assert.equal(draft.startMode, 'scheduled');
  assert.equal(draft.durationMinutes, 90); assert.equal(draft.groupLimit, 4);
});
test('low confidence or competing choices blank each field independently', () => {
  const draft = mapAnswers(input, questions, { answers: { ...complete,
    place: choice('span_0', .84), duration: choice('90', .99, .89), group: choice('none', .99, 0) } }, now);
  assert.equal(draft.placeName, null); assert.equal(draft.durationMinutes, null); assert.equal(draft.groupLimit, null);
  assert.equal(draft.title, 'Get dinner');
});
test('missing fields stay unset including exact time when only tonight was said', () => {
  const draft = mapAnswers(input, questions, { answers: { mode: choice('scheduled'), day: choice('2026-09-25') } }, now);
  for (const field of ['title', 'placeName', 'startsAt', 'durationMinutes', 'groupLimit']) assert.equal(draft[field], null);
  assert.equal(draft.startMode, 'unspecified');
});
test('unknown choices and malformed probability distributions cannot fill fields', () => {
  for (const invalid of [choice('invented'), choice('span_0', NaN), choice('span_0', Infinity),
    { ...choice('span_0'), probabilities: { span_0: 1, none: 1 } },
    { ...choice('span_0'), probabilities: { span_0: .99, invented: .01 } },
    { ...choice('span_0'), probabilities: { span_0: -.9, none: 1.9 } },
    { ...choice('span_0'), probabilities: null }]) {
    assert.equal(mapAnswers(input, questions, { answers: { title: invalid } }, now).title, null);
  }
  assert.throws(() => mapAnswers(input, questions, {}, now));
});
test('stale or ambiguous times never produce a scheduled hang', () => {
  assert.equal(mapAnswers(input, questions, { answers: complete }, new Date('2026-09-27T00:00:00Z')).startsAt, null);
  assert.equal(resolveLocalTime('2026-03-08', 2, 30, 'America/Los_Angeles'), null);
  assert.equal(resolveLocalTime('2026-11-01', 1, 30, 'America/Los_Angeles'), null);
  assert.equal(resolveLocalTime('2026-09-25', 20, 15, 'Asia/Kolkata'), '2026-09-25T14:45:00.000Z');
});
test('input rejects fabricated spans, oversized text, bad locales/zones and stale dates', () => {
  for (const overrides of [{ transcript: '' }, { transcript: 'a'.repeat(1801) }, { placeCandidates: ['Made-up venue'] },
    { placeCandidates: Array(25).fill('Lucia') }, { timeZone: 'Mars' }, { locale: '!' },
    { recordedAt: 'not-a-date' }, { recordedAt: '2026-01-01' }, { recordedAt: '2026-09-25T19:02:00Z' }]) {
    assert.throws(() => validateInput({ ...input, ...overrides }, now));
  }
  assert.equal(input.locale, 'en-US');
});
test('bounded JSON rejects streamed oversized bodies', async () => {
  await assert.rejects(boundedJSON(new Response('x'.repeat(100)), 50));
  assert.deepEqual(await boundedJSON(new Response('{"ok":true}'), 50), { ok: true });
});

const config = { supabaseURL: 'https://local.example', publishableKey: 'public-test-key', typesafeKey: 'server-test-key' };
function request(body: unknown = { ...input, recordedAt: new Date().toISOString() }, authorized = true) {
  return new Request('https://local.example/functions/v1/draft-hang', { method: 'POST',
    headers: authorized ? { Authorization: 'Bearer test-user-token' } : {}, body: JSON.stringify(body) });
}
function mockFetch(responses: (Response | Error)[]) {
  const calls: { url: string; options?: RequestInit }[] = [];
  const fetcher: typeof fetch = async (url, options) => {
    calls.push({ url: String(url), options });
    const next = responses.shift();
    if (!next) throw new Error('Unexpected network call');
    if (next instanceof Error) throw next;
    return next;
  };
  return { calls, fetcher };
}
const user = () => Response.json({ id: 'user-id', is_anonymous: false });
test('no credentials and API-key-only callers never reach Jev', async () => {
  const mock = mockFetch([]), handler = createHandler(config, mock.fetcher);
  assert.equal((await handler(request({}, false))).status, 401); assert.equal(mock.calls.length, 0);
  const denied = mockFetch([new Response('', { status: 401 })]);
  assert.equal((await createHandler(config, denied.fetcher)(request())).status, 401); assert.equal(denied.calls.length, 1);
  const anon = mockFetch([Response.json({ id: 'anon', is_anonymous: true })]);
  assert.equal((await createHandler(config, anon.fetcher)(request())).status, 403); assert.equal(anon.calls.length, 1);
});
test('malformed input, missing vendor key and exhausted budgets do not call Jev', async () => {
  const bad = mockFetch([user()]); assert.equal((await createHandler(config, bad.fetcher)(request({}))).status, 400);
  const missing = mockFetch([user()]); assert.equal((await createHandler({ ...config, typesafeKey: '' }, missing.fetcher)(request())).status, 503);
  const limited = mockFetch([user(), new Response('', { status: 429 })]);
  assert.equal((await createHandler(config, limited.fetcher)(request())).status, 429); assert.equal(limited.calls.length, 2);
});
test('signed-in requests spend a budget before sending only text/context with the server key', async () => {
  const mock = mockFetch([user(), new Response(null, { status: 204 }), Response.json({ answers: { title: choice('span_0') } })]);
  const response = await createHandler(config, mock.fetcher)(request());
  assert.equal(response.status, 200); assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(mock.calls[1].url, 'https://local.example/rest/v1/rpc/consume_hang_draft');
  assert.equal(mock.calls[2].url, 'https://api.typesafe.ai/v1/systemone');
  assert.equal(new Headers(mock.calls[2].options?.headers).get('Authorization'), 'Bearer server-test-key');
  const body = JSON.parse(mock.calls[2].options?.body as string);
  assert.equal(body.model, 'jev-1.13.0'); assert.equal(body.state.transcript, input.transcript);
  assert.ok(!JSON.stringify(body).includes('test-user-token'));
  const draft = await response.json(); assert.equal(draft.title, 'Get dinner'); assert.equal(draft.durationMinutes, null);
});
test('provider failures preserve a retryable error without disclosing its response', async () => {
  for (const failure of [new Response('private provider error', { status: 500 }), new Error('timeout with secret'), new Response('not json')]) {
    const mock = mockFetch([user(), new Response(null, { status: 204 }), failure]);
    const response = await createHandler(config, mock.fetcher)(request());
    assert.ok([502, 503].includes(response.status)); assert.deepEqual(await response.json(), { code: 'drafting_unavailable' });
  }
});
