open Result

let check = OUnit.assert_equal ~printer:string_of_int

let errors ?(check_msg = false) exp = function
  | Ok opt ->
    Alcotest.fail (Format.asprintf "Result.Ok %a when Result.error %s expected"
                     Tcp.Options.pps opt exp)
  | Error p -> if check_msg then Alcotest.check Alcotest.string "Result.Error didn't give the expected error message" exp p else ()

let test_unmarshal_bad_mss () =
  let odd_sized_mss = Cstruct.create 3 in
  Cstruct.set_uint8 odd_sized_mss 0 2;
  Cstruct.set_uint8 odd_sized_mss 1 3;
  Cstruct.set_uint8 odd_sized_mss 2 255;
  errors "MSS size is unreasonable" (Tcp.Options.unmarshal odd_sized_mss);
  Lwt.return_unit

let test_unmarshal_bogus_length () =
  let bogus = Cstruct.create (4*8-1) in
  Cstruct.memset bogus 0;
  Cstruct.blit_from_string "\x6e\x73\x73\x68\x2e\x63\x6f\x6d" 0 bogus 0 8;
  (* some unknown option (0x6e) with claimed length 0x73, longer than the buffer *)
  (* this invalidates later results, but previous ones are still valid, if any *)
  OUnit.assert_equal (Result.Ok []) (Tcp.Options.unmarshal bogus);
  Lwt.return_unit

let test_unmarshal_zero_length () =
  let bogus = Cstruct.create 10 in
  Cstruct.memset bogus 1; (* noops *)
  Cstruct.set_uint8 bogus 0 64; (* arbitrary unknown option-kind *)
  Cstruct.set_uint8 bogus 1 0;
  (* this invalidates later results, but previous ones are still valid, if any *)
  OUnit.assert_equal (Result.Ok []) (Tcp.Options.unmarshal bogus);
  Lwt.return_unit

let test_unmarshal_simple_options () =
  (* empty buffer should give empty list *)
  OUnit.assert_equal (Result.Ok []) (Tcp.Options.unmarshal (Cstruct.create 0));

  (* buffer with just eof should give empty list *)
  let just_eof = Cstruct.create 1 in
  Cstruct.set_uint8 just_eof 0 0;
  OUnit.assert_equal (Result.Ok []) (Tcp.Options.unmarshal just_eof);

  (* buffer with single noop should give a list with 1 noop *)
  let just_noop = Cstruct.create 1 in
  Cstruct.set_uint8 just_noop 0 1;
  OUnit.assert_equal (Result.Ok [ Tcp.Options.Noop ]) (Tcp.Options.unmarshal just_noop); 

  (* buffer with valid, but unknown, option should be correctly communicated *)
  let unknown = Cstruct.create 10 in
  let data = "hi mom!!" in
  let kind = 18 in (* TODO: more canonically unknown option-kind *)
  Cstruct.blit_from_string data 0 unknown 2 (String.length data);
  Cstruct.set_uint8 unknown 0 kind;
  Cstruct.set_uint8 unknown 1 (Cstruct.len unknown);
  OUnit.assert_equal
    (Result.Ok [Tcp.Options.Unknown (kind, data)])
    (Tcp.Options.unmarshal unknown);
  Lwt.return_unit

let test_unmarshal_stops_at_eof () =
  let buf = Cstruct.create 14 in
  let ts1 = (Int32.of_int 0xabad1dea) in
  let ts2 = (Int32.of_int 0xc0ffee33) in
  Cstruct.memset buf 0;
  Cstruct.set_uint8 buf 0 4; (* sack_ok *)
  Cstruct.set_uint8 buf 1 2; (* length of two *)
  Cstruct.set_uint8 buf 2 1; (* noop *)
  Cstruct.set_uint8 buf 3 0; (* eof *)
  Cstruct.set_uint8 buf 4 8; (* timestamp *)
  Cstruct.set_uint8 buf 5 10; (* timestamps are 2 4-byte times *)
  Cstruct.BE.set_uint32 buf 6 ts1;
  Cstruct.BE.set_uint32 buf 10 ts2;
  (* correct parsing will ignore options from after eof, so we shouldn't see
     timestamp or noop *)
  match Tcp.Options.unmarshal buf with
  | Error s -> Alcotest.fail s
  | Result.Ok result ->
    OUnit.assert_equal ~msg:"SACK_ok missing" ~printer:string_of_bool
      true (List.mem Tcp.Options.SACK_ok result);
    OUnit.assert_equal ~msg: "noop missing" ~printer:string_of_bool
      true (List.mem Tcp.Options.Noop result);
    OUnit.assert_equal ~msg:"timestamp present" ~printer:string_of_bool
      false (List.mem (Tcp.Options.Timestamp (ts1, ts2)) result);
    Lwt.return_unit

let test_unmarshal_ok_options () =
  let buf = Cstruct.create 8 in
  Cstruct.memset buf 0;
  let opts = [ Tcp.Options.MSS 536; Tcp.Options.SACK_ok; Tcp.Options.Noop;
               Tcp.Options.Noop ] in
  let marshalled = Tcp.Options.marshal buf opts in
  check marshalled 8;
  (* order is reversed by the unmarshaller, which is fine but we need to
     account for that when making equality assertions *)
  match Tcp.Options.unmarshal buf with
  | Error s -> Alcotest.fail s
  | Ok l ->
    OUnit.assert_equal (List.rev l) opts;
    Lwt.return_unit

let test_unmarshal_random_data () =
  let random = Cstruct.create 64 in
  let iterations = 100 in
  Random.self_init ();
  let set_random pos =
    let num = Random.int32 Int32.max_int in
    Cstruct.BE.set_uint32 random pos num;
  in
  let rec check = function
    | n when n <= 0 -> Lwt.return_unit
    | n ->
      List.iter set_random [0;4;8;12;16;20;24;28;32;36;40;44;48;52;56;60];
      Cstruct.hexdump random;
      (* acceptable outcomes: some list of options or the expected exception *)
      match Tcp.Options.unmarshal random with
      | Error _ -> (* Errors are OK, just finish *) Lwt.return_unit
      | Ok l ->
        Tcp.Options.pps Format.std_formatter l;
        (* a really basic truth: the longest list we can have is 64 noops *)
        OUnit.assert_equal true (List.length l < 65);
        check (n - 1)
  in
  check iterations

let test_marshal_unknown () =
  let buf = Cstruct.create 10 in
  Cstruct.memset buf 255;
  let unknown = [ Tcp.Options.Unknown (64, "  ") ] in (* overall, length 4 *)
  check 4 (Tcp.Options.marshal buf unknown); (* should have written 4 bytes *)
  Cstruct.hexdump buf;
  check ~msg:"option kind" 64 (Cstruct.get_uint8 buf 0); (* option-kind *)
  check ~msg:"option length" 4 (Cstruct.get_uint8 buf 1); (* option-length *)
  check ~msg:"data 1" 0x20 (Cstruct.get_uint8 buf 2); (* data *)
  check ~msg:"data 2" 0x20 (Cstruct.get_uint8 buf 3); (* moar data *)
  check ~msg:"canary" 255 (Cstruct.get_uint8 buf 4); (* unwritten region *)
  Lwt.return_unit

let test_marshal_padding () =
  let buf = Cstruct.create 8 in
  Cstruct.memset buf 255;
  let extract = Cstruct.get_uint8 buf in
  let needs_padding = [ Tcp.Options.SACK_ok ] in
  check 4 (Tcp.Options.marshal buf needs_padding);
  check 4 (extract 0);
  check 2 (extract 1);
  check 0 (extract 2); (* should pad out the rest of the buffer with 0 *)
  check 0 (extract 3);
  check 255 (extract 4); (* but not keep padding into random memory *)
  Lwt.return_unit

let test_marshal_empty () =
  let buf = Cstruct.create 4 in
  Cstruct.memset buf 255;
  check 0 (Tcp.Options.marshal buf []);
  check 255 (Cstruct.get_uint8 buf 0);
  Lwt.return_unit

let suite = [
  "unmarshal broken mss", `Quick, test_unmarshal_bad_mss;
  "unmarshal option with bogus length", `Quick, test_unmarshal_bogus_length;
  "unmarshal option with zero length", `Quick, test_unmarshal_zero_length;
  "unmarshal simple cases", `Quick, test_unmarshal_simple_options;
  "unmarshal stops at eof", `Quick, test_unmarshal_stops_at_eof;
  "unmarshal non-broken tcp options", `Quick, test_unmarshal_ok_options;
  "unmarshalling random data returns", `Quick, test_unmarshal_random_data;
  "test marshalling an unknown value", `Quick, test_marshal_unknown;
  "test marshalling when padding is needed", `Quick, test_marshal_padding;
  "test marshalling the empty list", `Quick, test_marshal_empty;
]
