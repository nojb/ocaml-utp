#include <assert.h>

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/callback.h>
#include <caml/bigarray.h>

#include "libutp/utp.h"

static uint64 utp_on_read (utp_callback_arguments* a)
{
  value ba = caml_ba_alloc (CAML_BA_UINT8, 1, (void *)a->buf, (intnat *) &(a->len));
  caml_callback2 (*caml_named_value ("caml_utp_on_read"), (value)a->socket, ba);
  return 0;
}

static uint64 utp_on_state_change (utp_callback_arguments *a)
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

CAMLprim value caml_utp_get_userdata (value sock)
{
  return *(value *)(utp_get_userdata((utp_socket *)sock));
}

CAMLprim value caml_utp_init (value version)
{
  utp_context *ctx = utp_init(Int_val(version));
  utp_set_callback (ctx, UTP_ON_READ, utp_on_read);
  utp_set_callback (ctx, UTP_ON_STATE_CHANGE, utp_on_state_change);
  return (value)ctx;
}

CAMLprim value caml_utp_destroy (value ctx)
{
  utp_destroy ((utp_context *)ctx);
  return Val_unit;
}

CAMLprim value caml_utp_create_socket (value ctx, value data)
{
  utp_socket *sock = utp_create_socket ((utp_context *)ctx);
  value *userdata = malloc (sizeof (value));
  *userdata = data;
  caml_register_generational_global_root(userdata);
  utp_set_userdata(sock, userdata);
  return (value)sock;
}
