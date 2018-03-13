
KBLD_DIR ?= /opt/kbuild-tool
SHELLCHECK_EXCL ?= 'SC2086,SC2002,SC2155,SC1090,SC2001'
all: build


build:
	echo "This is shell script, run make install"

install:
	mkdir -p $(KBLD_DIR)
	install -m 555 kbuild-tool.sh $(KBLD_DIR)/kbuild-tool
	install -m 555 setlocalversion $(KBLD_DIR)/setlocalversion
	install -m 644 kbuild-tool.config $(KBLD_DIR)/kbuild-tool.config
	install	-m 555 -D bin/x86_64/zstd $(KBLD_DIR)/bin/x86_64/zstd

check:
	shellcheck -f gcc -e $(SHELLCHECK_EXCL) kbuild-tool.sh
	shellcheck -f gcc -e $(SHELLCHECK_EXCL),SC2006 setlocalversion
uninstall:
	rm -rf $(KBLD_DIR)

.PHONY: all clean install uninstall check
