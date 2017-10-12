# Needed for clock_gettime
# lrt := $(shell echo 'int main() {}' | $(CC) -xc -o /dev/null - -lrt >/dev/null 2>&1; echo $$?)
# ifeq ($(strip $(lrt)),0)
#   LRT = -lrt
# endif

all:
	jbuilder build --dev @install

clean:
	jbuilder clean

# ucat: utp-lwt.cma $(BIN_DIR)ucat.ml
# 	$(OCAMLC) -g -bin-annot -I $(LWT_DIR) -I $(LIB_DIR) -ccopt -L. -o $@ unix.cma bigarray.cma lwt.cma lwt-unix.cma $^

# ucat.opt: utp.cmxa utp-lwt.cmxa $(BIN_DIR)ucat.ml
# 	$(OCAMLOPT) -g -bin-annot -I $(LWT_DIR) -I $(LIB_DIR) -ccopt -L. -o $@ unix.cmxa bigarray.cmxa lwt.cmxa lwt-unix.cmxa $^

doc:
	jbuilder doc

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

.PHONY: all clean doc
