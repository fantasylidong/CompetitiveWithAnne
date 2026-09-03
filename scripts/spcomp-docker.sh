#!/usr/bin/env bash
set -euo pipefail

# Compiles a SourcePawn plugin on a Linux x86-64 host.
#
# Backends (pick with SPCOMP_BACKEND, default "ssh"):
#   ssh    - run spcomp64 natively on $SPCOMP_SSH_HOST (default: pve-yma).
#   docker - run inside ubuntu:22.04 through the current docker context.
#
# Either way the scripting tree is streamed to the remote side over stdin (tar)
# and the compiled .smx comes back over stdout, so no shared filesystem or bind
# mount is required. This matters because our docker context usually points at
# a remote daemon whose bind mounts would refer to *its* filesystem, not this
# checkout.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripting_dir="addons/sourcemod/scripting"
backend="${SPCOMP_BACKEND:-ssh}"
ssh_host="${SPCOMP_SSH_HOST:-pve-yma}"

if [[ $# -lt 1 ]]; then
  echo "Usage: scripts/spcomp-docker.sh <plugin.sp> [output.smx]" >&2
  echo "When output is omitted, the plugin is written under addons/sourcemod/plugins." >&2
  exit 2
fi

source_file="$1"
if [[ "$source_file" = "$repo_root/"* ]]; then
  source_rel="${source_file#"$repo_root"/}"
else
  source_rel="$source_file"
fi

if [[ "$source_rel" != "$scripting_dir/"*.sp ]]; then
  echo "Source file must be under $scripting_dir: $source_file" >&2
  exit 2
fi

source_in_scripting="${source_rel#"$scripting_dir"/}"
source_dir_in_scripting="$(dirname "$source_in_scripting")"
source_file="$(basename "$source_in_scripting")"
plugin_name="$(basename "$source_in_scripting" .sp)"

default_plugin_rel_for_source() {
  local source_path="$1"
  local name="$2"

  # Project sources mirror addons/sourcemod/plugins/. Upstream SourceMod stock
  # sources are kept under scripting/sourcemod/ and map back to root/disabled.
  if [[ "$source_path" == sourcemod/* ]]; then
    if [[ -f "$repo_root/addons/sourcemod/plugins/$name.smx" ]]; then
      printf '%s.smx\n' "$name"
      return
    fi
    if [[ -f "$repo_root/addons/sourcemod/plugins/disabled/$name.smx" ]]; then
      printf 'disabled/%s.smx\n' "$name"
      return
    fi
    printf '%s.smx\n' "$name"
    return
  fi

  printf '%s.smx\n' "${source_path%.sp}"
}

local_output_for_arg() {
  local output_path="$1"

  if [[ "$output_path" = /* ]]; then
    printf '%s\n' "$output_path"
  elif [[ "$output_path" == ./* ]]; then
    printf '%s/%s\n' "$repo_root" "${output_path#./}"
  elif [[ "$output_path" == addons/* || "$output_path" == cfg/* || "$output_path" == scripts/* ]]; then
    printf '%s/%s\n' "$repo_root" "$output_path"
  else
    printf '%s/%s/%s\n' "$repo_root" "$scripting_dir" "$output_path"
  fi
}

if [[ $# -ge 2 ]]; then
  output="$(local_output_for_arg "$2")"
else
  output="$repo_root/addons/sourcemod/plugins/$(default_plugin_rel_for_source "$source_in_scripting" "$plugin_name")"
fi

container_source_dir="/work/$scripting_dir"
if [[ "$source_dir_in_scripting" != "." ]]; then
  container_source_dir="$container_source_dir/$source_dir_in_scripting"
fi

include_args=(
  -i/work/$scripting_dir
  -i/work/$scripting_dir/include
  -i/work/$scripting_dir/sourcemod/include
  -i/work/$scripting_dir/confoglcompmod/include
  -i/work/$scripting_dir/confoglcompmod/includes
  -i/work/$scripting_dir/archive/include
  -i/work/$scripting_dir/archive/includes
  -i/work/$scripting_dir/optional
  -i/work/$scripting_dir/optional/AnneHappy
  -i/work/$scripting_dir/extend
  -i/work/$scripting_dir/include/multicolors
  -i/work/$scripting_dir/include/ripext
)

mkdir -p "$(dirname "$output")"
tmp_output="$(mktemp "${TMPDIR:-/tmp}/spcomp.XXXXXX.smx")"
trap 'rm -f "$tmp_output"' EXIT

# Runs on the remote side with the scripting tarball on stdin. Extracts into a
# throwaway dir that is bind-independent: paths are rewritten so "/work" in the
# include args resolves inside it. Compiler chatter goes to stderr; stdout
# carries the binary .smx back.
remote_script='
set -euo pipefail
source_dir="$1"
source_file="$2"
shift 2

work="$(mktemp -d /tmp/spcomp.XXXXXX)"
trap "rm -rf \"$work\"" EXIT
tar xf - -C "$work" 2>/dev/null

args=()
for a in "$@"; do args+=("${a//\/work\//$work/}"); done
source_dir="${source_dir//\/work\//$work/}"

chmod +x "$work/'"$scripting_dir"'/sourcemod/spcomp64"
cd "$source_dir"
"$work/'"$scripting_dir"'/sourcemod/spcomp64" "$source_file" "${args[@]}" -o"$work/plugin.smx" 1>&2
cat "$work/plugin.smx"
'

remote_cmd=(bash -c "$remote_script" _ "$container_source_dir" "$source_file" "${include_args[@]}")

case "$backend" in
  ssh)
    # ssh flattens argv into one remote command line, so quote each word.
    quoted=""
    for w in "${remote_cmd[@]}"; do quoted+=" $(printf '%q' "$w")"; done
    runner=(ssh -o BatchMode=yes "$ssh_host" "$quoted")
    ;;
  docker)
    runner=(docker run --rm -i --platform linux/amd64 ubuntu:22.04 "${remote_cmd[@]}")
    ;;
  *)
    echo "Unknown SPCOMP_BACKEND: $backend (expected ssh or docker)" >&2
    exit 2
    ;;
esac

# COPYFILE_DISABLE stops macOS bsdtar from emitting AppleDouble/xattr entries
# that GNU tar on the remote side would warn about.
COPYFILE_DISABLE=1 tar -C "$repo_root" -cf - "$scripting_dir" | "${runner[@]}" > "$tmp_output"

if [[ ! -s "$tmp_output" ]]; then
  echo "Compile produced no output: $source_rel" >&2
  exit 1
fi

chmod 644 "$tmp_output"
mv "$tmp_output" "$output"
trap - EXIT
echo "Wrote $output" >&2
