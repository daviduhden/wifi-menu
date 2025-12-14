# See the LICENSE file at the top of the project tree for copyright
# and license details.

# Variables
SCRIPT = wifi-menu
SCRIPT_SRC = $(SCRIPT).pl
INSTALL_DIR = /usr/local/bin
WIFI_DIR = /etc/wifi_saved

# Default target
all: install

# Install the script
install: $(SCRIPT_SRC)
	@echo "Making $(SCRIPT_SRC) executable"
	chmod +x $(SCRIPT_SRC)
	@echo "Installing $(SCRIPT) to $(INSTALL_DIR)"
	install -m 755 $(SCRIPT_SRC) $(INSTALL_DIR)/$(SCRIPT)
	@echo "Creating wifi configuration directory $(WIFI_DIR) if it doesn't exist"
	[ -d $(WIFI_DIR) ] || mkdir -m 700 $(WIFI_DIR)

# Uninstall the script
uninstall:
	@echo "Removing $(INSTALL_DIR)/$(SCRIPT)"
	rm -f $(INSTALL_DIR)/$(SCRIPT)
	@echo "Removing wifi configuration directory $(WIFI_DIR)"
	rm -rf $(WIFI_DIR)

# Clean up any temporary files
clean:
	@echo "Cleaning up..."
	rm -f *~

# Display help
help:
	@echo "Usage:"
	@echo "  make all        - Install the script"
	@echo "  make install    - Install the script"
	@echo "  make uninstall  - Uninstall the script"
	@echo "  make clean      - Clean up temporary files"
	@echo "  make help       - Display this help message"

.PHONY: all install uninstall clean help
