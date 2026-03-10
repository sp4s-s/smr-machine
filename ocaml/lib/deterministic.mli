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

type state

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

val empty_state : unit -> state
val parse_script : string -> command list
val replay : ?checkpoint_interval:int -> ?max_failures:int -> command list -> replay_result
val rollback_to_seq : replay_result -> int -> snapshot option
val render_snapshot : snapshot -> string
val render_report : replay_result -> string
