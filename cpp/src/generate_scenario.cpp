#include "smr_machine_event_io.hpp"
#include "spsc_ring.hpp"

#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

using smr_machine::CommandEvent;
using smr_machine::SideCode;

std::string parse_output_path(int argc, char** argv) {
  std::string output = "examples/generated_from_cpp.pr42";
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--output" && i + 1 < argc) {
      output = argv[++i];
    } else {
      std::cerr << "usage: generate_scenario [--output path]\n";
      std::exit(1);
    }
  }
  return output;
}

std::vector<CommandEvent> scripted_events() {
  return {
      smr_machine::make_submit(2'000'000, "ord-201", "alpha", SideCode::Buy, 12, 100),
      smr_machine::make_fill(2'000'010, "ord-201", 7, 100),
      smr_machine::make_submit(2'000'020, "ord-202", "alpha", SideCode::Sell, 10, 103),
      smr_machine::make_modify(2'000'025, "ord-202", 8, 104),
      smr_machine::make_fill(2'000'030, "ord-202", 8, 104),
      smr_machine::make_submit(2'000'040, "ord-203", "beta", SideCode::Sell, 5, 99),
      smr_machine::make_cancel(2'000'050, "ord-203"),
      smr_machine::make_fail(2'000'060, "synthetic-loss-boundary-breach"),
  };
}

}  // namespace

int main(int argc, char** argv) {
  const std::string output = parse_output_path(argc, argv);
  smr_machine::SpscRing<CommandEvent, 32> ring;
  std::vector<CommandEvent> consumed;
  const std::vector<CommandEvent> events = scripted_events();
  consumed.reserve(events.size());

  std::thread consumer([&]() {
    while (consumed.size() < events.size()) {
      if (const auto item = ring.try_pop()) {
        consumed.push_back(*item);
      }
    }
  });

  for (const auto& event : events) {
    while (!ring.try_push(event)) {
    }
  }

  consumer.join();
  smr_machine::write_script_file(output, consumed);
  std::cout << "generated=" << output << "\n";
  std::cout << "events=" << consumed.size() << "\n";
  return 0;
}
