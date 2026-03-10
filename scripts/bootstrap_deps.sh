#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---install}"

if [[ "$MODE" != "--install" && "$MODE" != "--check" ]]; then
  cat <<'EOF'
usage: scripts/bootstrap_deps.sh [--install|--check]

Installs or checks the local toolchain needed for the C++, OCaml, Lua terminal,
tmux workflow, and optional plotting helpers.
EOF
  exit 1
fi

have() {
  command -v "$1" >/dev/null 2>&1
}

MISSING_COMMANDS=()

record_missing() {
  local command_name="$1"
  if ! have "$command_name"; then
    MISSING_COMMANDS+=("$command_name")
  fi
}

record_missing bash
record_missing cmake
record_missing make
record_missing pkg-config
record_missing lua
record_missing tmux
record_missing python3
record_missing dune

if ! have clang++ && ! have g++; then
  MISSING_COMMANDS+=("c++ compiler")
fi

print_missing() {
  if [[ ${#MISSING_COMMANDS[@]} -eq 0 ]]; then
    echo "dependencies ready"
    return
  fi
  echo "missing dependencies:"
  printf '  - %s\n' "${MISSING_COMMANDS[@]}"
}

install_with_brew() {
  local packages=(
    bash
    ccache
    cmake
    dune
    lua
    ninja
    ocaml
    pkg-config
    python
    tmux
  )
  brew update
  brew install "${packages[@]}"
}

install_with_apt() {
  local packages=(
    bash
    build-essential
    ca-certificates
    ccache
    clang
    cmake
    dune
    lua5.4
    make
    ninja-build
    ocaml-nox
    pkg-config
    python3
    python3-pip
    tmux
  )
  if [[ $EUID -ne 0 ]]; then
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "${packages[@]}"
  else
    apt-get update
    apt-get install -y --no-install-recommends "${packages[@]}"
  fi
}

install_with_pacman() {
  local packages=(
    bash
    base-devel
    ccache
    clang
    cmake
    dune
    lua
    make
    ninja
    ocaml
    pkgconf
    python
    tmux
  )
  if [[ $EUID -ne 0 ]]; then
    sudo pacman -Sy --needed --noconfirm "${packages[@]}"
  else
    pacman -Sy --needed --noconfirm "${packages[@]}"
  fi
}

if [[ "$MODE" == "--check" ]]; then
  print_missing
  [[ ${#MISSING_COMMANDS[@]} -eq 0 ]]
  exit $?
fi

if [[ ${#MISSING_COMMANDS[@]} -eq 0 ]]; then
  echo "dependencies already installed"
  exit 0
fi

if have brew; then
  install_with_brew
elif have apt-get; then
  install_with_apt
elif have pacman; then
  install_with_pacman
else
  print_missing
  echo "unsupported package manager: install the missing tools manually"
  exit 1
fi

MISSING_COMMANDS=()
record_missing bash
record_missing cmake
record_missing make
record_missing pkg-config
record_missing lua
record_missing tmux
record_missing python3
record_missing dune
if ! have clang++ && ! have g++; then
  MISSING_COMMANDS+=("c++ compiler")
fi

print_missing
[[ ${#MISSING_COMMANDS[@]} -eq 0 ]]
