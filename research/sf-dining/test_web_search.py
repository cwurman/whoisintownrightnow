"""Widget/source contract and safe degradation tests; no paid API requests."""
from copy import deepcopy
import unittest

import web_search as web


def fixture(request, timeout=3):
    answers = {}
    for name, q in request['questions'].items():
        if q['type'] == 'score':
            answers[name] = {'type': 'score', 'score': 2.5, 'confidence': .9}
        else:
            choice = 'show' if name.startswith('show_') else next(k for k in q['criteria'] if k != 'none')
            answers[name] = {'type': 'choice', 'choice': choice, 'confidence': .9}
            if name.startswith('show_'):
                answers[name]['probabilities'] = {'show': .95, 'hide': .05}
    return {'model': 'fixture', 'answers': answers}, {'cache_hit': False, 'api_ms': 0}


class WebSearchTests(unittest.TestCase):
    def setUp(self):
        web.CACHE.clear()

    def test_geographic_filters_use_collected_neighborhoods(self):
        for scope, total in [('nearby', 273), ('focus', 192), ('all', 500)]:
            data = web.local_search(web.normalize_options({'scope': scope}))
            self.assertEqual(data['total'], total)
        for key, names in web.GROUPS.items():
            data = web.local_search(web.normalize_options({'neighborhoods': [key]}))
            self.assertTrue(data['results'])
            self.assertTrue(all(r['neighborhood'] in names for r in data['results']))

    def test_menu_browse_requires_real_menu_photos(self):
        data = web.local_search(web.normalize_options({'query': 'menu'}))
        self.assertGreater(data['total'], 10)
        self.assertTrue(all(r['modules']['menu'] for r in data['results']))
        self.assertTrue(any(p['ocr'] for r in data['results'] for p in r['modules']['menu']))

    def test_rerank_photo_choices_belong_to_same_restaurant_and_module(self):
        data = web.rerank(web.normalize_options({'query': 'kebab outdoor seating'}), evaluator=fixture)
        self.assertEqual(data['status'], 'jev')
        self.assertEqual(data['signals']['food'], .95)
        self.assertEqual(data['signals']['space'], .95)
        self.assertLessEqual(data['reranked_count'], 10)
        for r in data['results']:
            for kind, pid in r['selected_photos'].items():
                source = next(p for p in r['photos'] if p['id'] == pid)
                self.assertEqual(source['kind'], kind)
                self.assertEqual(r['modules'][kind][0]['id'], pid)

    def test_timeout_returns_same_local_shape(self):
        def unavailable(*args, **kwargs):
            raise TimeoutError()
        options = web.normalize_options({'query': 'kebab'})
        local = web.local_search(options)
        failed = web.rerank(options, evaluator=unavailable)
        self.assertEqual(failed['status'], 'fallback')
        self.assertEqual(local['results'], failed['results'])
        self.assertEqual(local.keys(), failed.keys())

    def test_unknown_photo_choice_cannot_escape_source_records(self):
        def invalid(request, **kwargs):
            response, meta = fixture(request)
            key = next(k for k in response['answers'] if k.startswith('c') and k.endswith('_food'))
            response['answers'][key]['choice'] = 'food999'
            return response, meta
        data = web.rerank(web.normalize_options({'query': 'kebab'}), evaluator=invalid)
        self.assertEqual(data['status'], 'fallback')
        self.assertTrue(all(r['relevance'] is None for r in data['results']))

    def test_widget_question_criteria_are_distinct_and_data_is_text_only(self):
        local = web.local_search(web.normalize_options({'query': 'kebab outdoor seating'}))
        request = web.make_widget_request('kebab outdoor seating', local['results'][:10])
        show = [request['questions']['show_' + k]['criteria']['show'] for k in web.MODULES]
        self.assertEqual(len(show), len(set(show)))
        for r in request['state']['candidates'].values():
            for photo in r['photos'].values():
                self.assertNotIn('url', photo)

    def test_broad_and_compound_local_signals(self):
        self.assertLess(web.fallback_signals('mediterranean food')['food'], .2)
        signal = web.fallback_signals('kebab with outdoor seating')
        self.assertGreater(signal['food'], .8)
        self.assertGreater(signal['space'], .8)

    def test_cached_payload_is_isolated_and_ratings_sort_is_preserved(self):
        options = web.normalize_options({'query': 'outdoor seating', 'sort': 'rating'})
        data = web.rerank(options, evaluator=fixture)
        ratings = [r['rating'] for r in data['results']]
        self.assertEqual(ratings, sorted(ratings, reverse=True))
        data['results'].clear()
        self.assertTrue(web.rerank(options, evaluator=fixture)['results'])

    def test_unmatched_query_is_empty_and_bad_input_is_rejected(self):
        self.assertEqual(web.local_search(web.normalize_options({'query': 'zzzznomatches123'}))['total'], 0)
        for bad in [{'query': 'a' * 301}, {'scope': 'private'}, {'neighborhoods': ['unknown']}, {'sort': 'price'}]:
            with self.assertRaises(ValueError):
                web.normalize_options(bad)


if __name__ == '__main__':
    unittest.main()
