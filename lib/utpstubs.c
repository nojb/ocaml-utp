/* The MIT License (MIT)

   Copyright (c) 2015 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

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
#include <caml/socketaddr.h>
#include <caml/unixsupport.h>

#include "utp.h"

typedef struct {
  utp_context *context;

  value on_error;
  value on_sendto;
  value on_log;
  value on_accept;
} utp_context_userdata;

typedef struct {
  utp_socket *socket;

  value on_read;
  value on_connect;
  value on_writable;
  value on_eof;
  value on_close;
} utp_userdata;

static uint64 callback_on_read (utp_callback_arguments* a)
{
  utp_userdata *u;

  value ba = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *) a->buf, a->len);

  if (!ba) {
    caml_raise_out_of_memory ();
  }

  u = utp_get_userdata (a->socket);

  if (u->on_read) {
    caml_callback (u->on_read, ba);
  }

  utp_read_drained (a->socket);

  return 0;
}

static uint64 callback_on_state_change (utp_callback_arguments *a)
{
  utp_userdata *u;
  value cb;

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
    case UTP_STATE_DESTROYING: // TODO FIXME
      cb = u->on_close;
      break;
    default:
      caml_invalid_argument("callback_on_state_change");
      break;
  }

  if (cb) {
    caml_callback (cb, Val_unit);
  }

  return 0;
}

static uint64 callback_on_error (utp_callback_arguments *a)
{
  utp_context_userdata *u;
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

  u = utp_context_get_userdata (a->context);

  if (u->on_error) {
    caml_callback2(u->on_error, (value) a->socket, Val_int(i));
  }

  return 0;
}

static uint64 callback_on_sendto (utp_callback_arguments *a)
{
  CAMLparam0();
  CAMLlocal2(addr, buf);

  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;

  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy (&sock_addr.s_inet, (struct sockaddr_in *)a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);

  if (!addr) {
    caml_raise_out_of_memory();
  }

  buf = caml_ba_alloc_dims (CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *)a->buf, a->len);

  if (!buf) {
    caml_raise_out_of_memory ();
  }

  utp_context_userdata *u = utp_context_get_userdata (a->context);

  if (u->on_sendto) {
    caml_callback3 (u->on_sendto, (value) a->context, addr, buf);
  }

  CAMLreturn(0);
}

static uint64 callback_on_log (utp_callback_arguments *a)
{
  utp_context_userdata *u;
  value str;

  str = caml_alloc_string(strlen((char *)a->buf));
  strcpy(String_val(str), (char *)a->buf);

  u = utp_context_get_userdata (a->context);

  if (u->on_log) {
    caml_callback2(u->on_log, (value) a->socket, str);
  }

  return 0;
}

static uint64 callback_on_accept (utp_callback_arguments *a)
{
  utp_context_userdata *u;
  utp_userdata *su;
  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;
  value addr;

  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy(&sock_addr.s_inet, (struct sockaddr_in *)a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);

  if (!addr) {
    caml_raise_out_of_memory();
  }

  su = calloc (1, sizeof (utp_userdata));
  su->socket = a->socket;
  utp_set_userdata (a->socket, su);

  u = utp_context_get_userdata (a->context);

  if (u->on_accept) {
    caml_callback2(u->on_accept, (value) a->socket, addr);
  }

  return 0;
}

static uint64 callback_on_firewall(utp_callback_arguments *a)
{
  return 0;
}

CAMLprim value caml_utp_get_userdata(value sock)
{
  void *utp_info;

  utp_info = utp_get_userdata((utp_socket *)sock);

  if (!utp_info) {
    caml_invalid_argument("utp_get_userdata");
  }

  return *(value *)utp_info;
}

CAMLprim value caml_utp_set_userdata(value sock, value info)
{
  value *utp_info;
  utp_socket *utp_sock;

  utp_sock = (utp_socket *)sock;
  utp_info = utp_get_userdata(utp_sock);

  if (utp_info) {
    caml_modify_generational_global_root(utp_info, info);
  } else {
    utp_info = (value *)malloc(sizeof (value));

    if (!utp_info) {
      caml_raise_out_of_memory();
    }

    *utp_info = info;
    caml_register_generational_global_root(utp_info);
    utp_set_userdata(utp_sock, utp_info);
  }

  return Val_unit;
}

CAMLprim value caml_utp_close(value sock)
{
  utp_close((utp_socket *)sock);
  return Val_unit;
}

CAMLprim value caml_utp_set_callback(value ctx, value cb, value fun)
{
  CAMLparam3(ctx, cb, fun);

  utp_context_userdata *u = utp_context_get_userdata((utp_context *) ctx);
  value *cbaddr;

  switch (Int_val(cb)) {
    case 0:
      cbaddr = &(u->on_error);
      break;
    case 1:
      cbaddr = &(u->on_sendto);
      break;
    case 2:
      cbaddr = &(u->on_log);
      break;
    case 3:
      cbaddr = &(u->on_accept);
      break;
  }

  if (*cbaddr) {
    caml_modify_generational_global_root(cbaddr, fun);
  } else {
    *cbaddr = fun;
    caml_register_generational_global_root(cbaddr);
  }

  CAMLreturn(Val_unit);
}

CAMLprim value caml_socket_set_callback(value sock, value cbnum, value fun)
{
  CAMLparam3(sock, cbnum, fun);

  utp_userdata *u = utp_get_userdata((utp_socket *) sock);
  value *cb;

  switch (Int_val(cbnum)) {
    case 0:
      cb = &(u->on_read);
      break;
    case 1:
      cb = &(u->on_connect);
      break;
    case 2:
      cb = &(u->on_writable);
      break;
    case 3:
      cb = &(u->on_eof);
      break;
    case 4:
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
  utp_context *utp_ctx;
  utp_context_userdata *u;

  utp_ctx = utp_init(Int_val(version));
  u = calloc(1, sizeof(utp_context_userdata));

  utp_context_set_userdata (utp_ctx, u);

  utp_set_callback(utp_ctx, UTP_ON_READ, callback_on_read);
  utp_set_callback(utp_ctx, UTP_ON_STATE_CHANGE, callback_on_state_change);
  utp_set_callback(utp_ctx, UTP_SENDTO, callback_on_sendto);
  utp_set_callback(utp_ctx, UTP_LOG, callback_on_log);
  utp_set_callback(utp_ctx, UTP_ON_ERROR, callback_on_error);
  utp_set_callback(utp_ctx, UTP_ON_ACCEPT, callback_on_accept);
  utp_set_callback(utp_ctx, UTP_ON_FIREWALL, callback_on_firewall);

  return (value)utp_ctx;
}

CAMLprim value caml_utp_destroy(value ctx)
{
  utp_destroy((utp_context *)ctx);

  return Val_unit;
}

CAMLprim value caml_utp_read_drained(value sock)
{
  utp_read_drained((utp_socket *)sock);
  return Val_unit;
}

CAMLprim value caml_utp_issue_deferred_acks(value ctx)
{
  utp_issue_deferred_acks((utp_context *)ctx);

  return Val_unit;
}

CAMLprim value caml_utp_process_udp(value ctx, value buf, value len, value sa)
{
  union sock_addr_union addr;
  socklen_param_type addr_len;
  int handled;

  get_sockaddr(sa, &addr, &addr_len);
  handled = utp_process_udp((utp_context *)ctx, Caml_ba_data_val(buf), Int_val(len), &addr.s_gen, addr_len);

  return Val_bool(handled);
}

CAMLprim value caml_utp_create_socket(value ctx)
{
  utp_socket *utp_sock;
  utp_userdata *u;

  utp_sock = utp_create_socket((utp_context *)ctx);

  if (!utp_sock) {
    caml_failwith("utp_create_socket");
  }

  u = calloc (1, sizeof (utp_userdata));
  u->socket = utp_sock;
  utp_set_userdata (utp_sock, u);

  return (value)utp_sock;
}

CAMLprim value caml_utp_connect(value sock, value addr)
{
  union sock_addr_union sock_addr;
  socklen_param_type addr_len;
  int res;

  get_sockaddr(addr, &sock_addr, &addr_len);

  res = utp_connect((utp_socket *)sock, &sock_addr.s_gen, addr_len);

  if (res < 0) {
    caml_failwith("utp_connect");
  }

  return Val_unit;
}

CAMLprim value caml_utp_write(value sock, value buf, value off, value len)
{
  CAMLparam4(sock, buf, off, len);

  ssize_t written;
  void *utp_buf;

  utp_buf = String_val(buf) + Int_val(off);
  written = utp_write((utp_socket *)sock, utp_buf, Int_val(len));

  if (written < 0) {
    caml_failwith("utp_write");
  }

  CAMLreturn(Val_int(written));
}

CAMLprim value caml_utp_check_timeouts(value ctx)
{
  utp_check_timeouts((utp_context *)ctx);

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

CAMLprim value caml_utp_context_get_userdata(value utp_ctx)
{
  void *ctx;

  ctx = utp_context_get_userdata((utp_context *)utp_ctx);

  if (!ctx) {
    caml_invalid_argument("utp_context_get_userdata");
  }

  return *(value *)ctx;
}

CAMLprim value caml_utp_context_set_userdata(value utp_ctx, value ctx)
{
  value *old_ctx;

  old_ctx = utp_context_get_userdata((utp_context *)utp_ctx);

  if (old_ctx) {
    caml_modify_generational_global_root(old_ctx, ctx);
  } else {
    old_ctx = (value *)malloc(sizeof (value));

    if (!old_ctx) {
      caml_raise_out_of_memory();
    }

    *old_ctx = ctx;
    caml_register_generational_global_root(old_ctx);
    utp_context_set_userdata((utp_context *)utp_ctx, old_ctx);
  }

  return Val_unit;
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

  if (!stats) {
    caml_raise_out_of_memory();
  }

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

CAMLprim value caml_utp_getsockopt(value sock, value opt)
{
  int utp_opt;
  int val;

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

  val = utp_getsockopt((utp_socket *)sock, utp_opt);

  switch (utp_opt) {
  case UTP_LOG_NORMAL:
  case UTP_LOG_MTU:
  case UTP_LOG_DEBUG:
    return Val_bool(val);
  case UTP_SNDBUF:
  case UTP_RCVBUF:
  case UTP_TARGET_DELAY:
    return Val_int(val);
  default:
    caml_invalid_argument("utp_get_sockopt");
  }
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

  val = utp_context_get_option((utp_context *)ctx, utp_opt);

  if (val < 0) {
    caml_failwith("utp_context_get_option");
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
    caml_invalid_argument("caml_utp_context_set_option");
  }

  res = utp_context_set_option((utp_context *)ctx, utp_opt, Int_val(val));

  if (res < 0) {
    caml_failwith("utp_context_set_option");
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

  if (res < 0)
    uerror("sendto", sa);

  CAMLreturn(Val_unit);
}
