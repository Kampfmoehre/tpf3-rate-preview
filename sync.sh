#!/bin/bash
# Copies the mod into Transport Fever 3's staging area, where the game picks up
# mods under development (and from where the in-game Mod-Hub uploads them).
#
# Usage: ./sync.sh            (auto-detects the Steam user directory)
#        TF3_LOCAL=/path/to/userdata/<id>/3493540/local ./sync.sh
set -euo pipefail

MOD_ID="kampfmoehre_rate_preview_1"
SRC="$(dirname "$(readlink -f "$0")")/$MOD_ID"

if [ -z "${TF3_LOCAL:-}" ]; then
	candidates=("$HOME"/.local/share/Steam/userdata/*/3493540/local)
	if [ ${#candidates[@]} -ne 1 ] || [ ! -d "${candidates[0]}" ]; then
		echo "Could not determine the TF3 user directory, set TF3_LOCAL=.../userdata/<id>/3493540/local" >&2
		exit 1
	fi
	TF3_LOCAL="${candidates[0]}"
fi

DST="$TF3_LOCAL/staging_area/$MOD_ID"
mkdir -p "$DST"
# Keep what the game generates inside the staging copy: the cooked upload
# packages and the link to the mod's mod.io id.
rsync -a --delete --exclude=".cooked_*" --exclude="_metadata/mod.io_fileid.txt" "$SRC/" "$DST/"
echo "synced -> $DST"
