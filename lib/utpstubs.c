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

static uint64 on_read (utp_callback_arguments* a)
{
  utp_userdata *u;

  value ba = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *) a->buf, a->len);

  u = utp_get_userdata (a->socket);

  if (u->on_read) {
    caml_callback (u->on_read, ba);
  }

  utp_read_drained (a->socket);

  return 0;
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
  CAMLparam0();
  CAMLlocal2(addr, buf);

  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;
  utp_context_userdata *u;

  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy (&sock_addr.s_inet, (struct sockaddr_in *) a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);
  buf = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *) a->buf, a->len);
  u = utp_context_get_userdata (a->context);

  if (u->on_sendto) {
    caml_callback3 (u->on_sendto, (value) a->context, addr, buf);
  }

  CAMLreturn(0);
}

static uint64 on_log (utp_callback_arguments *a)
{
  UTP_DEBUG ("%s", a->buf);
  return 0;
}

static uint64 on_accept (utp_callback_arguments *a)
{
  utp_context_userdata *u;
  utp_userdata *su;
  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;
  value addr;

  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy (&sock_addr.s_inet, (struct sockaddr_in *) a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);

  if (!addr) {
    caml_failwith ("utp_stubs: on_accept");
  }

  su = calloc (1, sizeof (utp_userdata));
  su->socket = a->socket;
  utp_set_userdata (a->socket, su);

  u = utp_context_get_userdata (a->context);

  if (u->on_accept) {
    u->sockets ++;
    caml_callback2 (u->on_accept, (value) a->socket, addr);
  }

  return 0;
}

static uint64 on_firewall (utp_callback_arguments *a)
{
  return 0;
}

CAMLprim value caml_utp_close (value sock)
{
  utp_close ((utp_socket *) sock);
  return Val_unit;
}

CAMLprim value caml_utp_set_callback (value ctx, value cbnum, value fun)
{
  CAMLparam3(ctx, cbnum, fun);

  utp_context_userdata *u = utp_context_get_userdata ((utp_context *) ctx);
  value *cb;

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

  CAMLreturn(Val_unit);
}

CAMLprim value caml_socket_set_callback (value sock, value cbnum, value fun)
{
  CAMLparam3(sock, cbnum, fun);

  utp_userdata *u = utp_get_userdata ((utp_socket *) sock);
  value *cb;

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
    caml_modify_generational_global_root(cb, fun);
  } else {
    *cb = fun;
    caml_register_generational_global_root(cb);
  }

  CAMLreturn(Val_unit);
}

CAMLprim value caml_utp_init(value version)
{
  utp_context *context;
  utp_context_userdata *u;

  context = utp_init (Int_val(version));
  u = calloc (1, sizeof (utp_context_userdata));

  u->sockets = 0;
  u->context = context;
  u->fd = socket (PF_INET, SOCK_DGRAM, 0);
  u->buffer = malloc (UTP_BUFFER_SIZE);

  fcntl (u->fd, F_SETFL, O_NONBLOCK, 1);

  utp_context_set_userdata (context, u);

  utp_set_callback (context, UTP_ON_READ, on_read);
  utp_set_callback (context, UTP_ON_STATE_CHANGE, on_state_change);
  utp_set_callback (context, UTP_SENDTO, on_sendto);
  utp_set_callback (context, UTP_LOG, on_log);
  utp_set_callback (context, UTP_ON_ERROR, on_error);
  utp_set_callback (context, UTP_ON_ACCEPT, on_accept);
  utp_set_callback (context, UTP_ON_FIREWALL, on_firewall);

  return (value) context;
}

CAMLprim value caml_utp_file_descr (value ctx)
{
  CAMLparam1(ctx);
  utp_context_userdata *u;

  u = utp_context_get_userdata((utp_context *) ctx);

  CAMLreturn(Val_int(u->fd));
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
  u = utp_context_get_userdata ((utp_context *) context);

  while (1) {
    nread = recvfrom(u->fd, u->buffer, UTP_BUFFER_SIZE, 0, &addr.s_gen, &addr_len);

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
      utp_issue_deferred_acks ((utp_context *) context);
      break;
    }

    handled = utp_process_udp ((utp_context *) context, u->buffer, nread, &addr.s_gen, addr_len);

    if (!handled && u->on_message) {
      UTP_DEBUG ("not a utp message");
      sa = alloc_sockaddr (&addr, addr_len, 0);
      buf = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, u->buffer, nread);
      caml_callback2 (u->on_message, sa, buf);
    }
  }

  CAMLreturn(Val_unit);
}

CAMLprim value caml_utp_periodic (value context)
{
  utp_check_timeouts ((utp_context *) context);
  return Val_unit;
}

CAMLprim value caml_utp_bind (value ctx, value sa)
{
  CAMLparam2(ctx, sa);
  union sock_addr_union addr;
  socklen_param_type addr_len;
  utp_context_userdata *u;

  u = utp_context_get_userdata ((utp_context *) ctx);

  get_sockaddr (sa, &addr, &addr_len);

  bind (u->fd, &addr.s_gen, addr_len);

  CAMLreturn(Val_unit);
}

CAMLprim value caml_utp_destroy (value ctx)
{
  utp_destroy ((utp_context *) ctx);

  return Val_unit;
}

CAMLprim value caml_utp_create_socket (value ctx)
{
  utp_socket *socket;
  utp_userdata *u;

  socket = utp_create_socket ((utp_context *) ctx);

  if (!socket) {
    caml_failwith ("utp stubs: caml_utp_create_socket");
  }

  u = calloc (1, sizeof (utp_userdata));
  u->socket = socket;
  utp_set_userdata (socket, u);

  return (value) socket;
}

CAMLprim value caml_utp_connect (value sock, value addr)
{
  union sock_addr_union sock_addr;
  socklen_param_type addr_len;
  int res;

  get_sockaddr (addr, &sock_addr, &addr_len);

  res = utp_connect ((utp_socket *) sock, &sock_addr.s_gen, addr_len);

  if (res < 0) {
    caml_failwith ("utp stubs: caml_utp_connect");
  }

  return Val_unit;
}

CAMLprim value caml_utp_write (value socket, value buf, value off, value len)
{
  CAMLparam4(socket, buf, off, len);

  ssize_t written;

  written = utp_write ((utp_socket *) socket, String_val(buf) + Int_val(off), Int_val(len));

  if (written < 0) {
    caml_failwith ("utp_stubs: caml_utp_write");
  }

  CAMLreturn(Val_int(written));
}

CAMLprim value caml_utp_check_timeouts (value ctx)
{
  utp_check_timeouts ((utp_context *) ctx);

  return Val_unit;
}

CAMLprim value caml_utp_get_stats(value sock)
{
  CAMLparam1(sock);
  CAMLlocal1(stats);

  utp_socket_stats *utp_stats;

  utp_stats = utp_get_stats((utp_socket *)sock);

  if (!utp_stats) {
    caml_failwith("utp_get_stats");
  }

  stats = caml_alloc(8, 0);

  if (!stats) {
    caml_failwith("caml_utp_get_stats");
  }

  Store_field(stats, 0, Val_int(utp_stats->nbytes_recv));
  Store_field(stats, 1, Val_int(utp_stats->nbytes_xmit));
  Store_field(stats, 2, Val_int(utp_stats->rexmit));
  Store_field(stats, 3, Val_int(utp_stats->fastrexmit));
  Store_field(stats, 4, Val_int(utp_stats->nxmit));
  Store_field(stats, 5, Val_int(utp_stats->nrecv));
  Store_field(stats, 6, Val_int(utp_stats->nduprecv));
  Store_field(stats, 7, Val_int(utp_stats->mtu_guess));

  CAMLreturn(stats);
}

CAMLprim value caml_utp_get_context(value sock)
{
  if (!sock) {
    caml_invalid_argument("utp_get_context");
  }

  return (value)utp_get_context((utp_socket *)sock);
}

CAMLprim value caml_utp_get_context_stats(value ctx)
{
  utp_context_stats *utp_stats;
  value stats;

  utp_stats = utp_get_context_stats((utp_context *)ctx);

  if (!utp_stats) {
    caml_failwith("utp_get_context_stats");
  }

  stats = caml_alloc(10, 0);

  Store_field(stats, 0, Val_int(utp_stats->_nraw_recv[0]));
  Store_field(stats, 1, Val_int(utp_stats->_nraw_recv[1]));
  Store_field(stats, 2, Val_int(utp_stats->_nraw_recv[2]));
  Store_field(stats, 3, Val_int(utp_stats->_nraw_recv[3]));
  Store_field(stats, 4, Val_int(utp_stats->_nraw_recv[4]));
  Store_field(stats, 5, Val_int(utp_stats->_nraw_send[0]));
  Store_field(stats, 6, Val_int(utp_stats->_nraw_send[1]));
  Store_field(stats, 7, Val_int(utp_stats->_nraw_send[2]));
  Store_field(stats, 8, Val_int(utp_stats->_nraw_send[3]));
  Store_field(stats, 9, Val_int(utp_stats->_nraw_send[4]));

  return stats;
}

CAMLprim value caml_utp_getsockopt(value socket, value opt)
{
  int utp_opt;
  int val;
  value ret;

  switch (Int_val(opt)) {
    case 0:
      utp_opt = UTP_LOG_NORMAL;
      break;
    case 1:
      utp_opt = UTP_LOG_MTU;
      break;
    case 2:
      utp_opt = UTP_LOG_DEBUG;
      break;
    case 3:
      utp_opt = UTP_SNDBUF;
      break;
    case 4:
      utp_opt = UTP_RCVBUF;
      break;
    case 5:
      utp_opt = UTP_TARGET_DELAY;
      break;
    default:
      caml_invalid_argument("caml_utp_getsockopt");
  }

  val = utp_getsockopt ((utp_socket *) socket, utp_opt);

  switch (utp_opt) {
    case UTP_LOG_NORMAL:
    case UTP_LOG_MTU:
    case UTP_LOG_DEBUG:
      ret = Val_bool(val);
      break;
    case UTP_SNDBUF:
    case UTP_RCVBUF:
    case UTP_TARGET_DELAY:
      ret = Val_int(val);
      break;
    default:
      caml_invalid_argument("utp_get_sockopt");
      break;
  }

  return ret;
}

CAMLprim value caml_utp_setsockopt(value sock, value opt, value val)
{
  int utp_opt;

  switch (Int_val(opt)) {
    case 0:
      utp_opt = UTP_LOG_NORMAL;
      break;
    case 1:
      utp_opt = UTP_LOG_MTU;
      break;
    case 2:
      utp_opt = UTP_LOG_DEBUG;
      break;
    case 3:
      utp_opt = UTP_SNDBUF;
      break;
    case 4:
      utp_opt = UTP_RCVBUF;
      break;
    case 5:
      utp_opt = UTP_TARGET_DELAY;
      break;
    default:
      caml_invalid_argument("caml_utp_getsockopt");
  }

  utp_setsockopt((utp_socket *)sock, utp_opt, Int_val(val));

  return Val_unit;
}

CAMLprim value caml_utp_context_get_option(value ctx, value opt)
{
  int utp_opt;
  int val;
  value res;

  switch (Int_val(opt)) {
    case 0:
      utp_opt = UTP_LOG_NORMAL;
      break;
    case 1:
      utp_opt = UTP_LOG_MTU;
      break;
    case 2:
      utp_opt = UTP_LOG_DEBUG;
      break;
    case 3:
      utp_opt = UTP_SNDBUF;
      break;
    case 4:
      utp_opt = UTP_RCVBUF;
      break;
    case 5:
      utp_opt = UTP_TARGET_DELAY;
      break;
    default:
      caml_invalid_argument("caml_utp_context_get_option");
  }

  val = utp_context_get_option ((utp_context *) ctx, utp_opt);

  if (val < 0) {
    caml_failwith ("utp stubs: utp_context_get_option");
  }

  switch (utp_opt) {
    case UTP_LOG_NORMAL:
    case UTP_LOG_MTU:
    case UTP_LOG_DEBUG:
      res = Val_bool(val);
      break;
    case UTP_SNDBUF:
    case UTP_RCVBUF:
    case UTP_TARGET_DELAY:
      res = Val_int(val);
      break;
    default:
      caml_failwith("utp_context_get_option");
  }

  return res;
}

CAMLprim value caml_utp_context_set_option(value ctx, value opt, value val)
{
  int utp_opt;
  int res;

  switch (Int_val(opt)) {
    case 0:
      utp_opt = UTP_LOG_NORMAL;
      break;
    case 1:
      utp_opt = UTP_LOG_MTU;
      break;
    case 2:
      utp_opt = UTP_LOG_DEBUG;
      break;
    case 3:
      utp_opt = UTP_SNDBUF;
      break;
    case 4:
      utp_opt = UTP_RCVBUF;
      break;
    case 5:
      utp_opt = UTP_TARGET_DELAY;
      break;
    default:
      caml_invalid_argument ("utp_stubs: caml_utp_context_set_option");
      break;
  }

  res = utp_context_set_option ((utp_context *) ctx, utp_opt, Int_val(val));

  if (res < 0) {
    caml_failwith ("utp stubs: caml_utp_context_set_option");
  }

  return Val_unit;
}

CAMLprim value caml_utp_getpeername(value sock)
{
  int res;
  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;
  value addr;

  res = utp_getpeername((utp_socket *)sock, &sock_addr.s_gen, &sock_addr_len);

  if (res < 0) {
    caml_failwith("utp_getpeername");
  }

  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);

  if (!addr) {
    caml_failwith("caml_utp_getpeername");
  }

  return addr;
}

CAMLprim value caml_sendto_bytes(value fd, value buf, value off, value len, value sa)
{
  CAMLparam5(fd, buf, off, len, sa);
  union sock_addr_union sock_addr;
  socklen_param_type addr_len;
  int res;

  get_sockaddr(sa, &sock_addr, &addr_len);
  res = sendto(Int_val(fd), Caml_ba_data_val(buf) + Int_val(off), Int_val(len), 0, &sock_addr.s_gen, addr_len);

  if (res < 0) {
    uerror("sendto", sa);
  }

  CAMLreturn(Val_unit);
}
