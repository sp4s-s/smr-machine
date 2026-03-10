FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    ccache \
    clang \
    cmake \
    dune \
    lua5.4 \
    make \
    ninja-build \
    ocaml-nox \
    pkg-config \
    python3 \
    python3-pip \
    tmux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

ENV CC=clang
ENV CXX=clang++
ENV DUNE_CACHE=enabled
ENV CCACHE_DIR=/workspace/.ccache

COPY . .

RUN chmod +x scripts/bootstrap_deps.sh scripts/order_terminal.lua scripts/run_trading_stress.lua scripts/trading_terminal_tmux.sh \
    && ./scripts/bootstrap_deps.sh --check \
    && mkdir -p build \
    && cd build \
    && cmake .. -G Ninja -DSMR_MACHINE_ENABLE_CCACHE=ON -DSMR_MACHINE_ENABLE_DUNE_CACHE=ON \
    && cmake --build . --target all_smr_machine \
    && ctest --output-on-failure

CMD ["/bin/bash"]
