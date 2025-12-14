#!/usr/bin/perl

# Copyright (c) 2025 David Uhden Collado <david@uhden.dev>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use warnings;
use Term::ReadKey;
use File::Path qw(make_path);
use File::Copy;
use Cwd;

my $GREEN = "\e[32m";
my $YELLOW = "\e[33m";
my $RED = "\e[31m";
my $CYAN = "\e[36m";
my $BOLD = "\e[1m";
my $RESET = "\e[0m";

sub log {
    my ($msg) = @_;
    print "${GREEN}✅ [INFO]${RESET} $msg\n";
}

sub warn {
    my ($msg) = @_;
    print STDERR "${YELLOW}⚠️  [WARN]${RESET} $msg\n";
}

sub error {
    my ($msg, $code) = @_;
    $code //= 1;
    print STDERR "${RED}❌ [ERROR]${RESET} $msg\n";
    exit $code;
}

# Backward-compatible aliases
sub info     { log(@_); }
sub warn_msg { warn(@_); }

# --- Global variables ---
my $INT = $ARGV[0] // '';  # Network interface passed as argument
my $WIFI_DIR = "/etc/wifi_saved";  # Directory to save wifi configurations

# --- Binary paths ---
my $IFCONFIG = "/sbin/ifconfig";
my $CP = "/bin/cp";
my $DHCPCONTROL = "/usr/sbin/dhcpleasectl";
my $RCCTL = "/usr/sbin/rcctl";

# --- Check for root privileges and interface argument ---
sub check_root_and_interface {
    if ($> != 0) {
        error("This script must be run as root");
    }
    if (!$INT) {
        error("Usage: doas $0 [interface]");
    }
}

# --- Clear wireless settings ---
sub clear_wireless_settings {
    my $result = system("$IFCONFIG $INT -inet6 -inet -bssid -chan -nwid -nwkey -wpa -wpakey");
    if ($result != 0) {
        error("Failed to clear wireless settings on $INT");
    }
}

# --- Subroutine: read_saved ---
sub read_saved {
    # Attempt to open the directory containing saved wifi configurations
    unless (opendir(my $dh, $WIFI_DIR)) {
        warn("No saved wifi configuration directory found; creating $WIFI_DIR");
        make_path($WIFI_DIR, { mode => 0600 });
        return conf_create();
    }
    my @saved_files = grep { !/^\./ } readdir($dh);  # Get list of saved configuration files
    closedir($dh);
    
    if (!@saved_files) {
        warn("There are no previously saved wifi connections");
        return conf_create();
    }
    
    log("Saved wifi configurations:");
    my %file;
    my $i = 1;
    foreach my $f (@saved_files) {
        print "$i) $f\n";
        $file{$i} = $f;  # Map file index to file name
        $i++;
    }
    print "\nChoose a previously saved wifi connection or press Enter to create a new one: ";
    chomp(my $choice = <STDIN>);
    if (!$choice or !exists $file{$choice}) {
        return conf_create();
    }
    log("\"$file{$choice}\" is selected");
    return saved_connect($file{$choice});
}

# --- Subroutine: conf_create ---
sub conf_create {
    # Bring the interface up
    $result = system("$IFCONFIG $INT up");
    if ($result != 0) {
        error("Failed to bring interface $INT up");
    }
    # No se mata dhcpleased; en versiones modernas se utiliza dhcpleasectl para renovar el lease.
    
    log("Scanning for wifi networks on interface $INT...");
    my $scan_output = `$IFCONFIG $INT scan 2>/dev/null`;
    if ($? != 0) {
        error("Failed to scan for wifi networks on $INT");
    }
    my @networks;
    foreach my $line (split /\n/, $scan_output) {
        if ($line =~ /nwid\s+(\S+)/) {
            push @networks, $1;  # Extract network IDs (SSIDs)
        }
    }
    if (!@networks) {
        error("No available wifi connections found on interface $INT");
    }
    
    log("Available wifi networks:");
    my %list;
    my $i = 1;
    foreach my $net (@networks) {
        print "$i) $net\n";
        $list{$i} = $net;  # Map network index to SSID
        $i++;
    }
    print "\nChoose a wifi connection or press Enter to quit: ";
    chomp(my $choice = <STDIN>);
    if (!$choice or !exists $list{$choice}) {
        warn("Exiting");
        exit 1;
    }
    my $ssid = $list{$choice};
    print "Enter the passphrase for \"$ssid\" (leave empty if open network): ";
    ReadMode('noecho');
    chomp(my $password = <STDIN>);
    ReadMode('restore');
    print "\n";
    if (length($password) > 0 && length($password) < 8) {
        error("Passphrase must be between 8 and 63 characters for WPA networks");
    }
    
    print "\nDo you want to configure Host-based Access Point mode? (y/N): ";
    chomp(my $hostap_choice = <STDIN>);
    my $hostap_config = "";
    if (lc($hostap_choice) eq 'y') {
        $hostap_config = "mode 11g mediaopt hostap\n";
    }
    
    # Use "join" if a passphrase is provided, otherwise "nwid"
    my $config_mode = (length($password) > 0) ? "join" : "nwid";
    my $wpa_line = (length($password) > 0) ? " wpakey \"$password\"" : "";
    
    my $config = <<"EOF";
$config_mode "$ssid"$wpa_line
$hostap_config
inet autoconf
EOF

    my $conf_file = "$WIFI_DIR/$ssid.$INT";
    open(my $fh, '>', $conf_file) or do {
        error("Cannot write to $conf_file: $!");
    };
    print $fh $config;
    close($fh);
    chmod 0600, $conf_file or warn "Could not set permissions on $conf_file: $!";
    
    log("Creating new configuration using \"$ssid\"");
    return connect($ssid, $password, $config_mode);
}

# --- Subroutine: saved_connect ---
sub saved_connect {
    my ($conf_file) = @_;
    log("Connecting using saved configuration file \"$conf_file\"");
    $result = system("$IFCONFIG $INT up");
    if ($result != 0) {
        error("Failed to bring interface $INT up");
    }
    
    my ($mode, $ssid, $wpakey);
    open(my $fh, '<', "$WIFI_DIR/$conf_file") or error("Cannot open $WIFI_DIR/$conf_file: $!");
    while (my $line = <$fh>) {
        if ($line =~ /^(join|nwid)\s+"([^"]+)"(?:\s+wpakey\s+"([^"]+)")?/) {
            $mode = $1;
            $ssid = $2;
            $wpakey = $3;  # may be undefined for open networks
        }
    }
    close($fh);
    unless (defined $mode and defined $ssid) {
        error("Invalid configuration file. Exiting.");
    }
    
    if (defined $wpakey) {
        $result = system("$IFCONFIG $INT join \"$ssid\" wpakey \"$wpakey\"");
    } else {
        $result = system("$IFCONFIG $INT nwid \"$ssid\"");
    }
    if ($result != 0) {
        error("Failed to join wifi network $ssid");
    }
    
    $result = system("$CP \"$WIFI_DIR/$conf_file\" /etc/hostname.$INT");
    if ($result != 0) {
        error("Failed to copy configuration file");
    }
    log("Configured interface $INT; ESSID is \"$ssid\"");
    
    # Request a new DHCP lease using dhcpleasectl (instead of directly running dhcpleased)
    $result = system("$DHCPCONTROL -w 10 $INT");
    if ($result != 0) {
        error("Failed to request DHCP lease on $INT using dhcpleasectl");
    }
    
    $result = system("$RCCTL restart unbound");
    if ($result != 0) {
        error("Failed to restart unbound service");
    }
    exit 0;
}

# --- Subroutine: connect ---
sub connect {
    my ($ssid, $password, $config_mode) = @_;
    log("Connecting using configuration for \"$ssid\"");
    $result = system("$IFCONFIG $INT up");
    if ($result != 0) {
        print STDERR "[!] ${RED}Failed to bring interface $INT up${RST}\n";
        exit 1;
    }
    
    if ($config_mode eq "join") {
        $result = system("$IFCONFIG $INT join \"$ssid\" wpakey \"$password\"");
    } else {
        $result = system("$IFCONFIG $INT nwid \"$ssid\"");
    }
    if ($result != 0) {
        print STDERR "[!] ${RED}Failed to join wifi network $ssid${RST}\n";
        exit 1;
    }
    
    my $conf_file = "$WIFI_DIR/$ssid.$INT";
    $result = system("$CP \"$conf_file\" /etc/hostname.$INT");
    if ($result != 0) {
        print STDERR "[!] ${RED}Failed to copy configuration file to /etc/hostname.$INT${RST}\n";
        exit 1;
    }
    print "[+] ${BLU}Configured interface ${YLW}$INT${BLU}; ESSID is ${YLW}\"$ssid\"${RST}\n";
    
    # Request a new DHCP lease using dhcpleasectl
    $result = system("$DHCPCONTROL -w 10 $INT");
    if ($result != 0) {
        print STDERR "[!] ${RED}Failed to request DHCP lease on $INT using dhcpleasectl${RST}\n";
        exit 1;
    }
    
    $result = system("$RCCTL restart unbound");
    if ($result != 0) {
        print STDERR "[!] ${RED}Failed to restart unbound service${RST}\n";
        exit 1;
    }
    exit 0;
}

# --- Banner ---
sub print_banner {
    print "\n$GRN   .;'                     `;,            \n";
    print "$GRN  .;'  ,;'             `;,  `;,    OpenBSD wireless network manager\n";
    print "$GRN .;'  ,;'  ,;'     `;,  `;,  `;,        \n";
    print "$GRN ::   ::   :   $GRY( ) $GRN  :   ::   ::   \n";
    print "$GRN ':.  ':.  ':. $GRY/_\\ $GRN,:'  ,:'  ,:'  \n";
    print "$GRN  ':.  ':.    $GRY/___\\ $GRN   ,:'  ,:'   \n";
    print "$GRN   ':.       $GRY/_____\\ $GRN     ,:'     \n";
    print "$GRN            $GRY/       \\ $GRN    $RST\n\n";
}

# --- Main Execution ---
sub main {
    print_banner();
    check_root_and_interface();
    clear_wireless_settings();
    
    unless (-d $WIFI_DIR) {
        make_path($WIFI_DIR, { mode => 0600 }) or die "Cannot create directory $WIFI_DIR: $!";
    }
    
    read_saved();
}

main();