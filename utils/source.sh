source_modules() {
  local module
  for module in "$@"; do
    # shellcheck source=/dev/null
    source "$ROOT_DIR/$module" || return
  done
}
