package.path = table.concat({
  "./scripts/?.lua",
  "./scripts/?/init.lua",
  package.path,
}, ";")

local json = require("lua_json")

local function shell_quote(v)
  return "'" .. tostring(v):gsub("'", [['\"'\"']]) .. "'"
end

local function parse_args(argv)
  local opts = {
    refresh_ms          = 100,
    recent_limit        = 64,
    scan_lines_per_tick = 100000,
    tail_snapshot_lines = 4000,
    latency_window      = 10000,
    catchup_render_every = 5,
  }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local function next_val()
      i = i + 1
      if not argv[i] then error("missing value for " .. a) end
      return argv[i]
    end
    if     a == "--event-log"            then opts.event_log            = next_val()
    elseif a == "--status-json"          then opts.status_json          = next_val()
    elseif a == "--event-stream-log"     then opts.event_stream_log     = next_val()
    elseif a == "--run-history-jsonl"    then opts.run_history_jsonl    = next_val()
    elseif a == "--refresh-ms"           then opts.refresh_ms           = tonumber(next_val())
    elseif a == "--recent-limit"         then opts.recent_limit         = tonumber(next_val())
    elseif a == "--scan-lines-per-tick"  then opts.scan_lines_per_tick  = tonumber(next_val())
    elseif a == "--tail-snapshot-lines"  then opts.tail_snapshot_lines  = tonumber(next_val())
    elseif a == "--latency-window"       then opts.latency_window       = tonumber(next_val())
    elseif a == "--catchup-render-every" then opts.catchup_render_every = tonumber(next_val())
    elseif a == "--help" or a == "-h" then
      io.write("usage: lua scripts/order_terminal.lua --event-log PATH [options]\n")
      os.exit(0)
    else
      error("unknown arg: " .. tostring(a))
    end
    i = i + 1
  end
  if not opts.event_log then error("--event-log is required") end
  return opts
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function file_size(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:seek("end"); f:close(); return s
end

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close(); return c
end

local function mtime_sec(path)
  local cmds = {
    "stat -c %Y " .. shell_quote(path) .. " 2>/dev/null",
    "stat -f %m " .. shell_quote(path) .. " 2>/dev/null",
  }
  for _, cmd in ipairs(cmds) do
    local h = io.popen(cmd, "r")
    if h then
      local v = h:read("*l"); h:close()
      local n = tonumber(v)
      if n then return n end
    end
  end
  return nil
end

local function terminal_size()
  local h = io.popen("stty size 2>/dev/null", "r")
  if not h then return 40, 160 end
  local l = h:read("*l"); h:close()
  if not l then return 40, 160 end
  local r, c = l:match("^(%d+)%s+(%d+)$")
  return tonumber(r) or 40, tonumber(c) or 160
end

local function safe_int(v, default)
  local n = tonumber(v)
  if not n then return default or 0 end
  return math.tointeger(n) or math.floor(n)
end

local function push_front(list, v, limit)
  table.insert(list, 1, v)
  if #list > limit then table.remove(list) end
end

local function sorted_pairs(map, sorter)
  local keys = {}
  for k in pairs(map) do keys[#keys+1] = k end
  table.sort(keys, sorter)
  local i = 0
  return function()
    i = i + 1; local k = keys[i]
    if k == nil then return nil end
    return k, map[k]
  end
end

local function count_table(map)
  local n = 0; for _ in pairs(map) do n = n + 1 end; return n
end

local function top_keys(map, limit, cmp)
  local keys = {}
  for k in pairs(map) do keys[#keys+1] = k end
  table.sort(keys, cmp)
  local out = {}
  for i = 1, math.min(limit, #keys) do out[i] = keys[i] end
  return out
end

local function format_ns(ns)
  if ns < 1000 then return string.format("%dns", ns)
  elseif ns < 1000000 then return string.format("%.1fμs", ns / 1000)
  else return string.format("%.2fms", ns / 1e6) end
end

local function format_big(n)
  if math.abs(n) >= 1e9 then return string.format("%.2fB", n/1e9)
  elseif math.abs(n) >= 1e6 then return string.format("%.2fM", n/1e6)
  elseif math.abs(n) >= 1e3 then return string.format("%.1fK", n/1e3)
  else return string.format("%.0f", n) end
end

local function rel_time_ms(ns, origin)
  if not ns or not origin or ns < origin then return "-" end
  return string.format("%.3fms", (ns - origin) / 1e6)
end

local function bar_chart(val, max_val, width)
  if max_val <= 0 then return string.rep("░", width) end
  local filled = math.min(width, math.floor(val / max_val * width + 0.5))
  return string.rep("█", filled) .. string.rep("░", width - filled)
end


local tty_fd = nil

local function setup_raw_tty()
  io.write("\27[?1049h\27[?25l")
  io.flush()
  os.execute("stty -echo -icanon min 0 time 0 < /dev/tty 2>/dev/null")
  tty_fd = io.open("/dev/tty", "r")
end

local function restore_tty()
  if tty_fd then tty_fd:close(); tty_fd = nil end
  os.execute("stty sane < /dev/tty 2>/dev/null")
  io.write("\27[?25h\27[?1049l")
  io.flush()
end

local function read_key_nonblocking()
  if not tty_fd then return nil end
  local ch = tty_fd:read(1)
  if not ch or ch == "" then return nil end
  return ch
end


local function new_latency_tracker(window_size)
  return {
    window_size = window_size or 10000,
    samples     = {},
    write_pos   = 0,
    count       = 0,
    sorted_dirty = true,
    sorted_cache = nil,
    sum         = 0,
    sum_sq      = 0,
    min_val     = math.huge,
    max_val     = 0,
    last_latency = nil,
    jitter_sum   = 0,
    jitter_count = 0,
  }
end

local function tracker_add(t, latency_ns)
  local ws = t.window_size
  if t.count >= ws then
    local old = t.samples[t.write_pos + 1]
    if old then t.sum = t.sum - old; t.sum_sq = t.sum_sq - (old * old) end
  end
  t.write_pos = (t.write_pos) % ws
  t.samples[t.write_pos + 1] = latency_ns
  t.write_pos = t.write_pos + 1
  if t.write_pos >= ws then t.write_pos = 0 end
  t.count = t.count + 1
  t.sum = t.sum + latency_ns
  t.sum_sq = t.sum_sq + (latency_ns * latency_ns)
  if latency_ns < t.min_val then t.min_val = latency_ns end
  if latency_ns > t.max_val then t.max_val = latency_ns end
  t.sorted_dirty = true
  if t.last_latency then
    t.jitter_sum = t.jitter_sum + math.abs(latency_ns - t.last_latency)
    t.jitter_count = t.jitter_count + 1
  end
  t.last_latency = latency_ns
end

local function tracker_n(t) return math.min(t.count, t.window_size) end

local function tracker_ensure_sorted(t)
  if not t.sorted_dirty and t.sorted_cache then return end
  local n = tracker_n(t)
  local copy = {}
  for i = 1, n do copy[i] = t.samples[i] end
  table.sort(copy)
  t.sorted_cache = copy; t.sorted_dirty = false
end

local function tracker_percentile(t, pct)
  local n = tracker_n(t)
  if n == 0 then return 0 end
  tracker_ensure_sorted(t)
  local idx = math.max(1, math.min(n, math.ceil(pct / 100.0 * n)))
  return t.sorted_cache[idx]
end

local function tracker_mean(t)
  local n = tracker_n(t); if n == 0 then return 0 end; return t.sum / n
end

local function tracker_stddev(t)
  local n = tracker_n(t); if n < 2 then return 0 end
  local mean = t.sum / n
  local variance = (t.sum_sq / n) - (mean * mean)
  return math.sqrt(math.max(0, variance))
end

local function tracker_jitter(t)
  if t.jitter_count == 0 then return 0 end; return t.jitter_sum / t.jitter_count
end

local function tracker_cv(t)
  local mean = tracker_mean(t); if mean == 0 then return 0 end
  return tracker_stddev(t) / mean
end


local function new_state(recent_limit, latency_window)
  return {
    recent_limit        = recent_limit,
    total               = 0,
    failed              = 0,
    dropped             = 0,
    ok_count            = 0,
    by_type             = {},
    by_asset            = {},
    by_lane             = {},
    by_trader           = {},
    open_orders         = {},
    failures            = {},
    recent              = {},
    positions           = {},
    last_px_by_asset    = {},
    total_open_notional = 0,
    total_open_qty      = 0,
    start_observed_ns   = nil,
    last_observed_ns    = nil,
    max_seq             = -1,
    latency             = new_latency_tracker(latency_window),
    -- volume tracking
    total_buy_qty       = 0,
    total_sell_qty      = 0,
    total_buy_notional  = 0,
    total_sell_notional = 0,
    total_fills         = 0,
    total_submits       = 0,
    total_cancels       = 0,
    total_modifies      = 0,
    -- PnL tracking
    peak_pnl            = 0,
    trough_pnl          = 0,
    max_drawdown        = 0,
    pnl_snapshots       = {},
    -- stress region tracking
    stress_regions      = {},
    current_stress      = nil,
    stress_region_count = 0,
  }
end

local function reset_state(state)
  local fresh = new_state(state.recent_limit, state.latency.window_size)
  for k, v in pairs(fresh) do state[k] = v end
end

local function incr(map, key, delta) map[key] = (map[key] or 0) + (delta or 1) end

local function asset_row(state, asset)
  local row = state.by_asset[asset]
  if not row then
    row = { events=0, fills=0, buy_qty=0, sell_qty=0, open_orders=0,
            buy_notional=0, sell_notional=0, latency_sum=0, latency_count=0,
            submits=0, cancels=0, modifies=0 }
    state.by_asset[asset] = row
  end
  return row
end

local function position_row(state, asset)
  local row = state.positions[asset]
  if not row then
    row = { qty=0, cash=0, last_px=0, fills=0 }
    state.positions[asset] = row
  end
  return row
end

local function clone_event(event)
  local out = {}
  for k, v in pairs(event) do out[k] = v end
  return out
end

local function remove_open_order(state, order_id)
  local existing = state.open_orders[order_id]
  if not existing then return end
  local asset = existing.asset or "UNKNOWN"
  local rem = safe_int(existing.remaining_qty, 0)
  local px = safe_int(existing.px, 0)
  local row = asset_row(state, asset)
  row.open_orders = math.max(0, (row.open_orders or 0) - 1)
  state.total_open_qty = math.max(0, state.total_open_qty - rem)
  state.total_open_notional = math.max(0, state.total_open_notional - (rem * px))
  state.open_orders[order_id] = nil
end

local function store_open_order(state, order_id, order)
  remove_open_order(state, order_id)
  state.open_orders[order_id] = order
  local asset = order.asset or "UNKNOWN"
  local rem = safe_int(order.remaining_qty, 0)
  local px = safe_int(order.px, 0)
  local row = asset_row(state, asset)
  row.open_orders = (row.open_orders or 0) + 1
  state.total_open_qty = state.total_open_qty + rem
  state.total_open_notional = state.total_open_notional + (rem * px)
end

local function detect_stress_region(state, latency_ns)
  local n = tracker_n(state.latency)
  if n < 100 then return end
  local mean = tracker_mean(state.latency)
  local threshold = mean * 2.0
  if latency_ns > threshold then
    if not state.current_stress then
      state.stress_region_count = state.stress_region_count + 1
      state.current_stress = {
        id = state.stress_region_count, start_ns = state.last_observed_ns,
        peak_ns = latency_ns, events = 1, sum_lat = latency_ns,
      }
    else
      state.current_stress.events = state.current_stress.events + 1
      state.current_stress.sum_lat = state.current_stress.sum_lat + latency_ns
      if latency_ns > state.current_stress.peak_ns then state.current_stress.peak_ns = latency_ns end
    end
  else
    if state.current_stress and state.current_stress.events >= 5 then
      state.current_stress.end_ns = state.last_observed_ns
      state.current_stress.avg_lat = state.current_stress.sum_lat / state.current_stress.events
      push_front(state.stress_regions, state.current_stress, 8)
    end
    state.current_stress = nil
  end
end

local function mark_to_market(state)
  local profit, loss, net, gross = 0, 0, 0, 0
  for asset, pos in pairs(state.positions) do
    local lpx = state.last_px_by_asset[asset] or pos.last_px or 0
    local mtm = pos.cash + pos.qty * lpx
    net = net + mtm
    gross = gross + math.abs(pos.qty)
    if mtm >= 0 then profit = profit + mtm else loss = loss - mtm end
  end
  -- Track drawdown
  if net > state.peak_pnl then state.peak_pnl = net end
  if net < state.trough_pnl then state.trough_pnl = net end
  local dd = state.peak_pnl - net
  if dd > state.max_drawdown then state.max_drawdown = dd end
  return profit, loss, net, gross
end

local function apply_event(state, event)
  local seq = safe_int(event.seq, nil)
  if seq and seq <= state.max_seq then return false end
  if seq and seq > state.max_seq then state.max_seq = seq end

  state.total = state.total + 1
  local status     = event.status or ""
  local etype      = event.type or ""
  local asset      = event.asset or "UNKNOWN"
  local trader     = event.trader or "unknown"
  local lane       = tostring(event.lane or -1)
  local order_id   = event.id or ""
  local qty        = safe_int(event.qty, 0)
  local px         = safe_int(event.px, 0)
  local remaining  = safe_int(event.remaining_qty, 0)
  local side       = event.side or "BUY"
  local observed   = safe_int(event.observed_ns, nil)
  local latency_ns = safe_int(event.latency_ns, nil)

  if observed then
    state.last_observed_ns = observed
    if not state.start_observed_ns then state.start_observed_ns = observed end
  end

  if latency_ns and latency_ns > 0 then
    tracker_add(state.latency, latency_ns)
    detect_stress_region(state, latency_ns)
    local astats = asset_row(state, asset)
    astats.latency_sum = astats.latency_sum + latency_ns
    astats.latency_count = astats.latency_count + 1
  end

  incr(state.by_type, etype)
  incr(state.by_lane, lane)
  incr(state.by_trader, trader)
  local astats = asset_row(state, asset)
  astats.events = astats.events + 1

  if status == "failed" then
    state.failed = state.failed + 1
    push_front(state.failures, event, 12)
  elseif status == "dropped" then
    state.dropped = state.dropped + 1
  elseif status == "ok" then
    state.ok_count = state.ok_count + 1
  end

  if status == "ok" then
    if etype == "SUBMIT" then
      state.total_submits = state.total_submits + 1
      astats.submits = astats.submits + 1
      local stored = clone_event(event)
      stored.submitted_ns = safe_int(event.ts_ns, nil)
      stored.remaining_qty = remaining ~= 0 and remaining or qty
      store_open_order(state, order_id, stored)
    elseif etype == "MODIFY" then
      state.total_modifies = state.total_modifies + 1
      astats.modifies = astats.modifies + 1
      if state.open_orders[order_id] then
        local stored = clone_event(state.open_orders[order_id])
        for k,v in pairs(event) do stored[k] = v end
        stored.remaining_qty = remaining
        store_open_order(state, order_id, stored)
      end
    elseif etype == "FILL" then
      state.total_fills = state.total_fills + 1
      astats.fills = astats.fills + 1
      state.last_px_by_asset[asset] = px
      local pos = position_row(state, asset)
      if side == "BUY" then
        astats.buy_qty = astats.buy_qty + qty
        astats.buy_notional = astats.buy_notional + qty * px
        state.total_buy_qty = state.total_buy_qty + qty
        state.total_buy_notional = state.total_buy_notional + qty * px
        pos.qty  = pos.qty + qty
        pos.cash = pos.cash - qty * px
      else
        astats.sell_qty = astats.sell_qty + qty
        astats.sell_notional = astats.sell_notional + qty * px
        state.total_sell_qty = state.total_sell_qty + qty
        state.total_sell_notional = state.total_sell_notional + qty * px
        pos.qty  = pos.qty - qty
        pos.cash = pos.cash + qty * px
      end
      pos.last_px = px
      pos.fills   = pos.fills + 1
      if remaining > 0 then
        if state.open_orders[order_id] then
          local stored = clone_event(state.open_orders[order_id])
          for k,v in pairs(event) do stored[k] = v end
          stored.remaining_qty = remaining
          store_open_order(state, order_id, stored)
        else
          local stored = clone_event(event)
          stored.submitted_ns = safe_int(event.ts_ns, nil)
          store_open_order(state, order_id, stored)
        end
      else
        remove_open_order(state, order_id)
      end
    elseif etype == "CANCEL" then
      state.total_cancels = state.total_cancels + 1
      astats.cancels = astats.cancels + 1
      remove_open_order(state, order_id)
    end
  end

  push_front(state.recent, event, state.recent_limit)
  return true
end

local function throughput_eps(state)
  if not state.start_observed_ns or not state.last_observed_ns
     or state.last_observed_ns <= state.start_observed_ns then return 0 end
  local sec = (state.last_observed_ns - state.start_observed_ns) / 1e9
  if sec <= 0 then return 0 end
  return state.total / sec
end

local function elapsed_sec(state)
  if not state.start_observed_ns or not state.last_observed_ns then return 0 end
  return (state.last_observed_ns - state.start_observed_ns) / 1e9
end


local function tail_events(path, state, offset, max_lines)
  if not file_exists(path) then return offset, false, true end
  local sz = file_size(path)
  if not sz then return offset, false, true end
  if sz < offset then reset_state(state); offset = 0 end
  local f = io.open(path, "r")
  if not f then return offset, false, true end
  f:seek("set", offset)
  local changed = false
  local n = 0
  while true do
    if max_lines and n >= max_lines then break end
    local line = f:read("*l")
    if not line then break end
    n = n + 1
    if line ~= "" then
      local ok, ev = pcall(json.decode, line)
      if ok and type(ev) == "table" then
        if apply_event(state, ev) then changed = true end
      end
    end
  end
  local new_off = f:seek()
  f:close()
  return new_off, changed, new_off >= sz
end

local function load_tail_snapshot(path, state, lines)
  if not path or not file_exists(path) or not lines or lines <= 0 then return end
  local h = io.popen(string.format("tail -n %d %s 2>/dev/null", lines, shell_quote(path)), "r")
  if not h then return end
  while true do
    local line = h:read("*l")
    if not line then break end
    if line ~= "" then
      local ok, ev = pcall(json.decode, line)
      if ok and type(ev) == "table" then apply_event(state, ev) end
    end
  end
  h:close()
end

local function load_status(path)
  if not path or not file_exists(path) then return { label="OFF", state="off" } end
  local c = read_all(path)
  if not c then return { label="ERR", state="error" } end
  local ok, payload = pcall(json.decode, c)
  if not ok or type(payload) ~= "table" then return { label="ERR", state="error" } end
  local s = payload.state or "idle"
  payload.label = s == "active" and "LIVE" or (s == "error" and "ERR" or "IDLE")
  return payload
end

local function sync_stream_from_status(opts, status)
  if opts.event_stream_log then return end
  if type(status) == "table" and status.raw_events_stream_log and status.raw_events_stream_log ~= "" then
    opts.event_stream_log = status.raw_events_stream_log
  end
end

local function status_progress_num(status, key)
  if type(status) ~= "table" or type(status.progress) ~= "table" then return nil end
  return tonumber(status.progress[key])
end

local function status_run_config(status)
  if type(status) ~= "table" or type(status.run_config) ~= "table" then return nil end
  return status.run_config
end

local function load_last_runs(path, limit)
  if not path or not file_exists(path) then return {} end
  local f = io.open(path, "r")
  if not f then return {} end
  local rows = {}
  while true do
    local line = f:read("*l")
    if not line then break end
    if line ~= "" then
      local ok, row = pcall(json.decode, line)
      if ok and type(row) == "table" then
        rows[#rows+1] = row
        if #rows > limit then table.remove(rows, 1) end
      end
    end
  end
  f:close()
  local out = {}
  for i = #rows, 1, -1 do out[#out+1] = rows[i] end
  return out
end


-- GUI STUFF
-- ═══════════════════════════════════════════════════════════════════════════
-- ANSI
-- ═══════════════════════════════════════════════════════════════════════════

local C = {
  R="\27[0m", B="\27[1m", D="\27[2m",
  r="\27[31m", g="\27[32m", y="\27[33m", b="\27[34m",
  m="\27[35m", c="\27[36m", w="\27[37m",
  Br="\27[1;31m", Bg="\27[1;32m", By="\27[1;33m",
  Bb="\27[1;34m", Bm="\27[1;35m", Bc="\27[1;36m", Bw="\27[1;37m",
  Dr="\27[2;31m", Dg="\27[2;32m", Dy="\27[2;33m", Dc="\27[2;36m",
  inv="\27[7m",
}

-- ═══════════════════════════════════════════════════════════════════════════
-- rendering — dense full-screen trading terminal
-- ═══════════════════════════════════════════════════════════════════════════

local function render(state, opts, status, last_runs, catchup_info, term_rows, term_cols)
  local lt = state.latency
  local n_lat = tracker_n(lt)
  local profit, loss, net, gross = mark_to_market(state)
  local eps = throughput_eps(state)
  local el = elapsed_sec(state)
  local total_volume = state.total_buy_notional + state.total_sell_notional
  local fill_rate = state.total_submits > 0 and (state.total_fills / state.total_submits * 100) or 0
  local fail_rate = state.total > 0 and (state.failed / state.total * 100) or 0
  local open_count = count_table(state.open_orders)

  local buf = {}
  local function w(s) buf[#buf+1] = s end
  local function pad(s, width)
    local plain = s:gsub("\27%[[%d;]*m", "")
    local needed = width - #plain
    if needed > 0 then return s .. string.rep(" ", needed) end
    return s
  end
  local function rpad(s, width)
    local plain = s:gsub("\27%[[%d;]*m", "")
    local needed = width - #plain
    if needed > 0 then return string.rep(" ", needed) .. s end
    return s
  end

  -- ── ROW 1: title bar ──
  local status_c = status.label == "LIVE" and C.Bg or (status.label == "ERR" and C.Br or C.By)
  local title = string.format("%s%s STATE MACHINE REPLICATION TRADING TERMINAL %s", C.inv, C.Bc, C.R)
  local status_str = string.format(" %s[%s]%s", status_c, status.label, C.R)
  local time_str = el > 0 and string.format(" %s%.1fs%s", C.Dc, el, C.R) or ""
  local src = file_exists(opts.event_log) and (C.Dg .. "LOG✓" .. C.R) or (C.Br .. "LOG✗" .. C.R)
  local strm = opts.event_stream_log and (file_exists(opts.event_stream_log) and (C.Dg .. "STR✓" .. C.R) or (C.Dy .. "STR…" .. C.R)) or (C.D .. "STR-" .. C.R)
  local catch = catchup_info and (C.By .. string.format("CATCH %s", format_big(catchup_info.offset)) .. C.R) or (C.Dg .. "LIVE" .. C.R)
  w(string.format("%s%s %s %s %s%s %sq/x%s=quit", title, status_str, src, strm, catch, time_str, C.D, C.R))

  -- ── ROW 2-3: key metrics ──
  local eps_c = eps > 100000 and C.Bg or (eps > 10000 and C.By or C.Bw)
  local net_c = net >= 0 and C.Bg or C.Br
  w(string.format(" %sEVENTS%s %-9s %sOK%s %-9s %sFAIL%s %s%-6d%s(%s%.1f%%%s) %sDROP%s %-6d %sOPEN%s %-5d %sEPS%s %s%s%s %sSEQ%s %s",
    C.Bw, C.R, format_big(state.total),
    C.Dg, C.R, format_big(state.ok_count),
    C.r, C.R, C.Br, state.failed, C.R, C.Dr, fail_rate, C.R,
    C.Dy, C.R, state.dropped,
    C.Bc, C.R, open_count,
    C.Bw, C.R, eps_c, format_big(eps), C.R,
    C.D, C.R, format_big(state.max_seq)))
  w(string.format(" %sPnL%s %s%s%s  %s↑%s%s %s↓%s%s %sDRAWDOWN%s %s%s%s │ %sVOLUME%s %s  %sBUY%s %s  %sSELL%s %s │ %sFILLS%s %s %sSUBMIT%s %s %sMOD%s %s %sCXL%s %s %sFILL%%%s %.1f%%",
    C.Bw, C.R, net_c, format_big(net), C.R,
    C.g, C.R, format_big(profit),
    C.r, C.R, format_big(loss),
    C.Bw, C.R, C.Br, format_big(state.max_drawdown), C.R,
    C.Bw, C.R, format_big(total_volume),
    C.g, C.R, format_big(state.total_buy_notional),
    C.r, C.R, format_big(state.total_sell_notional),
    C.Bw, C.R, format_big(state.total_fills),
    C.Dc, C.R, format_big(state.total_submits),
    C.Dc, C.R, format_big(state.total_modifies),
    C.Dc, C.R, format_big(state.total_cancels),
    C.By, C.R, fill_rate))
  w(string.format(" %sINVENTORY%s %-8s │ %sOPEN QTY%s %-9s │ %sOPEN NOTIONAL%s %-12s │ %sGROSS%s %s %sBUY QTY%s %s %sSELL QTY%s %s",
    C.Bw, C.R, format_big(gross),
    C.Bw, C.R, format_big(state.total_open_qty),
    C.Bw, C.R, format_big(state.total_open_notional),
    C.Bw, C.R, format_big(gross),
    C.g, C.R, format_big(state.total_buy_qty),
    C.r, C.R, format_big(state.total_sell_qty)))

  local run_cfg = status_run_config(status)
  local progress_elapsed_ms = status_progress_num(status, "elapsed_ms")
  local progress_produced = status_progress_num(status, "produced")
  local progress_consumed = status_progress_num(status, "consumed")
  local progress_succeeded = status_progress_num(status, "succeeded")
  local progress_failed = status_progress_num(status, "failed")
  local progress_backlog = status_progress_num(status, "backlog")
  local progress_interval_mps = status_progress_num(status, "interval_mps")
  local progress_moving_avg_mps = status_progress_num(status, "moving_avg_mps")
  if run_cfg or progress_elapsed_ms or progress_produced then
    w(C.Bc .. "─── RUN STATE " .. string.rep("─", math.max(0, term_cols - 16)) .. C.R)
    local cfg_line = string.format(
      " %sRUN%s lanes=%s stress=%s cap=%s dur=%ss fail=%s seed=%s interval=%sms",
      C.Bw, C.R,
      tostring(run_cfg and run_cfg.lanes or "?"),
      tostring(run_cfg and run_cfg.stress_threads or "?"),
      tostring(run_cfg and run_cfg.capacity or "?"),
      tostring(run_cfg and run_cfg.duration_sec or "?"),
      tostring(run_cfg and run_cfg.failure_limit or "?"),
      tostring(run_cfg and run_cfg.seed or "?"),
      tostring(run_cfg and run_cfg.report_interval_ms or "?"))
    local weight_line = string.format(
      " %sWGTS%s sub=%s mod=%s cxl=%s fill=%s fail=%s invalid=%sbps bytes=%s replay=%s",
      C.Bw, C.R,
      tostring(run_cfg and run_cfg.submit_weight or "?"),
      tostring(run_cfg and run_cfg.modify_weight or "?"),
      tostring(run_cfg and run_cfg.cancel_weight or "?"),
      tostring(run_cfg and run_cfg.fill_weight or "?"),
      tostring(run_cfg and run_cfg.fail_weight or "?"),
      tostring(run_cfg and run_cfg.invalid_bps or "?"),
      tostring(run_cfg and format_big(run_cfg.stress_bytes or 0) or "?"),
      tostring(run_cfg and run_cfg.replay_window or "?"))
    local progress_line = string.format(
      " %sPROGRESS%s elapsed=%ss prod=%s cons=%s ok=%s fail=%s backlog=%s inst=%sM avg=%sM",
      C.Bw, C.R,
      progress_elapsed_ms and string.format("%.1f", progress_elapsed_ms / 1000.0) or "?",
      progress_produced and format_big(progress_produced) or "?",
      progress_consumed and format_big(progress_consumed) or "?",
      progress_succeeded and format_big(progress_succeeded) or "?",
      progress_failed and format_big(progress_failed) or "?",
      progress_backlog and format_big(progress_backlog) or "?",
      progress_interval_mps and string.format("%.3f", progress_interval_mps) or "?",
      progress_moving_avg_mps and string.format("%.3f", progress_moving_avg_mps) or "?")
    w(cfg_line)
    w(weight_line)
    w(progress_line)
  end

  -- ── ROW 4-5: latency band ──
  w(C.Bc .. "─── LATENCY " .. string.rep("─", math.max(0, term_cols - 14)) .. C.R)
  if n_lat > 0 then
    local p50  = tracker_percentile(lt, 50)
    local p75  = tracker_percentile(lt, 75)
    local p90  = tracker_percentile(lt, 90)
    local p95  = tracker_percentile(lt, 95)
    local p99  = tracker_percentile(lt, 99)
    local p999 = tracker_percentile(lt, 99.9)
    local mean = tracker_mean(lt)
    local sd   = tracker_stddev(lt)
    local jit  = tracker_jitter(lt)
    local cv   = tracker_cv(lt)
    local min_l = lt.min_val == math.huge and 0 or lt.min_val
    local cv_c = cv > 1.0 and C.Br or (cv > 0.5 and C.By or C.Bg)
    w(string.format(" %sp50%s %-9s %sp75%s %-9s %sp90%s %s%-9s%s %sp95%s %s%-9s%s %sp99%s %s%-9s%s %sp999%s %s%-9s%s │ %sn%s=%d",
      C.Dg, C.R, format_ns(p50),
      C.Dc, C.R, format_ns(p75),
      C.By, C.R, C.By, format_ns(p90), C.R,
      C.By, C.R, C.By, format_ns(p95), C.R,
      C.Br, C.R, C.Br, format_ns(p99), C.R,
      C.Br, C.R, C.Br, format_ns(p999), C.R,
      C.D, C.R, n_lat))
    w(string.format(" %smean%s %-9s %sstddev%s %-9s %sjitter%s %-9s %sCV%s %s%.3f%s │ %smin%s %-9s %smax%s %s%-9s%s │ %s%s%s",
      C.Dg, C.R, format_ns(mean),
      C.Dc, C.R, format_ns(sd),
      C.Dc, C.R, format_ns(jit),
      C.Bw, C.R, cv_c, cv, C.R,
      C.Dg, C.R, format_ns(min_l),
      C.Br, C.R, C.Br, format_ns(lt.max_val), C.R,
      C.D, bar_chart(p99, lt.max_val, 20), C.R))
  else
    w(C.D .. " awaiting latency samples…" .. C.R)
    w("")
  end

  -- ── left/right split ──
  local lw = math.max(50, math.floor(term_cols / 2) - 1)
  local rw = math.max(50, term_cols - lw - 3)
  local left = {}
  local right = {}

  -- ── LEFT: assets table ──
  left[#left+1] = C.Bc .. "─── ASSETS " .. string.rep("─", math.max(0, lw - 12)) .. C.R
  -- header
  left[#left+1] = string.format(" %s%-6s %7s %5s %8s %8s %5s %5s %5s  %8s%s",
    C.D, "TICKER", "EVENTS", "OPEN", "BUY-VOL", "SELL-VOL", "FILLS", "SUB", "CXL", "AVG-LAT", C.R)

  local max_asset_events = 0
  for _, row in pairs(state.by_asset) do
    if row.events > max_asset_events then max_asset_events = row.events end
  end

  for _, asset in ipairs(top_keys(state.by_asset, 10, function(a,b)
    return (state.by_asset[a].events) > (state.by_asset[b].events)
  end)) do
    local s = state.by_asset[asset]
    local avg_lat = s.latency_count > 0 and format_ns(s.latency_sum / s.latency_count) or "-"
    local vol_bar = bar_chart(s.events, max_asset_events, 6)
    left[#left+1] = string.format(" %s%-6s%s %7d %5d %8s %8s %5d %5d %5d %s%8s%s %s%s%s",
      C.Bw, asset, C.R, s.events, s.open_orders or 0,
      format_big(s.buy_notional or 0), format_big(s.sell_notional or 0),
      s.fills or 0, s.submits or 0, s.cancels or 0,
      C.Dc, avg_lat, C.R, C.D, vol_bar, C.R)
  end
  if count_table(state.by_asset) == 0 then
    left[#left+1] = C.Dy .. " waiting for events…" .. C.R
  end

  -- ── LEFT: recent events ──
  left[#left+1] = C.Bc .. "─── RECENT " .. string.rep("─", math.max(0, lw - 12)) .. C.R
  local max_recent = math.min(#state.recent, math.max(5, term_rows - 22))
  for i = 1, max_recent do
    local e = state.recent[i]
    local st_c = (e.status == "ok" and C.g) or (e.status == "failed" and C.r) or C.y
    local side_c = (e.side == "BUY" and C.g) or C.r
    local lat_s = e.latency_ns and format_ns(safe_int(e.latency_ns, 0)) or "-"
    left[#left+1] = string.format(" %s%9s%s %s%-4s%s %-6s %s%-4s%s %-6s %-14.14s q=%-4s px=%-4s %slat=%s%s",
      C.D, rel_time_ms(safe_int(e.observed_ns,nil), state.start_observed_ns), C.R,
      st_c, tostring(e.status or "?"):sub(1,4), C.R,
      tostring(e.type or "?"),
      side_c, tostring(e.side or "?"):sub(1,4), C.R,
      tostring(e.asset or "?"),
      tostring(e.id or ""),
      tostring(e.qty or 0), tostring(e.px or 0),
      C.Dc, lat_s, C.R)
  end
  if #state.recent == 0 then left[#left+1] = C.Dy .. " no events" .. C.R end

  -- ── LEFT: working orders ──
  left[#left+1] = C.Bc .. "─── WORKING ORDERS " .. string.rep("─", math.max(0, lw - 20)) .. C.R
  local orders = {}
  for _, o in pairs(state.open_orders) do orders[#orders+1] = o end
  table.sort(orders, function(a,b) return safe_int(a.submitted_ns,0) > safe_int(b.submitted_ns,0) end)
  for i = 1, math.min(#orders, 6) do
    local o = orders[i]
    local sc = (o.side == "BUY") and C.g or C.r
    left[#left+1] = string.format(" %s%9s%s %-6s %s%-4s%s %-14.14s rem=%-6s px=%-5s",
      C.D, rel_time_ms(safe_int(o.submitted_ns,nil), state.start_observed_ns), C.R,
      tostring(o.asset or "?"), sc, tostring(o.side or "?"):sub(1,4), C.R,
      tostring(o.id or ""), tostring(o.remaining_qty or 0), tostring(o.px or 0))
  end
  if #orders == 0 then left[#left+1] = C.D .. " none" .. C.R end

  -- ── RIGHT: positions (dense) ──
  right[#right+1] = C.Bc .. "─── POSITIONS " .. string.rep("─", math.max(0, rw - 15)) .. C.R
  right[#right+1] = string.format(" %s%-6s %8s %6s %10s %10s %5s%s",
    C.D, "ASSET", "QTY", "LAST", "CASH", "MTM", "FILLS", C.R)
  local pos_count = 0
  for asset, pos in sorted_pairs(state.positions, function(a,b)
    local pa, pb = state.positions[a], state.positions[b]
    if math.abs(pa.qty) == math.abs(pb.qty) then return a < b end
    return math.abs(pa.qty) > math.abs(pb.qty)
  end) do
    if pos_count >= 8 then break end
    pos_count = pos_count + 1
    local lpx = state.last_px_by_asset[asset] or pos.last_px or 0
    local mtm = pos.cash + pos.qty * lpx
    local mc = mtm >= 0 and C.g or C.r
    local qc = pos.qty >= 0 and C.Bg or C.Br
    right[#right+1] = string.format(" %s%-6s%s %s%8s%s %6d %10s %s%10s%s %5d",
      C.Bw, asset, C.R,
      qc, format_big(pos.qty), C.R,
      lpx,
      format_big(pos.cash),
      mc, format_big(mtm), C.R,
      pos.fills)
  end
  if pos_count == 0 then right[#right+1] = C.D .. " no positions" .. C.R end

  -- ── RIGHT: lanes ──
  right[#right+1] = C.Bc .. "─── LANES " .. string.rep("─", math.max(0, rw - 11)) .. C.R
  local max_lane_ev = 0
  for _, v in pairs(state.by_lane) do if v > max_lane_ev then max_lane_ev = v end end
  for _, lane in ipairs(top_keys(state.by_lane, 8, function(a,b)
    return (state.by_lane[a] or 0) > (state.by_lane[b] or 0)
  end)) do
    local ev = state.by_lane[lane]
    right[#right+1] = string.format(" %slane %-2s%s %7d %s%s%s",
      C.Bc, lane, C.R, ev, C.D, bar_chart(ev, max_lane_ev, 15), C.R)
  end

  -- ── RIGHT: traders ──
  right[#right+1] = C.Bc .. "─── TRADERS " .. string.rep("─", math.max(0, rw - 13)) .. C.R
  local max_trader_ev = 0
  for _, v in pairs(state.by_trader) do if v > max_trader_ev then max_trader_ev = v end end
  for _, trader in ipairs(top_keys(state.by_trader, 6, function(a,b)
    return (state.by_trader[a] or 0) > (state.by_trader[b] or 0)
  end)) do
    local ev = state.by_trader[trader]
    right[#right+1] = string.format(" %s%-8s%s %7d %s%s%s",
      C.Bm, trader, C.R, ev, C.D, bar_chart(ev, max_trader_ev, 12), C.R)
  end

  -- ── RIGHT: event type breakdown ──
  right[#right+1] = C.Bc .. "─── EVENT TYPES " .. string.rep("─", math.max(0, rw - 17)) .. C.R
  local type_colors = { SUBMIT=C.Bg, MODIFY=C.Bc, CANCEL=C.By, FILL=C.Bm, FAIL=C.Br }
  local max_type_ev = 0
  for _, v in pairs(state.by_type) do if v > max_type_ev then max_type_ev = v end end
  for _, etype in ipairs(top_keys(state.by_type, 6, function(a,b)
    return (state.by_type[a] or 0) > (state.by_type[b] or 0)
  end)) do
    local ev = state.by_type[etype]
    local tc = type_colors[etype] or C.w
    right[#right+1] = string.format(" %s%-7s%s %7d %s%s%s",
      tc, etype, C.R, ev, C.D, bar_chart(ev, max_type_ev, 12), C.R)
  end

  -- ── RIGHT: stress regions ──
  right[#right+1] = C.By .. "─── STRESS REGIONS " .. string.rep("─", math.max(0, rw - 20)) .. C.R
  if state.current_stress then
    right[#right+1] = string.format(" %s!! ACTIVE%s peak=%s events=%d",
      C.Br, C.R, format_ns(state.current_stress.peak_ns), state.current_stress.events)
  end
  for i = 1, math.min(#state.stress_regions, 4) do
    local sr = state.stress_regions[i]
    right[#right+1] = string.format(" %s#%-2d%s peak=%s avg=%s ev=%d",
      C.Dy, sr.id, C.R, format_ns(sr.peak_ns), format_ns(sr.avg_lat or 0), sr.events)
  end
  if #state.stress_regions == 0 and not state.current_stress then
    right[#right+1] = C.D .. " none detected" .. C.R
  end

  -- ── RIGHT: failures ──
  right[#right+1] = C.Br .. "─── FAILURES " .. string.rep("─", math.max(0, rw - 14)) .. C.R
  for i = 1, math.min(#state.failures, 4) do
    local e = state.failures[i]
    right[#right+1] = string.format(" %slane=%-2s seq=%-6s%s %-6s %s",
      C.Dr, tostring(e.lane or "?"), tostring(e.seq or "?"), C.R,
      tostring(e.type or "?"), tostring(e.reason or ""):sub(1, rw - 25))
  end
  if #state.failures == 0 then right[#right+1] = C.D .. " none" .. C.R end

  -- ── RIGHT: last runs ──
  right[#right+1] = C.Bc .. "─── RUNS " .. string.rep("─", math.max(0, rw - 10)) .. C.R
  for i = 1, math.min(#last_runs, 3) do
    local r = last_runs[i]
    local rc = (r.state == "idle" and C.g) or (r.state == "error" and C.r) or C.y
    right[#right+1] = string.format(" %s%-17s%s %s%-4s%s msg=%s fail=%s",
      C.D, tostring(r.ended_at or "?"), C.R, rc, tostring(r.state or "?"):sub(1,4), C.R,
      tostring(r.messages or "?"), tostring(r.failures or "?"))
  end
  if #last_runs == 0 then right[#right+1] = C.D .. " none" .. C.R end

  -- ── merge & output ──
  -- first output the header rows
  io.write("\27[H\27[J")
  for _, line in ipairs(buf) do
    io.write(line .. "\n")
  end

  -- two-column merged
  local sep = C.D .. "│" .. C.R
  local body_budget = math.max(0, term_rows - #buf - 1)
  local total_body = math.min(math.max(#left, #right), body_budget)
  local pad_rows = math.max(0, body_budget - total_body)
  -- distribute extra rows to left recent events
  for i = 1, total_body do
    local l = left[i] or ""
    local r = right[i] or ""
    -- strip to width (rough – ANSI makes this approximate)
    io.write(l)
    local l_plain = l:gsub("\27%[[%d;]*m", "")
    local l_pad = lw - #l_plain
    if l_pad > 0 then io.write(string.rep(" ", l_pad)) end
    io.write(" " .. sep .. " ")
    io.write(r .. "\n")
  end
  -- fill remaining rows
  for _ = 1, pad_rows do
    io.write(string.rep(" ", lw) .. " " .. sep .. "\n")
  end
  -- bottom bar
  io.write(C.Bc .. string.rep("═", term_cols) .. C.R)
  io.flush()
end


local function main()
  local opts  = parse_args(arg)
  local state = new_state(opts.recent_limit, opts.latency_window)
  local offset = 0
  local stream_offset = 0

  setup_raw_tty()

  local init_status = load_status(opts.status_json)
  sync_stream_from_status(opts, init_status)
  local current_run_started_at = init_status.started_at

  local last_status_mtime  = nil
  local last_history_mtime = nil
  local refresh_sec    = math.max(0.05, opts.refresh_ms / 1000.0)
  local last_total     = -1
  local render_count   = 0

  local function cleanup() restore_tty() end

  local ok, err = xpcall(function()
    while true do
      local key = read_key_nonblocking()
      if key == "q" or key == "Q" or key == "x" then break end
      if key == string.char(24) then os.execute("tmux kill-session 2>/dev/null"); break end

      local status = load_status(opts.status_json)
      sync_stream_from_status(opts, status)

      -- Auto-detect new stress test runs or status changes
      if status.started_at and status.started_at ~= current_run_started_at then
        reset_state(state)
        current_run_started_at = status.started_at
        offset = 0
        stream_offset = 0
        load_tail_snapshot(opts.event_log, state, opts.tail_snapshot_lines)
        offset = file_size(opts.event_log) or 0
        if opts.event_stream_log then
          stream_offset = file_size(opts.event_stream_log) or 0
        end
      end

      local new_off, ev_changed, reached_end = tail_events(
        opts.event_log, state, offset, opts.scan_lines_per_tick)
      offset = new_off
      local stream_changed = false
      local stream_reached_end = true
      if opts.event_stream_log then
        local new_stream_off, changed_stream, reached_stream_end = tail_events(
          opts.event_stream_log, state, stream_offset, opts.scan_lines_per_tick)
        stream_offset = new_stream_off
        stream_changed = changed_stream
        stream_reached_end = reached_stream_end
      end

      local smtime = opts.status_json      and mtime_sec(opts.status_json)      or nil
      local hmtime = opts.run_history_jsonl and mtime_sec(opts.run_history_jsonl) or nil
      local aux_changed = (smtime ~= last_status_mtime) or (hmtime ~= last_history_mtime)
      last_status_mtime  = smtime
      last_history_mtime = hmtime

      render_count = render_count + 1
      local catching_up = (not reached_end) or (not stream_reached_end)
      local should_render = ev_changed or stream_changed or aux_changed
        or (state.total ~= last_total)
        or (render_count % 15 == 0)
      if catching_up and (render_count % math.max(1, opts.catchup_render_every) ~= 0) then
        should_render = false
      end

      if should_render then
        last_total = state.total
        local last_runs = load_last_runs(opts.run_history_jsonl, 5)
        local catchup_info = (not reached_end) and { offset = offset } or nil
        local tr, tc = terminal_size()
        render(state, opts, status, last_runs, catchup_info, tr, tc)
      end

      os.execute(string.format("sleep %.3f", refresh_sec))
    end
  end, debug.traceback)

  cleanup()
  if not ok then io.stderr:write(tostring(err) .. "\n"); os.exit(1) end
  os.exit(0)
end

main()
