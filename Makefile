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
	@[ -n "$(INSTALL_DIR)" ] || { echo "$(INFO) INSTALL_DIR is empty"; exit 1; }; [ -n "$(WIFI_DIR)" ] || { echo "$(INFO) WIFI_DIR is empty"; exit 1; }
	@echo "$(INFO) Installing $(SCRIPT) -> $(INSTALL_DIR)/$(SCRIPT)" && install -d -m 755 "$(INSTALL_DIR)" && install -m 755 "$(SCRIPT_SRC)" "$(INSTALL_DIR)/$(SCRIPT)"
	@echo "$(INFO) Ensuring wifi directory $(WIFI_DIR) exists" && { [ -d "$(WIFI_DIR)" ] || mkdir -m 700 "$(WIFI_DIR)"; } && chmod 700 "$(WIFI_DIR)"
	@echo "$(INFO) Install complete"

# Uninstall the script
uninstall:
	@echo "$(INFO) Removing $(INSTALL_DIR)/$(SCRIPT)"
	@rm -f -- "$(INSTALL_DIR)/$(SCRIPT)"
	@echo "$(INFO) Uninstall complete"

# Remove saved credentials and backups only when explicitly requested.
purge: uninstall
	@case "$(WIFI_DIR)" in ""|"/"|"."|"..") echo "$(INFO) Refusing unsafe WIFI_DIR=$(WIFI_DIR)"; exit 1;; esac
	@echo "$(INFO) Removing wifi configuration directory $(WIFI_DIR)"
	@rm -rf -- "$(WIFI_DIR)"
	@rm -f -- /etc/hostname.*.wifi-menu.old && rm -f -- /etc/.hostname.*.wifi-menu.*
	@echo "$(INFO) Active /etc/hostname.* files are preserved" && echo "$(INFO) Purge complete"

# Remove editor backup files
clean:
	@echo "$(INFO) Cleaning up editor backup files"
	@rm -f -- *~
	@echo "$(INFO) Clean complete"

# Display help
help:
	@printf "Usage:\n  make all               - Install the script\n  make install           - Install the script\n  make uninstall         - Uninstall and preserve saved credentials\n  make purge             - Uninstall, remove saved credentials and backups\n  make test              - Check the Perl script syntax\n  make check-agent-sync  - Enforce agent and skills maintenance\n  make clean             - Remove editor backup files\n  make help              - Display this help message\n"

# Static check: verify that the script parses.
test:
	@echo "$(INFO) Checking $(SCRIPT_SRC) syntax"
	@perl -c $(SCRIPT_SRC)

# Enforce a substantive instruction update for every repository change.
check-agent-sync:
	@perl scripts/check-agent-sync.pl

.PHONY: all install uninstall purge clean help test check-agent-sync
