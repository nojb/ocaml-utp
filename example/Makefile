OCAMLFIND = ocamlc
OCAMLFIND = ocamlfind
LIBUTP_DIR = ../libutp
LIB_DIR = ../lib
LWT_DIR = `ocamlfind query lwt.unix`

byte:
	ocamlc -verbose -o ucat -I $(LWT_DIR) -I $(LIB_DIR) unix.cma bigarray.cma $(LWT_DIR)/lwt.cma $(LWT_DIR)/lwt-unix.cma $(LIBUTP_DIR)/libutp.a $(LIB_DIR)/utpstubs.a utp.cma ucat.ml

native:
	$(OCAMLFIND) ocamlopt -linkpkg -package lwt.unix -o ucat -I $(LIB_DIR) $(LIB_DIR)/utp.a $(LIB_DIR)/utp.cmxa ucat.ml

clean:
	rm -f *.cmi *.cmo *.cmx *.o
	rm -f ucat

.PHONY: all clean
