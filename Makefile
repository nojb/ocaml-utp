all: clib bytelib nativelib

libutp:
	$(MAKE) -C libutp

utp.cmo: utp.ml
	ocamlc -c utp.ml

utp.cmx: utp.ml
	ocamlopt -c utp.ml

utpstubs.o: utpstubs.c libutp
	ocamlopt -o utpstubs.o utpstubs.c

clib: utpstubs.o
	ocamlmklib -o utpstubs utpstubs.o -lutp -Llibutp

bytelib: utp.cmo
	ocamlmklib -o utp utp.cmo -lutp -Llibutp

nativelib: utp.cmx
	ocamlmklib -o utp utp.cmx -lutp -Llibutp

clean:
	rm -f utp.cmo utp.cmx utp.cma utp.cmxa utp.o utp.cmi utp.a
	rm -f utpstubs.o dllutpstubs.so libutpstubs.a

full_clean: clean
	$(MAKE) -C libutp clean

.PHONY: clean libutp
