"""Tests of lib/homelab/logs.py: the LogQL it builds, and how it merges the
labelled streams with those written before the logging agent labelled them.
A stub stands in for the Loki client, so nothing is reached over the network.

Run from the repository root:  python3 -m unittest discover -s tests -p 'test_*.py'
"""
from __future__ import annotations

import json
import pathlib
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "lib"))
from homelab import logs  # noqa: E402


def line(ns: int, **fields: str) -> list[str]:
    return [str(ns), json.dumps(fields)]


class StubLoki:
    """Answers each query with the result given for it; records the queries."""

    def __init__(self, results: dict[str, list]):
        self.results = results
        self.queries: list[str] = []

    def query_range(self, query, since_seconds=3600, limit=200):
        self.queries.append(query)
        return {"result": self.results.get(query, [])}

    def query(self, query):
        self.queries.append(query)
        return {"result": self.results.get(query, [])}


class BuildQueries(unittest.TestCase):
    def test_no_unit_is_one_query_as_before(self):
        self.assertEqual(
            logs.build_queries(host="h", service="caddy"),
            [
                '{job="systemd-journal", host="h"} | json'
                ' | _SYSTEMD_UNIT=~"(?i).*caddy.*" or SYSLOG_IDENTIFIER=~"(?i).*caddy.*"'
                ' or CONTAINER_NAME=~"(?i).*caddy.*"'
            ],
        )

    def test_unit_selects_by_label_and_falls_back_to_json(self):
        self.assertEqual(
            logs.build_queries(host="h", unit="sshd.service", priority=3),
            [
                '{job="systemd-journal", host="h", unit="sshd.service"} | json | PRIORITY <= 3',
                '{job="systemd-journal", host="h", unit=""} | json'
                ' | _SYSTEMD_UNIT="sshd.service" | PRIORITY <= 3',
            ],
        )

    def test_container_falls_back_on_streams_without_unit(self):
        # Container lines always have a unit, so the old streams are those
        # without one; container="" would also take every host service.
        self.assertEqual(
            logs.build_queries(container="vaka", grep="err"),
            [
                '{job="systemd-journal", container="vaka"} | json | MESSAGE=~"(?i)err"',
                '{job="systemd-journal", unit=""} | json | CONTAINER_NAME="vaka" | MESSAGE=~"(?i)err"',
            ],
        )

    def test_values_are_escaped(self):
        labelled, unlabelled = logs.build_queries(unit='a"b\\c')
        self.assertIn('unit="a\\"b\\\\c"', labelled)
        self.assertIn('_SYSTEMD_UNIT="a\\"b\\\\c"', unlabelled)


class FetchLogs(unittest.TestCase):
    def test_merges_both_queries_in_order_and_keeps_the_latest(self):
        labelled, unlabelled = logs.build_queries(container="vaka")
        stub = StubLoki({
            labelled: [{
                "stream": {"host": "h", "unit": "podman-vaka.service", "container": "vaka"},
                "values": [
                    line(30, _SYSTEMD_UNIT="podman-vaka.service", CONTAINER_NAME="vaka", MESSAGE="new", PRIORITY="6"),
                    line(20, _SYSTEMD_UNIT="podman-vaka.service", CONTAINER_NAME="vaka", MESSAGE="newer than old", PRIORITY="6"),
                ],
            }],
            unlabelled: [{
                "stream": {"host": "h"},
                "values": [
                    line(10, _SYSTEMD_UNIT="podman-vaka.service", CONTAINER_NAME="vaka", MESSAGE="old", PRIORITY="3"),
                    line(5, _SYSTEMD_UNIT="podman-vaka.service", CONTAINER_NAME="vaka", MESSAGE="oldest", PRIORITY="3"),
                ],
            }],
        })
        rows = logs.fetch_logs(container="vaka", limit=3, client=stub)
        self.assertEqual(stub.queries, [labelled, unlabelled])
        self.assertEqual([r["message"] for r in rows], ["old", "newer than old", "new"])
        self.assertEqual({r["unit"] for r in rows}, {"podman-vaka.service"})
        self.assertEqual(rows[0]["priority"], 3)


class ListServices(unittest.TestCase):
    def test_adds_labelled_and_unlabelled_counts(self):
        labelled = 'sum by (unit) (count_over_time({job="systemd-journal", host="h", unit!=""} [3600s]))'
        unlabelled = (
            'sum by (_SYSTEMD_UNIT) (count_over_time('
            '{job="systemd-journal", host="h", unit=""} | json [3600s]))'
        )
        stub = StubLoki({
            labelled: [
                {"metric": {"unit": "sshd.service"}, "value": [0, "5"]},
                {"metric": {"unit": "podman-vaka.service"}, "value": [0, "2"]},
            ],
            unlabelled: [
                {"metric": {"_SYSTEMD_UNIT": "podman-vaka.service"}, "value": [0, "7"]},
                {"metric": {}, "value": [0, "40"]},
            ],
        })
        rows = logs.list_services(host="h", client=stub)
        self.assertEqual(stub.queries, [labelled, unlabelled])
        self.assertEqual(rows, [
            {"unit": "podman-vaka.service", "count": 9},
            {"unit": "sshd.service", "count": 5},
        ])


if __name__ == "__main__":
    unittest.main()
