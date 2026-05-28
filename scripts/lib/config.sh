# config.sh — load defaults.env, then server.env, then shell env (highest wins).
# Re-export so any child process (DepotDownloader, dotnet) inherits values.

# Baked-into-image defaults (committed in the repo, copied into
# /home/steam/server/config/defaults.env at build time).
RS_DEFAULTS_FILE="${RS_DEFAULTS_FILE:-$RS_BIN_DIR/config/defaults.env}"

# Operator overrides — typically lives on the persistent volume so it survives
# image rebuilds. Compose / K8s pass values via env_file / Secret too; either
# wins because shell env beats both.
RS_SERVER_ENV_FILE="${RS_SERVER_ENV_FILE:-/mnt/steam/server.env}"

rs::config::_source() {
  local file=$1
  [[ -f "$file" ]] || return 0
  set -o allexport
  # shellcheck disable=SC1090
  source "$file"
  set +o allexport
}

rs::config::load() {
  rs::config::_source "$RS_DEFAULTS_FILE"
  rs::config::_source "$RS_SERVER_ENV_FILE"
}
