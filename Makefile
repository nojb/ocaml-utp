LIBUTP_DIR = libutp/
LIB_DIR = lib/
BIN_DIR = bin/
OCAMLFIND = ocamlfind
OCAMLC = ocamlc
OCAMLOPT = ocamlopt
OCAMLDOC = ocamldoc
STDLIB_DIR = `$(OCAMLC) -where`
LWT_DIR = `$(OCAMLFIND) query lwt`

all: ucat ucat.opt $(LIB_DIR)utp.cma $(LIB_DIR)utp.cmxa

.PHONY: $(LIBUTP_DIR)libutp.a
$(LIBUTP_DIR)libutp.a: $(LIB_DIR)utpstubs.o
	$(MAKE) -C $(LIBUTP_DIR) $(notdir $@)
	ar qv $@ $<

$(LIB_DIR)utpstubs.o: $(LIB_DIR)utpstubs.c
	$(CC) -I $(LIBUTP_DIR) -I $(STDLIB_DIR) -Wall -o $@ -c $<

$(LIB_DIR)utp.cma: $(LIBUTP_DIR)libutp.a $(LIB_DIR)utp.cmo
	$(OCAMLC) -bin-annot -a -custom -o $@ unix.cma bigarray.cma -cclib -lutp $(LIB_DIR)utp.cmo -cclib -lstdc++

$(LIB_DIR)utp.cmxa: $(LIBUTP_DIR)libutp.a $(LIB_DIR)utp.cmx
	$(OCAMLOPT) -bin-annot -a -o $@ -cclib -lunix -cclib -lbigarray -cclib -lutp $(LIB_DIR)utp.cmx -cclib -lstdc++

$(LIB_DIR)utp.cmo: $(LIB_DIR)utp.mli $(LIB_DIR)utp.ml
	$(OCAMLC) -g -bin-annot -I $(LIB_DIR) -o $@ -c $^

$(LIB_DIR)utp.cmx: $(LIB_DIR)utp.mli $(LIB_DIR)utp.ml
	$(OCAMLOPT) -g -bin-annot -I $(LIB_DIR) -o $@ -c $^

doc: $(LIB_DIR)utp.mli
	$(OCAMLDOC) -package lwt.unix -d doc -html -colorize-code -css-style style.css $^

ucat: $(LIB_DIR)utp.cma $(BIN_DIR)ucat.ml
	$(OCAMLC) -g -bin-annot -I $(LWT_DIR) -I $(LIB_DIR) -ccopt -L$(LIB_DIR) -ccopt -L$(LIBUTP_DIR) \
		$(LIB_DIR)utp.cma lwt.cma lwt-unix.cma $(BIN_DIR)ucat.ml -o $@

ucat.opt: $(LIB_DIR)utp.cmxa $(BIN_DIR)ucat.ml
	$(OCAMLOPT) -g -bin-annot -I $(LWT_DIR) -I $(LIB_DIR) -ccopt -L$(LIB_DIR) -ccopt -L$(LIBUTP_DIR) \
		$(LIB_DIR)utp.cmxa unix.cmxa bigarray.cmxa lwt.cmxa lwt-unix.cmxa $(BIN_DIR)ucat.ml -o $@

install: $(LIB_DIR)utp.cma $(LIB_DIR)utp.cmxa $(LIBUTP_DIR)libutp.a $(LIB_DIR)META
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

.PHONY: clean install uninstall doc
