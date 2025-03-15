# OpenBSD Wireless Network Manager

## Overview

This script helps manage wireless network connections on OpenBSD. It allows you to save, list, and connect to Wi-Fi networks using a simple menu interface.

## Features

- Displays available Wi-Fi networks.
- Stores network configurations for future use.
- Connects to both saved and new networks.
- Randomizes the MAC address for enhanced privacy.
- Configures the interface as a Host-based Access Point.

## Requirements

- Must be run as root.
- [OpenBSD operating system](https://www.openbsd.org/faq/faq4.html#Download).

## Usage

1. Clone the repository:
    ```sh
    git clone https://github.com/daviduhden/wifi-menu.git
    cd wifi-menu
    ```

2. Make the script executable:
    ```sh
    chmod +x wifi-menu
    ```

3. Run the script:
    ```sh
    perl wifi-menu <interface>
    ```

4. Follow the interactive prompts to apply the desired configurations.

## Notes

- Ensure the Wi-Fi configuration directory (`/etc/wifi_saved`) exists with proper permissions.
- The script must be run as root to modify network settings.
- The passphrase for WPA networks must be between 8 and 63 characters.
- The script supports configuring the interface as a Host-based Access Point.
