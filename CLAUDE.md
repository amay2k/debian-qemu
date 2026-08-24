# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENT.md

AGENT.md above is this repo's canonical source of truth (build/test commands, architecture, conventions, decision log). Keep it updated when behavior or architecture changes — see its own "Required workflow" notes.

## Claude-specific operational notes

- `make init` and `make install` prompt interactively (y/N to overwrite `disk.img`) — this will hang if run non-interactively; pipe input (e.g. `yes | make init`) or warn the user before running these.
- `disk.img` and `efi-vars.fd` are listed in `.gitignore` but are intentionally tracked in git as checked-in VM state (~131MB). This is known and expected — do not untrack or "clean up" them unprompted.
- `make start` and `make console` spawn a real, long-lived background QEMU process and Unix domain sockets (`qemu.pid`, `qemu.mon`, `qemu.console`) in the repo root. Be aware of this side effect when testing changes in a sandboxed shell — use `make stop`/`make kill` to clean up afterward.
