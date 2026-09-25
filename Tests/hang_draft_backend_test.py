#!/usr/bin/env python3
"""Drafting quotas and authorization against disposable LOCAL accounts; no vendor calls."""
import concurrent.futures
import json
import secrets
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid

config = json.loads(subprocess.check_output(['supabase', 'status', '-o', 'json'], stderr=subprocess.DEVNULL))
base = config['API_URL']
assert urllib.parse.urlparse(base).hostname in ('localhost', '127.0.0.1'), 'Local tests only'
created = []


def request(method, path, body=None, token=None):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
        headers={'apikey': config['ANON_KEY'], 'Content-Type': 'application/json',
                 **({'Authorization': 'Bearer ' + token} if token else {})}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            data = response.read()
            return response.status, json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def ok(method, path, body=None, token=None):
    status, data = request(method, path, body, token)
    assert 200 <= status < 300, f'Unexpected status {status}'
    return data


def user(complete=True):
    email, password = f'draft-{uuid.uuid4()}@example.test', secrets.token_urlsafe(24)
    account = ok('POST', '/auth/v1/admin/users', {'email': email, 'password': password, 'email_confirm': True}, config['SERVICE_ROLE_KEY'])
    created.append(account['id'])
    token = ok('POST', '/auth/v1/token?grant_type=password', {'email': email, 'password': password})['access_token']
    snapshot = ok('POST', '/rest/v1/rpc/bootstrap_account', {'p_initial_name': 'Draft Test'}, token)
    if complete:
        ok('POST', '/rest/v1/rpc/save_account', {'p_display_name': 'Draft Test', 'p_avatar_path': None,
            'p_location_mode': 'vicinity', 'p_notification_mode': 'off',
            'p_profile_revision': snapshot['profile']['revision'], 'p_settings_revision': snapshot['settings']['revision']}, token)
    return account['id'], token


def consume(token):
    return request('POST', '/rest/v1/rpc/consume_hang_draft', {}, token)[0]


def sql(command):
    return subprocess.check_output(['docker', 'exec', '-i', 'supabase_db_whosintownrightnow',
        'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atc', command], text=True).strip()


try:
    account, token = user()
    incomplete, incomplete_token = user(complete=False)
    assert consume(None) in (401, 403)
    assert consume(incomplete_token) == 403
    assert request('GET', '/rest/v1/hang_draft_limits', token=token)[0] >= 400
    assert request('POST', '/rest/v1/rpc/consume_hang_draft', {'p_user_id': incomplete}, token)[0] >= 400
    print('PASS: anonymous/incomplete callers denied; private counter not exposed; caller identity cannot be overridden')

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        statuses = list(pool.map(consume, [token] * 28))
    assert statuses.count(204) == 20, statuses
    assert statuses.count(429) == 8, statuses
    assert sql(f"select requests from private.hang_draft_limits where user_id = '{account}'") == '20'
    print('PASS: concurrent requests cannot exceed the 20-per-hour budget')

    sql(f"update private.hang_draft_limits set window_started_at = now() - interval '61 minutes' where user_id = '{account}'")
    assert consume(token) == 204
    assert sql(f"select requests from private.hang_draft_limits where user_id = '{account}'") == '1'
    ok('PUT', f'/auth/v1/admin/users/{account}', {'ban_duration': '1h'}, config['SERVICE_ROLE_KEY'])
    assert consume(token) in (401, 403)
    print('PASS: an expired budget resets; banning takes effect for existing tokens')
finally:
    for account_id in created:
        ok('DELETE', '/auth/v1/admin/users/' + account_id, token=config['SERVICE_ROLE_KEY'])
    ids = ','.join("'" + account_id + "'" for account_id in created)
    if ids:
        assert sql(f'select count(*) from private.hang_draft_limits where user_id in ({ids})') == '0'
    print('Cleaned up local draft test accounts and their counters')
