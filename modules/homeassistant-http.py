"""Merge the reverse proxy settings into Home Assistant's .storage/http.

Usage: homeassistant-http <path to .storage/http> <settings JSON file>

The settings file holds the keys the homeassistant module manages,
use_x_forwarded_for and trusted_proxies. Every other setting in the store
stays as Home Assistant or its network settings left it
(docs/adr/0022-home-assistant-http-settings-after-the-yaml.md).

Home Assistant 2026.11 (components/http/config.py) stores the file as
version 3: a stable slot it applies without a trial, a pending slot the
network settings stage for one, and whether the YAML was taken over. Both
slots get the managed keys, so a trial started in the UI cannot change
them. With no file yet, the tool writes a version 1 file, a plain config
that Home Assistant migrates through its own schema on start, filling in
its defaults as the stable slot. A version it does not know, it leaves
alone and fails.
"""

import ipaddress
import json
import os
import sys
import tempfile

KEY = "http"
MANAGED = ("use_x_forwarded_for", "trusted_proxies")
# Version 1 is a plain config; 2 and 3 hold it in the slots below.
SLOTS = ("stable", "pending")
KNOWN = (1, 2, 3)


def fail(message):
    print(f"homeassistant-http: {message}", file=sys.stderr)
    sys.exit(1)


def managed(path):
    with open(path, encoding="utf-8") as f:
        settings = json.load(f)
    proxies = []
    for proxy in settings["trusted_proxies"]:
        # As Home Assistant's own schema has it: a network with no host
        # bits set, in its normal form. The stored config skips the schema,
        # so a wrong one would only fail when the server starts.
        try:
            proxies.append(str(ipaddress.ip_network(proxy)))
        except ValueError as err:
            fail(f"trusted proxy {proxy!r}: {err}")
    return {
        "use_x_forwarded_for": bool(settings["use_x_forwarded_for"]),
        "trusted_proxies": proxies,
    }


def merge(store, settings):
    version = store.get("version")
    if store.get("key") != KEY or version not in KNOWN:
        fail(
            f"unknown store (key {store.get('key')!r}, version {version!r}); "
            "left as it is"
        )
    if version == 1:
        store["data"].update(settings)
        return store
    data = store["data"]
    for slot in SLOTS:
        if data.get(slot) is not None:
            data[slot].update(settings)
    return store


def write(path, store):
    # As Home Assistant writes it: private, and replaced in one rename.
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".http.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(store, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def main(argv):
    if len(argv) != 3 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if len(argv) == 2 else 2
    path, settings = argv[1], managed(argv[2])
    try:
        with open(path, encoding="utf-8") as f:
            store = json.load(f)
    except FileNotFoundError:
        store = None
    except ValueError as err:
        fail(f"{path} is not JSON ({err}); left as it is")

    if store is None:
        new = {"version": 1, "minor_version": 1, "key": KEY, "data": settings}
        print("homeassistant-http: no store yet, writing the settings for Home Assistant to take over")
    else:
        new = merge(json.loads(json.dumps(store)), settings)
        if new == store:
            print("homeassistant-http: settings already in place")
            return 0
        print(f"homeassistant-http: settings merged into version {store['version']}")
    write(path, new)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
