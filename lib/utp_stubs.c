/* The MIT License (MIT)

   Copyright (c) 2015-2017 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

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

#define Utp_context_val(v) ((utp_context *) v)
#define Val_utp_context(c) ((value) c)
#define Utp_socket_val(v) ((utp_socket *) v)
#define Val_utp_socket(s) ((value) s)

static uint64 on_read (utp_callback_arguments* a)
{
  CAMLparam0 ();
  CAMLlocal1 (ba);
  static value *on_read_fun = NULL;

  if (on_read_fun == NULL) on_read_fun = caml_named_value ("utp_on_read");
  ba = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *) a->buf, a->len);
  caml_callback2 (*on_read_fun, Val_utp_socket (a->socket), ba);
  utp_read_drained (a->socket);
  CAMLreturn (0);
}

static uint64 on_state_change (utp_callback_arguments *a)
{
  CAMLparam0 ();
  value *cb;
  static value *on_connect_fun = NULL;
  static value *on_writable_fun = NULL;
  static value *on_eof_fun = NULL;
  static value *on_close_fun = NULL;

  if (on_connect_fun == NULL) on_connect_fun = caml_named_value ("utp_on_connect");
  if (on_writable_fun == NULL) on_writable_fun = caml_named_value ("utp_on_writable");
  if (on_eof_fun == NULL) on_eof_fun = caml_named_value ("utp_on_eof");
  if (on_close_fun == NULL) on_close_fun = caml_named_value ("utp_on_close");
  switch (a->state) {
    case UTP_STATE_CONNECT:
      cb = on_connect_fun;
      break;
    case UTP_STATE_WRITABLE:
      cb = on_writable_fun;
      break;
    case UTP_STATE_EOF:
      cb = on_eof_fun;
      break;
    case UTP_STATE_DESTROYING:
      UTP_DEBUG ("destroying socket");
      cb = on_close_fun;
      break;
    default:
      UTP_DEBUG ("unknown state change: %d", a->state);
      cb = NULL;
      break;
  }
  if (cb) caml_callback (*cb, Val_utp_socket (a->socket));
  CAMLreturn (0);
}

static uint64 on_sendto (utp_callback_arguments *a)
{
  CAMLparam0 ();
  CAMLlocal2 (addr, buf);
  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;
  static value *on_sendto_fun = NULL;

  if (on_sendto_fun == NULL) on_sendto_fun = caml_named_value ("utp_on_sendto");
  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy (&sock_addr.s_inet, (struct sockaddr_in *) a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);
  buf = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *) a->buf, a->len);
  caml_callback3 (*on_sendto_fun, Val_utp_context (a->context), addr, buf);
  CAMLreturn (0);
}

static uint64 on_error (utp_callback_arguments *a)
{
  CAMLparam0 ();
  static value *on_error_fun = NULL;

  if (on_error_fun == NULL) on_error_fun = caml_named_value ("utp_on_error");
  caml_callback2 (*on_error_fun, Val_utp_socket (a->socket), Val_int (a->error_code));
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
  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;
  static value *on_accept_fun = NULL;

  if (on_accept_fun == NULL) on_accept_fun = caml_named_value ("utp_on_accept");
  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy (&sock_addr.s_inet, (struct sockaddr_in *) a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);
  caml_callback3 (*on_accept_fun, Val_utp_context (a->context), Val_utp_socket (a->socket), addr);
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

CAMLprim value stub_utp_init (value unit)
{
  CAMLparam1 (unit);
  utp_context *context;

  context = utp_init (2);
  utp_set_callback (context, UTP_ON_READ, on_read);
  utp_set_callback (context, UTP_ON_STATE_CHANGE, on_state_change);
  utp_set_callback (context, UTP_SENDTO, on_sendto);
  utp_set_callback (context, UTP_LOG, on_log);
  utp_set_callback (context, UTP_ON_ERROR, on_error);
  utp_set_callback (context, UTP_ON_ACCEPT, on_accept);
  utp_set_callback (context, UTP_ON_FIREWALL, on_firewall);
  CAMLreturn (Val_utp_context (context));
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

CAMLprim value stub_utp_create_socket (value ctx)
{
  CAMLparam1 (ctx);
  CAMLlocal1 (val);
  utp_socket *socket;

  socket = utp_create_socket (Utp_context_val (ctx));
  if (socket == NULL) caml_failwith ("utp_create_socket");
  CAMLreturn (Val_utp_socket (socket));
}

CAMLprim value stub_utp_connect (value sock, value addr)
{
  CAMLparam2 (sock, addr);
  union sock_addr_union sock_addr;
  socklen_param_type addr_len;
  int res;

  get_sockaddr (addr, &sock_addr, &addr_len);
  res = utp_connect (Utp_socket_val (sock), &sock_addr.s_gen, addr_len);
  if (res < 0) caml_failwith ("utp_connect");
  CAMLreturn (Val_unit);
}

CAMLprim value stub_utp_write (value socket, value buf, value off, value len)
{
  CAMLparam4(socket, buf, off, len);
  ssize_t written;

  written = utp_write (Utp_socket_val (socket), Caml_ba_data_val(buf) + Int_val(off), Int_val(len));
  if (written < 0) caml_failwith ("utp_write");
  CAMLreturn (Val_int (written));
}

CAMLprim value stub_utp_set_debug (value context, value v)
{
  CAMLparam2 (context, v);

  utp_context_set_option (Utp_context_val (context), UTP_LOG_DEBUG, Bool_val (v));
  CAMLreturn (Val_unit);
}

CAMLprim value stub_utp_get_context (value v)
{
  CAMLparam1 (v);
  utp_context *c;

  c = utp_get_context (Utp_socket_val (v));
  CAMLreturn (Val_utp_context (c));
}

CAMLprim value stub_utp_destroy (value v)
{
  CAMLparam1 (v);

  UTP_DEBUG ("stub_utp_destroy");
  utp_destroy (Utp_context_val (v));
  CAMLreturn (Val_unit);
}
