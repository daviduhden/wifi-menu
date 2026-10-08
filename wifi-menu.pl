#!/usr/bin/perl

# Interactive Wi-Fi network manager for OpenBSD.
# See LICENSE for copyright and licence details.

use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use POSIX      qw(ECHO TCSANOW);

my $WIFI_DIR    = '/etc/wifi_saved';
my $IFCONFIG    = '/sbin/ifconfig';
my $DHCPCONTROL = '/usr/sbin/dhcpleasectl';
my $INT         = '';

sub logi { print "[INFO] $_[0]\n" }
sub logw { print STDERR "[WARN] $_[0]\n" }

sub die_tool {
    print STDERR "[ERROR] $_[0]\n";
    exit 1;
}

sub run {
    my (@command) = @_;
    system { $command[0] } @command;
    return $? == 0;
}

sub capture {
    my (@command) = @_;
    open my $fh, '-|', @command
      or die_tool("Cannot execute $command[0]: $!");
    local $/;
    my $output = <$fh> // '';
    my $ok     = close $fh;
    return ( $ok, $output );
}

sub require_root {
    die_tool('This script must be run as root') if $> != 0;
}

# Read one line from the terminal, returning '' at end of input and
# discarding the surrounding whitespace so that stray spaces or tabs do
# not turn a valid choice into an invalid one.
sub read_choice {
    my $line = <STDIN>;
    return '' unless defined $line;
    $line =~ s/\A\s+//;
    $line =~ s/\s+\z//;
    return $line;
}

sub setup_sandbox {
    return unless $^O eq 'openbsd';

    require OpenBSD::Pledge;
    require OpenBSD::Unveil;

    for my $path ( $IFCONFIG, $DHCPCONTROL, '/usr/libexec/ld.so' ) {
        next unless -e $path;
        OpenBSD::Unveil::unveil( $path, 'rx' )
          or die_tool("unveil($path) failed: $!");
    }

    # /dev/urandom is read when Perl seeds the random names used by
    # File::Temp; unveiling it avoids falling back to weaker sources.
    for my $path ( '/usr/lib', '/var/run/ld.so.hints', '/dev/urandom' ) {
        next unless -e $path;
        OpenBSD::Unveil::unveil( $path, 'r' )
          or die_tool("unveil($path) failed: $!");
    }
    for my $path ( $WIFI_DIR, "/etc/hostname.$INT" ) {
        OpenBSD::Unveil::unveil( $path, 'rwc' )
          or die_tool("unveil($path) failed: $!");
    }
    for my $path (
        "/etc/.hostname.$INT.wifi-menu.$$",
        "/etc/.hostname.$INT.wifi-menu-backup.$$",
        "/etc/hostname.$INT.wifi-menu.old"
      )
    {
        OpenBSD::Unveil::unveil( $path, 'rwc' )
          or die_tool("unveil($path) failed: $!");
    }
    for my $path ( '/dev/null', '/dev/dhcpleased.sock' ) {
        next unless -e $path;
        OpenBSD::Unveil::unveil( $path, 'rw' )
          or die_tool("unveil($path) failed: $!");
    }
    OpenBSD::Unveil::unveil()
      or die_tool("unveil lock failed: $!");

    my @promises = qw(stdio rpath wpath cpath fattr proc exec tty);
    OpenBSD::Pledge::pledge(@promises)
      or die_tool("pledge failed: $!");
}

sub list_wifi_interfaces {
    my ( $ok, $output ) = capture( $IFCONFIG, 'wlan' );
    return unless $ok;

    my %seen;
    return grep { !$seen{$_}++ }
      map { /^([[:alpha:]]+[[:digit:]]+):/ ? $1 : () }
      split /\n/, $output;
}

sub choose_interface {
    my (@interfaces) = @_;
    die_tool('No Wi-Fi interfaces found in the wlan group')
      unless @interfaces;
    if ( @interfaces == 1 ) {
        logi("Using detected Wi-Fi interface: $interfaces[0]");
        return $interfaces[0];
    }

    logi('Available Wi-Fi interfaces:');
    for my $i ( 0 .. $#interfaces ) {
        printf "%d) %s\n", $i + 1, $interfaces[$i];
    }
    print "\nChoose interface (number) or press Enter to cancel: ";
    my $choice = read_choice();
    return if $choice eq '';
    die_tool('Invalid interface selection')
      unless $choice =~ /\A[1-9][0-9]*\z/ && $choice <= @interfaces;
    return $interfaces[ $choice - 1 ];
}

sub select_interface {
    my @interfaces = list_wifi_interfaces();
    $INT = choose_interface(@interfaces) // exit 0;
    die_tool("Interface $INT cannot be brought up")
      unless run( $IFCONFIG, $INT, 'up' );
}

sub clear_wireless_settings {
    run(
        $IFCONFIG, $INT,     '-bssid', '-chan',
        '-nwid',   '-nwkey', '-wpa',   '-wpakey',
        '-joinlist'
    ) or die_tool("Failed to clear wireless settings on $INT");
}

# ifconfig(8) prints printable SSIDs verbatim, quotes those containing
# whitespace, and represents non-printable SSIDs as 0x-prefixed hex.
sub scan_networks {
    logi("Scanning for Wi-Fi networks on $INT...");
    my ( $ok, $output ) = capture( $IFCONFIG, $INT, 'scan' );
    die_tool("Failed to scan for Wi-Fi networks on $INT") unless $ok;

    my %seen;
    my @networks;
    for my $line ( split /\n/, $output ) {

        # Scan results are indented "nwid <ssid> chan <n> ..." lines.
        # Anchoring on the leading whitespace stops the interface status
        # line that precedes the results, and matching a quoted SSID as
        # a unit stops an SSID containing " chan " from being split.
        next unless $line =~ /^\s*nwid\s+("[^"]*"|\S+)\s+chan\s+/;
        my $printed = $1;
        next if $printed eq '""';
        my $ssid = $printed;
        $ssid = substr( $ssid, 1, -1 )
          if $ssid =~ /\A".*"\z/s;
        next if $seen{$ssid}++;
        push @networks, { display => $printed, ssid => $ssid };
    }
    die_tool("No Wi-Fi networks found on $INT") unless @networks;
    return @networks;
}

sub choose_network {
    my @networks = @_;
    logi('Available Wi-Fi networks:');
    for my $i ( 0 .. $#networks ) {
        printf "%d) %s\n", $i + 1, $networks[$i]{display};
    }
    print "\nChoose a Wi-Fi network or press Enter to quit: ";
    my $choice = read_choice();
    exit 0 if $choice eq '';
    die_tool('Invalid network selection')
      unless $choice =~ /\A[1-9][0-9]*\z/ && $choice <= @networks;
    return $networks[ $choice - 1 ];
}

sub read_password {
    my ($display) = @_;
    print "Passphrase for $display (empty for an open network): ";
    my $fd = fileno(STDIN);
    defined $fd or die_tool('Standard input has no file descriptor');
    my $termios = POSIX::Termios->new();
    eval {
        defined $termios->getattr($fd)
          or die "$!\n";
        1;
    }
      or die_tool( "Cannot read terminal settings: " . ( $@ || $! ) );
    my $original_lflag = $termios->getlflag();
    $termios->setlflag( $original_lflag & ~ECHO );
    eval {
        defined $termios->setattr( $fd, TCSANOW )
          or die "$!\n";
        1;
    }
      or die_tool( "Cannot disable terminal echo: " . ( $@ || $! ) );

    my ( $password, $read_error, $restore_error );
    eval {
        local $SIG{INT}  = sub { die "interrupted\n" };
        local $SIG{TERM} = sub { die "terminated\n" };
        $password = <STDIN>;
        1;
    } or $read_error = $@ || 'unknown input error';
    $termios->setlflag($original_lflag);
    eval {
        defined $termios->setattr( $fd, TCSANOW )
          or die "$!\n";
        1;
    }
      or $restore_error = $@ || $! || 'unknown error';
    print "\n";
    die_tool("Could not restore terminal input mode: $restore_error")
      if $restore_error;
    die_tool("Could not read the passphrase: $read_error") if $read_error;
    die_tool('Could not read the passphrase') unless defined $password;
    chomp $password;
    if ( length $password ) {
        die_tool('A WPA passphrase must contain between 8 and 63 characters')
          unless length($password) >= 8 && length($password) <= 63;
        die_tool(
            'Line breaks and NUL bytes are not supported in saved passphrases')
          if $password =~ /[\r\n\0]/;
    }
    return $password;
}

sub hostname_arg {
    my ($value) = @_;

    # netstart(8) evaluates every hostname.if(5) line with the shell, so
    # a bare word could run a command or be mangled.  Wrap the value in
    # single quotes and encode each embedded single quote as '\''.
    die_tool('A saved value cannot contain line breaks or NUL bytes')
      if $value =~ /[\r\n\0]/;
    my @parts = split /'/, $value, -1;
    return "'" . join( "'\\''", @parts ) . "'";
}

# Decode a field produced by hostname_arg(), while still accepting the
# bare and double-quoted formats written by older versions.
sub unquote_hn_field {
    my ($field) = @_;
    return $1 if $field         =~ /\A"([^"]*)"\z/s;
    return $field unless $field =~ /\A'/;
    my $sep = "'\\''";
    $field =~ s/\A'//;
    $field =~ s/'\z//;
    $field =~ s/\Q$sep\E/'/g;
    return $field;
}

sub config_path {
    my ($ssid) = @_;
    return sprintf '%s/%s.%s', $WIFI_DIR, unpack( 'H*', $ssid ), $INT;
}

sub write_config {
    my ( $ssid, $password ) = @_;
    my $path       = config_path($ssid);
    my $ssid_field = hostname_arg($ssid);
    my $line       = "join $ssid_field";
    $line .= ' wpakey ' . hostname_arg($password) if length $password;
    my $content = "$line\ninet autoconf\n";

    # UNLINK removes the staging file if the write fails; after the
    # successful rename the recorded name no longer exists.
    my ( $fh, $temporary ) = tempfile(
        '.wifi-menu-XXXXXX',
        DIR    => $WIFI_DIR,
        UNLINK => 1
    );
    chmod 0600, $temporary
      or die_tool("Cannot protect $temporary: $!");
    print {$fh} $content
      or die_tool("Cannot write $temporary: $!");
    close $fh or die_tool("Cannot close $temporary: $!");
    rename $temporary, $path
      or die_tool("Cannot install $path: $!");
    return $path;
}

sub parse_saved_config {
    my ($path) = @_;
    open my $fh, '<', $path or die_tool("Cannot read $path: $!");
    my $line = <$fh> // '';
    close $fh or die_tool("Cannot close $path: $!");

    my $single = qr/'[^']*(?:'\\''[^']*)*'/;
    my $field  = qr/$single|"[^"]*"|\S+/;
    $line =~ /\Ajoin\s+($field)(?:\s+wpakey\s+($field))?\s*\z/
      or die_tool("Invalid saved configuration: $path");
    my $ssid     = unquote_hn_field($1);
    my $password = defined $2 ? unquote_hn_field($2) : '';
    return ( $ssid, $password );
}

sub install_hostname_file {
    my ($source)         = @_;
    my $destination      = "/etc/hostname.$INT";
    my $temporary        = "/etc/.hostname.$INT.wifi-menu.$$";
    my $backup           = "$destination.wifi-menu.old";
    my $backup_temporary = "/etc/.hostname.$INT.wifi-menu-backup.$$";

    if ( -e $destination ) {
        unlink $backup_temporary if -e $backup_temporary;
        unless ( copy( $destination, $backup_temporary ) ) {
            my $error = $!;
            unlink $backup_temporary;
            die_tool("Cannot stage backup of $destination: $error");
        }
        unless ( chmod 0600, $backup_temporary ) {
            my $error = $!;
            unlink $backup_temporary;
            die_tool("Cannot protect staged backup of $destination: $error");
        }
        unless ( rename $backup_temporary, $backup ) {
            my $error = $!;
            unlink $backup_temporary;
            die_tool("Cannot install backup $backup atomically: $error");
        }
    }
    unlink $temporary if -e $temporary;
    unless ( copy( $source, $temporary ) ) {
        my $error = $!;
        unlink $temporary;
        die_tool("Cannot stage $destination: $error");
    }
    chmod 0600, $temporary
      or do {
        my $error = $!;
        unlink $temporary;
        die_tool("Cannot protect staged $destination: $error");
      };
    rename $temporary, $destination
      or do {
        my $error = $!;
        unlink $temporary;
        die_tool("Cannot install $destination atomically: $error");
      };
}

sub apply_connection {
    my ( $ssid, $password, $config ) = @_;
    clear_wireless_settings();

    my @join = ( $IFCONFIG, $INT, 'join', $ssid );
    push @join, 'wpakey', $password if length $password;
    run(@join) or die_tool("Failed to join network $ssid");
    run( $IFCONFIG, $INT, 'inet', 'autoconf' )
      or die_tool("Failed to enable IPv4 autoconfiguration on $INT");
    install_hostname_file($config);
    run( $DHCPCONTROL, '-w', '10', $INT )
      or die_tool("DHCP did not complete on $INT within 10 seconds");
    logi("Configured $INT for $ssid");
}

sub create_connection {
    my $network  = choose_network( scan_networks() );
    my $password = read_password( $network->{display} );
    my $config   = write_config( $network->{ssid}, $password );
    apply_connection( $network->{ssid}, $password, $config );
}

sub saved_connections {
    opendir my $dh, $WIFI_DIR
      or die_tool("Cannot open $WIFI_DIR: $!");
    my @files =
      sort grep { /\A[0-9a-f]+\.\Q$INT\E\z/ && -f "$WIFI_DIR/$_" } readdir $dh;
    closedir $dh;
    return @files;
}

sub choose_saved_or_new {
    my @files = saved_connections();
    return create_connection() unless @files;

    logi('Saved Wi-Fi configurations:');
    for my $i ( 0 .. $#files ) {
        my ($hex) = split /\./, $files[$i], 2;

        # Only decode well-formed hexadecimal, and never warn about a
        # stray file that happens to match the filename pattern.
        my $valid = $hex =~ /\A(?:[0-9a-f]{2})+\z/;
        my $label = $valid ? pack( 'H*', $hex ) : $files[$i];
        printf "%d) %s\n", $i + 1, $label;
    }
    print "\nChoose a saved network or press Enter to scan: ";
    my $choice = read_choice();
    return create_connection() if $choice eq '';
    die_tool('Invalid saved-network selection')
      unless $choice =~ /\A[1-9][0-9]*\z/ && $choice <= @files;

    my $path = "$WIFI_DIR/$files[ $choice - 1 ]";
    my ( $ssid, $password ) = parse_saved_config($path);
    apply_connection( $ssid, $password, $path );
}

sub print_banner {
    print "\nOpenBSD Wi-Fi network manager\n\n";
}

sub main {
    require_root();
    make_path( $WIFI_DIR, { mode => 0700 } ) unless -d $WIFI_DIR;
    chmod 0700, $WIFI_DIR
      or die_tool("Cannot protect $WIFI_DIR: $!");
    select_interface();
    setup_sandbox();
    print_banner();
    choose_saved_or_new();
}

main();
