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
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

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

#define UTP_BUFFER_SIZE 65536

typedef struct {
  utp_context *context;
  int fd;
  int sockets;
  void *buffer;
  value on_error;
  value on_sendto;
  value on_accept;
  value on_message;
} utp_context_userdata;

typedef struct {
  utp_socket *socket;
  value on_error;
  value on_read;
  value on_connect;
  value on_writable;
  value on_eof;
  value on_close;
} utp_userdata;

static struct custom_operations utp_context_custom_ops = {
  .identifier = "utp context",
  .finalize = custom_finalize_default,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default
};

#define Utp_context_val(v) (*(utp_context **) (Data_custom_val (v)))

static value alloc_utp_context (utp_context *context)
{
    CAMLparam0();
    CAMLlocal1(v);
    v = caml_alloc_custom (&utp_context_custom_ops, sizeof (utp_context *), 0, 1);
    Utp_context_val (v) = context;
    CAMLreturn(v);
}

static struct custom_operations utp_socket_custom_ops = {
  .identifier = "utp socket",
  .finalize = custom_finalize_default,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default
};

#define Utp_socket_val(v) (*(utp_socket **) (Data_custom_val (v)))

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
      cu->sockets --;
      cb = u->on_close;
      break;
    default:
      UTP_DEBUG ("unknown state change");
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

  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy (&sock_addr.s_inet, (struct sockaddr_in *) a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);

  if (!addr) {
    caml_failwith ("on_accept: alloc_sockaddr");
  }

  su = calloc (1, sizeof (utp_userdata));
  su->socket = a->socket;
  utp_set_userdata (a->socket, su);

  u = utp_context_get_userdata (a->context);

  if (u->on_accept) {
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

CAMLprim value caml_utp_close (value socket)
{
  CAMLparam1 (socket);

  utp_close (Utp_socket_val (socket));

  CAMLreturn (Val_unit);
}

CAMLprim value caml_utp_set_callback (value ctx, value cbnum, value fun)
{
  CAMLparam3 (ctx, cbnum, fun);

  utp_context_userdata *u;
  value *cb;

  u = utp_context_get_userdata (Utp_context_val (ctx));

  switch (Int_val(cbnum)) {
    case 0:
      cb = &(u->on_error);
      break;
    case 1:
      cb = &(u->on_sendto);
      break;
    case 2:
      cb = &(u->on_accept);
      break;
    case 3:
      cb = &(u->on_message);
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

CAMLprim value caml_socket_set_callback (value sock, value cbnum, value fun)
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

CAMLprim value caml_utp_init (value version)
{
  CAMLparam1 (version);
  CAMLlocal1 (val);

  utp_context *context;
  utp_context_userdata *u;

  context = utp_init (Int_val (version));
  u = calloc (1, sizeof (utp_context_userdata));

  u->sockets = 0;
  u->context = context;
  u->fd = socket (PF_INET, SOCK_DGRAM, 0);
  u->buffer = malloc (UTP_BUFFER_SIZE);

  if (!(u->buffer)) {
    caml_failwith ("caml_utp_init: malloc");
  }

  if (fcntl (u->fd, F_SETFL, O_NONBLOCK, 1) < 0) {
    caml_failwith ("caml_utp_init: fcntl");
  }

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

CAMLprim value caml_utp_file_descr (value ctx)
{
  CAMLparam1 (ctx);

  utp_context_userdata *u;

  u = utp_context_get_userdata (Utp_context_val (ctx));

  CAMLreturn (Val_int (u->fd));
}

CAMLprim value caml_utp_readable (value context)
{
  CAMLparam1(context);
  CAMLlocal2(buf, sa);

  union sock_addr_union addr;
  socklen_param_type addr_len;
  utp_context_userdata *u;
  ssize_t nread;
  bool handled;

  addr_len = sizeof (struct sockaddr_in);
  u = utp_context_get_userdata (Utp_context_val (context));

  while (1) {
    nread = recvfrom (u->fd, u->buffer, UTP_BUFFER_SIZE, 0, &addr.s_gen, &addr_len);

    if (nread < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        nread = 0;
      } else {
        UTP_DEBUG ("context error");
        if (u->on_error) {
          caml_callback (u->on_error, Val_unit);
        }
        break;
      }
    }

    if (nread == 0) {
      /* UTP_DEBUG ("issuing deferred acks"); */
      utp_issue_deferred_acks (Utp_context_val (context));
      break;
    }

    handled = utp_process_udp (Utp_context_val (context), u->buffer, nread, &addr.s_gen, addr_len);

    if (!handled && u->on_message) {
      UTP_DEBUG ("not a utp message");
      sa = alloc_sockaddr (&addr, addr_len, 0);
      buf = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, u->buffer, nread);
      caml_callback2 (u->on_message, sa, buf);
    }
  }

  CAMLreturn (Val_unit);
}

CAMLprim value caml_utp_periodic (value context)
{
  CAMLparam1 (context);

  utp_check_timeouts (Utp_context_val (context));

  CAMLreturn (Val_unit);
}

CAMLprim value caml_utp_bind (value ctx, value sa)
{
  CAMLparam2 (ctx, sa);

  union sock_addr_union addr;
  socklen_param_type addr_len;
  utp_context_userdata *u;

  u = utp_context_get_userdata (Utp_context_val (ctx));

  get_sockaddr (sa, &addr, &addr_len);

  bind (u->fd, &addr.s_gen, addr_len);

  CAMLreturn (Val_unit);
}

CAMLprim value caml_utp_destroy (value ctx)
{
  CAMLparam1 (ctx);

  utp_destroy (Utp_context_val (ctx));

  CAMLreturn (Val_unit);
}

CAMLprim value caml_utp_create_socket (value ctx)
{
  CAMLparam1 (ctx);
  CAMLlocal1 (val);

  utp_socket *socket;
  utp_userdata *u;

  socket = utp_create_socket (Utp_context_val (ctx));

  if (!socket) {
    caml_failwith ("caml_utp_create_socket: utp_create_socket");
  }

  u = calloc (1, sizeof (utp_userdata));

  if (!u) {
    caml_failwith ("caml_utp_create_socket: calloc");
  }

  u->socket = socket;
  utp_set_userdata (socket, u);

  val = alloc_utp_socket (socket);

  CAMLreturn (val);
}

CAMLprim value caml_utp_connect (value sock, value addr)
{
  CAMLparam2 (sock, addr);

  union sock_addr_union sock_addr;
  socklen_param_type addr_len;
  int res;

  get_sockaddr (addr, &sock_addr, &addr_len);

  res = utp_connect (Utp_socket_val (sock), &sock_addr.s_gen, addr_len);

  if (res < 0) {
    caml_failwith ("caml_utp_connect: utp_connect");
  }

  CAMLreturn (Val_unit);
}

CAMLprim value caml_utp_write (value socket, value buf, value off, value len)
{
  CAMLparam4(socket, buf, off, len);

  ssize_t written;

  written = utp_write (Utp_socket_val (socket), String_val(buf) + Int_val(off), Int_val(len));

  if (written < 0) {
    caml_failwith ("caml_utp_write: utp_write");
  }

  CAMLreturn (Val_int (written));
}

CAMLprim value caml_utp_set_debug (value context, value v)
{
  CAMLparam2 (context, v);

  utp_context_set_option (Utp_context_val (context), UTP_LOG_DEBUG, Bool_val (v));

  CAMLreturn (Val_unit);
}

CAMLprim value caml_utp_getpeername (value sock)
{
  CAMLparam1 (sock);
  CAMLlocal1 (addr);

  int res;
  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;

  res = utp_getpeername (Utp_socket_val (sock), &sock_addr.s_gen, &sock_addr_len);

  if (res < 0) {
    caml_failwith ("caml_utp_getpeername: utp_getpeername");
  }

  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);

  if (!addr) {
    caml_failwith ("caml_utp_getpeername: alloc_sockaddr");
  }

  CAMLreturn (addr);
}
