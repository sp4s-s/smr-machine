#include "spsc_ring.hpp"

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

using smr_machine::LossEvent;

struct RunConfig {
  std::optional<std::uint64_t> messages;
  double duration_sec = 0.0;
  std::uint64_t report_interval_ms = 0;
  std::string timeline_csv_path;
  std::string latency_histogram_csv_path;
  std::string trace_event_json_path;
  std::size_t lanes = 1;
  std::size_t stress_threads = 0;
  std::size_t stress_bytes = 8 * 1024 * 1024;
  std::uint64_t latency_bucket_ns = 100;
  std::uint64_t latency_max_ns = 100'000'000;
};

struct TimelineSample {
  std::uint64_t elapsed_ns;
  std::uint64_t produced;
  std::uint64_t consumed;
  double interval_mps;
};

struct LaneTrace {
  std::uint64_t producer_start_ns = 0;
  std::uint64_t producer_end_ns = 0;
  std::uint64_t consumer_start_ns = 0;
  std::uint64_t consumer_end_ns = 0;
};

struct LatencySummary {
  std::uint64_t samples = 0;
  std::uint64_t min_ns = 0;
  std::uint64_t max_ns = 0;
  long double mean_ns = 0.0;
  std::uint64_t p50_ns = 0;
  std::uint64_t p55_ns = 0;
  std::uint64_t p90_ns = 0;
  std::uint64_t p95_ns = 0;
  std::uint64_t p99_ns = 0;
  std::uint64_t p999_ns = 0;
  std::uint64_t p9999_ns = 0;
};

void write_latency_histogram_csv(
    const std::string& path,
    const std::vector<std::uint64_t>& histogram,
    std::uint64_t bucket_ns,
    std::uint64_t max_ns) {
  std::ofstream out(path);
  if (!out) {
    throw std::runtime_error("failed to open latency histogram CSV: " + path);
  }

  out << "bucket_start_ns,bucket_end_ns,samples\n";
  for (std::size_t bucket = 0; bucket < histogram.size(); ++bucket) {
    const auto start_ns = static_cast<std::uint64_t>(bucket) * bucket_ns;
    const auto end_ns = std::min(start_ns + bucket_ns, max_ns + 1);
    out << start_ns << ',' << end_ns << ',' << histogram[bucket] << '\n';
  }
}

void write_trace_event_json(
    const std::string& path,
    const std::vector<TimelineSample>& timeline,
    const std::vector<LaneTrace>& lane_traces,
    std::size_t stress_threads,
    std::uint64_t elapsed_ns,
    std::size_t lanes) {
  std::ofstream out(path);
  if (!out) {
    throw std::runtime_error("failed to open trace event JSON: " + path);
  }

  auto write_event = [&](bool& first, const std::string& event) {
    if (!first) {
      out << ",\n";
    }
    first = false;
    out << event;
  };

  out << "{\n  \"traceEvents\": [\n";
  bool first = true;

  write_event(first, "    {\"name\":\"process_name\",\"ph\":\"M\",\"pid\":1,\"tid\":0,\"args\":{\"name\":\"spsc_bench\"}}");
  write_event(first, "    {\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":1,\"tid\":1,\"args\":{\"name\":\"benchmark-main\"}}");
  write_event(first, "    {\"name\":\"benchmark\",\"cat\":\"run\",\"ph\":\"X\",\"pid\":1,\"tid\":1,\"ts\":0,\"dur\":" +
                        std::to_string(elapsed_ns / 1000) + "}");

  for (std::size_t lane_index = 0; lane_index < lanes; ++lane_index) {
    const auto producer_tid = 100 + static_cast<int>(lane_index);
    const auto consumer_tid = 200 + static_cast<int>(lane_index);
    write_event(first, "    {\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":1,\"tid\":" + std::to_string(producer_tid) +
                          ",\"args\":{\"name\":\"producer-lane-" + std::to_string(lane_index) + "\"}}");
    write_event(first, "    {\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":1,\"tid\":" + std::to_string(consumer_tid) +
                          ",\"args\":{\"name\":\"consumer-lane-" + std::to_string(lane_index) + "\"}}");

    const auto& lane = lane_traces[lane_index];
    if (lane.producer_end_ns > lane.producer_start_ns) {
      write_event(first, "    {\"name\":\"producer\",\"cat\":\"lane\",\"ph\":\"X\",\"pid\":1,\"tid\":" +
                            std::to_string(producer_tid) + ",\"ts\":" +
                            std::to_string(lane.producer_start_ns / 1000) + ",\"dur\":" +
                            std::to_string((lane.producer_end_ns - lane.producer_start_ns) / 1000) +
                            ",\"args\":{\"lane\":" + std::to_string(lane_index) + "}}");
    }
    if (lane.consumer_end_ns > lane.consumer_start_ns) {
      write_event(first, "    {\"name\":\"consumer\",\"cat\":\"lane\",\"ph\":\"X\",\"pid\":1,\"tid\":" +
                            std::to_string(consumer_tid) + ",\"ts\":" +
                            std::to_string(lane.consumer_start_ns / 1000) + ",\"dur\":" +
                            std::to_string((lane.consumer_end_ns - lane.consumer_start_ns) / 1000) +
                            ",\"args\":{\"lane\":" + std::to_string(lane_index) + "}}");
    }
  }

  for (std::size_t stress_index = 0; stress_index < stress_threads; ++stress_index) {
    const auto stress_tid = 300 + static_cast<int>(stress_index);
    write_event(first, "    {\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":1,\"tid\":" + std::to_string(stress_tid) +
                          ",\"args\":{\"name\":\"stress-" + std::to_string(stress_index) + "\"}}");
    write_event(first, "    {\"name\":\"stress\",\"cat\":\"load\",\"ph\":\"X\",\"pid\":1,\"tid\":" +
                          std::to_string(stress_tid) + ",\"ts\":0,\"dur\":" +
                          std::to_string(elapsed_ns / 1000) + ",\"args\":{\"index\":" +
                          std::to_string(stress_index) + "}}");
  }

  for (const auto& sample : timeline) {
    const auto ts_us = sample.elapsed_ns / 1000;
    write_event(first, "    {\"name\":\"produced\",\"cat\":\"counters\",\"ph\":\"C\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(ts_us) + ",\"args\":{\"count\":" + std::to_string(sample.produced) + "}}");
    write_event(first, "    {\"name\":\"consumed\",\"cat\":\"counters\",\"ph\":\"C\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(ts_us) + ",\"args\":{\"count\":" + std::to_string(sample.consumed) + "}}");
    write_event(first, "    {\"name\":\"backlog\",\"cat\":\"counters\",\"ph\":\"C\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(ts_us) + ",\"args\":{\"count\":" +
                          std::to_string(sample.produced - sample.consumed) + "}}");

    std::ostringstream interval;
    interval << std::fixed << std::setprecision(3) << sample.interval_mps;
    write_event(first, "    {\"name\":\"interval_mps\",\"cat\":\"counters\",\"ph\":\"C\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(ts_us) + ",\"args\":{\"value\":" + interval.str() + "}}");
  }

  out << "\n  ],\n  \"displayTimeUnit\": \"ns\"\n}\n";
}

void write_timeline_csv(const std::string& path, const std::vector<TimelineSample>& samples) {
  std::ofstream out(path);
  if (!out) {
    throw std::runtime_error("failed to open timeline CSV: " + path);
  }

  out << "elapsed_ms,produced,consumed,interval_mps\n";
  for (const auto& sample : samples) {
    out << std::fixed << std::setprecision(3)
        << (static_cast<double>(sample.elapsed_ns) / 1'000'000.0) << ','
        << sample.produced << ','
        << sample.consumed << ','
        << sample.interval_mps << '\n';
  }
}

std::uint64_t lane_target_messages(std::uint64_t total_messages, std::size_t lanes, std::size_t lane_index) {
  const auto base = total_messages / static_cast<std::uint64_t>(lanes);
  const auto extra = static_cast<std::uint64_t>(lane_index) < (total_messages % static_cast<std::uint64_t>(lanes)) ? 1u : 0u;
  return base + extra;
}

std::uint64_t percentile_from_histogram(
    const std::vector<std::uint64_t>& histogram, std::uint64_t bucket_ns, double percentile, std::uint64_t samples) {
  if (samples == 0) {
    return 0;
  }

  const auto threshold = static_cast<std::uint64_t>(std::ceil((percentile / 100.0) * static_cast<double>(samples)));
  std::uint64_t cumulative = 0;
  for (std::size_t bucket = 0; bucket < histogram.size(); ++bucket) {
    cumulative += histogram[bucket];
    if (cumulative >= threshold) {
      return static_cast<std::uint64_t>(bucket) * bucket_ns;
    }
  }
  return static_cast<std::uint64_t>(histogram.size() - 1) * bucket_ns;
}

template <std::size_t Capacity>
int run_benchmark(const RunConfig& config) {
  struct LaneState {
    smr_machine::SpscRing<LossEvent, Capacity> ring;
    std::atomic<bool> done{false};
    std::atomic<std::uint64_t> produced{0};
  };

  std::vector<std::unique_ptr<LaneState>> lanes;
  lanes.reserve(config.lanes);
  for (std::size_t i = 0; i < config.lanes; ++i) {
    lanes.push_back(std::make_unique<LaneState>());
  }

  std::atomic<bool> stress_done{false};
  std::atomic<bool> reporter_done{false};
  std::atomic<std::uint64_t> total_produced{0};
  std::atomic<std::uint64_t> total_consumed{0};
  std::vector<TimelineSample> timeline;
  std::vector<std::uint64_t> lane_checksums(config.lanes, 0);
  std::vector<LaneTrace> lane_traces(config.lanes);
  std::vector<std::vector<std::uint64_t>> lane_histograms;
  lane_histograms.reserve(config.lanes);
  const auto histogram_buckets = (config.latency_max_ns / config.latency_bucket_ns) + 1;
  for (std::size_t i = 0; i < config.lanes; ++i) {
    lane_histograms.emplace_back(histogram_buckets, 0);
  }
  std::vector<std::uint64_t> lane_min_latency(config.lanes, std::numeric_limits<std::uint64_t>::max());
  std::vector<std::uint64_t> lane_max_latency(config.lanes, 0);
  std::vector<long double> lane_total_latency(config.lanes, 0.0);
  std::vector<std::uint64_t> lane_latency_samples(config.lanes, 0);
  std::vector<std::thread> producers;
  std::vector<std::thread> consumers;
  std::vector<std::thread> stress_threads;

  const auto start = std::chrono::steady_clock::now();
  const auto report_interval = std::chrono::milliseconds(config.report_interval_ms);
  const auto has_duration = config.duration_sec > 0.0;
  const auto duration_limit =
      std::chrono::nanoseconds(static_cast<std::int64_t>(config.duration_sec * 1'000'000'000.0));
  const auto deadline = start + duration_limit;
  std::thread reporter;

  consumers.reserve(config.lanes);
  for (std::size_t lane_index = 0; lane_index < config.lanes; ++lane_index) {
    consumers.emplace_back([&, lane_index]() {
      auto& lane = *lanes[lane_index];
      lane_traces[lane_index].consumer_start_ns = static_cast<std::uint64_t>(
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              std::chrono::steady_clock::now().time_since_epoch())
              .count());
      std::uint64_t checksum = 0;
      std::uint64_t local_consumed = 0;
      auto& histogram = lane_histograms[lane_index];
      auto& local_min = lane_min_latency[lane_index];
      auto& local_max = lane_max_latency[lane_index];
      auto& local_total = lane_total_latency[lane_index];
      while (!lane.done.load(std::memory_order_acquire) ||
             local_consumed < lane.produced.load(std::memory_order_acquire)) {
        if (const auto item = lane.ring.try_pop()) {
          const auto now_ns = static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::nanoseconds>(
                  std::chrono::steady_clock::now().time_since_epoch())
                  .count());
          const auto latency_ns = now_ns >= item->timestamp_ns ? now_ns - item->timestamp_ns : 0;
          const auto bucket =
              std::min<std::size_t>(latency_ns / config.latency_bucket_ns, histogram.size() - 1);
          ++histogram[bucket];
          local_min = std::min(local_min, latency_ns);
          local_max = std::max(local_max, latency_ns);
          local_total += static_cast<long double>(latency_ns);
          checksum += item->sequence ^ static_cast<std::uint64_t>(item->loss_bps);
          ++local_consumed;
          total_consumed.fetch_add(1, std::memory_order_relaxed);
        }
      }
      lane_latency_samples[lane_index] = local_consumed;
      lane_checksums[lane_index] = checksum;
      lane_traces[lane_index].consumer_end_ns = static_cast<std::uint64_t>(
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              std::chrono::steady_clock::now().time_since_epoch())
              .count());
    });
  }

  if (config.report_interval_ms > 0) {
    reporter = std::thread([&]() {
      auto next_report = start + report_interval;
      std::uint64_t last_report_produced = 0;
      while (!reporter_done.load(std::memory_order_acquire)) {
        std::this_thread::sleep_until(next_report);
        const auto now = std::chrono::steady_clock::now();
        const auto produced_now = total_produced.load(std::memory_order_relaxed);
        const auto consumed_now = total_consumed.load(std::memory_order_relaxed);
        const auto elapsed_ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(now - start).count();
        const auto interval_ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(report_interval).count();
        const auto interval_messages = produced_now - last_report_produced;
        const auto interval_mps = interval_ns > 0
                                      ? (static_cast<double>(interval_messages) * 1'000'000'000.0) /
                                            static_cast<double>(interval_ns) / 1'000'000.0
                                      : 0.0;
        timeline.push_back(TimelineSample{
            .elapsed_ns = static_cast<std::uint64_t>(elapsed_ns),
            .produced = produced_now,
            .consumed = consumed_now,
            .interval_mps = interval_mps,
        });
        std::cout << "progress_elapsed_ms=" << std::fixed << std::setprecision(3)
                  << (static_cast<double>(elapsed_ns) / 1'000'000.0) << "\n";
        std::cout << "progress_produced=" << produced_now << "\n";
        std::cout << "progress_consumed=" << consumed_now << "\n";
        std::cout << "progress_backlog=" << (produced_now >= consumed_now ? produced_now - consumed_now : 0) << "\n";
        std::cout << "progress_interval_mps=" << std::fixed << std::setprecision(3) << interval_mps << "\n";
        std::cout << std::flush;
        last_report_produced = produced_now;
        next_report += report_interval;
      }
    });
  }

  stress_threads.reserve(config.stress_threads);
  for (std::size_t stress_index = 0; stress_index < config.stress_threads; ++stress_index) {
    stress_threads.emplace_back([&, stress_index]() {
      const auto word_count = std::max<std::size_t>(config.stress_bytes / sizeof(std::uint64_t), 1024);
      std::vector<std::uint64_t> buffer(word_count, 0x9e3779b97f4a7c15ULL ^ static_cast<std::uint64_t>(stress_index));
      std::uint64_t acc = 0x517cc1b727220a95ULL ^ static_cast<std::uint64_t>(stress_index);
      while (!stress_done.load(std::memory_order_acquire)) {
        for (std::size_t i = 0; i < buffer.size(); i += 16) {
          acc ^= acc << 7;
          acc ^= acc >> 9;
          acc ^= static_cast<std::uint64_t>(i);
          buffer[i] = buffer[i] * 2862933555777941757ULL + acc;
        }
      }
      if (acc == 0) {
        std::cerr << "stress_checksum=0\n";
      }
    });
  }

  producers.reserve(config.lanes);
  for (std::size_t lane_index = 0; lane_index < config.lanes; ++lane_index) {
    producers.emplace_back([&, lane_index]() {
      auto& lane = *lanes[lane_index];
      lane_traces[lane_index].producer_start_ns = static_cast<std::uint64_t>(
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              std::chrono::steady_clock::now().time_since_epoch())
              .count());
      const auto target_messages =
          config.messages.has_value() ? lane_target_messages(*config.messages, config.lanes, lane_index) : 0;
      std::uint64_t sequence = 0;
      const auto sequence_base = static_cast<std::uint64_t>(lane_index) << 48;

      while (true) {
        if (config.messages.has_value() && sequence >= target_messages) {
          break;
        }
        if (has_duration && (sequence & 0x3FFu) == 0u && std::chrono::steady_clock::now() >= deadline) {
          break;
        }

        LossEvent event{
            .sequence = sequence_base + sequence,
            .timestamp_ns = static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::steady_clock::now().time_since_epoch())
                    .count()),
            .loss_bps = static_cast<std::int64_t>((sequence + lane_index) % 2048) - 1024,
            .venue = static_cast<std::int32_t>(lane_index % 4),
            .reserved = static_cast<std::int32_t>(lane_index),
        };

        while (!lane.ring.try_push(event)) {
          if (has_duration && (sequence & 0x3FFu) == 0u && std::chrono::steady_clock::now() >= deadline) {
            goto lane_done;
          }
        }

        ++sequence;
        total_produced.fetch_add(1, std::memory_order_relaxed);
      }

    lane_done:
      lane.produced.store(sequence, std::memory_order_release);
      lane.done.store(true, std::memory_order_release);
      lane_traces[lane_index].producer_end_ns = static_cast<std::uint64_t>(
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              std::chrono::steady_clock::now().time_since_epoch())
              .count());
    });
  }

  for (auto& producer : producers) {
    producer.join();
  }
  for (auto& consumer : consumers) {
    consumer.join();
  }
  stress_done.store(true, std::memory_order_release);
  for (auto& stress_thread : stress_threads) {
    stress_thread.join();
  }
  reporter_done.store(true, std::memory_order_release);
  if (reporter.joinable()) {
    reporter.join();
  }

  const auto end = std::chrono::steady_clock::now();
  const auto ns =
      std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
  const auto total_messages = total_produced.load(std::memory_order_relaxed);
  const double per_message =
      total_messages > 0 ? static_cast<double>(ns) / static_cast<double>(total_messages) : 0.0;
  const double throughput_mps =
      ns > 0 ? (static_cast<double>(total_messages) * 1'000'000'000.0) / static_cast<double>(ns) / 1'000'000.0 : 0.0;
  std::vector<std::uint64_t> merged_histogram(histogram_buckets, 0);
  LatencySummary latency;
  latency.min_ns = std::numeric_limits<std::uint64_t>::max();

  for (std::size_t lane_index = 0; lane_index < config.lanes; ++lane_index) {
    for (std::size_t bucket = 0; bucket < histogram_buckets; ++bucket) {
      merged_histogram[bucket] += lane_histograms[lane_index][bucket];
    }
    latency.samples += lane_latency_samples[lane_index];
    latency.min_ns = std::min(latency.min_ns, lane_min_latency[lane_index]);
    latency.max_ns = std::max(latency.max_ns, lane_max_latency[lane_index]);
    latency.mean_ns += lane_total_latency[lane_index];
  }

  if (latency.samples == 0) {
    latency.min_ns = 0;
  } else {
    latency.mean_ns /= static_cast<long double>(latency.samples);
    latency.p50_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 50.0, latency.samples);
    latency.p55_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 55.0, latency.samples);
    latency.p90_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 90.0, latency.samples);
    latency.p95_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 95.0, latency.samples);
    latency.p99_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 99.0, latency.samples);
    latency.p999_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 99.9, latency.samples);
    latency.p9999_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 99.99, latency.samples);
  }

  if (config.report_interval_ms > 0) {
    timeline.push_back(TimelineSample{
        .elapsed_ns = static_cast<std::uint64_t>(ns),
        .produced = total_messages,
        .consumed = total_consumed.load(std::memory_order_relaxed),
        .interval_mps = throughput_mps,
    });
  }

  if (!config.timeline_csv_path.empty()) {
    write_timeline_csv(config.timeline_csv_path, timeline);
  }
  if (!config.latency_histogram_csv_path.empty()) {
    write_latency_histogram_csv(
        config.latency_histogram_csv_path, merged_histogram, config.latency_bucket_ns, config.latency_max_ns);
  }
  if (!config.trace_event_json_path.empty()) {
    const auto origin_ns = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(start.time_since_epoch()).count());
    auto normalized_lane_traces = lane_traces;
    for (auto& lane : normalized_lane_traces) {
      lane.producer_start_ns = lane.producer_start_ns >= origin_ns ? lane.producer_start_ns - origin_ns : 0;
      lane.producer_end_ns = lane.producer_end_ns >= origin_ns ? lane.producer_end_ns - origin_ns : 0;
      lane.consumer_start_ns = lane.consumer_start_ns >= origin_ns ? lane.consumer_start_ns - origin_ns : 0;
      lane.consumer_end_ns = lane.consumer_end_ns >= origin_ns ? lane.consumer_end_ns - origin_ns : 0;
    }
    write_trace_event_json(
        config.trace_event_json_path, timeline, normalized_lane_traces, config.stress_threads,
        static_cast<std::uint64_t>(ns), config.lanes);
  }

  std::cout << "mode=" << (has_duration ? "duration" : "messages") << "\n";
  if (config.messages.has_value()) {
    std::cout << "target_messages=" << *config.messages << "\n";
  }
  if (has_duration) {
    std::cout << "target_duration_sec=" << config.duration_sec << "\n";
  }
  std::cout << "lanes=" << config.lanes << "\n";
  std::cout << "stress_threads=" << config.stress_threads << "\n";
  std::cout << "stress_bytes=" << config.stress_bytes << "\n";
  std::cout << "messages=" << total_messages << "\n";
  std::cout << "elapsed_ns=" << ns << "\n";
  std::cout << std::fixed << std::setprecision(3);
  std::cout << "ns_per_message=" << per_message << "\n";
  std::cout << "throughput_mps=" << throughput_mps << "\n";
  std::cout << "latency_samples=" << latency.samples << "\n";
  std::cout << "latency_bucket_ns=" << config.latency_bucket_ns << "\n";
  std::cout << "latency_min_ns=" << latency.min_ns << "\n";
  std::cout << "latency_mean_ns=" << std::fixed << std::setprecision(3) << static_cast<double>(latency.mean_ns) << "\n";
  std::cout << "latency_p50_ns=" << latency.p50_ns << "\n";
  std::cout << "latency_p55_ns=" << latency.p55_ns << "\n";
  std::cout << "latency_p90_ns=" << latency.p90_ns << "\n";
  std::cout << "latency_p95_ns=" << latency.p95_ns << "\n";
  std::cout << "latency_p99_ns=" << latency.p99_ns << "\n";
  std::cout << "latency_p999_ns=" << latency.p999_ns << "\n";
  std::cout << "latency_p9999_ns=" << latency.p9999_ns << "\n";
  std::cout << "latency_max_ns=" << latency.max_ns << "\n";
  std::uint64_t checksum = 0;
  for (const auto lane_checksum : lane_checksums) {
    checksum ^= lane_checksum;
  }
  std::cout << "checksum=" << checksum << "\n";
  if (!config.timeline_csv_path.empty()) {
    std::cout << "timeline_csv=" << config.timeline_csv_path << "\n";
  }
  if (!config.latency_histogram_csv_path.empty()) {
    std::cout << "latency_histogram_csv=" << config.latency_histogram_csv_path << "\n";
  }
  if (!config.trace_event_json_path.empty()) {
    std::cout << "trace_event_json=" << config.trace_event_json_path << "\n";
  }
  return 0;
}

std::uint64_t parse_u64(char* value) { return static_cast<std::uint64_t>(std::strtoull(value, nullptr, 10)); }
double parse_f64(char* value) { return std::strtod(value, nullptr); }

}  // namespace

int main(int argc, char** argv) {
  RunConfig config{
      .messages = 1'000'000,
  };
  std::size_t capacity = 1024;

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--messages" && i + 1 < argc) {
      config.messages = parse_u64(argv[++i]);
    } else if (arg == "--duration-sec" && i + 1 < argc) {
      config.duration_sec = parse_f64(argv[++i]);
      config.messages.reset();
    } else if (arg == "--capacity" && i + 1 < argc) {
      capacity = static_cast<std::size_t>(parse_u64(argv[++i]));
    } else if (arg == "--report-interval-ms" && i + 1 < argc) {
      config.report_interval_ms = parse_u64(argv[++i]);
    } else if (arg == "--timeline-csv" && i + 1 < argc) {
      config.timeline_csv_path = argv[++i];
    } else if (arg == "--lanes" && i + 1 < argc) {
      config.lanes = static_cast<std::size_t>(parse_u64(argv[++i]));
    } else if (arg == "--stress-threads" && i + 1 < argc) {
      config.stress_threads = static_cast<std::size_t>(parse_u64(argv[++i]));
    } else if (arg == "--stress-bytes" && i + 1 < argc) {
      config.stress_bytes = static_cast<std::size_t>(parse_u64(argv[++i]));
    } else if (arg == "--latency-bucket-ns" && i + 1 < argc) {
      config.latency_bucket_ns = parse_u64(argv[++i]);
    } else if (arg == "--latency-max-ns" && i + 1 < argc) {
      config.latency_max_ns = parse_u64(argv[++i]);
    } else if (arg == "--latency-histogram-csv" && i + 1 < argc) {
      config.latency_histogram_csv_path = argv[++i];
    } else if (arg == "--trace-event-json" && i + 1 < argc) {
      config.trace_event_json_path = argv[++i];
    } else {
      std::cerr << "usage: spsc_bench [--messages N | --duration-sec SEC] "
                   "[--capacity power-of-two] [--report-interval-ms MS] [--timeline-csv PATH] "
                   "[--lanes N] [--stress-threads N] [--stress-bytes BYTES] "
                   "[--latency-bucket-ns NS] [--latency-max-ns NS] "
                   "[--latency-histogram-csv PATH] [--trace-event-json PATH]\n";
      return 1;
    }
  }

  if (config.lanes == 0) {
    std::cerr << "lanes must be >= 1\n";
    return 1;
  }
  if (config.latency_bucket_ns == 0 || config.latency_max_ns < config.latency_bucket_ns) {
    std::cerr << "invalid latency histogram configuration\n";
    return 1;
  }

  switch (capacity) {
    case 256:
      return run_benchmark<256>(config);
    case 512:
      return run_benchmark<512>(config);
    case 1024:
      return run_benchmark<1024>(config);
    case 2048:
      return run_benchmark<2048>(config);
    case 4096:
      return run_benchmark<4096>(config);
    default:
      std::cerr << "unsupported capacity: " << capacity << "\n";
      return 1;
  }
}
