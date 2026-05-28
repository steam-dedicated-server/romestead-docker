# server.sh — server lifecycle: install-if-missing, render config, exec dotnet.

RS_FIFO="${RS_FIFO:-/tmp/romestead-stdin}"
RS_BINARY="${RS_BINARY:-Server.dll}"

rs::server::_prep_runtime() {
  local install_dir="${INSTALL_DIR:-/mnt/steam/server-files}"

  # GameAnalytics writes telemetry under $HOME on first run — create the dir
  # ahead of time so a read-only homedir (e.g. some K8s setups) doesn't crash
  # the engine.
  mkdir -p "$HOME/.local/share/GameAnalytics"

  # Engine ships native libs alongside the managed dlls; prepend both
  # locations so dotnet's P/Invoke loader finds them.
  export LD_LIBRARY_PATH="${install_dir}:${install_dir}/linux64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

  # File-descriptor headroom for player connections. nofile is set in the
  # compose/k8s spec too; this is defense-in-depth for ad-hoc `docker run`.
  ulimit -n 65536 2>/dev/null || true
}

# Stdin pipe — Romestead's server reads console commands ('save', 'stop',
# 'kick', 'ban') from stdin. We open a FIFO so external processes can pump
# commands in without holding the server's stdin open.
rs::server::_open_fifo() {
  rm -f "$RS_FIFO"
  mkfifo "$RS_FIFO"
  # Keep an FD open on the write end so the FIFO doesn't close when no one
  # is writing. FD 3 stays open for the lifetime of this shell.
  exec 3<>"$RS_FIFO"
}

# Graceful shutdown — send 'stop' through the FIFO, then wait up to
# STOP_GRACE_SECONDS for the engine to flush saves before SIGKILL.
rs::server::_install_traps() {
  local stop_grace=${STOP_GRACE_SECONDS:-30}
  trap '
    rs::log::warn "received shutdown signal; sending stop to engine"
    echo stop >&3 2>/dev/null || true
    for _ in $(seq 1 '"$stop_grace"'); do
      kill -0 "$RS_ENGINE_PID" 2>/dev/null || break
      sleep 1
    done
  ' TERM INT
}

rs::server::run() {
  local install_dir="${INSTALL_DIR:-/mnt/steam/server-files}"
  local binary_path="$install_dir/$RS_BINARY"

  # Auto-install on first boot. UPDATE_ON_START=true (default) also re-runs
  # DepotDownloader on every restart — fast when nothing's changed, cheap
  # insurance against a half-finished previous install.
  if [[ ! -f "$binary_path" ]]; then
    rs::log::warn "$binary_path missing — running first-time install"
    rs::depot::install
  elif [[ "${UPDATE_ON_START:-true}" == "true" ]]; then
    rs::log::info "UPDATE_ON_START=true — refreshing depot before launch"
    rs::depot::update
  fi

  [[ -f "$binary_path" ]] || rs::die "server binary not found at $binary_path (install failed?)"

  rs::settings::compile
  rs::server::_prep_runtime
  rs::server::_open_fifo

  cd "$install_dir" || rs::die "cannot cd into $install_dir"
  rs::log::action "starting Romestead dedicated server on UDP ${PORT:-8050}"

  # Background the engine so this shell stays alive to handle signals.
  # `exec <"$RS_FIFO"` would block until a writer connects; using `< &3` reads
  # from our already-open FIFO without that handshake.
  dotnet "$RS_BINARY" <&3 &
  RS_ENGINE_PID=$!
  export RS_ENGINE_PID

  rs::server::_install_traps
  wait "$RS_ENGINE_PID"
}

# rs send <command> — pipe an in-game console command into the running server.
# Useful for cron-driven 'save' or admin 'kick'/'ban' from outside the container.
rs::server::send() {
  (( $# > 0 )) || rs::die "rs send: missing command"
  [[ -p "$RS_FIFO" ]] || rs::die "rs send: $RS_FIFO does not exist — server not running?"
  printf '%s\n' "$*" > "$RS_FIFO"
  rs::log::ok "sent: $*"
}
