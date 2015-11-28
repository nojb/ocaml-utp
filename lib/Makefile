OCAMLFIND = ocamlfind
OCAMLC = ocamlc
OCAMLOPT = ocamlopt
OCAMLMKLIB = ocamlmklib
CC = cc
LIBUTP_DIR = ../libutp
OCAML_DIR = `ocamlfind printconf stdlib`
CFLAGS = -fPIC -I$(OCAML_DIR) -I$(LIBUTP_DIR)
LWT_DIR = `ocamlfind query lwt.unix`

all: utp.cma utp.cmxa utpstubs.a

utp.cmo: utp.mli utp.ml
	$(OCAMLC) -o $@ -I $(LWT_DIR) -c $^

utp.cma: utp.cmo
	$(OCAMLC) -a -o $@ -I $(LWT_DIR) -cclib -lstdc++ -custom $^

utp.cmx: utp.mli utp.ml
	$(OCAMLOPT) -I $(LWT_DIR) -c $^

utp.cmxa: utp.cmx utpstubs.a
	$(OCAMLOPT) -a -o $@ -cclib -lstdc++ $^

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

utpstubs.a: utpstubs.o socketaddr.o unixsupport.o
	ar rcs $@ $^

clean:
	rm -f *.cmo *.cmx *.cma *.cmxa *.cmi *.a *.o

.PHONY: clean
