#!/usr/bin/perl

# Interactive Wi-Fi network manager for OpenBSD
#
# Features:
#  - Detects available Wi-Fi interfaces and prompts when multiple exist
#  - Scans networks on the selected interface and lets you choose an SSID
#  - Prompts for a passphrase when the network is secured
#  - Saves configurations for reuse and allows selection from saved entries
#  - Applies interface settings and requests a DHCP lease
# Usage:
#   wifi-menu.pl
#
# See the LICENSE file at the top of the project tree for copyright
# and license details.

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

# --- Global variables ---
our $INT      = '';                   # Interface selected interactively
our $WIFI_DIR = "/etc/wifi_saved";    # Directory to save wifi configurations

# --- Binary paths ---
our $IFCONFIG    = "/sbin/ifconfig";
our $ROUTE       = "/sbin/route";
our $CP          = "/bin/cp";
our $DHCPCONTROL = "/usr/sbin/dhcpleasectl";
our $RCCTL       = "/usr/sbin/rcctl";

sub setup_sandbox {
    my ($ifc) = @_;
    return unless $^O eq 'openbsd';

    # Unveil only the binaries and paths needed for wifi setup.
    eval {
        require OpenBSD::Pledge;
        require OpenBSD::Unveil;

        my @rx_paths =
          ( $IFCONFIG, $ROUTE, $CP, $DHCPCONTROL, $RCCTL, '/bin/sh' );
        my @r_paths   = ( '/etc', '/dev' );
        my @rwc_paths = ( $WIFI_DIR, '/tmp' );

        for my $p (@rx_paths) {
            OpenBSD::Unveil::unveil( $p, 'rx' );
        }
        for my $p (@r_paths) {
            OpenBSD::Unveil::unveil( $p, 'r' );
        }
        for my $p (@rwc_paths) {
            OpenBSD::Unveil::unveil( $p, 'rwc' );
        }
        if ( defined $ifc && length $ifc ) {
            OpenBSD::Unveil::unveil( "/etc/hostname.$ifc", 'rwc' );
        }

        OpenBSD::Unveil::unveil();
        OpenBSD::Pledge::pledge('stdio rpath wpath cpath fattr proc exec unix')
          or die "pledge failed";
        1;
    } or do {
        logw("OpenBSD pledge/unveil setup failed: $@");
    };
}

# --- Wi-Fi interface discovery ---
sub list_wifi_interfaces {
    my @group = ('wlan');
    my %seen;
    my @ifs;

    for my $grp (@group) {
        my $output = `$IFCONFIG -g $grp 2>/dev/null`;
        foreach my $line ( split /\n/, $output ) {
            if ( $line =~ /^([\w.-]+):/ ) {
                my $ifc = $1;
                next if $seen{$ifc};

                # Validate interface exists/configurable
                if ( system("$IFCONFIG $ifc >/dev/null 2>&1") == 0 ) {
                    push @ifs, $ifc;
                    $seen{$ifc} = 1;
                }
            }
        }
    }

    return @ifs;
}

sub choose_interface {
    my (@ifs) = @_;

    if ( !@ifs ) {
        die_tool("No Wi-Fi interfaces found (group wlan in ifconfig)");
    }

    if ( @ifs == 1 ) {
        logi("Using detected Wi-Fi interface: $ifs[0]");
        return $ifs[0];
    }

    logi("Available Wi-Fi interfaces:");
    my %map;
    my $i = 1;
    foreach my $iface (@ifs) {
        print "$i) $iface\n";
        $map{$i} = $iface;
        $i++;
    }

    print "\nChoose interface (number) or press Enter to cancel: ";
    chomp( my $choice = <STDIN> );
    return               if !$choice;
    return $map{$choice} if exists $map{$choice};
    die_tool("Invalid interface selection");
}

sub ensure_interface_available {
    my ($ifc) = @_;
    if ( system("$IFCONFIG $ifc >/dev/null 2>&1") != 0 ) {
        die_tool("Interface $ifc is not available");
    }
}

sub ensure_default_route {
    my ($ifc) = @_;
    return if system("$ROUTE -n get default >/dev/null 2>&1") == 0;
    if ( system("$ROUTE -n add default -iface $ifc >/dev/null 2>&1") != 0 ) {
        logw("Failed to set default route via $ifc");
    }
}

# --- Check for root privileges and interface selection ---
sub check_root_and_interface {
    if ( $> != 0 ) {
        loge("This script must be run as root");
    }
    while (1) {
        my @ifs = list_wifi_interfaces();
        if ( !@ifs ) {
            die_tool("No Wi-Fi interfaces found (group wlan in ifconfig)");
        }

        my @ordered;
        if ( @ifs == 1 ) {
            @ordered = @ifs;
        }
        else {
            my $selected = choose_interface(@ifs);
            if ( !defined $selected ) {
                logi("Exiting.");
                exit 0;
            }
            @ordered = ( $selected, grep { $_ ne $selected } @ifs );
        }

        for my $ifc (@ordered) {
            next if system("$IFCONFIG $ifc up >/dev/null 2>&1") != 0;
            $INT = $ifc;
            ensure_interface_available($INT);
            return;
        }

        logw("No Wi-Fi interfaces could be brought up; choose another.");
    }
}

# --- Clear existing wireless settings before reconfigure ---
sub clear_wireless_settings {
    my $result = system(
        "$IFCONFIG $INT -inet6 -inet -bssid -chan -nwid -nwkey -wpa -wpakey");
    if ( $result != 0 ) {
        loge("Failed to clear wireless settings on $INT");
    }
}

# --- Subroutine: read_saved (load or create config) ---
sub read_saved {

    my $dh;

    # Attempt to open the directory containing saved Wi-Fi configurations.
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

# --- Subroutine: conf_create (scan and build config) ---
sub conf_create {

    my $result;

    # Bring the interface up before scanning.
    $result = system("$IFCONFIG $INT up");
    if ( $result != 0 ) {
        return;
    }

    logi("Scanning for wifi networks on interface $INT...");
    my $scan_output = `$IFCONFIG $INT scan 2>/dev/null`;
    if ( $? != 0 ) {
        loge("Failed to scan for wifi networks on $INT");
    }
    my @networks;
    foreach my $line ( split /\n/, $scan_output ) {
        if ( $line =~ /nwid\s+(\S+)/ ) {
            my $id = $1;
            next if $id eq '""' || $id eq '"' || $id eq '';   # skip empty SSIDs
            push @networks, $id;    # Extract network IDs (SSIDs)
        }
    }
    if ( !@networks ) {
        loge("No available Wi-Fi connections found on $INT");
    }

    logi("Available wifi networks:");
    my %list;
    my $i = 1;
    foreach my $net (@networks) {
        print "$i) $net\n";
        $list{$i} = $net;    # Map network index to SSID
        $i++;
    }
    print "\nChoose a Wi-Fi network or press Enter to quit: ";
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

    # Use "join" for WPA networks, otherwise "nwid" for open networks.
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

# --- Subroutine: saved_connect (connect using saved config) ---
sub saved_connect {
    my ($conf_file) = @_;
    logi("Connecting using saved configuration file \"$conf_file\"");
    my $result = system("$IFCONFIG $INT up");
    if ( $result != 0 ) {
        return;
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

    # Request a new DHCP lease using dhcpleasectl.
    $result = system("$DHCPCONTROL -w 10 $INT");
    if ( $result != 0 ) {
        loge("Failed to request DHCP lease on $INT using dhcpleasectl");
    }
    ensure_default_route($INT);

    $result = system("$RCCTL restart unbound");
    if ( $result != 0 ) {
        loge("Failed to restart unbound service");
    }
    exit 0;
}

# --- Subroutine: connect (apply config and DHCP) ---
sub wifi_connect {
    my ( $ssid, $password, $config_mode ) = @_;
    my $result;
    logi("Connecting using configuration for \"$ssid\"");
    $result = system("$IFCONFIG $INT up");
    if ( $result != 0 ) {
        return;
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

    # Request a new DHCP lease using dhcpleasectl.
    $result = system("$DHCPCONTROL -w 10 $INT");
    if ( $result != 0 ) {
        print STDERR
"[!] ${RED}Failed to request DHCP lease on $INT using dhcpleasectl${RESET}\n";
        exit 1;
    }
    ensure_default_route($INT);

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

# Main script execution
sub main {
    print_banner();
    check_root_and_interface();

    unless ( -d $WIFI_DIR ) {
        make_path( $WIFI_DIR, { mode => 0600 } )
          or die_tool "Cannot create directory $WIFI_DIR: $!";
    }

    setup_sandbox($INT);
    clear_wireless_settings();
    read_saved();
}

main();
