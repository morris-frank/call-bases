# call-bases

A one-time, real-time-synced web art piece: a live stream of a genome iterating
over its base-pairs. The whole genome streams **exactly once** over the project's
runtime, and **every client sees the same current state** because that state is a
pure function of wall-clock time.

```
current_index = floor((now - start_epoch) * rate)   clamped to [0, N]
```

A client joining on day 100 sees day-100 content, not the beginning. The server
only ever releases data up to `current_index`, at real-time pace - that single
clamp is the entire enforcement of the hard constraint:

> The underlying data cannot be retrieved all at once. The only way to obtain the
> full genome is to listen to the server for the complete runtime and save it -
> which is the intended nature of the piece.

## Architecture

Two halves, deliberately asymmetric in weight:

- **scaffold/** - heavy, one-time, offline. Turns a single CRAM into compact,
  offset-addressable artifacts.
- **server/** + **web/** - a trivial, dependency-free, long-lived service that
  just reads byte offsets and pushes them on a timer. No samtools, no CRAM at
  runtime.

```
CRAM + .crai + reference.fa
        |  scaffold/build.sh   (samtools consensus, optional mpileup)
        v
consensus.bin  pileup.bin/.idx (optional)  meta.json
        |  server/server.js    (positioned reads, f(now) gate)
        v   SSE: bases up to f(now)
   web/index.html  --- GET /pileup?pos=P (P <= current_index) --->  server
```

## Artifacts

| file | what |
|---|---|
| `consensus.bin` | 1 byte per reference position (ASCII base), all contigs concatenated in reference order. ~3.2 GB for a human genome. |
| `meta.json` | `n` (total length), contig offset table for `chrN:pos` readouts, source info, default pacing. |
| `pileup.bin` + `pileup.idx` | *optional.* Per-position read-base columns (depth-capped) addressed by a `uint64` offset index. Tens of GB at 30x. |

## 1. Build artifacts (offline)

Requires `samtools` (>= 1.16 for `samtools consensus`) and `python3`. Run on a
beefy machine - consensus calling over a 60 GB CRAM is the slow part.

```bash
scaffold/build.sh \
  --cram sample.cram \
  --ref  reference.fa \
  --out  artifacts \
  --start-epoch 2026-07-01T00:00:00Z \
  --runtime 31536000          # ~1 year; or use --rate 101 (bases/sec)

# add the optional hover pile-up (large on disk):
scaffold/build.sh ... --pileup --max-depth 64
```

Inputs: the CRAM, its `.crai` (auto-created if missing), and the reference FASTA
(its `.fai` is auto-created). The reference is mandatory - a CRAM cannot be
decoded without it.

## 2. Run the server

Node only, zero dependencies, no build step:

```bash
cp server/config.example.json server/config.json   # edit pacing
node server/server.js
# or via env:
CALLBASES_ARTIFACTS_DIR=./artifacts CALLBASES_START_EPOCH=2026-07-01T00:00:00Z \
CALLBASES_RUNTIME_SECONDS=31536000 node server/server.js
```

Open <http://localhost:8080>.

### Pacing config

Set `startEpoch` plus **exactly one** of `rate` (bases/sec) or `runtimeSeconds`
(the other is derived from `N`). Config precedence: defaults < `config.json` <
environment. At human-genome scale (~3.2 Gb): ~101 b/s is roughly a year,
~1235 b/s is roughly 30 days. (At those rates the UI is a flowing "river" of
bases rather than a one-letter tick.)

### Endpoints

- `GET /` - the UI (`web/index.html`).
- `GET /stream` - SSE. On connect: `hello` with `{index, n, rate, startEpoch,
  pileup, contigs, tail}` (a small fixed tail for visual continuity, **not** the
  backlog). Then `tick` messages with only the bases newly revealed since the
  last tick, and finally `complete` at `N`.
- `GET /pileup?pos=P` - one position's read-base column, **only if
  `P <= current_index`** (else 403); 404 when the pile-up module is disabled.

## 3. Deploy (canonical infra)

One small VPS, sized for the artifact disk (~5 GB consensus-only, ~60-80 GB with
pile-up), running the server under `systemd` for the whole project, behind Caddy
for automatic HTTPS and SSE-friendly proxying.

```bash
# on the VPS, once:
sudo mkdir -p /opt/call-bases
sudo cp infra/call-bases.service /etc/systemd/system/
sudo cp infra/call-bases.env.example /opt/call-bases/call-bases.env   # edit pacing
CALLBASES_DOMAIN=stream.example.org caddy run --config infra/Caddyfile  # or as a service

# from your machine:
infra/deploy.sh user@vps-host artifacts
```

The server is stateless: a restart (or reboot) resumes at the correct `f(now)`
index automatically.

## The hard constraint, concretely

- SSE only ever emits bases with index `<= current_index`, paced by a real-time timer.
- The join `tail` is a small fixed window, so a late joiner near the end cannot
  grab the whole backlog at once.
- `/pileup` is clamped to `<= current_index` - the future is never served.
- No endpoint returns the artifact files; they are server-side only.

## Layout

```
scaffold/   build.sh, pack_consensus.py, pack_pileup.py   (offline preprocessing)
server/     server.js, config.example.json                (runtime)
web/        index.html                                    (vanilla UI, no bundler)
infra/      Caddyfile, call-bases.service, deploy.sh, *.env.example
```
