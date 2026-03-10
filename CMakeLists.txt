cmake_minimum_required(VERSION 3.20)

project(smr-machine LANGUAGES CXX)

option(SMR_MACHINE_ENABLE_CCACHE "Use ccache for C++ compilations when available" ON)
option(SMR_MACHINE_ENABLE_DUNE_CACHE "Enable dune cache for OCaml targets" ON)
option(SMR_MACHINE_ENABLE_DEBUG_INFO "Emit debug info for profiler symbolization" ON)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

if(SMR_MACHINE_ENABLE_CCACHE)
  find_program(SMR_MACHINE_CCACHE_PROGRAM ccache)
  if(SMR_MACHINE_CCACHE_PROGRAM)
    set(CMAKE_CXX_COMPILER_LAUNCHER "${SMR_MACHINE_CCACHE_PROGRAM}")
  endif()
endif()

find_program(SMR_MACHINE_DUNE_PROGRAM dune REQUIRED)
find_program(SMR_MACHINE_BASH_PROGRAM bash REQUIRED)

add_custom_target(bootstrap_deps
  COMMAND ${SMR_MACHINE_BASH_PROGRAM} ${CMAKE_SOURCE_DIR}/scripts/bootstrap_deps.sh --install
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  USES_TERMINAL
)

add_custom_target(deps_check
  COMMAND ${SMR_MACHINE_BASH_PROGRAM} ${CMAKE_SOURCE_DIR}/scripts/bootstrap_deps.sh --check
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  USES_TERMINAL
)

set(SMR_MACHINE_DUNE_CACHE_VALUE "disabled")
if(SMR_MACHINE_ENABLE_DUNE_CACHE)
  set(SMR_MACHINE_DUNE_CACHE_VALUE "enabled")
endif()

add_executable(spsc_bench cpp/src/spsc_bench.cpp)
target_include_directories(spsc_bench PRIVATE cpp/include)
target_compile_options(spsc_bench PRIVATE -O3 -Wall -Wextra -Wpedantic $<$<BOOL:${SMR_MACHINE_ENABLE_DEBUG_INFO}>:-g>)

add_executable(spsc_tests cpp/tests/spsc_tests.cpp)
target_include_directories(spsc_tests PRIVATE cpp/include)
target_compile_options(spsc_tests PRIVATE -O3 -Wall -Wextra -Wpedantic $<$<BOOL:${SMR_MACHINE_ENABLE_DEBUG_INFO}>:-g>)

add_executable(generate_scenario cpp/src/generate_scenario.cpp)
target_include_directories(generate_scenario PRIVATE cpp/include)
target_compile_options(generate_scenario PRIVATE -O3 -Wall -Wextra -Wpedantic $<$<BOOL:${SMR_MACHINE_ENABLE_DEBUG_INFO}>:-g>)

add_executable(command_stress cpp/src/command_stress.cpp)
target_include_directories(command_stress PRIVATE cpp/include)
target_compile_options(command_stress PRIVATE -O3 -Wall -Wextra -Wpedantic $<$<BOOL:${SMR_MACHINE_ENABLE_DEBUG_INFO}>:-g>)

add_custom_target(ocaml
  COMMAND ${CMAKE_COMMAND} -E env DUNE_CACHE=${SMR_MACHINE_DUNE_CACHE_VALUE} ${SMR_MACHINE_DUNE_PROGRAM} build
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  USES_TERMINAL
)

add_custom_target(all_smr_machine DEPENDS ocaml spsc_bench spsc_tests generate_scenario command_stress)

add_custom_target(bench_report
  COMMAND ${SMR_MACHINE_BASH_PROGRAM} ${CMAKE_SOURCE_DIR}/scripts/bench_matrix.sh
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  DEPENDS spsc_bench
  USES_TERMINAL
)

add_custom_target(stress_report
  COMMAND ${SMR_MACHINE_BASH_PROGRAM} ${CMAKE_SOURCE_DIR}/scripts/stress_report.sh
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  DEPENDS spsc_bench
  USES_TERMINAL
)

add_custom_target(perf_report
  COMMAND ${SMR_MACHINE_BASH_PROGRAM} ${CMAKE_SOURCE_DIR}/scripts/perf_report.sh
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  DEPENDS spsc_bench
  USES_TERMINAL
)

add_custom_target(flame_report
  COMMAND ${SMR_MACHINE_BASH_PROGRAM} ${CMAKE_SOURCE_DIR}/scripts/profile_bench.sh
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  DEPENDS spsc_bench
  USES_TERMINAL
)

add_custom_target(integration
  COMMAND ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/generate_scenario --output examples/generated_from_cpp.pr42
  COMMAND ${CMAKE_COMMAND} -E env DUNE_CACHE=${SMR_MACHINE_DUNE_CACHE_VALUE} ${SMR_MACHINE_DUNE_PROGRAM} exec ./ocaml/bin/deterministic_cli.exe -- replay examples/generated_from_cpp.pr42 --checkpoint 2 --rollback-seq 4
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  DEPENDS ocaml generate_scenario
  USES_TERMINAL
)

enable_testing()
add_test(NAME cpp_spsc_tests COMMAND ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/spsc_tests)
add_test(
  NAME ocaml_dune_runtest
  COMMAND ${CMAKE_COMMAND} -E env DUNE_CACHE=${SMR_MACHINE_DUNE_CACHE_VALUE} ${SMR_MACHINE_DUNE_PROGRAM} runtest
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)
add_test(
  NAME integration_replay
  COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target integration
)
