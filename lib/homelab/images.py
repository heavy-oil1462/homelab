"""Pinned container images: find the pins, ask the registries whether their
tag has moved, and rewrite the pins that have.

A pin is a line of a Nix file of the form

    image = "<name>@sha256:<digest>"; # <version>, :<tag> as of <date>

as DIRECTION.md asks for. The comment names the tag the digest came from and,
where known, the image's version. Checking is read-only: it asks each
registry for the tag's current digest over the OCI distribution API, with
the anonymous bearer-token flow that docker.io, ghcr.io, codeberg.org and
lscr.io use. Rewriting (bump_line, apply_bumps) is only for the image-bump
script. Standard library only.
"""
from __future__ import annotations

import datetime
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from typing import Any

INDEX_TYPES = (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
)
MANIFEST_TYPES = (
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
)
ACCEPT = ", ".join(INDEX_TYPES + MANIFEST_TYPES)

VERSION_LABEL = "org.opencontainers.image.version"
REVISION_LABEL = "org.opencontainers.image.revision"

# The fleet is x86_64-linux only (DIRECTION.md, "Not now"): versions are read
# from this platform's image, and a pin of this platform's manifest counts as
# a pin of the index that holds it.
PLATFORM = ("linux", "amd64")

# Registries whose API is not at https://<registry>/v2/.
API_HOSTS = {"docker.io": "https://registry-1.docker.io"}

SKIP_DIRS = {".git", "result", "node_modules", "__pycache__"}

PIN_RE = re.compile(
    r'(?P<lead>\bimage\s*=\s*")(?P<name>[^"@\s]+)@(?P<digest>sha256:[0-9a-f]{64})'
    r'(?P<close>"\s*;)(?P<trail>[ \t]*(?:#(?P<comment>.*))?)$'
)
# "17.0.1-rootless, :17-rootless as of 2026-11-09", ":stable as of 2026-06-13",
# ":latest (built 2026-11-03, revision 97ef10c) as of 2026-11-12".
COMMENT_RE = re.compile(
    r"^\s*(?:(?P<version>[^,:\s][^,\s]*),\s*)?:(?P<tag>[A-Za-z0-9_][A-Za-z0-9_.-]*)"
    r"(?P<extra>.*?)(?:\s+as of (?P<date>\d{4}-\d{2}-\d{2}))?\s*$"
)
BUILT_RE = re.compile(r"\(built (?P<date>\d{4}-\d{2}-\d{2}), revision (?P<rev>[0-9a-f]+)\)")
NUMERIC_RE = re.compile(r"^v?(?P<nums>\d+(?:\.\d+)*)(?P<suffix>.*)$")


class RegistryError(RuntimeError):
    """Raised when a registry cannot answer a request."""


@dataclass
class Pin:
    file: str
    line: int
    image: str
    digest: str
    comment: str | None
    tag: str | None
    version: str | None
    date: str | None


@dataclass
class Result:
    file: str
    line: int
    image: str
    tag: str | None
    pinned_digest: str
    current_digest: str | None = None
    old_version: str | None = None
    new_version: str | None = None
    status: str = "unknown"  # up-to-date, update, unknown or error
    note: str | None = None
    newer_major: str | None = None
    newer_in_major: str | None = None
    # For the rewrite: the config's build date and revision label.
    built: str | None = None
    revision: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


# Finding pins


def parse_comment(comment: str | None) -> tuple[str | None, str | None, str, str | None]:
    """Return (version, tag, extra, date) of a pin's comment; tag is None
    when the comment names none."""
    if comment is None:
        return None, None, "", None
    m = COMMENT_RE.match(comment)
    if not m:
        return None, None, "", None
    return m["version"], m["tag"], m["extra"], m["date"]


def parse_line(line: str) -> tuple[str, str, str | None] | None:
    """Return (image, digest, comment) of a pin line, or None. A pin that is
    commented out is no pin."""
    if line.lstrip().startswith("#"):
        return None
    m = PIN_RE.search(line.rstrip("\n"))
    if not m:
        return None
    return m["name"], m["digest"], m["comment"]


def find_pins(root: str = ".") -> list[Pin]:
    """Every pin in the *.nix files under root, in file and line order."""
    pins = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for fn in sorted(filenames):
            if not fn.endswith(".nix"):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root)
            with open(path, encoding="utf-8") as f:
                for no, line in enumerate(f, 1):
                    parsed = parse_line(line)
                    if not parsed:
                        continue
                    image, digest, comment = parsed
                    version, tag, _, date = parse_comment(comment)
                    pins.append(Pin(rel, no, image, digest, comment and comment.strip(), tag, version, date))
    return pins


def split_name(image: str) -> tuple[str, str]:
    """Split an image name into (registry, repository), as podman does:
    the first component is a registry when it has a dot or a port."""
    first, _, rest = image.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        registry, repo = first, rest
    else:
        registry, repo = "docker.io", image
    if registry == "docker.io" and "/" not in repo:
        repo = "library/" + repo
    return registry, repo


# Registry client


class _KeepMethod(urllib.request.HTTPRedirectHandler):
    """Follow redirects with HEAD kept as HEAD. Authorization is added as an
    unredirected header, so it is never sent on to a blob store."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and req.get_method() == "HEAD":
            new.method = "HEAD"
        return new


def parse_registries(values: list[str]) -> dict[str, str]:
    """{name: url} from NAME=URL arguments."""
    hosts = {}
    for v in values:
        name, sep, url = v.partition("=")
        if not sep or not name or not url:
            raise SystemExit(f"error: a registry is NAME=URL, not {v!r}")
        hosts[name] = url
    return hosts


class RegistryClient:
    """Read-only client for the OCI distribution API of several registries.

    api_hosts maps a registry name (docker.io) to its API base URL; the
    default is https://<registry>. Tokens are fetched anonymously as each
    registry's 401 asks, and kept per scope.
    """

    def __init__(self, api_hosts: dict[str, str] | None = None, timeout: float = 30):
        self.api_hosts = dict(API_HOSTS)
        self.api_hosts.update(api_hosts or {})
        self.timeout = timeout
        self.tokens: dict[tuple[str, str], str] = {}
        self.opener = urllib.request.build_opener(_KeepMethod)

    def base(self, registry: str) -> str:
        return self.api_hosts.get(registry, "https://" + registry).rstrip("/")

    def _open(self, url: str, method: str, accept: str | None, token: str | None):
        req = urllib.request.Request(url, method=method)
        if accept:
            req.add_header("Accept", accept)
        if token:
            req.add_unredirected_header("Authorization", "Bearer " + token)
        return self.opener.open(req, timeout=self.timeout)

    def request(self, registry: str, repo: str, path: str, method: str = "GET",
                accept: str | None = None):
        """Make a request, fetching a token if the registry asks for one.
        Returns (headers, body); body is b"" for HEAD."""
        url = self.base(registry) + path
        key = (registry, repo)
        try:
            for attempt in range(2):
                try:
                    with self._open(url, method, accept, self.tokens.get(key)) as resp:
                        return resp.headers, resp.read() if method != "HEAD" else b""
                except urllib.error.HTTPError as exc:
                    exc.close()
                    if exc.code != 401 or attempt:
                        raise
                    self.tokens[key] = self._token(exc.headers.get("WWW-Authenticate", ""), repo)
        except urllib.error.HTTPError as exc:
            raise RegistryError(f"{method} {url}: HTTP {exc.code} {exc.reason}") from exc
        except (urllib.error.URLError, OSError) as exc:
            raise RegistryError(f"{method} {url}: {getattr(exc, 'reason', exc)}") from exc
        raise AssertionError("unreachable")

    def _token(self, challenge: str, repo: str) -> str:
        scheme, _, params = challenge.partition(" ")
        if scheme.lower() != "bearer":
            raise RegistryError(f"unsupported authentication challenge: {challenge!r}")
        fields = dict(re.findall(r'(\w+)="([^"]*)"', params))
        if "realm" not in fields:
            raise RegistryError(f"bearer challenge without realm: {challenge!r}")
        query = {"scope": fields.get("scope") or f"repository:{repo}:pull"}
        if fields.get("service"):
            query["service"] = fields["service"]
        url = fields["realm"] + "?" + urllib.parse.urlencode(query)
        try:
            with self._open(url, "GET", "application/json", None) as resp:
                payload = json.load(resp)
        except (urllib.error.URLError, OSError, ValueError) as exc:
            raise RegistryError(f"token from {fields['realm']}: {exc}") from exc
        token = payload.get("token") or payload.get("access_token")
        if not token:
            raise RegistryError(f"token from {fields['realm']}: no token in answer")
        return token

    def head_digest(self, registry: str, repo: str, ref: str) -> str:
        """The digest a tag points at now, from a HEAD of its manifest."""
        headers, _ = self.request(registry, repo, f"/v2/{repo}/manifests/{ref}", "HEAD", ACCEPT)
        digest = headers.get("Docker-Content-Digest")
        if not digest:
            # Without the header a GET and a hash of the body would do; every
            # registry we use sends it.
            raise RegistryError(f"{registry}/{repo}:{ref}: no Docker-Content-Digest header")
        return digest

    def manifest(self, registry: str, repo: str, ref: str) -> dict[str, Any]:
        _, body = self.request(registry, repo, f"/v2/{repo}/manifests/{ref}", "GET", ACCEPT)
        return json.loads(body)

    def blob(self, registry: str, repo: str, digest: str) -> dict[str, Any]:
        _, body = self.request(registry, repo, f"/v2/{repo}/blobs/{digest}", "GET")
        return json.loads(body)

    def tags(self, registry: str, repo: str) -> list[str]:
        """Every tag of a repository, following the Link header's pages."""
        path = f"/v2/{repo}/tags/list?n=1000"
        tags: list[str] = []
        for _ in range(100):
            headers, body = self.request(registry, repo, path, "GET", "application/json")
            tags += json.loads(body).get("tags") or []
            m = re.search(r'<([^>]+)>\s*;\s*rel="?next"?', headers.get("Link", ""))
            if not m:
                return tags
            nxt = urllib.parse.urlsplit(m[1])
            path = nxt.path + ("?" + nxt.query if nxt.query else "")
        return tags


# Checking


def _platform_entry(index: dict[str, Any]) -> dict[str, Any] | None:
    for entry in index.get("manifests", []):
        p = entry.get("platform") or {}
        if (p.get("os"), p.get("architecture")) == PLATFORM:
            return entry
    return None


def version_key(tag: str) -> tuple[tuple[int, ...], str] | None:
    """(numbers, suffix) of a tag that starts with a version, else None."""
    m = NUMERIC_RE.match(tag)
    if not m:
        return None
    return tuple(int(n) for n in m["nums"].split(".")), m["suffix"]


def _major(nums: tuple[int, ...]) -> tuple[int, ...]:
    # A 0.x release is its own major, as semver has it.
    return nums[:2] if nums[0] == 0 and len(nums) > 1 else nums[:1]


def newer_tags(tag: str, tags: list[str]) -> tuple[str | None, str | None]:
    """(newer_major, newer_in_major) for a tag that names a version.

    Candidates have the tag's shape: as many numbers and the same suffix, so
    17-rootless is compared with 18-rootless, not with 18.0.1 or 18-rc1.
    newer_major is the highest in a later major. newer_in_major is the
    highest later one in the same major, reported only for a tag of three or
    more numbers, which names one release and so never moves.
    """
    key = version_key(tag)
    if key is None:
        return None, None
    nums, suffix = key
    later = []
    for t in tags:
        k = version_key(t)
        if k and k[1] == suffix and len(k[0]) == len(nums) and k[0] > nums:
            later.append((k[0], t))
    major = max((x for x in later if _major(x[0]) > _major(nums)), default=None)
    within = max((x for x in later if _major(x[0]) == _major(nums)), default=None)
    return (major and major[1],
            within[1] if within and len(nums) >= 3 else None)


def new_version(old: str | None, label: str | None) -> str | None:
    """The version for the comment from the image's version label, in the
    old version's form: 17.0.2 becomes 17.0.2-rootless after
    17.0.1-rootless, and 2.11.9-alpine becomes 2.11.9 after 2.11.2."""
    if not label:
        return None
    label = label.strip()
    if label.startswith("v") and label[1:2].isdigit():
        label = label[1:]
    if old is None:
        return label
    lo, ol = NUMERIC_RE.match(label), NUMERIC_RE.match(old)
    if lo and ol:
        return lo["nums"] + ol["suffix"]
    return label


def check_pin(pin: Pin, client: RegistryClient, majors: bool = True) -> Result:
    r = Result(pin.file, pin.line, pin.image, pin.tag, pin.digest, old_version=pin.version)
    if pin.tag is None:
        r.status = "unknown"
        r.note = "the comment names no tag (\":<tag> as of <date>\")"
        return r
    registry, repo = split_name(pin.image)
    try:
        current = client.head_digest(registry, repo, pin.tag)
        r.current_digest = current
        index = None
        if current == pin.digest:
            r.status = "up-to-date"
        else:
            top = client.manifest(registry, repo, current)
            if top.get("mediaType") in INDEX_TYPES or "manifests" in top:
                index = top
                entry = _platform_entry(top)
                if entry and entry.get("digest") == pin.digest:
                    r.status = "up-to-date"
                    r.note = "pinned to the index's linux/amd64 manifest"
            if r.status != "up-to-date":
                r.status = "update"
                _read_version(r, client, registry, repo, current, top)
        if r.status == "up-to-date":
            r.new_version = pin.version
        if majors and version_key(pin.tag):
            r.newer_major, r.newer_in_major = newer_tags(pin.tag, client.tags(registry, repo))
    except RegistryError as exc:
        r.status = "error"
        r.note = str(exc)
    return r


def _read_version(r: Result, client: RegistryClient, registry: str, repo: str,
                  digest: str, top: dict[str, Any]) -> None:
    """Fill in new_version (and built, revision) from the config of the
    image's linux/amd64 manifest."""
    annotations: dict[str, str] = {}
    manifest = top
    if "manifests" in top:
        entry = _platform_entry(top)
        if entry is None:
            r.new_version = r.old_version
            r.note = "no linux/amd64 image in the index; version left as is"
            return
        annotations = entry.get("annotations") or {}
        manifest = client.manifest(registry, repo, entry["digest"])
    config = client.blob(registry, repo, manifest["config"]["digest"])
    labels = (config.get("config") or {}).get("Labels") or {}
    if config.get("created"):
        r.built = config["created"][:10]
    revision = annotations.get(REVISION_LABEL) or labels.get(REVISION_LABEL)
    if revision:
        r.revision = revision[:7]
    # The config's label first, as the image's own. A label inherited from
    # the base image (mongo's says 24.04, Ubuntu's) does not match a tag that
    # names a version, so the index's annotation, which official images
    # carry, is tried next.
    found = [v for v in (labels.get(VERSION_LABEL), annotations.get(VERSION_LABEL)) if v]
    versions = [new_version(r.old_version, v) for v in found]
    fitting = [v for v in versions if v and _fits_tag(v, r.tag)]
    if fitting:
        r.new_version = fitting[0]
    else:
        r.new_version = r.old_version
        r.note = ("the image has no version label; version left as is" if not found else
                  f"version label {found[0]} does not match the tag; version left as is")


def _fits_tag(version: str, tag: str | None) -> bool:
    """Whether a version can be the tag's: 8.0.28 fits 8.0, 24.04 does not.
    Any version fits a tag without numbers, such as latest."""
    t, v = version_key(tag or ""), version_key(version)
    if t is None:
        return True
    return v is not None and v[0][: len(t[0])] == t[0]


def check(root: str = ".", client: RegistryClient | None = None, majors: bool = True) -> list[Result]:
    """Check every pin under root. Read-only."""
    client = client or RegistryClient()
    return [check_pin(p, client, majors) for p in find_pins(root)]


# Rewriting, for image-bump only


def bump_line(line: str, result: Result, today: str | None = None) -> str:
    """The pin line with the new digest and the comment's version and date.
    Raises ValueError if the line is not the result's pin."""
    m = PIN_RE.search(line.rstrip("\n"))
    if not m or m["digest"] != result.pinned_digest or not result.current_digest:
        raise ValueError(f"{result.file}:{result.line} is not the pin of {result.pinned_digest}")
    today = today or datetime.date.today().isoformat()
    version, tag, extra, _ = parse_comment(m["comment"])
    if tag is None:
        raise ValueError(f"{result.file}:{result.line}: the comment names no tag")
    if version is not None and result.new_version:
        version = result.new_version
    if result.built and result.revision:
        extra = BUILT_RE.sub(f"(built {result.built}, revision {result.revision})", extra)
    comment = (f"{version}, " if version else "") + f":{tag}{extra} as of {today}"
    space = re.match(r"[ \t]*", m["trail"])[0] or " "
    newline = "\n" if line.endswith("\n") else ""
    return (line[: m.start("digest")] + result.current_digest + line[m.end("digest"): m.end("close")]
            + space + "# " + comment + newline)


def apply_bumps(root: str, results: list[Result], today: str | None = None) -> list[Result]:
    """Rewrite the pins whose status is update, and return them. Every other
    line of each file is left byte for byte."""
    done: list[Result] = []
    by_file: dict[str, list[Result]] = {}
    for r in results:
        if r.status == "update":
            by_file.setdefault(r.file, []).append(r)
    # Every line is rewritten before any file is, so a pin that moved since
    # the check (ValueError) leaves all files as they were.
    rewritten = {}
    for rel, rs in by_file.items():
        path = os.path.join(root, rel)
        with open(path, encoding="utf-8", newline="") as f:
            lines = f.readlines()
        for r in rs:
            if not 0 < r.line <= len(lines):
                raise ValueError(f"{rel}:{r.line} is past the end of the file")
            lines[r.line - 1] = bump_line(lines[r.line - 1], r, today)
            done.append(r)
        rewritten[path] = lines
    for path, lines in rewritten.items():
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.writelines(lines)
    return done
