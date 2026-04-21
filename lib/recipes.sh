#!/usr/bin/env bash
# ==================================================
# lib/recipes.sh — Scaffold recipe discovery & metadata
# ==================================================
#
# Recipes are pre-built stack blueprints (Dockerfile + compose + config)
# for common stack shapes — static-site, python-api, next-postgres, etc.
# Official recipes ship under $STRUT_HOME/templates/recipes/ and users
# can drop their own under $PROJECT_ROOT/.strut/recipes/.
#
# Recipe layout:
#   <recipe-name>/
#     recipe.conf        # metadata: NAME, DESCRIPTION, TAGS, ...
#     <stack files...>   # copied verbatim into stacks/<new-name>/
#
# During scaffold the recipe directory's contents (minus recipe.conf)
# are copied into stacks/<new-name>/ and run through the usual
# STACK_NAME_PLACEHOLDER / YOUR_ORG sed substitution so the same
# recipe works across projects.
#
# Precedence: user recipes in .strut/recipes/ override official recipes
# of the same name. This lets a team lock a custom "next-postgres" recipe
# without forking strut.
#
# Discovery is cheap (one readdir per source) and idempotent, so it's
# safe to re-run from tests that manipulate PROJECT_ROOT.

set -euo pipefail

# Parallel arrays (bash 3 compatible, matches lib/plugins.sh pattern).
_STRUT_RECIPE_NAMES=()
_STRUT_RECIPE_DIRS=()
_STRUT_RECIPE_SOURCES=()  # "official" or "user"

recipes_official_dir() {
  echo "${STRUT_HOME:-$CLI_ROOT}/templates/recipes"
}

recipes_user_dir() {
  echo "${PROJECT_ROOT:-$PWD}/.strut/recipes"
}

# recipes_discover — populate the recipe registry. User recipes win when
# names collide with official recipes.
recipes_discover() {
  _STRUT_RECIPE_NAMES=()
  _STRUT_RECIPE_DIRS=()
  _STRUT_RECIPE_SOURCES=()

  local official user
  official="$(recipes_official_dir)"
  user="$(recipes_user_dir)"

  local seen_names=""
  local dir src name entry
  for entry in "user:$user" "official:$official"; do
    src="${entry%%:*}"
    dir="${entry#*:}"
    [ -d "$dir" ] || continue

    local sub
    for sub in "$dir"/*/; do
      [ -d "$sub" ] || continue
      name="$(basename "$sub")"
      [ -n "$name" ] || continue
      # Skip if already registered (user wins, iterated first).
      case " $seen_names " in
        *" $name "*) continue ;;
      esac
      seen_names="$seen_names $name"
      _STRUT_RECIPE_NAMES+=("$name")
      _STRUT_RECIPE_DIRS+=("${sub%/}")
      _STRUT_RECIPE_SOURCES+=("$src")
    done
  done
}

# recipes_dir_for <name> — print the recipe directory, or return 1.
recipes_dir_for() {
  local want="$1" i
  local count="${#_STRUT_RECIPE_NAMES[@]}"
  [ "$count" -eq 0 ] && return 1
  for ((i = 0; i < count; i++)); do
    if [ "${_STRUT_RECIPE_NAMES[i]}" = "$want" ]; then
      printf '%s\n' "${_STRUT_RECIPE_DIRS[i]}"
      return 0
    fi
  done
  return 1
}

recipes_source_for() {
  local want="$1" i
  local count="${#_STRUT_RECIPE_NAMES[@]}"
  [ "$count" -eq 0 ] && return 1
  for ((i = 0; i < count; i++)); do
    if [ "${_STRUT_RECIPE_NAMES[i]}" = "$want" ]; then
      printf '%s\n' "${_STRUT_RECIPE_SOURCES[i]}"
      return 0
    fi
  done
  return 1
}

recipes_has() {
  recipes_dir_for "$1" >/dev/null 2>&1
}

# recipes_meta <name> <key> — read a field from the recipe's recipe.conf.
# Safe parser: only matches ^KEY=... lines, strips surrounding quotes.
# Prints empty string if the key or file is missing.
recipes_meta() {
  local name="$1" key="$2"
  local dir
  dir="$(recipes_dir_for "$name")" || return 0
  local conf="$dir/recipe.conf"
  [ -f "$conf" ] || return 0
  local line val
  line="$(grep -E "^${key}=" "$conf" | head -1 || true)"
  [ -n "$line" ] || return 0
  val="${line#*=}"
  # Strip surrounding single/double quotes.
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

# recipes_list_text — render discovered recipes as a table.
recipes_list_text() {
  local official user
  official="$(recipes_official_dir)"
  user="$(recipes_user_dir)"

  if [ "${#_STRUT_RECIPE_NAMES[@]}" -eq 0 ]; then
    echo ""
    echo "No recipes found."
    echo "  Official: $official"
    echo "  User:     $user"
    echo ""
    echo "Drop a recipe directory in either location and re-run to pick it up."
    echo ""
    return 0
  fi

  echo ""
  echo -e "${BLUE:-}Recipes:${NC:-}"
  echo ""
  out_table_header "Name" "Source" "Description"
  local i name src desc
  for i in "${!_STRUT_RECIPE_NAMES[@]}"; do
    name="${_STRUT_RECIPE_NAMES[i]}"
    src="${_STRUT_RECIPE_SOURCES[i]}"
    desc="$(recipes_meta "$name" DESCRIPTION)"
    [ -n "$desc" ] || desc="(no description)"
    out_table_row "$name" "$src" "$desc"
  done
  out_table_render
  echo ""
  echo "Scaffold with:  strut scaffold <stack-name> --recipe <name>"
  echo ""
}

# recipes_list_json — stream discovered recipes as JSON.
recipes_list_json() {
  out_json_object
    out_json_field "official_dir" "$(recipes_official_dir)"
    out_json_field "user_dir" "$(recipes_user_dir)"
    out_json_array "recipes"
    local i name dir src desc tags count="${#_STRUT_RECIPE_NAMES[@]}"
    for ((i = 0; i < count; i++)); do
      name="${_STRUT_RECIPE_NAMES[i]}"
      dir="${_STRUT_RECIPE_DIRS[i]}"
      src="${_STRUT_RECIPE_SOURCES[i]}"
      desc="$(recipes_meta "$name" DESCRIPTION)"
      tags="$(recipes_meta "$name" TAGS)"
      out_json_object
        out_json_field "name" "$name"
        out_json_field "source" "$src"
        out_json_field "description" "$desc"
        out_json_field "tags" "$tags"
        out_json_field "dir" "$dir"
      out_json_close_object
    done
    out_json_close_array
  out_json_close_object
  out_json_newline
}
