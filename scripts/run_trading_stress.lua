#!/usr/bin/env lua

package.path = table.concat({
  "./scripts/?.lua",
  "./scripts/?/init.lua",
  package.path,
}, ";")

local json = require("lua_json")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", [['"'"']]) .. "'"
end

local function now_iso()
  local now = os.date("!*t")
  return string.format(
    "%04d-%02d-%02dT%02d:%02d:%02dZ",
    now.year, now.month, now.day, now.hour, now.min, now.sec
  )
end

local function cwd()
  local handle = assert(io.popen("pwd", "r"))
  local value = handle:read("*l")
  handle:close()
  return value
end

local function is_absolute_path(path)
  return type(path) == "string" and path:sub(1, 1) == "/"
end

local function absolute_path(path)
  if not path or path == "" or is_absolute_path(path) then
    return path
  end
  return cwd() .. "/" .. path
end

local function parse_args(argv)
  local options = {
    duration_sec = 900,
    capacity = 4096,
    lanes = 12,
    stress_threads = 8,
    stress_bytes = 134217728,
    report_interval_ms = 10,
    failure_limit = 100000,
    replay_window = 5000,
    submit_weight = 28,
    modify_weight = 30,
    cancel_weight = 22,
    fill_weight = 18,
    fail_weight = 2,
    invalid_bps = 15,
    seed = 99,
    command_stress_bin = "./build/command_stress",
    extra = {},
  }
  local i = 1
  while i <= #argv do
    local argi = argv[i]
    local function take_number(field)
      i = i + 1
      options[field] = tonumber(argv[i])
    end
    if argi == "--artifact-dir" then
      i = i + 1
      options.artifact_dir = argv[i]
    elseif argi == "--duration-sec" then
      take_number("duration_sec")
    elseif argi == "--capacity" then
      take_number("capacity")
    elseif argi == "--lanes" then
      take_number("lanes")
    elseif argi == "--stress-threads" then
      take_number("stress_threads")
    elseif argi == "--stress-bytes" then
      take_number("stress_bytes")
    elseif argi == "--report-interval-ms" then
      take_number("report_interval_ms")
    elseif argi == "--failure-limit" then
      take_number("failure_limit")
    elseif argi == "--replay-window" then
      take_number("replay_window")
    elseif argi == "--submit-weight" then
      take_number("submit_weight")
    elseif argi == "--modify-weight" then
      take_number("modify_weight")
    elseif argi == "--cancel-weight" then
      take_number("cancel_weight")
    elseif argi == "--fill-weight" then
      take_number("fill_weight")
    elseif argi == "--fail-weight" then
      take_number("fail_weight")
    elseif argi == "--invalid-bps" then
      take_number("invalid_bps")
    elseif argi == "--seed" then
      take_number("seed")
    elseif argi == "--command-stress-bin" then
      i = i + 1
      options.command_stress_bin = argv[i]
    elseif argi == "--help" or argi == "-h" then
      io.write([[
usage: lua scripts/run_trading_stress.lua --artifact-dir PATH [options] [-- extra flags...]
]])
      os.exit(0)
    elseif argi == "--" then
      for j = i + 1, #argv do
        options.extra[#options.extra + 1] = argv[j]
      end
      break
    else
      options.extra[#options.extra + 1] = argi
    end
    i = i + 1
  end
  if not options.artifact_dir then
    error("--artifact-dir is required")
  end
  options.artifact_dir = absolute_path(options.artifact_dir)
  options.command_stress_bin = absolute_path(options.command_stress_bin)
  return options
end

local function read_all(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function write_text(path, content)
  local handle = assert(io.open(path, "w"))
  handle:write(content)
  handle:close()
end

local function append_text(path, content)
  local handle = assert(io.open(path, "a"))
  handle:write(content)
  handle:close()
end

local function ensure_dir(path)
  assert(os.execute("mkdir -p " .. shell_quote(path)))
end

local function mkfifo(path)
  assert(os.execute("mkfifo " .. shell_quote(path)))
end

local function remove_path(path)
  os.execute("rm -rf " .. shell_quote(path))
end

local function write_json(path, payload)
  write_text(path, json.encode(payload) .. "\n")
end

local function touch_file(path)
  local handle = assert(io.open(path, "a"))
  handle:close()
end

local function append_jsonl(path, payload)
  append_text(path, json.encode(payload) .. "\n")
end

local function reset_artifacts(artifact_dir)
  local files = {
    "status.json",
    "run_history.jsonl",
    "summary.json",
    "timeline.csv",
    "trace_event.json",
    "raw_events.jsonl",
    "raw_events.stream.jsonl",
    "raw_events.stream.fifo",
    "stress.stdout.log",
    "stress.stderr.log",
    ".runner.pid",
    ".runner.rc",
    ".stream_relay.pid",
  }
  for _, name in ipairs(files) do
    remove_path(artifact_dir .. "/" .. name)
  end
  remove_path(artifact_dir .. "/replays")
end

local function parse_metrics_line(line, metrics)
  local key, value = line:match("^([^=]+)=(.*)$")
  if key then
    metrics[key] = value
  end
end

local function parse_metrics_file(path)
  local metrics = {}
  local content = read_all(path)
  if not content then
    return metrics
  end
  for line in content:gmatch("([^\n]*)\n?") do
    if line ~= "" then
      parse_metrics_line(line, metrics)
    end
  end
  return metrics
end

local function start_child(command, stdout_log, stderr_log, pid_file, rc_file)
  local full = string.format(
    "bash -lc %s",
    shell_quote(string.format(
      "( %s >> %s 2>> %s; printf '%%s\\n' \"$?\" > %s ) & echo $! > %s",
      command,
      shell_quote(stdout_log),
      shell_quote(stderr_log),
      shell_quote(rc_file),
      shell_quote(pid_file)
    ))
  )
  local ok = os.execute(full)
  if not ok then
    error("failed to start command_stress")
  end
end

local function start_stream_relay(fifo_path, stream_log, relay_pid_file)
  local full = string.format(
    "bash -lc %s",
    shell_quote(string.format(
      "( cat %s >> %s ) & echo $! > %s",
      shell_quote(fifo_path),
      shell_quote(stream_log),
      shell_quote(relay_pid_file)
    ))
  )
  local ok = os.execute(full)
  if not ok then
    error("failed to start raw event stream relay")
  end
end

local function process_alive(pid)
  local command = string.format("kill -0 %s >/dev/null 2>&1", shell_quote(pid))
  local ok = os.execute(command)
  return ok == true or ok == 0
end

local function sleep_seconds(value)
  os.execute(string.format("sleep %.3f", value))
end

local function replayable_metrics(metrics)
  return {
    elapsed_ms = metrics.progress_elapsed_ms,
    produced = metrics.progress_produced,
    consumed = metrics.progress_consumed,
    succeeded = metrics.progress_succeeded,
    failed = metrics.progress_failed,
    backlog = metrics.progress_backlog,
    interval_mps = metrics.progress_interval_mps,
    moving_avg_mps = metrics.progress_moving_avg_mps,
  }
end

local function status_run_config(options)
  return {
    duration_sec = options.duration_sec,
    capacity = options.capacity,
    lanes = options.lanes,
    stress_threads = options.stress_threads,
    stress_bytes = options.stress_bytes,
    report_interval_ms = options.report_interval_ms,
    failure_limit = options.failure_limit,
    replay_window = options.replay_window,
    submit_weight = options.submit_weight,
    modify_weight = options.modify_weight,
    cancel_weight = options.cancel_weight,
    fill_weight = options.fill_weight,
    fail_weight = options.fail_weight,
    invalid_bps = options.invalid_bps,
    seed = options.seed,
    command_stress_bin = options.command_stress_bin,
    extra = options.extra,
  }
end

local function main()
  local options = parse_args(arg)
  ensure_dir(options.artifact_dir)

  local artifact_dir = options.artifact_dir
  local status_json = artifact_dir .. "/status.json"
  local history_jsonl = artifact_dir .. "/run_history.jsonl"
  local summary_json = artifact_dir .. "/summary.json"
  local timeline_csv = artifact_dir .. "/timeline.csv"
  local trace_json = artifact_dir .. "/trace_event.json"
  local raw_events_jsonl = artifact_dir .. "/raw_events.jsonl"
  local replay_dir = artifact_dir .. "/replays"
  local stdout_log = artifact_dir .. "/stress.stdout.log"
  local stderr_log = artifact_dir .. "/stress.stderr.log"
  local raw_events_stream_fifo = artifact_dir .. "/raw_events.stream.fifo"
  local raw_events_stream_log = artifact_dir .. "/raw_events.stream.jsonl"
  local pid_file = artifact_dir .. "/.runner.pid"
  local rc_file = artifact_dir .. "/.runner.rc"
  local relay_pid_file = artifact_dir .. "/.stream_relay.pid"

  reset_artifacts(artifact_dir)
  mkfifo(raw_events_stream_fifo)
  touch_file(raw_events_jsonl)
  touch_file(raw_events_stream_log)
  touch_file(stdout_log)
  touch_file(stderr_log)
  start_stream_relay(raw_events_stream_fifo, raw_events_stream_log, relay_pid_file)

  local started_at = now_iso()
  write_json(status_json, {
    state = "active",
    label = "ACTIVE",
    started_at = started_at,
    artifact_dir = artifact_dir,
    run_config = status_run_config(options),
    raw_events_jsonl = raw_events_jsonl,
    raw_events_stream_fifo = raw_events_stream_fifo,
    raw_events_stream_log = raw_events_stream_log,
  })

  local command_parts = {
    shell_quote(options.command_stress_bin),
    "--duration-sec", tostring(options.duration_sec),
    "--capacity", tostring(options.capacity),
    "--lanes", tostring(options.lanes),
    "--stress-threads", tostring(options.stress_threads),
    "--stress-bytes", tostring(options.stress_bytes),
    "--report-interval-ms", tostring(options.report_interval_ms),
    "--failure-limit", tostring(options.failure_limit),
    "--replay-window", tostring(options.replay_window),
    "--submit-weight", tostring(options.submit_weight),
    "--modify-weight", tostring(options.modify_weight),
    "--cancel-weight", tostring(options.cancel_weight),
    "--fill-weight", tostring(options.fill_weight),
    "--fail-weight", tostring(options.fail_weight),
    "--invalid-bps", tostring(options.invalid_bps),
    "--seed", tostring(options.seed),
    "--summary-json", shell_quote(summary_json),
    "--timeline-csv", shell_quote(timeline_csv),
    "--trace-event-json", shell_quote(trace_json),
    "--raw-events-jsonl", shell_quote(raw_events_jsonl),
    "--raw-events-stream-fifo", shell_quote(raw_events_stream_fifo),
    "--replay-dir", shell_quote(replay_dir),
  }
  for _, extra in ipairs(options.extra) do
    command_parts[#command_parts + 1] = shell_quote(extra)
  end
  local command = table.concat(command_parts, " ")

  start_child(command, stdout_log, stderr_log, pid_file, rc_file)

  local pid = (read_all(pid_file) or ""):gsub("%s+$", "")
  if pid == "" then
    error("managed runner failed to capture child pid")
  end

  local stdout_offset = 0
  local stderr_offset = 0
  local function mirror_log(path, offset, target)
    local handle = io.open(path, "r")
    if not handle then
      return offset
    end
    local size = handle:seek("end")
    if size < offset then
      offset = 0
    end
    handle:seek("set", offset)
    local chunk = handle:read("*a")
    local new_offset = handle:seek()
    handle:close()
    if chunk and chunk ~= "" then
      target:write(chunk)
      target:flush()
    end
    return new_offset
  end

  while true do
    stdout_offset = mirror_log(stdout_log, stdout_offset, io.stdout)
    stderr_offset = mirror_log(stderr_log, stderr_offset, io.stderr)
    local metrics = parse_metrics_file(stdout_log)
    if next(metrics) ~= nil then
      write_json(status_json, {
        state = "active",
        label = "ACTIVE",
        started_at = started_at,
        artifact_dir = artifact_dir,
        run_config = status_run_config(options),
        raw_events_jsonl = raw_events_jsonl,
        raw_events_stream_fifo = raw_events_stream_fifo,
        raw_events_stream_log = raw_events_stream_log,
        progress = replayable_metrics(metrics),
      })
    end
    if read_all(rc_file) then
      break
    end
    if not process_alive(pid) then
      break
    end
    sleep_seconds(0.05)
  end

  stdout_offset = mirror_log(stdout_log, stdout_offset, io.stdout)
  stderr_offset = mirror_log(stderr_log, stderr_offset, io.stderr)

  local returncode = tonumber((read_all(rc_file) or "1"):match("%-?%d+")) or 1
  local metrics = parse_metrics_file(stdout_log)
  local state = returncode == 0 and "idle" or "error"
  local ended_at = now_iso()

  write_json(status_json, {
    state = state,
    label = state == "idle" and "IDLE" or "ERROR",
    started_at = started_at,
    ended_at = ended_at,
    returncode = returncode,
    artifact_dir = artifact_dir,
    run_config = status_run_config(options),
    messages = metrics.messages,
    failures = metrics.failures,
    throughput_mps = metrics.throughput_mps,
    interrupted = false,
    summary_json = summary_json,
    raw_events_jsonl = raw_events_jsonl,
    raw_events_stream_fifo = raw_events_stream_fifo,
    raw_events_stream_log = raw_events_stream_log,
    stderr_log = stderr_log,
  })

  append_jsonl(history_jsonl, {
    started_at = started_at,
    ended_at = ended_at,
    state = state,
    returncode = returncode,
    messages = metrics.messages,
    failures = metrics.failures,
    throughput_mps = metrics.throughput_mps,
    artifact_dir = artifact_dir,
    interrupted = false,
  })

  remove_path(pid_file)
  remove_path(rc_file)
  local relay_pid = (read_all(relay_pid_file) or ""):gsub("%s+$", "")
  if relay_pid ~= "" then
    os.execute(string.format("kill %s >/dev/null 2>&1", shell_quote(relay_pid)))
  end
  remove_path(relay_pid_file)
  remove_path(raw_events_stream_fifo)

  return returncode
end

local ok, result = xpcall(main, debug.traceback)
if not ok then
  io.stderr:write(result .. "\n")
  os.exit(1)
end
os.exit(result or 0)
