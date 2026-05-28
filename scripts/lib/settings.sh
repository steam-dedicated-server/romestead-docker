# settings.sh — render Romestead's config.json from env vars.
#
# Romestead reads <INSTALL_DIR>/config.json at startup. Unlike UE games this
# isn't INI, and one field (AutoCreateWorldSeed) needs JSON `null` vs string
# logic that envsubst can't express cleanly — so we generate the JSON in bash
# instead of using a template.

rs::settings::_apply_defaults() {
  export AUTO_START_WORLD_NAME="${AUTO_START_WORLD_NAME:-}"
  export AUTO_CREATE_AND_LOAD_WORLD="${AUTO_CREATE_AND_LOAD_WORLD:-true}"
  export AUTO_CREATE_WORLD_SIZE="${AUTO_CREATE_WORLD_SIZE:-1}"
  export AUTO_CREATE_WORLD_SEED="${AUTO_CREATE_WORLD_SEED:-null}"
  export PASSWORD="${PASSWORD:-}"
  export PORT="${PORT:-8050}"
  export MAX_PLAYERS="${MAX_PLAYERS:-8}"
  export ENABLE_CHEATS="${ENABLE_CHEATS:-false}"
}

# Minimal JSON-string escape for free-form env vars (world name / password).
# Replaces backslash and double-quote; control chars are unlikely in practice
# and the game would reject them anyway.
rs::settings::_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

rs::settings::_write_config() {
  local dest=$1
  local seed_json
  if [[ -n "${AUTO_CREATE_WORLD_SEED:-}" && "$AUTO_CREATE_WORLD_SEED" != "null" ]]; then
    seed_json="\"$(rs::settings::_json_escape "$AUTO_CREATE_WORLD_SEED")\""
  else
    seed_json="null"
  fi

  cat > "$dest" <<EOF
{
  "AutoStartWorldName": "$(rs::settings::_json_escape "$AUTO_START_WORLD_NAME")",
  "AutoCreateAndLoadWorld": ${AUTO_CREATE_AND_LOAD_WORLD},
  "AutoCreateWorldSize": ${AUTO_CREATE_WORLD_SIZE},
  "AutoCreateWorldSeed": ${seed_json},
  "Password": "$(rs::settings::_json_escape "$PASSWORD")",
  "Port": ${PORT},
  "MaxPlayers": ${MAX_PLAYERS},
  "EnableCheats": ${ENABLE_CHEATS}
}
EOF
}

rs::settings::compile() {
  local install_dir="${INSTALL_DIR:-/mnt/steam/server-files}"
  local config_path="$install_dir/config.json"

  if [[ "${GENERATE_SETTINGS:-true}" == "false" ]]; then
    rs::log::warn "GENERATE_SETTINGS=false — preserving existing $config_path"
    [[ -f "$config_path" ]] || rs::die "GENERATE_SETTINGS=false but $config_path does not exist"
    return 0
  fi

  mkdir -p "$install_dir"
  rs::settings::_apply_defaults
  rs::settings::_write_config "$config_path"
  rs::log::ok "wrote $config_path"
}
