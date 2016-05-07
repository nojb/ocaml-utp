LIBUTP_DIR = libutp/
LIB_DIR = lib/
BIN_DIR = bin/
OCAMLFIND = ocamlfind
OCAMLOPT = ocamlopt
CFLAGS = -Wall -I `ocamlfind printconf stdlib`
CC = cc

all: ucat ucat.opt $(LIB_DIR)utp.cma $(LIB_DIR)utp.cmxa $(LIB_DIR)libutpstubs.a $(LIBUTP_DIR)libutp.a

$(LIBUTP_DIR)libutp.a:
	$(MAKE) -C $(LIBUTP_DIR) libutp.a

$(LIB_DIR)utp.cma: $(LIB_DIR)utp.cmo $(LIB_DIR)libutpstubs.a $(LIBUTP_DIR)libutp.a
	$(OCAMLFIND) ocamlc -bin-annot -package lwt.unix -a -o $@ -custom $< -cclib -lutpstubs -cclib -lutp -cclib -lstdc++

$(LIB_DIR)utp.cmxa: $(LIB_DIR)utp.cmx $(LIB_DIR)libutpstubs.a $(LIBUTP_DIR)libutp.a
	$(OCAMLFIND) ocamlopt -bin-annot -package lwt.unix -a -o $@ $< -cclib -lutpstubs -cclib -lutp -cclib -lstdc++

$(LIB_DIR)utp.cmo: $(LIB_DIR)utp.mli $(LIB_DIR)utp.ml
	$(OCAMLFIND) ocamlc -bin-annot -package lwt.unix -o $@ -c -I $(LIB_DIR) $^

$(LIB_DIR)utp.cmx: $(LIB_DIR)utp.mli $(LIB_DIR)utp.ml
	$(OCAMLFIND) ocamlopt -bin-annot -package lwt.unix -o $@ -c -I $(LIB_DIR) $^

$(LIB_DIR)libutpstubs.a: $(LIB_DIR)utpstubs.o
	ar rvs $@ $^

%.o: %.c
	$(CC) -I$(LIBUTP_DIR) $(CFLAGS) -o $@ -c -I$(LIB_DIR) $<

doc: $(LIB_DIR)utp.mli
	$(OCAMLFIND) ocamldoc -package lwt.unix -d doc -html -colorize-code -css-style style.css $^

ucat: $(BIN_DIR)ucat.ml $(LIB_DIR)libutpstubs.a $(LIBUTP_DIR)libutp.a $(LIB_DIR)utp.cma
	$(OCAMLFIND) ocamlc -bin-annot -linkpkg -o $@ -package lwt.unix -package lwt.ppx -g -I $(LIB_DIR) -cclib -L$(LIB_DIR) -cclib -L$(LIBUTP_DIR) utp.cma $<

ucat.opt: $(BIN_DIR)ucat.ml $(LIB_DIR)libutpstubs.a $(LIBUTP_DIR)libutp.a $(LIB_DIR)utp.cmxa
	$(OCAMLFIND) ocamlopt -bin-annot -linkpkg -o $@ -package lwt.unix -package lwt.ppx -g -I $(LIB_DIR) -cclib -L$(LIB_DIR) -cclib -L$(LIBUTP_DIR) utp.cmxa $<

install: $(LIB_DIR)utp.cma $(LIB_DIR)utp.cmxa $(LIB_DIR)libutpstubs.a $(LIBUTP_DIR)libutp.a $(LIB_DIR)META
	$(OCAMLFIND) install utp $^

uninstall:
	$(OCAMLFIND) remove utp

clean:
	$(MAKE) -C libutp clean
	rm -f $(LIB_DIR)*.cm* $(LIB_DIR)*.[oa]
	rm -f $(BIN_DIR)*.cm* $(BIN_DIR)*.o
	rm -f ucat ucat.opt

gh-pages: doc
	git clone `git config --get remote.origin.url` .gh-pages --reference .
	git -C .gh-pages checkout --orphan gh-pages
	git -C .gh-pages reset
	git -C .gh-pages clean -dxf
	cp doc/* .gh-pages/
	git -C .gh-pages add .
	git -C .gh-pages commit -m "Update Pages"
	git -C .gh-pages push origin gh-pages -f
	rm -rf .gh-pages

.PHONY: libutp clean install uninstall doc
