#include <assert.h>

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/callback.h>
#include <caml/bigarray.h>

#include "utp.h"

#include "socketaddr.h"

static uint64 utp_on_read(utp_callback_arguments* a)
{
  value ba = caml_ba_alloc_dims(CAML_BA_UINT8 | CAML_BA_C_LAYOUT, 1, (void *)a->buf, a->len);
  caml_callback2 (*caml_named_value("caml_utp_on_read"), (value)a->socket, ba);
  return 0;
}

static uint64 utp_on_state_change(utp_callback_arguments *a)
{
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

static uint64 utp_on_error(utp_callback_arguments *a)
{
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

CAMLprim value caml_utp_get_userdata(value sock)
{
  return *(value *)(utp_get_userdata((utp_socket *)sock));
}

CAMLprim value caml_utp_init(value version)
{
  utp_context *ctx =utp_init(Int_val(version));
  utp_set_callback(ctx, UTP_ON_READ, utp_on_read);
  utp_set_callback(ctx, UTP_ON_STATE_CHANGE, utp_on_state_change);
  return (value)ctx;
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
  get_sockaddr(sa, &addr, &addr_len);
  int n = utp_process_udp((utp_context *)ctx, Caml_ba_data_val(buf), Int_val(len), &addr.s_gen, addr_len);
  return Val_int(n);
}

CAMLprim value caml_utp_create_socket(value ctx, value data)
{
  utp_socket *sock = utp_create_socket((utp_context *)ctx);
  value *userdata = malloc(sizeof (value));
  *userdata = data;
  caml_register_generational_global_root(userdata);
  utp_set_userdata(sock, userdata);
  return (value)sock;
}

CAMLprim value caml_utp_connect(value sock, value addr)
{
  utp_socket* utp_sock = (utp_socket*)sock;
  union sock_addr_union sock_addr;
  socklen_param_type addr_len;
  get_sockaddr(addr, &sock_addr, &addr_len);
  utp_connect(utp_sock, &sock_addr.s_gen, addr_len);
  return Val_unit;
}

CAMLprim value caml_utp_check_timeouts(value ctx)
{
  utp_context* utp_ctx = (utp_context*)ctx;
  utp_check_timeouts(utp_ctx);
  return Val_unit;
}
