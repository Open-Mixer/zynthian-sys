#!/bin/bash
#******************************************************************************
# scripts/omx-release-target.sh, the release tag update_zynthian.sh takes for
# one repository when the device follows the last stable release:
#
#   omx-release-target.sh [--fetch] <checkout> <stable branch>
#
# It prints one tag, the newest <stable branch>-* tag (version order) that
# passes, and exits 0; or prints nothing and exits 1, and the device stays
# where it is. The tags are the ones the checkout already has: the updater
# fetches them. Each tag refused is one line on stderr saying why.
#
# --fetch takes the fork's tags again first. The updater's own fetch
# (--all --prune-tags) keeps only the tags of the remote it fetched last, so
# in a checkout with upstream and the fork as remotes it can drop ours.
#
# A tag passes when it contains the tip the device runs, so an update never
# rewinds a device or drops work it has. In a checkout of the OpenMixer fork
# (a remote names it) the tag must also be a release of ours: the form
# <stable branch>-<release>-omx.<serial>, annotated, naming the repository,
# and signed by a key in keys/track-signing-keys.asc of this checkout of
# zynthian-sys. Whoever can push to the fork cannot move a device without that
# key. Maintainers make the tag with scripts/omx-release-tag.sh.
#******************************************************************************

FORK_URL_PATTERN=${FORK_URL_PATTERN:-Open-Mixer/\|FreeMixer/}
RELEASE_KEYS=${RELEASE_KEYS:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/keys/track-signing-keys.asc}
GIT=${GIT:-git}

fetch=0
if [ "$1" = --fetch ]; then
	fetch=1
	shift
fi
repo=${1:?usage: $0 [--fetch] <checkout> <stable branch>}
stable=${2:?usage: $0 [--fetch] <checkout> <stable branch>}
name=$(basename "$(cd "$repo" && pwd)")
say() { echo "$name: $*" >&2; }

head=$("$GIT" -C "$repo" rev-parse --verify -q HEAD) || { say "no commit checked out"; exit 1; }
short=$("$GIT" -C "$repo" rev-parse --short HEAD)

fork=0
for r in $("$GIT" -C "$repo" remote); do
	"$GIT" -C "$repo" remote get-url "$r" 2>/dev/null | grep -q "$FORK_URL_PATTERN" || continue
	fork=1
	if [ "$fetch" = 1 ]; then
		"$GIT" -C "$repo" fetch -q --tags --force "$r" || say "the tags of $r could not be fetched, using the ones here"
	fi
done

# The pinned keys: a keyring for gpgv and the primary fingerprints a good
# signature must come from
keyring=""
pinned=""
nokey=""
if [ "$fork" = 1 ]; then
	if ! command -v gpg >/dev/null || ! command -v gpgv >/dev/null; then
		nokey="gpg and gpgv are needed to check a signature (apt-get install gnupg)"
	elif [ ! -s "$RELEASE_KEYS" ]; then
		nokey="no pinned signing key at $RELEASE_KEYS"
	else
		keyring=$(mktemp)
		trap 'rm -f "$keyring"' EXIT
		gpg --batch --yes --dearmor <"$RELEASE_KEYS" >"$keyring" 2>/dev/null || nokey="no pinned signing key at $RELEASE_KEYS"
		pinned=$(gpg --batch --with-colons --import-options show-only --import <"$RELEASE_KEYS" 2>/dev/null |
			awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0}')
	fi
	if [ -n "$nokey" ]; then
		say "$nokey: no release tag is taken"
		exit 1
	fi
fi

# A release tag of ours, checked. <tag>
ours() {
	local tag=$1 body payload sig status fpr
	[[ $tag =~ ^"$stable"-.+-omx\.[0-9]+$ ]] || { say "$tag is not an OpenMixer release tag, not taken"; return 1; }
	[ "$("$GIT" -C "$repo" cat-file -t "refs/tags/$tag" 2>/dev/null)" = tag ] || { say "$tag is not an annotated tag, not taken"; return 1; }
	body=$("$GIT" -C "$repo" cat-file tag "refs/tags/$tag")
	if ! printf '%s\n' "$body" | grep -qx "tag $tag" ||
		! printf '%s\n' "$body" | grep -qx 'type commit' ||
		! printf '%s\n' "$body" | grep -qx "repository: $name"; then
		say "$tag does not name $name and itself, not taken"
		return 1
	fi
	payload=$(mktemp)
	sig=$(mktemp)
	printf '%s\n' "$body" | sed '/^-----BEGIN PGP SIGNATURE-----$/,$d' >"$payload"
	printf '%s\n' "$body" | sed -n '/^-----BEGIN PGP SIGNATURE-----$/,$p' >"$sig"
	status=$(gpgv --status-fd 1 --keyring "$keyring" "$sig" "$payload" 2>/dev/null)
	rm -f "$payload" "$sig"
	fpr=$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" {print $NF}')
	if [ -z "$fpr" ] || printf '%s\n' "$status" | grep -qE ' (BADSIG|ERRSIG|EXPKEYSIG|REVKEYSIG|EXPSIG) ' ||
		! printf '%s\n' "$pinned" | grep -qx "$fpr"; then
		say "$tag has no good signature by a pinned key, not taken"
		return 1
	fi
}

while read -r tag; do
	[ -n "$tag" ] || continue
	if ! "$GIT" -C "$repo" merge-base --is-ancestor "$head" "refs/tags/$tag^{commit}" 2>/dev/null; then
		say "$tag does not contain the tip this device runs ($short), not taken"
		continue
	fi
	if [ "$fork" = 1 ]; then
		ours "$tag" || continue
	fi
	echo "$tag"
	exit 0
done < <("$GIT" -C "$repo" tag -l "$stable-*" | sort -rV)
say "no release tag to take, staying on $short"
exit 1
