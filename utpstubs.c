#include <caml/mlvalues.h>
#include <caml/memory.h>

#include "libutp/utp.h"

utp_context *__ctx = utp_init (2);

CAMLprim value caml_utp_create_socket (value unit)
{
  utp_socket *sock = utp_create_socket (__ctx);
  CAMLreturn ((value)sock);
}
