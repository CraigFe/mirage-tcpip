(*
 * Copyright (c) 2014 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

type t = unit
type error = Mirage_protocols.Ip.error
type ipaddr = Ipaddr.V4.t
type callback = src:ipaddr -> dst:ipaddr -> Cstruct.t -> unit Lwt.t

let pp_error = Mirage_protocols.Ip.pp_error
let pp_ipaddr = Ipaddr.V4.pp

let mtu _ ~dst:_ = 1500 - Ipv4_wire.sizeof_ipv4

let disconnect _ = Lwt.return_unit
let connect _ = Lwt.return_unit

let input _ ~tcp:_ ~udp:_ ~default:_ _ = Lwt.return_unit
let write _ ?fragment:_ ?ttl:_ ?src:_ _ _ ?size:_ _ _ =
  Lwt.fail (Failure "Not implemented")

let get_ip _ = [Ipaddr.V4.any]
let src _ ~dst:_ = raise (Failure "Not implemented")
let pseudoheader _ ?src:_ _ _ _ = raise (Failure "Not implemented")
