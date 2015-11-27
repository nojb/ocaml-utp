#include <caml/mlvalues.h>
#include <caml/memory.h>

#include "libutp/utp.h"

CAMLprim value caml_utp_init (value version)
{
  return (value)utp_init(Int_val(version));
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
