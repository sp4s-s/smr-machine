#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <new>
#include <optional>
#include <type_traits>

namespace smr_machine {

template <typename T, std::size_t Capacity>
class alignas(64) SpscRing {
  static_assert(Capacity >= 2, "Capacity must be at least 2");
  static_assert((Capacity & (Capacity - 1)) == 0, "Capacity must be a power of two");
  static_assert(std::is_trivially_copyable_v<T>, "T must be trivially copyable");

 public:
  SpscRing() = default;
  SpscRing(const SpscRing&) = delete;
  SpscRing& operator=(const SpscRing&) = delete;

  bool try_push(const T& value) noexcept {
    const auto head = head_.load(std::memory_order_relaxed);
    const auto next = increment(head);
    if (next == tail_cache_) {
      tail_cache_ = tail_.load(std::memory_order_acquire);
      if (next == tail_cache_) {
        return false;
      }
    }
    storage_[head] = value;
    head_.store(next, std::memory_order_release);
    return true;
  }

  std::optional<T> try_pop() noexcept {
    const auto tail = tail_.load(std::memory_order_relaxed);
    if (tail == head_cache_) {
      head_cache_ = head_.load(std::memory_order_acquire);
      if (tail == head_cache_) {
        return std::nullopt;
      }
    }
    const T value = storage_[tail];
    tail_.store(increment(tail), std::memory_order_release);
    return value;
  }

  [[nodiscard]] std::size_t approx_size() const noexcept {
    const auto head = head_.load(std::memory_order_acquire);
    const auto tail = tail_.load(std::memory_order_acquire);
    return (head + Capacity - tail) & mask();
  }

 private:
  static constexpr std::size_t mask() noexcept { return Capacity - 1; }
  static constexpr std::size_t increment(std::size_t idx) noexcept { return (idx + 1) & mask(); }

  alignas(64) std::array<T, Capacity> storage_{};
  alignas(64) std::atomic<std::size_t> head_{0};
  alignas(64) std::atomic<std::size_t> tail_{0};
  alignas(64) std::size_t head_cache_{0};
  alignas(64) std::size_t tail_cache_{0};
};

struct LossEvent {
  std::uint64_t sequence;
  std::uint64_t timestamp_ns;
  std::int64_t loss_bps;
  std::int32_t venue;
  std::int32_t reserved;
};

static_assert(sizeof(LossEvent) == 32, "LossEvent layout changed");

}  // namespace smr_machine
