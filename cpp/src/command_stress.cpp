#include "smr_machine_event_io.hpp"
#include "spsc_ring.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>
#include <unistd.h>

namespace {

using smr_machine::CommandEvent;
using smr_machine::CommandType;
using smr_machine::SideCode;

struct StressConfig {
  std::optional<std::uint64_t> messages = 200'000;
  double duration_sec = 0.0;
  std::size_t lanes = 2;
  std::size_t stress_threads = 0;
  std::size_t stress_bytes = 8 * 1024 * 1024;
  std::uint64_t report_interval_ms = 250;
  std::uint64_t latency_bucket_ns = 1'000;
  std::uint64_t latency_max_ns = 100'000'000;
  std::uint64_t submit_weight = 40;
  std::uint64_t modify_weight = 15;
  std::uint64_t cancel_weight = 15;
  std::uint64_t fill_weight = 25;
  std::uint64_t fail_weight = 5;
  std::uint64_t invalid_bps = 250;
  std::uint64_t seed = 42;
  std::size_t failure_limit = 1;
  std::size_t replay_window = 64;
  std::string summary_json_path;
  std::string timeline_csv_path;
  std::string trace_event_json_path;
  std::string raw_events_jsonl_path;
  std::string raw_events_stream_fifo_path;
  std::string replay_dir_path;
};

struct QueuedCommand {
  CommandEvent event;
  std::uint64_t enqueue_ns;
};

struct TimelineSample {
  std::uint64_t elapsed_ns;
  std::uint64_t produced;
  std::uint64_t consumed;
  std::uint64_t succeeded;
  std::uint64_t failed;
  std::uint64_t backlog;
  double interval_mps;
  double moving_avg_mps;
};

struct WorkerTrace {
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
  double stddev_ns = 0.0;
  double coeff_var = 0.0;
  std::uint64_t p50_ns = 0;
  std::uint64_t p75_ns = 0;
  std::uint64_t p90_ns = 0;
  std::uint64_t p95_ns = 0;
  std::uint64_t p99_ns = 0;
  std::uint64_t p999_ns = 0;
};

struct FailureRecord {
  std::size_t index = 0;
  std::size_t lane = 0;
  std::uint64_t seq = 0;
  std::string reason;
  std::size_t history_index = 0;
};

struct Counters {
  std::uint64_t submit = 0;
  std::uint64_t modify = 0;
  std::uint64_t cancel = 0;
  std::uint64_t fill = 0;
  std::uint64_t fail = 0;
};

struct OrderState {
  std::string trader;
  std::string asset;
  SideCode side = SideCode::Buy;
  std::int32_t open_qty = 0;
  std::int32_t px = 0;
};

struct LaneStats {
  std::vector<std::uint64_t> histogram;
  std::uint64_t min_latency = std::numeric_limits<std::uint64_t>::max();
  std::uint64_t max_latency = 0;
  long double total_latency = 0.0;
  long double total_latency_sq = 0.0;
  std::uint64_t latency_samples = 0;
  Counters produced;
  Counters succeeded;
  Counters failed;
  std::vector<CommandEvent> history;
};

std::uint64_t now_ns() {
  return static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count());
}

std::uint64_t parse_u64(char* value) { return static_cast<std::uint64_t>(std::strtoull(value, nullptr, 10)); }
double parse_f64(char* value) { return std::strtod(value, nullptr); }

void bump_counter(Counters& counters, CommandType type) {
  switch (type) {
    case CommandType::Submit:
      ++counters.submit;
      break;
    case CommandType::Modify:
      ++counters.modify;
      break;
    case CommandType::Cancel:
      ++counters.cancel;
      break;
    case CommandType::Fill:
      ++counters.fill;
      break;
    case CommandType::Fail:
      ++counters.fail;
      break;
  }
}

std::string unpack24(const std::array<char, 24>& buffer) { return smr_machine::unpack_cstr(buffer); }
std::string unpack64(const std::array<char, 64>& buffer) { return smr_machine::unpack_cstr(buffer); }

std::string json_escape(const std::string& input) {
  std::ostringstream out;
  for (const char ch : input) {
    switch (ch) {
      case '\\':
        out << "\\\\";
        break;
      case '"':
        out << "\\\"";
        break;
      case '\n':
        out << "\\n";
        break;
      case '\r':
        out << "\\r";
        break;
      case '\t':
        out << "\\t";
        break;
      default:
        out << ch;
        break;
    }
  }
  return out.str();
}

std::string side_name(SideCode side) { return side == SideCode::Buy ? "BUY" : "SELL"; }

std::string type_name(CommandType type) {
  switch (type) {
    case CommandType::Submit:
      return "SUBMIT";
    case CommandType::Modify:
      return "MODIFY";
    case CommandType::Cancel:
      return "CANCEL";
    case CommandType::Fill:
      return "FILL";
    case CommandType::Fail:
      return "FAIL";
  }
  return "UNKNOWN";
}

std::string asset_from_id(const std::string& id) {
  const auto pos = id.find('-');
  return pos == std::string::npos ? "UNKNOWN" : id.substr(0, pos);
}

void ensure_parent_directory(const std::string& path, const char* label) {
  if (path.empty()) {
    return;
  }
  const auto parent = std::filesystem::path(path).parent_path();
  if (parent.empty()) {
    return;
  }
  auto probe = parent;
  while (!probe.empty() && !std::filesystem::exists(probe)) {
    probe = probe.parent_path();
  }
  if (!probe.empty() && std::filesystem::exists(probe) && !std::filesystem::is_directory(probe)) {
    throw std::runtime_error(std::string(label) + " path conflicts with file: " + probe.string());
  }
  std::filesystem::create_directories(parent);
}

void ensure_output_directory(const std::string& path, const char* label) {
  if (path.empty()) {
    return;
  }
  const auto dir = std::filesystem::path(path);
  auto probe = dir;
  while (!probe.empty() && !std::filesystem::exists(probe)) {
    probe = probe.parent_path();
  }
  if (!probe.empty() && std::filesystem::exists(probe) && !std::filesystem::is_directory(probe)) {
    throw std::runtime_error(std::string(label) + " path conflicts with file: " + probe.string());
  }
  std::filesystem::create_directories(dir);
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

void write_timeline_csv(const std::string& path, const std::vector<TimelineSample>& samples) {
  std::ofstream out(path);
  if (!out) {
    throw std::runtime_error("failed to open timeline CSV: " + path);
  }
  out << "elapsed_ms,produced,consumed,succeeded,failed,backlog,interval_mps,moving_avg_mps\n";
  for (const auto& sample : samples) {
    out << std::fixed << std::setprecision(3) << (static_cast<double>(sample.elapsed_ns) / 1'000'000.0) << ','
        << sample.produced << ',' << sample.consumed << ',' << sample.succeeded << ',' << sample.failed << ','
        << sample.backlog << ',' << sample.interval_mps << ',' << sample.moving_avg_mps << '\n';
  }
}

void write_trace_event_json(
    const std::string& path,
    const std::vector<TimelineSample>& timeline,
    const std::vector<WorkerTrace>& traces,
    const std::vector<FailureRecord>& failures,
    std::uint64_t elapsed_ns,
    std::size_t lanes,
    std::size_t stress_threads) {
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
  write_event(first, "    {\"name\":\"process_name\",\"ph\":\"M\",\"pid\":1,\"tid\":0,\"args\":{\"name\":\"command_stress\"}}");
  write_event(first, "    {\"name\":\"benchmark\",\"cat\":\"run\",\"ph\":\"X\",\"pid\":1,\"tid\":1,\"ts\":0,\"dur\":" +
                        std::to_string(elapsed_ns / 1000) + "}");

  for (std::size_t lane = 0; lane < lanes; ++lane) {
    const auto producer_tid = 100 + static_cast<int>(lane);
    const auto consumer_tid = 200 + static_cast<int>(lane);
    write_event(first, "    {\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":1,\"tid\":" + std::to_string(producer_tid) +
                          ",\"args\":{\"name\":\"producer-lane-" + std::to_string(lane) + "\"}}");
    write_event(first, "    {\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":1,\"tid\":" + std::to_string(consumer_tid) +
                          ",\"args\":{\"name\":\"consumer-lane-" + std::to_string(lane) + "\"}}");
    const auto& trace = traces[lane];
    if (trace.producer_end_ns > trace.producer_start_ns) {
      write_event(first, "    {\"name\":\"producer\",\"cat\":\"lane\",\"ph\":\"X\",\"pid\":1,\"tid\":" +
                            std::to_string(producer_tid) + ",\"ts\":" +
                            std::to_string(trace.producer_start_ns / 1000) + ",\"dur\":" +
                            std::to_string((trace.producer_end_ns - trace.producer_start_ns) / 1000) +
                            ",\"args\":{\"lane\":" + std::to_string(lane) + "}}");
    }
    if (trace.consumer_end_ns > trace.consumer_start_ns) {
      write_event(first, "    {\"name\":\"consumer\",\"cat\":\"lane\",\"ph\":\"X\",\"pid\":1,\"tid\":" +
                            std::to_string(consumer_tid) + ",\"ts\":" +
                            std::to_string(trace.consumer_start_ns / 1000) + ",\"dur\":" +
                            std::to_string((trace.consumer_end_ns - trace.consumer_start_ns) / 1000) +
                            ",\"args\":{\"lane\":" + std::to_string(lane) + "}}");
    }
  }

  for (std::size_t stress = 0; stress < stress_threads; ++stress) {
    const auto tid = 300 + static_cast<int>(stress);
    write_event(first, "    {\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":1,\"tid\":" + std::to_string(tid) +
                          ",\"args\":{\"name\":\"stress-" + std::to_string(stress) + "\"}}");
    write_event(first, "    {\"name\":\"stress\",\"cat\":\"load\",\"ph\":\"X\",\"pid\":1,\"tid\":" + std::to_string(tid) +
                          ",\"ts\":0,\"dur\":" + std::to_string(elapsed_ns / 1000) + "}");
  }

  for (const auto& sample : timeline) {
    const auto ts_us = sample.elapsed_ns / 1000;
    write_event(first, "    {\"name\":\"produced\",\"cat\":\"counters\",\"ph\":\"C\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(ts_us) + ",\"args\":{\"count\":" + std::to_string(sample.produced) + "}}");
    write_event(first, "    {\"name\":\"consumed\",\"cat\":\"counters\",\"ph\":\"C\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(ts_us) + ",\"args\":{\"count\":" + std::to_string(sample.consumed) + "}}");
    write_event(first, "    {\"name\":\"failures\",\"cat\":\"counters\",\"ph\":\"C\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(ts_us) + ",\"args\":{\"count\":" + std::to_string(sample.failed) + "}}");
    write_event(first, "    {\"name\":\"backlog\",\"cat\":\"counters\",\"ph\":\"C\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(ts_us) + ",\"args\":{\"count\":" + std::to_string(sample.backlog) + "}}");
    std::ostringstream interval;
    interval << std::fixed << std::setprecision(3) << sample.interval_mps;
    write_event(first, "    {\"name\":\"interval_mps\",\"cat\":\"counters\",\"ph\":\"C\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(ts_us) + ",\"args\":{\"value\":" + interval.str() + "}}");
    std::ostringstream moving;
    moving << std::fixed << std::setprecision(3) << sample.moving_avg_mps;
    write_event(first, "    {\"name\":\"moving_avg_mps\",\"cat\":\"counters\",\"ph\":\"C\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(ts_us) + ",\"args\":{\"value\":" + moving.str() + "}}");
  }

  for (const auto& failure : failures) {
    write_event(first, "    {\"name\":\"failure\",\"cat\":\"error\",\"ph\":\"i\",\"s\":\"g\",\"pid\":1,\"tid\":1,\"ts\":" +
                          std::to_string(failure.seq) + ",\"args\":{\"lane\":" + std::to_string(failure.lane) +
                          ",\"reason\":\"" + json_escape(failure.reason) + "\"}}");
  }

  out << "\n  ],\n  \"displayTimeUnit\": \"ns\"\n}\n";
}

void write_summary_json(
    const std::string& path,
    const StressConfig& config,
    const Counters& produced,
    const Counters& succeeded,
    const Counters& failed,
    const LatencySummary& latency,
    const std::vector<TimelineSample>& timeline,
    const std::vector<FailureRecord>& failures,
    std::uint64_t elapsed_ns,
    std::uint64_t messages,
    double throughput_mps,
    double ns_per_message,
    std::uint64_t max_backlog,
    double throughput_jitter_mps,
    std::uint64_t dropped_after_limit) {
  std::ofstream out(path);
  if (!out) {
    throw std::runtime_error("failed to open summary JSON: " + path);
  }

  out << "{\n";
  out << "  \"config\": {\n";
  out << "    \"mode\": \"" << (config.duration_sec > 0.0 ? "duration" : "messages") << "\",\n";
  if (config.messages.has_value()) {
    out << "    \"messages\": " << *config.messages << ",\n";
  } else {
    out << "    \"messages\": null,\n";
  }
  out << "    \"duration_sec\": " << config.duration_sec << ",\n";
  out << "    \"lanes\": " << config.lanes << ",\n";
  out << "    \"stress_threads\": " << config.stress_threads << ",\n";
  out << "    \"stress_bytes\": " << config.stress_bytes << ",\n";
  out << "    \"report_interval_ms\": " << config.report_interval_ms << ",\n";
  out << "    \"failure_limit\": " << config.failure_limit << ",\n";
  out << "    \"replay_window\": " << config.replay_window << ",\n";
  out << "    \"seed\": " << config.seed << "\n";
  out << "  },\n";
  out << "  \"throughput\": {\n";
  out << "    \"messages\": " << messages << ",\n";
  out << "    \"elapsed_ns\": " << elapsed_ns << ",\n";
  out << "    \"ns_per_message\": " << std::fixed << std::setprecision(3) << ns_per_message << ",\n";
  out << "    \"throughput_mps\": " << throughput_mps << ",\n";
  out << "    \"max_backlog\": " << max_backlog << ",\n";
  out << "    \"throughput_jitter_mps\": " << throughput_jitter_mps << ",\n";
  out << "    \"dropped_after_failure_limit\": " << dropped_after_limit << "\n";
  out << "  },\n";
  out << "  \"latency\": {\n";
  out << "    \"samples\": " << latency.samples << ",\n";
  out << "    \"min_ns\": " << latency.min_ns << ",\n";
  out << "    \"mean_ns\": " << static_cast<double>(latency.mean_ns) << ",\n";
  out << "    \"stddev_ns\": " << latency.stddev_ns << ",\n";
  out << "    \"coefficient_of_variation\": " << latency.coeff_var << ",\n";
  out << "    \"p50_ns\": " << latency.p50_ns << ",\n";
  out << "    \"p75_ns\": " << latency.p75_ns << ",\n";
  out << "    \"p90_ns\": " << latency.p90_ns << ",\n";
  out << "    \"p95_ns\": " << latency.p95_ns << ",\n";
  out << "    \"p99_ns\": " << latency.p99_ns << ",\n";
  out << "    \"p999_ns\": " << latency.p999_ns << ",\n";
  out << "    \"max_ns\": " << latency.max_ns << "\n";
  out << "  },\n";
  auto write_counts = [&](const char* name, const Counters& counts, bool trailing_comma) {
    out << "  \"" << name << "\": {\n";
    out << "    \"submit\": " << counts.submit << ",\n";
    out << "    \"modify\": " << counts.modify << ",\n";
    out << "    \"cancel\": " << counts.cancel << ",\n";
    out << "    \"fill\": " << counts.fill << ",\n";
    out << "    \"fail\": " << counts.fail << "\n";
    out << "  }" << (trailing_comma ? "," : "") << "\n";
  };
  write_counts("produced", produced, true);
  write_counts("succeeded", succeeded, true);
  write_counts("failed", failed, true);
  out << "  \"timeline_samples\": " << timeline.size() << ",\n";
  out << "  \"failures\": [\n";
  for (std::size_t i = 0; i < failures.size(); ++i) {
    const auto& failure = failures[i];
    out << "    {\"index\": " << failure.index << ", \"lane\": " << failure.lane << ", \"seq\": " << failure.seq
        << ", \"reason\": \"" << json_escape(failure.reason) << "\"}";
    out << (i + 1 < failures.size() ? ",\n" : "\n");
  }
  out << "  ]\n";
  out << "}\n";
}

std::uint64_t choose_weighted(
    std::mt19937_64& rng,
    std::uint64_t submit_weight,
    std::uint64_t modify_weight,
    std::uint64_t cancel_weight,
    std::uint64_t fill_weight,
    std::uint64_t fail_weight) {
  const auto total = submit_weight + modify_weight + cancel_weight + fill_weight + fail_weight;
  if (total == 0) {
    return 0;
  }
  std::uniform_int_distribution<std::uint64_t> dist(0, total - 1);
  return dist(rng);
}

template <std::size_t Capacity>
int run_stress(const StressConfig& config) {
  struct RawEventStreamWriter {
    int fd = -1;
    ~RawEventStreamWriter() {
      if (fd >= 0) {
        ::close(fd);
      }
    }
    void open_if_needed(const std::string& path) {
      if (path.empty() || fd >= 0) {
        return;
      }
      fd = ::open(path.c_str(), O_WRONLY | O_NONBLOCK);
      if (fd < 0) {
        if (errno == ENXIO || errno == ENOENT) {
          return;
        }
        throw std::runtime_error("failed to open raw event stream fifo: " + path);
      }
    }
    void write_line(const std::string& path, const std::string& line) {
      if (path.empty()) {
        return;
      }
      open_if_needed(path);
      if (fd < 0) {
        return;
      }
      const char* data = line.data();
      std::size_t remaining = line.size();
      while (remaining > 0) {
        const auto written = ::write(fd, data, remaining);
        if (written < 0) {
          if (errno == EPIPE || errno == EAGAIN || errno == EWOULDBLOCK) {
            ::close(fd);
            fd = -1;
            return;
          }
          throw std::runtime_error("failed to write raw event stream fifo: " + path);
        }
        data += written;
        remaining -= static_cast<std::size_t>(written);
      }
    }
  };

  struct LaneRuntime {
    smr_machine::SpscRing<QueuedCommand, Capacity> ring;
    std::atomic<bool> done{false};
    std::atomic<std::uint64_t> produced{0};
    std::atomic<std::uint64_t> consumed{0};
  };

  std::vector<std::unique_ptr<LaneRuntime>> lanes;
  lanes.reserve(config.lanes);
  for (std::size_t i = 0; i < config.lanes; ++i) {
    lanes.push_back(std::make_unique<LaneRuntime>());
  }

  std::vector<LaneStats> lane_stats;
  lane_stats.reserve(config.lanes);
  const auto histogram_buckets = (config.latency_max_ns / config.latency_bucket_ns) + 1;
  for (std::size_t i = 0; i < config.lanes; ++i) {
    lane_stats.push_back(LaneStats{.histogram = std::vector<std::uint64_t>(histogram_buckets, 0)});
  }

  std::vector<WorkerTrace> traces(config.lanes);
  std::vector<std::thread> producers;
  std::vector<std::thread> consumers;
  std::vector<std::thread> stress_threads;
  std::vector<TimelineSample> timeline;
  std::vector<FailureRecord> failures;
  std::mutex failure_mutex;

  std::atomic<bool> stop_requested{false};
  std::atomic<bool> stress_done{false};
  std::atomic<bool> reporter_done{false};
  std::atomic<std::uint64_t> total_produced{0};
  std::atomic<std::uint64_t> total_consumed{0};
  std::atomic<std::uint64_t> total_succeeded{0};
  std::atomic<std::uint64_t> total_failed{0};
  std::atomic<std::uint64_t> total_dropped{0};
  std::atomic<std::uint64_t> global_seq{0};
  std::mutex raw_event_mutex;
  std::unique_ptr<std::ofstream> raw_event_log;
  RawEventStreamWriter raw_event_stream;

  if (!config.raw_events_jsonl_path.empty()) {
    raw_event_log = std::make_unique<std::ofstream>(config.raw_events_jsonl_path, std::ios::trunc);
    if (!*raw_event_log) {
      throw std::runtime_error("failed to open raw events JSONL: " + config.raw_events_jsonl_path);
    }
  }

  auto log_raw_event = [&](std::uint64_t seq,
                           std::size_t lane,
                           const CommandEvent& event,
                           const std::string& status,
                           const std::string& trader,
                           const std::string& asset,
                           SideCode side,
                           std::int32_t remaining_qty,
                           std::uint64_t latency_ns,
                           std::uint64_t observed_ns,
                           const std::string& reason) {
    if (!raw_event_log && config.raw_events_stream_fifo_path.empty()) {
      return;
    }
    std::ostringstream line;
    line << "{\"seq\":" << seq << ",\"lane\":" << lane << ",\"ts_ns\":" << event.ts_ns
         << ",\"observed_ns\":" << observed_ns << ",\"latency_ns\":" << latency_ns
         << ",\"status\":\"" << status << "\",\"type\":\"" << type_name(event.type)
         << "\",\"id\":\"" << json_escape(unpack24(event.id)) << "\",\"asset\":\""
         << json_escape(asset) << "\",\"trader\":\"" << json_escape(trader) << "\",\"side\":\""
         << side_name(side) << "\",\"qty\":" << event.qty << ",\"px\":" << event.px
         << ",\"remaining_qty\":" << remaining_qty << ",\"reason\":\"" << json_escape(reason) << "\"}\n";
    std::lock_guard<std::mutex> lock(raw_event_mutex);
    if (raw_event_log) {
      *raw_event_log << line.str();
      raw_event_log->flush();
    }
    raw_event_stream.write_line(config.raw_events_stream_fifo_path, line.str());
  };

  const auto start = std::chrono::steady_clock::now();
  const auto has_duration = config.duration_sec > 0.0;
  const auto duration_limit =
      std::chrono::nanoseconds(static_cast<std::int64_t>(config.duration_sec * 1'000'000'000.0));
  const auto deadline = start + duration_limit;
  const auto report_interval = std::chrono::milliseconds(config.report_interval_ms);
  std::thread reporter;

  if (config.report_interval_ms > 0) {
    reporter = std::thread([&]() {
      auto next_report = start + report_interval;
      std::uint64_t last_produced = 0;
      double moving_avg_mps = 0.0;
      while (!reporter_done.load(std::memory_order_acquire)) {
        std::this_thread::sleep_until(next_report);
        const auto now = std::chrono::steady_clock::now();
        const auto produced_now = total_produced.load(std::memory_order_relaxed);
        const auto consumed_now = total_consumed.load(std::memory_order_relaxed);
        const auto succeeded_now = total_succeeded.load(std::memory_order_relaxed);
        const auto failed_now = total_failed.load(std::memory_order_relaxed);
        const auto elapsed_ns =
            static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(now - start).count());
        const auto interval_ns =
            static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(report_interval).count());
        const auto interval_messages = produced_now - last_produced;
        const auto interval_mps = interval_ns > 0
                                      ? (static_cast<double>(interval_messages) * 1'000'000'000.0) /
                                            static_cast<double>(interval_ns) / 1'000'000.0
                                      : 0.0;
        moving_avg_mps = moving_avg_mps == 0.0 ? interval_mps : (moving_avg_mps * 0.8) + (interval_mps * 0.2);
        timeline.push_back(TimelineSample{
            .elapsed_ns = elapsed_ns,
            .produced = produced_now,
            .consumed = consumed_now,
            .succeeded = succeeded_now,
            .failed = failed_now,
            .backlog = produced_now >= consumed_now ? produced_now - consumed_now : 0,
            .interval_mps = interval_mps,
            .moving_avg_mps = moving_avg_mps,
        });
        std::cout << "progress_elapsed_ms=" << std::fixed << std::setprecision(3)
                  << (static_cast<double>(elapsed_ns) / 1'000'000.0) << "\n";
        std::cout << "progress_produced=" << produced_now << "\n";
        std::cout << "progress_consumed=" << consumed_now << "\n";
        std::cout << "progress_succeeded=" << succeeded_now << "\n";
        std::cout << "progress_failed=" << failed_now << "\n";
        std::cout << "progress_backlog=" << (produced_now >= consumed_now ? produced_now - consumed_now : 0) << "\n";
        std::cout << "progress_interval_mps=" << std::fixed << std::setprecision(3) << interval_mps << "\n";
        std::cout << "progress_moving_avg_mps=" << std::fixed << std::setprecision(3) << moving_avg_mps << "\n";
        std::cout << std::flush;
        last_produced = produced_now;
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

  consumers.reserve(config.lanes);
  for (std::size_t lane_index = 0; lane_index < config.lanes; ++lane_index) {
    consumers.emplace_back([&, lane_index]() {
      auto& lane = *lanes[lane_index];
      auto& stats = lane_stats[lane_index];
      std::unordered_map<std::string, OrderState> orders;
      traces[lane_index].consumer_start_ns = now_ns();
      while (!lane.done.load(std::memory_order_acquire) ||
             lane.consumed.load(std::memory_order_acquire) < lane.produced.load(std::memory_order_acquire)) {
        const auto item = lane.ring.try_pop();
        if (!item.has_value()) {
          continue;
        }

        ++lane.consumed;
        total_consumed.fetch_add(1, std::memory_order_relaxed);

        if (stop_requested.load(std::memory_order_acquire) &&
            total_failed.load(std::memory_order_relaxed) >= config.failure_limit) {
          total_dropped.fetch_add(1, std::memory_order_relaxed);
          const auto dropped_id = unpack24(item->event.id);
          const auto dropped_asset = dropped_id.empty() ? "UNKNOWN" : asset_from_id(dropped_id);
          log_raw_event(
              0,
              lane_index,
              item->event,
              "dropped",
              item->event.type == CommandType::Submit ? unpack24(item->event.trader) : "",
              dropped_asset,
              item->event.side,
              0,
              0,
              now_ns(),
              "dropped_after_failure_limit");
          continue;
        }

        stats.history.push_back(item->event);

        const auto observed_ns = now_ns();
        const auto latency_ns = observed_ns >= item->enqueue_ns ? observed_ns - item->enqueue_ns : 0;
        const auto bucket = std::min<std::size_t>(latency_ns / config.latency_bucket_ns, stats.histogram.size() - 1);
        ++stats.histogram[bucket];
        stats.min_latency = std::min(stats.min_latency, latency_ns);
        stats.max_latency = std::max(stats.max_latency, latency_ns);
        stats.total_latency += static_cast<long double>(latency_ns);
        stats.total_latency_sq += static_cast<long double>(latency_ns) * static_cast<long double>(latency_ns);
        ++stats.latency_samples;

        const auto seq = global_seq.fetch_add(1, std::memory_order_relaxed) + 1;
        const auto type = item->event.type;
        auto failure_reason = std::string{};
        auto is_error = false;
        auto event_trader = std::string{};
        auto event_asset = std::string{};
        auto event_side = item->event.side;
        auto remaining_qty = 0;

        const auto id = unpack24(item->event.id);
        switch (type) {
          case CommandType::Submit:
            if (item->event.qty <= 0 || item->event.px <= 0) {
              is_error = true;
              failure_reason = "submit must have positive qty and px";
            } else if (orders.contains(id)) {
              is_error = true;
              failure_reason = "duplicate order id: " + id;
            } else {
              event_trader = unpack24(item->event.trader);
              event_asset = asset_from_id(id);
              event_side = item->event.side;
              remaining_qty = item->event.qty;
              orders.emplace(id, OrderState{
                                  .trader = event_trader,
                                  .asset = event_asset,
                                  .side = item->event.side,
                                  .open_qty = item->event.qty,
                                  .px = item->event.px,
                              });
            }
            break;
          case CommandType::Modify: {
            auto it = orders.find(id);
            if (item->event.qty <= 0 || item->event.px <= 0) {
              is_error = true;
              failure_reason = "modify must have positive qty and px";
            } else if (it == orders.end()) {
              is_error = true;
              failure_reason = "modify for unknown order: " + id;
            } else {
              event_trader = it->second.trader;
              event_asset = it->second.asset;
              event_side = it->second.side;
              it->second.open_qty = item->event.qty;
              it->second.px = item->event.px;
              remaining_qty = it->second.open_qty;
            }
            break;
          }
          case CommandType::Cancel:
            if (const auto it = orders.find(id); it == orders.end()) {
              is_error = true;
              failure_reason = "cancel for unknown order: " + id;
            } else {
              event_trader = it->second.trader;
              event_asset = it->second.asset;
              event_side = it->second.side;
              remaining_qty = 0;
              orders.erase(it);
            }
            break;
          case CommandType::Fill: {
            auto it = orders.find(id);
            if (item->event.qty <= 0 || item->event.px <= 0) {
              is_error = true;
              failure_reason = "fill must have positive qty and px";
            } else if (it == orders.end()) {
              is_error = true;
              failure_reason = "fill for unknown order: " + id;
            } else if (item->event.qty > it->second.open_qty) {
              is_error = true;
              failure_reason = "overfill on order: " + id;
            } else {
              event_trader = it->second.trader;
              event_asset = it->second.asset;
              event_side = it->second.side;
              it->second.open_qty -= item->event.qty;
              remaining_qty = it->second.open_qty;
              if (it->second.open_qty == 0) {
                orders.erase(it);
              }
            }
            break;
          }
          case CommandType::Fail:
            is_error = true;
            failure_reason = unpack64(item->event.reason);
            event_asset = "SYSTEM";
            event_trader = "system";
            event_side = SideCode::Buy;
            break;
        }

        if (event_asset.empty() && !id.empty()) {
          event_asset = asset_from_id(id);
        }

        if (is_error) {
          bump_counter(stats.failed, type);
          total_failed.fetch_add(1, std::memory_order_relaxed);
          log_raw_event(
              seq, lane_index, item->event, "failed", event_trader, event_asset, event_side, remaining_qty,
              latency_ns, observed_ns, failure_reason);
          std::lock_guard<std::mutex> lock(failure_mutex);
          failures.push_back(FailureRecord{
              .index = failures.size() + 1,
              .lane = lane_index,
              .seq = seq,
              .reason = failure_reason,
              .history_index = stats.history.size() - 1,
          });
          if (failures.size() >= config.failure_limit) {
            stop_requested.store(true, std::memory_order_release);
          }
        } else {
          bump_counter(stats.succeeded, type);
          total_succeeded.fetch_add(1, std::memory_order_relaxed);
          log_raw_event(
              seq, lane_index, item->event, "ok", event_trader, event_asset, event_side, remaining_qty, latency_ns,
              observed_ns, "");
        }
      }
      traces[lane_index].consumer_end_ns = now_ns();
    });
  }

  producers.reserve(config.lanes);
  for (std::size_t lane_index = 0; lane_index < config.lanes; ++lane_index) {
    producers.emplace_back([&, lane_index]() {
      auto& lane = *lanes[lane_index];
      auto& stats = lane_stats[lane_index];
      traces[lane_index].producer_start_ns = now_ns();
      std::mt19937_64 rng(config.seed + static_cast<std::uint64_t>(lane_index * 7919));
      std::uniform_int_distribution<int> side_dist(0, 1);
      std::uniform_int_distribution<int> invalid_dist(1, 10'000);
      const std::array<std::string, 8> assets{"AAPL", "MSFT", "NVDA", "TSLA", "SPY", "AMD", "META", "QQQ"};
      const std::array<int, 8> base_prices{185, 410, 900, 190, 510, 170, 480, 440};
      const std::array<std::string, 6> traders{"alpha", "beta", "gamma", "delta", "sigma", "omega"};
      std::uniform_int_distribution<std::size_t> asset_pick(0, assets.size() - 1);
      std::uniform_int_distribution<std::size_t> trader_pick(0, traders.size() - 1);
      std::vector<std::pair<std::string, OrderState>> local_orders;
      std::uint64_t produced = 0;

      auto sample_qty = [&](std::mt19937_64& local_rng) {
        std::uniform_int_distribution<int> tier_pick(1, 100);
        const auto tier = tier_pick(local_rng);
        if (tier <= 55) {
          std::uniform_int_distribution<int> small(1, 16);
          return small(local_rng);
        }
        if (tier <= 85) {
          std::uniform_int_distribution<int> medium(17, 250);
          return medium(local_rng);
        }
        if (tier <= 95) {
          std::uniform_int_distribution<int> large(251, 5000);
          return large(local_rng);
        }
        std::uniform_int_distribution<int> huge(5001, 20000);
        return huge(local_rng);
      };

      auto sample_px = [&](std::mt19937_64& local_rng, std::size_t asset_index) {
        const auto base = base_prices[asset_index];
        std::uniform_int_distribution<int> shock_pick(1, 100);
        const auto shock = shock_pick(local_rng);
        if (shock <= 70) {
          std::uniform_int_distribution<int> tight(-2, 2);
          return std::max(1, base + tight(local_rng));
        }
        if (shock <= 92) {
          std::uniform_int_distribution<int> medium(-12, 12);
          return std::max(1, base + medium(local_rng));
        }
        std::uniform_int_distribution<int> wide(-40, 40);
        return std::max(1, base + wide(local_rng));
      };

      auto active_index = [&](std::mt19937_64& local_rng) -> std::optional<std::size_t> {
        std::vector<std::size_t> active;
        for (std::size_t i = 0; i < local_orders.size(); ++i) {
          if (local_orders[i].second.open_qty > 0) {
            active.push_back(i);
          }
        }
        if (active.empty()) {
          return std::nullopt;
        }
        std::uniform_int_distribution<std::size_t> pick(0, active.size() - 1);
        return active[pick(local_rng)];
      };

      while (!stop_requested.load(std::memory_order_acquire)) {
        if (config.messages.has_value() && produced >= *config.messages / config.lanes + 1) {
          break;
        }
        if (has_duration && produced % 1024 == 0 && std::chrono::steady_clock::now() >= deadline) {
          break;
        }

        auto submit_weight = config.submit_weight;
        auto modify_weight = config.modify_weight;
        auto cancel_weight = config.cancel_weight;
        auto fill_weight = config.fill_weight;
        auto fail_weight = config.fail_weight;
        auto invalid_bps = config.invalid_bps;
        if (has_duration && config.duration_sec > 0.0) {
          const auto elapsed_ratio =
              std::clamp(std::chrono::duration_cast<std::chrono::duration<double>>(std::chrono::steady_clock::now() - start)
                             .count() /
                             config.duration_sec,
                         0.0, 1.0);
          if (elapsed_ratio < 0.15) {
            submit_weight += 20;
            fill_weight += 8;
          } else if (elapsed_ratio < 0.45) {
            modify_weight += 18;
            fill_weight += 10;
          } else if (elapsed_ratio < 0.75) {
            cancel_weight += 24;
            modify_weight += 8;
            invalid_bps += 20;
          } else {
            cancel_weight += 30;
            fail_weight += 6;
            invalid_bps += 40;
          }
        }

        const auto invalid = invalid_dist(rng) <= static_cast<int>(invalid_bps);
        const auto weighted = choose_weighted(rng, submit_weight, modify_weight, cancel_weight, fill_weight, fail_weight);
        std::uint64_t cursor = submit_weight;
        CommandEvent event{};

        if (local_orders.empty() || weighted < submit_weight) {
          const auto asset_index = asset_pick(rng);
          const auto asset = assets[asset_index];
          const auto trader = traders[trader_pick(rng)];
          const auto id = asset + "-l" + std::to_string(lane_index) + "-" + std::to_string(produced);
          const auto qty = sample_qty(rng);
          const auto px = sample_px(rng, asset_index);
          const auto side = side_dist(rng) == 0 ? SideCode::Buy : SideCode::Sell;
          event = smr_machine::make_submit(now_ns(), id, trader, side, qty, px);
          local_orders.push_back(
              {id, OrderState{.trader = trader, .asset = asset, .side = side, .open_qty = qty, .px = px}});
        } else if ((cursor += modify_weight) > weighted) {
          const auto idx = active_index(rng);
          if (!idx.has_value() || invalid) {
            event = smr_machine::make_modify(now_ns(), "missing-mod", sample_qty(rng), sample_px(rng, asset_pick(rng)));
          } else {
            const auto asset_index = static_cast<std::size_t>(
                std::distance(assets.begin(), std::find(assets.begin(), assets.end(), local_orders[*idx].second.asset)));
            const auto qty = sample_qty(rng);
            const auto px = sample_px(rng, asset_index < assets.size() ? asset_index : 0);
            local_orders[*idx].second.open_qty = qty;
            local_orders[*idx].second.px = px;
            event = smr_machine::make_modify(now_ns(), local_orders[*idx].first, qty, px);
          }
        } else if ((cursor += cancel_weight) > weighted) {
          const auto idx = active_index(rng);
          if (!idx.has_value() || invalid) {
            event = smr_machine::make_cancel(now_ns(), "missing-cxl");
          } else {
            local_orders[*idx].second.open_qty = 0;
            event = smr_machine::make_cancel(now_ns(), local_orders[*idx].first);
          }
        } else if ((cursor += fill_weight) > weighted) {
          const auto idx = active_index(rng);
          if (!idx.has_value()) {
            const auto asset_index = asset_pick(rng);
            const auto asset = assets[asset_index];
            const auto id = asset + "-boot-" + std::to_string(lane_index) + "-" + std::to_string(produced);
            const auto qty = sample_qty(rng);
            const auto px = sample_px(rng, asset_index);
            const auto trader = traders[trader_pick(rng)];
            event = smr_machine::make_submit(now_ns(), id, trader, SideCode::Buy, qty, px);
            local_orders.push_back(
                {id, OrderState{.trader = trader, .asset = asset, .side = SideCode::Buy, .open_qty = qty, .px = px}});
          } else if (invalid) {
            const auto asset_index = static_cast<std::size_t>(
                std::distance(assets.begin(), std::find(assets.begin(), assets.end(), local_orders[*idx].second.asset)));
            event = smr_machine::make_fill(
                now_ns(), local_orders[*idx].first, local_orders[*idx].second.open_qty + 1,
                sample_px(rng, asset_index < assets.size() ? asset_index : 0));
          } else {
            std::uniform_int_distribution<int> fill_qty_dist(1, std::max(1, local_orders[*idx].second.open_qty));
            const auto fill_qty = fill_qty_dist(rng);
            local_orders[*idx].second.open_qty -= fill_qty;
            event = smr_machine::make_fill(now_ns(), local_orders[*idx].first, fill_qty, local_orders[*idx].second.px);
          }
        } else {
          event = smr_machine::make_fail(now_ns(), invalid ? "synthetic-risk-limit-breach" : "synthetic-venue-pause");
        }

        const QueuedCommand queued{
            .event = event,
            .enqueue_ns = now_ns(),
        };
        auto pushed = false;
        while (!(pushed = lane.ring.try_push(queued))) {
          if (stop_requested.load(std::memory_order_acquire)) {
            break;
          }
        }
        if (!pushed) {
          break;
        }

        ++produced;
        lane.produced.store(produced, std::memory_order_release);
        total_produced.fetch_add(1, std::memory_order_relaxed);
        bump_counter(stats.produced, event.type);
      }

      lane.done.store(true, std::memory_order_release);
      traces[lane_index].producer_end_ns = now_ns();
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
  const auto elapsed_ns =
      static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count());
  const auto produced_messages = total_produced.load(std::memory_order_relaxed);
  const auto ns_per_message =
      produced_messages > 0 ? static_cast<double>(elapsed_ns) / static_cast<double>(produced_messages) : 0.0;
  const auto throughput_mps =
      elapsed_ns > 0 ? (static_cast<double>(produced_messages) * 1'000'000'000.0) / static_cast<double>(elapsed_ns) /
                           1'000'000.0
                     : 0.0;

  Counters produced_counts{};
  Counters succeeded_counts{};
  Counters failed_counts{};
  std::vector<std::uint64_t> merged_histogram(histogram_buckets, 0);
  LatencySummary latency;
  latency.min_ns = std::numeric_limits<std::uint64_t>::max();

  for (const auto& stats : lane_stats) {
    produced_counts.submit += stats.produced.submit;
    produced_counts.modify += stats.produced.modify;
    produced_counts.cancel += stats.produced.cancel;
    produced_counts.fill += stats.produced.fill;
    produced_counts.fail += stats.produced.fail;
    succeeded_counts.submit += stats.succeeded.submit;
    succeeded_counts.modify += stats.succeeded.modify;
    succeeded_counts.cancel += stats.succeeded.cancel;
    succeeded_counts.fill += stats.succeeded.fill;
    succeeded_counts.fail += stats.succeeded.fail;
    failed_counts.submit += stats.failed.submit;
    failed_counts.modify += stats.failed.modify;
    failed_counts.cancel += stats.failed.cancel;
    failed_counts.fill += stats.failed.fill;
    failed_counts.fail += stats.failed.fail;
    for (std::size_t i = 0; i < merged_histogram.size(); ++i) {
      merged_histogram[i] += stats.histogram[i];
    }
    latency.samples += stats.latency_samples;
    latency.min_ns = std::min(latency.min_ns, stats.min_latency);
    latency.max_ns = std::max(latency.max_ns, stats.max_latency);
    latency.mean_ns += stats.total_latency;
  }

  if (latency.samples == 0) {
    latency.min_ns = 0;
  } else {
    latency.mean_ns /= static_cast<long double>(latency.samples);
    long double variance_sum = 0.0;
    for (const auto& stats : lane_stats) {
      variance_sum += stats.total_latency_sq;
    }
    const auto mean_sq = latency.mean_ns * latency.mean_ns;
    const auto variance =
        std::max<long double>(0.0, (variance_sum / static_cast<long double>(latency.samples)) - mean_sq);
    latency.stddev_ns = std::sqrt(static_cast<double>(variance));
    latency.coeff_var = latency.mean_ns > 0.0 ? latency.stddev_ns / static_cast<double>(latency.mean_ns) : 0.0;
    latency.p50_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 50.0, latency.samples);
    latency.p75_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 75.0, latency.samples);
    latency.p90_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 90.0, latency.samples);
    latency.p95_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 95.0, latency.samples);
    latency.p99_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 99.0, latency.samples);
    latency.p999_ns = percentile_from_histogram(merged_histogram, config.latency_bucket_ns, 99.9, latency.samples);
  }

  if (config.report_interval_ms > 0) {
    timeline.push_back(TimelineSample{
        .elapsed_ns = elapsed_ns,
        .produced = produced_messages,
        .consumed = total_consumed.load(std::memory_order_relaxed),
        .succeeded = total_succeeded.load(std::memory_order_relaxed),
        .failed = total_failed.load(std::memory_order_relaxed),
        .backlog = produced_messages >= total_consumed.load(std::memory_order_relaxed)
                       ? produced_messages - total_consumed.load(std::memory_order_relaxed)
                       : 0,
        .interval_mps = throughput_mps,
        .moving_avg_mps = timeline.empty() ? throughput_mps : timeline.back().moving_avg_mps,
    });
  }

  std::uint64_t max_backlog = 0;
  double throughput_jitter_mps = 0.0;
  if (!timeline.empty()) {
    for (std::size_t i = 0; i < timeline.size(); ++i) {
      max_backlog = std::max(max_backlog, timeline[i].backlog);
      if (i > 0) {
        throughput_jitter_mps += std::abs(timeline[i].interval_mps - timeline[i - 1].interval_mps);
      }
    }
    throughput_jitter_mps /= static_cast<double>(timeline.size());
  }

  if (!config.replay_dir_path.empty()) {
    ensure_output_directory(config.replay_dir_path, "replay-dir");
    for (const auto& entry : std::filesystem::directory_iterator(config.replay_dir_path)) {
      if (entry.is_regular_file() && entry.path().extension() == ".pr42" &&
          entry.path().filename().string().rfind("failure_", 0) == 0) {
        std::filesystem::remove(entry.path());
      }
    }
    for (const auto& failure : failures) {
      const auto& history = lane_stats[failure.lane].history;
      const auto begin =
          failure.history_index > config.replay_window ? failure.history_index - config.replay_window : 0;
      const auto end_index = std::min(history.size(), failure.history_index + 1);
      std::vector<CommandEvent> window(history.begin() + static_cast<std::ptrdiff_t>(begin),
                                       history.begin() + static_cast<std::ptrdiff_t>(end_index));
      const auto path = config.replay_dir_path + "/failure_" + std::to_string(failure.index) + "_lane_" +
                        std::to_string(failure.lane) + ".pr42";
      smr_machine::write_script_file(path, window);
    }
  }

  if (!config.timeline_csv_path.empty()) {
    write_timeline_csv(config.timeline_csv_path, timeline);
  }
  if (!config.trace_event_json_path.empty()) {
    const auto origin_ns =
        static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(start.time_since_epoch()).count());
    auto normalized_traces = traces;
    for (auto& trace : normalized_traces) {
      trace.producer_start_ns = trace.producer_start_ns >= origin_ns ? trace.producer_start_ns - origin_ns : 0;
      trace.producer_end_ns = trace.producer_end_ns >= origin_ns ? trace.producer_end_ns - origin_ns : 0;
      trace.consumer_start_ns = trace.consumer_start_ns >= origin_ns ? trace.consumer_start_ns - origin_ns : 0;
      trace.consumer_end_ns = trace.consumer_end_ns >= origin_ns ? trace.consumer_end_ns - origin_ns : 0;
    }
    write_trace_event_json(
        config.trace_event_json_path, timeline, normalized_traces, failures, elapsed_ns, config.lanes,
        config.stress_threads);
  }
  if (!config.summary_json_path.empty()) {
    write_summary_json(
        config.summary_json_path, config, produced_counts, succeeded_counts, failed_counts, latency, timeline, failures,
        elapsed_ns, produced_messages, throughput_mps, ns_per_message, max_backlog, throughput_jitter_mps,
        total_dropped.load(std::memory_order_relaxed));
  }

  std::cout << "mode=" << (has_duration ? "duration" : "messages") << "\n";
  if (config.messages.has_value()) {
    std::cout << "target_messages=" << *config.messages << "\n";
  }
  if (has_duration) {
    std::cout << "target_duration_sec=" << config.duration_sec << "\n";
  }
  std::cout << "lanes=" << config.lanes << "\n";
  std::cout << "messages=" << produced_messages << "\n";
  std::cout << "elapsed_ns=" << elapsed_ns << "\n";
  std::cout << std::fixed << std::setprecision(3);
  std::cout << "ns_per_message=" << ns_per_message << "\n";
  std::cout << "throughput_mps=" << throughput_mps << "\n";
  std::cout << "latency_samples=" << latency.samples << "\n";
  std::cout << "latency_min_ns=" << latency.min_ns << "\n";
  std::cout << "latency_mean_ns=" << static_cast<double>(latency.mean_ns) << "\n";
  std::cout << "latency_stddev_ns=" << latency.stddev_ns << "\n";
  std::cout << "latency_p50_ns=" << latency.p50_ns << "\n";
  std::cout << "latency_p75_ns=" << latency.p75_ns << "\n";
  std::cout << "latency_p90_ns=" << latency.p90_ns << "\n";
  std::cout << "latency_p95_ns=" << latency.p95_ns << "\n";
  std::cout << "latency_p99_ns=" << latency.p99_ns << "\n";
  std::cout << "latency_p999_ns=" << latency.p999_ns << "\n";
  std::cout << "latency_max_ns=" << latency.max_ns << "\n";
  std::cout << "throughput_jitter_mps=" << throughput_jitter_mps << "\n";
  std::cout << "max_backlog=" << max_backlog << "\n";
  std::cout << "failures=" << failures.size() << "\n";
  std::cout << "dropped_after_failure_limit=" << total_dropped.load(std::memory_order_relaxed) << "\n";
  std::cout << "produced_submit=" << produced_counts.submit << "\n";
  std::cout << "produced_modify=" << produced_counts.modify << "\n";
  std::cout << "produced_cancel=" << produced_counts.cancel << "\n";
  std::cout << "produced_fill=" << produced_counts.fill << "\n";
  std::cout << "produced_fail=" << produced_counts.fail << "\n";
  if (!config.summary_json_path.empty()) {
    std::cout << "summary_json=" << config.summary_json_path << "\n";
  }
  if (!config.timeline_csv_path.empty()) {
    std::cout << "timeline_csv=" << config.timeline_csv_path << "\n";
  }
  if (!config.trace_event_json_path.empty()) {
    std::cout << "trace_event_json=" << config.trace_event_json_path << "\n";
  }
  if (!config.raw_events_jsonl_path.empty()) {
    std::cout << "raw_events_jsonl=" << config.raw_events_jsonl_path << "\n";
  }
  if (!config.replay_dir_path.empty()) {
    std::cout << "replay_dir=" << config.replay_dir_path << "\n";
  }
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    StressConfig config;
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
      } else if (arg == "--lanes" && i + 1 < argc) {
        config.lanes = static_cast<std::size_t>(parse_u64(argv[++i]));
      } else if (arg == "--stress-threads" && i + 1 < argc) {
        config.stress_threads = static_cast<std::size_t>(parse_u64(argv[++i]));
      } else if (arg == "--stress-bytes" && i + 1 < argc) {
        config.stress_bytes = static_cast<std::size_t>(parse_u64(argv[++i]));
      } else if (arg == "--report-interval-ms" && i + 1 < argc) {
        config.report_interval_ms = parse_u64(argv[++i]);
      } else if (arg == "--latency-bucket-ns" && i + 1 < argc) {
        config.latency_bucket_ns = parse_u64(argv[++i]);
      } else if (arg == "--latency-max-ns" && i + 1 < argc) {
        config.latency_max_ns = parse_u64(argv[++i]);
      } else if (arg == "--submit-weight" && i + 1 < argc) {
        config.submit_weight = parse_u64(argv[++i]);
      } else if (arg == "--modify-weight" && i + 1 < argc) {
        config.modify_weight = parse_u64(argv[++i]);
      } else if (arg == "--cancel-weight" && i + 1 < argc) {
        config.cancel_weight = parse_u64(argv[++i]);
      } else if (arg == "--fill-weight" && i + 1 < argc) {
        config.fill_weight = parse_u64(argv[++i]);
      } else if (arg == "--fail-weight" && i + 1 < argc) {
        config.fail_weight = parse_u64(argv[++i]);
      } else if (arg == "--invalid-bps" && i + 1 < argc) {
        config.invalid_bps = parse_u64(argv[++i]);
      } else if (arg == "--seed" && i + 1 < argc) {
        config.seed = parse_u64(argv[++i]);
      } else if (arg == "--failure-limit" && i + 1 < argc) {
        config.failure_limit = static_cast<std::size_t>(parse_u64(argv[++i]));
      } else if (arg == "--replay-window" && i + 1 < argc) {
        config.replay_window = static_cast<std::size_t>(parse_u64(argv[++i]));
      } else if (arg == "--summary-json" && i + 1 < argc) {
        config.summary_json_path = argv[++i];
      } else if (arg == "--timeline-csv" && i + 1 < argc) {
        config.timeline_csv_path = argv[++i];
      } else if (arg == "--trace-event-json" && i + 1 < argc) {
        config.trace_event_json_path = argv[++i];
      } else if (arg == "--raw-events-jsonl" && i + 1 < argc) {
        config.raw_events_jsonl_path = argv[++i];
      } else if (arg == "--raw-events-stream-fifo" && i + 1 < argc) {
        config.raw_events_stream_fifo_path = argv[++i];
      } else if (arg == "--replay-dir" && i + 1 < argc) {
        config.replay_dir_path = argv[++i];
      } else {
        std::cerr
            << "usage: command_stress [--messages N | --duration-sec SEC] [--capacity power-of-two] [--lanes N] "
               "[--stress-threads N] [--stress-bytes BYTES] [--report-interval-ms MS] "
               "[--latency-bucket-ns NS] [--latency-max-ns NS] [--submit-weight N] [--modify-weight N] "
               "[--cancel-weight N] [--fill-weight N] [--fail-weight N] [--invalid-bps N] [--seed N] "
               "[--failure-limit N] [--replay-window N] [--summary-json PATH] [--timeline-csv PATH] "
               "[--trace-event-json PATH] [--raw-events-jsonl PATH] [--raw-events-stream-fifo PATH] [--replay-dir PATH]\n";
        return 1;
      }
    }

    if (config.lanes == 0 || config.failure_limit == 0) {
      std::cerr << "lanes and failure-limit must be >= 1\n";
      return 1;
    }
    if (config.latency_bucket_ns == 0 || config.latency_max_ns < config.latency_bucket_ns) {
      std::cerr << "invalid latency histogram configuration\n";
      return 1;
    }

    ensure_parent_directory(config.summary_json_path, "summary-json");
    ensure_parent_directory(config.timeline_csv_path, "timeline-csv");
    ensure_parent_directory(config.trace_event_json_path, "trace-event-json");
    ensure_parent_directory(config.raw_events_jsonl_path, "raw-events-jsonl");
    ensure_parent_directory(config.raw_events_stream_fifo_path, "raw-events-stream-fifo");
    if (!config.replay_dir_path.empty()) {
      ensure_output_directory(config.replay_dir_path, "replay-dir");
    }

    switch (capacity) {
      case 256:
        return run_stress<256>(config);
      case 512:
        return run_stress<512>(config);
      case 1024:
        return run_stress<1024>(config);
      case 2048:
        return run_stress<2048>(config);
      case 4096:
        return run_stress<4096>(config);
      default:
        std::cerr << "unsupported capacity: " << capacity << "\n";
        return 1;
    }
  } catch (const std::exception& ex) {
    std::cerr << "command_stress: " << ex.what() << "\n";
    return 1;
  }
}
