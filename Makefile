OCAMLFIND = ocamlfind
OCAMLC = ocamlc
OCAMLOPT = ocamlopt
OCAMLMKLIB = ocamlmklib
CC = cc
CFLAGS = -fPIC -I/usr/local/lib/ocaml/

all: clib bytelib nativelib

libutp:
	$(MAKE) -C libutp

utp.cmo: utp.mli utp.ml
	$(OCAMLFIND) $(OCAMLC) -package lwt.unix -c utp.mli utp.ml

utp.cmx: utp.mli utp.ml
	$(OCAMLFIND) $(OCAMLOPT) -package lwt.unix -c utp.mli utp.ml

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clib: utpstubs.o socketaddr.o unixsupport.o
	$(OCAMLMKLIB) -o utpstubs socketaddr.o utpstubs.o unixsupport.o -lutp -Llibutp

bytelib: utp.cmo
	$(OCAMLMKLIB) -o utp utp.cmo -lutp -Llibutp

nativelib: utp.cmx
	$(OCAMLMKLIB) -o utp utp.cmx -lutp -Llibutp

clean:
	rm -f *.cmo *.cmx *.cma *.cmxa *.cmi *.a *.o
	rm -f dllutpstubs.so

full_clean: clean
	$(MAKE) -C libutp clean

.PHONY: clean libutp
