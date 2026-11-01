#!/usr/bin/env python3
"""Assign Macs in Apple Business Manager to a client's Addigy MDM server.

Once a Mac's serial number is assigned to Addigy in Apple Business Manager (ABM), it enrolls
into Addigy automatically the first time it reaches the internet during Setup Assistant
(Automated Device Enrollment). This script removes the manual "find the serial in ABM, click
Edit MDM Server, pick Addigy" step, for one Mac or a whole order at once.

Uses the Apple Business Manager API (Preferences > API in ABM) with one API account per client.

Commands:
  servers                       List the MDM servers in the client's ABM (find the Addigy one)
  status  SERIAL [SERIAL ...]   Show whether each serial is in ABM and which server it is on
  assign  SERIAL [SERIAL ...]   Assign serials to the client's Addigy server and wait for it
          --csv FILE            ... or read serials from the first column of a CSV
          --dry-run             Show what would happen without changing anything
          --reassign            Also move Macs currently assigned to another MDM server

Examples:
  python3 abm_assign.py --client contoso servers
  python3 abm_assign.py --client contoso status C02XK1ABJG5H
  python3 abm_assign.py --client contoso assign --csv order-4471.csv
"""

import argparse
import csv
import json
import sys
import time
import uuid
from pathlib import Path

import jwt  # PyJWT
import requests

API = "https://api-business.apple.com/v1"
TOKEN_URL = "https://account.apple.com/auth/oauth2/token"
TOKEN_AUDIENCE = "https://account.apple.com/auth/oauth2/v2/token"
CONFIG_PATH = Path(__file__).with_name("clients.json")
MAX_BATCH = 100  # keep each assignment activity to a manageable size


class ABMClient:
    def __init__(self, client_id: str, key_id: str, private_key_path: Path):
        self.client_id = client_id
        self.key_id = key_id
        self.private_key = private_key_path.read_text()
        self.session = requests.Session()
        self._token = None
        self._token_expiry = 0.0

    # -- auth -----------------------------------------------------------------------------
    def _client_assertion(self) -> str:
        now = int(time.time())
        payload = {
            "sub": self.client_id,
            "iss": self.client_id,
            "aud": TOKEN_AUDIENCE,
            "iat": now,
            "exp": now + 60 * 60,
            "jti": str(uuid.uuid4()),
        }
        return jwt.encode(payload, self.private_key, algorithm="ES256",
                          headers={"kid": self.key_id})

    def _auth_header(self) -> dict:
        if not self._token or time.time() > self._token_expiry - 60:
            resp = self.session.post(TOKEN_URL, data={
                "grant_type": "client_credentials",
                "client_id": self.client_id,
                "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion": self._client_assertion(),
                "scope": "business.api",
            }, timeout=30)
            if resp.status_code != 200:
                sys.exit(f"ABM sign-in failed ({resp.status_code}): {resp.text}")
            body = resp.json()
            self._token = body["access_token"]
            self._token_expiry = time.time() + int(body.get("expires_in", 3600))
        return {"Authorization": f"Bearer {self._token}"}

    # -- http -----------------------------------------------------------------------------
    def request(self, method: str, url: str, **kwargs) -> requests.Response:
        if not url.startswith("http"):
            url = f"{API}{url}"
        for attempt in range(5):
            resp = self.session.request(method, url, headers=self._auth_header(), timeout=30, **kwargs)
            if resp.status_code == 429:  # rate limited: back off and retry
                time.sleep(int(resp.headers.get("Retry-After", 2 ** attempt)))
                continue
            return resp
        return resp

    def get_all(self, path: str) -> list:
        items, url = [], path
        while url:
            resp = self.request("GET", url)
            resp.raise_for_status()
            body = resp.json()
            items.extend(body.get("data", []))
            url = body.get("links", {}).get("next")
        return items

    # -- ABM operations -------------------------------------------------------------------
    def mdm_servers(self) -> list:
        return self.get_all("/mdmServers")

    def device(self, serial: str):
        resp = self.request("GET", f"/orgDevices/{serial}")
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        return resp.json()["data"]

    def assigned_server_id(self, serial: str):
        resp = self.request("GET", f"/orgDevices/{serial}/relationships/assignedServer")
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        data = resp.json().get("data")
        return data["id"] if data else None

    def assign(self, server_id: str, serials: list) -> dict:
        body = {"data": {
            "type": "orgDeviceActivities",
            "attributes": {"activityType": "ASSIGN_DEVICES"},
            "relationships": {
                "mdmServer": {"data": {"type": "mdmServers", "id": server_id}},
                "devices": {"data": [{"type": "orgDevices", "id": s} for s in serials]},
            },
        }}
        resp = self.request("POST", "/orgDeviceActivities", json=body)
        if resp.status_code not in (200, 201):
            sys.exit(f"Assignment request failed ({resp.status_code}): {resp.text}")
        return resp.json()["data"]

    def wait_for_activity(self, activity_id: str, timeout: int = 600) -> dict:
        deadline = time.time() + timeout
        while True:
            resp = self.request("GET", f"/orgDeviceActivities/{activity_id}")
            resp.raise_for_status()
            attrs = resp.json()["data"]["attributes"]
            if attrs.get("status") != "IN_PROGRESS" or time.time() > deadline:
                return attrs
            time.sleep(10)


# -- helpers -------------------------------------------------------------------------------
def load_client(name: str) -> dict:
    if not CONFIG_PATH.exists():
        sys.exit(f"Missing {CONFIG_PATH.name}. Copy clients.example.json and fill it in.")
    clients = json.loads(CONFIG_PATH.read_text())
    if name not in clients:
        sys.exit(f"Unknown client '{name}'. Known: {', '.join(sorted(clients))}")
    return clients[name]


def read_serials(args) -> list:
    serials = list(args.serials or [])
    if getattr(args, "csv", None):
        with open(args.csv, newline="") as f:
            for row in csv.reader(f):
                if row and row[0].strip() and row[0].strip().lower() not in ("serial", "serial number"):
                    serials.append(row[0].strip())
    # Normalise and de-duplicate while keeping order.
    seen, out = set(), []
    for s in (s.upper().replace(" ", "") for s in serials):
        if s not in seen:
            seen.add(s)
            out.append(s)
    if not out:
        sys.exit("No serial numbers given.")
    return out


def find_server(abm: ABMClient, server_name: str) -> dict:
    servers = abm.mdm_servers()
    for s in servers:
        if s["attributes"].get("serverName", "").lower() == server_name.lower():
            return s
    names = ", ".join(s["attributes"].get("serverName", "?") for s in servers)
    sys.exit(f"MDM server '{server_name}' not found in ABM. Available: {names}")


# -- commands ------------------------------------------------------------------------------
def cmd_servers(abm: ABMClient, cfg: dict, args) -> None:
    for s in abm.mdm_servers():
        a = s["attributes"]
        print(f"{s['id']}  {a.get('serverName', '?'):40}  {a.get('serverType', '')}")


def cmd_status(abm: ABMClient, cfg: dict, args) -> None:
    names = {s["id"]: s["attributes"].get("serverName", s["id"]) for s in abm.mdm_servers()}
    for serial in read_serials(args):
        dev = abm.device(serial)
        if not dev:
            print(f"{serial:16} NOT IN ABM  (buy through an ABM-linked reseller, or add with Apple Configurator)")
            continue
        model = dev["attributes"].get("productDescription") or dev["attributes"].get("deviceModel", "")
        server = abm.assigned_server_id(serial)
        print(f"{serial:16} {model:30} {names.get(server, 'UNASSIGNED') if server else 'UNASSIGNED'}")


def cmd_assign(abm: ABMClient, cfg: dict, args) -> None:
    server = find_server(abm, cfg["addigy_server_name"])
    server_id, server_name = server["id"], server["attributes"]["serverName"]

    to_assign, failed = [], []
    for serial in read_serials(args):
        dev = abm.device(serial)
        if not dev:
            print(f"{serial:16} SKIP  not in ABM")
            failed.append(serial)
        else:
            current = abm.assigned_server_id(serial)
            if current == server_id:
                print(f"{serial:16} OK    already assigned to {server_name}")
            elif current and not args.reassign:
                print(f"{serial:16} SKIP  assigned to another MDM server ({current}); use --reassign to move it")
                failed.append(serial)
            else:
                to_assign.append(serial)

    if not to_assign:
        print("Nothing to assign.")
        sys.exit(1 if failed else 0)

    print(f"\nAssigning {len(to_assign)} Mac(s) to '{server_name}'")
    if args.dry_run:
        print("Dry run: no changes made.")
        return

    for i in range(0, len(to_assign), MAX_BATCH):
        batch = to_assign[i:i + MAX_BATCH]
        activity = abm.assign(server_id, batch)
        result = abm.wait_for_activity(activity["id"])
        status = result.get("status")
        print(f"  batch {i // MAX_BATCH + 1}: {status} {result.get('subStatus', '')}".rstrip())
        if status != "COMPLETED":
            failed.extend(batch)
            if result.get("downloadUrl"):
                print(f"  details: {result['downloadUrl']}")

    # Verify each device so the output is something you can paste into the ticket.
    print()
    for serial in to_assign:
        ok = abm.assigned_server_id(serial) == server_id
        print(f"{serial:16} {'ASSIGNED' if ok else 'CHECK  '} -> {server_name}")
        if not ok and serial not in failed:
            failed.append(serial)

    print("\nNext: power on the Mac (or erase it if it was already set up) and connect to the "
          "internet. It will enroll into Addigy during Setup Assistant.")
    sys.exit(1 if failed else 0)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--client", required=True, help="client key in clients.json")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("servers", help="list MDM servers in ABM")

    p_status = sub.add_parser("status", help="show ABM status of serials")
    p_status.add_argument("serials", nargs="*")
    p_status.add_argument("--csv")

    p_assign = sub.add_parser("assign", help="assign serials to the client's Addigy server")
    p_assign.add_argument("serials", nargs="*")
    p_assign.add_argument("--csv")
    p_assign.add_argument("--dry-run", action="store_true")
    p_assign.add_argument("--reassign", action="store_true",
                          help="also move Macs currently assigned to a different MDM server")

    args = parser.parse_args()
    cfg = load_client(args.client)
    key_path = Path(cfg["private_key_path"]).expanduser()
    if not key_path.is_absolute():
        key_path = CONFIG_PATH.parent / key_path
    abm = ABMClient(cfg["client_id"], cfg["key_id"], key_path)

    {"servers": cmd_servers, "status": cmd_status, "assign": cmd_assign}[args.command](abm, cfg, args)


if __name__ == "__main__":
    main()
