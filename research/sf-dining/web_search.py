"""The restaurant demo's read-only search API and evidence-backed widget contract."""
from collections import Counter, OrderedDict
from copy import deepcopy
import json
import math
import re
from threading import BoundedSemaphore, Lock

from photo_search import DATA, STOP, search
from jev_search import MODEL, RULES, LEVELS, evaluate

RESTAURANTS = {r['restaurant_id']: r for r in json.loads((DATA / 'maps-demo.json').read_text())['restaurants']}
EVIDENCE = {}
DESCRIPTIONS = {}
for line in (DATA / 'photo-vision.jsonl').read_text().splitlines():
    annotation = json.loads(line)
    if annotation.get('status') == 'completed':
        DESCRIPTIONS[annotation['photo_id']] = annotation['extraction']['caption']
for line in (DATA / 'search-evidence.jsonl').read_text().splitlines():
    row = json.loads(line)
    if row.get('photo_id'):
        EVIDENCE.setdefault(row['photo_id'], []).append(row)

GROUPS = {'castro': ['The Castro'], 'mission': ['Mission District', 'Mission Dolores'],
          'noe': ['Noe Valley']}
MODULES = {
    'food': 'Show dish or drink photos when a specific dish, ingredient, or drink is requested. A broad cuisine alone is not sufficient.',
    'space': 'Show interior, exterior, or seating photos when appearance, decor, patio, outdoor seating, or atmosphere matters.',
    'menu': 'Show menu photos and extracted menu text when the user asks to see a menu or prices on a menu.',
    'reviews': 'Show customer review excerpts when opinions, taste, quality, service, noise, dietary needs, or a compound request need review evidence.',
}
MODULE_CRITERIA = {
    'food': {
        'show': 'The query names a specific dish, ingredient, or drink, such as kebab, dumplings, pasta, or a cocktail. Seeing that food is directly useful.',
        'hide': 'The query only names a broad cuisine/category, location, decor, ambiance, service, or asks for menus. No particular food or drink is requested.'},
    'space': {
        'show': 'The query explicitly describes the physical space or vibe: outdoor seating, patio, decor, colors, cozy, romantic, or a date-night atmosphere.',
        'hide': 'The query only asks for food, cuisine, menus, or service. The restaurant setting or its appearance is not requested.'},
    'menu': {
        'show': 'The query explicitly asks to see or read a menu, a menu photo, a price list, or menu prices.',
        'hide': 'The query does not ask to see a menu or menu prices. Naming a dish, cuisine, decor, or seating alone does not ask for a menu.'},
    'reviews': {
        'show': 'The query asks for opinions, food quality, taste, reviews, quietness, service, dietary needs, or a combination of food and atmosphere/seating constraints.',
        'hide': 'The query is a simple dish name, broad cuisine/category, visual color/decoration search, or menu request. It does not ask for opinions or multiple constraints.'},
}
FOOD_WORDS = r'\b(kebab|kabob|kabab|pizza|taco|tacos|burrito|burritos|ramen|sushi|dumpling|dumplings|pasta|burger|burgers|steak|chicken|falafel|shawarma|hummus|pho|curry|biryani|dosa|noodles|sandwich|sandwiches|croissant|coffee|cocktail|cocktails|wine|beer|matcha|dessert|ice cream|pancake|pancakes|salad|salads|chocolate|pastry|pastries|oyster|oysters|seafood|salmon|tuna|margarita)\b'
SPACE_WORDS = r'\b(patio|outdoor|outside|interior|decor|space|seating|cozy|cosy|vibe|romantic|date|green|bright|sunny|garden|colorful|colourful|plants|wood|terrace|rooftop)\b'
REVIEW_WORDS = r'\b(quiet|loud|service|review|reviews|best|delicious|taste|crispy|spicy|vegan|vegetarian|gluten|allerg|friendly|date|cozy|cosy)'
MENU_WORDS = r'\b(menu|menus|prices)\b'
ALIASES = {'outdoor': ['patio', 'outside'], 'cozy': ['cosy', 'warm'], 'quiet': ['noise'],
           'kebab': ['kabob', 'kabab'], 'dumplings': ['dumpling'], 'tacos': ['taco']}
EXTRA_STOP = {'some', 'something', 'good', 'great', 'nice', 'looking', 'get', 'see', 'has', 'that', 'is', 'it', 'at', 'on', 'my', 'dinner', 'lunch', 'breakfast', 'menu', 'menus', 'price', 'prices'}
PHOTO_CACHE = {}
CACHE = OrderedDict()
CACHE_LOCK = Lock()
JEV_SLOTS = BoundedSemaphore(2)


def terms(query):
    return list(dict.fromkeys(t for t in re.findall(r'\w+', query.lower()) if t not in STOP | EXTRA_STOP))[:16]


def photo_kind(rows, caption):
    kind = next((e.get('photo_type') for e in rows if e.get('photo_type')), None)
    if kind:
        return {'food': 'food', 'drink': 'food', 'interior': 'space', 'exterior': 'space', 'menu': 'menu'}.get(kind, 'other')
    if re.search(r'\b(menu|price list|drink list)\b', caption, re.I):
        return 'menu'
    if re.search(r'\b(interior|exterior|seating|patio|dining area|dining room|storefront|entrance|facade|tables|decor|counter|bar area|kitchen|restaurant space)\b', caption, re.I):
        return 'space'
    if re.search(r'\b(stickers?|logo|receipt|signage|business card)\b', caption, re.I):
        return 'other'
    return 'food' if caption else 'other'


def photos_for(rid):
    if rid not in PHOTO_CACHE:
        output = []
        for p in RESTAURANTS[rid]['photos']:
            rows = EVIDENCE.get(p['photo_id'], [])
            captions = [e for e in rows if e['kind'] != 'photo_ocr']
            if not captions:
                continue
            search_text = captions[-1]['text']
            caption = DESCRIPTIONS.get(p['photo_id'], search_text)
            output.append({'id': p['photo_id'], 'url': p['url'], 'caption': caption,
                           'search_text': search_text,
                           'kind': photo_kind(rows, caption), 'author': p.get('author'),
                           'origin': 'AI photo description' if captions[-1]['kind'] == 'photo_vision_caption' else 'Source photo description',
                           'source_url': p['source_url'], 'ocr': '\n'.join(e['text'] for e in rows if e['kind'] == 'photo_ocr'),
                           'uncertainties': captions[-1].get('uncertainties', [])})
        PHOTO_CACHE[rid] = output
    return PHOTO_CACHE[rid]


# Populate once before the threaded HTTP server starts.
for restaurant_id in RESTAURANTS:
    photos_for(restaurant_id)


def accepts(r, scope, neighborhoods):
    allowed = {'focus': {'focus'}, 'nearby': {'focus', 'nearby'}, 'all': {'focus', 'nearby', 'other_sf'}}[scope]
    return r['area_priority'] in allowed and (not neighborhoods or any(r['neighborhood'] in GROUPS[n] for n in neighborhoods))


def normalize_options(body):
    query = body.get('query', '')
    scope = body.get('scope', 'nearby')
    neighborhoods = body.get('neighborhoods', [])
    sort = body.get('sort', 'relevance')
    if not isinstance(query, str) or len(query) > 300:
        raise ValueError('Search must be 300 characters or fewer.')
    if scope not in {'focus', 'nearby', 'all'} or sort not in {'relevance', 'rating'}:
        raise ValueError('Unknown search option.')
    if not isinstance(neighborhoods, list) or any(n not in GROUPS for n in neighborhoods):
        raise ValueError('Unknown neighborhood.')
    return {'query': ' '.join(query.split()), 'scope': scope, 'neighborhoods': sorted(set(neighborhoods)), 'sort': sort}


def fallback_signals(query):
    signals = {kind: .92 if re.search(pattern, query.lower()) else .08 for kind, pattern in
               [('food', FOOD_WORDS), ('space', SPACE_WORDS), ('menu', MENU_WORDS), ('reviews', REVIEW_WORDS)]}
    if signals['food'] > .8 and signals['space'] > .8:
        signals['reviews'] = .92
    return signals


def text_score(text, query_terms):
    words = set(re.findall(r'\w+', text.lower()))
    return sum(any(t in words for t in [term, *ALIASES.get(term, [])]) for term in query_terms)


def serialize(rid, query='', hit=None):
    r = RESTAURANTS[rid]
    qterms = terms(query)
    photos = sorted(photos_for(rid), key=lambda p: -text_score(p['search_text'] + ' ' + p['ocr'], qterms))
    evidence = hit.get('matched_evidence', []) if hit else []
    reviews = sorted(r['reviews'], key=lambda e: -text_score(e['text'], qterms))
    matching_reviews = [e for e in reviews if text_score(e['text'], qterms)]
    modules = {}
    for kind in ['food', 'space', 'menu']:
        all_of_kind = [p for p in photos if p['kind'] == kind]
        matched = [p for p in all_of_kind if text_score(p['search_text'] + ' ' + p['ocr'], qterms)]
        # Each module must have supporting records. Manual views can still browse all photos.
        modules[kind] = (all_of_kind if not qterms or kind == 'menu' and re.search(MENU_WORDS, query, re.I) else matched)[:4]
    modules['reviews'] = matching_reviews[:2] if qterms else reviews[:2]
    out = {key: r.get(key) for key in ['restaurant_id', 'name', 'address', 'neighborhood', 'category', 'rating',
                                      'google_review_count', 'price_display', 'source_url', 'website', 'phone', 'retrieved_at']}
    out.update(photos=photos, reviews=reviews, modules=modules,
               matched_evidence=evidence, matched_sources=hit.get('matched_sources', 0) if hit else 0,
               match_type=hit.get('match_type', 'browse') if hit else 'browse',
               matched_query_terms=hit.get('matched_query_terms', []) if hit else [],
               relevance=None, selected_photos={})
    return out


def local_search(options):
    query, scope = options['query'], options['scope']
    neighborhoods = options['neighborhoods']
    retrieval_terms = terms(query)
    retrieval = ' '.join(retrieval_terms)
    if retrieval:
        hits = search(retrieval, scope=scope, limit=500, prefix_last=True)
        # Synonyms are a second, bounded recall pass; original matches retain priority.
        expanded = list(dict.fromkeys([*retrieval_terms, *(a for t in retrieval_terms for a in ALIASES.get(t, []))]))
        if expanded != retrieval_terms:
            ids = {h['restaurant_id'] for h in hits}
            hits += [h for h in search(' '.join(expanded), scope=scope, limit=500) if h['restaurant_id'] not in ids]
        hits = [h for h in hits if accepts(RESTAURANTS[h['restaurant_id']], scope, neighborhoods)]
        results = [serialize(h['restaurant_id'], query, h) for h in hits]
    else:
        pool = [r for r in RESTAURANTS.values() if accepts(r, scope, neighborhoods)]
        # Browsing order balances star rating and review volume, with no invented recommendation score.
        pool.sort(key=lambda r: (-(r['rating'] * min(r['google_review_count'], 1000) + 4.2 * 100) /
                                 (min(r['google_review_count'], 1000) + 100), r['name']))
        results = [serialize(r['restaurant_id'], query) for r in pool]
        if re.search(MENU_WORDS, query, re.I):
            results = [r for r in results if r['modules']['menu']]
    if options['sort'] == 'rating':
        results.sort(key=lambda r: (-(r['rating'] or 0), -(r['google_review_count'] or 0)))
    return {**options, 'status': 'local', 'signals': fallback_signals(query), 'total': len(results),
            'results': results, 'reranked_count': 0, 'fallback_reason': None}


def make_widget_request(query, results):
    state = {'query': query, 'candidates': {}}
    questions = {f'show_{kind}': {'type': 'choice', 'instructions': RULES +
                                 'Judge ONLY the intent of state.query, not the kinds of evidence available in candidates. ' + instructions,
                                 'criteria': MODULE_CRITERIA[kind]}
                 for kind, instructions in MODULES.items()}
    for i, r in enumerate(results):
        cid = f'c{i}'
        state['candidates'][cid] = {'name': r['name'], 'category': r['category'], 'neighborhood': r['neighborhood'],
                                  'evidence': [{'kind': e['kind'], 'text': e['text'][:650]} for e in r['matched_evidence'][:5]],
                                  'photos': {}}
        questions[f'{cid}_match'] = {'type': 'score', 'instructions': RULES +
                                     f'How well does state.candidates.{cid} support state.query? Evaluate only this candidate.', 'criteria': LEVELS}
        for kind in ['food', 'space', 'menu']:
            photos = r['modules'][kind][:3]
            if not photos:
                continue
            aspect = {'food': 'specific dish, ingredient, or drink', 'space': 'physical space, decor, or seating',
                      'menu': 'menu contents or prices'}[kind]
            choices = {'none': f'None of these photos supports the {aspect} aspect of the query.'}
            for j, p in enumerate(photos):
                pid = f'{kind}{j}'
                state['candidates'][cid]['photos'][pid] = {'kind': kind, 'caption': p['search_text'][:500],
                                                          'menu_text': p['ocr'][:500], 'uncertainties': p['uncertainties']}
                choices[pid] = f'The photo described in state.candidates.{cid}.photos.{pid}.'
            questions[f'{cid}_{kind}'] = {'type': 'choice', 'instructions': RULES +
                                         f'Select the {kind} photo in state.candidates.{cid}.photos most relevant to state.query. '
                                         f'Evaluate ONLY the {aspect} aspect of the query. A food photo need not show seating; a seating photo need not show the food. '
                                         'Other modules address the other requirements. You see descriptions, not pixels. Choose none if no photo supports this aspect.',
                                         'criteria': choices}
    return {'model': MODEL, 'state': state, 'questions': questions}


def rerank(options, evaluator=None):
    key = json.dumps(options, sort_keys=True)
    with CACHE_LOCK:
        if key in CACHE:
            CACHE.move_to_end(key)
            return deepcopy(CACHE[key]) | {'cached': True}
    payload = local_search(options)
    if not options['query'] or not payload['results']:
        return payload
    if not JEV_SLOTS.acquire(blocking=False):
        return payload | {'status': 'fallback', 'fallback_reason': 'busy'}
    try:
        candidates = payload['results'][:10]
        request = make_widget_request(options['query'], candidates)
        response, meta = (evaluator or evaluate)(request, timeout=3)
        # Injected evaluators in tests pass through the same strict API validator.
        from jev_search import validate_response
        validate_response(response, request)
        answers = response['answers']
        for kind in MODULES:
            answer = answers[f'show_{kind}']
            probability = answer.get('probabilities', {}).get('show')
            if probability is None:
                probability = (1 + answer['confidence']) / 2 if answer['choice'] == 'show' else (1 - answer['confidence']) / 2
            if type(probability) not in (int, float) or not math.isfinite(probability) or not 0 <= probability <= 1:
                raise ValueError('Invalid module probability')
            payload['signals'][kind] = probability
        for i, r in enumerate(candidates):
            r['relevance'] = answers[f'c{i}_match']['score']
            for kind in ['food', 'space', 'menu']:
                answer = answers.get(f'c{i}_{kind}')
                if not answer:
                    continue
                if answer['choice'] == 'none' or answer['confidence'] < .55:
                    r['modules'][kind] = []
                else:
                    index = int(answer['choice'][len(kind):])
                    selected = r['modules'][kind].pop(index)
                    r['modules'][kind].insert(0, selected)
                    r['selected_photos'][kind] = selected['id']
        if options['sort'] == 'relevance':
            candidates.sort(key=lambda r: -r['relevance'])
            payload['results'] = candidates + payload['results'][len(candidates):]
        payload.update(status='jev', reranked_count=len(candidates), cached=meta['cache_hit'], api_ms=meta['api_ms'])
        with CACHE_LOCK:
            CACHE[key] = deepcopy(payload)
            while len(CACHE) > 150:
                CACHE.popitem(last=False)
        return payload
    except (ValueError, OSError, KeyError, TypeError, IndexError):
        # Rebuild the local response so a partially applied invalid answer cannot leak into the fallback.
        return local_search(options) | {'status': 'fallback', 'fallback_reason': 'unavailable'}
    finally:
        JEV_SLOTS.release()


def catalog():
    return {'restaurants': len(RESTAURANTS), 'photos': sum(len(p) for p in PHOTO_CACHE.values()),
            'reviews': sum(len(r['reviews']) for r in RESTAURANTS.values()),
            'neighborhoods': {key: sum(r['neighborhood'] in names for r in RESTAURANTS.values()) for key, names in GROUPS.items()},
            'scopes': dict(Counter(r['area_priority'] for r in RESTAURANTS.values())),
            'collected_at': '2026-09-25'}
