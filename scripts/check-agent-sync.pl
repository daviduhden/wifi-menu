#!/usr/bin/env perl

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Find qw(find);
use File::Spec;

my $base;
if (@ARGV == 2 && $ARGV[0] eq '--base') {
    $base = $ARGV[1];
}
elsif (@ARGV) {
    die "Usage: $0 [--base <git-ref>]\n";
}

sub capture {
    my (@command) = @_;
    open my $pipe, '-|', @command
      or die "Cannot run $command[0]: $!\n";
    local $/;
    my $output = <$pipe> // '';
    close $pipe or die "Command failed: @command\n";
    return $output;
}

sub is_instruction {
    my ($path) = @_;
    return $path eq 'AGENTS.md'
      || $path eq 'CLAUDE.md'
      || $path eq '.github/copilot-instructions.md'
      || $path =~ m{(?:^|/)AGENTS\.md\z}
      || $path =~ m{\.agent\.md\z}
      || $path =~ m{(?:^|/)SKILL\.md\z}
      || $path =~ m{^\.cursor/rules/.*\.mdc\z}
      || $path =~ m{^\.github/instructions/.*\.instructions\.md\z};
}

my @changed;
if (defined $base) {
    push @changed, split /\n/, capture('git', 'diff', '--name-only',
      "$base...HEAD", '--');
}
push @changed, split /\n/, capture('git', 'diff', '--name-only', 'HEAD', '--');
push @changed, split /\n/, capture('git', 'ls-files', '--others',
  '--exclude-standard');
my %seen;
@changed = grep { length && !$seen{$_}++ } @changed;

if (!@changed) {
    print "Agent/skills sync: no repository changes detected.\n";
    exit 0;
}

my @instruction_changes = grep { is_instruction($_) } @changed;
if (!@instruction_changes) {
    die "Agent/skills sync failed: repository changes require a substantive "
      . "AGENTS.md, agent instruction, or SKILL.md update.\n";
}

my $diff_range = defined $base ? "$base...HEAD" : 'HEAD';
my $meaningful = 0;
for my $path (@instruction_changes) {
    next if !-f $path;
    my $diff = capture('git', 'diff', '--no-ext-diff', '--unified=0',
      $diff_range, '--', $path);
    if (!length $diff) {
        open my $file, '<', $path or die "Cannot read $path: $!\n";
        local $/;
        my $content = <$file> // '';
        close $file;
        $diff = join '', map { "+$_\n" } split /(?<=\n)/, $content;
    }
    for my $line (split /\n/, $diff) {
        next if $line !~ /^[+-](?![+-])/;
        $line =~ s/^[+-]//;
        next if $line =~ /^\s*(?:#|[-*_]{3,}\s*$)/;
        $line =~ s/\b\d{4}-\d\d-\d\d\b//g;
        $line =~ s/[^A-Za-z0-9]+//g;
        $meaningful += length $line;
    }
}
if ($meaningful < 20) {
    die "Agent/skills sync failed: instruction changes are empty or too "
      . "trivial (need at least 20 changed alphanumeric characters).\n";
}

my @instruction_files;
find({
    no_chdir => 1,
    preprocess => sub { grep { $_ ne '.git' } @_ },
    wanted => sub {
        return if !-f $_;
        my $path = $File::Find::name;
        $path =~ s{\A\./}{};
        push @instruction_files, $path if is_instruction($path);
    },
}, '.');
for my $path (@changed) {
    push @instruction_files, $path if is_instruction($path) && -f $path;
}
%seen = ();
@instruction_files = grep { !$seen{$_}++ } @instruction_files;
die "AGENTS.md: required root agent instructions are missing\n"
  if !-f 'AGENTS.md';

for my $path (@instruction_files) {
    open my $file, '<', $path or die "Cannot read $path: $!\n";
    local $/;
    my $content = <$file> // '';
    close $file;
    die "$path: must use LF line endings\n" if $content =~ /\r/;
    die "$path: must end with a newline\n"
      if length($content) && $content !~ /\n\z/;
    die "$path: contains trailing whitespace\n"
      if $content =~ /[\t ]+\n/m;
    die "$path: contains a NUL byte\n" if $content =~ /\x00/;
    die "$path: must contain ASCII text\n" if $content =~ /[^\x00-\x7f]/;

    if ($path =~ m{(?:^|/)SKILL\.md\z}) {
        die "$path: invalid or missing Agent Skills frontmatter\n"
          if $content !~ /\A---\nname: [a-z0-9-]+\ndescription: .+\n---\n/s;
        die "$path: missing Maintenance & Continuous Learning section\n"
          if $content !~ /^## Maintenance & Continuous Learning\s*$/m;
    }
    elsif ($path eq 'AGENTS.md') {
        die "$path: missing Continuous Agent & Skills Maintenance section\n"
          if $content !~ /^## Continuous Agent & Skills Maintenance\s*$/m;
    }
    elsif ($path =~ /\.agent\.md\z/) {
        die "$path: missing Post-Change Knowledge Synchronization section\n"
          if $content !~ /^## Post-Change Knowledge Synchronization\s*$/m;
    }

    while ($content =~ /\]\(([^)]+)\)/g) {
        my $target = $1;
        next if $target =~ m{\A(?:[A-Za-z][A-Za-z0-9+.-]*:|//|#)};
        $target =~ s/[?#].*\z//;
        next if !length $target;
        my $resolved = File::Spec->catfile(dirname($path), $target);
        die "$path: local reference does not exist: $target\n"
          if !-e $resolved;
    }
}

print "Agent/skills sync: PASS; checked " . scalar(@instruction_files)
  . " instruction files and " . scalar(@changed) . " changed paths.\n";
print "Semantic relevance still requires human review.\n";
