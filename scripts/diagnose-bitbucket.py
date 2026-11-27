#!/usr/bin/env python3
"""Read-only Bitbucket Cloud diagnostic for MergeCue.

Replays the calls MergeCue makes to find your authored pull requests, using the Bitbucket credential MergeCue
stored in your login Keychain (macOS asks for permission; the token is never printed, logged or sent anywhere
but api.bitbucket.org). Prints only HTTP statuses, counts, workspace slugs and repository names.

    python3 scripts/diagnose-bitbucket.py
"""
import base64
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.bitbucket.org/2.0"
SERVICE = "dev.mergecue.credentials"


def find_credential():
    dump = subprocess.run(["security", "dump-keychain"], capture_output=True, text=True).stdout
    accounts = []
    for block in dump.split("keychain: ")[1:]:
        if f'"svce"<blob>="{SERVICE}"' in block and "bitbucket" in block:
            for line in block.splitlines():
                if '"acct"<blob>=' in line:
                    accounts.append(line.split('<blob>=', 1)[1].strip().strip('"'))
    if not accounts:
        sys.exit("No Bitbucket credential from MergeCue found in the login Keychain. Connect Bitbucket in MergeCue first.")
    account = accounts[0]
    raw = subprocess.run(["security", "find-generic-password", "-s", SERVICE, "-a", account, "-w"],
                         capture_output=True, text=True)
    if raw.returncode != 0:
        sys.exit("Keychain access was denied or failed: " + raw.stderr.strip())
    secret = json.loads(raw.stdout.strip())["secret"]
    if secret["type"] == "basic":
        value = base64.b64encode(f'{secret["username"]}:{secret["password"]}'.encode()).decode()
        return account, "Basic " + value, "email + API token"
    return account, "Bearer " + secret["token"], "access token (Bearer)"


def get(auth, path, params=None):
    url = path if path.startswith("http") else API + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"Authorization": auth, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read() or b"{}"), response.headers
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")[:300]
        return error.code, {"error": body}, error.headers


def show(label, status, body, extra=""):
    detail = ""
    if status >= 400:
        detail = " -> " + json.dumps(body.get("error"))[:240]
    print(f"  [{status}] {label}{extra}{detail}")


def main():
    account, auth, kind = find_credential()
    print(f"MergeCue Bitbucket credential: {kind}\n")

    status, user, headers = get(auth, "/user")
    show("GET /user", status, user)
    if status != 200:
        sys.exit("\nThe token cannot read your profile (needs read:user:bitbucket, or the token/email is wrong).")
    uuid = user.get("uuid")
    print(f"      user: {user.get('nickname') or user.get('display_name')} {uuid}")
    scopes = headers.get("x-oauth-scopes") or headers.get("X-OAuth-Scopes")
    if scopes:
        print(f"      token scopes: {scopes}")

    status, spaces, _ = get(auth, "/user/workspaces", {"pagelen": 100})
    slugs = [v.get("workspace", {}).get("slug") for v in spaces.get("values", [])] if status == 200 else []
    show("GET /user/workspaces", status, spaces, f" -> {len(slugs)} workspace(s): {', '.join(filter(None, slugs))}")
    if status != 200:
        status, spaces, _ = get(auth, "/user/permissions/workspaces", {"pagelen": 100})
        slugs = [v.get("workspace", {}).get("slug") for v in spaces.get("values", [])] if status == 200 else []
        show("GET /user/permissions/workspaces (fallback)", status, spaces, f" -> {len(slugs)} workspace(s)")

    total = 0
    first_pr = None
    for slug in filter(None, slugs):
        path = f"/workspaces/{urllib.parse.quote(slug)}/pullrequests/{urllib.parse.quote(uuid)}"
        status, page, _ = get(auth, path, {"state": "OPEN", "pagelen": 50})
        prs = page.get("values", []) if status == 200 else []
        total += len(prs)
        repos = sorted({pr.get("destination", {}).get("repository", {}).get("full_name", "?") for pr in prs})
        show(f"authored open PRs in '{slug}'", status, page, f" -> {len(prs)} PR(s) {repos if repos else ''}")
        if prs and first_pr is None:
            first_pr = prs[0]

    print(f"\nAuthored open PRs found: {total}")
    if first_pr:
        repo = first_pr.get("destination", {}).get("repository", {}).get("full_name")
        number = first_pr.get("id")
        print(f"\nLoading the details MergeCue needs for {repo}#{number}:")
        base = f"/repositories/{repo}/pullrequests/{number}"
        for label, sub in [("PR detail", ""), ("comments", "/comments"), ("tasks", "/tasks"),
                           ("statuses", "/statuses"), ("commits", "/commits"), ("diffstat", "/diffstat")]:
            status, body, _ = get(auth, base + sub, {"pagelen": 10} if sub else None)
            show(label, status, body)
        status, body, _ = get(auth, f"/repositories/{repo}/pipelines/", {"pagelen": 1})
        show("pipelines (optional)", status, body)
    print("\nNothing was changed. Paste this output (it contains no token) to MergeCue's developer.")


if __name__ == "__main__":
    main()
