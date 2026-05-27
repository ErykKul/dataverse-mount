# dataverse-mount (with optional Globus endpoint)

Mount any [Dataverse](https://dataverse.org) dataset as a real filesystem,
in a single `docker run`. Optionally publish the mount as a personal
[Globus](https://www.globus.org) endpoint for high-throughput transfers.

```text
   docker run … mount
            │
            ▼
   /mnt/dataset (FUSE)              ◄── bind-mount this to your host
            ▲                            and browse like any folder
            │
   ┌────────────────────┐     ┌──────────────┐  ?format=original
   │ rclone Dataverse   │────►│  Dataverse   │──► presigned S3 URL
   │ backend (read-only)│     │  /api/access │   (or proxied bytes)
   └────────────────────┘     └──────────────┘
```

Add `--build-arg INCLUDE_GLOBUS=1` at image build time and run with mode
`mount-globus` to layer Globus Connect Personal on top.

## Why

- A research dataset on a Dataverse instance you don't operate.
- You want to **read** the bytes as files with the original folder
  structure — not learn the Dataverse REST API and certainly not get
  S3 credentials.
- One `docker run`, a Dataverse token, a dataset PID. Done.

The bytes are fetched via Dataverse's `/api/access/datafile/{id}`
endpoint with your API token. When the installation is configured for
direct S3 download, the response is a 302 to a presigned S3 URL — the
rclone backend follows the redirect transparently. When it isn't, the
backend reads bytes from the Dataverse server itself. Either way, the
user only ever sees their Dataverse token.

## What's in the image

- A patched [rclone](https://rclone.org) with a Dataverse backend.
- `fuse3`, `tini`, `curl`, `ca-certificates`.
- *(optional, built with `--build-arg INCLUDE_GLOBUS=1`)* [Globus
  Connect Personal](https://docs.globus.org/globus-connect-personal/),
  installed at build time, configured at first run.
- A small entrypoint that wires everything together.

## Prerequisites

- Linux host with Docker, `/dev/fuse`, and the `SYS_ADMIN` capability.
  Tested on `linux/amd64` and `linux/arm64`.
- A Dataverse API token. Get it from your user profile in any
  Dataverse instance.
- *(Globus mode only)* A free Globus account at
  https://app.globus.org. You'll log in once via the browser to issue
  a one-time setup key (see [Globus mode](#globus-mode) below).

The Dataverse instance does **not** need to be operated by you; the
token just needs read access to the dataset.

## Quick start: mount only

Copy `sample.env` to `.env` and fill in `DV_HOST`, `DV_TOKEN`,
`DATASET_PID`. Then:

```bash
docker run --rm -it \
  --cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor:unconfined \
  --mount type=bind,source="$PWD/data",target=/mnt/dataset,bind-propagation=rshared \
  --env-file .env \
  ghcr.io/erykkul/dataverse-mount:latest
```

When the container is up, `./data/` on the host shows the dataset's
folder structure with the original filenames. Read files like any
other folder. `Ctrl-C` stops the container and unmounts cleanly.

The `bind-propagation=rshared` part is what makes the FUSE mount inside
the container visible on the host. Without it the bind mount only
shows the directory's contents from container startup, not the live
FUSE filesystem. (rclone's own docker docs cover this:
https://rclone.org/install/#docker-image)

If you don't want a host bind mount and just want to `docker exec` into
the container to inspect files, drop the `--mount` flag.

### DNS for presigned-URL hosts

When Dataverse is configured for direct S3 download, `/api/access/datafile/{id}`
returns a 302 to whatever hostname the storage driver was registered with
(e.g. `s3.us-east-1.amazonaws.com`, `minio.example.com`). The container
needs to resolve that hostname. For public hosts this just works. For
private hosts or local dev setups where the S3 endpoint lives under a
`.localhost` subdomain (e.g. `minio.localhost:9000`), add a static
mapping:

```bash
docker run --add-host minio.example.com:10.0.0.42 ... 
```

Symptom of a missing mapping: listings work but reads fail with `cat:
…: Input/output error`. Container logs show the rclone backend got a
redirect target it couldn't resolve.

## Globus mode

For when you want the dataset reachable as a Globus endpoint — useful
for very large datasets, slow networks, or sharing access with
collaborators who have Globus.

### 1. Build the image with Globus included

```bash
docker build --build-arg INCLUDE_GLOBUS=1 -t dataverse-mount:globus .
```

Or pull the prebuilt image with the `-globus` tag suffix once CI
publishes it:

```bash
docker pull ghcr.io/erykkul/dataverse-mount:latest-globus
```

### 2. Register the endpoint (one-time, interactive)

GCP no longer hands out setup keys from a web button. Run the setup
mode interactively — it'll print a URL and a one-time code, you visit
the URL in any browser, log into Globus, paste the code, and the
endpoint registers itself.

```bash
docker volume create dataverse-globus-state

docker run --rm -it \
  -v dataverse-globus-state:/home/dvgr/.globusonline \
  -e GLOBUS_ENDPOINT_NAME="my-dataverse-mount" \
  dataverse-mount:globus globus-setup
```

Watch the terminal for a `https://auth.globus.org/v2/oauth2/device`
URL and a short user code. Once you complete the device-code flow in
your browser, GCP writes credentials into the volume and exits. The
endpoint now shows up in the Globus web app under your account, and
the volume survives container restarts.

(If you have a legacy setup key from somewhere, pass it via
`GLOBUS_SETUP_KEY=…` instead. The web UI doesn't generate these
anymore but old keys still work via the same code path.)

### 3. Run the mount + Globus together

```bash
docker run -d --name dv-globus \
  --cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor:unconfined \
  -v dataverse-globus-state:/home/dvgr/.globusonline \
  --env-file .env \
  dataverse-mount:globus mount-globus
```

A few seconds later the endpoint shows as **online** in the Globus web
UI. Use it like any other Globus endpoint.

`docker stop dv-globus` unmounts FUSE and stops GCP cleanly. The
state volume keeps the same endpoint registered for next time.

## Modes

The container's `CMD` selects the mode. Pass it as the final
positional argument to `docker run`:

- **`mount`** *(default)* — mount the dataset on `/mnt/dataset` and
  stay in the foreground. Container lifetime == mount lifetime.
- **`mount-globus`** — same mount, plus start Globus Connect Personal
  in the foreground. Requires `INCLUDE_GLOBUS=1` build and a prior
  `globus-setup` run.
- **`globus-setup`** — one-time GCP registration. Requires
  `GLOBUS_SETUP_KEY`. Exits after the endpoint is registered.
- **`status`** — print whether the mount is live and whether GCP is
  running. Intended for `docker exec` checks.
- **`shell`** — drop into a bash shell. For debugging the image.

## Configuration reference

All passed via environment variables. See `sample.env` for defaults.

| Variable           | Required for         | Description |
| ---                | ---                  | --- |
| `DV_HOST`          | `mount`/`mount-globus` | Dataverse base URL, no trailing slash. |
| `DV_TOKEN`         | `mount`/`mount-globus` | Dataverse API token. Sent as `X-Dataverse-Key` on every request. |
| `DATASET_PID`      | `mount`/`mount-globus` | Persistent ID, e.g. `doi:10.5072/FK2/ABCD`. |
| `DATASET_VERSION`  | optional             | `:latest`, `:draft`, `:latest-published`, or `1.0`/`2.0`/…. Default `:latest`. |
| `VFS_CACHE_MODE`   | optional             | rclone VFS cache mode. Default `minimal`. |
| `VFS_CACHE_MAX_AGE`| optional             | How long cached bytes stay valid. Default `1h`. |
| `RCLONE_LOG_LEVEL` | optional             | `DEBUG`/`INFO`/`NOTICE`/`ERROR`. Default `INFO`. |
| `GLOBUS_ENDPOINT_NAME` | `globus-setup` (optional) | Name to give the new endpoint in Globus. Defaults to `dataverse-mount-<hostname>`. |
| `GLOBUS_SETUP_KEY` | `globus-setup` (legacy) | Old-style setup key. Web UI no longer issues these; provided for backwards compatibility only. |

## Read-only by design

- `Put`, `Update`, `Remove`, `Mkdir`, `Rmdir` all return errors.
- `rclone mount` is invoked with `--read-only`.

Globus transfers **from** this endpoint to elsewhere work.
Transfers **to** this endpoint don't. If you want to upload, use the
Dataverse UI or its Native API directly.

## What about the rclone backend itself?

Source lives at
[ErykKul/rclone, branch `dataverse-backend`](https://github.com/ErykKul/rclone/tree/dataverse-backend/backend/dataverse).
See `backend/dataverse/README.md` there for the backend's own
configuration, caching, and tabular-ingest handling notes.

The Dockerfile pins the rclone repo and ref via build args
(`RCLONE_REPO`, `RCLONE_REF`). Override them to build against a fork
or a specific commit.

## Why not just use `s3fs` against Dataverse's S3 backend?

There's a community recipe at
[gdcc/dataverse-recipes#35](https://github.com/gdcc/dataverse-recipes/pull/35).
It works, but:

- It needs the **operator's** S3 credentials. Most operators won't
  share these.
- It bypasses Dataverse's access-control checks: if the operator's
  S3 creds can read the bucket, the user can read every dataset.
- It surfaces raw S3 object keys, not the dataset's folder
  structure and human-readable filenames.

This image takes the opposite approach: every byte goes through
Dataverse's access endpoint, which honours the token's permissions.
The user never sees S3 credentials. The mount surfaces the dataset's
`directoryLabel` + `label` tree, so files have the names the dataset
author chose.

Pick s3fs if you're the operator and want one mount per Dataverse
instance. Pick this if you're a user and want one mount per dataset.

## Building locally

```bash
# Mount-only (default):
docker build -t dataverse-mount:dev .

# Mount + Globus:
docker build --build-arg INCLUDE_GLOBUS=1 -t dataverse-mount:dev-globus .
```

Build against a different rclone fork or branch:

```bash
docker build \
  --build-arg RCLONE_REPO=https://github.com/example/rclone.git \
  --build-arg RCLONE_REF=my-branch \
  -t dataverse-mount:dev .
```

Multi-arch:

```bash
docker buildx create --use --name dataverse-mount
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/erykkul/dataverse-mount:latest --push .
```

## License

Source in this repository (Dockerfile, entrypoint, docs) is MIT —
see `LICENSE`.

The image bundles:

- rclone (MIT) at the pinned ref.
- *(only when built with `INCLUDE_GLOBUS=1`)* Globus Connect Personal,
  downloaded at build time from https://downloads.globus.org. GCP is
  distributed under Globus's own license; the image doesn't
  redistribute it independently, it fetches per build. See
  https://www.globus.org/legal/license.

If you publish images built from this repo with `INCLUDE_GLOBUS=1`,
your downstream users also receive the GCP bundle; verify GCP's
license still permits your distribution model.
