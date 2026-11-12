#!/bin/bash
#******************************************************************************
# scripts/omx-release-tag.sh, publish a release devices following the fork
# take with update_zynthian.sh: a signed annotated tag
# <branch>-<release>-omx.<serial> on a commit of zynthian-ui or zynthian-sys.
# <branch>-<release> is the upstream release the commit is built on
# (vangelis-2610), <serial> counts our releases on it from 1.
# scripts/omx-release-target.sh checks the tag against
# keys/track-signing-keys.asc before the updater moves a device.
#
#   omx-release-tag.sh <checkout> [<commit>] [--base <branch>-<release>]
#                      [--branch <stable branch>] [--key <key id>]
#                      [--push <remote>] [--name <repository>]
#
# <commit> defaults to the checkout's openmixer. --base defaults to the newest
# upstream tag of the stable branch that the commit contains; the stable
# branch defaults to the one in scripts/zynthian_envars_extended.sh. The tag
# message names the repository, read from the URL of the remote that points at
# the OpenMixer fork (or --name): a device refuses a tag naming another.
# The key defaults to git's user.signingkey; it must be one the key file
# pins, or devices will not take the tag.
#******************************************************************************
set -euo pipefail

usage() { echo "usage: $0 <checkout> [<commit>] [--base <branch>-<release>] [--branch <stable branch>] [--key <key id>] [--push <remote>] [--name <repository>]" >&2; exit 2; }
repo=""
commit=""
base=""
stable=""
key=""
push=""
name=""
while [ $# -gt 0 ]; do
	case "$1" in
		--base) base=${2:?}; shift 2 ;;
		--branch) stable=${2:?}; shift 2 ;;
		--key) key=${2:?}; shift 2 ;;
		--push) push=${2:?}; shift 2 ;;
		--name) name=${2:?}; shift 2 ;;
		-*) usage ;;
		*) if [ -z "$repo" ]; then repo=$1; elif [ -z "$commit" ]; then commit=$1; else usage; fi; shift ;;
	esac
done
[ -n "$repo" ] || usage
if [ -z "$name" ]; then
	for r in fork origin $(git -C "$repo" remote); do
		url=$(git -C "$repo" remote get-url "$r" 2>/dev/null) || continue
		case $url in *Open-Mixer/*|*FreeMixer/*) name=$(basename "${url%.git}"); break ;; esac
	done
fi
[ -n "$name" ] || { echo "no remote points at the OpenMixer fork: pass --name" >&2; exit 1; }
commit=$(git -C "$repo" rev-parse --verify "${commit:-openmixer}^{commit}")
key=${key:-$(git -C "$repo" config user.signingkey || true)}
[ -n "$key" ] || { echo "no signing key: pass --key or set user.signingkey" >&2; exit 1; }
if [ -z "$stable" ]; then
	stable=$(sed -n 's/^export ZYNTHIAN_STABLE_BRANCH="\(.*\)"/\1/p' "$(dirname "$(readlink -f "$0")")/zynthian_envars_extended.sh")
fi
[ -n "$stable" ] || { echo "no stable branch: pass --branch" >&2; exit 1; }
if [ -z "$base" ]; then
	while read -r t; do
		case $t in *-omx.*) continue ;; esac
		if git -C "$repo" merge-base --is-ancestor "refs/tags/$t^{commit}" "$commit"; then base=$t; break; fi
	done < <(git -C "$repo" tag -l "$stable-*" | sort -rV)
fi
[ -n "$base" ] || { echo "the commit contains no $stable-* release of upstream: pass --base" >&2; exit 1; }
case $base in "$stable"-?*) ;; *) echo "--base must be $stable-<release>" >&2; exit 1 ;; esac

serial=1
while git -C "$repo" rev-parse -q --verify "refs/tags/$base-omx.$serial" >/dev/null ||
	{ [ -n "$push" ] && git -C "$repo" ls-remote --exit-code --tags "$push" "$base-omx.$serial" >/dev/null; }; do
	serial=$((serial + 1))
done
tag=$base-omx.$serial

git -C "$repo" tag -s -u "$key" -m "repository: $name" -m "OpenMixer release $serial on $base: $(git -C "$repo" rev-parse --short "$commit")." "$tag" "$commit"
git -C "$repo" verify-tag "$tag" >/dev/null 2>&1 || { git -C "$repo" tag -d "$tag" >/dev/null; echo "the new tag does not verify, deleted" >&2; exit 1; }
echo "$tag $commit"
if [ -n "$push" ]; then
	git -C "$repo" push -q "$push" "refs/tags/$tag"
	echo "pushed $tag to $push"
fi
