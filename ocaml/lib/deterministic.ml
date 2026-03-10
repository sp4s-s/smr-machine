type side = Buy | Sell

type command =
  | Submit of {
      ts_ns : int64;
      id : string;
      trader : string;
      side : side;
      qty : int;
      px : int;
    }
  | Cancel of {
      ts_ns : int64;
      id : string;
    }
  | Fill of {
      ts_ns : int64;
      id : string;
      qty : int;
      px : int;
    }
  | Modify of {
      ts_ns : int64;
      id : string;
      qty : int;
      px : int;
    }
  | Fail of {
      ts_ns : int64;
      reason : string;
    }

type position = {
  qty : int;
  cash : int;
  realized_pnl : int;
  avg_entry_px : int option;
}

type order = {
  trader : string;
  side : side;
  mutable open_qty : int;
  mutable px : int;
}

type state = {
  positions : (string, position) Hashtbl.t;
  orders : (string, order) Hashtbl.t;
  mutable seq : int;
}

type snapshot = {
  seq : int;
  hash : string;
  positions : (string * position) list;
  open_orders : (string * order) list;
}

type replay_result = {
  final_state : snapshot;
  failure : (int * string) option;
  failures : (int * string) list;
  checkpoints : snapshot list;
}

let empty_state () =
  { positions = Hashtbl.create 32; orders = Hashtbl.create 32; seq = 0 }

let trim = String.trim

let split_ws line =
  line
  |> String.split_on_char ' '
  |> List.filter (fun token -> token <> "")

let hd_opt = function [] -> None | head :: _ -> Some head

let parse_side = function
  | "BUY" -> Buy
  | "SELL" -> Sell
  | value -> invalid_arg ("unknown side: " ^ value)

let get_nth parts idx name =
  match List.nth_opt parts idx with
  | Some value -> value
  | None -> invalid_arg ("missing " ^ name)

let parse_int parts idx name = int_of_string (get_nth parts idx name)
let parse_i64 parts idx name = Int64.of_string (get_nth parts idx name)

let parse_line line =
  let parts = split_ws line in
  match parts with
  | [] -> None
  | cmd :: _ -> (
      match String.uppercase_ascii cmd with
      | "SUBMIT" ->
          Some
            (Submit
               {
                 ts_ns = parse_i64 parts 1 "ts_ns";
                 id = get_nth parts 2 "id";
                 trader = get_nth parts 3 "trader";
                 side = parse_side (String.uppercase_ascii (get_nth parts 4 "side"));
                 qty = parse_int parts 5 "qty";
                 px = parse_int parts 6 "px";
               })
      | "CANCEL" ->
          Some
            (Cancel
               {
                 ts_ns = parse_i64 parts 1 "ts_ns";
                 id = get_nth parts 2 "id";
               })
      | "FILL" ->
          Some
            (Fill
               {
                 ts_ns = parse_i64 parts 1 "ts_ns";
                 id = get_nth parts 2 "id";
                 qty = parse_int parts 3 "qty";
                 px = parse_int parts 4 "px";
               })
      | "MODIFY" ->
          Some
            (Modify
               {
                 ts_ns = parse_i64 parts 1 "ts_ns";
                 id = get_nth parts 2 "id";
                 qty = parse_int parts 3 "qty";
                 px = parse_int parts 4 "px";
               })
      | "FAIL" ->
          let ts_ns = parse_i64 parts 1 "ts_ns" in
          let reason = parts |> List.filteri (fun idx _ -> idx >= 2) |> String.concat " " in
          Some (Fail { ts_ns; reason = trim reason })
      | "#" -> None
      | value when String.length value > 0 && value.[0] = '#' -> None
      | _ -> invalid_arg ("unknown command: " ^ cmd))

let parse_script text =
  text
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
         let clean = trim line in
         if clean = "" then None else parse_line clean)

let position_for (state : state) trader =
  match Hashtbl.find_opt state.positions trader with
  | Some position -> position
  | None ->
      let position = { qty = 0; cash = 0; realized_pnl = 0; avg_entry_px = None } in
      Hashtbl.add state.positions trader position;
      position

let clone_position p =
  { qty = p.qty; cash = p.cash; realized_pnl = p.realized_pnl; avg_entry_px = p.avg_entry_px }
let clone_order o = { trader = o.trader; side = o.side; open_qty = o.open_qty; px = o.px }

let side_factor = function Buy -> 1 | Sell -> -1

let abs_int value = if value < 0 then -value else value

let avg_entry_after_fill position signed_qty px =
  let prev_qty = position.qty in
  let next_qty = prev_qty + signed_qty in
  if next_qty = 0 then None
  else if prev_qty = 0 then Some px
  else if prev_qty * signed_qty > 0 then
    let total_qty = abs_int prev_qty + abs_int signed_qty in
    let prev_px = Option.value position.avg_entry_px ~default:px in
    Some (((prev_px * abs_int prev_qty) + (px * abs_int signed_qty)) / total_qty)
  else if abs_int signed_qty < abs_int prev_qty then position.avg_entry_px
  else if abs_int signed_qty = abs_int prev_qty then None
  else Some px

let realized_delta position signed_qty px =
  if position.qty = 0 || position.qty * signed_qty > 0 then 0
  else
    let matched_qty = min (abs_int position.qty) (abs_int signed_qty) in
    let avg_px = Option.value position.avg_entry_px ~default:px in
    matched_qty * (px - avg_px) * if position.qty > 0 then 1 else -1

let apply_command (state : state) = function
  | Submit { id; trader; side; qty; px; _ } ->
      if qty <= 0 || px <= 0 then Error "submit must have positive qty and px"
      else if Hashtbl.mem state.orders id then Error ("duplicate order id: " ^ id)
      else (
        Hashtbl.add state.orders id { trader; side; open_qty = qty; px };
        Ok ())
  | Cancel { id; _ } ->
      if Hashtbl.mem state.orders id then (
        Hashtbl.remove state.orders id;
        Ok ())
      else Error ("cancel for unknown order: " ^ id)
  | Fill { id; qty; px; _ } ->
      if qty <= 0 || px <= 0 then Error "fill must have positive qty and px"
      else (
        match Hashtbl.find_opt state.orders id with
        | None -> Error ("fill for unknown order: " ^ id)
        | Some order ->
            if qty > order.open_qty then Error ("overfill on order: " ^ id)
            else
              let position = position_for state order.trader in
              let signed_qty = side_factor order.side * qty in
              let signed_cash = -signed_qty * px in
              let next_qty = position.qty + signed_qty in
              let next_cash = position.cash + signed_cash in
              let avg_entry_px = avg_entry_after_fill position signed_qty px in
              let realized_delta = realized_delta position signed_qty px in
              Hashtbl.replace state.positions order.trader
                {
                  qty = next_qty;
                  cash = next_cash;
                  realized_pnl = position.realized_pnl + realized_delta;
                  avg_entry_px;
                };
              order.open_qty <- order.open_qty - qty;
              if order.open_qty = 0 then Hashtbl.remove state.orders id;
              Ok ())
  | Modify { id; qty; px; _ } ->
      if qty <= 0 || px <= 0 then Error "modify must have positive qty and px"
      else (
        match Hashtbl.find_opt state.orders id with
        | None -> Error ("modify for unknown order: " ^ id)
        | Some order ->
            order.open_qty <- qty;
            order.px <- px;
            Ok ())
  | Fail { reason; _ } -> Error reason

let snapshot_of_state (state : state) =
  let positions =
    Hashtbl.to_seq state.positions
    |> List.of_seq
    |> List.sort (fun (lhs, _) (rhs, _) -> String.compare lhs rhs)
    |> List.map (fun (trader, position) -> (trader, clone_position position))
  in
  let open_orders =
    Hashtbl.to_seq state.orders
    |> List.of_seq
    |> List.sort (fun (lhs, _) (rhs, _) -> String.compare lhs rhs)
    |> List.map (fun (id, order) -> (id, clone_order order))
  in
  let fingerprint =
    let position_terms =
      positions
      |> List.map (fun (trader, p) ->
             Printf.sprintf "%s:%d:%d:%d:%s" trader p.qty p.cash p.realized_pnl
               (match p.avg_entry_px with None -> "-" | Some px -> string_of_int px))
    in
    let order_terms =
      open_orders
      |> List.map (fun (id, o) ->
             let side = match o.side with Buy -> "B" | Sell -> "S" in
             Printf.sprintf "%s:%s:%s:%d:%d" id o.trader side o.open_qty o.px)
    in
    Digest.to_hex (Digest.string (String.concat "|" (position_terms @ order_terms)))
  in
  { seq = state.seq; hash = fingerprint; positions; open_orders }

let replay ?(checkpoint_interval = 2) ?(max_failures = 1) commands =
  let state = empty_state () in
  let checkpoints = ref [ snapshot_of_state state ] in
  let failures = ref [] in
  let continue = ref true in
  List.iter
    (fun command ->
      if !continue then (
        state.seq <- state.seq + 1;
        match apply_command state command with
        | Ok () ->
            if state.seq mod checkpoint_interval = 0 then
              checkpoints := !checkpoints @ [ snapshot_of_state state ]
        | Error reason ->
            failures := !failures @ [ (state.seq, reason) ];
            checkpoints := !checkpoints @ [ snapshot_of_state state ];
            if List.length !failures >= max_failures then continue := false))
    commands;
  let final_state = snapshot_of_state state in
  let first_failure =
    match !failures with
    | [] -> None
    | failure :: _ -> Some failure
  in
  { final_state; failure = first_failure; failures = !failures; checkpoints = !checkpoints }

let rollback_to_seq result seq =
  result.checkpoints
  |> List.filter (fun checkpoint -> checkpoint.seq <= seq)
  |> List.rev |> hd_opt

let string_of_side = function Buy -> "BUY" | Sell -> "SELL"

let render_snapshot snapshot =
  let positions =
    snapshot.positions
    |> List.map (fun (trader, p) ->
           Printf.sprintf "  trader=%s qty=%d cash=%d realized_pnl=%d avg_entry_px=%s" trader
             p.qty p.cash p.realized_pnl
             (match p.avg_entry_px with None -> "-" | Some px -> string_of_int px))
  in
  let orders =
    snapshot.open_orders
    |> List.map (fun (id, order) ->
           Printf.sprintf "  order=%s trader=%s side=%s open_qty=%d px=%d" id order.trader
             (string_of_side order.side) order.open_qty order.px)
  in
  String.concat "\n"
    ([ Printf.sprintf "snapshot seq=%d hash=%s" snapshot.seq snapshot.hash ]
    @ [ "positions:" ]
    @ (if positions = [] then [ "  <none>" ] else positions)
    @ [ "open_orders:" ]
    @ if orders = [] then [ "  <none>" ] else orders)

let render_report result =
  let failure_line =
    match result.failure with
    | None -> "failure: none"
    | Some (seq, reason) -> Printf.sprintf "failure: seq=%d reason=%s" seq reason
  in
  let failures =
    match result.failures with
    | [] -> [ "failures:"; "  <none>" ]
    | entries ->
        "failures:"
        :: List.map
             (fun (seq, reason) -> Printf.sprintf "  seq=%d reason=%s" seq reason)
             entries
  in
  let checkpoint_lines =
    result.checkpoints
    |> List.map (fun checkpoint ->
           Printf.sprintf "  seq=%d hash=%s" checkpoint.seq checkpoint.hash)
  in
  String.concat "\n"
    ([ failure_line ]
    @ failures
    @ [ "checkpoints:" ]
    @ checkpoint_lines
    @ [ "final_state:"; render_snapshot result.final_state ])
