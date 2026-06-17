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
#
# Supply-chain hardening: every external artifact below is PINNED to an explicit
# version and (where the upstream publishes one) integrity-verified with a SHA-256
# or GPG signature gate BEFORE it is placed on PATH or executed. Bumps are
# deliberate — change the *_VER / *_SHA256 constants together. Bump procedure: set
# the new version, run the download once, and copy the upstream-published checksum
# (or recompute with sha256sum) into the matching constant.
# set -o pipefail (below) makes a broken download in any `curl | …` pipe abort the
# build instead of silently continuing.
set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned versions (bump deliberately; update the paired checksum at the same time)
# ---------------------------------------------------------------------------
CARGO_BINSTALL_VER="v1.20.0"   # cargo-bins/cargo-binstall release tag (was `main`)
YQ_VER="4.53.3"                # mikefarah/yq
LG_VER="0.62.2"               # jesseduffield/lazygit
AWS_CLI_VER="2.35.4"          # aws/aws-cli (versioned download path)

# yq publishes per-asset binaries; pin the SHA-256 of each arch's raw binary.
# Referenced indirectly via ${!yq_sha_var} below, so shellcheck can't see the
# use — suppress the false-positive SC2034 on the arch-indexed constants.
# shellcheck disable=SC2034
YQ_SHA256_amd64="fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4"
# shellcheck disable=SC2034
YQ_SHA256_arm64="578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea"

# AWS CLI public PGP key fingerprint (AWS-published, stable). The build fetches
# the key over TLS and refuses to trust it unless this fingerprint matches.
AWS_CLI_PGP_FPR="FB5DB77FD5C118B80511ADA8A6310ACC4672475C"

DPKG_ARCH="$(dpkg --print-architecture)"   # arm64 | amd64
case "$DPKG_ARCH" in
    arm64) GO_ARCH=arm64; LG_ARCH=arm64;  AWS_ARCH=aarch64 ;;
    amd64) GO_ARCH=amd64; LG_ARCH=x86_64; AWS_ARCH=x86_64  ;;
    *) echo "ERROR: unsupported arch ${DPKG_ARCH}" >&2; exit 1 ;;
esac

echo "==> Installing cargo-binstall (${CARGO_BINSTALL_VER})"
# Pin the installer to a release tag, not `main` HEAD — fetch-then-run so a broken
# download aborts the build (a piped truncated script could otherwise half-execute).
CB_TMP="$(mktemp -d)"
curl -L --proto '=https' --tlsv1.2 -fsSf \
    "https://raw.githubusercontent.com/cargo-bins/cargo-binstall/${CARGO_BINSTALL_VER}/install-from-binstall-release.sh" \
    -o "${CB_TMP}/install-cargo-binstall.sh"
bash "${CB_TMP}/install-cargo-binstall.sh"
rm -rf "${CB_TMP}"
export PATH="${HOME}/.cargo/bin:${PATH}"

echo "==> Installing Rust CLI tools via cargo-binstall"
# crate names: du-dust->`dust`, bottom->`btm`, git-delta->`delta`, tealdeer->`tldr`.
# --locked uses each crate's published Cargo.lock so transitive resolution is
# reproducible. NOTE (deliberate deviation, org standard): the crate *versions*
# are intentionally left floating — cargo-binstall resolves newest-on-crates.io
# and verifies the crate checksum against the registry index. Pinning all 11 to
# exact versions would require an out-of-band bump cadence for low-risk dev CLIs;
# the registry checksum + --locked is the accepted trade-off here.
RUST_TOOLS=(eza zoxide starship git-delta bottom du-dust procs sd hyperfine tokei tealdeer)

# Resilience to flaky build-host networks (notably WSL2 / Docker Desktop, whose NAT
# chokes cargo-binstall's concurrent fetcher checks — ~20 simultaneous outbound
# connections is the observed ceiling). Three guards, all no-ops on a healthy host:
#   * --disable-strategies compile — NEVER fall back to building from source. This
#     image ships no Rust toolchain, AND the source path rejects --install-path, so
#     a single transient fetcher timeout would otherwise hard-fail the build with a
#     misleading `cargo-install does not support --install-path` (exit 100). All 11
#     crates publish prebuilt binaries, so the compile strategy is never legitimately
#     needed here.
#   * --maximum-resolution-timeout 60 — give each GitHub/QuickInstall lookup room
#     beyond the stingy 15s default before it's declared timed out.
#   * install in batches of 4 (≈8 concurrent connections, well under the ceiling)
#     and retry each batch — 11 crates at once sat right at the edge; batching +
#     retry rides out a brief NAT/DNS blip. The cargo cache mount makes retries cheap.
binstall_retry() {  # args: crate names; retries the batch to absorb transient blips
    local attempt
    for attempt in 1 2 3; do
        if cargo-binstall --no-confirm --locked \
                --disable-strategies compile \
                --maximum-resolution-timeout 60 \
                --install-path /usr/local/bin "$@"; then
            return 0
        fi
        echo "WARN: cargo-binstall attempt ${attempt}/3 failed for: $* — retrying" >&2
        sleep "$((attempt * 8))"
    done
    echo "ERROR: cargo-binstall failed after 3 attempts for: $*" >&2
    return 1
}
batch=()
for tool in "${RUST_TOOLS[@]}"; do
    batch+=("$tool")
    if [ "${#batch[@]}" -eq 4 ]; then
        binstall_retry "${batch[@]}"
        batch=()
    fi
done
if [ "${#batch[@]}" -gt 0 ]; then
    binstall_retry "${batch[@]}"
fi

echo "==> Installing yq ${YQ_VER} (${GO_ARCH})"
# Pinned version + SHA-256 gate (no /releases/latest redirect, no unverified write).
YQ_TMP="$(mktemp -d)"
curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VER}/yq_linux_${GO_ARCH}" \
    -o "${YQ_TMP}/yq"
yq_sha_var="YQ_SHA256_${GO_ARCH}"
echo "${!yq_sha_var}  ${YQ_TMP}/yq" | sha256sum -c -
install -m 0755 "${YQ_TMP}/yq" /usr/local/bin/yq
rm -rf "${YQ_TMP}"

echo "==> Installing lazygit ${LG_VER} (${LG_ARCH})"
# Pinned version (no api.github.com/releases/latest lookup) + checksums.txt gate.
LG_TMP="$(mktemp -d)"
LG_TARBALL="lazygit_${LG_VER}_linux_${LG_ARCH}.tar.gz"
LG_BASE="https://github.com/jesseduffield/lazygit/releases/download/v${LG_VER}"
curl -fsSL "${LG_BASE}/${LG_TARBALL}" -o "${LG_TMP}/${LG_TARBALL}"
curl -fsSL "${LG_BASE}/checksums.txt" -o "${LG_TMP}/checksums.txt"
( cd "${LG_TMP}" && grep " ${LG_TARBALL}\$" checksums.txt | sha256sum -c - )
tar -xz -C /usr/local/bin -f "${LG_TMP}/${LG_TARBALL}" lazygit
chmod +x /usr/local/bin/lazygit
rm -rf "${LG_TMP}"

# AWS CLI v2 (official bundled installer — pinned to arch, not the v1 pip pkg).
# Installs to /usr/local/aws-cli and symlinks aws + aws_completer into
# /usr/local/bin (on PATH for every user). Runtime egress to AWS APIs is handled
# separately by the firewall's @aws-ip-ranges directive; this is a build-time
# fetch only. Credentials/config persist via AWS_CONFIG_FILE +
# AWS_SHARED_CREDENTIALS_FILE (set in the Dockerfile, pointed at the ~/.claude
# volume) — nothing here writes user state.
#
# Verified install (AWS-documented): pin a version, fetch the bundle AND its
# detached PGP signature, import AWS's public key (fingerprint-checked), and
# `gpg --verify` before unzip — never run ./aws/install on an unverified archive.
echo "==> Installing AWS CLI v2 ${AWS_CLI_VER} (${AWS_ARCH})"
AWS_TMP="$(mktemp -d)"
AWS_BASE="https://awscli.amazonaws.com"
AWS_ZIP="awscli-exe-linux-${AWS_ARCH}-${AWS_CLI_VER}.zip"
curl -fsSL "${AWS_BASE}/${AWS_ZIP}" -o "${AWS_TMP}/awscliv2.zip"
curl -fsSL "${AWS_BASE}/${AWS_ZIP}.sig" -o "${AWS_TMP}/awscliv2.sig"
export GNUPGHOME="${AWS_TMP}/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"
# AWS does not serve the public key from a fetchable URL — it publishes the key
# block in its docs. Embed it here (the AWS-documented procedure) and assert its
# fingerprint matches AWS_CLI_PGP_FPR before importing, so an accidental edit to
# the block below can't silently swap the trust anchor.
cat > "${AWS_TMP}/awscli.gpg" <<'AWSCLIPUBKEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBF2Cr7UBEADJZHcgusOJl7ENSyumXh85z0TRV0xJorM2B/JL0kHOyigQluUG
ZMLhENaG0bYatdrKP+3H91lvK050pXwnO/R7fB/FSTouki4ciIx5OuLlnJZIxSzx
PqGl0mkxImLNbGWoi6Lto0LYxqHN2iQtzlwTVmq9733zd3XfcXrZ3+LblHAgEt5G
TfNxEKJ8soPLyWmwDH6HWCnjZ/aIQRBTIQ05uVeEoYxSh6wOai7ss/KveoSNBbYz
gbdzoqI2Y8cgH2nbfgp3DSasaLZEdCSsIsK1u05CinE7k2qZ7KgKAUIcT/cR/grk
C6VwsnDU0OUCideXcQ8WeHutqvgZH1JgKDbznoIzeQHJD238GEu+eKhRHcz8/jeG
94zkcgJOz3KbZGYMiTh277Fvj9zzvZsbMBCedV1BTg3TqgvdX4bdkhf5cH+7NtWO
lrFj6UwAsGukBTAOxC0l/dnSmZhJ7Z1KmEWilro/gOrjtOxqRQutlIqG22TaqoPG
fYVN+en3Zwbt97kcgZDwqbuykNt64oZWc4XKCa3mprEGC3IbJTBFqglXmZ7l9ywG
EEUJYOlb2XrSuPWml39beWdKM8kzr1OjnlOm6+lpTRCBfo0wa9F8YZRhHPAkwKkX
XDeOGpWRj4ohOx0d2GWkyV5xyN14p2tQOCdOODmz80yUTgRpPVQUtOEhXQARAQAB
tCFBV1MgQ0xJIFRlYW0gPGF3cy1jbGlAYW1hem9uLmNvbT6JAlQEEwEIAD4CGwMF
CwkIBwIGFQoJCAsCBBYCAwECHgECF4AWIQT7Xbd/1cEYuAURraimMQrMRnJHXAUC
aGveYQUJDMpiLAAKCRCmMQrMRnJHXKBYD/9Ab0qQdGiO5hObchG8xh8Rpb4Mjyf6
0JrVo6m8GNjNj6BHkSc8fuTQJ/FaEhaQxj3pjZ3GXPrXjIIVChmICLlFuRXYzrXc
Pw0lniybypsZEVai5kO0tCNBCCFuMN9RsmmRG8mf7lC4FSTbUDmxG/QlYK+0IV/l
uJkzxWa+rySkdpm0JdqumjegNRgObdXHAQDWlubWQHWyZyIQ2B4U7AxqSpcdJp6I
S4Zds4wVLd1WE5pquYQ8vS2cNlDm4QNg8wTj58e3lKN47hXHMIb6CHxRnb947oJa
pg189LLPR5koh+EorNkA1wu5mAJtJvy5YMsppy2y/kIjp3lyY6AmPT1posgGk70Z
CmToEZ5rbd7ARExtlh76A0cabMDFlEHDIK8RNUOSRr7L64+KxOUegKBfQHb9dADY
qqiKqpCbKgvtWlds909Ms74JBgr2KwZCSY1HaOxnIr4CY43QRqAq5YHOay/mU+6w
hhmdF18vpyK0vfkvvGresWtSXbag7Hkt3XjaEw76BzxQH21EBDqU8WJVjHgU6ru+
DJTs+SxgJbaT3hb/vyjlw0lK+hFfhWKRwgOXH8vqducF95NRSUxtS4fpqxWVaw3Q
V2OWSjbne99A5EPEySzryFTKbMGwaTlAwMCwYevt4YT6eb7NmFhTx0Fis4TalUs+
j+c7Kg92pDx2uQ==
=OBAt
-----END PGP PUBLIC KEY BLOCK-----
AWSCLIPUBKEY
got_fpr="$(gpg --show-keys --with-colons "${AWS_TMP}/awscli.gpg" \
    | awk -F: '/^fpr:/{print $10; exit}')"
if [ "${got_fpr}" != "${AWS_CLI_PGP_FPR}" ]; then
    echo "ERROR: AWS CLI PGP key fingerprint mismatch: got=${got_fpr} want=${AWS_CLI_PGP_FPR}" >&2
    exit 1
fi
gpg --import "${AWS_TMP}/awscli.gpg"
gpg --verify "${AWS_TMP}/awscliv2.sig" "${AWS_TMP}/awscliv2.zip"
unset GNUPGHOME
unzip -q "${AWS_TMP}/awscliv2.zip" -d "${AWS_TMP}"
"${AWS_TMP}/aws/install"
rm -rf "${AWS_TMP}"

# Warm the tealdeer page cache into a system path (not under a runtime volume).
echo "==> Seeding tldr pages"
TEALDEER_CACHE_DIR=/usr/local/share/tealdeer tldr --update || \
    echo "WARN: tldr cache update failed (non-fatal)"

echo "==> install-tools.sh complete"
command -v eza zoxide starship delta btm dust procs sd hyperfine tokei tldr yq lazygit aws
