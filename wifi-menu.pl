#!/usr/bin/perl

# Interactive Wi-Fi network manager for OpenBSD.
# See LICENSE for copyright and license details.

use strict;
use warnings;
use Fcntl      qw(O_CREAT O_EXCL O_WRONLY);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use POSIX      qw(ECHO TCSANOW);

my $WIFI_DIR    = '/etc/wifi_saved';
my $IFCONFIG    = '/sbin/ifconfig';
my $DHCPCONTROL = '/usr/sbin/dhcpleasectl';
my $INT         = '';

# Print an informational message to stdout.  The interactive prompts also use
# stdout, so callers can redirect status output without hiding questions.
sub logi { print "[INFO] $_[0]\n" }

# Report a fatal error and exit.  All failures that occur after the script has
# started changing system state use this path so the operator sees one clear
# diagnostic instead of a Perl exception.
sub die_tool {
    print STDERR "[ERROR] $_[0]\n";
    exit 1;
}

# Render untrusted bytes without letting terminal control sequences through.
sub display_label {
    my ($value) = @_;
    $value =~ s/([^\x20-\x7e])/sprintf( '\\x%02x', ord($1) )/ge;
    return $value;
}

# netstart(8) reads every hostname.if(5) line without read -r and then
# word-splits it before eval.  Values that cannot survive that pipeline
# must be rejected instead of being written in a different form.
sub validate_saved_value {
    my ( $value, $label ) = @_;
    die_tool("$label cannot contain line breaks or NUL bytes")
      if $value =~ /[\r\n\0]/;
    die_tool("$label cannot contain tabs or repeated spaces")
      if $value =~ /\t/ || $value =~ /  /;
}

# Run a command with list-form argv so SSIDs and passphrases are never parsed
# by a shell.  Returns true only for an exit status of zero.
sub run {
    my (@command) = @_;
    system { $command[0] } @command;
    return $? == 0;
}

# Run a command and capture all of its output.  The command is executed with
# list-form open and no shell.  The caller receives both the close status and
# the complete output so it can distinguish an execution failure from an empty
# result.
sub capture {
    my (@command) = @_;
    open my $fh, '-|', @command
      or die_tool("Cannot execute $command[0]: $!");
    local $/ = undef;
    my $output = <$fh> // '';
    my $ok     = close $fh;
    return ( $ok, $output );
}

# Refuse to continue unless the effective user is root.  The script edits files
# under /etc and configures network interfaces, so this check must happen before
# any path is created or changed.
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

# Apply the unveil(2) policy for the selected interface.  Interface discovery
# happens before this call, so the policy can name the exact config and backup
# paths.  The process remains unpledged because it must exec native utilities
# and the Perl binding cannot restrict exec promises; each child therefore
# starts with an empty unveil view.
sub setup_sandbox {
    return unless $^O eq 'openbsd';

    require OpenBSD::Unveil;

    for my $path ( $IFCONFIG, $DHCPCONTROL ) {
        -e $path or die_tool("Required tool $path not found");
        OpenBSD::Unveil::unveil( $path, 'rx' )
          or die_tool("unveil($path) failed: $!");
    }
    if ( -e '/usr/libexec/ld.so' ) {
        OpenBSD::Unveil::unveil( '/usr/libexec/ld.so', 'rx' )
          or die_tool("unveil(/usr/libexec/ld.so) failed: $!");
    }

    # Base OpenBSD Perl seeds with arc4random(3); keep /dev/urandom for
    # Perl builds that still read it and for File::Temp's fallbacks.
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
    OpenBSD::Unveil::unveil()
      or die_tool("unveil lock failed: $!");

    # This launcher deliberately remains unpledged: it executes native
    # utilities and does not set execpromises.  Without execpromises,
    # execve(2) clears the unveil view for each child, so the locked view
    # constrains only pathname operations in this Perl process.
}

# List interfaces in the ifconfig(8) "wlan" group and extract their names.
# Duplicate names are removed while preserving the command's order.
sub list_wifi_interfaces {
    my ( $ok, $output ) = capture( $IFCONFIG, 'wlan' );
    die_tool('Cannot list interfaces in the wlan group') unless $ok;

    my %seen;
    return grep { !$seen{$_}++ }
      map { /^([[:alpha:]]+[[:digit:]]+):/ ? $1 : () }
      split /\n/, $output;
}

# Select one interface automatically when there is only one, or prompt for a
# one-based index.  An empty answer cancels the program; out-of-range and
# nonnumeric answers are errors rather than accidental defaults.
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
      if $choice !~ /\A[1-9][0-9]*\z/ || $choice > @interfaces;
    return $interfaces[ $choice - 1 ];
}

# Store the selected interface in the script global and bring it up.  The
# remaining functions use $INT as the implicit current interface.
sub select_interface {
    my @interfaces = list_wifi_interfaces();
    $INT = choose_interface(@interfaces) // exit 0;
    die_tool("Interface $INT cannot be brought up")
      unless run( $IFCONFIG, $INT, 'up' );
}

# Clear all wireless state on the interface before joining a new network.
# ifconfig(8) accepts several clearing options in one invocation; a failure is
# fatal because a stale join list or key would make the next connection
# ambiguous.
sub clear_wireless_settings {
    run(
        $IFCONFIG, $INT,     '-bssid', '-chan',
        '-nwid',   '-nwkey', '-wpa',   '-wpakey',
        '-joinlist'
    ) or die_tool("Failed to clear wireless settings on $INT");
}

# Scan for networks and parse ifconfig(8) scan output into display/SSID pairs.
# Printable SSIDs are printed bare, values containing spaces are wrapped in
# double quotes without escaping embedded quotes, and all other bytes are shown
# as 0x-prefixed hex. The printed form is kept for the menu because it
# preserves that spelling; the ssid field is passed back to ifconfig.
sub scan_networks {
    logi("Scanning for Wi-Fi networks on $INT...");
    my ( $ok, $output ) = capture( $IFCONFIG, $INT, 'scan' );
    die_tool("Failed to scan for Wi-Fi networks on $INT") unless $ok;

    my %seen;
    my @networks;
    for my $line ( split /\n/, $output ) {

        # Scan results are indented "nwid <ssid> chan <n> ..." lines.
        # Anchoring on the leading whitespace stops the interface status
        # line that precedes the results, and matching the quoted form
        # greedily stops an SSID containing " chan " from being split.
        next unless $line =~ /^\s*nwid\s+(".*"|\S+)\s+chan\s+/;
        my $printed = $1;

        # An empty SSID and a literal two-quote SSID are both printed as
        # "" and cannot be distinguished here.
        next if $printed eq '""';

        # Strip only the outer quotes that ifconfig adds for whitespace.
        # A bare SSID that itself starts and ends with a quote must stay
        # intact.  Hex strings are passed back to ifconfig unchanged.
        my $ssid = $printed;
        if ( $ssid =~ /\A"(.*)"\z/s && $ssid =~ /\s/ ) {
            $ssid = $1;
        }
        next if $seen{$ssid}++;
        push @networks, { display => $printed, ssid => $ssid };
    }
    die_tool("No Wi-Fi networks found on $INT") unless @networks;
    return @networks;
}

# Prompt for one scanned network.  An empty answer exits successfully; a
# malformed or out-of-range selection is a fatal input error.
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
      if $choice !~ /\A[1-9][0-9]*\z/ || $choice > @networks;
    return $networks[ $choice - 1 ];
}

# Read a WPA passphrase without echoing it.  The terminal mode is saved and
# restored on every path, including SIGINT, SIGTERM, SIGQUIT and SIGHUP, so an
# interrupted prompt does not leave the controlling terminal without echo.  An
# empty answer selects an open network; nonempty values must be either a
# 64-hex-digit raw PSK or an 8..63 byte passphrase.
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
        local $SIG{HUP}  = sub { die "interrupted\n" };
        local $SIG{QUIT} = sub { die "terminated\n" };
        $password = <STDIN>;
        1;
    } || ( $read_error = $@ || 'unknown input error' );
    $termios->setlflag($original_lflag);
    eval {
        defined $termios->setattr( $fd, TCSANOW )
          or die "$!\n";
        1;
    }
      || ( $restore_error = $@ || $! || 'unknown error' );
    print "\n";
    die_tool("Could not restore terminal input mode: $restore_error")
      if $restore_error;
    die_tool("Could not read the passphrase: $read_error") if $read_error;
    die_tool('Could not read the passphrase') unless defined $password;
    chomp $password;
    if ( length $password ) {

        # ifconfig accepts either an 8-63 byte passphrase or a raw PSK
        # written as 0x followed by 64 hexadecimal digits.
        if ( $password !~ /\A0[xX][0-9a-fA-F]{64}\z/ ) {
            die_tool(
                'A WPA passphrase must contain between 8 and 63 characters')
              if length($password) < 8 || length($password) > 63;
        }
        validate_saved_value( $password, 'A WPA passphrase' );
    }
    return $password;
}

sub hostname_arg {
    my ($value) = @_;
    validate_saved_value( $value, 'A saved value' );

    # netstart(8) evaluates every hostname.if(5) line with the shell, so
    # a bare word could run a command or be mangled.  Wrap the value in
    # single quotes and encode each embedded single quote as '\''.
    my @parts = split /'/, $value, -1;
    my $word  = "'" . join( "'\\''", @parts ) . "'";

    # netstart reads the file with ksh read(1) without -r, which consumes
    # one level of backslashes.  Double them so eval sees our quoting.
    $word =~ s/\\/\\\\/g;
    return $word;
}

# Decode a field produced by hostname_arg(), while still accepting the
# bare and double-quoted formats written by older versions.
sub unquote_hn_field {
    my ($field) = @_;
    return unless defined $field;
    my $text = $field;

    # Current files double every backslash so that netstart's read(1)
    # leaves the shell word intact.  Undo that layer when present; older
    # files used a single backslash and are decoded as-is.
    $text =~ s/\\(.)/$1/gs if $text =~ /\\\\/;

    return $1 if $text        =~ /\A"([^"]*)"\z/s;
    return $text unless $text =~ /\A'/;

    my $value = '';
    my $i     = 1;
    my $len   = length $text;
    while ( $i < $len ) {
        my $char = substr $text, $i, 1;
        if ( $char eq "'" ) {
            if ( substr( $text, $i, 4 ) eq "'\\''" ) {
                $value .= "'";
                $i += 4;
                next;
            }
            return if $i != $len - 1;
            return $value;
        }
        $value .= $char;
        $i++;
    }
    return;
}

# Derive the saved-configuration path for an SSID.  The SSID is hex-encoded so
# arbitrary bytes, slashes and missing bytes cannot escape $WIFI_DIR or make
# names ambiguous; the interface name is appended to keep per-interface files
# distinct.
sub config_path {
    my ($ssid) = @_;
    return sprintf '%s/%s.%s', $WIFI_DIR, unpack( 'H*', $ssid ), $INT;
}

# Generate the canonical hostname.if(5) content for one network.  Only the
# join line and IPv4 autoconfiguration are produced; the values are quoted by
# hostname_arg() so netstart(8) sees exactly one argument per field.
sub config_content {
    my ( $ssid, $password ) = @_;
    die_tool('The SSID cannot be empty') unless length $ssid;
    my $line = 'join ' . hostname_arg($ssid);
    $line .= ' wpakey ' . hostname_arg($password) if length $password;
    return "$line\ninet autoconf\n";
}

# Persist a newly successful connection.  The file is written to a private
# temporary in $WIFI_DIR and renamed into place, so a crash cannot leave a
# partially written credential file under its final name.
sub write_config {
    my ( $ssid, $password ) = @_;
    my $path    = config_path($ssid);
    my $content = config_content( $ssid, $password );

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

# Parse a saved "join ... [wpakey ...]" line.  The grammar accepts the current
# single-quoted encoding produced by hostname_arg() as well as the older bare
# and double-quoted forms, then revalidates the decoded values before they are
# passed back to ifconfig or copied into a new config.
sub parse_saved_config {
    my ($path) = @_;
    open my $fh, '<', $path or die_tool("Cannot read $path: $!");
    my $line = <$fh> // '';
    close $fh or die_tool("Cannot close $path: $!");
    chomp $line;
    die_tool("Invalid saved configuration: $path") if $line =~ /[\r\0]/;

    my $single = qr/'(?:[^']|'\\\\''|'\\'')*'/;
    my $field  = qr/$single|"[^"]*"|[^\s'"]+/;
    $line =~ /\Ajoin[ \t]+($field)(?:[ \t]+wpakey[ \t]+($field))?[ \t]*\z/
      or die_tool("Invalid saved configuration: $path");
    my $ssid_field     = $1;
    my $password_field = $2;
    my $ssid           = unquote_hn_field($ssid_field);
    my $password =
      defined $password_field ? unquote_hn_field($password_field) : '';
    die_tool("Invalid saved configuration: $path")
      unless defined $ssid && length $ssid && defined $password;
    validate_saved_value( $ssid,     'The saved SSID' );
    validate_saved_value( $password, 'The saved passphrase' );
    return ( $ssid, $password );
}

# Install /etc/hostname.<if> atomically.  The previous file is first copied to
# a private staging file and renamed to the one-generation backup; the new
# content uses a separate staging file and a final rename.  Every staging and
# backup path is mode 0600 because the file contains the WPA passphrase.
sub install_hostname_file {
    my ($content)        = @_;
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
    sysopen my $fh, $temporary, O_WRONLY | O_CREAT | O_EXCL, 0600
      or die_tool("Cannot stage $destination: $!");
    unless ( print {$fh} $content ) {
        my $error = $!;
        close $fh;
        unlink $temporary;
        die_tool("Cannot write $temporary: $error");
    }
    unless ( close $fh ) {
        my $error = $!;
        unlink $temporary;
        die_tool("Cannot close $temporary: $error");
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

# Join the selected network, enable IPv4 autoconfiguration, install the
# persistent hostname file, and wait for dhcpleased to report a bound lease.
# dhcpleasectl exits zero even on timeout, so success is determined from both
# its status and the "Bound" token in its output.
sub apply_connection {
    my ( $ssid, $password ) = @_;
    die_tool('The SSID cannot be empty') unless length $ssid;
    validate_saved_value( $ssid,     'The SSID' );
    validate_saved_value( $password, 'The passphrase' ) if length $password;
    clear_wireless_settings();

    my @join = ( $IFCONFIG, $INT, 'join', $ssid );
    push @join, 'wpakey', $password if length $password;
    run(@join) or die_tool( "Failed to join network " . display_label($ssid) );
    run( $IFCONFIG, $INT, 'inet', 'autoconf' )
      or die_tool("Failed to enable IPv4 autoconfiguration on $INT");
    install_hostname_file( config_content( $ssid, $password ) );

    my ( $ok, $output ) = capture( $DHCPCONTROL, '-w', '10', $INT );
    print $output if length $output;
    die_tool("DHCP did not complete on $INT within 10 seconds")
      unless $ok && $output =~ /\bBound\b/;
    logi( "Configured $INT for " . display_label($ssid) );
}

# Interactive new-connection path: scan, choose, ask for a passphrase, apply,
# and only then save the credentials.  Saving after a successful DHCP result
# avoids leaving a usable-looking file for a network that never connected.
sub create_connection {
    my $network  = choose_network( scan_networks() );
    my $password = read_password( $network->{display} );
    apply_connection( $network->{ssid}, $password );
    write_config( $network->{ssid}, $password );
}

# List saved files for the current interface.  Filenames encode the SSID as
# hexadecimal and end in ".<interface>"; unrelated files in the directory are
# ignored rather than presented as networks.
sub saved_connections {
    opendir my $dh, $WIFI_DIR
      or die_tool("Cannot open $WIFI_DIR: $!");
    my @files =
      sort grep { /\A[0-9a-f]+\.\Q$INT\E\z/ && -f "$WIFI_DIR/$_" } readdir $dh;
    closedir $dh;
    return @files;
}

# Offer saved networks first.  Selecting one revalidates the saved values and
# reapplies them without rewriting the file; an empty answer falls through to a
# fresh scan.  Only well-formed hexadecimal filenames are decoded for display.
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
        printf "%d) %s\n", $i + 1, display_label($label);
    }
    print "\nChoose a saved network or press Enter to scan: ";
    my $choice = read_choice();
    return create_connection() if $choice eq '';
    die_tool('Invalid saved-network selection')
      if $choice !~ /\A[1-9][0-9]*\z/ || $choice > @files;

    my $path = "$WIFI_DIR/$files[ $choice - 1 ]";
    my ( $ssid, $password ) = parse_saved_config($path);
    apply_connection( $ssid, $password );
}

sub print_banner {
    print "\nOpenBSD Wi-Fi network manager\n\n";
}

# Script entry point.  Root, umask and the credential directory are established
# before interface discovery; the sandbox is installed only after the interface
# name is known so its unveil rules can name the exact hostname files.
sub main {
    require_root();
    umask 077;
    unless ( -d $WIFI_DIR ) {
        make_path( $WIFI_DIR, { mode => oct(700) } )
          or die_tool("Cannot create $WIFI_DIR");
    }
    die_tool("$WIFI_DIR is not a directory") unless -d $WIFI_DIR;
    chmod 0700, $WIFI_DIR
      or die_tool("Cannot protect $WIFI_DIR: $!");
    select_interface();
    setup_sandbox();
    print_banner();
    choose_saved_or_new();
}

main();
