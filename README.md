# dataverse-mount (with optional Globus endpoint)

## What this does, in plain English

A [Dataverse](https://dataverse.org) dataset is normally something you
download file-by-file through a website. This tool lets you **browse
it as if it were a folder on your own computer** — with the original
folder structure and filenames preserved. Open files in your editor,
`ls` and `grep` them, point a script at them, whatever — they behave
like real files. Under the hood the bytes are fetched on-demand from
Dataverse, so there's no upfront download and no disk space needed
for the whole dataset. That's the basic mode (`./mount.sh`).

The second mode (`./mount-globus.sh`) layers a personal
[Globus](https://www.globus.org) endpoint on top of the same mount.
Globus is the standard tool for moving TBs of research data between
institutions — much faster and more resilient than scp/rsync over
long distances. Run this script and your machine becomes a Globus
endpoint serving the dataset (folder/file names preserved at the
destination); point any other Globus endpoint at it — say your HPC
cluster's scratch storage — and Globus pulls the whole dataset over.

**Almost no setup.** Three pieces of information: the Dataverse URL,
the dataset DOI, and optionally an API token if the files aren't
public. The Globus mode adds one extra one-time browser login (the
script walks you through it) — credentials persist locally so later
runs go straight to "endpoint online."

**Nothing required from anyone else.** No paid Globus subscription,
no Globus Connect Server, no Globus S3 connector, no Dataverse-side
plugin, no operator changes. The traditional "Dataverse + managed
Globus" path needs all of those — usually only realistic for
institutions with dedicated data-engineering staff. This tool needs
none of them: it talks to any standard Dataverse and runs Globus
Connect Personal under Globus's free tier. Everything happens inside
one Docker container on your own machine.

See the [Quickstart](#quickstart) for the three-line setup.

```text
           ┌──────────────────────────┐
           │   docker container       │
           │  ┌────────────────────┐  │     Dataverse  ──► presigned S3 URL
 ./data ◄──┼──┤ FUSE mount         │  │           ▲
  (host)   │  │ rclone backend     │──┼───────────┘
           │  └────────────────────┘  │
           │  ┌────────────────────┐  │
           │  │ (optional)         │  │     Globus Transfer ◄── any
           │  │ Globus Connect     │  │                          Globus
           │  │ Personal           │  │                          client
           │  └────────────────────┘  │
           └──────────────────────────┘
```

## Quickstart

```bash
git clone https://github.com/ErykKul/dataverse-globus.git
cd dataverse-globus
./mount.sh
```

That's it. On the first run, `mount.sh` prompts for your Dataverse
URL, dataset DOI, and (optionally) an API token, saves them to
`.env`, builds the Docker image, and brings the mount up at `./data`
in the foreground. Ctrl-C unmounts cleanly. Subsequent runs read
`.env` and just go.

```bash
# In another terminal, while mount.sh is running:
ls -R ./data
cat ./data/path/to/file.txt
```

The API token is **optional** — public datasets and published files
are readable as a guest. Provide a token only when you need restricted
files, draft versions, or owner-only access.

## Prerequisites

- Docker (Engine on Linux; Docker Desktop on macOS or WSL2 on
  Windows).
- For the Globus path: a free Globus account at
  https://app.globus.org.

### Platform notes

| Platform        | Mount mode                                     | Globus mode  |
| ---             | ---                                            | ---          |
| Linux           | ✅ full host visibility via bind-mount         | ✅ full       |
| WSL2 (Windows)  | ✅ same as Linux (clone *inside* WSL for speed) | ✅ full       |
| macOS           | ⚠️ visible inside container only (see below)    | ✅ full       |

On macOS, Docker Desktop runs containers inside a hidden Linux VM.
FUSE works fine *inside* that VM, but the mount events don't
propagate back to the macOS filesystem — so `./data` on the host
won't show files even while the container is happily serving them.
Two workarounds: (a) browse via `docker exec -it dv-mount ls /mnt/dataset`,
or (b) use the Globus mode and pull the dataset to a Globus endpoint
on your Mac (e.g. a Globus Connect Personal you've installed
natively), which writes straight to your real filesystem.

## Three scripts

### `./mount.sh` — mount the dataset

Foreground rclone FUSE mount. Container lifetime == mount lifetime;
`Ctrl-C` shuts down and unmounts cleanly.

If `.env` is missing, prompts for:

| Prompt              | Required? | Notes                                                            |
| ---                 | ---       | ---                                                              |
| Dataverse base URL  | yes       | e.g. `https://demo.dataverse.org`, no trailing slash             |
| Dataset DOI         | yes       | e.g. `doi:10.5072/FK2/ABCD`                                      |
| API token           | optional  | blank = guest access (public datasets / public files only)       |
| Dataset version     | optional  | `:latest`, `:draft`, `:latest-published`, or `1.0`/`2.0`/…       |
| Ingest format       | optional  | `original` (default) or `archival` — see [Tabular files](#tabular-files-csv-stata-spss) below |

### `./mount-globus.sh` — mount the dataset + publish as a Globus endpoint

Same prompts. On first run, also asks for a Globus endpoint name and
walks you through the device-code login (open a URL, paste a code).
Endpoint credentials live in a Docker volume so future runs skip
straight to the mount.

When the endpoint comes online (a few seconds after the script
starts), find it in the Globus web app under your account. Dataset
files appear at `/mnt/dataset/` inside the endpoint.

`Ctrl-C` takes the endpoint offline and unmounts.

### `./unmount.sh` — stop and clean up

Stops whichever container is running (`dv-mount` or `dv-mount-globus`)
and clears any stale FUSE mount on `./data`. Idempotent — safe to run
any time.

### `./reset-globus.sh` — wipe the Globus endpoint state

Removes `./globus-state/` so the next `./mount-globus.sh` registers a
new endpoint (with a fresh device-code login). Prints the URL to
delete the endpoint on Globus's side too — both halves need to go for
a real reset. Use `-y` to skip the confirmation prompt.

## What happens during restarts and interruptions

- **Container restart** (e.g. `docker stop` / re-run, host reboot,
  laptop sleep). Globus Transfer tracks each task server-side. When
  the endpoint disconnects mid-transfer, the task pauses and Globus
  resumes it once the endpoint comes back. On our side, restarting
  the script re-fetches the file list, re-uses the Globus credentials
  in `./globus-state/`, and the endpoint reconnects automatically.
  Resume granularity is per-file (Globus's standard).

- **Presigned-URL expiry mid-stream** (long single-file transfer
  through a 1-hour AWS URL TTL). The rclone backend detects this,
  fetches a fresh URL, and re-issues the GET with `Range:
  bytes=<bytes-already-read>-…` transparently. The caller never sees
  the failure.

- **Dataset gets a new version while we're running.** The file list
  is frozen at mount time on purpose (so it can't shift under an
  in-progress transfer). New / removed files only show up after a
  restart. This is the one interruption case that needs human
  attention.

- **Network blips, Dataverse 5xx errors.** rclone retries by default.
  If retries exhaust, Globus retries the task.

## Resetting for a demo or fresh start

The Globus endpoint has two halves: local credentials in
`./globus-state/` and a registered endpoint on Globus's side.

To reset both:

```bash
./unmount.sh        # stop the container if it's running
./reset-globus.sh   # wipe ./globus-state/ (and any legacy Docker volume)
```

Then open https://app.globus.org/file-manager/collections, find the
endpoint (named whatever you typed during setup, default
`dataverse-mount-<hostname>`), menu → **Delete**.

Next `./mount-globus.sh` walks you through registering a fresh
endpoint from scratch.

(If you only delete the local state without removing the endpoint on
Globus, the orphaned endpoint stays listed in your account forever
but doesn't do anything — harmless, just untidy.)

## Tabular files (CSV, Stata, SPSS, …)

Dataverse "ingests" tabular uploads: it parses the file and stores
both the original bytes and a normalised `.tab` archival form. The
default (`INGEST_FORMAT=original`) exposes the file under its original
name with a verifiable MD5 — what most users want. Set
`INGEST_FORMAT=archival` to expose Dataverse's post-ingest form
instead (no MD5, no reliable size).

## Configuration reference

All values are read from `.env`. The scripts create one on first run;
edit by hand to change values, or delete to re-prompt.

| Variable           | Required for         | Description |
| ---                | ---                  | --- |
| `DV_HOST`          | always               | Dataverse base URL, no trailing slash. |
| `DATASET_PID`      | always               | Persistent ID, e.g. `doi:10.5072/FK2/ABCD`. |
| `DV_TOKEN`         | optional             | Dataverse API token. Blank → guest access. |
| `DATASET_VERSION`  | optional             | `:latest` (default), `:draft`, `:latest-published`, or `1.0`/`2.0`/…. |
| `INGEST_FORMAT`    | optional             | `original` (default) or `archival`. |
| `VFS_CACHE_MODE`   | optional             | rclone VFS cache mode. Default `minimal`. |
| `VFS_CACHE_MAX_AGE`| optional             | How long cached bytes stay valid. Default `1h`. |
| `RCLONE_LOG_LEVEL` | optional             | `DEBUG`/`INFO`/`NOTICE`/`ERROR`. Default `INFO`. |

## Read-only

The backend is intentionally read-only:

- `Put`, `Update`, `Remove`, `Mkdir`, `Rmdir` all return errors.
- `rclone mount` runs with `--read-only`.

Globus transfers **from** this endpoint to elsewhere work. Transfers
**to** this endpoint don't. If you want to upload, use the Dataverse
UI or its Native API directly.

## Under the hood

- **Image**: multi-stage Dockerfile. Stage 1 builds the rclone binary
  from a pinned ref of [ErykKul/rclone](https://github.com/ErykKul/rclone/tree/dataverse-backend/backend/dataverse).
  Stage 2 is `debian:bookworm-slim` with FUSE3, `tini`, and (when
  built with `--build-arg INCLUDE_GLOBUS=1`) Globus Connect Personal
  installed at build time.
- **Backend behaviour** (in the rclone fork): per-dataset remote,
  presigned-URL cache with `singleflight` dedup, mid-stream URL
  resume on long transfers, tabular-ingest handling. See
  [`backend/dataverse/README.md`](https://github.com/ErykKul/rclone/blob/dataverse-backend/backend/dataverse/README.md)
  for the gritty details.

## Building from source manually

The scripts auto-build on first run. To build by hand:

```bash
docker build -t dataverse-mount:local .                                      # mount-only
docker build --build-arg INCLUDE_GLOBUS=1 -t dataverse-mount:local-globus .  # + Globus
```

Build against a different rclone fork / branch:

```bash
docker build \
  --build-arg RCLONE_REPO=https://github.com/your-fork/rclone.git \
  --build-arg RCLONE_REF=your-branch \
  -t dataverse-mount:local .
```

## Prebuilt images on GHCR

CI publishes `ghcr.io/erykkul/dataverse-mount:latest` (mount-only) and
`…:latest-globus` (with GCP) on every push to `main`. If you'd rather
skip the build, point `IMAGE_TAG` at GHCR:

```bash
IMAGE_TAG=ghcr.io/erykkul/dataverse-mount:latest ./mount.sh
IMAGE_TAG=ghcr.io/erykkul/dataverse-mount:latest-globus ./mount-globus.sh
```

Note: newly-published GHCR packages default to private. The repo's CI
flips visibility automatically if the maintainer has set up a
`GHCR_VISIBILITY_TOKEN` secret (a PAT with `admin:packages` scope); if
not, the first time you pull you may need to `docker login ghcr.io`
with your own token.

## License

Source in this repository (Dockerfile, scripts, docs) is MIT — see
`LICENSE`.

The image bundles:

- rclone (MIT) at the pinned ref.
- *(only when built with `INCLUDE_GLOBUS=1`)* Globus Connect Personal,
  downloaded at build time from https://downloads.globus.org. GCP is
  distributed under Globus's own license. See
  https://www.globus.org/legal/license.
