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

type t =
  | Plain
  | SSL of Ssl.socket

type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

type socket = Eio.Net.stream_socket * t
type uninitialized_socket = Eio.Net.stream_socket * Ssl.socket

let ssl_socket (_fd, kind) =
  match kind with Plain -> None | SSL socket -> Some socket

let ssl_socket_of_uninitialized_socket (_fd, socket) = socket
let is_ssl s = match snd s with Plain -> false | SSL _ -> true

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

let wrap_call_async ~f () =
  let p, u = Eio.Promise.create () in
  let _t : Thread.t =
    Thread.create
      (fun () ->
        match wrap_call ~f () with
        | r -> Eio.Promise.resolve_ok u r
        | exception exn -> Eio.Promise.resolve_error u exn)
      ()
  in
  match Eio.Promise.await p with Ok r -> r | Error exn -> raise exn

let unix_fd_exn (fd : Eio.Net.stream_socket) =
  Option.get (Eio_unix.FD.peek_opt fd)

let repeat_call ~f fd =
  let rec inner polls_remaining fd f =
    if polls_remaining <= 0
    then raise Exn.Too_many_polls
    else
      try wrap_call_async ~f () with
      | Exn.Retry_read ->
        Eio_unix.await_readable (unix_fd_exn fd);
        inner (polls_remaining - 1) fd f
      | Exn.Retry_write ->
        Eio_unix.await_writable (unix_fd_exn fd);
        inner (polls_remaining - 1) fd f
      | e -> raise e
  in
  inner 64 fd f

(**)

let plain fd = fd, Plain

let embed_socket fd context =
  fd, SSL (Ssl.embed_socket (unix_fd_exn fd) context)

let embed_uninitialized_socket fd context =
  fd, Ssl.embed_socket (unix_fd_exn fd) context

let ssl_accept fd ctx =
  let socket = Ssl.embed_socket (unix_fd_exn fd) ctx in
  repeat_call fd ~f:(fun () -> Ssl.accept socket);
  fd, SSL socket

let ssl_connect fd ctx =
  let socket = Ssl.embed_socket (unix_fd_exn fd) ctx in
  repeat_call fd ~f:(fun () -> Ssl.connect socket);
  fd, SSL socket

let ssl_accept_handshake (fd, socket) =
  repeat_call fd ~f:(fun () -> Ssl.accept socket);
  fd, SSL socket

let ssl_perform_handshake (fd, socket) =
  repeat_call fd ~f:(fun () -> Ssl.connect socket);
  fd, SSL socket

let read ((fd, s) : socket) ~off ~len buf =
  match s with
  | Plain -> Eio.Flow.read fd (Cstruct.of_bigarray buf ~off ~len)
  | SSL s ->
    if len = 0
    then 0
    else
      repeat_call fd ~f:(fun () ->
          match Ssl.read_into_bigarray s buf off len with
          | n -> n
          | exception Ssl.Read_error Ssl.Error_zero_return -> 0)

let write_string ((fd, s) : socket) str =
  let len = String.length str in
  match s with
  | Plain ->
    Eio.Flow.copy_string str fd;
    len
  | SSL s ->
    if String.length str = 0
    then 0
    else
      repeat_call fd ~f:(fun () ->
          match Ssl.write s (Bytes.unsafe_of_string str) 0 len with
          | n -> n
          | exception Ssl.Write_error Ssl.Error_zero_return -> 0)

let write (fd, s) ~off ~len buf =
  match s with
  | Plain ->
    Eio.Flow.copy
      (Eio.Flow.cstruct_source [ Cstruct.of_bigarray ~off ~len buf ])
      fd;
    len
  | SSL s ->
    if len = 0
    then 0
    else
      repeat_call fd ~f:(fun () ->
          match Ssl.write_bigarray s buf off len with
          | n -> n
          | exception Ssl.Write_error Ssl.Error_zero_return -> 0)

let ssl_shutdown (fd, s) =
  match s with
  | Plain -> ()
  | SSL s -> repeat_call fd ~f:(fun () -> Ssl.shutdown s)

let shutdown (fd, _) cmd = Eio.Flow.shutdown fd cmd

let shutdown_and_close s =
  let () = ssl_shutdown s in
  shutdown s `All

let get_fd (fd, _socket) = fd

let get_unix_fd (fd, socket) =
  match socket with
  | Plain -> unix_fd_exn fd
  | SSL socket -> Ssl.file_descr_of_socket socket

let getsockname s = Unix.getsockname (get_unix_fd s)
let getpeername s = Unix.getpeername (get_unix_fd s)
