LIBUTP_DIR = libutp/
LIB_DIR = lib/
BIN_DIR = bin/
OCAMLFIND = ocamlfind
OCAMLC = ocamlc
OCAMLOPT = ocamlopt
OCAMLMKLIB = ocamlmklib
OCAMLDOC = ocamldoc
STDLIB_DIR = `$(OCAMLC) -where`
LWT_DIR = `$(OCAMLFIND) query lwt`

all: ucat ucat.opt utp.cma utp.cmxa utp-lwt.cma utp-lwt.cmxa utp.a libutp.a utp-lwt.a

$(LIB_DIR)utpstubs.o: $(LIB_DIR)utpstubs.c
	$(CC) -I $(LIBUTP_DIR) -I $(STDLIB_DIR) -Wall -fPIC -o $@ -c $<

LIBUTP_OBJS = utp_internal.o utp_utils.o utp_hash.o utp_callbacks.o utp_api.o utp_packedsockaddr.o

$(LIBUTP_DIR)%.o: $(LIBUTP_DIR)%.cpp
	$(MAKE) -C $(LIBUTP_DIR) $(notdir $@)

$(LIB_DIR)utp.cmo: $(LIB_DIR)utp.mli $(LIB_DIR)utp.ml
	$(OCAMLC) -g -bin-annot -I $(LIB_DIR) -o $@ -c $^

$(LIB_DIR)utp.cmx: $(LIB_DIR)utp.mli $(LIB_DIR)utp.ml
	$(OCAMLOPT) -g -bin-annot -I $(LIB_DIR) -o $@ -c $^

$(LIB_DIR)utp_lwt.cmo: $(LIB_DIR)utp.mli $(LIB_DIR)utp_lwt.mli $(LIB_DIR)utp_lwt.ml
	$(OCAMLC) -g -bin-annot -I $(LIB_DIR) -I $(LWT_DIR) -o $@ -c $^

$(LIB_DIR)utp_lwt.cmx: $(LIB_DIR)utp.mli $(LIB_DIR)utp_lwt.mli $(LIB_DIR)utp_lwt.ml
	$(OCAMLOPT) -g -bin-annot -I $(LIB_DIR) -I $(LWT_DIR) -o $@ -c $^

utp.cma utp.cmxa libutp.a utp.a: $(addprefix $(LIBUTP_DIR),$(LIBUTP_OBJS)) $(LIB_DIR)utpstubs.o $(LIB_DIR)utp.cmo $(LIB_DIR)utp.cmx
	$(OCAMLMKLIB) -custom -o utp $^ -lstdc++

utp-lwt.cma: utp.cma $(LIB_DIR)utp_lwt.cmo
	$(OCAMLC) -a -o $@ $^

utp-lwt.cmxa utp-lwt.a: $(LIB_DIR)utp_lwt.cmx
	$(OCAMLOPT) -a -o $@ $^

ucat: utp-lwt.cma $(BIN_DIR)ucat.ml
	$(OCAMLC) -g -bin-annot -I $(LWT_DIR) -I $(LIB_DIR) -ccopt -L. -o $@ unix.cma bigarray.cma lwt.cma lwt-unix.cma $^

ucat.opt: utp.cmxa utp-lwt.cmxa $(BIN_DIR)ucat.ml
	$(OCAMLOPT) -g -bin-annot -I $(LWT_DIR) -I $(LIB_DIR) -ccopt -L. -o $@ unix.cmxa bigarray.cmxa lwt.cmxa lwt-unix.cmxa $^

install: utp.a libutp.a utp.cma utp.cmxa utp-lwt.cma utp-lwt.cmxa utp-lwt.a $(LIB_DIR)utp.mli $(LIB_DIR)utp_lwt.mli $(LIB_DIR)utp.cmi $(LIB_DIR)utp_lwt.cmi META
	$(OCAMLFIND) install utp $^

uninstall:
	$(OCAMLFIND) remove utp

doc: $(LIB_DIR)utp.mli $(LIB_DIR)utp_lwt.mli
	$(OCAMLFIND) $(OCAMLDOC) -package lwt.unix -d doc -html -colorize-code -css-style style.css $^

clean:
	$(MAKE) -C libutp clean
	rm -f $(LIB_DIR)*.cm* $(LIB_DIR)*.[oa]
	rm -f $(BIN_DIR)*.cm* $(BIN_DIR)*.o
	rm -f *.a *.cma *.cmxa *.so
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
