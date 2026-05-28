# New-Game Bring-Up Checklist

Use this when porting the [`README.md`](README.md) blueprint to a new Steam dedicated server (Satisfactory, Rust, ARK, Valheim, Palworld, V Rising, Conan Exiles, …). Items marked with `[example: …]` are illustrative — replace with values for your game.

> Placeholders below match the blueprint: `<cli>` (your CLI name, e.g. `lo`, `sat`), `<game>` (short slug for image tags), `<game-dir>` (top-level install subdirectory, e.g. `Mist`, `FactoryGame`).

---

## Phase 0 — Discovery (before writing any code)

- [ ] **Steam app ID — installer**: which app does SteamCMD download? (search SteamDB)
- [ ] **Steam app ID — runtime**: does the engine need `steam_appid.txt` with a different id? (many games reuse the installer ID — verify, don't assume)
- [ ] **Anonymous download?** — try `steamcmd +login anonymous +app_info_print <ID> +quit` first; if it 401s, you need a real account
- [ ] **Branch toggle**: does the game have a `-beta <branch>` (experimental / test-live / staging)? If yes, plan for a `BRANCH` env var from day one.
      `[examples: Satisfactory public/experimental, Valheim public/public-test, Conan public/testlive]`
- [ ] **Server binary name + path** inside the install dir
      `[example: Mist/Binaries/Linux/MistServer-Linux-Shipping | FactoryGame/Binaries/Linux/FactoryServer-Linux-Shipping | RustDedicated]`
- [ ] **Default ports** — game UDP/TCP + Steam query UDP + any side channels (beacon, RCON, web admin, HTTPS management API)
- [ ] **Required CLI flags** — copy verbatim from the official server guide; don't paraphrase
- [ ] **Backend / matchmaking URL** — exact hostname (some games need a `-production` or region suffix; first-party-matchmaking games may have no URL at all)
- [ ] **Healthcheck protocol** — Source games = A2S; UE5/modern titles often have an HTTPS API (Satisfactory `/api/v1`); others may need a custom UDP/JSON-RPC probe — sniff with `wireshark` on the query port if undocumented
- [ ] **Settings surface** — does the game read config from one or more INI files (UE games typical)? If yes, plan for `scripts/lib/settings.sh` + `config/templates/*.ini.template`. If config is fully CLI-flag-driven (Last Oasis, Valheim), skip the INI generator.
- [ ] **Save data location** — **inside `<INSTALL_DIR>/<game-dir>/Saved/`** or **under `$HOME` at a fixed relative path** (e.g. Satisfactory writes to `$HOME/.config/Epic/FactoryGame/Saved`)? This decides multi-server volume strategy — see [`README.md → Multi-server`](README.md#multi-server-on-one-host-shared-vs-per-server-volume).
- [ ] **Realistic player count + RAM/CPU per slot** — sets compose resource caps (UE4 ≈ 4–6 GB typical, UE5 ≈ 8–12 GB+)
- [ ] **UE5 cold-boot time** — if the game uses UE5, plan for 2–4 minute startup (Compose `start_period: 300s`, K8s `startupProbe.failureThreshold: 60` at 10s period)
- [ ] **License / EULA** — some games require accepting on first run (e.g. ARK, Conan Exiles)
- [ ] **Admin auth pattern** — is the admin password set via env, INI key, or in-game (Server Manager) on first connect? Determines what belongs in the Secret vs the volume.

---

## Phase 1 — Scaffolding (~30 min)

- [ ] Copy the file tree from [`README.md → Canonical file structure`](README.md#canonical-file-structure)
- [ ] Rename the CLI: `scripts/<reference-cli>` → `scripts/<cli>`
      `[example: scripts/lo → scripts/sat, scripts/rust, scripts/pal]`
- [ ] Update internal namespace: `<reference-cli>::*` → `<cli>::*` (sed across `scripts/lib/`)
      `[example: sed -i 's/lo::/sat::/g; s/LO_/SAT_/g' scripts/lib/*.sh]`
- [ ] Set `IMAGE` in `Makefile` to `ghcr.io/<org>/<game>-docker`
- [ ] Set GHCR target in `.github/workflows/release.yml` (auto-derives from `${{ github.repository }}` if the repo name matches)
- [ ] Replace the reference banner image with the new game's banner (`<game>-logo.{jpg,png}`)
- [ ] Add `.gitattributes` with `* text=auto eol=lf` + binary excludes — silences "LF will be replaced by CRLF" on Windows porters' commits

---

## Phase 2 — Container plumbing

- [ ] **Dockerfile**: change `STEAM_APP_ID` ARG defaults if you want them baked in; keep `HOME=/mnt/steam`, `UID 1000 GID 1001`, `tini`, `python3-minimal`
- [ ] **Add game-specific apt deps** if the engine needs them (e.g. `libsdl2-2.0-0` for some titles)
- [ ] **healthcheck.py**: if not Source-engine, swap the probe payload + reply check
- [ ] **scripts/lib/steam.sh**: confirm `+@ShutdownOnFailedCommand 1`, `+@NoPromptForPassword 1`, `+app_license_request` are present
- [ ] **scripts/lib/server.sh**:
  - [ ] Set the binary path constant
  - [ ] Update the built-in CLI flags to match the official guide
  - [ ] Keep `_link_steamclient` and `LD_LIBRARY_PATH` export (needed for any Steam-SDK engine)
  - [ ] Keep `ulimit -n 65536` and `renice -n -5`
  - [ ] If the game has a `-beta` branch toggle: thread `BRANCH` through `steam.sh` (`+app_update <ID> -beta "$BRANCH"`)
- [ ] **scripts/lib/settings.sh** (only if the game reads from INI files):
  - [ ] One `<cli>::settings::_apply_defaults` function with `export VAR=${VAR:-default}` for every `$VAR` referenced in templates
  - [ ] Per-template `_render` helper using `envsubst`
  - [ ] Public `<cli>::settings::compile` called from `server::run`
  - [ ] Respect `GENERATE_SETTINGS=false` (keep hand-edits; still patch hot keys like `MaxPlayers` in place)
- [ ] **config/templates/*.ini.template** (only if using INI generation): one per file the game reads — see [`README.md → Game settings generation`](README.md#game-settings-generation-ini-templates--envsubst)
- [ ] **scripts/lib/backup.sh**: point `src=` at the game's save dir (in install dir or under `$HOME` — see Phase 0)

---

## Phase 3 — Config + compose

- [ ] **config/defaults.env**: set `STEAM_APP_ID` (installer), `STEAM_RUNTIME_APP_ID` (omit/equal-to-installer when single-ID), `INSTALL_DIR=/mnt/steam/<game-dir>`, `BACKUP_DIR=/mnt/steam/backups`
- [ ] **config/server.example.env**: list every required env var with a comment explaining where to get it (link to the game's admin panel / Steam guide / community wiki)
- [ ] **compose/docker-compose.yml**: update port mappings + `deploy.resources` to match the game's spec
- [ ] **compose/docker-compose.multi.yml** if multi-server is in scope:
  - Save-in-install-dir games: one shared volume across all server services
  - Save-in-`$HOME` games: one volume **per** server service — sharing clobbers worlds silently

---

## Phase 4 — Kubernetes

- [ ] **k8s/secret.example.yaml**: list all env vars from `server.example.env`
- [ ] **k8s/install-job.yaml + deployment.yaml + backup-cronjob.yaml**: update `containerPort` / `hostPort`, resource requests/limits, healthcheck command if changed
- [ ] **k8s/pvc.yaml**: size for the game's install footprint + saves headroom
- [ ] **k8s/README.md**: copy the structure, swap the reference game slug → `<game>` and update the resource name examples
- [ ] Keep `fix-permissions` initContainer, `SYS_NICE` capability, `hostNetwork: true`, `Recreate` strategy

---

## Phase 5 — CI / release

- [ ] **.github/workflows/ci.yml**: smoke tests pass (`<cli> version`, `<cli> help`)
- [ ] **.github/workflows/*.yml**: quote `"on":` so yamllint's `truthy` rule stays silent (YAML 1.1 reads bare `on` as boolean `true`)
- [ ] Do NOT set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` — it produces a "Node.js 20 is deprecated" warning on every JS action; GitHub will auto-migrate when Node 20 is removed (late 2026)
- [ ] **.github/workflows/release.yml**: tag a `v0.1.0` to dry-run the publish (delete the package after if needed)
- [ ] **README.md**: top-of-repo banner, quick start, configuration table, performance tuning, and (if the game has one) a link to its admin/management portal
      `[examples: MyRealm for Last Oasis, Server Manager for Satisfactory, RustAdmin for Rust]`
- [ ] **LICENSE**: keep MIT or pick something compatible with upstream's license if you derived from one — credit them

---

## Phase 6 — Verification

- [ ] `make build` succeeds locally
- [ ] `docker compose --profile maintenance run --rm install` downloads game files into `/mnt/steam`
- [ ] `docker compose --profile maintenance run --rm --entrypoint=bash install -c "ls /mnt/steam/<game-dir>/Binaries/Linux/"` confirms the binary exists
- [ ] `docker compose up -d server` starts; `docker compose ps` shows `healthy` within `start_period`
- [ ] External player can connect to `SERVER_IP_ADDRESS:SERVER_PORT`
- [ ] The server appears in the game's matchmaking / browser (this catches backend-URL typos — skip for join-code-only games)
- [ ] `docker compose --profile maintenance run --rm backup` produces a tarball
- [ ] On K8s: install Job completes, Deployment becomes Ready, port-forward proves the healthcheck probe responds

---

## Common time-sinks (in order of likelihood)

1. **Wrong app ID for `app_update`** — always installer ID, not runtime ID → `Invalid platform`
2. **Backend URL typo / missing suffix** — server runs fine but invisible
3. **Volume path mismatch** — image vs PVC mount; install "succeeds" but binary not found
4. **Save-in-`$HOME` games sharing a multi-server volume** — second server silently clobbers the first's world
5. **UID/GID mismatch with existing PVC** — permission errors after first restart
6. **Missing `steam_appid.txt`** — engine refuses to start, "App not registered" in logs
7. **Anonymous download forbidden** — need to switch `STEAM_USER` to an owning account
8. **Forgot `+app_license_request`** — first run fails with "Missing configuration"
9. **`envsubst` over an INI template with an unset var** — output contains the literal `$VAR` placeholder; broken INI lines on first start. Fix by setting defaults in `settings.sh` rather than only in `defaults.env`.
10. **UE5 startup timing out** — `startupProbe.failureThreshold` left at default; raise to 60 (with `periodSeconds: 10`) for the first cold boot.
11. **yamllint `truthy` on `on:`** — quote workflow trigger as `"on":`
12. **`FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`** — produces a deprecation warning every CI run; just don't set it
13. **CRLF noise on Windows commits** — missing `.gitattributes` with `* text=auto eol=lf`
14. **shellcheck `source-path=SCRIPTDIR` not set** — CI fails to follow `# shellcheck source=lib/...`
15. **hadolint DL4006** — pipe in `RUN` without `SHELL ... pipefail`
16. **yamllint default rules** — too strict for inline-map k8s style; relax `braces`/`colons`/`commas` in CI
