OCAMLFIND = ocamlfind
OCAMLC = ocamlc
OCAMLOPT = ocamlopt
LIBUTP_DIR = ../libutp

all: libutp.a utp.cma utp.cmxa

libutp.a: $(LIBUTP_DIR)/libutp.a utpstubs.o socketaddr.o unixsupport.o
	cp $(LIBUTP_DIR)/libutp.a .
	ar rvs libutp.a utpstubs.o socketaddr.o unixsupport.o

utp.cma: utp.cmo libutp.a
	$(OCAMLFIND) ocamlc -package lwt.unix -a -o utp.cma -custom -cclib -lstdc++ utp.cmo -cclib -lutp

utp.cmxa: utp.cmx libutp.a
	$(OCAMLFIND) ocamlopt -package lwt.unix -a -o utp.cmxa -cclib -lstdc++ utp.cmx -cclib -lutp

utp.cmo: utp.mli utp.ml
	$(OCAMLFIND) ocamlc -package lwt.unix -c $^

utp.cmx: utp.mli utp.ml
	$(OCAMLFIND) ocamlopt -package lwt.unix -c $^

%.o: %.c
	ocamlopt -ccopt -I -ccopt $(LIBUTP_DIR) -o $@ -c $<

clean:
	rm -f *.cmo *.cmx *.cma *.cmxa *.cmi *.a *.o *.so

.PHONY: clean
