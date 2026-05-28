# backup.sh — tar.gz the save directory.
#
# Romestead's saves live under <INSTALL_DIR>/Worlds (the engine writes there
# regardless of AutoStartWorldName). We snapshot the whole subdir so backups
# also capture world-config json + screenshots the game generates per world.

rs::backup::create() {
  local install_dir="${INSTALL_DIR:-/mnt/steam/server-files}"
  local backup_dir="${BACKUP_DIR:-/mnt/steam/backups}"
  local save_subdir="${SAVE_SUBDIR:-Worlds}"
  local src="$install_dir/$save_subdir"

  [[ -d "$src" ]] || rs::die "no saves to back up at $src"

  mkdir -p "$backup_dir"
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  local out="$backup_dir/romestead-${stamp}.tar.gz"

  rs::log::action "backing up $src → $out"
  tar -C "$install_dir" -czf "$out" "$save_subdir"

  rs::log::ok "backup: $out ($(du -h "$out" | cut -f1))"
  # Stdout (not stderr) so callers can capture the path: PATH=$(rs backup | tail -1)
  printf '%s\n' "$out"
}
