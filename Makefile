all: libutp lib bin

libutp:
	$(MAKE) -C libutp

lib: libutp
	$(MAKE) -C lib

bin: lib
	$(MAKE) -C bin

doc install uninstall:
	$(MAKE) -C lib $@

clean:
	$(MAKE) -C lib clean
	$(MAKE) -C libutp clean
	$(MAKE) -C bin clean

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

.PHONY: doc lib libutp bin clean install uninstall
