#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/callback.h>
#include <caml/bigarray.h>

#include "libutp/utp.h"

static uint64 utp_on_read (utp_callback_arguments* a)
{
  value ba = caml_ba_alloc (CAML_BA_UINT8, 1, (void *)a->buf, &(a->len));
  caml_callback2 (*caml_named_value ("caml_utp_on_read"), (value)a->socket, ba);
  return 0;
}

static uint64 utp_on_state_change (utp_callback_arguments *a)
{
  return 0;
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

CAMLprim value caml_utp_create_socket (value ctx)
{
  utp_socket *sock = utp_create_socket ((utp_context *)ctx);
  return (value)sock;
}
