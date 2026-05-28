# common.sh — logging, retry, trap helpers. Sourced by rs and other libs.
# No `set -e` here; the entry script owns strict mode so this stays sourceable.

RS_VERSION="${RS_VERSION:-0.1.0}"

# Colors only on TTY. Logs go to stderr so stdout stays clean for commands
# that want to pipe data (e.g. backup paths).
if [[ -t 2 ]]; then
  RS_RED=$'\033[31m'    ; RS_GREEN=$'\033[32m'  ; RS_YELLOW=$'\033[33m'
  RS_BLUE=$'\033[34m'   ; RS_CYAN=$'\033[36m'   ; RS_RESET=$'\033[0m'
else
  RS_RED='' ; RS_GREEN='' ; RS_YELLOW='' ; RS_BLUE='' ; RS_CYAN='' ; RS_RESET=''
fi

rs::log::_write() {
  local level=$1 color=$2 ; shift 2
  printf '%s %s%-5s%s rs: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$color" "$level" "$RS_RESET" "$*" >&2
}

rs::log::info()   { rs::log::_write INFO  "$RS_BLUE"   "$*"; }
rs::log::warn()   { rs::log::_write WARN  "$RS_YELLOW" "$*"; }
rs::log::error()  { rs::log::_write ERROR "$RS_RED"    "$*"; }
rs::log::ok()     { rs::log::_write OK    "$RS_GREEN"  "$*"; }
rs::log::action() { rs::log::_write RUN   "$RS_CYAN"   "$*"; }

rs::die() {
  rs::log::error "$*"
  exit 1
}

# Require an env var to be non-empty; fail loudly if it isn't.
rs::require() {
  local var=$1
  [[ -n "${!var:-}" ]] || rs::die "missing required env: $var"
}

# Retry with exponential backoff. Used for DepotDownloader (Steam CMS
# occasionally fails the first attempt against a cold license cache).
#
#   RS_RETRY_MAX     max attempts (default 5)
#   RS_RETRY_DELAY   initial delay seconds (default 5; doubles each attempt)
rs::retry() {
  local max=${RS_RETRY_MAX:-5}
  local delay=${RS_RETRY_DELAY:-5}
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    local rc=$?
    if (( attempt >= max )); then
      rs::log::error "command failed after $max attempts (exit $rc): $*"
      return "$rc"
    fi
    rs::log::warn "attempt $attempt/$max failed (exit $rc); retrying in ${delay}s"
    sleep "$delay"
    delay=$(( delay * 2 ))
    attempt=$(( attempt + 1 ))
  done
}

rs::version() {
  printf 'rs %s\n' "$RS_VERSION"
}
