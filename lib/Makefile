OCAMLFIND = ocamlfind
OCAMLC = ocamlc
OCAMLOPT = ocamlopt
OCAMLMKLIB = ocamlmklib
CC = cc
LIBUTP_DIR = ../libutp
CFLAGS = -fPIC -I/usr/local/lib/ocaml/ -I$(LIBUTP_DIR)

all: clib bytelib nativelib

utp.cmo: utp.mli utp.ml
	$(OCAMLFIND) $(OCAMLC) -package lwt.unix -c utp.mli utp.ml

utp.cmx: utp.mli utp.ml
	$(OCAMLFIND) $(OCAMLOPT) -package lwt.unix -c utp.mli utp.ml

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clib: utpstubs.o socketaddr.o unixsupport.o
	$(OCAMLMKLIB) -o utpstubs socketaddr.o utpstubs.o unixsupport.o -lutp -L$(LIBUTP_DIR)

bytelib: utp.cmo
	$(OCAMLMKLIB) -o utp utp.cmo -lutp -L$(LIBUTP_DIR)

nativelib: utp.cmx
	$(OCAMLMKLIB) -o utp utp.cmx -lutp -L$(LIBUTP_DIR)

clean:
	rm -f *.cmo *.cmx *.cma *.cmxa *.cmi *.a *.o
	rm -f dllutpstubs.so

.PHONY: clean
