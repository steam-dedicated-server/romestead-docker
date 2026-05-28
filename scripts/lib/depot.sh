# depot.sh — DepotDownloader wrapper.
#
# Romestead's dedicated server depot (app 4763510) is not accessible via
# steamcmd's anonymous license at time of writing, so we use DepotDownloader
# — which also handles the depot manifest more directly. Both anonymous and
# owning-account downloads are supported; flip via STEAM_USER.

RS_DEPOT_BIN="${RS_DEPOT_BIN:-/usr/local/bin/DepotDownloader}"

rs::depot::_args() {
  local -a args=(
    -app "${STEAM_APP_ID:-4763510}"
    -dir "${INSTALL_DIR:-/mnt/steam/server-files}"
    -validate
  )

  # Branch toggle — Romestead has no public beta channel today, but bake the
  # plumbing in so adding one later is a single env-var change.
  if [[ -n "${BRANCH:-}" && "$BRANCH" != "public" ]]; then
    args+=(-branch "$BRANCH")
    [[ -n "${BRANCH_PASSWORD:-}" ]] && args+=(-branchpassword "$BRANCH_PASSWORD")
  fi

  # Auth. Default = anonymous (DepotDownloader's implicit mode when -username
  # is omitted). Set STEAM_USER to download with an owning account; password
  # + 2FA are read from STEAM_PASSWORD / STEAM_GUARD_CODE on first run and
  # DepotDownloader caches the session token in INSTALL_DIR/.DepotDownloader
  # for subsequent runs.
  if [[ -n "${STEAM_USER:-}" && "$STEAM_USER" != "anonymous" ]]; then
    args+=(-username "$STEAM_USER")
    [[ -n "${STEAM_PASSWORD:-}" ]] && args+=(-password "$STEAM_PASSWORD")
    [[ -n "${STEAM_GUARD_CODE:-}" ]] && args+=(-remember-password)
  fi

  printf '%s\n' "${args[@]}"
}

rs::depot::_run() {
  local -a args
  mapfile -t args < <(rs::depot::_args)

  mkdir -p "${INSTALL_DIR:-/mnt/steam/server-files}"

  rs::log::action "DepotDownloader: app ${STEAM_APP_ID:-4763510} → ${INSTALL_DIR:-/mnt/steam/server-files}"
  rs::retry "$RS_DEPOT_BIN" "${args[@]}"
}

rs::depot::install() {
  rs::depot::_run
  rs::log::ok "install complete"
}

rs::depot::update() {
  rs::depot::_run
  rs::log::ok "update complete"
}
