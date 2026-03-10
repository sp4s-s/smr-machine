exception Test_failure of string

let fail message = raise (Test_failure message)

let expect cond message = if not cond then fail message

let script =
  {|
SUBMIT 1000 ord-1 alice BUY 10 100
FILL 1010 ord-1 4 100
SUBMIT 1020 ord-2 bob SELL 5 101
FILL 1030 ord-2 5 101
FAIL 1040 injected-risk-limit-breach
|}

let advanced_script =
  {|
# partial open, full close, then flip short
SUBMIT 2000 ord-10 alice BUY 10 100
FILL 2010 ord-10 10 100
SUBMIT 2020 ord-11 alice SELL 4 103
FILL 2030 ord-11 4 103
SUBMIT 2040 ord-12 alice SELL 10 98
FILL 2050 ord-12 10 98
|}

let modify_script =
  {|
SUBMIT 3000 ord-20 alice BUY 10 100
MODIFY 3010 ord-20 7 102
FILL 3020 ord-20 7 102
|}

let multi_failure_script =
  {|
SUBMIT 4000 ord-30 alice BUY 5 100
CANCEL 4010 missing
FILL 4020 ord-30 6 100
FAIL 4030 final-stop
|}

let () =
  try
    let commands = Deterministic.parse_script script in
    let result = Deterministic.replay ~checkpoint_interval:2 commands in
    expect (List.length result.checkpoints >= 3) "expected checkpoints to be captured";
    expect (Option.is_some result.failure) "expected failure to be recorded";
    (match result.failure with
    | Some (seq, reason) ->
        expect (seq = 5) "unexpected failure sequence";
        expect (reason = "injected-risk-limit-breach") "unexpected failure reason"
    | None -> fail "missing failure");
    let rollback = Deterministic.rollback_to_seq result 4 in
    match rollback with
    | None -> fail "expected rollback snapshot"
    | Some snapshot ->
        expect (snapshot.seq = 4) "rollback seq mismatch";
        let alice =
          List.assoc_opt "alice" snapshot.positions |> Option.map (fun p -> p.Deterministic.qty)
        in
        let bob =
          List.assoc_opt "bob" snapshot.positions |> Option.map (fun p -> p.Deterministic.qty)
        in
        expect (alice = Some 4) "alice qty mismatch";
        expect (bob = Some (-5)) "bob qty mismatch"
    ;
    let advanced = Deterministic.parse_script advanced_script |> Deterministic.replay in
    let final = advanced.final_state in
    let alice_position = List.assoc "alice" final.positions in
    expect (alice_position.qty = -4) "advanced qty mismatch";
    expect (alice_position.realized_pnl = 0) "advanced realized pnl mismatch";
    expect (alice_position.avg_entry_px = Some 98) "advanced avg entry mismatch";
    expect (List.length final.open_orders = 0) "expected no open orders after advanced replay";
    let modified = Deterministic.parse_script modify_script |> Deterministic.replay in
    let modified_position = List.assoc "alice" modified.final_state.positions in
    expect (modified_position.qty = 7) "modify qty mismatch";
    expect (modified_position.avg_entry_px = Some 102) "modify price mismatch";
    let duplicate_failure =
      Deterministic.parse_script
        "SUBMIT 1 ord-x alice BUY 1 10\nSUBMIT 2 ord-x alice BUY 1 10\n"
      |> Deterministic.replay
    in
    expect (duplicate_failure.failure = Some (2, "duplicate order id: ord-x"))
      "expected duplicate id failure";
    let cancel_failure =
      Deterministic.parse_script "CANCEL 1 missing\n" |> Deterministic.replay
    in
    expect (cancel_failure.failure = Some (1, "cancel for unknown order: missing"))
      "expected cancel failure";
    let multi_failure =
      Deterministic.parse_script multi_failure_script
      |> Deterministic.replay ~max_failures:2
    in
    expect
      (multi_failure.failures
      = [ (2, "cancel for unknown order: missing"); (3, "overfill on order: ord-30") ])
      "expected multiple failures";
    expect (multi_failure.failure = Some (2, "cancel for unknown order: missing"))
      "expected first failure to remain available"
  with Test_failure message ->
    prerr_endline message;
    exit 1
