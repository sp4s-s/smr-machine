OCAML_DUNE ?= dune
CXX ?= clang++
CCACHE ?= $(shell command -v ccache 2>/dev/null)
DUNE_CACHE ?= enabled
CXXFLAGS ?= -std=c++20 -O3 -Wall -Wextra -Wpedantic -Icpp/include
BUILD_DIR := build
CXX_COMPILE := $(if $(CCACHE),$(CCACHE) ,)$(CXX)

.PHONY: all bootstrap deps-check ocaml cpp test integration bench bench-report stress-report perf-report flame-report clean

all: ocaml cpp

bootstrap:
	./scripts/bootstrap_deps.sh --install

deps-check:
	./scripts/bootstrap_deps.sh --check

ocaml:
	DUNE_CACHE=$(DUNE_CACHE) $(OCAML_DUNE) build

cpp: $(BUILD_DIR)/spsc_bench $(BUILD_DIR)/spsc_tests $(BUILD_DIR)/generate_scenario $(BUILD_DIR)/command_stress

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/spsc_bench: cpp/src/spsc_bench.cpp cpp/include/spsc_ring.hpp | $(BUILD_DIR)
	$(CXX_COMPILE) $(CXXFLAGS) cpp/src/spsc_bench.cpp -o $@

$(BUILD_DIR)/spsc_tests: cpp/tests/spsc_tests.cpp cpp/include/spsc_ring.hpp | $(BUILD_DIR)
	$(CXX_COMPILE) $(CXXFLAGS) cpp/tests/spsc_tests.cpp -o $@

$(BUILD_DIR)/generate_scenario: cpp/src/generate_scenario.cpp cpp/include/spsc_ring.hpp cpp/include/smr_machine_event_io.hpp | $(BUILD_DIR)
	$(CXX_COMPILE) $(CXXFLAGS) cpp/src/generate_scenario.cpp -o $@

$(BUILD_DIR)/command_stress: cpp/src/command_stress.cpp cpp/include/spsc_ring.hpp cpp/include/smr_machine_event_io.hpp | $(BUILD_DIR)
	$(CXX_COMPILE) $(CXXFLAGS) cpp/src/command_stress.cpp -o $@

test: ocaml cpp
	DUNE_CACHE=$(DUNE_CACHE) $(OCAML_DUNE) runtest
	./$(BUILD_DIR)/spsc_tests

integration: all
	./$(BUILD_DIR)/generate_scenario --output examples/generated_from_cpp.pr42
	DUNE_CACHE=$(DUNE_CACHE) $(OCAML_DUNE) exec ./ocaml/bin/deterministic_cli.exe -- replay examples/generated_from_cpp.pr42 --checkpoint 2 --rollback-seq 4

bench: cpp
	./$(BUILD_DIR)/spsc_bench --messages 1000000 --capacity 1024

bench-report: cpp
	./scripts/bench_matrix.sh

stress-report: cpp
	./scripts/stress_report.sh

perf-report: cpp
	./scripts/perf_report.sh

flame-report: cpp
	./scripts/profile_bench.sh

clean:
	rm -rf _build $(BUILD_DIR)
