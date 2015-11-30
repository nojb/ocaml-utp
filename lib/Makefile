OCAMLFIND = ocamlfind
OCAMLC = ocamlc
OCAMLOPT = ocamlopt
LIBUTP_DIR = ../libutp
CFLAGS = -Wall

all: libutp.a utp.cma utp.cmxa

libutp.a: $(LIBUTP_DIR)/libutp.a utpstubs.o socketaddr.o unixsupport.o
	cp $(LIBUTP_DIR)/libutp.a .
	ar rvs libutp.a utpstubs.o socketaddr.o unixsupport.o

utp.cma: utp.cmo libutp.a
	$(OCAMLFIND) ocamlc -package lwt.unix -a -o utp.cma -custom utp.cmo -cclib -lutp -cclib -lstdc++

utp.cmxa: utp.cmx libutp.a
	$(OCAMLFIND) ocamlopt -package lwt.unix -a -o utp.cmxa utp.cmx -cclib -lutp -cclib -lstdc++

utp.cmo: utp.mli utp.ml
	$(OCAMLFIND) ocamlc -package lwt.unix -c $^

utp.cmx: utp.mli utp.ml
	$(OCAMLFIND) ocamlopt -package lwt.unix -c $^

%.o: %.c
	$(OCAMLOPT) -ccopt -I$(LIBUTP_DIR) -ccopt $(CFLAGS) -o $@ -c $<

doc: utp.mli
	$(OCAMLFIND) ocamldoc -package lwt.unix -d ../doc -html -colorize-code -css-style style.css $^

install: all
	$(OCAMLFIND) install utp META utp.cma utp.cmxa libutp.a

uninstall:
	$(OCAMLFIND) remove utp

clean:
	rm -f *.cmo *.cmx *.cma *.cmxa *.cmi *.a *.o *.so

.PHONY: clean
