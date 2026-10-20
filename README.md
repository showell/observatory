# The Observatory

A small machine that watches another. Every `interval_s` it wakes, asks one
server for its `/version`, writes one line about what it heard, and sleeps:

    2026-10-17T09:14:00Z ok 200 commit fb3253d started 1789000000000 accounts 3 turns 2 in 41 ms
    2026-10-17T09:15:00Z connect_deadline in 1000 ms
    2026-10-17T09:16:00Z ok 200 commit fb3253d started 1789000960000 (restarted) accounts 0 turns 0 in 38 ms

Version one watches Dog Park (dogpark.lynrummy.com's machine, on the private
network); lynrummy.com's `/version` reads the same way and can be a second
target later. Its plan and the reasons for each choice are the essay
[`notes/the-observatory-v1.md`](https://github.com/showell/essay-repl-server/blob/master/notes/the-observatory-v1.md)
and zig-metal-unikernel's `docs/designs/DESIGN-sleep.md`; its queue item is
metal-vmm's QUEUE 228.

## What it is made of

- **An application** on [zig-webbox](https://github.com/showell/zig-webbox)'s
  `Site` (`src/app.zig`), whose `between` keeps the schedule
  (`src/schedule.zig`) and starts each poll through its host's fetch (webbox's
  `host_fetch`). Its answer to `between` is when it next needs to run, and the
  host sleeps until then.
- **Two hosts, the same app:** Linux (`src/main.zig`, webbox's Linux host) and
  bare metal ([zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)'s
  kernel, through its `addAppKernel`: `zig build metal`). The outcome words on
  a line are the host's fetch's, the same on both.
- **Its lines** go to its `data/polls.txt` and to the host's console (on
  metal, the kept log). `data/polls.txt` grows about 190 KB a day at 60 s
  (estimated, not measured), and nothing trims it. **Its page,** `/`, is the
  newest 100 lines and a count of each outcome since the start.
- **The page has no login.** It says nothing secret (the target, the
  outcomes, the commits), but it is meant to be private. On Linux, bind it to
  127.0.0.1 (`OBSERVATORY_BIND=127.0.0.1`) unless it is meant to be seen: with
  `OBSERVATORY_BIND` unset it listens on every interface.

## Its conf

`observatory.conf` in its data folder, a setting a line (`#` starts a
comment line):

    target = <address>:<port> /version
    interval_s = 60
    connect_ms = 1000
    idle_ms = 3000
    total_ms = 10000

The target is an IPv4 address, a port and a path. It has no default: without
one it refuses to start. The rest default to what is shown. It also refuses to
start on:
- a line that is not `key = value`, or an unknown key;
- an `interval_s` or a deadline of 0, or one that is not a number;
- `connect_ms` or `idle_ms` above `total_ms`, or `total_ms` at or above the
  interval (a poll must end before the next is due).

`observatory.conf.example` targets a Dog Park on the same machine
(`zig build play` in ../dog-park, port 9103). Its fetch is on-link only on
metal: the target must be on the machine's own network.

### Its lines

`<UTC time> <outcome>`, then:
- for `ok`: the status, then `commit C started S` (and `(restarted)` when S
  differs from the last poll's), `accounts N` and `turns N` when the server
  sends them; or `not a /version` when the body is not one, or its commit
  could forge or split a line;
- for any other outcome: the status, when the server sent one;
- always `in N ms`, and `(late N ms)` when the poll started late.

The outcome words are zig-webbox's `host_fetch.Outcome` (`ok`, `refused`,
`connect_deadline`, `no_arp`, …); `src/app.zig`'s `formatLine` writes the line.

### Its environment (Linux)

| variable | default |
|---|---|
| `OBSERVATORY_PORT` | 9104 |
| `OBSERVATORY_BIND` | every interface |
| `OBSERVATORY_CONFIG` | none: its data is `./data` |
| `OBSERVATORY_TRUSTED_PROXY` | 127.0.0.1 |
| `OBSERVATORY_KEEPALIVE_MS` | webbox's default (a quiet stream's ping window, for tests) |

A config that names a `data_dir` and no `auth_dir` uses `~/ObservatoryAuth`
(`src/main.zig`).

## Building and testing, fastest first

Every build needs the sibling checkouts beside this one: `../zig-webbox`,
`../zig-metal-unikernel`, and the kernel's own two, `../zig-coverage-sdk` and
`../shale`. Zig runs a path dependency's build at every configure, lazy or
not, so even `zig build test` needs all four. The pair test also needs
`../metal-vmm` (built) and `../dog-park` (with `zig build metal` run, which
needs the Roc dog-park's `roc/roc-version` pins).

The times were measured warm on the box, and nothing checks them: a cold
cache or another machine differs.

| command | what it proves | time |
|---|---|---|
| `zig build test` | the schedule (due, late, one at a time, a missed poll skipped), the conf (contradictory deadlines refused), the lines (a commit that would forge or split a line refused), `/version` read; then the poll on Linux against a server on 127.0.0.1 that answers twice (a restart between) and goes silent, each line's time the real one; and a poll its host would not start | about 1.5 s, most of it the build |
| `zig build metal` | observatory.elf builds | about 25 s |
| `tools/pair.sh` | observatory.elf (it builds it) watching dogpark.elf on metal-vmm, ten minutes of their time: ten polls ok with Dog Park's own commit and one start, no `(restarted)` (a stale dogpark.elf fails, saying so); then Dog Park silent from 180 s to 300 s, polls 4 and 5 `no_arp` and the rest `ok` | about 5 s for the runs, as it prints; its own `zig build metal` comes first and is not in that time |

`tools/pair.sh` is a bash script: run it as itself, not with `sh`. It needs `/dev/kvm`, `sgdisk`, `mkfs.vfat`, `mcopy` and `mmd`,
and says `NOT RUN` (exit 2) without one. It writes to
`~/build/observatory/pair` (`OUT` names another place).

`zig build run` serves it on Linux, its page on port 9104. From the
checkout its data is `./data` (ignored by git):

    mkdir -p data && cp observatory.conf.example data/observatory.conf
    OBSERVATORY_BIND=127.0.0.1 zig build run

(`OBSERVATORY_CONFIG` names a config file whose `data_dir` is elsewhere.)

## Which version is running

This README names none. The commit a machine runs is the image it was built
from; `git log -1 --format=%h` here says what a build from this checkout
would be. The Observatory has no `/version` of its own, so a running one
cannot be asked which build it is.

## Where it runs

**On prod, as a Linux program** (Steve, 2026-10-17): Dog Park's droplet is on
prod's private network, which the dev box is not on, and the Observatory's
fetch is plain HTTP to an address. In prod's `~/observatory/`:
- `observatory`, this repo's `zig build -Doptimize=ReleaseSafe` (statically
  linked, so built on the dev box and copied);
- `host.conf` (`data_dir = ~/observatory/data`, `auth_dir = ~/observatory/auth`);
- `data/observatory.conf`, its target Dog Park's private address, port 80;
- `data/polls.txt`, its lines; `log`; `PID`.

**Its findings, summed up:** `tools/findings.shale`, copied to prod's
`~/observatory/findings.shale` and run there by Shale (prod's
`~/.local/bin/shale`): `cd ~/observatory/data && shale ../findings.shale`.
It counts the outcomes, lists every change of commit or start, every gap
over 90 s between polls, how fast the answers came, and the most accounts
and turns.

Its page binds to 127.0.0.1, so it is read on prod:
`ssh <prod> curl -s http://127.0.0.1:9104/`. It runs detached, with no service
around it: **a reboot of prod stops it**, and nothing starts it again. To
replace the binary or start it, on prod:

    kill $(cat ~/observatory/PID)        # if it runs
    cd ~/observatory && OBSERVATORY_BIND=127.0.0.1 OBSERVATORY_CONFIG=$HOME/observatory/host.conf \
        setsid nohup ./observatory >> log 2>&1 < /dev/null &
    ss -ltnp | grep ':9104 '              # its PID, into PID

## Not yet

A droplet of its own. The repo has no droplet folder, conf or image script yet. The
intended setup: the cheapest droplet, on the private network beside Dog Park,
deployed as zig-metal-unikernel's `DEPLOY.md` deploys an application (Steve's
step).
- It would serve the private network only (`card = private` in its
  zig-metal-unikernel.conf), with no Caddy block, reached from prod
  (`curl -s http://<its private address>/`).
- It would keep no volume, so a release would start `data/polls.txt` over.
- Its target would be Dog Park's private address, port 80.
