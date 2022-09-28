(*
 * Copyright (C) 2005-2008 Jérôme Vouillon
 * Laboratoire PPS - CNRS Université Paris Diderot
 * Copyright (C) 2022 Antonio Nuno Monteiro
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)

module Exn = struct
  exception Retry_read
  exception Retry_write
  exception Too_many_polls

  exception
    Ssl_exception of
      { ssl_error : Ssl.ssl_error
      ; message : string
      }
end

module Unix_fd = struct
  let get_exn (fd : Eio.Net.stream_socket) =
    Option.get (Eio_unix.FD.peek_opt fd)
end

let wrap_call ~f () =
  try f () with
  | ( Ssl.Connection_error err
    | Ssl.Accept_error err
    | Ssl.Read_error err
    | Ssl.Write_error err ) as e ->
    (match err with
    | Ssl.Error_want_read -> raise_notrace Exn.Retry_read
    | Ssl.Error_want_write -> raise_notrace Exn.Retry_write
    | Ssl.Error_syscall | Ssl.Error_ssl ->
      raise
        (Exn.Ssl_exception
           { ssl_error = err; message = Ssl.get_error_string () })
    | _ -> raise e)

let repeat_call ~f fd =
  let rec inner polls_remaining fd f =
    if polls_remaining <= 0
    then raise Exn.Too_many_polls
    else
      try wrap_call ~f () with
      | Exn.Retry_read ->
        Eio_unix.await_readable (Unix_fd.get_exn fd);
        inner (polls_remaining - 1) fd f
      | Exn.Retry_write ->
        Eio_unix.await_writable (Unix_fd.get_exn fd);
        inner (polls_remaining - 1) fd f
      | e -> raise e
  in
  inner 64 fd f

(**)

module Raw = struct
  type t =
    { flow : Eio.Flow.two_way
    ; ctx : Ssl.context
    ; ssl_socket : Ssl.socket
    ; mutable state : [ `Uninitialized | `Connected | `Shutdown ]
    }

  let read { flow; state; ssl_socket; _ } buf =
    match state with
    | `Uninitialized | `Shutdown -> Eio.Flow.read flow buf
    | `Connected ->
      if buf.len = 0
      then 0
      else
        repeat_call flow ~f:(fun () ->
            match
              Ssl.read_into_bigarray ssl_socket buf.buffer buf.off buf.len
            with
            | n -> n
            | exception Ssl.Read_error Ssl.Error_zero_return -> 0)

  let writev { flow; ssl_socket; _ } bufs =
    let rec do_write buf ~off ~len =
      match
        repeat_call flow ~f:(fun () ->
            Ssl.write_bigarray ssl_socket buf off len)
      with
      | n when n < len -> n + do_write buf ~off:(off + n) ~len:(len - n)
      | n -> n
      | exception Ssl.Write_error Ssl.Error_zero_return -> 0
    in

    if Cstruct.lenv bufs = 0
    then 0
    else
      List.fold_left
        (fun acc (buf : Cstruct.t) ->
          acc + do_write buf.buffer ~off:buf.off ~len:buf.len)
        0
        bufs

  let copy t src =
    let do_rsb rsb =
      try
        while true do
          rsb (writev t)
        done
      with
      | End_of_file -> ()
    in
    match Eio.Flow.read_methods src with
    | Eio.Flow.Read_source_buffer rsb :: _
    | _ :: Eio.Flow.Read_source_buffer rsb :: _ ->
      do_rsb rsb
    | xs ->
      (match
         List.find_map
           (function Eio.Flow.Read_source_buffer rsb -> Some rsb | _ -> None)
           xs
       with
      | Some rsb -> do_rsb rsb
      | None ->
        (try
           while true do
             let buf = Cstruct.create 4096 in
             let got = Eio.Flow.read src buf in
             ignore (writev t [ Cstruct.sub buf 0 got ] : int)
           done
         with
        | End_of_file -> ()))

  let shutdown t cmd =
    match cmd with
    | `Receive -> ()
    | `Send | `All ->
      (match t.state with
      | `Uninitialized | `Shutdown -> ()
      | `Connected -> if Ssl.close_notify t.ssl_socket then t.state <- `Shutdown)
end

module Context = struct
  include Raw

  let create ~ctx flow =
    let flow = (flow :> Eio.Flow.two_way) in
    let ssl_socket = Ssl.embed_socket (Unix_fd.get_exn flow) ctx in
    { flow; ctx; ssl_socket; state = `Uninitialized }

  let get_fd t = t.flow

  let get_unix_fd t =
    match t.state with
    | `Uninitialized | `Shutdown -> Unix_fd.get_exn t.flow
    | `Connected -> Ssl.file_descr_of_socket t.ssl_socket

  let ssl_socket t = t.ssl_socket
end

type t = < Eio.Flow.two_way ; t : Raw.t >

let of_t t =
  object
    inherit Eio.Flow.two_way
    method read_into = Raw.read t
    method copy = Raw.copy t
    method shutdown = Raw.shutdown t
    method t = t
  end

let accept (t : Raw.t) =
  assert (t.state = `Uninitialized);
  repeat_call t.flow ~f:(fun () -> Ssl.accept t.ssl_socket);
  of_t { t with state = `Connected }

let connect (t : Raw.t) =
  assert (t.state = `Uninitialized);
  repeat_call t.flow ~f:(fun () -> Ssl.connect t.ssl_socket);
  of_t { t with state = `Connected }

let ssl_socket t = Context.ssl_socket t#t
