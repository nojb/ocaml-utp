OCAMLFIND = ocamlfind
OCAMLC = ocamlc
OCAMLOPT = ocamlopt
LIBUTP_DIR = ../libutp
LIBUTP_OBJS = utp_internal.o utp_utils.o utp_hash.o utp_callbacks.o utp_api.o utp_packedsockaddr.o

lib: utp.cmo utp.cmx utpstubs.o socketaddr.o unixsupport.o $(addprefix $(LIBUTP_DIR)/,$(LIBUTP_OBJS))
	$(OCAMLFIND) ocamlmklib -package lwt.unix -o utp -cclib -lstdc++ $^

utp.cmo: utp.mli utp.ml
	$(OCAMLFIND) ocamlc -package lwt.unix -c $^

utp.cmx: utp.mli utp.ml
	$(OCAMLFIND) ocamlopt -package lwt.unix -c $^

%.o: %.c
	ocamlopt -ccopt -I -ccopt $(LIBUTP_DIR) -o $@ -c $<

clean:
	rm -f *.cmo *.cmx *.cma *.cmxa *.cmi *.a *.o *.so

.PHONY: clean
