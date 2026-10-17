#!/usr/bin/env bash
# Downloads the release binaries for the dev container image and verifies each one
# against the SHA256 checksum file the project publishes next to the download.
# Runs in the 'downloads' stage of the Dockerfile. Versions come from the Dockerfile ARGs.
#
# Output:
#   /out/bin         terraform, tflint, kubectl, helm, gh
#   /out/powershell  PowerShell (extracted archive)
set -euo pipefail

: "${TARGETARCH:?TARGETARCH is not set}"
: "${POWERSHELL_VERSION:?}" "${TERRAFORM_VERSION:?}" "${TFLINT_VERSION:?}"
: "${KUBECTL_VERSION:?}" "${HELM_VERSION:?}" "${GH_VERSION:?}"

case "${TARGETARCH}" in
    amd64) ps_arch="x64" ;;
    arm64) ps_arch="arm64" ;;
    *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;;
esac

out_bin="/out/bin"
out_pwsh="/out/powershell"
mkdir -p "${out_bin}" "${out_pwsh}"
work="$(mktemp -d)"
cd "${work}"

# fetch <url> [<file name>]
fetch() {
    local url="$1"
    local file="${2:-${url##*/}}"
    curl -fsSL --retry 3 --retry-delay 2 -o "${file}" "${url}"
}

# as_utf8 <file> - prints a text file as UTF-8 without BOM and CR.
# PowerShell's hashes.sha256 is UTF-16 LE with CRLF, the others are plain UTF-8.
as_utf8() {
    local bom
    bom="$(head -c 2 "$1" | od -An -tx1 | tr -d ' \n')"
    if [[ "${bom}" == "fffe" || "${bom}" == "feff" ]]; then
        iconv -f UTF-16 -t UTF-8 "$1"
    else
        cat "$1"
    fi | sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//'
}

# verify <file> <checksum file>
# Checksum files list "<hash>  <file>" or "<hash> *<file>".
verify() {
    local file="$1"
    local sums="$2"
    local expected actual
    expected="$(as_utf8 "${sums}" \
        | awk -v f="${file}" '{ name = $2; sub(/^\*/, "", name) } name == f { print tolower($1); exit }')"
    if [[ -z "${expected}" ]]; then
        echo "No checksum for ${file} in ${sums}" >&2
        exit 1
    fi
    actual="$(sha256sum "${file}" | cut -d ' ' -f 1)"
    if [[ "${expected}" != "${actual}" ]]; then
        echo "Checksum mismatch for ${file}: expected ${expected}, got ${actual}" >&2
        exit 1
    fi
    echo "[ok] ${file}"
}

# PowerShell
file="powershell-${POWERSHELL_VERSION}-linux-${ps_arch}.tar.gz"
fetch "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${file}"
fetch "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/hashes.sha256"
verify "${file}" hashes.sha256
tar -xzf "${file}" -C "${out_pwsh}"

# Terraform
file="terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip"
fetch "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${file}"
fetch "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
verify "${file}" "terraform_${TERRAFORM_VERSION}_SHA256SUMS"
unzip -o -q "${file}" terraform -d "${out_bin}"

# TFLint
file="tflint_linux_${TARGETARCH}.zip"
fetch "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/${file}"
fetch "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/checksums.txt" tflint_checksums.txt
verify "${file}" tflint_checksums.txt
unzip -o -q "${file}" tflint -d "${out_bin}"

# kubectl - the .sha256 file contains only the hash
fetch "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"
fetch "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256"
printf '%s  kubectl\n' "$(tr -d '[:space:]' < kubectl.sha256)" > kubectl.sums
verify kubectl kubectl.sums
install -m 0755 kubectl "${out_bin}/kubectl"

# Helm
file="helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz"
fetch "https://get.helm.sh/${file}"
fetch "https://get.helm.sh/${file}.sha256sum"
verify "${file}" "${file}.sha256sum"
tar -xzf "${file}" "linux-${TARGETARCH}/helm"
install -m 0755 "linux-${TARGETARCH}/helm" "${out_bin}/helm"

# GitHub CLI
file="gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz"
fetch "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${file}"
fetch "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt"
verify "${file}" "gh_${GH_VERSION}_checksums.txt"
tar -xzf "${file}" "gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh"
install -m 0755 "gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" "${out_bin}/gh"

chmod 0755 "${out_bin}"/*
cd /
rm -rf "${work}"
