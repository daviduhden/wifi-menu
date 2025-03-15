# Variables
SCRIPT = wifi-menu
INSTALL_DIR = /usr/local/bin
WIFI_DIR = /etc/wifi_saved

# Default target
all: install

# Install the script
install:
	@echo "Making $(SCRIPT) executable"
	chmod +x $(SCRIPT)
	@echo "Installing $(SCRIPT) to $(INSTALL_DIR)"
	install -m 755 $(SCRIPT) $(INSTALL_DIR)/$(SCRIPT)
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
