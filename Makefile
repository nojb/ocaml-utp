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

LIBUTP_OBJS = \
	$(LIBUTP_DIR)utp_internal.o \
	$(LIBUTP_DIR)utp_utils.o \
	$(LIBUTP_DIR)utp_hash.o \
	$(LIBUTP_DIR)utp_callbacks.o \
	$(LIBUTP_DIR)utp_api.o \
	$(LIBUTP_DIR)utp_packedsockaddr.o

$(LIBUTP_DIR)%.o: $(LIBUTP_DIR)%.cpp
	$(MAKE) -C $(LIBUTP_DIR) $(notdir $@)

$(LIB_DIR)utpstubs.o: $(LIB_DIR)utpstubs.c
	$(CC) -I $(LIBUTP_DIR) -I $(STDLIB_DIR) -Wall -o $@ -c $<

$(LIB_DIR)utp.cma: $(LIB_DIR)utp.cmo $(LIBUTP_OBJS) $(LIB_DIR)utpstubs.o
	$(OCAMLC) -bin-annot -a -custom -o $@ $^ -cclib -lstdc++

$(LIB_DIR)utp.cmxa: $(LIB_DIR)utp.cmx $(LIBUTP_OBJS) $(LIB_DIR)utpstubs.o
	$(OCAMLOPT) -bin-annot -a -o $@ $^ -cclib -lstdc++

$(LIB_DIR)utp.cmo: $(LIB_DIR)utp.mli $(LIB_DIR)utp.ml
	$(OCAMLC) -g -bin-annot -I $(LIB_DIR) -o $@ -c $^

$(LIB_DIR)utp.cmx: $(LIB_DIR)utp.mli $(LIB_DIR)utp.ml
	$(OCAMLOPT) -g -bin-annot -I $(LIB_DIR) -o $@ -c $^

doc: $(LIB_DIR)utp.mli
	$(OCAMLDOC) -package lwt.unix -d doc -html -colorize-code -css-style style.css $^

ucat: $(LIB_DIR)utp.cma $(BIN_DIR)ucat.ml
	$(OCAMLC) -g -bin-annot -I $(LWT_DIR) -I $(LIB_DIR) unix.cma bigarray.cma lwt.cma lwt-unix.cma -o $@ $^

ucat.opt: $(LIB_DIR)utp.cmxa $(BIN_DIR)ucat.ml
	$(OCAMLOPT) -g -bin-annot -I $(LWT_DIR) -I $(LIB_DIR) unix.cmxa bigarray.cmxa lwt.cmxa lwt-unix.cmxa -o $@ $^

install: $(LIB_DIR)utp.cma $(LIB_DIR)utp.cmxa $(LIBUTP_OBJS) $(LIBUTP_DIR)utpstubs.o $(LIB_DIR)META
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
