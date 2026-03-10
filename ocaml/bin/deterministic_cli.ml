let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let usage () =
  prerr_endline
    "usage: deterministic-cli replay <script-path> [--checkpoint N] [--rollback-seq N] [--max-failures N]";
  exit 1

let parse_args argv =
  match Array.length argv with
  | n when n >= 3 && argv.(1) = "replay" ->
      let path = argv.(2) in
      let checkpoint = ref 2 in
      let rollback_seq = ref None in
      let max_failures = ref 1 in
      let i = ref 3 in
      while !i < n do
        match argv.(!i) with
        | "--checkpoint" when !i + 1 < n ->
            checkpoint := int_of_string argv.(!i + 1);
            i := !i + 2
        | "--rollback-seq" when !i + 1 < n ->
            rollback_seq := Some (int_of_string argv.(!i + 1));
            i := !i + 2
        | "--max-failures" when !i + 1 < n ->
            max_failures := int_of_string argv.(!i + 1);
            i := !i + 2
        | _ -> usage ()
      done;
      (path, !checkpoint, !rollback_seq, !max_failures)
  | _ -> usage ()

let () =
  let path, checkpoint_interval, rollback_seq, max_failures = parse_args Sys.argv in
  let script = read_file path |> Deterministic.parse_script in
  let result =
    Deterministic.replay ~checkpoint_interval ~max_failures script
  in
  print_endline (Deterministic.render_report result);
  match rollback_seq with
  | None -> ()
  | Some seq ->
      print_endline "";
      (match Deterministic.rollback_to_seq result seq with
      | None -> print_endline "rollback: unavailable"
      | Some snapshot ->
          print_endline "rollback:";
          print_endline (Deterministic.render_snapshot snapshot))
