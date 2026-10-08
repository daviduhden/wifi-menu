# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Variables
SCRIPT = wifi-menu
SCRIPT_SRC = $(SCRIPT).pl
PREFIX ?= /usr/local
INSTALL_DIR ?= $(PREFIX)/bin
WIFI_DIR ?= /etc/wifi_saved
INFO = ==>

# Default target
all: install

# Install the script
install: $(SCRIPT_SRC)
	@echo "$(INFO) Installing $(SCRIPT) -> $(INSTALL_DIR)/$(SCRIPT)"
	@install -d -m 755 $(INSTALL_DIR)
	@install -m 755 $(SCRIPT_SRC) $(INSTALL_DIR)/$(SCRIPT)
	@echo "$(INFO) Ensuring wifi directory $(WIFI_DIR) exists"
	@[ -d $(WIFI_DIR) ] || mkdir -m 700 $(WIFI_DIR)
	@chmod 700 $(WIFI_DIR)
	@echo "$(INFO) Install complete"

# Uninstall the script
uninstall:
	@echo "$(INFO) Removing $(INSTALL_DIR)/$(SCRIPT)"
	rm -f $(INSTALL_DIR)/$(SCRIPT)
	@echo "$(INFO) Uninstall complete"

# Remove saved credentials only when explicitly requested.
purge: uninstall
	@echo "$(INFO) Removing wifi configuration directory $(WIFI_DIR)"
	rm -rf $(WIFI_DIR)

# Clean up any temporary files
clean:
	@echo "$(INFO) Cleaning up temporary files"
	rm -f *~
	@echo "$(INFO) Clean complete"

# Display help
help:
	@printf "Usage:\n  make all        - Install the script\n  make install    - Install the script\n  make uninstall  - Uninstall and preserve saved credentials\n  make purge      - Uninstall and remove saved credentials\n  make test       - Check the Perl script syntax\n  make clean      - Clean up temporary files\n  make help       - Display this help message\n"

# Static check: verify that the script compiles.
test:
	@echo "$(INFO) Checking $(SCRIPT_SRC) syntax"
	@perl -c $(SCRIPT_SRC)

.PHONY: all install uninstall purge clean help test
