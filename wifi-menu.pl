#!/usr/bin/perl
use strict;
use warnings;
use Term::ReadKey;
use File::Path qw(make_path);
use File::Copy;
use Cwd;

# --- Color definitions (ANSI escape sequences) ---
my $RED = "\033[0;31m";
my $BLU = "\033[1;34m";
my $YLW = "\033[1;33m";
my $RST = "\033[0m";
my $GRN = "\033[32m";
my $GRY = "\033[37m";

# --- Global variables ---
my $INT      = $ARGV[0] // '';
my $WIFI_DIR = "/etc/wifi_saved";

# --- Check for root privileges and interface argument ---
if ($> != 0) {
    print STDERR "[!] ${RED}This script must be run as root${RST}\n";
    exit 1;
}
if (!$INT) {
    print STDERR "[!] ${RED}Usage: doas $0 [interface]${RST}\n";
    exit 1;
}

# --- Subroutine: read_saved ---
# Clears the current wireless settings (per OpenBSD ifconfig(8) docs) and then
# looks for previously saved wifi configurations. If none are found, it calls conf_create.
sub read_saved {
    # Clear wireless settings and randomize MAC address
    system("/sbin/ifconfig $INT -inet6 -inet -bssid -chan -nwid -nwkey -wpa -wpakey");
    system("/sbin/ifconfig $INT lladdr random");

    # Read list of saved configurations
    opendir(my $dh, $WIFI_DIR) or do {
        print "[*] ${YLW}No saved wifi configuration directory found; creating $WIFI_DIR${RST}\n";
        make_path($WIFI_DIR, { mode => 0600 });
        return conf_create();
    };
    my @saved_files = grep { !/^\./ } readdir($dh);
    closedir($dh);

    if (!@saved_files) {
        print "[*] ${YLW}There are no previously saved wifi connections${RST}\n${RST}";
        return conf_create();
    }

    # List saved configurations with index numbers
    print "\nSaved wifi configurations:\n";
    my %file;
    my $i = 1;
    foreach my $f (@saved_files) {
        print "$i) $f\n";
        $file{$i} = $f;
        $i++;
    }
    print "\n[+] ${BLU}Choose a previously saved wifi connection or press ${YLW}Enter${BLU} to create a new one: ${RST}";
    chomp(my $choice = <STDIN>);
    if (!$choice or !exists $file{$choice}) {
        return conf_create();
    }
    print "[+] ${YLW}\"$file{$choice}\"${BLU} is selected${RST}\n";
    return saved_connect($file{$choice});
}

# --- Subroutine: conf_create ---
# Brings the interface up, scans for available networks using ifconfig's scan option,
# and then prompts the user to choose an SSID and enter its WPA passphrase.
sub conf_create {
    system("/sbin/ifconfig $INT up");
    system("/usr/bin/pkill dhclient");

    # Scan for available wifi networks.
    print "[*] ${BLU}Scanning for wifi networks on interface $INT...${RST}\n";
    my $scan_output = `/sbin/ifconfig $INT scan 2>/dev/null`;
    my @networks;
    foreach my $line (split /\n/, $scan_output) {
        # Extract the network ID from lines that contain "nwid"
        if ($line =~ /nwid\s+(\S+)/) {
            push @networks, $1;
        }
    }
    if (!@networks) {
        print "[!] ${RED}No available wifi connections found on interface $INT${RST}\n";
        exit 1;
    }

    # List available networks
    print "\nAvailable wifi networks:\n";
    my %list;
    my $i = 1;
    foreach my $net (@networks) {
        print "$i) $net\n";
        $list{$i} = $net;
        $i++;
    }
    print "\n[+] ${BLU}Choose a wifi connection or press ${YLW}Enter${BLU} to quit: ${RST}";
    chomp(my $choice = <STDIN>);
    if (!$choice or !exists $list{$choice}) {
        print "[!] ${RED}Exiting${RST}\n";
        exit 1;
    }
    my $ssid = $list{$choice};
    print "[+] ${BLU}Enter the passphrase for ${YLW}\"$ssid\"${BLU}:\n${RST}";
    print "[+] Password: ";
    ReadMode('noecho');
    chomp(my $password = <STDIN>);
    ReadMode('restore');
    print "\n";
    if (length($password) < 8) {
        print "[!] ${RED}wpakey:${YLW} passphrase must be between 8 and 63 characters${RST}\n";
        exit 1;
    }

    # Create configuration file content following the OpenBSD hostname.if format
    my $config = << "EOF";
-inet6 -bssid -chan -nwid -nwkey -wpa -wpakey
nwid "$ssid" lladdr "random"
wpakey "$password"
dhcp
EOF

    # Save the configuration file
    my $conf_file = "$WIFI_DIR/$ssid.$INT";
    open(my $fh, '>', $conf_file) or die "Cannot write to $conf_file: $!";
    print $fh $config;
    close($fh);
    chmod 0600, $conf_file or warn "Could not set permissions on $conf_file: $!";

    print "[+] ${BLU}Creating new configuration using ${YLW}\"$ssid\"${RST}\n";
    return connect($ssid, $password);
}

# --- Subroutine: saved_connect ---
# Reads a previously saved configuration file, extracts the SSID and WPA key,
# and applies it using ifconfig (following OpenBSD documentation recommendations).
sub saved_connect {
    my ($conf_file) = @_;
    print "[+] ${BLU}Connecting using saved configuration file ${YLW}\"$conf_file\"${RST}\n";
    system("/sbin/ifconfig $INT up");
    system("/usr/bin/pkill dhclient");

    # Open the saved file and extract the nwid and wpakey values.
    my ($ssid, $wpakey);
    open(my $fh, '<', "$WIFI_DIR/$conf_file") or die "Cannot open $WIFI_DIR/$conf_file: $!";
    while (my $line = <$fh>) {
        if ($line =~ /^nwid\s+"([^"]+)"/) {
            $ssid = $1;
        }
        if ($line =~ /^wpakey\s+"([^"]+)"/) {
            $wpakey = $1;
        }
    }
    close($fh);
    unless (defined $ssid and defined $wpakey) {
        print "[!] ${RED}Invalid configuration file. Exiting.${RST}\n";
        exit 1;
    }

    # Configure the interface using the saved configuration.
    system("/sbin/ifconfig $INT nwid \"$ssid\" wpakey \"$wpakey\"");
    system("/bin/cp \"$WIFI_DIR/$conf_file\" /etc/hostname.$INT");
    print "[+] ${BLU}Configured interface ${YLW}$INT${BLU}; ESSID is ${YLW}\"$ssid\"${RST}\n";
    print "[+] ${BLU}Interface ${YLW}$INT${BLU} is up${RST}\n";
    print "[+] ${BLU}Running dhclient${RST}\n";
    system("/sbin/dhclient $INT");
    system("/usr/sbin/rcctl restart dnscrypt_proxy unbound");
    exit 0;
}

# --- Subroutine: connect ---
# Uses the newly created configuration to connect to the selected wifi network.
sub connect {
    my ($ssid, $password) = @_;
    print "[+] ${BLU}Connecting using configuration for ${YLW}\"$ssid\"${RST}\n";
    system("/sbin/ifconfig $INT up");
    system("/usr/bin/pkill dhclient");
    my $conf_file = "$WIFI_DIR/$ssid.$INT";
    system("/bin/cp \"$conf_file\" /etc/hostname.$INT");
    print "[+] ${BLU}Configured interface ${YLW}$INT${BLU}; ESSID is ${YLW}\"$ssid\"${RST}\n";
    system("/sbin/ifconfig $INT nwid \"$ssid\" wpakey \"$password\"");
    print "[+] ${BLU}Interface ${YLW}$INT${BLU} is up${RST}\n";
    print "[+] ${BLU}Running dhclient${RST}\n";
    system("/sbin/dhclient $INT");
    system("/usr/sbin/rcctl restart dnscrypt_proxy unbound");
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
print_banner();

# Ensure the wifi configuration directory exists with proper permissions.
unless (-d $WIFI_DIR) {
    make_path($WIFI_DIR, { mode => 0600 }) or die "Cannot create directory $WIFI_DIR: $!";
}

# Begin by reading saved configurations or creating a new one.
read_saved();