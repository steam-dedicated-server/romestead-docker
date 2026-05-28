# romestead-docker

Production-tuned Docker / Compose / Kubernetes packaging of the **Romestead** dedicated server. One image, three deploy targets, single CLI inside the container.

> Built on the [Steam-dedicated-server blueprint](.claude/blueprint/README.md). The bring-up patterns were first proven on [last-oasis-docker](https://github.com/steam-dedicated-server/last-oasis-docker), and adapted here for Romestead's DepotDownloader + .NET stack — credit to [indifferentbroccoli/romestead-server-docker](https://github.com/indifferentbroccoli/romestead-server-docker) for the original .NET + DepotDownloader recipe.

## What you get

- **Multi-stage Dockerfile** (Ubuntu 24.04, .NET 8 runtime, DepotDownloader pre-fetched) → ~1.2 GB image
- **`rs` CLI** inside the image: `install` · `update` · `run` · `backup` · `send` · `health` · `config`
- **A2S healthcheck** on UDP 8050 (the same probe player browsers use — catches a server with the process alive but the network loop frozen)
- **Compose** single-server + multi-realm skeletons with seccomp/ulimits/resource caps tuned
- **Kubernetes** bundle: PVC, install Job, single-replica Deployment with hostNetwork, daily backup CronJob
- **CI/CD**: shellcheck + hadolint + yamllint on every PR; GHCR publish with SBOM + provenance on `v*.*.*` tags

## Quick start (Docker Compose)

```bash
# 1. Copy and edit env
cp config/server.example.env config/server.env
$EDITOR config/server.env   # set PASSWORD at minimum

# 2. Pull the image (or `make build` to build locally)
docker compose -f compose/docker-compose.yml pull

# 3. First-time install (downloads ~3 GB of game files)
make install

# 4. Start the server
make run

# 5. Watch it come up
make logs
```

The server binds **UDP 8050** by default. Open that port on your firewall and players can connect to `<host>:8050`.

## Quick start (Kubernetes)

See [`k8s/README.md`](k8s/README.md) — `kubectl apply -k k8s/` after populating the Secret.

## Configuration

Every knob lives in [`config/server.example.env`](config/server.example.env). The most-touched ones:

| Variable | Default | What it controls |
|---|---|---|
| `PASSWORD` | *(empty)* | Server password. Empty = public. |
| `PORT` | `8050` | Game + Steam query UDP port |
| `MAX_PLAYERS` | `8` | Player slot cap |
| `AUTO_START_WORLD_NAME` | *(empty)* | Load this saved world by name. Empty = auto-create. |
| `AUTO_CREATE_WORLD_SIZE` | `1` | `1` small, `2` medium, `3` large (used only on auto-create) |
| `AUTO_CREATE_WORLD_SEED` | `null` | `null` = random, or quote a string for fixed |
| `ENABLE_CHEATS` | `false` | Admin cheats; leave off for public servers |
| `UPDATE_ON_START` | `true` | Re-validate depot every restart (fast when nothing changed) |
| `BRANCH` | `public` | Plumbing for a future beta channel — no current effect |
| `GENERATE_SETTINGS` | `true` | Set `false` to keep hand-edits to `config.json` |
| `STEAM_USER` | `anonymous` | Switch to an owning account if anonymous downloads break |

Precedence (highest wins): shell env → `config/server.env` → `config/defaults.env`.

## Day-to-day operations

```bash
# Update the depot (no-op when up to date)
make update

# Backup the save dir (Worlds/) to /mnt/steam/backups
make backup

# Send a console command into the running server
docker compose -f compose/docker-compose.yml exec server rs send save
docker compose -f compose/docker-compose.yml exec server rs send "kick <player>"
docker compose -f compose/docker-compose.yml exec server rs send stop

# Open a shell inside the container
make shell

# Probe the healthcheck manually
docker compose -f compose/docker-compose.yml exec server rs health
```

## Performance tuning

Defaults are tuned for ~16 concurrent players on a 4-core / 6 GB box. Larger realms:

| Knob | Where | Recommendation |
|---|---|---|
| `deploy.resources.limits` | `compose/docker-compose.yml` | Bump CPU+RAM proportionally to slot count |
| `ulimits.nofile` | `compose/docker-compose.yml` | Already `1048576` — don't lower |
| `seccomp:unconfined` | `compose/docker-compose.yml` | Required; do not remove |
| `tmpfs: /tmp:size=256m` | `compose/docker-compose.yml` | Bump if you see "no space left on device" |

## Project layout

```
docker/        Dockerfile + healthcheck.py
scripts/       `rs` CLI + lib modules (sourced bash)
config/        defaults.env + server.example.env
compose/       single-server + multi-realm Compose files
k8s/           PVC / install Job / Deployment / backup CronJob / Secret template
.github/       CI + release workflows
.claude/       blueprint + new-game checklist (lives with the repo for reference)
```

For the design rationale behind each pattern (UID/GID, mount path, seccomp, etc.), read [`.claude/blueprint/README.md`](.claude/blueprint/README.md).

## License

MIT — see [`LICENSE`](LICENSE). Romestead is a trademark of its respective owner; this project is community-maintained and not affiliated with the game's developer.
