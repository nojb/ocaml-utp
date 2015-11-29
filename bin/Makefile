OCAMLFIND = ocamlfind
LIB_DIR = ../lib

all: ucat ucat.opt

ucat: ucat.ml
	$(OCAMLFIND) ocamlc -linkpkg -o $@ -package lwt.unix -I $(LIB_DIR) -cclib -L$(LIB_DIR) utp.cma ucat.ml

ucat.opt: ucat.ml
	$(OCAMLFIND) ocamlopt -linkpkg -o $@ -package lwt.unix -I $(LIB_DIR) -cclib -L$(LIB_DIR) utp.cmxa ucat.ml

clean:
	rm -f *.cmi *.cmo *.cmx *.o
	rm -f ucat ucat.opt

.PHONY: all clean
