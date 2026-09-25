#!/usr/bin/env python3
"""Contact discovery checks against disposable LOCAL accounts. No SMS is sent."""
import json
import secrets
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid

config = json.loads(subprocess.check_output(["supabase", "status", "-o", "json"], stderr=subprocess.DEVNULL))
base = config["API_URL"]
assert urllib.parse.urlparse(base).hostname in ("127.0.0.1", "localhost"), "Local tests only"
created = []


def request(method, path, body=None, token=None):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
        headers={"apikey": config["ANON_KEY"], "Content-Type": "application/json",
                 **({"Authorization": "Bearer " + token} if token else {})}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            data = response.read()
            return response.status, json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def ok(method, path, body=None, token=None):
    status, data = request(method, path, body, token)
    assert 200 <= status < 300, (status, data)
    return data


def rpc(name, args, token):
    return request("POST", "/rest/v1/rpc/" + name, args, token)


def user(phone=None, confirmed=False, complete=True):
    email, password = f"contacts-{uuid.uuid4()}@example.test", secrets.token_urlsafe(24)
    body = {"email": email, "password": password, "email_confirm": True}
    if phone:
        body.update(phone=phone, phone_confirm=confirmed)
    account = ok("POST", "/auth/v1/admin/users", body, config["SERVICE_ROLE_KEY"])
    created.append(account["id"])
    token = ok("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": password})["access_token"]
    status, snapshot = rpc("bootstrap_account", {"p_initial_name": "Contact Test"}, token)
    assert status == 200
    if complete:
        assert rpc("save_account", {"p_display_name": "Contact Test", "p_avatar_path": None,
            "p_location_mode": "vicinity", "p_notification_mode": "off",
            "p_profile_revision": snapshot["profile"]["revision"], "p_settings_revision": snapshot["settings"]["revision"]}, token)[0] == 200
    return account["id"], token


try:
    a, at = user("+14155550100", True)
    b, bt = user("+14155550101", True)
    c, ct = user("+14155550102", False)
    d, dt = user("+14155550103", True, complete=False)
    e, et = user()
    phones = {"p_phones": ["+14155550100", "+14155550101", "+14155550102", "+14155550103", "+14155550999"]}
    assert rpc("contact_discovery_settings", {}, bt) == (200, {"enabled": False, "verified_phone": "+14155550101"})
    assert rpc("match_contacts", phones, at) == (200, [])
    for token in (at, bt, dt):
        assert rpc("contact_discovery_settings", {"p_enabled": True}, token)[0] == 200
    assert rpc("contact_discovery_settings", {"p_enabled": True}, ct)[0] == 400
    assert rpc("contact_discovery_settings", {"p_enabled": True}, et)[0] == 400
    assert rpc("match_contacts", phones, at) == (200, ["+14155550101"])
    assert rpc("match_contacts", {"p_phones": ["+14155550101", "+14155550101"]}, at) == (200, ["+14155550101"])
    assert rpc("match_contacts", {"p_phones": []}, at) == (200, [])
    print("PASS: opt-in verified accounts only; self, incomplete and unverified accounts excluded; unique matches")

    assert rpc("match_contacts", phones, None)[0] in (401, 403)
    assert rpc("contact_discovery_settings", {}, None)[0] in (401, 403)
    assert rpc("match_contacts", phones, dt)[0] == 403
    assert rpc("contact_discovery_settings", {"p_enabled": True, "p_user_id": b}, at)[0] >= 400
    assert ok("GET", f"/rest/v1/profiles?id=eq.{b}", token=at) == []
    assert request("GET", "/rest/v1/contact_discovery", token=at)[0] >= 400
    assert request("GET", "/rest/v1/contact_lookup_limits", token=at)[0] >= 400
    for invalid in (None, [None], ["4155550101"], ["%"], ["+14155550101"] * 501):
        assert rpc("match_contacts", {"p_phones": invalid}, at)[0] == 400
    print("PASS: anonymous/incomplete callers denied, owner-only preferences, no directory/profile exposure, bounded validated inputs")

    assert rpc("contact_discovery_settings", {"p_enabled": False}, bt)[0] == 200
    assert rpc("match_contacts", phones, at) == (200, [])
    assert rpc("contact_discovery_settings", {"p_enabled": True}, bt)[0] == 200
    ok("PUT", f"/auth/v1/admin/users/{b}", {"phone": "+14155550104", "phone_confirm": True}, config["SERVICE_ROLE_KEY"])
    assert rpc("match_contacts", phones, at) == (200, [])
    assert rpc("match_contacts", {"p_phones": ["+14155550104"]}, at) == (200, ["+14155550104"])
    ok("PUT", f"/auth/v1/admin/users/{b}", {"ban_duration": "1h"}, config["SERVICE_ROLE_KEY"])
    assert rpc("match_contacts", {"p_phones": ["+14155550104"]}, at) == (200, [])
    print("PASS: disabling discovery, changing number, and banning take effect immediately")

    # Fresh caller: exactly 10,000 submitted numbers per hour, then reject further lookups.
    for _ in range(20):
        assert rpc("match_contacts", {"p_phones": ["+14155550999"] * 500}, et)[0] == 200
    assert rpc("match_contacts", {"p_phones": ["+14155550999"]}, et)[0] == 429
    print("PASS: per-account lookup budget enforced by the database")
finally:
    for account_id in created:
        ok("DELETE", "/auth/v1/admin/users/" + account_id, token=config["SERVICE_ROLE_KEY"])
    print("Cleaned up disposable local contact accounts")
