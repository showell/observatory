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
- **Its lines** go to `polls.txt` in its data and to the host's console (on
  metal, the kept log and `/admin/log`'s). **Its page,** `/`, is the newest 100
  lines and a count of each outcome since the start. It is private: no
  Caddy block; reach it through prod, or with a Shale script.

## Its conf

`observatory.conf` in its data folder, a setting a line:

    target = 10.100.0.3:80 /version
    interval_s = 60
    connect_ms = 1000
    idle_ms = 3000
    total_ms = 10000

The target has no default: without one it refuses to start. The rest default
to what is shown. Its fetch is on-link only on metal: the target must be on the
machine's own network.

## Building and testing, fastest first

All need the sibling checkouts beside this one: zig-webbox (always),
zig-metal-unikernel (for `metal`), and for the pair test metal-vmm and
dog-park too.

| command | what it proves | time |
|---|---|---|
| `zig build test` | the schedule (due, late, one at a time, a missed poll skipped), the conf, the lines, `/version` read; then the poll on Linux against a server on 127.0.0.1 that answers twice (a restart between) and goes silent | about 2 s, half of it the build |
| `zig build metal` | observatory.elf builds | about 25 s |
| `tools/pair.sh` | observatory.elf watching dogpark.elf on metal-vmm, ten minutes of their time: ten polls ok with Dog Park's own commit; then Dog Park silent from 180 s to 300 s, polls 4 and 5 `no_arp` and the rest `ok` | about 5 s, after `zig build metal` here and in ../dog-park |

`zig build run` serves it on Linux (`OBSERVATORY_CONFIG` names a config whose
`data_dir` holds the conf; from the checkout, `./data`), its page on
localhost:9104.

## Which version is running

This README names none. The commit a machine runs is the image it was built
from; `git log -1 --format=%h` here says what a build from this checkout
would be.

## Not yet

A droplet: the cheapest one, on the private network beside Dog Park, deployed
as zig-metal-unikernel's `DEPLOY.md` deploys an application. That is Steve's
step.
