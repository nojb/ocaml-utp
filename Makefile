all: libutp lib bin

libutp:
	$(MAKE) -C libutp

lib: libutp
	$(MAKE) -C lib

bin: lib
	$(MAKE) -C bin

clean:
	$(MAKE) -C lib clean
	$(MAKE) -C libutp clean
	$(MAKE) -C bin clean

.PHONY: lib libutp bin clean
