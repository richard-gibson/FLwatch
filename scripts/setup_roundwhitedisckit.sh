#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
package_parent="$(cd "$repo_root/../.." && pwd)/GitHub"
package_path="$package_parent/RoundWhiteDiscKit"
expected_tree=fd4678042aaf1a1f4a231773b01d0a2694b1cf1b

if [[ -e "$package_path" || -L "$package_path" ]]; then
    if [[ -e "$package_path/.git" ]] &&
        [[ "$(git -C "$package_path" rev-parse 'HEAD^{tree}')" == "$expected_tree" ]] &&
        [[ -z "$(git -C "$package_path" status --porcelain)" ]]; then
        printf 'RoundWhiteDiscKit is ready at %s\n' "$package_path"
        exit 0
    fi
    printf 'Move the existing checkout at %s aside before running this setup.\n' "$package_path" >&2
    exit 1
fi

mkdir -p "$package_parent"
staging="$(mktemp -d "$package_parent/.RoundWhiteDiscKit.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT

git clone https://github.com/airedev326/RoundWhiteDiscKit.git "$staging/checkout"
git -C "$staging/checkout" switch -c flwatch-242 7dd6396f04371330d35799c88b9cba105a200180
git -C "$staging/checkout" fetch https://github.com/poml88/RoundWhiteDiscKit.git watchos-support
git -C "$staging/checkout" -c user.name=FLwatch -c user.email=flwatch@localhost \
    cherry-pick 28cc24652072237a001cc1f510d89bdf3e47a822 \
                fe2653df62a7dfccd4bb618018a993f4223c27f5 \
                a019d6af931cc52d25a9bc1ea877f810fce1f7a4 \
                aabc07070382932e34b832e6f2541bc6d4aeabd2
[[ "$(git -C "$staging/checkout" rev-parse 'HEAD^{tree}')" == "$expected_tree" ]]

# Reserve the destination without overwriting a checkout created during setup.
mkdir "$package_path"
mv "$staging/checkout/.git" "$package_path/"
git -C "$package_path" restore --source=HEAD --worktree -- :/
printf 'RoundWhiteDiscKit is ready at %s\n' "$package_path"
