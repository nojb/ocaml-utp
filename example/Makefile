OCAMLFIND = ocamlfind
LIB_DIR = ../lib

all: ucat ucat.opt

ucat:
	$(OCAMLFIND) ocamlc -linkpkg -o $@ -package lwt.unix -I $(LIB_DIR) -cclib -L$(LIB_DIR) utp.cma ucat.ml

ucat.opt:
	$(OCAMLFIND) ocamlopt -linkpkg -o $@ -package lwt.unix -I $(LIB_DIR) -cclib -L$(LIB_DIR) utp.cmxa ucat.ml

clean:
	rm -f *.cmi *.cmo *.cmx *.o
	rm -f ucat ucat.opt

.PHONY: all clean
