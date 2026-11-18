"""Tests of lib/homelab/images.py and the image-updates skill, against a fake
registry on 127.0.0.1 that speaks the bearer-token flow, manifests, indexes,
blobs behind a redirect, and a paginated tag list.

Run from the repository root:  python3 -m unittest discover -s tests -p 'test_*.py'
"""
from __future__ import annotations

import hashlib
import http.server
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "lib"))
from homelab import images  # noqa: E402

OCI_INDEX = "application/vnd.oci.image.index.v1+json"
OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"


def blob(obj) -> tuple[str, bytes]:
    data = json.dumps(obj, sort_keys=True).encode()
    return "sha256:" + hashlib.sha256(data).hexdigest(), data


class FakeRegistry:
    """Repositories of manifests and blobs, keyed by digest, and tags."""

    def __init__(self):
        self.manifests: dict[str, dict[str, tuple[str, bytes]]] = {}
        self.blobs: dict[str, dict[str, bytes]] = {}
        self.tags: dict[str, dict[str, str]] = {}
        self.log: list[str] = []

    def add_image(self, repo: str, labels: dict | None = None, created: str = "2026-11-01T00:00:00Z",
                  media_type: str = OCI_MANIFEST) -> str:
        """An image manifest with a config; returns its digest."""
        cdigest, cdata = blob({"architecture": "amd64", "os": "linux", "created": created,
                               "config": {"Labels": labels} if labels else {}})
        self.blobs.setdefault(repo, {})[cdigest] = cdata
        digest, data = blob({"schemaVersion": 2, "mediaType": media_type,
                             "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                                        "digest": cdigest, "size": len(cdata)},
                             "layers": []})
        self.manifests.setdefault(repo, {})[digest] = (media_type, data)
        return digest

    def add_index(self, repo: str, children: list[tuple[str, str, dict | None]]) -> str:
        """An index of (digest, architecture, annotations); returns its digest."""
        digest, data = blob({"schemaVersion": 2, "mediaType": OCI_INDEX, "manifests": [
            {"mediaType": OCI_MANIFEST, "digest": d, "size": 1,
             "platform": {"os": "linux", "architecture": arch},
             **({"annotations": ann} if ann else {})} for d, arch, ann in children]})
        self.manifests.setdefault(repo, {})[digest] = (OCI_INDEX, data)
        return digest

    def tag(self, repo: str, tag: str, digest: str) -> None:
        self.tags.setdefault(repo, {})[tag] = digest

    def serve(self) -> tuple[http.server.ThreadingHTTPServer, str]:
        registry = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_HEAD(self):
                self.handle_request(head=True)

            def do_GET(self):
                self.handle_request(head=False)

            def send(self, code, body=b"", headers=None, head=False):
                self.send_response(code)
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if not head:
                    self.wfile.write(body)

            def handle_request(self, head):
                url = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(url.query)
                base = f"http://127.0.0.1:{self.server.server_address[1]}"
                registry.log.append(f"{self.command} {url.path}")
                if url.path == "/token":
                    scope = query["scope"][0]
                    assert query["service"] == ["fake-registry"], query
                    return self.send(200, json.dumps({"token": "t:" + scope}).encode(), head=head)
                if url.path.startswith("/blobstore/"):
                    # A blob store must not be sent the registry's token.
                    if self.headers.get("Authorization"):
                        return self.send(400, b"token sent to the blob store", head=head)
                    repo, digest = url.path[len("/blobstore/"):].rsplit("/", 1)
                    return self.send(200, registry.blobs[repo][digest], head=head)
                m = re.match(r"^/v2/(.+)/(manifests|blobs|tags)/(.+)$", url.path)
                if not m:
                    return self.send(404, head=head)
                repo, kind, ref = m.groups()
                if self.headers.get("Authorization") != f"Bearer t:repository:{repo}:pull":
                    return self.send(401, b"{}", {"WWW-Authenticate":
                        f'Bearer realm="{base}/token",service="fake-registry",scope="repository:{repo}:pull"'},
                        head=head)
                if kind == "blobs":
                    if ref not in registry.blobs.get(repo, {}):
                        return self.send(404, head=head)
                    return self.send(307, headers={"Location": f"{base}/blobstore/{repo}/{ref}"}, head=head)
                if kind == "tags":
                    tags = sorted(registry.tags.get(repo, {}))
                    n = int(query.get("n", ["1000"])[0])
                    after = query.get("last", [""])[0]
                    page = [t for t in tags if t > after][:2]  # small pages, to test the Link header
                    headers = {"Content-Type": "application/json"}
                    if page and page[-1] != tags[-1]:
                        headers["Link"] = f'</v2/{repo}/tags/list?n={n}&last={page[-1]}>; rel="next"'
                    return self.send(200, json.dumps({"name": repo, "tags": page}).encode(), headers, head)
                digest = ref if ref.startswith("sha256:") else registry.tags.get(repo, {}).get(ref)
                found = registry.manifests.get(repo, {}).get(digest or "")
                if not found:
                    return self.send(404, b'{"errors":[{"code":"MANIFEST_UNKNOWN"}]}', head=head)
                media_type, data = found
                accept = self.headers.get("Accept", "")
                if media_type not in accept:
                    return self.send(406, head=head)
                return self.send(200, data, {"Content-Type": media_type, "Docker-Content-Digest": digest}, head)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server, f"http://127.0.0.1:{server.server_address[1]}"


def no_proxy():
    for k in ("http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
        os.environ.pop(k, None)


class RealPins(unittest.TestCase):
    """The pins in containers/ as they are in the tree."""

    def setUp(self):
        self.pins = images.find_pins(str(REPO / "containers"))
        self.by_name = {p.image.rsplit("/", 1)[-1]: p for p in self.pins}

    def test_every_pin_has_a_tag(self):
        # Every @sha256 reference in containers/ must be found as a pin and
        # name its tag, so image-updates can check it. Fix a failure by
        # writing the pin as: image = "<name>@sha256:<digest>"; # <version>, :<tag> as of <date>
        refs = []
        for path in sorted((REPO / "containers").rglob("*.nix")):
            for no, line in enumerate(path.read_text().splitlines(), 1):
                if "@sha256:" in line and not line.lstrip().startswith("#"):
                    refs.append(f"{path.relative_to(REPO / 'containers')}:{no}")
        found = [f"{p.file}:{p.line}" for p in self.pins]
        self.assertEqual(refs, found, "an @sha256 reference that is not a pin")
        untagged = [f"containers/{p.file}:{p.line}" for p in self.pins if p.tag is None]
        self.assertEqual(untagged, [], "pins whose comment names no tag")
        undated = [f"containers/{p.file}:{p.line}" for p in self.pins if p.date is None]
        self.assertEqual(undated, [], "pins whose comment has no 'as of <date>'")

    def test_formats(self):
        # Version and tag with a suffix.
        p = self.by_name["forgejo"]
        self.assertEqual(p.tag, "17-rootless")
        self.assertRegex(p.version, r"^17\.\d+\.\d+-rootless$")
        # Version and a tag of major and minor.
        p = self.by_name["mongo"]
        self.assertEqual(p.tag, "8.0")
        self.assertRegex(p.version, r"^8\.0\.\d+$")
        self.assertEqual(p.image, "docker.io/library/mongo")
        # Version and a tag that is no version.
        p = self.by_name["home-assistant"]
        self.assertEqual(p.tag, "stable")
        self.assertRegex(p.version, r"^\d{4}\.\d+\.\d+$")
        # Tag with a note between it and the date.
        p = self.by_name["all-in-one"]
        self.assertEqual((p.tag, p.version), ("latest", None))
        self.assertIn("(built ", images.parse_comment(p.comment)[2])
        # lscr.io and codeberg.org names.
        self.assertEqual(images.split_name(self.by_name["unifi-network-application"].image),
                         ("lscr.io", "linuxserver/unifi-network-application"))
        self.assertEqual(images.split_name(self.by_name["forgejo"].image), ("codeberg.org", "forgejo/forgejo"))


class Parsing(unittest.TestCase):
    def test_comment(self):
        self.assertEqual(images.parse_comment(" 1.37.1, :latest as of 2026-08-04"),
                         ("1.37.1", "latest", "", "2026-08-04"))
        # Tag only.
        self.assertEqual(images.parse_comment(" :stable as of 2026-06-13"),
                         (None, "stable", "", "2026-06-13"))
        self.assertEqual(images.parse_comment(" :latest (built 2026-11-03, revision 97ef10c) as of 2026-11-12"),
                         (None, "latest", " (built 2026-11-03, revision 97ef10c)", "2026-11-12"))
        self.assertEqual(images.parse_comment(" pinned by hand")[1], None)
        self.assertEqual(images.parse_comment(None)[1], None)

    def test_commented_out_pin_is_no_pin(self):
        self.assertIsNone(images.parse_line(
            '#  image = "docker.io/x/y@sha256:' + "a" * 64 + '"; # :latest as of 2026-01-01'))

    def test_split_name(self):
        self.assertEqual(images.split_name("caddy"), ("docker.io", "library/caddy"))
        self.assertEqual(images.split_name("docker.io/library/caddy"), ("docker.io", "library/caddy"))
        self.assertEqual(images.split_name("prom/prometheus"), ("docker.io", "prom/prometheus"))
        self.assertEqual(images.split_name("127.0.0.1:5000/a/b"), ("127.0.0.1:5000", "a/b"))

    def test_newer_tags(self):
        tags = ["17-rootless", "18-rootless", "18", "18.0.1-rootless", "18-rc1-rootless", "latest"]
        self.assertEqual(images.newer_tags("17-rootless", tags), ("18-rootless", None))
        self.assertEqual(images.newer_tags("8.0", ["7.0", "8.0", "8.2", "9.0", "10.0", "9.0.1"]), ("10.0", None))
        self.assertEqual(images.newer_tags("0.17.1-tensorrt",
                                           ["0.17.2-tensorrt", "0.18.0-tensorrt", "0.18.0", "0.18.1-rc1-tensorrt"]),
                         ("0.18.0-tensorrt", "0.17.2-tensorrt"))
        self.assertEqual(images.newer_tags("latest", tags), (None, None))
        self.assertEqual(images.newer_tags("3", ["2", "3"]), (None, None))

    def test_new_version(self):
        self.assertEqual(images.new_version("17.0.1-rootless", "17.0.2"), "17.0.2-rootless")
        self.assertEqual(images.new_version("2.11.2", "2.11.9-alpine"), "2.11.9")
        self.assertEqual(images.new_version("1.37.1", "v1.37.5"), "1.37.5")
        self.assertEqual(images.new_version(None, "2026.11.2"), "2026.11.2")
        self.assertIsNone(images.new_version("1.0", None))


DIGEST_RE = r"sha256:[0-9a-f]{64}"


class AgainstFakeRegistry(unittest.TestCase):
    def setUp(self):
        no_proxy()
        self.reg = FakeRegistry()
        self.server, self.url = self.reg.serve()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        # Real registry names, all answered by the fake.
        self.hosts = {r: self.url for r in ("docker.io", "ghcr.io", "codeberg.org", "lscr.io")}
        self.client = images.RegistryClient(self.hosts, timeout=10)

    def write(self, text: str, name: str = "containers/a.nix") -> pathlib.Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def check(self):
        return images.check(str(self.root), self.client)

    def test_single_manifest_up_to_date_and_moved(self):
        old = self.reg.add_image("vaultwarden/server", {images.VERSION_LABEL: "1.37.1"}, media_type=DOCKER_MANIFEST)
        new = self.reg.add_image("vaultwarden/server", {images.VERSION_LABEL: "1.37.5",
                                                        images.REVISION_LABEL: "6ed6921aaaa"})
        self.reg.tag("vaultwarden/server", "latest", old)
        self.write(f'  image = "docker.io/vaultwarden/server@{old}"; # 1.37.1, :latest as of 2026-08-04\n')
        [r] = self.check()
        self.assertEqual((r.status, r.current_digest, r.new_version), ("up-to-date", old, "1.37.1"))

        self.reg.tag("vaultwarden/server", "latest", new)
        [r] = self.check()
        self.assertEqual((r.status, r.pinned_digest, r.current_digest), ("update", old, new))
        self.assertEqual((r.old_version, r.new_version), ("1.37.1", "1.37.5"))
        self.assertEqual((r.file, r.line, r.tag), ("containers/a.nix", 1, "latest"))
        # The token flow ran, and blobs were fetched from the store without it.
        self.assertIn("GET /token", self.reg.log)
        self.assertTrue(any(e.startswith("GET /blobstore/") for e in self.reg.log))

    def test_index_digest_is_compared(self):
        repo = "library/caddy"
        amd64 = self.reg.add_image(repo)
        arm64 = self.reg.add_image(repo, created="2026-11-02T00:00:00Z")
        index = self.reg.add_index(repo, [(amd64, "amd64", {images.VERSION_LABEL: "2.11.2-alpine"}),
                                          (arm64, "arm64", None)])
        self.reg.tag(repo, "2", index)
        self.write(f'image = "docker.io/library/caddy@{index}"; # 2.11.2, :2 as of 2026-07-18\n')
        [r] = self.check()
        self.assertEqual((r.status, r.current_digest), ("up-to-date", index))

        # A new index around a new amd64 image: an update to the index digest,
        # with the version from the platform's annotation (no config label).
        amd64b = self.reg.add_image(repo, created="2026-11-10T00:00:00Z")
        index2 = self.reg.add_index(repo, [(amd64b, "amd64", {images.VERSION_LABEL: "2.11.9-alpine"}),
                                           (arm64, "arm64", None)])
        self.reg.tag(repo, "2", index2)
        [r] = self.check()
        self.assertEqual((r.status, r.current_digest, r.new_version), ("update", index2, "2.11.9"))

    def test_platform_manifest_pin(self):
        repo = "blakeblackshear/frigate"
        amd64 = self.reg.add_image(repo)
        index = self.reg.add_index(repo, [(amd64, "amd64", None)])
        self.reg.tag(repo, "0.17.1-tensorrt", index)
        self.write(f'image = "ghcr.io/{repo}@{amd64}"; # 0.17.1-tensorrt, :0.17.1-tensorrt as of 2026-07-18\n')
        [r] = self.check()
        self.assertEqual((r.status, r.current_digest), ("up-to-date", index))
        self.assertIn("linux/amd64", r.note)

    def test_inherited_label_is_not_the_version(self):
        repo = "library/mongo"
        old = self.reg.add_image(repo)
        new = self.reg.add_image(repo, {images.VERSION_LABEL: "24.04"}, created="2026-11-11T00:00:00Z")
        index = self.reg.add_index(repo, [(new, "amd64", {images.VERSION_LABEL: "8.0.38"})])
        self.reg.tag(repo, "8.0", index)
        for t in ("7.0", "8.0", "8.2", "9.0", "latest"):
            self.reg.tags[repo].setdefault(t, old)
        self.write(f'image = "docker.io/library/mongo@{old}"; # 8.0.28, :8.0 as of 2026-08-06\n')
        [r] = self.check()
        self.assertEqual((r.status, r.new_version, r.newer_major), ("update", "8.0.38", "9.0"))

    def test_no_version_label(self):
        repo = "prom/prometheus"
        old, new = self.reg.add_image(repo), self.reg.add_image(repo, created="2026-11-05T00:00:00Z")
        self.reg.tag(repo, "latest", new)
        self.write(f'image = "docker.io/{repo}@{old}"; # :latest as of 2026-06-13\n')
        [r] = self.check()
        self.assertEqual((r.status, r.old_version, r.new_version), ("update", None, None))
        self.assertIn("no version label", r.note)

    def test_newer_major_from_paginated_tags(self):
        repo = "forgejo/forgejo"
        d = self.reg.add_image(repo)
        for t in ("16-rootless", "17-rootless", "18", "18-rootless", "19-rc1-rootless", "latest"):
            self.reg.tag(repo, t, d)
        self.write(f'image = "codeberg.org/{repo}@{d}"; # 17.0.1-rootless, :17-rootless as of 2026-11-09\n')
        [r] = self.check()
        self.assertEqual((r.status, r.newer_major, r.newer_in_major), ("up-to-date", "18-rootless", None))
        self.assertGreater(sum(e.startswith("GET /v2/forgejo/forgejo/tags/list") for e in self.reg.log), 1)

    def test_missing_tag_comment_is_unknown(self):
        d = self.reg.add_image("library/caddy")
        self.write(f'image = "docker.io/library/caddy@{d}";\n'
                   f'image = "docker.io/library/caddy@{d}"; # pinned by hand\n')
        rs = self.check()
        self.assertEqual([r.status for r in rs], ["unknown", "unknown"])
        self.assertFalse(self.reg.log, "an unknown pin asks no registry")

    def test_missing_tag_in_registry_is_error(self):
        d = self.reg.add_image("library/caddy")
        self.write(f'image = "docker.io/library/caddy@{d}"; # :gone as of 2026-01-01\n')
        [r] = self.check()
        self.assertEqual(r.status, "error")
        self.assertIn("404", r.note)

    def test_bump_line(self):
        old, new = "sha256:" + "a" * 64, "sha256:" + "b" * 64
        r = images.Result("x.nix", 1, "docker.io/vaultwarden/server", "latest", old, new,
                          "1.37.1", "1.37.5", "update")
        line = f'      image = "docker.io/vaultwarden/server@{old}"; # 1.37.1, :latest as of 2026-08-04\n'
        self.assertEqual(images.bump_line(line, r, "2026-11-18"),
                         f'      image = "docker.io/vaultwarden/server@{new}"; # 1.37.5, :latest as of 2026-11-18\n')
        # No version in the comment: none is added. No version label: the old stays.
        r.new_version = None
        self.assertEqual(images.bump_line(line, r, "2026-11-18"),
                         f'      image = "docker.io/vaultwarden/server@{new}"; # 1.37.1, :latest as of 2026-11-18\n')
        line = f'image = "docker.io/prom/prometheus@{old}"; # :latest as of 2026-06-13'
        self.assertEqual(images.bump_line(line, r, "2026-11-18"),
                         f'image = "docker.io/prom/prometheus@{new}"; # :latest as of 2026-11-18')
        # The build note follows the new image.
        r.built, r.revision = "2026-11-15", "1234567"
        line = f'image = "docker.io/nextcloud/all-in-one@{old}"; # :latest (built 2026-11-03, revision 97ef10c) as of 2026-11-12'
        self.assertEqual(images.bump_line(line, r, "2026-11-18"),
                         f'image = "docker.io/nextcloud/all-in-one@{new}"; # :latest (built 2026-11-15, revision 1234567) as of 2026-11-18')
        with self.assertRaises(ValueError):
            images.bump_line(line.replace(old, "sha256:" + "c" * 64), r)

    def test_image_bump_script(self):
        repo = "vaultwarden/server"
        old = self.reg.add_image(repo, {images.VERSION_LABEL: "1.37.1"})
        new = self.reg.add_image(repo, {images.VERSION_LABEL: "1.37.5"})
        same = self.reg.add_image("library/caddy")
        self.reg.tag(repo, "latest", new)
        self.reg.tag("library/caddy", "2", same)
        before = ("{ lib, ... }:\n# image = \"not a pin\"\n{\n"
                  f'  vaultwarden.image = "docker.io/{repo}@{old}"; # 1.37.1, :latest as of 2026-08-04\n'
                  f'  caddy.image = "docker.io/library/caddy@{same}"; # 2.11.2, :2 as of 2026-07-18\n'
                  "}\n")
        path = self.write(before)
        script = REPO / "skills/image-updates/image_bump.py"
        args = [sys.executable, "-I", str(script), str(self.root), "--json"]
        for h in self.hosts:
            args += ["--registry", f"{h}={self.url}"]
        out = subprocess.run(args, capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        bumped = json.loads(out.stdout)["bumped"]
        self.assertEqual([b["image"] for b in bumped], [f"docker.io/{repo}"])
        after = path.read_text().splitlines(keepends=True)
        expect = before.splitlines(keepends=True)
        self.assertEqual(after[3], expect[3].replace(old, new).replace("1.37.1", "1.37.5")
                         .replace("2026-08-04", re.search(r"as of (\S+)", after[3])[1]))
        del after[3], expect[3]
        self.assertEqual(after, expect, "image-bump changed another line")

    def test_check_script_json_and_exit(self):
        d = self.reg.add_image("library/caddy")
        self.write(f'image = "docker.io/library/caddy@{d}"; # :gone as of 2026-01-01\n')
        args = [sys.executable, "-I", str(REPO / "skills/image-updates/image_updates.py"), str(self.root),
                "--json", "--registry", f"docker.io={self.url}"]
        out = subprocess.run(args, capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, "read-only check exits 0 even on errors")
        self.assertEqual(json.loads(out.stdout)[0]["status"], "error")


if __name__ == "__main__":
    unittest.main()
