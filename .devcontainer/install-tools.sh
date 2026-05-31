#!/usr/bin/env bash
#
# install-tools.sh — install the modern CLI toolbelt that isn't packaged in
# Debian bookworm apt. Runs at BUILD time as root (network unrestricted).
#
# Strategy:
#   * Rust tools  -> cargo-binstall (resolves the correct prebuilt release asset
#                    per crate/arch automatically; no rustc/compile needed).
#   * Go binaries -> direct GitHub release download (yq, lazygit).
# Everything lands in /usr/local/bin so it's on PATH for every user.
set -euo pipefail

DPKG_ARCH="$(dpkg --print-architecture)"   # arm64 | amd64
case "$DPKG_ARCH" in
    arm64) GO_ARCH=arm64; LG_ARCH=arm64 ;;
    amd64) GO_ARCH=amd64; LG_ARCH=x86_64 ;;
    *) echo "ERROR: unsupported arch ${DPKG_ARCH}" >&2; exit 1 ;;
esac

echo "==> Installing cargo-binstall"
curl -L --proto '=https' --tlsv1.2 -sSf \
    https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
export PATH="${HOME}/.cargo/bin:${PATH}"

echo "==> Installing Rust CLI tools via cargo-binstall"
# crate names: du-dust->`dust`, bottom->`btm`, git-delta->`delta`, tealdeer->`tldr`.
cargo-binstall --no-confirm --install-path /usr/local/bin \
    eza \
    zoxide \
    starship \
    git-delta \
    bottom \
    du-dust \
    procs \
    sd \
    hyperfine \
    tokei \
    tealdeer

echo "==> Installing yq (${GO_ARCH})"
curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${GO_ARCH}" \
    -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq

echo "==> Installing lazygit (${LG_ARCH})"
LG_VER="$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
    | grep -Po '"tag_name":\s*"v\K[^"]*')"
curl -fsSL \
    "https://github.com/jesseduffield/lazygit/releases/download/v${LG_VER}/lazygit_${LG_VER}_Linux_${LG_ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin lazygit
chmod +x /usr/local/bin/lazygit

# Warm the tealdeer page cache into a system path (not under a runtime volume).
echo "==> Seeding tldr pages"
TEALDEER_CACHE_DIR=/usr/local/share/tealdeer tldr --update || \
    echo "WARN: tldr cache update failed (non-fatal)"

echo "==> install-tools.sh complete"
command -v eza zoxide starship delta btm dust procs sd hyperfine tokei tldr yq lazygit
