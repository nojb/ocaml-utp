/* Copyright (C) 2015 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

   This file is part of ocaml-libutp.

   This library is free software; you can redistribute it and/or modify it under
   the terms of the GNU Lesser General Public License as published by the Free
   Software Foundation; either version 2.1 of the License, or (at your option)
   any later version.

   This library is distributed in the hope that it will be useful, but WITHOUT
   ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
   FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more
   details.

   You should have received a copy of the GNU Lesser General Public License
   along with this library; if not, write to the Free Software Foundation, Inc.,
   51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA */

#include <assert.h>
#include <string.h>
#include <stdio.h>

#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/bigarray.h>
#include <caml/fail.h>

#include "utp.h"

#include "socketaddr.h"

static uint64 callback_on_read(utp_callback_arguments* a)
{
  /* fprintf(stderr, "callback_on_read\n"); */
  value ba = caml_ba_alloc_dims(CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *)a->buf, a->len);
  caml_callback2 (*caml_named_value("caml_utp_on_read"), (value)a->socket, ba);
  return 0;
}

static uint64 callback_on_state_change(utp_callback_arguments *a)
{
  /* fprintf(stderr, "callback_on_state_change\n"); */
  int state;
  switch (a->state) {
  case UTP_STATE_CONNECT:
    state = 0;
    break;
  case UTP_STATE_WRITABLE:
    state = 1;
    break;
  case UTP_STATE_EOF:
    state = 2;
    break;
  case UTP_STATE_DESTROYING:
    state = 3;
    break;
  default:
    state = -1; /* CANT HAPPEN */
    break;
  }
  caml_callback2(*caml_named_value("caml_utp_on_state_change"), (value)a->socket, Val_int(state));
  return 0;
}

static uint64 callback_on_error(utp_callback_arguments *a)
{
  /* fprintf(stderr, "callback_on_error"); */
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
  caml_callback2(*caml_named_value("caml_utp_on_error"), (value)a->socket, Val_int(i));
  return 0;
}

static uint64 callback_on_sendto(utp_callback_arguments *a)
{
  /* fprintf(stderr, "callback_on_sendto\n"); */
  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;
  value addr;
  value buf;

  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy(&sock_addr.s_inet, (struct sockaddr_in *)a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);
  buf = caml_ba_alloc_dims(CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *)a->buf, a->len);

  caml_callback3(*caml_named_value("caml_utp_on_sendto"), (value)a->context, addr, buf);

  return 0;
}

static uint64 callback_on_log(utp_callback_arguments *a)
{
  /* fprintf(stderr, "callback_on_log\n"); */
  value str;

  str = caml_alloc_string(strlen((char *)a->buf));
  strcpy(String_val(str), (char *)a->buf);
  caml_callback2(*caml_named_value("caml_utp_on_log"), (value)a->socket, str);

  return 0;
}

static uint64 callback_on_accept(utp_callback_arguments *a)
{
  /* fprintf(stderr, "callback_on_accept\n"); */

  union sock_addr_union sock_addr;
  socklen_param_type sock_addr_len;
  value addr;

  sock_addr_len = sizeof (struct sockaddr_in);
  memcpy(&sock_addr.s_inet, (struct sockaddr_in *)a->address, sock_addr_len);
  addr = alloc_sockaddr (&sock_addr, sock_addr_len, 0);

  caml_callback2(*caml_named_value("caml_utp_on_accept"), (value)a->socket, addr);

  return 0;
}

static uint64 callback_on_firewall(utp_callback_arguments *a)
{
  /* fprintf(stderr, "callback_on_firewall\n"); */
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

CAMLprim value caml_utp_init(value version)
{
  utp_context *utp_ctx;

  utp_ctx = utp_init(Int_val(version));

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

  return Val_int(handled);
}

CAMLprim value caml_utp_create_socket(value ctx)
{
  utp_socket *utp_sock;

  utp_sock = utp_create_socket((utp_context *)ctx);

  if (!utp_sock) {
    caml_failwith("utp_create_socket");
  }

  return (value)utp_sock;
}

CAMLprim value caml_utp_connect(value sock, value addr)
{
  union sock_addr_union sock_addr;
  socklen_param_type addr_len;

  get_sockaddr(addr, &sock_addr, &addr_len);
  utp_connect((utp_socket *)sock, &sock_addr.s_gen, addr_len);

  return Val_unit;
}

CAMLprim value caml_utp_write(value sock, value buf, value off, value len)
{
  CAMLparam4(sock, buf, off, len);

  utp_socket *utp_sock;
  ssize_t written;
  void *utp_buf;

  utp_buf = String_val(buf) + Int_val(off);
  utp_sock = (utp_socket *)sock;
  written = utp_write(utp_sock, utp_buf, Int_val(len));

  CAMLreturn(Val_int(written));
}

CAMLprim value caml_utp_check_timeouts(value ctx)
{
  utp_context* utp_ctx = (utp_context*)ctx;
  utp_check_timeouts(utp_ctx);
  return Val_unit;
}

CAMLprim value caml_utp_get_stats(value sock)
{
  CAMLparam1(sock);
  CAMLlocal1(stats);

  utp_socket_stats *utp_stats;
  utp_socket *utp_sock;

  utp_sock = (utp_socket *)sock;
  utp_stats = utp_get_stats(utp_sock);

  if (!utp_stats) {
    caml_failwith("utp_get_stats");
  }

  stats = caml_alloc(8, 0);

  if (!stats) {
    caml_failwith("caml_utp_get_stats: caml_alloc");
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
    caml_failwith("caml_utp_get_context_stats: caml_alloc");
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
