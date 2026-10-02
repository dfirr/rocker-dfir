"""Exercise HTTP authentication against a disposable local RStudio server."""
import sys
import time
import requests

username, expected = sys.argv[1:]
session = requests.Session()
base = "http://127.0.0.1:8787"
for attempt in range(50):
    try:
        page = session.get(base + "/auth-sign-in", timeout=2)
        page.raise_for_status()
        break
    except requests.RequestException:
        if attempt == 49:
            raise
        time.sleep(0.1)
token = session.cookies.get("csrf-token")
assert token, "Missing CSRF cookie"
response = session.post(
    base + "/auth-do-sign-in",
    data={"username": username, "password": "test-password",
          "staySignedIn": "0", "appUri": "/", "csrf-token": token},
    headers={"Referer": base + "/auth-sign-in"},
    allow_redirects=False, timeout=10,
)
location = response.headers.get("Location", "")
accepted = response.status_code == 302 and "auth-sign-in" not in location
assert accepted == (expected == "accepted"), (username, response.status_code, location)
print(f"HTTP login {username}: {expected}")
