"""Shared homelab toolkit used by the Claude Code skills under .claude/skills.

Modules here are backend/helper code, not entry points. Skills add this
directory to sys.path and import from here, so the same Prometheus client
and helpers are reused across every skill (Home Assistant today, per-host
metrics and generic NixOS helpers later).
"""
