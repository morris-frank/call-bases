# call-bases

a genome, unfurling itself exactly once. base by base.

at human scale:

* ~101 b/s → ~1 year
* ~1235 b/s → ~30 days

## build

requires `samtools` (>= 1.16 for `samtools consensus`) and `python3`.

```bash
scaffold/build.sh \
  --cram sample.cram \
  --ref  reference.fa \
  --out  artifacts \
  --start-epoch 2026-07-01T00:00:00Z \
  --runtime 31536000          # ~1 year; or use --rate 101 (bases/sec)

# add the optional pileup (large on disk):
scaffold/build.sh ... --pileup --max-depth 64
```

inputs: cram, `.crai` (else auto-created), and the reference fasta
(else auto-created). the reference is mandatory; a cram cannot be decoded
without it.

## run

node only, zero dependencies.

```bash
cp server/config.example.json server/config.json   # edit pacing
node server/server.js
# or via env:
CALLBASES_ARTIFACTS_DIR=./artifacts CALLBASES_START_EPOCH=2026-07-01T00:00:00Z \
CALLBASES_RUNTIME_SECONDS=31536000 node server/server.js
```

Open <http://localhost:8080>.

`touristic attractions` are enabled by default and are fetched only on the
backend from Ensembl region endpoints, then broadcast as summary messages over
the existing SSE stream. They are window-cached server-side and the attraction
worker quiets down after `attractionDeadAirMs` of having no connected listeners.

If your reference assembly is not GRCh38, set it explicitly in `config.json`
or via env:

```bash
CALLBASES_ATTRACTION_ASSEMBLY=GRCh37
CALLBASES_ATTRACTION_DEAD_AIR_MS=30000
CALLBASES_ATTRACTION_WINDOW_BASES=200000
node server/server.js
```

## deploy

one small vps, sized for the artifact disk (~5 gb consensus-only, ~60-80 gb with
pile-up), running the server under `systemd` for the whole project, behind caddy
for automatic https and sse-friendly proxying.

```bash
# on the VPS, once:
sudo mkdir -p /opt/call-bases
sudo cp infra/call-bases.service /etc/systemd/system/
sudo cp infra/call-bases.env.example /opt/call-bases/call-bases.env   # edit pacing
CALLBASES_DOMAIN=stream.example.org caddy run --config infra/Caddyfile  # or as a service

# from your machine:
infra/deploy.sh user@vps-host artifacts
```

the server is stateless: a restart (or reboot) resumes at the correct `f(now)`
index automatically.
