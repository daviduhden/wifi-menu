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

# --- Logging ---
my $no_color  = 0;
my $is_tty    = ( -t STDOUT )             ? 1 : 0;
my $use_color = ( !$no_color && $is_tty ) ? 1 : 0;

my ( $GREEN, $YELLOW, $RED, $CYAN, $BOLD, $GRY, $RESET ) =
  ( "", "", "", "", "", "", "" );
if ($use_color) {
    $GREEN  = "\e[32m";
    $YELLOW = "\e[33m";
    $RED    = "\e[31m";
    $CYAN   = "\e[36m";
    $BOLD   = "\e[1m";
    $GRY    = "\e[90m";
    $RESET  = "\e[0m";
}

sub logi { print "${GREEN}✅ [INFO]${RESET} $_[0]\n"; }
sub logw { print STDERR "${YELLOW}⚠️ [WARN]${RESET} $_[0]\n"; }
sub loge { print STDERR "${RED}❌ [ERROR]${RESET} $_[0]\n"; }

sub die_tool {
    my ($msg) = @_;
    loge($msg);
    exit 1;
}

# --- Wi-Fi interfaces discovery ---
sub list_wifi_interfaces {
    my $output = `$IFCONFIG -g wifi 2>/dev/null`;
    my @ifs;

    foreach my $line ( split /\n/, $output ) {
        if ( $line =~ /^([\w.-]+):/ ) {
            push @ifs, $1;
        }
    }

    return @ifs;
}

sub choose_interface {
    my @ifs = list_wifi_interfaces();

    if ( !@ifs ) {
        die_tool("No se encontraron interfaces Wi-Fi (grupo 'wifi' en ifconfig)");
    }

    if ( @ifs == 1 ) {
        logi("Usando interfaz Wi-Fi detectada: $ifs[0]");
        return $ifs[0];
    }

    logi("Interfaces Wi-Fi disponibles:");
    my %map;
    my $i = 1;
    foreach my $iface (@ifs) {
        print "$i) $iface\n";
        $map{$i} = $iface;
        $i++;
    }

    print "\nElige interfaz (número) o pulsa Enter para cancelar: ";
    chomp( my $choice = <STDIN> );
    if ( !$choice || !exists $map{$choice} ) {
        die_tool("Interfaz no seleccionada");
    }

    return $map{$choice};
}

# --- Global variables ---
my $INT      = $ARGV[0] // '';       # Network interface passed as argument
my $WIFI_DIR = "/etc/wifi_saved";    # Directory to save wifi configurations

# --- Binary paths ---
my $IFCONFIG    = "/sbin/ifconfig";
my $CP          = "/bin/cp";
my $DHCPCONTROL = "/usr/sbin/dhcpleasectl";
my $RCCTL       = "/usr/sbin/rcctl";

# --- Check for root privileges and interface argument ---
sub check_root_and_interface {
    if ( $> != 0 ) {
        loge("This script must be run as root");
    }
    if ( !$INT ) {
        $INT = choose_interface();
    }
}

# --- Clear wireless settings ---
sub clear_wireless_settings {
    my $result = system(
        "$IFCONFIG $INT -inet6 -inet -bssid -chan -nwid -nwkey -wpa -wpakey");
    if ( $result != 0 ) {
        loge("Failed to clear wireless settings on $INT");
    }
}

# --- Subroutine: read_saved ---
sub read_saved {

	my $dh;

    # Attempt to open the directory containing saved wifi configurations
    unless ( opendir( $dh, $WIFI_DIR ) ) {
        logw("No saved wifi configuration directory found; creating $WIFI_DIR");
        make_path( $WIFI_DIR, { mode => 0600 } );
        return conf_create();
    }
    my @saved_files =
      grep { !/^\./ } readdir($dh);    # Get list of saved configuration files
    closedir($dh);

    if ( !@saved_files ) {
        logw("There are no previously saved wifi connections");
        return conf_create();
    }

    logi("Saved wifi configurations:");
    my %file;
    my $i = 1;
    foreach my $f (@saved_files) {
        print "$i) $f\n";
        $file{$i} = $f;    # Map file index to file name
        $i++;
    }
    print
"\nChoose a previously saved wifi connection or press Enter to create a new one: ";
    chomp( my $choice = <STDIN> );
    if ( !$choice or !exists $file{$choice} ) {
        return conf_create();
    }
    logi("\"$file{$choice}\" is selected");
    return saved_connect( $file{$choice} );
}

# --- Subroutine: conf_create ---
sub conf_create {

    my $result;

    # Bring the interface up
    $result = system("$IFCONFIG $INT up");
    if ( $result != 0 ) {
        loge("Failed to bring interface $INT up");
    }

    logi("Scanning for wifi networks on interface $INT...");
    my $scan_output = `$IFCONFIG $INT scan 2>/dev/null`;
    if ( $? != 0 ) {
        loge("Failed to scan for wifi networks on $INT");
    }
    my @networks;
    foreach my $line ( split /\n/, $scan_output ) {
        if ( $line =~ /nwid\s+(\S+)/ ) {
            push @networks, $1;    # Extract network IDs (SSIDs)
        }
    }
    if ( !@networks ) {
        loge("No available wifi connections found on $INT");
    }

    logi("Available wifi networks:");
    my %list;
    my $i = 1;
    foreach my $net (@networks) {
        print "$i) $net\n";
        $list{$i} = $net;    # Map network index to SSID
        $i++;
    }
    print "\nChoose a wifi connection or press Enter to quit: ";
    chomp( my $choice = <STDIN> );
    if ( !$choice or !exists $list{$choice} ) {
        logw("Exiting");
        exit 1;
    }
    my $ssid = $list{$choice};
    print "Enter the passphrase for \"$ssid\" (leave empty if open network): ";
    ReadMode('noecho');
    chomp( my $password = <STDIN> );
    ReadMode('restore');
    print "\n";
    if ( length($password) > 0 && length($password) < 8 ) {
        loge("Passphrase must be between 8 and 63 characters for WPA networks");
    }

    print "\nDo you want to configure Host-based Access Point mode? (y/N): ";
    chomp( my $hostap_choice = <STDIN> );
    my $hostap_config = "";
    if ( lc($hostap_choice) eq 'y' ) {
        $hostap_config = "mode 11g mediaopt hostap\n";
    }

    # Use "join" if a passphrase is provided, otherwise "nwid"
    my $config_mode = ( length($password) > 0 ) ? "join" : "nwid";
    my $wpa_line    = ( length($password) > 0 ) ? " wpakey \"$password\"" : "";

    my $config = <<"EOF";
$config_mode "$ssid"$wpa_line
$hostap_config
inet autoconf
EOF

    my $conf_file = "$WIFI_DIR/$ssid.$INT";
    open( my $fh, '>', $conf_file ) or do {
        loge("Cannot write to $conf_file: $!");
    };
    print $fh $config;
    close($fh);
    chmod 0600, $conf_file
      or warn "Could not set permissions on $conf_file: $!";

    logi("Creating new configuration using \"$ssid\"");
    return connect_wifi( $ssid, $password, $config_mode );
}

# --- Subroutine: saved_connect ---
sub saved_connect {
    my ($conf_file) = @_;
    logi("Connecting using saved configuration file \"$conf_file\"");
    my $result = system("$IFCONFIG $INT up");
    if ( $result != 0 ) {
        loge("Failed to bring interface $INT up");
    }

    my ( $mode, $ssid, $wpakey );
    open( my $fh, '<', "$WIFI_DIR/$conf_file" )
      or loge("Cannot open $WIFI_DIR/$conf_file: $!");
    while ( my $line = <$fh> ) {
        if ( $line =~ /^(join|nwid)\s+"([^"]+)"(?:\s+wpakey\s+"([^"]+)")?/ ) {
            $mode   = $1;
            $ssid   = $2;
            $wpakey = $3;    # may be undefined for open networks
        }
    }
    close($fh);
    unless ( defined $mode and defined $ssid ) {
        loge("Invalid configuration file. Exiting.");
    }

    if ( defined $wpakey ) {
        $result = system("$IFCONFIG $INT join \"$ssid\" wpakey \"$wpakey\"");
    }
    else {
        $result = system("$IFCONFIG $INT nwid \"$ssid\"");
    }
    if ( $result != 0 ) {
        loge("Failed to join wifi network $ssid");
    }

    $result = system("$CP \"$WIFI_DIR/$conf_file\" /etc/hostname.$INT");
    if ( $result != 0 ) {
        loge("Failed to copy configuration file");
    }
    logi("Configured interface $INT; ESSID is \"$ssid\"");

# Request a new DHCP lease using dhcpleasectl (instead of directly running dhcpleased)
    $result = system("$DHCPCONTROL -w 10 $INT");
    if ( $result != 0 ) {
        loge("Failed to request DHCP lease on $INT using dhcpleasectl");
    }

    $result = system("$RCCTL restart unbound");
    if ( $result != 0 ) {
        loge("Failed to restart unbound service");
    }
    exit 0;
}

# --- Subroutine: connect ---
sub wifi_connect {
    my ( $ssid, $password, $config_mode ) = @_;
    my $result;
    logi("Connecting using configuration for \"$ssid\"");
    $result = system("$IFCONFIG $INT up");
    if ( $result != 0 ) {
        print STDERR "[!] ${RED}Failed to bring interface $INT up${RESET}\n";
        exit 1;
    }

    if ( $config_mode eq "join" ) {
        $result = system("$IFCONFIG $INT join \"$ssid\" wpakey \"$password\"");
    }
    else {
        $result = system("$IFCONFIG $INT nwid \"$ssid\"");
    }
    if ( $result != 0 ) {
        print STDERR "[!] ${RED}Failed to join wifi network $ssid${RESET}\n";
        exit 1;
    }

    my $conf_file = "$WIFI_DIR/$ssid.$INT";
    $result = system("$CP \"$conf_file\" /etc/hostname.$INT");
    if ( $result != 0 ) {
        print STDERR
"[!] ${RED}Failed to copy configuration file to /etc/hostname.$INT${RESET}\n";
        exit 1;
    }
    print
"[+] ${CYAN}Configured interface ${YELLOW}$INT${CYAN}; ESSID is ${YELLOW}\"$ssid\"${RESET}\n";

    # Request a new DHCP lease using dhcpleasectl
    $result = system("$DHCPCONTROL -w 10 $INT");
    if ( $result != 0 ) {
        print STDERR
"[!] ${RED}Failed to request DHCP lease on $INT using dhcpleasectl${RESET}\n";
        exit 1;
    }

    $result = system("$RCCTL restart unbound");
    if ( $result != 0 ) {
        print STDERR "[!] ${RED}Failed to restart unbound service${RESET}\n";
        exit 1;
    }
    exit 0;
}

# Alias to avoid clashing with built-in connect()
sub connect_wifi {
    wifi_connect(@_);
}

# --- Banner ---
sub print_banner {
    print "\n$GREEN   .;'                     `;,            \n";
    print
"$GREEN  .;'  ,;'             `;,  `;,    OpenBSD wireless network manager\n";
    print "$GREEN .;'  ,;'  ,;'     `;,  `;,  `;,        \n";
    print "$GREEN ::   ::   :   $GRY( ) $GREEN  :   ::   ::   \n";
    print "$GREEN ':.  ':.  ':. $GRY/_\\ $GREEN,:'  ,:'  ,:'  \n";
    print "$GREEN  ':.  ':.    $GRY/___\\ $GREEN   ,:'  ,:'   \n";
    print "$GREEN   ':.       $GRY/_____\\ $GREEN     ,:'     \n";
    print "$GREEN            $GRY/       \\ $GREEN    $RESET\n\n";
}

# --- Main Execution ---
sub main {
    print_banner();
    check_root_and_interface();
    clear_wireless_settings();

    unless ( -d $WIFI_DIR ) {
        make_path( $WIFI_DIR, { mode => 0600 } )
          or die_tool "Cannot create directory $WIFI_DIR: $!";
    }

    read_saved();
}

main();
