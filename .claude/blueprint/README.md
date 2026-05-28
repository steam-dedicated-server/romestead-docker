# Game-Server-on-Docker Blueprint

Reusable patterns for shipping any Steam-based dedicated server (Rust, ARK, Valheim, V Rising, Palworld, Satisfactory, Conan Exiles, 7 Days to Die, …) on Docker, Compose, and Kubernetes. Every "why" line in this document traces back to a real bug or operational lesson — these are tested defaults, not theory.

> Companion: [`checklist-new-game.md`](checklist-new-game.md) — phase-by-phase bring-up checklist for porting to a new game.
>
> Reference implementation: [`last-oasis-docker`](https://github.com/steam-dedicated-server/last-oasis-docker) — the project these patterns were first extracted from. When in doubt about how a pattern looks in real code, read that repo.

**Placeholder convention used throughout this document:**
- `<cli>` — your chosen CLI name (e.g. `lo`, `rust`, `sat`, `pal`). Used as both the script filename and the bash namespace (`<cli>::log::info`).
- `<CLI>` — uppercase form, used for env vars (`<CLI>_RETRY_MAX`).
- `<game>` — the game's short name, used in image tags, paths, banners.
- `<game-dir>` — the game's top-level install subdirectory (e.g. `Mist`, `FactoryGame`, `RustDedicated`).

---

## Philosophy

1. **One image, three deploy targets.** The same image runs bare Docker, Compose, and Kubernetes. Differences are configuration, not separate images.
2. **The container is the binary.** Game files, steamcmd state, saves, and backups all live on one persistent volume — easy to back up, easy to migrate.
3. **A single CLI inside the image.** `install`, `update`, `run`, `backup`, `health`, `login`, `shell` — same dispatcher whether you're on Compose or K8s.
4. **Fail loudly.** SteamCMD is happy to return 0 on a truncated download or wrong platform. Use `+@ShutdownOnFailedCommand 1`, `set -o pipefail`, healthchecks, and proper exit codes.
5. **Performance defaults that are obvious.** seccomp:unconfined, tini PID 1, `nofile=1048576`, `SYS_NICE` for renice, pre-warmed steamcmd — every choice has a one-line "why" in the code or compose file.

---

## Canonical file structure

```
.
├── docker/
│   ├── Dockerfile             # multi-stage; downloader → runtime
│   └── healthcheck.py         # protocol probe (A2S for Source-engine games)
├── scripts/
│   ├── <cli>                  # main dispatcher — e.g. `lo`, `rust`, `sat`, `pal`
│   └── lib/
│       ├── common.sh          # logging, retry, traps, help
│       ├── config.sh          # env loading + required-var validation
│       ├── steam.sh           # steamcmd wrappers (install / update / login)
│       ├── server.sh          # lifecycle (run, start, runtime prep)
│       └── backup.sh          # tar.gz of save dir
├── config/
│   ├── defaults.env           # baked-into-image defaults
│   └── server.example.env     # user template (copy to server.env)
├── compose/
│   ├── docker-compose.yml         # single-server, production-tuned
│   └── docker-compose.multi.yml   # multi-map skeleton
├── k8s/
│   ├── README.md              # deploy guide
│   ├── kustomization.yaml
│   ├── pvc.yaml
│   ├── install-job.yaml       # one-shot steamcmd Job
│   ├── deployment.yaml        # the actual server
│   ├── backup-cronjob.yaml
│   └── secret.example.yaml
├── .github/workflows/
│   ├── ci.yml                 # shellcheck + hadolint + yamllint + smoke test
│   └── release.yml            # GHCR on v*.*.* tags, SBOM + provenance
├── Makefile                   # task runner
├── README.md
├── LICENSE
├── .dockerignore .gitignore .gitattributes .editorconfig .shellcheckrc .hadolint.yaml
└── <game>-logo.jpg            # optional banner for the README
```

---

## Build patterns

### Multi-stage Dockerfile

```
┌─ Stage 1: steamcmd ────────────┐    Downloads + extracts steamcmd_linux.tar.gz.
│   FROM ubuntu:24.04            │    Cached separately from the runtime stage
│   curl | tar -xz               │    so code changes don't refetch steamcmd.
└────────────────────────────────┘

┌─ Stage 2: runtime ─────────────┐    Minimal apt deps + tini, COPY steamcmd
│   FROM ubuntu:24.04            │    from stage 1, COPY scripts + config,
│   apt: tini ca-certs lib32     │    pre-warm `steamcmd.sh +quit`, then USER
│   COPY --from=steamcmd ...     │    steam.
│   COPY scripts/ config/ ...    │
└────────────────────────────────┘
```

Key flags:

| Flag | Why |
|---|---|
| `# syntax=docker/dockerfile:1.7` | Enables `--mount=type=cache` and `--chmod` |
| `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` (in pipe stages) | Truncated `curl \| tar` would otherwise return 0 — hadolint DL4006 |
| `--mount=type=cache,target=/var/cache/apt` | Re-builds skip apt re-download |
| `COPY --chmod=0755 ...` | Linux exec bit on scripts authored on Windows |
| `ENV HOME=/mnt/steam` | steamcmd's `~/.steam` lands inside the volume |
| `VOLUME ["/mnt/steam"]` | Single canonical mount point — matches the upstream/K8s convention |
| `tini` as PID 1 | Clean signal forwarding, zombie reaping |
| `HEALTHCHECK CMD python3 /opt/.../healthcheck.py` | Pure stdlib, ~5 ms/probe |
| `USER steam` (UID 1000, GID 1001) | Match upstream convention — see [`patterns.md → UID/GID`](#uidgid) |

### Healthcheck — protocol probe

The probe structure is the same regardless of protocol: `socket` (or `http.client`) → send → recv → parse → exit code 0 or 1. Pick the payload by what the server actually speaks.

**A2S (Source-engine games — UDP query).** Works for Source-engine and a wide list of derivatives:

```python
A2S_INFO = b"\xff\xff\xff\xffTSource Engine Query\x00"
sock.sendto(A2S_INFO, (host, query_port))
data, _ = sock.recvfrom(2048)
ok = data[:4] == b"\xff\xff\xff\xff" and data[4:5] in (b"I", b"A")
```

**HTTPS API (modern UE5 games — Satisfactory / V Rising / Palworld).** POST a JSON body to the management endpoint. The server typically ships a self-signed cert; disable verification because we're asserting reachability + liveness, not identity. `CERT_NONE` is appropriate here — the alternative is shipping a trust bundle, which is a maintenance burden the probe doesn't deserve:

```python
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
conn = http.client.HTTPSConnection(host, port, timeout=TIMEOUT, context=ctx)
conn.request("POST", "/api/v1",
             body=json.dumps({"function": "HealthCheck", "data": {"clientCustomData": ""}}),
             headers={"Content-Type": "application/json"})
resp = conn.getresponse()
payload = json.loads(resp.read())
ok = resp.status == 200 and payload.get("data", {}).get("health") == "healthy"
```

Why HTTPS catches more than `pgrep`: a Satisfactory server can have the `FactoryServer-Linux-Shipping` process alive but its API loop frozen — `pgrep` returns 0, but no player can connect. The HTTPS round-trip catches this; `pgrep` doesn't.

**Other protocol families** (swap the body, keep the structure):

- **Rust** — UDP query similar to A2S, slightly different payload
- **Valheim** — Steam A2S works on the query port
- **Minecraft (non-Steam, but same blueprint applies)** — server list ping over TCP

Keep the probe in pure stdlib (`socket`, `ssl`, `http.client`, `json`) — no `pip install` in a healthcheck.

### tini + exec

Inside the container the `<cli> run` script ends with `exec "$bin" "${args[@]}"` so the engine becomes the direct child of tini. Without `exec`, a bash wrapper holds PID and SIGTERM never reaches the engine — `terminationGracePeriodSeconds` then elapses and SIGKILL truncates saves.

---

## Script patterns

### Modular CLI

```
scripts/<cli>               ← entrypoint, sources libs, dispatches subcommand
scripts/lib/common.sh       ← log, die, retry, require, help
scripts/lib/config.sh       ← load defaults.env + server.env (allexport)
scripts/lib/steam.sh        ← steamcmd wrappers (install/update/login)
scripts/lib/server.sh       ← run + runtime prep (steamclient symlinks, ulimit, renice)
scripts/lib/backup.sh       ← tar -czf with timestamp
```

Why split:

- Each lib has one responsibility — easy to swap (e.g., replace `steam.sh` with `epic.sh` for Epic Online Services games)
- Sourced libs share `<cli>::*` namespace, no global pollution
- Strict mode (`set -euo pipefail`) only in the entry script — libs stay sourceable

### Logging

```bash
<cli>::log::info()  { <cli>::log::_write INFO  "$<CLI>_BLUE"   "$*"; }
<cli>::log::warn()  { <cli>::log::_write WARN  "$<CLI>_YELLOW" "$*"; }
<cli>::log::error() { <cli>::log::_write ERROR "$<CLI>_RED"    "$*"; }
<cli>::log::ok()    { <cli>::log::_write OK    "$<CLI>_GREEN"  "$*"; }
```

ISO timestamp, level, message, color only on TTY. Writes to stderr so command output stays clean on stdout.

### Retry with exponential backoff

```bash
<cli>::retry()   # wraps any command; honors <CLI>_RETRY_MAX, <CLI>_RETRY_DELAY
```

Used for every steamcmd call — Steam's CMS occasionally fails the first attempt on a fresh anonymous license cache.

### Config loading precedence

```
defaults.env  (lowest)  →  config/server.env  →  shell env  (highest)
```

Two-line implementation: `set -o allexport; . file; set +o allexport`. Re-export so child processes inherit the values.

### Game settings generation (INI templates → envsubst)

Many UE games read their server config from one or more `.ini` files at startup — typically under `<game-dir>/Saved/Config/LinuxServer/`. Re-baking those INIs from environment variables on every start gives operators one consistent control surface (env vars / Secret) instead of a mix of "edit this INI inside the volume" and "set this env var".

**Pattern:** ship `*.ini.template` files with `$VAR` placeholders in `config/templates/`, run `envsubst` against each at server start, and write to the LinuxServer config dir.

```
config/templates/
  Engine.ini.template
  Game.ini.template
  GameUserSettings.ini.template
  …

scripts/lib/settings.sh
  <cli>::settings::_apply_defaults    # `export VAR=${VAR:-default}` for every $VAR the templates reference
  <cli>::settings::_render <name>     # envsubst < templates/$name.template > $dest/$name
  <cli>::settings::compile            # public — _apply_defaults then _render each
```

**Games where this fits:** Satisfactory, ARK, Conan Exiles, 7 Days to Die, Project Zomboid — basically any UE-based dedicated server that exposes config via INI rather than just CLI flags. Skip the pattern if the game accepts everything via CLI (Last Oasis, Valheim) — no benefit.

**Escape hatch:** an `GENERATE_SETTINGS=false` env should let the operator preserve hand-edits to INI files between restarts, while still letting some "hot" keys be patched in place (e.g. `MaxPlayers`) — that way capping slots doesn't require a full re-render.

**Why not bake all the defaults into `defaults.env`?** envsubst leaves `$UNSET_VAR` as the literal string in the output — which produces broken INI lines. The cleaner pattern is `export VAR=${VAR:-default}` inside the settings library so the rendering still works when a user supplies only a partial override.

---

## Deployment patterns

### Docker Compose

| Knob | Where | Effect |
|---|---|---|
| `seccomp:unconfined` | `security_opt` | steamcmd uses blocked syscalls (mandatory) |
| `ulimits.nofile: 1048576` | service | many concurrent player connections |
| `tmpfs: /tmp:size=256m` | service | avoid volume churn |
| `stop_grace_period: 60s` | service | flush saves before SIGKILL |
| `deploy.resources.{limits,reservations}` | service | cap a runaway server |
| `logging.options.max-size: 20m, max-file: 5` | service | log rotation |
| `--profile maintenance` | install/update/backup services | one-shot ops don't auto-start |
| Anchors (`x-image`, `x-common`, `x-env`) | top-level | DRY for multi-server |
| `init: false` | service | tini is already inside the image |

### Kubernetes

| Resource | Notes |
|---|---|
| `Namespace` | Created **out-of-band** via `kubectl create namespace` — not in the kustomize bundle, leaves namespace policy to the operator |
| `PVC` | RWO, sized for the game's install + saves headroom (typical 20–80 Gi; Last Oasis ≈ 30 Gi, Satisfactory ≈ 15 Gi, ARK ≈ 50 Gi) |
| `Secret` | All env vars; never committed; `secret.example.yaml` is the template |
| `Job` (install) | One-shot steamcmd run, `restartPolicy: Never`, `backoffLimit: 0` so a failed attempt surfaces fast |
| `Deployment` (server) | `replicas: 1`, `strategy: Recreate`, `hostNetwork: true`, `terminationGracePeriodSeconds: 60` |
| `CronJob` (backup) | Daily, `concurrencyPolicy: Forbid` |
| `initContainer` (fix-permissions) | busybox `chown 1000:1001` — PVCs often provision root-owned |
| Pod `securityContext` | `runAsUser: 1000`, `runAsGroup: 1001`, `fsGroup: 1001` |
| Container `securityContext` | `seccompProfile: Unconfined`, `capabilities.add: [SYS_NICE]` for renice |
| Probes | startup / liveness / readiness — all `exec` the same healthcheck.py |

### Multi-server on one host: shared vs per-server volume

Where the game writes saves decides the multi-server layout:

| Save location | Multi-server strategy | Disk cost | Examples |
|---|---|---|---|
| Inside install dir (`<INSTALL_DIR>/<game-dir>/Saved/`) | **One shared volume** — install/update once, run N server services with different ports | 1× game install | Last Oasis, ARK |
| Under `$HOME` at a fixed relative path | **One volume per server** — each container needs its own `$HOME/.config/...` namespace | N× game install | Satisfactory (`$HOME/.config/Epic/FactoryGame/Saved/`), some other UE5 titles |

The save-in-HOME case is the trap: if two compose services share `/mnt/steam`, both servers write into the same save path and clobber each other's worlds — but the second one starts fine, healthcheck passes, and the symptom is "missing buildings after a restart." Use per-server volumes (`satisfactory-01`, `satisfactory-02`) and accept the extra disk. Document this trade-off in the project's compose `multi.yml`.

K8s analogue: one PVC per realm Deployment when saves live in `$HOME`; one shared PVC across replicas-1 Deployments when saves live in the install dir.

### UID/GID

**UID 1000, GID 1001.** A common convention across Steam-server images (originating with Deradon's Last Oasis images and adopted widely). Many existing PVCs are already owned `1000:1001` — using `1000:1000` invites migration headaches when inheriting state from another image.

Ubuntu 24.04 ships a default `ubuntu` user at UID 1000 — `userdel --remove ubuntu` first, then create the runtime user (conventionally `steam`) at 1000:1001.

**PUID/PGID trade-off.** Some upstream images (Linuxserver.io / `cm2network`-style) take `PUID`/`PGID` env vars and `usermod`/`groupmod` at startup, then drop privileges. That's friendlier for **bind-mounting host directories** (the operator picks the host UID) but requires the container to start as **root**, which is a security regression. The blueprint defaults to baked-in 1000:1001 because:

- K8s PVCs are accessed by `fsGroup`/`runAsUser` at the pod level — runtime UID drift doesn't help
- Named volumes (Docker / Compose) are owned by whatever wrote them first — UID inside the image only matters once
- Running as non-root from PID 1 is one less thing for a security scan to flag

Offer PUID/PGID only when bind-mounts are the primary use case AND the operator can't pre-`chown` the host dir.

---

## CI / CD

```yaml
# .github/workflows/ci.yml
jobs:
  lint:
    - shellcheck (scripts/)
    - hadolint   (docker/Dockerfile)
    - yamllint   (relaxed: allow inline maps + aligned columns)
  build:
    - docker/build-push-action with type=gha cache, push: false, smoke-test `cli version` and `cli help`

# .github/workflows/release.yml
"on": push: tags: [v*.*.*]
- docker/metadata-action → semver tags + latest
- docker/build-push-action → push to GHCR with provenance + SBOM
```

**Quote the workflow `on:` key.** YAML 1.1 parses `on`, `off`, `yes`, `no` as booleans, so yamllint's default `truthy` rule reports the unquoted `on:` at line 3 of every workflow. Write it as `"on":` to keep the rule happy without changing behavior — GitHub Actions reads the file as YAML but treats the trigger key as a string either way.

**Skip `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`.** It was tempting as a Node 24 canary, but the practical effect is a "Node.js 20 is deprecated… being forced to run on Node.js 24" warning on every single CI run for every JS action you reference (checkout / setup-buildx / build-push / hadolint). The canary value is small (these actions are JS-only and run fine on Node 24) and the noise isn't worth it. When GitHub finishes removing Node 20 from runners (late 2026), JS actions auto-upgrade to Node 24 anyway, and by then most maintainers will have published Node 24-native majors to pin.

`.shellcheckrc` essentials:
```
shell=bash
external-sources=true
source-path=SCRIPTDIR    ← lets shellcheck follow `# shellcheck source=lib/common.sh`
```

`.hadolint.yaml`:
```yaml
ignored: [DL3008, DL3009]   # don't pin apt versions; cache mounts replace `rm -rf /var/lib/apt/lists`
```

yamllint inline config (allow k8s/compose inline-map style):
```yaml
rules:
  braces:  { max-spaces-inside: 1 }
  colons:  { max-spaces-after: -1 }
  commas:  { max-spaces-after: -1 }
```

`.gitattributes` for cross-platform projects (Windows porters in particular):
```
* text=auto eol=lf
*.{jpg,jpeg,png,gif,ico,webp,zip,tar,gz} binary
```
Without this every commit on Windows emits `warning: LF will be replaced by CRLF` for every text file the repo touches.

---

## SteamCMD gotchas (bug history)

Common pitfalls when integrating SteamCMD with dedicated servers. Each has been observed in real builds — apply the fixes up front to skip a debugging cycle.

### 1. Two app IDs per game — installer vs runtime

Some Steam dedicated servers expose **two** app IDs:

- **Installer app** — what SteamCMD downloads
- **Runtime app** — written to `<game-dir>/Binaries/Linux/steam_appid.txt` so the running server identifies itself to matchmaking

Examples:

| Game | Installer ID | Runtime ID | Same? |
|---|---|---|---|
| Last Oasis | `920720` | `903950` | ❌ |
| ARK: Survival Evolved | `376030` | (per-map) | ❌ |
| Satisfactory | `1690800` | `1690800` | ✅ |
| Valheim | `896660` | `896660` | ✅ |
| Palworld | `2394010` | `2394010` | ✅ |

If you use the runtime ID for `+app_update` on a two-ID game, SteamCMD returns **`Invalid platform`** because the runtime app has no downloadable depot. Use the installer ID for download, then write the runtime ID into `steam_appid.txt` post-install:

```bash
+force_install_dir "$INSTALL_DIR" \
+login "$STEAM_USER" \
+app_license_request "$STEAM_APP_ID" \
+app_update "$STEAM_APP_ID" validate \
+quit

# After install (only needed when installer ID ≠ runtime ID):
echo "$STEAM_RUNTIME_APP_ID" > "$INSTALL_DIR/<game-dir>/Binaries/Linux/steam_appid.txt"
```

### 2. SteamCMD silently returns 0 on failure

Without `+@ShutdownOnFailedCommand 1`, a failing `app_update` can still exit 0. Always set:

```
+@ShutdownOnFailedCommand 1     ← exit non-zero on first failed step
+@NoPromptForPassword 1         ← don't block waiting for an interactive password
+app_license_request <APP_ID>   ← pre-warm license cache (avoids "Missing configuration")
```

### 3. Unreal Engine (UE4/UE5) dedicated servers need steamclient.so symlinks

Engines built with the Steam SDK (most UE4 and UE5 dedicated servers, plus some Unity titles using Steamworks.NET) `dlopen` `steamclient.so` from `~/.steam/sdk32/steamclient.so` and `~/.steam/sdk64/steamclient.so`. steamcmd drops the runtime under various paths depending on version — symlink the first hit:

```bash
for arch in 32 64; do
  target=""
  for c in \
    "$HOME/.steam/steamcmd/linux${arch}/steamclient.so" \
    "$HOME/Steam/steamcmd/linux${arch}/steamclient.so" \
    "$HOME/.steam/steam/linux${arch}/steamclient.so" \
    "$HOME/.steam/Steam/linux${arch}/steamclient.so" \
    "/home/steam/steamcmd/linux${arch}/steamclient.so"; do
    [[ -e "$c" ]] && { target="$c"; break; }
  done
  [[ -n "$target" ]] && ln -sfT "$target" "$HOME/.steam/sdk${arch}/steamclient.so"
done

export LD_LIBRARY_PATH="$HOME/.steam/sdk64:$HOME/.steam/sdk32${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

For UE-based servers, also pass `-force_steamclient_link` to the engine CLI.

### 4. Anonymous downloads don't always work

`STEAM_USER=anonymous` works for many dedicated servers but **fails** for games whose SteamCMD depot requires an account that **owns the game**.

| Anonymous works | Requires owning account |
|---|---|
| Satisfactory, Valheim, Rust, Palworld, V Rising, Project Zomboid, CS2 | Last Oasis, ARK, Conan Exiles, 7 Days to Die, DayZ |

Symptom on the wrong side: install fails with `Invalid Password` / `Login Failure` / `Access Denied`. Switch to a real account:

```bash
docker compose --profile maintenance run --rm -it install
# enter password + 2FA on first run; cached for subsequent runs
```

Always verify on the official server setup guide or SteamDB before assuming.

### 5. Backend URL exactness (where applicable)

Some games proxy through a community matchmaking backend whose hostname must be **exact**. The unsuffixed host often resolves but the realm never registers with matchmaking. Symptom: **server starts fine, healthcheck passes, but no player can see it in the browser.**

Example: Last Oasis needs `backend-production.last-oasis.com`, not `backend.last-oasis.com`.

Games that use first-party matchmaking (Satisfactory, Valheim, Rust) or join-code / IP-direct (most newer titles) avoid this class of bug entirely.

When porting to a new game, find the official setup guide and copy the backend URL verbatim — don't guess, don't paraphrase.

### 6. Volume / UID mismatch

If the image uses `/data` but the K8s PVC mounts at `/mnt/steam`, the install writes into a tmpfs that vanishes between commands. The next `run` looks at an empty install dir and reports "binary not found." Pick **one** path, document it in the Dockerfile `VOLUME` directive and in `defaults.env`, and use it everywhere.

### 7. Branch / beta toggle

Several games ship a stable plus one or more parallel branches through SteamCMD's `-beta` flag. Operators want a one-knob switch (`BRANCH=public` ↔ `BRANCH=experimental`) — bake that in from day one:

```bash
steamcmd \
  +force_install_dir "$INSTALL_DIR" \
  +login "$STEAM_USER" \
  +app_update "$STEAM_APP_ID" -beta "$BRANCH" validate \
  +quit
```

Examples (canonical branch names you'll find on the game's beta page):

| Game | Stable | Beta |
|---|---|---|
| Satisfactory | `public` | `experimental` |
| Valheim | `public` | `public-test` |
| Conan Exiles | `public` | `testlive` |
| Rust | `public` | `staging`, `prerelease` |
| ARK: Survival Ascended | `public` | (none typical) |

Switching branches at runtime means re-running `install` against the new branch — the depot files differ. Document this in your `k8s/README.md` as a "branch-switch recipe" (patch Secret → delete install Job → re-apply → restart Deployment).

---

## Performance levers (in order of impact)

1. **`cpus`/`memory` limits + reservations** — prevents the engine from starving the host and vice versa.
2. **`ulimits.nofile=1048576`** — Unreal Engine + Steam SDK eat FDs (so do Source-engine servers at scale).
3. **`renice -n -5` (needs `SYS_NICE`)** — game thread wins scheduler conflicts.
4. **`tmpfs: /tmp:size=256m`** — Unreal Engine caches in /tmp; tmpfs avoids volume IO. Other engines vary — check before enlarging.
5. **`-USEALLAVAILABLECORES`** (Unreal Engine only) — task graph schedules across all visible CPUs. Drop for non-UE games.
6. **Pre-warmed steamcmd in the build** — first runtime `install` doesn't pay for bootstrap.
7. **Multi-stage build with BuildKit cache** — rebuild times drop from minutes to seconds when only scripts change.

---

## Things to revisit per-game

When porting this blueprint to a new game, expect to change:

- **App IDs** (installer + runtime) and how `steam_appid.txt` is laid out
- **Binary name and path** (Linux vs Windows binary, executable filename)
- **Server CLI flags** — every game has its own; check the official server guide
- **Backend / matchmaking URL** — must be exact
- **Required env vars** — game-specific keys (e.g. `CustomerKey`/`ProviderKey` for Last Oasis, `RCON_PASSWORD` for Rust, admin password / session token for Satisfactory)
- **Healthcheck protocol** — A2S works for Source games; others may need a custom probe
- **Resource sizing** — modern UE5 titles typically need 8–12 GB+ RAM where UE4 titles fit in 4–6 GB
- **Anonymous download support** — verify on Steam store page or community forums

Everything else (file structure, CLI shape, Compose layout, K8s patterns, CI/CD) should stay the same.
