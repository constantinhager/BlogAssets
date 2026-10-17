# syntax=docker/dockerfile:1

# DevOps dev container image: PowerShell, Terraform, Ansible, Azure CLI, kubectl, Helm, GitHub CLI.
# Every tool version is pinned here. tests/image.Tests.ps1 reads the *_VERSION ARGs from this file
# and checks that the image contains exactly these versions.

# Microsoft's Ubuntu 24.04 dev container base image: non-root user 'vscode', Git, zsh, common tools.
# '3-noble' follows the 3.x releases of the base image. The weekly scheduled build picks up its updates.
ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:3-noble

#region Stage 1: download and verify the release binaries
FROM ${BASE_IMAGE} AS downloads

ARG TARGETARCH
ARG POWERSHELL_VERSION=7.6.7
ARG TERRAFORM_VERSION=1.16.6
ARG TFLINT_VERSION=0.64.0
ARG KUBECTL_VERSION=1.37.1
ARG HELM_VERSION=4.3.1
ARG GH_VERSION=2.102.0

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# unzip for Terraform and TFLint (usually in the base image already - this makes sure)
# hadolint ignore=DL3008
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/download-tools.sh /usr/local/bin/download-tools.sh

# Downloads each tool and compares it with the SHA256 checksum the project publishes.
# Result: /out/bin (single binaries) and /out/powershell (PowerShell)
RUN chmod +x /usr/local/bin/download-tools.sh \
    && TARGETARCH="${TARGETARCH:-amd64}" /usr/local/bin/download-tools.sh
#endregion

#region Stage 2: the dev container image
FROM ${BASE_IMAGE}

ARG AZURE_CLI_VERSION=2.91.0
ARG ANSIBLE_VERSION=14.5.0
ARG ANSIBLE_LINT_VERSION=26.10.1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# OS packages. Not pinned on purpose: security fixes come with the weekly rebuild.
# python3-venv for Ansible, libicu74 for PowerShell, sshpass + openssh-client for Ansible connections.
# hadolint ignore=DL3008
RUN apt-get update \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        jq \
        less \
        libicu74 \
        openssh-client \
        python3 \
        python3-venv \
        rsync \
        sshpass \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# Azure CLI from Microsoft's apt repository, pinned to one version
# hadolint ignore=DL3008
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
    && chmod go+r /etc/apt/keyrings/microsoft.gpg \
    && . /etc/os-release \
    && printf 'Types: deb\nURIs: https://packages.microsoft.com/repos/azure-cli/\nSuites: %s\nComponents: main\nArchitectures: %s\nSigned-by: /etc/apt/keyrings/microsoft.gpg\n' \
        "${VERSION_CODENAME}" "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/azure-cli.sources \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "azure-cli=${AZURE_CLI_VERSION}-1~${VERSION_CODENAME}" \
    && rm -rf /var/lib/apt/lists/*

# Ansible + ansible-lint in their own virtual environment (Ubuntu 24.04 blocks pip installs into the system Python).
# The symlinks put the commands on the default PATH. The venv is also appended to PATH (ENV below),
# otherwise ansible-lint warns "PATH altered to include /opt/ansible/bin" on every run.
RUN python3 -m venv /opt/ansible \
    && /opt/ansible/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/ansible/bin/pip install --no-cache-dir "ansible==${ANSIBLE_VERSION}" "ansible-lint==${ANSIBLE_LINT_VERSION}" \
    && for tool in /opt/ansible/bin/ansible*; do ln -s "${tool}" /usr/local/bin/; done

# Binaries from stage 1
COPY --from=downloads /out/bin/ /usr/local/bin/
COPY --from=downloads /out/powershell/ /opt/microsoft/powershell/7/
RUN chmod +x /opt/microsoft/powershell/7/pwsh \
    && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
    && printf '/usr/bin/pwsh\n' >> /etc/shells

ENV PATH="${PATH}:/opt/ansible/bin" \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    AZURE_CORE_COLLECT_TELEMETRY=false \
    CHECKPOINT_DISABLE=1 \
    TF_PLUGIN_CACHE_DIR=/home/vscode/.terraform.d/plugin-cache

# PowerShell modules for all users (/usr/local/share/powershell/Modules)
COPY scripts/install-modules.ps1 /tmp/install-modules.ps1
RUN pwsh -NoLogo -NoProfile -File /tmp/install-modules.ps1 \
    && rm /tmp/install-modules.ps1

# Terraform provider cache: downloaded providers survive 'terraform init' in other folders
RUN install -d -o vscode -g vscode /home/vscode/.terraform.d /home/vscode/.terraform.d/plugin-cache

# The image brings its own VS Code setup. The Dev Containers extension and Codespaces read this label
# and merge it with the devcontainer.json of the repository. It replaces the label of the base image.
LABEL devcontainer.metadata='[{ \
    "remoteUser": "vscode", \
    "customizations": { \
        "vscode": { \
            "extensions": [ \
                "ms-vscode.powershell", \
                "pspester.pester-test", \
                "hashicorp.terraform", \
                "redhat.ansible", \
                "redhat.vscode-yaml", \
                "ms-kubernetes-tools.vscode-kubernetes-tools", \
                "github.vscode-github-actions", \
                "editorconfig.editorconfig" \
            ], \
            "settings": { \
                "terminal.integrated.defaultProfile.linux": "pwsh", \
                "powershell.codeFormatting.preset": "OTBS", \
                "powershell.codeFormatting.useCorrectCasing": true, \
                "powershell.scriptAnalysis.enable": true, \
                "ansible.python.interpreterPath": "/opt/ansible/bin/python", \
                "ansible.validation.lint.path": "/usr/local/bin/ansible-lint", \
                "[terraform]": { \
                    "editor.defaultFormatter": "hashicorp.terraform", \
                    "editor.formatOnSave": true \
                } \
            } \
        } \
    } \
}]'
#endregion
