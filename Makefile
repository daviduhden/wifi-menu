# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Variables
SCRIPT = wifi-menu
SCRIPT_SRC = $(SCRIPT).pl
SCRIPT_PATH = ${.PARSEDIR}/${SCRIPT_SRC}
INSTALL_DIR = /usr/local/bin
WIFI_DIR = /etc/wifi_saved
INFO = ==>

# Default target
all: install

# Install the script
install: $(SCRIPT_PATH)
	@echo "$(INFO) Making $(SCRIPT_SRC) executable" && chmod +x $(SCRIPT_PATH)
	@echo "$(INFO) Installing $(SCRIPT) -> $(INSTALL_DIR)/$(SCRIPT)" && install -m 755 $(SCRIPT_PATH) $(INSTALL_DIR)/$(SCRIPT)
	@echo "$(INFO) Ensuring wifi directory $(WIFI_DIR) exists" && [ -d $(WIFI_DIR) ] || mkdir -m 700 $(WIFI_DIR)
	@echo "$(INFO) Install complete"

# Uninstall the script
uninstall:
	@echo "$(INFO) Removing $(INSTALL_DIR)/$(SCRIPT)"
	rm -f $(INSTALL_DIR)/$(SCRIPT)
	@echo "$(INFO) Removing wifi configuration directory $(WIFI_DIR)"
	rm -rf $(WIFI_DIR)
	@echo "$(INFO) Uninstall complete"

# Clean up any temporary files
clean:
	@echo "$(INFO) Cleaning up temporary files"
	rm -f *~
	@echo "$(INFO) Clean complete"

# Display help
help:
	@printf "Usage:\n  make all        - Install the script\n  make install    - Install the script\n  make uninstall  - Uninstall the script\n  make clean      - Clean up temporary files\n  make help       - Display this help message\n"

test:
	@echo "$(INFO) No automated tests defined"

.PHONY: all install uninstall clean help test