#!/usr/bin/env python3
"""Integration tests against the local Supabase stack, never a hosted project.

Run `supabase start`, then `python3 Tests/account_backend_test.py`.
Creates disposable local accounts, exercises Auth/REST/Storage, then removes them.
"""
import json
import secrets
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor

config = json.loads(subprocess.check_output(["supabase", "status", "-o", "json"], stderr=subprocess.DEVNULL))
base = config["API_URL"]
assert urllib.parse.urlparse(base).hostname in ("127.0.0.1", "localhost"), "Local tests only"
key = config["ANON_KEY"]
admin = config["SERVICE_ROLE_KEY"]
created = []


def request(method, path, body=None, token=None, raw=False, content_type="application/json"):
    data = body if raw else (json.dumps(body).encode() if body is not None else None)
    headers = {"apikey": key, "Content-Type": content_type, "Prefer": "return=representation"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(base + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            payload = response.read()
            return response.status, payload if raw else (json.loads(payload) if payload else None)
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def ok(method, path, body=None, token=None, **kwargs):
    status, result = request(method, path, body, token, **kwargs)
    assert 200 <= status < 300, f"{method} {path}: {status}: {result}"
    return result


def new_user():
    email = f"account-test-{uuid.uuid4()}@example.test"
    password = secrets.token_urlsafe(28)
    user = ok("POST", "/auth/v1/admin/users", {"email": email, "password": password, "email_confirm": True}, admin)
    created.append(user["id"])
    session = ok("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": password})
    return user["id"], session["access_token"], session["refresh_token"]


def bootstrap(token, name=""):
    return ok("POST", "/rest/v1/rpc/bootstrap_account", {"p_initial_name": name}, token)


def save(token, name="Changed Name", location="exact", notifications="all", photo=None, snapshot=None):
    snapshot = snapshot or bootstrap(token)
    return request("POST", "/rest/v1/rpc/save_account", {
        "p_display_name": name, "p_avatar_path": photo,
        "p_location_mode": location, "p_notification_mode": notifications,
        "p_profile_revision": snapshot["profile"]["revision"],
        "p_settings_revision": snapshot["settings"]["revision"],
    }, token)


try:
    a, at, refresh = new_user()
    b, bt, _ = new_user()
    first = bootstrap(at, "Apple Name")
    assert first["profile"]["display_name"] == "Apple Name"
    assert first["profile"]["onboarding_completed_at"] is None
    assert first["settings"]["location_mode"] == "vicinity"
    assert first["settings"]["notification_mode"] == "off"
    assert first["settings"]["location_sharing_confirmed_at"] is None
    bootstrap(bt, "Second User")
    status, saved = save(at)
    assert status == 200, saved
    assert saved["profile"]["onboarding_completed_at"]
    assert saved["settings"]["location_sharing_confirmed_at"]
    assert saved["settings"]["privacy_revision"] == 2
    assert bootstrap(at, "Replacement Apple Name") == saved, "Bootstrap must preserve existing choices"
    refreshed = ok("POST", "/auth/v1/token?grant_type=refresh_token", {"refresh_token": refresh})
    at = refreshed["access_token"]
    assert bootstrap(at) == saved, "Session refresh must restore the same account"
    print("PASS: resumable bootstrap, defaults, atomic onboarding, idempotency, session refresh")

    for mode in ["off", "direct_only", "all"]:
        status, value = save(at, notifications=mode)
        assert status == 200 and value["settings"]["notification_mode"] == mode
    before = bootstrap(at)
    for invalid in [dict(name="  "), dict(location="hidden"), dict(notifications="sometimes")]:
        status, _ = save(at, **invalid)
        assert status >= 400
        assert bootstrap(at) == before, "Invalid input must not partially save"
    status, _ = request("PATCH", f"/rest/v1/user_settings?user_id=eq.{a}", {"privacy_revision": 0}, at)
    assert status == 403
    print("PASS: all notification modes, invalid values, transaction rollback, server-managed revision")

    stale = bootstrap(at)
    assert save(at, notifications="off")[0] == 200
    current = bootstrap(at)
    status, error = save(at, notifications="all", snapshot=stale)
    assert status == 409 and json.loads(error)["code"] == "PT409"
    assert bootstrap(at) == current, "A stale session must not undo Off or other saved changes"
    for table, column in [("profiles", "id"), ("user_settings", "user_id")]:
        assert request("PATCH", f"/rest/v1/{table}?{column}=eq.{a}", {"revision": 0}, at)[0] == 403
    # Direct owner updates must also invalidate the snapshot used by the RPC.
    ok("PATCH", f"/rest/v1/user_settings?user_id=eq.{a}", {"notification_mode": "direct_only"}, at)
    assert save(at, snapshot=current)[0] == 409
    current = bootstrap(at)
    ok("PATCH", f"/rest/v1/profiles?id=eq.{a}", {"display_name": "Newer Name"}, at)
    assert save(at, snapshot=current)[0] == 409
    current = bootstrap(at)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda name: save(at, name=name, snapshot=current), ["Device One", "Device Two"]))
    assert sorted(status for status, _ in results) == [200, 409], results
    assert bootstrap(at)["profile"]["revision"] == current["profile"]["revision"] + 1
    print("PASS: stale saves preserve privacy, both rows invalidate snapshots, simultaneous saves have one winner")

    assert ok("GET", f"/rest/v1/profiles?id=eq.{a}", token=bt) == []
    assert ok("GET", f"/rest/v1/user_settings?user_id=eq.{a}", token=bt) == []
    assert ok("PATCH", f"/rest/v1/profiles?id=eq.{a}", {"display_name": "Hacked"}, bt) == []
    assert request("POST", "/rest/v1/profiles", {"id": a, "display_name": "Hacked"}, bt)[0] >= 400
    assert request("GET", "/rest/v1/profiles")[0] in (401, 403)
    assert request("POST", "/rest/v1/rpc/bootstrap_account", {})[0] in (401, 403)
    print("PASS: cross-account read/write isolation and unauthenticated denial")

    path = f"{a}/{uuid.uuid4()}.jpg"
    # Storage validates MIME/size; these bytes test access control, not image rendering.
    image_bytes = b"\xff\xd8\xff\xd9"
    assert request("POST", "/storage/v1/object/avatars/" + path, image_bytes, bt, raw=True, content_type="image/jpeg")[0] >= 400
    ok("POST", "/storage/v1/object/avatars/" + path, image_bytes, at, raw=True, content_type="image/jpeg")
    status, saved = save(at, photo=path)
    assert status == 200 and saved["profile"]["avatar_path"] == path, saved
    assert ok("GET", "/storage/v1/object/authenticated/avatars/" + path, token=at, raw=True) == image_bytes
    assert request("GET", "/storage/v1/object/authenticated/avatars/" + path, token=bt, raw=True)[0] >= 400
    assert request("GET", "/storage/v1/object/public/avatars/" + path, raw=True)[0] >= 400
    assert save(bt, photo=path)[0] >= 400, "A user cannot link another user's photo"
    assert ok("DELETE", "/storage/v1/object/avatars", {"prefixes": [path]}, at) == [], "Active photos must remain"
    assert save(at, photo=None)[0] == 200
    assert len(ok("DELETE", "/storage/v1/object/avatars", {"prefixes": [path]}, at)) == 1
    print("PASS: private avatars, ownership, persistence, explicit removal, active-photo protection")
finally:
    for user_id in created:
        objects = ok("POST", "/storage/v1/object/list/avatars", {"prefix": user_id}, admin)
        paths = [user_id + "/" + item["name"] for item in objects]
        if paths:
            ok("DELETE", "/storage/v1/object/avatars", {"prefixes": paths}, admin)
        ok("DELETE", "/auth/v1/admin/users/" + user_id, token=admin)
        assert ok("GET", f"/rest/v1/profiles?id=eq.{user_id}", token=admin) == []
        assert ok("GET", f"/rest/v1/user_settings?user_id=eq.{user_id}", token=admin) == []
    print("PASS: disposable accounts cleaned up; profile/settings deletion cascades")
