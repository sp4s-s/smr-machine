#include "spsc_ring.hpp"
#include "smr_machine_event_io.hpp"

#include <cstdlib>
#include <iostream>
#include <thread>

namespace {

using smr_machine::LossEvent;

[[noreturn]] void fail(const char* message) {
  std::cerr << message << "\n";
  std::exit(1);
}

void test_fifo() {
  smr_machine::SpscRing<int, 8> ring;
  for (int i = 0; i < 7; ++i) {
    if (!ring.try_push(i)) {
      fail("push failed unexpectedly");
    }
  }
  if (ring.try_push(999)) {
    fail("ring should report full");
  }
  for (int i = 0; i < 7; ++i) {
    const auto value = ring.try_pop();
    if (!value.has_value() || *value != i) {
      fail("fifo ordering mismatch");
    }
  }
  if (ring.try_pop().has_value()) {
    fail("ring should be empty");
  }
}

void test_threaded() {
  constexpr std::uint64_t kMessages = 250000;
  smr_machine::SpscRing<LossEvent, 1024> ring;
  std::atomic<bool> done{false};
  std::uint64_t consumed = 0;
  std::thread consumer([&]() {
    std::uint64_t expected = 0;
    while (!done.load(std::memory_order_acquire) || consumed < kMessages) {
      if (const auto item = ring.try_pop()) {
        if (item->sequence != expected) {
          fail("sequence mismatch under contention");
        }
        ++expected;
        ++consumed;
      }
    }
  });
  for (std::uint64_t i = 0; i < kMessages; ++i) {
    LossEvent event{
        .sequence = i,
        .timestamp_ns = i,
        .loss_bps = static_cast<std::int64_t>(i),
        .venue = 1,
        .reserved = 0,
    };
    while (!ring.try_push(event)) {
    }
  }
  done.store(true, std::memory_order_release);
  consumer.join();
}

void test_wraparound_and_size() {
  smr_machine::SpscRing<int, 8> ring;
  for (int i = 0; i < 5; ++i) {
    if (!ring.try_push(i)) {
      fail("wraparound push failed");
    }
  }
  if (ring.approx_size() != 5) {
    fail("approx_size should reflect pending items");
  }
  for (int i = 0; i < 3; ++i) {
    const auto value = ring.try_pop();
    if (!value.has_value() || *value != i) {
      fail("wraparound pop mismatch");
    }
  }
  for (int i = 5; i < 8; ++i) {
    if (!ring.try_push(i)) {
      fail("wraparound second push failed");
    }
  }
  for (int expected = 3; expected < 8; ++expected) {
    const auto value = ring.try_pop();
    if (!value.has_value() || *value != expected) {
      fail("wraparound ordering mismatch");
    }
  }
}

void test_event_encoding() {
  const auto submit = smr_machine::make_submit(42, "ord-1", "alice", smr_machine::SideCode::Buy, 5, 101);
  const auto cancel = smr_machine::make_cancel(43, "ord-1");
  const auto fill = smr_machine::make_fill(44, "ord-1", 2, 101);
  const auto modify = smr_machine::make_modify(45, "ord-1", 4, 102);
  const auto fail_event = smr_machine::make_fail(45, "synthetic-breach");

  if (smr_machine::to_script_line(submit) != "SUBMIT 42 ord-1 alice BUY 5 101") {
    fail("submit encoding mismatch");
  }
  if (smr_machine::to_script_line(cancel) != "CANCEL 43 ord-1") {
    fail("cancel encoding mismatch");
  }
  if (smr_machine::to_script_line(fill) != "FILL 44 ord-1 2 101") {
    fail("fill encoding mismatch");
  }
  if (smr_machine::to_script_line(modify) != "MODIFY 45 ord-1 4 102") {
    fail("modify encoding mismatch");
  }
  if (smr_machine::to_script_line(fail_event) != "FAIL 45 synthetic-breach") {
    fail("fail encoding mismatch");
  }
}

}  // namespace

int main() {
  test_fifo();
  test_threaded();
  test_wraparound_and_size();
  test_event_encoding();
  std::cout << "spsc_tests: ok\n";
  return 0;
}
