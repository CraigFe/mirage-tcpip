type t = {
  src     : Ipaddr.V4.t;
  dst     : Ipaddr.V4.t;
  proto   : Cstruct.uint8;
  ttl     : Cstruct.uint8;
  options : Cstruct.t;
}

type protocol = [
  | `ICMP
  | `TCP
  | `UDP ]

let pp fmt t =
  Format.fprintf fmt "IPv4 packet %a -> %a: proto %d, ttl %d, options %a"
    Ipaddr.V4.pp_hum t.src Ipaddr.V4.pp_hum t.dst t.proto t.ttl Cstruct.hexdump_pp t.options

let equal p q = (p = q)

module Unmarshal = struct
  type error = string

  let int_to_protocol = function
    | 1  -> Some `ICMP
    | 6  -> Some `TCP
    | 17 -> Some `UDP
    | _  -> None

  let of_cstruct buf =
    let open Rresult in
    let open Ipv4_wire in
    let length_of_hlen_version n = (n land 0x0f) * 4 in
    let get_header_length buf =
      try
        Result.Ok (get_ipv4_hlen_version buf |> length_of_hlen_version)
      with
      | Invalid_argument s -> Result.Error s
    in
    let check_header_len buf options_end =
      if options_end < 20 then Result.Error
          (Printf.sprintf "IPv4 header claimed to have size < 20: %d" options_end)
      else Result.Ok (options_end - sizeof_ipv4)
    in
    let check_overall_len buf len =
      if (Cstruct.len buf) < len then Result.Error "buffer supplied was shorter than claimed length of header + payload"
      else Result.Ok ()
    in
    let parse buf options_len =
      let payload_len = (get_ipv4_len buf) - sizeof_ipv4 - options_len in
      check_overall_len buf (options_len + sizeof_ipv4 + payload_len) >>= fun () ->
      let src = Ipaddr.V4.of_int32 (get_ipv4_src buf) in
      let dst = Ipaddr.V4.of_int32 (get_ipv4_dst buf) in
      let proto = get_ipv4_proto buf in
      let ttl = get_ipv4_ttl buf in
      let options =
        if options_len > 0 then (Cstruct.sub buf sizeof_ipv4 options_len)
        else (Cstruct.create 0)
      in
      let payload_len = (get_ipv4_len buf) - sizeof_ipv4 - options_len in
      let payload = Cstruct.sub buf (sizeof_ipv4 + options_len) payload_len in
      Ok ({src; dst; proto; ttl; options;}, payload)
    in
    get_header_length buf >>= check_header_len buf >>= parse buf
end
module Marshal = struct
  open Ipv4_wire

  type error = string

  let protocol_to_int = function
    | `ICMP   -> 1
    | `TCP    -> 6
    | `UDP    -> 17

  let pseudoheader ~src ~dst ~proto len =
    let proto = protocol_to_int proto in
    let ph = Cstruct.create 12 in
    let numify = Ipaddr.V4.to_int32 in
    Cstruct.BE.set_uint32 ph 0 (numify src);
    Cstruct.BE.set_uint32 ph 4 (numify dst);
    Cstruct.set_uint8 ph 8 0;
    Cstruct.set_uint8 ph 9 proto;
    Cstruct.BE.set_uint16 ph 10 len;
    ph

  let unsafe_fill t buf =
    let nearest_4 n = match n mod 4 with
      | 0 -> n
      | k -> (4 - k) + n
    in
    let options_len = nearest_4 @@ Cstruct.len t.options in
    set_ipv4_hlen_version buf ((4 lsl 4) + 5 + (options_len / 4));
    set_ipv4_ttl buf t.ttl;
    set_ipv4_proto buf t.proto;
    set_ipv4_src buf (Ipaddr.V4.to_int32 t.src);
    set_ipv4_dst buf (Ipaddr.V4.to_int32 t.dst);
    Cstruct.blit t.options 0 buf sizeof_ipv4 (Cstruct.len t.options)

  let into_cstruct t buf =
    if Cstruct.len buf < (sizeof_ipv4 + Cstruct.len t.options) then
      Result.Error "Not enough space for IPv4 header"
    else begin
      Result.Ok (unsafe_fill t buf)
    end

  let make_cstruct t =
    let nearest_4 n = match n mod 4 with
      | 0 -> n
      | k -> (4 - k) + n
    in
    let options_len = nearest_4 @@ Cstruct.len t.options in
    let buf = Cstruct.create (sizeof_ipv4 + options_len) in
    Cstruct.memset buf 0x00; (* should be removable in the future *)
    unsafe_fill t buf;
    buf
end
