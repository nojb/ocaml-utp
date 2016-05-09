/* The MIT License (MIT)

   Copyright (c) 2015-2016 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   SOFTWARE. */

#include <assert.h>
#include <string.h>
#include <stdio.h>

#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/bigarray.h>
#include <caml/fail.h>
#include <caml/custom.h>
#include <caml/socketaddr.h>
#include <caml/unixsupport.h>

#include "utp.h"

#define UTP_DEBUG(msg, ...) \
  do { \
    fprintf (stderr, "[UTP DEBUG] "); \
    fprintf (stderr, (msg), ##__VA_ARGS__); \
    fprintf (stderr, "\n"); \
  } while (0);

typedef struct {
  utp_context *context;
  int finalized;
  int sockets;
  value on_sendto;
  value on_accept;
} utp_context_userdata;

typedef struct {
  utp_socket *socket;
  int destroyed;
  int finalized;
  value on_error;
  value on_read;
  value on_connect;
  value on_writable;
  value on_eof;
  value on_close;
} utp_userdata;

#define Utp_context_val(v) (*(utp_context **) (Data_custom_val (v)))

static void free_utp_context_userdata (utp_context_userdata *u)
{
  if (u->on_sendto) {
    caml_remove_generational_global_root (&(u->on_sendto));
  }
  if (u->on_accept) {
    caml_remove_generational_global_root (&(u->on_accept));
  }
  free (u);
}

static void finalize_utp_context (value v)
{
  utp_context_userdata *u;
  u = utp_context_get_userdata (Utp_context_val (v));
  if (u->sockets == 0) {
    utp_destroy (Utp_context_val (v));
    free_utp_context_userdata (u);
  } else {
    u->finalized = 1;
  }
}

static struct custom_operations utp_context_custom_ops = {
  .identifier = "utp context",
  .finalize = finalize_utp_context,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default
};

static value alloc_utp_context (utp_context *context)
{
    CAMLparam0();
    CAMLlocal1(v);
    v = caml_alloc_custom (&utp_context_custom_ops, sizeof (utp_context *), 0, 1);
    Utp_context_val (v) = context;
    CAMLreturn(v);
}

#define Utp_socket_val(v) (*(utp_socket **) (Data_custom_val (v)))

static void free_utp_userdata (utp_userdata *u)
{
  if (u->on_error) {
    caml_remove_generational_global_root (&(u->on_error));
  }
  if (u->on_read) {
    caml_remove_generational_global_root (&(u->on_read));
  }
  if (u->on_connect) {
    caml_remove_generational_global_root (&(u->on_connect));
  }
  if (u->on_writable) {
    caml_remove_generational_global_root (&(u->on_writable));
  }
  if (u->on_eof) {
    caml_remove_generational_global_root (&(u->on_eof));
  }
  if (u->on_close) {
    caml_remove_generational_global_root (&(u->on_close));
  }
  free (u);
}

static void finalize_utp_socket (value v)
{
  utp_userdata *u;
  u = utp_get_userdata (Utp_socket_val (v));
  if (u->destroyed) {
    free_utp_userdata (u);
  } else {
    u->finalized = 1;
  }
}

static struct custom_operations utp_socket_custom_ops = {
  .identifier = "utp socket",
  .finalize = finalize_utp_socket,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default
};

static value alloc_utp_socket (utp_socket *socket)
{
    CAMLparam0();
    CAMLlocal1(v);

    v = caml_alloc_custom (&utp_socket_custom_ops, sizeof (utp_socket *), 0, 1);
    Utp_socket_val (v) = socket;

    CAMLreturn(v);
}

static uint64 on_read (utp_callback_arguments* a)
{
  CAMLparam0 ();
  CAMLlocal1 (ba);

  utp_userdata *u;

  ba = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *) a->buf, a->len);
  u = utp_get_userdata (a->socket);

  if (u->on_read) {
    caml_callback (u->on_read, ba);
  }

  utp_read_drained (a->socket);

  CAMLreturn (0);
}

static uint64 on_state_change (utp_callback_arguments *a)
{
  utp_context_userdata *cu;
  utp_userdata *u;
  value cb = 0;

  cu = utp_context_get_userdata (a->context);
  u = utp_get_userdata (a->socket);

  switch (a->state) {
    case UTP_STATE_CONNECT:
      cb = u->on_connect;
      break;
    case UTP_STATE_WRITABLE:
      cb = u->on_writable;
      break;
    case UTP_STATE_EOF:
      cb = u->on_eof;
      break;
    case UTP_STATE_DESTROYING:
      if (u->finalized) {
        free_utp_userdata (u);
      } else {
        u->destroyed = 1;
      }
      cu->sockets --;
      if (cu->sockets == 0 && cu->finalized) {
        utp_destroy (a->context);
        free_utp_context_userdata (cu);
      }
      cb = u->on_close;
      break;
    default:
      UTP_DEBUG ("unknown state change: %d", a->state);
      break;
  }

  if (cb) {
    caml_callback (cb, Val_unit);
  }

  return 0;
}

static uint64 on_error (utp_callback_arguments *a)
{
  utp_userdata *u;
  int i;

  switch (a->error_code) {
    case UTP_ECONNREFUSED:
      i = 0;
      break;
    case UTP_ECONNRESET:
      i = 1;
      break;
    case UTP_ETIMEDOUT:
      i = 2;
      break;
  }

  u = utp_get_userdata (a->socket);

  if (u->on_error) {
    caml_callback(u->on_error, Val_int(i));
  }

  return 0;
}

static uint64 on_sendto (utp_callback_arguments *a)
{
  CAMLparam0 ();
  CAMLlocal2 (addr, buf);

  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;
  utp_context_userdata *u;

  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy (&sock_addr.s_inet, (struct sockaddr_in *) a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);
  buf = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *) a->buf, a->len);
  u = utp_context_get_userdata (a->context);

  if (u->on_sendto) {
    caml_callback2 (u->on_sendto, addr, buf);
  }

  CAMLreturn (0);
}

static uint64 on_log (utp_callback_arguments *a)
{
  UTP_DEBUG ("%s", a->buf);
  return 0;
}

static uint64 on_accept (utp_callback_arguments *a)
{
  CAMLparam0 ();
  CAMLlocal2 (addr, val);

  utp_context_userdata *u;
  utp_userdata *su;
  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;

  u = utp_context_get_userdata (a->context);

  if (u->on_accept) {
    sock_addr_len = sizeof (struct sockaddr_in);
    memcpy (&sock_addr.s_inet, (struct sockaddr_in *) a->address, sock_addr_len);
    addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);

    su = calloc (1, sizeof (utp_userdata));

    if (!su) {
      caml_fatal_error ("on_accept: out of memory");
    }

    su->socket = a->socket;
    su->destroyed = 0;
    su->finalized = 0;
    utp_set_userdata (a->socket, su);
    u->sockets ++;
    val = alloc_utp_socket (a->socket);
    caml_callback2 (u->on_accept, val, addr);
  }

  CAMLreturn (0);
}

static uint64 on_firewall (utp_callback_arguments *a)
{
  return 0;
}

CAMLprim value stub_utp_close (value socket)
{
  CAMLparam1 (socket);

  utp_close (Utp_socket_val (socket));

  CAMLreturn (Val_unit);
}

CAMLprim value stub_utp_set_callback (value ctx, value cbnum, value fun)
{
  CAMLparam3 (ctx, cbnum, fun);

  utp_context_userdata *u;
  value *cb;

  u = utp_context_get_userdata (Utp_context_val (ctx));

  switch (Int_val(cbnum)) {
    case 0:
      cb = &(u->on_sendto);
      break;
    case 1:
      cb = &(u->on_accept);
      break;
  }

  if (*cb) {
    caml_modify_generational_global_root (cb, fun);
  } else {
    *cb = fun;
    caml_register_generational_global_root (cb);
  }

  CAMLreturn (Val_unit);
}

CAMLprim value stub_socket_set_callback (value sock, value cbnum, value fun)
{
  CAMLparam3 (sock, cbnum, fun);

  utp_userdata *u;
  value *cb;

  u = utp_get_userdata (Utp_socket_val (sock));

  switch (Int_val(cbnum)) {
    case 0:
      cb = &(u->on_error);
      break;
    case 1:
      cb = &(u->on_read);
      break;
    case 2:
      cb = &(u->on_connect);
      break;
    case 3:
      cb = &(u->on_writable);
      break;
    case 4:
      cb = &(u->on_eof);
      break;
    case 5:
      cb = &(u->on_close);
      break;
  }

  if (*cb) {
    caml_modify_generational_global_root (cb, fun);
  } else {
    *cb = fun;
    caml_register_generational_global_root (cb);
  }

  CAMLreturn (Val_unit);
}

CAMLprim value stub_utp_init (value unit)
{
  CAMLparam1 (unit);
  CAMLlocal1 (val);

  utp_context *context;
  utp_context_userdata *u;

  context = utp_init (2);
  u = calloc (1, sizeof (utp_context_userdata));

  if (!u) {
    caml_fatal_error ("stub_utp_init: out of memory");
  }

  u->sockets = 0;
  u->context = context;
  u->finalized = 0;

  utp_context_set_userdata (context, u);

  utp_set_callback (context, UTP_ON_READ, on_read);
  utp_set_callback (context, UTP_ON_STATE_CHANGE, on_state_change);
  utp_set_callback (context, UTP_SENDTO, on_sendto);
  utp_set_callback (context, UTP_LOG, on_log);
  utp_set_callback (context, UTP_ON_ERROR, on_error);
  utp_set_callback (context, UTP_ON_ACCEPT, on_accept);
  utp_set_callback (context, UTP_ON_FIREWALL, on_firewall);

  val = alloc_utp_context (context);

  CAMLreturn (val);
}

CAMLprim value stub_utp_process_udp (value context, value addr, value buf, value off, value len)
{
  CAMLparam5 (context, addr, buf, off, len);

  union sock_addr_union sock_addr;
  socklen_param_type addr_len;
  int handled;

  get_sockaddr (addr, &sock_addr, &addr_len);
  handled = utp_process_udp (Utp_context_val (context), Caml_ba_data_val (buf) + Int_val (off), Int_val (len), &sock_addr.s_gen, addr_len);

  CAMLreturn (Val_bool (handled));
}

CAMLprim value stub_utp_issue_deferred_acks (value context)
{
  CAMLparam1 (context);

  utp_issue_deferred_acks (Utp_context_val (context));

  CAMLreturn (Val_unit);
}

CAMLprim value stub_utp_check_timeouts (value context)
{
  CAMLparam1 (context);

  utp_check_timeouts (Utp_context_val (context));

  CAMLreturn (Val_unit);
}

CAMLprim value stub_utp_destroy (value ctx)
{
  CAMLparam1 (ctx);

  utp_destroy (Utp_context_val (ctx));

  CAMLreturn (Val_unit);
}

CAMLprim value stub_utp_create_socket (value ctx)
{
  CAMLparam1 (ctx);
  CAMLlocal1 (val);

  utp_socket *socket;
  utp_userdata *u;
  utp_context_userdata *su;

  socket = utp_create_socket (Utp_context_val (ctx));

  if (!socket) {
    caml_failwith ("utp_create_socket");
  }

  u = calloc (1, sizeof (utp_userdata));

  if (!u) {
    caml_fatal_error ("stub_utp_create_socket: out of memory");
  }

  u->socket = socket;
  u->destroyed = 0;
  u->finalized = 0;
  utp_set_userdata (socket, u);

  su = utp_context_get_userdata (Utp_context_val (ctx));
  su->sockets ++;

  val = alloc_utp_socket (socket);

  CAMLreturn (val);
}

CAMLprim value stub_utp_connect (value sock, value addr)
{
  CAMLparam2 (sock, addr);

  union sock_addr_union sock_addr;
  socklen_param_type addr_len;
  int res;

  get_sockaddr (addr, &sock_addr, &addr_len);

  res = utp_connect (Utp_socket_val (sock), &sock_addr.s_gen, addr_len);

  if (res < 0) {
    caml_failwith ("utp_connect");
  }

  CAMLreturn (Val_unit);
}

CAMLprim value stub_utp_write (value socket, value buf, value off, value len)
{
  CAMLparam4(socket, buf, off, len);

  ssize_t written;

  written = utp_write (Utp_socket_val (socket), Caml_ba_data_val(buf) + Int_val(off), Int_val(len));

  if (written < 0) {
    caml_failwith ("utp_write");
  }

  CAMLreturn (Val_int (written));
}

CAMLprim value stub_utp_set_debug (value context, value v)
{
  CAMLparam2 (context, v);

  utp_context_set_option (Utp_context_val (context), UTP_LOG_DEBUG, Bool_val (v));

  CAMLreturn (Val_unit);
}

CAMLprim value stub_utp_getpeername (value sock)
{
  CAMLparam1 (sock);
  CAMLlocal1 (addr);

  int res;
  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;

  res = utp_getpeername (Utp_socket_val (sock), &sock_addr.s_gen, &sock_addr_len);

  if (res < 0) {
    caml_failwith ("utp_getpeername");
  }

  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);

  CAMLreturn (addr);
}
