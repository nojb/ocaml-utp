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

static intnat last_num = 0;

typedef struct {
  intnat num;
  int finalized;
  int sockets;
  value val;
} utp_context_userdata;

typedef struct {
  intnat num;
  value val;
  int closed;
} utp_userdata;

#define Utp_context_val(v) (*(utp_context **) (Data_custom_val (v)))

static void finalize_utp_context (value v)
{
  utp_context_userdata *u;
  u = utp_context_get_userdata (Utp_context_val (v));
  UTP_DEBUG ("finalize_utp_context (%ld)", u->num);
  if (u->sockets == 0) {
    utp_destroy (Utp_context_val (v));
    free (u);
  } else {
    u->finalized = 1;
  }
}

static intnat hash_utp_context (value v)
{
  utp_context_userdata *u;
  u = utp_context_get_userdata (Utp_context_val (v));
  return u->num;
}

static struct custom_operations utp_context_custom_ops = {
  .identifier = "utp context",
  .finalize = finalize_utp_context,
  .compare = custom_compare_default,
  .hash = hash_utp_context,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default
};

static value alloc_utp_context (utp_context *context)
{
  CAMLparam0 ();
  CAMLlocal1 (v);
  v = caml_alloc_custom (&utp_context_custom_ops, sizeof (utp_context *), 0, 1);
  Utp_context_val (v) = context;
  CAMLreturn (v);
}

#define Utp_socket_val(v) (*(utp_socket **) (Data_custom_val (v)))

static void finalize_utp_socket (value v)
{
  utp_userdata *u;
  u = utp_get_userdata (Utp_socket_val (v));
  UTP_DEBUG ("finalize_utp_socket (%ld)", u->num);
  free (u);
}

static int compare_utp_socket (value v1, value v2)
{
  utp_userdata *u1, *u2;
  u1 = utp_get_userdata (Utp_socket_val (v1));
  u2 = utp_get_userdata (Utp_socket_val (v2));
  if (u1->num < u2->num) {
    return -1;
  }
  if (u1->num > u2->num) {
    return 1;
  }
  return 0;
}

static intnat hash_utp_socket (value v)
{
  utp_userdata *u;
  u = utp_get_userdata (Utp_socket_val (v));
  return u->num;
}

static struct custom_operations utp_socket_custom_ops = {
  .identifier = "utp socket",
  .finalize = finalize_utp_socket,
  .compare = compare_utp_socket,
  .hash = hash_utp_socket,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default
};

static value alloc_utp_socket (utp_socket *socket)
{
  CAMLparam0 ();
  CAMLlocal1 (v);
  v = caml_alloc_custom (&utp_socket_custom_ops, sizeof (utp_socket *), 0, 1);
  Utp_socket_val (v) = socket;
  CAMLreturn (v);
}

static uint64 on_read (utp_callback_arguments* a)
{
  CAMLparam0 ();
  CAMLlocal1 (ba);
  utp_userdata *u;
  static value *on_read_fun = NULL;

  if (on_read_fun == NULL) {
    on_read_fun = caml_named_value ("utp_on_read");
  }

  u = utp_get_userdata (a->socket);

  if (u->val) {
    ba = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *) a->buf, a->len);
    caml_callback2 (*on_read_fun, u->val, ba);
  }

  utp_read_drained (a->socket);

  CAMLreturn (0);
}

static uint64 on_state_change (utp_callback_arguments *a)
{
  CAMLparam0 ();
  utp_context_userdata *cu;
  utp_userdata *u;
  static value *on_connect_fun = NULL;
  static value *on_writable_fun = NULL;
  static value *on_eof_fun = NULL;
  static value *on_close_fun = NULL;
  value *cb;

  if (on_connect_fun == NULL) {
    on_connect_fun = caml_named_value ("utp_on_connect");
  }

  if (on_writable_fun == NULL) {
    on_writable_fun = caml_named_value ("utp_on_writable");
  }

  if (on_eof_fun == NULL) {
    on_eof_fun = caml_named_value ("utp_on_eof");
  }

  if (on_close_fun == NULL) {
    on_close_fun = caml_named_value ("utp_on_close");
  }

  cu = utp_context_get_userdata (a->context);
  u = utp_get_userdata (a->socket);

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
      caml_remove_generational_global_root (&(u->val));
      cb = on_close_fun;
      break;
    default:
      UTP_DEBUG ("unknown state change: %d", a->state);
      cb = NULL;
      break;
  }

  if (u->val && cb) {
    caml_callback (*cb, u->val);
    if (a->state == UTP_STATE_DESTROYING) {
      u->val = 0;
      cu->sockets --;
      if (cu->sockets == 0 && cu->finalized) {
        utp_destroy (a->context);
        free (cu);
      }
    }
  }

  CAMLreturn (0);
}

static uint64 on_sendto (utp_callback_arguments *a)
{
  CAMLparam0 ();
  CAMLlocal2 (addr, buf);
  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;
  utp_context_userdata *u;
  static value *on_sendto_fun = NULL;

  if (on_sendto_fun == NULL) {
    on_sendto_fun = caml_named_value ("utp_on_sendto");
  }

  u = utp_context_get_userdata (a->context);
  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy (&sock_addr.s_inet, (struct sockaddr_in *) a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);
  buf = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *) a->buf, a->len);
  caml_callback3 (*on_sendto_fun, u->val, addr, buf);

  CAMLreturn (0);
}

static uint64 on_error (utp_callback_arguments *a)
{
  CAMLparam0 ();
  utp_userdata *u;
  static value *on_error_fun = NULL;

  if (on_error_fun == NULL) {
    on_error_fun = caml_named_value ("utp_on_error");
  }

  u = utp_get_userdata (a->socket);

  if (u->val) {
    caml_callback2 (*on_error_fun, u->val, Val_int (a->error_code));
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
  static value *on_accept_fun = NULL;

  if (on_accept_fun == NULL) {
    on_accept_fun = caml_named_value ("utp_on_accept");
  }

  u = utp_context_get_userdata (a->context);
  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy (&sock_addr.s_inet, (struct sockaddr_in *) a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);
  su = caml_stat_alloc (sizeof (utp_userdata));
  su->num = last_num ++;
  su->val = alloc_utp_socket (a->socket);
  su->closed = 0;
  caml_register_generational_global_root (&(su->val));
  utp_set_userdata (a->socket, su);
  u->sockets ++;
  caml_callback3 (*on_accept_fun, u->val, su->val, addr);

  CAMLreturn (0);
}

static uint64 on_firewall (utp_callback_arguments *a)
{
  return 0;
}

CAMLprim value stub_utp_close (value socket)
{
  CAMLparam1 (socket);
  utp_userdata *u;
  u = utp_get_userdata (Utp_socket_val (socket));
  if (u->closed == 0) {
    utp_close (Utp_socket_val (socket));
    u->closed = 1;
  }
  CAMLreturn (Val_unit);
}

CAMLprim value stub_utp_init (value unit)
{
  CAMLparam1 (unit);
  utp_context *context;
  utp_context_userdata *u;

  context = utp_init (2);
  u = caml_stat_alloc (sizeof (utp_context_userdata));
  u->finalized = 0;
  u->sockets = 0;
  u->num = last_num ++;
  u->val = alloc_utp_context (context);
  caml_register_generational_global_root (&(u->val));
  utp_context_set_userdata (context, u);
  utp_set_callback (context, UTP_ON_READ, on_read);
  utp_set_callback (context, UTP_ON_STATE_CHANGE, on_state_change);
  utp_set_callback (context, UTP_SENDTO, on_sendto);
  utp_set_callback (context, UTP_LOG, on_log);
  utp_set_callback (context, UTP_ON_ERROR, on_error);
  utp_set_callback (context, UTP_ON_ACCEPT, on_accept);
  utp_set_callback (context, UTP_ON_FIREWALL, on_firewall);

  CAMLreturn (u->val);
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
  utp_userdata *u;
  utp_context_userdata *su;

  socket = utp_create_socket (Utp_context_val (ctx));

  if (!socket) {
    caml_failwith ("utp_create_socket");
  }

  u = caml_stat_alloc (sizeof (utp_userdata));
  u->num = last_num ++;
  u->val = alloc_utp_socket (socket);
  u->closed = 0;
  caml_register_generational_global_root (&(u->val));
  utp_set_userdata (socket, u);
  su = utp_context_get_userdata (Utp_context_val (ctx));
  su->sockets ++;

  CAMLreturn (u->val);
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

CAMLprim value stub_utp_get_id (value v)
{
  CAMLparam1 (v);
  utp_userdata *u;
  u = utp_get_userdata (Utp_socket_val (v));
  CAMLreturn (Val_int (u->num));
}
