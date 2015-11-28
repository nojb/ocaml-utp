lib: libutp
	$(MAKE) -C lib all

libutp:
	$(MAKE) -C libutp

clean:
	$(MAKE) -C lib clean
	$(MAKE) -C libutp clean

.PHONY: lib libutp clean
