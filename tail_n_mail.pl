#!/usr/bin/env perl
# -*-mode:cperl; indent-tabs-mode: nil-*-

## Tail one or more files, mail the new stuff to one or more emails
## Developed at End Point Corporation by:
## Greg Sabino Mullane <greg@endpoint.com>
## Selena Deckelmann <selena@endpoint.com>
## BSD licensed
## For full documentation, please see: http://bucardo.org/wiki/Tail_n_mail

##
## Quick usage:
## Run: tail tail_n_mail.pl > tail_n_mail.config
## Edit tail_n_mail.config in your favorite editor
## Run: perl tail_n_mail.pl tail_n_mail.config
## Once working, put the above into a cron job

use strict;
use warnings;
use Data::Dumper   qw( Dumper     );
use Getopt::Long   qw( GetOptions );
use File::Temp     qw( tempfile   );
use File::Basename qw( dirname    );
use 5.008003;

our $VERSION = '1.13.0';

## Mail sending options.
# Which mode to use?
my $MAILMODE = 'sendmail'; ## change with --mailmode option
## Location of the sendmail program. Expects to be able to use a -f argument.
my $MAILCOM = '/usr/sbin/sendmail'; ## change with --mailcom option
## Mail server if using SMTP mode
my $MAILSERVER = 'example.com'; ## change with --mailserver option
## Username and password if using authenticated smtp
my $MAILUSER = 'example';       ## change with --mailuser option
my $MAILPASS = 'example';       ## change with --mailpass option
my $MAILPORT = 465;             ## change with --mailport option

## We never go back more than this number of bytes. Can be overriden in the config file and command line.
my $MAXSIZE = 80_000_000;

## Default message subject if not set elsewhere. Keywords replaced: FILE HOST NUMBER UNIQUE
my $DEFAULT_SUBJECT= 'Results for FILE on host: HOST';

## We can define custom types, e.g. "duration" that get printed differently
my $custom_type = 'normal';

## Do some really simple line wrapping for super-long lines
my $WRAPLIMIT = 990;

## Set defaults for all the options, then read them in from command line
my ($verbose,$quiet,$debug,$dryrun,$help,$reset,$limit,$rewind,$version) = (0,0,0,0,0,0,0,0,0);
my ($custom_offset,$custom_duration,$custom_file,$nomail,$flatten) = (-1,-1,'',0,1);
my ($timewarp,$pgmode,$find_line_number,$pgformat,$maxsize) = (0,1,1,1,$MAXSIZE);
my ($showonly,$usesmtp,$mailzero,$pretty_query,$duration_limit) = (0,0,0,1,0);
my ($sortby) = ('count'); ## Can also be 'date'
## The thousands separator for formatting numbers. Whether to turn off in subject lines
my ($tsep, $tsepnosub);

my $result = GetOptions
 (
   'verbose'          => \$verbose,
   'quiet'            => \$quiet,
   'debug'            => \$debug,
   'dryrun'           => \$dryrun,
   'help'             => \$help,
   'nomail'           => \$nomail,
   'reset'            => \$reset,
   'limit=i'          => \$limit,
   'rewind=i'         => \$rewind,
   'version'          => \$version,
   'offset=i'         => \$custom_offset,
   'duration=i'       => \$custom_duration,
   'file=s'           => \$custom_file,
   'flatten!'         => \$flatten,
   'timewarp=i'       => \$timewarp,
   'pgmode=s'         => \$pgmode,
   'pgformat=i'       => \$pgformat,
   'maxsize=i'        => \$maxsize,
   'type=s'           => \$custom_type,
   'sortby=s'         => \$sortby,
   'showonly=i'       => \$showonly,
   'mailmode=s'       => \$MAILMODE,
   'mailcom=s'        => \$MAILCOM,
   'mailserver=s'     => \$MAILSERVER,
   'mailuser=s'       => \$MAILUSER,
   'mailpass=s'       => \$MAILPASS,
   'mailport=s'       => \$MAILPORT,
   'mailzero'         => \$mailzero,
   'smtp'             => \$usesmtp,
   'tsep=s'           => \$tsep,
   'tsepnosub'        => \$tsepnosub,
   'pretty_query'     => \$pretty_query,
   'duration_limit=i' => \$duration_limit,
  ) or help();
++$verbose if $debug;

if ($version) {
    print "$0 version $VERSION\n";
    exit 0;
}

sub help {
    print "Usage: $0 configfile [options]\n";
    print "For full documentation, please visit:\n";
    print "http://bucardo.org/wiki/Tail_n_mail\n";
    exit 0;
}
$help and help();

$usesmtp and $MAILMODE = 'smtp';

## First option is always the config file, which must exist.
my $configfile = shift or die qq{Usage: $0 configfile\n};

## If the file has the name 'duration' in it, switch to that type as the default
if ($configfile =~ /duration/i) {
    $custom_type = 'duration';
}

## Save away our hostname
my $hostname = qx{hostname};
chomp $hostname;

## Regexen for Postgres PIDs:
## $1=PID $2=part1 $3=part2
my %pgpidres = (
    1 => qr{\[(\d+)\]: \[(\d+)\-(\d+)\]},
    2 => qr{\d\d:\d\d:\d\d \w\w\w (\d+)},
    3 => qr{\d\d:\d\d:\d\d (\w\w\w)}, ## Fake a PID
    4 => qr{\[(\d+)\]},
);

my $pgpidre = $pgpidres{$pgformat};

## Regexes to extract the date part from a line:
my %pgpiddateres = (
    1 => qr{(.+?\[\d+\]): \[\d+\-\d+\]},
    2 => qr{(.+?\d\d:\d\d:\d\d \w\w\w)},
    3 => qr{(.+?\d\d:\d\d:\d\d \w\w\w)},
    4 => qr{(.+? \w\w\w)},
);
my $pgpiddatere = $pgpiddateres{$pgformat};

## The possible types of levels in Postgres logs
my %level = map { $_ => 1 } qw{PANIC FATAL ERROR WARNING NOTICE LOG INFO};
for (1..5) { $level{"DEBUG$_"} = 1; }
my $levels = join '|' => keys %level;
my $levelre = qr{(?:$levels)};

## We use a CURRENT key for future expansion
my $curr = 'CURRENT';

## Global option variables
my (%opt, %itemcomment);

## These options must come before the GetOptions call
for my $arg (@ARGV) {
    if ($arg eq '--no-tailnmailrc') {
        $opt{'no-tailnmailrc'} = 1;
    }
    if ($arg =~ /--tailnmailrc=(.+)/) {
        $opt{'tailnmailrc'} = $1;
    }
    if ($arg =~ /^-+\?$/) {
        help();
    }
}

## Read in any rc files
parse_rc_files();
## Read in and parse the config file
parse_config_file();
## Read in any inherited config files and merge their information in
parse_inherited_files();

## Keep track of changes to know if we need to rewrite the config file or not
my $changes = 0;

## Global regex: may change per file
my ($exclude, $include);

## Note if we bumped into maxsize when trying to read a file
my (%toolarge);

# Actual matching strings are stored here
my %find;

## Keep track of which entries are similar to the ones we've seen before for possible flattening
my %similar;

## Map filenames to "A", "B", etc. for clean output of multiple matches
my %fab;

## Are we viewing the older version of the file because it was rotated?
my $rotatedfile = 0;

## Did we handle more than one file this round?
my $multifile = 0;

## Total matches across all files
$opt{grand_total} = 0;

## For help in sorting later on
my (%fileorder, $filenum);

## Generic globals
my ($string);

## Parse each file returned by pick_log_file until we start looping
my $last_logfile = '';
my @files_parsed;
{
    ## Generate the next log file to parse
    my $logfile = pick_log_file();

    ## If undefined, simply exit the loop
    last if ! defined $logfile;

    ## If it's the same as the last one we did, we are done
    last if $last_logfile eq $logfile;

    $debug and warn "Parsing file ($logfile)\n";
    my $count = parse_file($logfile);
    push @files_parsed => [$logfile, $count];
    $fileorder{$logfile} = ++$filenum;
    $last_logfile = $logfile;
    redo;
}


$opt{$curr}{filename} = $last_logfile;

## We're done parsing the message, send an email if needed
process_report() if $opt{grand_total} or $mailzero or $opt{$curr}{mailzero};
final_cleanup();

exit 0;


sub pick_log_file {

    ## Figure out which files we need to parse

    ## Basic flow:
    ## Start with "last" (and apply offset to it)
    ## Then walk forward until we hit the most recent one

    ## If a custom file, we always just return the main filename
    ## We also remove the lastfile, as it's not important anymore
    ## Same for a reset - we only want the latest file
    if ($custom_file or $reset) {
        delete $opt{$curr}{lastfile};
        return $opt{$curr}{filename};
    }

    my $lastfile = $opt{$curr}{lastfile};
    my $orig = $opt{$curr}{original_filename};

    ## Handle the LATEST case right away
    if ($orig =~ s{([^/\\]*)LATEST([^/\\]*)$}{}o) {

        my ($prefix,$postfix) = ($1,$2);

        ## At this point, the lastfile has already been handled
        ## We need all files newer than that one, in order, until we run out

        ## Already have the list? Pop off items until we are done
        if (exists $opt{$curr}{middle_filenames}) {
            ## Return the next file, or undef when we run out
            return pop @{$opt{$curr}{middle_filenames}};
        }

        my $dir = $orig;
        $dir =~ s{/\z}{};
        -d $dir or die qq{Cannot open $dir: not a directory!\n};
        opendir my $dh, $dir or die qq{Could not opendir "$dir": $!\n};

        ## We need the modification time of the lastfile
        my $lastfiletime = defined $lastfile ? -M $lastfile : 0;

        my %fileq;
        while (my $file = readdir($dh)) {
            my $fname = "$dir/$file";
            my $modtime = -M $fname;
            ## Skip if not a normal file
            next if ! -f _;
            if (length $prefix or length $postfix) {
                next if $file !~ /\A\Q$prefix\E.*\Q$postfix\E\z/o;
            }
            ## Skip if it's older than the lastfile
            next if $lastfiletime and $modtime > $lastfiletime;
            $fileq{$modtime}{$fname} = 1;
        }
        closedir $dh or warn qq{Could not closedir "$dir": $!\n};
      TF: for my $time (sort { $a <=> $b } keys %fileq) {
            for my $file (sort keys %{$fileq{$time}}) {
                push @{$opt{$curr}{middle_filenames}} => $file;
                ## If we don't have a lastfile, we simply use the most recent file
                ## and throw away the rest
                last TF if ! $lastfiletime;
            }
        }

        return pop @{$opt{$curr}{middle_filenames}};

    } ## end of LATEST time travel

    ## No lastfile makes it easy
    exists $opt{$curr}{lastfile} or return $opt{$curr}{filename};

    ## If we haven't processed the lastfile, do that one first
    exists $find{$lastfile} or return $lastfile;

    ## If the last is the same as the current, return
    $lastfile eq $opt{$curr}{filename} and return $lastfile;

    ## We've processed the last file, are there any files in between the two?
    ## POSIX-based time travel
    if ($orig =~ /%/) {

        ## Already have the list? Pop off items until we are done
        if (exists $opt{$curr}{middle_filenames}) {
            my $newfile = pop @{$opt{$curr}{middle_filenames}};
            ## When we run out, return the current file
            return $newfile || $opt{$curr}{filename};
        }

        ## We're going to walk backwards, 30 minutes at a time, and gather up
        ## all files between "now" and the "last"
        my $timerewind = 60*30; ## 30 minutes
        my $maxloops = 24*2 * 7 * 30; ## max of 30 days
        my $bail = 0;
        my %seenfile;
        BACKINTIME: {

            my @ltime = localtime(time - $timerewind);
            my $newfile = POSIX::strftime($orig, @ltime); ## no critic (ProhibitCallsToUnexportedSubs)
            $debug and warn "Checking for file $newfile (last was $lastfile)\n";
            last if $newfile eq $lastfile;
            if (! exists $seenfile{$newfile}) {
                $seenfile{$newfile} = 1;
                push @{$opt{$curr}{middle_filenames}} => $newfile;
            }

            $timerewind += 60*30;
            ++$bail > $maxloops and die "Too many loops ($bail): bailing\n";
            redo;
        }

        return (keys %seenfile) ? (pop @{$opt{$curr}{middle_filenames}}) : $opt{$curr}{filename};
    }

    ## Just return the current file
    return $opt{$curr}{filename};

} ## end of pick_log_file


sub assign_pgformat {
    my $value = shift;
    $pgformat = $value;
    ## Assign new regex, bail if they don't exist
    $pgpidre = $pgpidres{$pgformat} or die "Invalid pgformat: $value\n";
    $pgpiddatere = $pgpiddateres{$pgformat} or die "Invalid pgformat: $value\n";
    return;
}


sub parse_rc_files {

    ## Read in global settings from rc files

    my $file;
    if (! $opt{'no-tailnmailrc'}) {
        if ($opt{tailnmailrc}) {
            -e $opt{tailnmailrc} or die qq{Could not find the file "$opt{tailnmailrc}"\n};
            $file = $opt{tailnmailrc};
        }
        elsif (-e '.tailnmailrc') {
            $file = '.tailnmailrc';
        }
        elsif (exists $ENV{HOME} and -e "$ENV{HOME}/.tailnmailrc") {
            $file = "$ENV{HOME}/.tailnmailrc";
        }
        elsif (-e '/etc/tailnmailrc') {
            $file = '/etc/tailnmailrc';
        }
    }
    if (defined $file) {
        open my $rc, '<', $file or die qq{Could not open "$file": $!\n};
        while (<$rc>) {
            next if /^\s*#/;
            next if ! /^\s*(\w+)\s*[=:]\s*(.+?)\s*$/o;
            my ($name,$value) = (lc $1,$2); ## no critic (ProhibitCaptureWithoutTest)
            $opt{$curr}{$name} = $value;
            ## If we are disabled, simply exit quietly
            if ($name eq 'disable' and $value) {
                exit 0;
            }
            if ($name eq 'pgformat') {
                assign_pgformat($value);
            }
            if ($name eq 'maxsize') {
                $maxsize = $value;
            }
            if ($name eq 'duration_limit') {
                $duration_limit = $value;
            }
        }
        close $rc or die;
    }

    return;

} ## end of parse_rc_files


sub parse_config_file {

    ## Read in a configuration file and populate the global %opt

    ## Are we in the standard non-user comments at the top of the file?
    my $in_standard_comments = 1;

    ## Temporarily store user comments until we know where to put them
    my (@comment);

    ## Store locally so we can easily populate %opt at the end
    my %localopt;

    open my $c, '<', $configfile or die qq{Could not open "$configfile": $!\n};
    $debug and warn qq{Opened config file "$configfile"\n};
    while (<$c>) {

        ## If we are at the top of the file, don't store standard comments
        if ($in_standard_comments) {
            next if /^## Config file for/;
            next if /^## This file is automatically updated/;
            next if /^## Last updated:/;
            next if /^\s*$/;
            ## Once we reach the first non-comment, non-whitespace line,
            ## treat it as a normal line
            $in_standard_comments = 0;
        }

        ## Found a user comment; store it away until we have context for it
        if (/^\s*#/) {
            push @comment => $_;
            next;
        }

        ## A non-comment after one or comments allows us to map them to each other
        if (@comment and m{^(\w+):}) {
            chomp;
            for my $c (@comment) {
                ## We store as both the keyword and the entire line
                push @{$itemcomment{$1}} => $c;
                push @{$itemcomment{$_}} => $c;
            }
            ## Empty out our user comment queue
            undef @comment;
        }

        ## What file are we checking on?
        if (/^FILE:\s*(.+?)\s*$/) {
            my $filename = $localopt{original_filename} = $1;

            if ($filename !~ /\w/) {
                die "No FILE found in the config file! (tried: $filename)\n";
            }

            ## Transform the file name if it contains escapes
            if ($filename =~ /%/) {
                eval { ## no critic (RequireCheckingReturnValueOfEval)
                    require POSIX;
                };

                $@ and die qq{Cannot use strftime formatting without the Perl POSIX module!\n};

                ## Allow moving back in time with the timewarp argument (defaults to 0)
                my @ltime = localtime(time + $timewarp);
                $filename = POSIX::strftime($filename, @ltime); ## no critic (ProhibitCallsToUnexportedSubs)
            }

            ## If a custom file was specified, use that instead
            if ($custom_file) {
                ## If it contains a path, use it directly
                if ($custom_file =~ m{/}) {
                    $filename = $custom_file;
                }
                ## Otherwise, replace the current file name but keep the directory
                else {
                    my $dir = dirname($filename);
                    $filename = "$dir/$custom_file";
                }
            }

            ## Set some default values
            $localopt{filename} = $filename;
            $localopt{exclude} ||= [];
            $localopt{include} ||= [];
            $localopt{email}   ||= [];

        } ## end of FILE:

        ## The last filename we used
        elsif (/^LASTFILE:\s*(.+?)\s*$/) {
            $localopt{lastfile} = $1;
        }
        ## Who to send emails to for this file
        elsif (/^EMAIL:\s*(.+?)\s*$/) {
            push @{$localopt{email}}, $1;
        }
        ## Who to send emails from
        elsif (/^FROM:\s*(.+?)\s*$/) {
            $localopt{from} = $1;
        }
        ## The pg format to use
        elsif (/^PGFORMAT:\s*(\d)\s*$/) {
            $localopt{pgformat} = $1;
            assign_pgformat($1);
        }
        ## What type of report this is
        elsif (/^TYPE:\s*(.+?)\s*$/) {
            $custom_type = $1;
        }
        ## Exclude durations below this number
        elsif (/^DURATION:\s*(\d+)/) {
            ## Command line still wins
            if ($custom_duration < 0) {
                $custom_duration = $localopt{duration} = $1;
            }
        }
        ## Limit how many duration matches we show
        elsif (/^DURATION_LIMIT:\s*(\d+)/) {
            ## Command line still wins
            if (!$duration_limit) {
                $duration_limit = $localopt{duration_limit} = $1;
            }
        }
        ## How to sort the output
        elsif (/^SORTBY:\s*(\w+)/) {
            $localopt{sortby} = $1;
        }
        ## Force line number lookup on or off
        elsif (/^FIND_LINE_NUMBER:\s*(\d+)/) {
            $find_line_number = $localopt{find_line_number} = $1;
        }
        ## Any inheritance files to look at
        elsif (/^INHERIT:\s*(.+)/) {
            push @{$localopt{inherit}}, $1;
        }
        ## Which lines to exclude from the report
        elsif (/^EXCLUDE:\s*(.+?)\s*$/) {
            push @{$localopt{exclude}}, $1;
        }
        ## Which lines to include in the report
        elsif (/^INCLUDE:\s*(.+)/) {
            push @{$localopt{include}}, $1;
        }
        ## The current offset into the file
        elsif (/^OFFSET:\s*(\d+)/) {
            $localopt{offset} = $1;
        }
        ## The custom maxsize for this file
        elsif (/^MAXSIZE:\s*(\d+)/) {
            $localopt{maxsize} = $1;
            ## Command line still wins
            if (int $maxsize == int $MAXSIZE) {
                $maxsize = $localopt{maxsize};
            }
        }
        ## The subject line for this file
        elsif (/^MAILSUBJECT:\s*(.+)/) { ## Trailing whitespace is significant here
            $localopt{mailsubject} = $1;
            $localopt{customsubject} = 1;
        }
        ## Force mail to be sent - overrides any other setting
        elsif (/^MAILZERO:\s*(.+)/) {
            $localopt{mailzero} = $1;
        }
    }
    close $c or die qq{Could not close "$configfile": $!\n};

    ## Move the local vars into place, also record that we found them here
    for my $k (keys %localopt) {
        ## Note it came from the config file so we rewrite it there
        $opt{configfile}{$k} = 1;
        ## If an array, we also want to mark individual items
        if (ref $localopt{$k} eq 'ARRAY') {
            for my $ik (@{$localopt{$k}}) {
                $opt{configfile}{"$k.$ik"} = 1;
            }
        }
        $opt{$curr}{$k} = $localopt{$k};
    }
    if ($debug) {
        local $Data::Dumper::Varname = 'opt';
        warn Dumper \%opt;
    }

    return;

} ## end of parse_config_file


sub parse_inherited_files {

    ## Call parse_inherit_file on each item in $opt{inherit}

    for my $file (@{$opt{$curr}{inherit}}) {
        parse_inherit_file($file);
    }

    return;

} ## end of parse_inherited_files


sub parse_inherit_file {

    ## Similar to parse_config_file, but much simpler
    ## Because we only allow a few items
    ## This is most useful for sharing INCLUDE and EXCLUDE across many config files

    my $file = shift;

    ## Only allow certain characters.
    if ($file !~ s{^\s*([a-zA-Z0-9_\.\/\-\=]+)\s*$}{$1}) {
        die "Invalid inherit file ($file)\n";
    }

    ## If not an absolute path, we'll check current directory and "tnm/"
    my $filename = $file;
    my $filefound = 0;
    if (-e $file) {
        $filefound = 1;
    }
    elsif ($file =~ /^\w/) {
        $filename = "tnm/$file";
        if (-e $filename) {
            $filefound = 1;
        }
        else {
            my $basedir = dirname($0);
            $filename = "$basedir/$file";
            if (-e $filename) {
                $filefound = 1;
            }
            else {
                $filename = "$basedir/tnm/$file";
                -e $filename and $filefound = 1;
            }
        }
    }
    if (!$filefound) {
        die "Unable to open inherit file ($file)\n";
    }

    open my $fh, '<', $filename or die qq{Could not open file "$file": $!\n};
    while (<$fh>) {
        ## Only a few things are allowed in here
        if (/^FIND_LINE_NUMBER:\s*(\d+)/) {
            ## We adjust the global here and now
            $find_line_number = $1;
        }
        ## How to sort the output
        elsif (/^SORTBY:\s*(\w+)/) {
            $opt{$curr}{sortby} = $1;
        }
        ## Which lines to exclude from the report
        elsif (/^EXCLUDE:\s*(.+?)\s*$/) {
            push @{$opt{$curr}{exclude}}, $1;
        }
        ## Which lines to include in the report
        elsif (/^INCLUDE:\s*(.+)/) {
            push @{$opt{$curr}{include}}, $1;
        }
        ## Maximum file size
        elsif (/^MAXSIZE:\s*(\d+)/) {
            $opt{$curr}{maxsize} = $1;
        }
        ## Exclude durations below this number
        elsif (/^DURATION:\s*(\d+)/) {
            ## Command line still wins
            if ($custom_duration < 0) {
                $custom_duration = $1;
            }
        }
        ## The pg format to use
        elsif (/^PGFORMAT:\s*(\d)\s*$/) {
            assign_pgformat($1);
        }
        ## Who to send emails from
        elsif (/^FROM:\s*(.+?)\s*$/) {
            $opt{$curr}{from} = $1;
        }
        ## Who to send emails to for this file
        elsif (/^EMAIL:\s*(.+?)\s*$/) {
            push @{$opt{$curr}{email}}, $1;
        }
        ## Force mail to be sent - overrides any other setting
        elsif (/^MAILZERO:\s*(.+)/) {
            $opt{$curr}{mailzero} = $1;
        }

    }
    close $fh or warn qq{Could not close file "$file": $!\n};

    return;

} ## end of parse_inherited_file


sub parse_file {

    ## Parse the passed in file
    ## Returns the number of matches

    my $filename = shift;

    ## Touch the hash so we know we've been here
    $find{$filename} = {};

    ## Make sure the file exists and is readable
    if (! -e $filename) {
        $quiet or warn qq{WARNING! Skipping non-existent file "$filename"\n};
        return 0;
    }
    if (! -f $filename) {
        $quiet or warn qq{WARNING! Skipping non-file "$filename"\n};
        return 0;
    }

    ## Figure out where in the file we want to start scanning from
    my $size = -s $filename;
    my $offset = 0;

    ## Is the offset significant?
    ## Usually only is if the stored offset matches the current file

    if (!exists $opt{$curr}{lastfile} or ($opt{$curr}{lastfile} eq $filename)) {
        ## Allow the offset to equal the size via --reset
        if ($reset) {
            $offset = $opt{$curr}{newoffset} = $size;
            $verbose and warn "  Resetting offset to $offset\n";
        }
        ## Allow the offset to be changed on the command line
        elsif ($custom_offset != -1) {
            if ($custom_offset >= 0) {
                $offset = $custom_offset;
            }
            elsif ($custom_offset < -1) {
                $offset = $size + $custom_offset;
                $offset = 0 if $offset < 0;
            }
        }
        elsif (exists $opt{$curr}{offset}) {
            $offset = $opt{$curr}{offset};
        }
    }

    my $psize = pretty_number($size);
    my $pmaxs = pretty_number($maxsize);
    $verbose and warn "  File: $filename Offset: $offset Size: $psize Maxsize: $pmaxs\n";

    ## The file may have shrunk due to a logrotate
    if ($offset > $size) {
        $verbose and warn "  File has shrunk - resetting offset to 0\n";
        $offset = 0;
    }

    ## If the offset is equal to the size, we're done!
    return 0 if $offset >= $size;

    ## Store the original offset
    my $original_offset = $offset;

    ## This can happen quite a bit on busy files!
    if ($maxsize and ($size - $offset > $maxsize) and $custom_offset < 0) {
        $quiet or warn "  SIZE TOO BIG (size=$size, offset=$offset): resetting to last $maxsize bytes\n";
        $toolarge{$filename} = qq{File "$filename" too large:\n  only read last $maxsize bytes (size=$size, offset=$offset)};
        $offset = $size - $maxsize;
    }

    open my $fh, '<', $filename or die qq{Could not open "$filename": $!\n};

    ## Seek the right spot as needed
    if ($offset and $offset < $size) {

        ## Because we go back by 10 characters below, always offset at least 10
        $offset = 10 if $offset < 10;

        ## We go back 10 characters to get us before the newlines we (probably) ended with
        seek $fh, $offset-10, 0;

        ## If a manual rewind request has been given, process it (inverse)
        if ($rewind) {
            seek $fh, -$rewind, 1;
        }
    }

    ## Optionally figure out what approximate line we are on
    my $newlines = 0;
    if ($find_line_number) {
        my $pos = tell $fh;

        ## No sense in counting if we're at the start of the file!
        if ($pos > 1) {

            seek $fh, 0, 0;
            ## Need to sysread up to $pos
            my $blocksize = 100_000;
            my $current = 0;
            {
                my $chunksize = $blocksize;
                if ($current + $chunksize > $pos) {
                    $chunksize = $pos - $current;
                }
                my $foobar;
                my $res = sysread $fh, $foobar, $chunksize;
                ## How many newlines in there?
                $newlines += $foobar =~ y/\n/\n/;
                $current += $chunksize;
                redo if $current < $pos;
            }

            ## Return to the original position
            seek $fh, 0, $pos;

        } ## end pos > 1
    } ## end find_line_number

    ## Get exclusion and inclusion regexes for this file
    ($exclude,$include) = generate_regexes($filename);

    ## Discard the previous line if needed (we rewound by 10 characters above)
    $original_offset and <$fh>;

    ## Keep track of matches for this file
    my $count = 0;

    ## Needed to track postgres PIDs
    my %pidline;

    if (lc $pgmode eq 'csv') {
        ## Move this somewhere else
        my $csv;
            eval {
                require Text::CSV;
            };
        if (!$@) {
            $csv = Text::CSV->new({ binary => 1, eol => $/ });
        }
        else {
            ## Assume it failed because it doesn't exist, so try another version
            eval {
                require Text::CSV_XS;
            };
            if ($@) {
                    die qq{Cannot parse CSV logs unless Text::CSV or Text::CSV_XS is available\n};
                }
            $csv = Text::CSV_XS->new({ binary => 1, eol => $/ });
        }
        while (my $line = $csv->getline($fh)) {
            my @cols = @$line;
            $count += process_line("$line->[0] $line->[1]\@$line->[2] $line->[11]:  $line->[13] STATEMENT:  $line->[19]", $., $filename);
        }

    } ## end of PG CSV mode
    else {
        ## Postgres-specific multi-line grabbing stuff:
        my ($pgpid, $pgnum, $pgsub, %current_pid_num, $lastpid);
        my $lastline = '';

        while (<$fh>) {
            ## Easiest to just remove the newline here and now
            chomp;
            if ($pgmode) {
                if ($_ =~ $pgpidre) {
                    ($pgpid, $pgsub, $pgnum) = ($1,$2||1,$3||1);
                    $lastpid = $pgpid;
                    ## We've found something that looks like: postgres[12345] [1-1]
                    ## Have we seen this PID before?
                    if (exists $pidline{$pgpid}) {
                        ## If this is a statement or detail or hint or context, append to the previous entry
                        ## Do the same for a LOG: statement combo (e.g. following a duration)
                        if (/\b(?:STATEMENT|DETAIL|HINT|CONTEXT):  /o
                                or (/ LOG:  statement: /o
                                and
                                $pidline{$pgpid}{string}{$current_pid_num{$pgpid}}
                                or (/ LOG:  statement: /o and $lastline !~ /  statement: |FATAL|PANIC/))) {
                            $pgnum = $current_pid_num{$pgpid} + 1;
                        }
                        ## Is this a new entry for this PID? If so, process the old.
                        if ($pgnum <= 1) {
                            $count += process_line($pidline{$pgpid}, 0, $filename);
                            ## Delete it so it gets recreated afresh below
                            delete $pidline{$pgpid};
                        }
                        else {
                            ## Trim the string up - no need to see the header info each time
                            s/^.+?$pgpidre\s*//;
                            ## No need to see the user more than once for supplemental information
                            s/.+\b(STATEMENT|DETAIL|HINT|CONTEXT):/$1:/;
                        }
                    }
                    $pidline{$pgpid}{string}{$pgnum} = $_;
                    $current_pid_num{$pgpid} = $pgnum;

                    ## Store the line number if we don't have one yet for this PID
                    $pidline{$pgpid}{line} ||= ($. + $newlines);

                    $lastline = $_;
                }
                elsif ($lastpid) {
                    ## Append this to the previous entry
                    $pgnum = $current_pid_num{$lastpid} + 1;
                    s{^\t}{ };
                    $pidline{$lastpid}{string}{$pgnum} = $_;
                    $current_pid_num{$lastpid} = $pgnum;
                }

                ## No need to do anything more right now
                next;
            } ## end of normal pgmode

            ## Just a bare entry, so process it right away
            $count += process_line($_, $. + $newlines, $filename);

        } ## end of each line in the file

    } ## end of non-CSV mode

    ## Get the new offset and store it
    seek $fh, 0, 1;
    $opt{$curr}{newoffset} = tell $fh;

    close $fh or die qq{Could not close "$filename": $!\n};

    ## Now add in any pids that have not been processed yet
    for my $pid (sort { $pidline{$a}{line} <=> $pidline{$b}{line} } keys %pidline) {
        $count += process_line($pidline{$pid}, 0, $filename);
    }

    if (!$count) {
        $verbose and warn "  No new lines found in file $filename\n";
    }
    else {
        $verbose and warn "  Lines found in $filename: $count\n";
    }

    $opt{grand_total} += $count;

    return $count;

} ## end of parse_file


sub generate_regexes {

    ## Given a filename, generate exclusion and inclusion regexes for it

    ## Currently, all files get the same regex, so we cache it
    if (exists $opt{globalexcluderegex}) {
        return $opt{globalexcluderegex}, $opt{globalincluderegex};
    }

    ## Build an exclusion regex
    my $lexclude = '';
    for my $ex (@{$opt{$curr}{exclude}}) {
        $debug and warn "  Adding exclusion: $ex\n";
        my $regex = qr{$ex};
        $lexclude .= "$regex|";
    }
    $lexclude =~ s/\|$//;
    $verbose and $lexclude and warn "  Exclusion: $lexclude\n";

    ## Build an inclusion regex
    my $linclude = '';
    for my $in (@{$opt{$curr}{include}}) {
        $debug and warn "  Adding inclusion: $in\n";
        my $regex = qr{$in};
        $linclude .= "$regex|";
    }
    $linclude =~ s/\|$//;
    $verbose and $linclude and warn "  Inclusion: $linclude\n";

    $opt{globalexcluderegex} = $lexclude;
    $opt{globalincluderegex} = $linclude;

    return $lexclude, $linclude;

} ## end of generate_regexes


sub process_line {

    ## We've got a complete statement, so do something with it!
    ## If it matches, we'll either put into %find directly, or store in %similar

    my ($arg,$line,$filename) = @_;

    ## The final string
    $string = '';

    if (ref $arg eq 'HASH') {
        for my $l (sort {$a<=>$b} keys %{$arg->{string}}) {
            ## Some Postgres/syslog combos produce ugly output
            $arg->{string}{$l} =~ s/^(?:\s*#011\s*)+//o;
            $string .= ' '.$arg->{string}{$l};
        }
        $line = $arg->{line};
    }
    else {
        $string = $arg;
    }

    ## Bail if it does not match the inclusion regex
    return 0 if $include and $string !~ $include;

    ## Bail if it matches the exclusion regex
    return 0 if $exclude and $string =~ $exclude;

    ## If in duration mode, and we have a minimum cutoff, discard faster ones
    if ($custom_type eq 'duration' and $custom_duration >= 0) {
        return 0 if ($string =~ / duration: (\d+)/o and $1 < $custom_duration);
    }

    $debug and warn "MATCH at line $line of $filename\n";

    ## Force newlines to a single line
    $string =~ s/\n/\\n/go;

    ## Compress all whitespace
    $string =~ s/\s+/ /go;

    ## Strip leading whitespace
    $string =~ s/^\s+//o;

    ## If not in Postgres mode, we avoid all the mangling below
    if (!$pgmode) {
        $find{$filename}{$line} =
                {
                 string   => $string,
                 nonflat  => $string,
                 line     => $line,
                 filename => $filename,
                 count    => 1,
                 };
        return 1;
    }

    ## Save the pre-flattened version
    my $nonflat = $string;

    ## Make some adjustments to attempt to compress similar entries
    if ($flatten) {

        my $thisletter;

        $string =~ s{(VALUES|REPLACE)\s*\((.+)\)}{
            my ($word,$list) = ($1,$2);
            my @word = split(//, $list);
            my $numitems = 0;
            my $status = 'start';
            my @dollar;

          F: for (my $x = 0; $x <= $#word; $x++) {

                $thisletter = $word[$x];
                if ($status eq 'start') {

                    ## Ignore white space and commas
                    if ($thisletter eq ' ' or $thisletter eq '    ' or $thisletter eq ',') {
                        next F;
                    }

                    $numitems++;
                    ## Is this a normal quoted string?
                    if ($thisletter eq q{'}) {
                        $status = 'inquote';
                        next F;
                    }
                    ## Perhaps E'' quoting?
                    if ($thisletter eq 'E') {
                        if (defined $word[$x+1] and $word[$x+1] ne q{'}) {
                            ## So weird we'll just pass it through
                            $status = 'fail';
                            last F;
                        }
                        $x++;
                        $status = 'inquote';
                        next F;
                    }
                    ## Dollar quoting
                    if ($thisletter eq '$') {
                        undef @dollar;
                        {
                            push @dollar => $word[$x++];
                            ## Give up if we don't find a matching dollar
                            if ($x > $#word) {
                                $status = 'fail';
                                last F;
                            }
                            if ($thisletter eq '$') {
                                $status = 'dollar';
                                next F;
                            }
                            redo;
                        }
                    }
                    ## Must be a literal
                    $status = 'literal';
                    next F;
                } ## end status 'start'

                if ($status eq 'literal') {

                    ## May be the end of the whole section
                    if ($thisletter eq ';') {
                        ## Replace what we have, then move on
                        #my $qs = '?,' x $numitems;
                        #chop $qs;
                        $word .= "(?);";
                        $numitems = 0;

                        ## Grab everything forward from this point
                        my $newlist = substr($list,$x+1);

                        if ($newlist =~ m{(.+?(?:VALUES|REPLACE))\s*\(}io) {
                            $word .= $1;
                            $x += length $1;
                        }

                        $status = 'start';
                        next F;
                    }

                    ## Almost always numbers. Just go until a comma
                    if ($thisletter eq ',') {
                        $status = 'start';
                    }
                    next F;
                }

                if ($status eq 'inquote') {
                    ## The only way out is an unescaped single quote
                    if ($thisletter eq q{'}) {
                        next F if $word[$x-1] eq '\\';
                        if (defined $word[$x+1] and $word[$x+1] eq q{'}) {
                            $x++;
                            next F;
                        }
                        $status = 'start';
                    }
                    next F;
                }

                if ($status eq 'dollar') {
                    ## Only way out is a matching dollar escape
                    if ($thisletter eq '$') {
                        ## Possibility
                        my $oldpos = $x++;
                        for (my $y=0; $y <= $#dollar; $y++, $x++) {
                            if ($dollar[$y] ne $thisletter) {
                                ## Tricked us - reset to next position
                                $x = $oldpos;
                                next F;
                            }
                        }
                        ## Got a match!
                        $x++;
                        $status = 'start';
                        next F;
                    }
                }

            } ## end each letter (F)

            if ($status eq 'fail') {
                "$word ($list)";
            }
            else {
                #my $qs = '?,' x $numitems;
                #chop $qs;
                "$word (?)";
            }
        }geix;
        $string =~ s{(\bWHERE\s+\w+\s*=\s*)\d+}{$1?}gio;
        $string =~ s{(\bWHERE\s+\w+\s+IN\s*\().+?\)}{$1?)}gio;
        $string =~ s{(\bWHERE\s+\w+\s*=\s*)'[\d\w]+'}{$1'?')}gio;
        $string =~ s{(UPDATE\s+\w+\s+SET\s+\w+\s*=\s*)'[^']*'}{$1'?'}go;
        $string =~ s/(invalid byte sequence for encoding "UTF8": 0x)[a-f0-9]+/$1????/o;
        $string =~ s{(\(simple_geom,)'.+?'}{$1'???'}gio;
        $string =~ s{(DETAIL: Key \(\w+\))=\(.+?\)}{$1=(?)}go;
        $string =~ s{Failed on request of size \d+}{Failed on request of size ?}go;
        $string =~ s{ARRAY\[.+?\]}{ARRAY[?]}go;
    }

    ## Format the final string a little bit
    if ($pretty_query and $pgmode and $pgmode ne 'csv') {
        for my $word (qw/DETAIL HINT QUERY CONTEXT STATEMENT/) {
            $string =~ s/$word: /\n$word: /;
        }
        $string =~ s/($levelre): /\n$1: /;
        if ($custom_type eq 'duration') {
            $string =~ s/LOG: duration: (\d+\.\d+ ms) LOG: statement: /DURATION: $1\nSTATEMENT: /;
        }
    }

    ## Try to separate into header and body, then check for similar entries
    if ($string =~ /(.+?)(\n?$levelre:.+)/o) {
        my ($head,$body) = ($1,$2);

        ## Seen this body before?
        my $seenit = 0;

        if (exists $similar{$body}) {
            $seenit = 1;
            ## This becomes the new latest one
            $similar{$body}{latest} =
                {
                 string   => $string,
                 nonflat  => $nonflat,
                 line     => $line,
                 filename => $filename,
                 };
            ## Increment the count
            $similar{$body}{count}++;
        }

        if (!$seenit) {
            ## Store as the earliest and latest version we've seen
            $similar{$body}{earliest} = $similar{$body}{latest} =
                {
                 string   => $string,
                 nonflat  => $nonflat,
                 line     => $line,
                 filename => $filename,
                 };
            ## Start counting these items
            $similar{$body}{count} = 1;
            ## Store this away for eventual output
            $find{$filename}{$line} = $similar{$body};
            ## Copy filename and line up a level for later sorting ease
            $find{$filename}{$line}{filename} = $similar{$body}{earliest}{filename};
            $find{$filename}{$line}{line} = $similar{$body}{earliest}{line};
        }
    }
    else {
        $find{$filename}{$line} = {
            string   => $string,
            count    => 1,
            line     => $line,
            filename => $filename,
            nonflat  => $nonflat,
        };
    }

    return 1;

} ## end of process_line


sub process_report {

    ## Create the mail message
    my ($fh, $tempfile) = tempfile('tnmXXXXXXXX', SUFFIX => '.tnm');

    if ($dryrun) {
        close $fh or warn 'Could not close filehandle';
        $fh = \*STDOUT;
    }

    if (! @files_parsed) {
        $quiet or warn qq{No files were read in, exiting\n};
        exit 1;
    }

    ## How many files actually had things?
    my $matchfiles = 0;
    ## How many unique items?
    my $unique_matches = 0;
    for my $f (values %find) {
        $unique_matches += keys %{$f};
    }
    my $pretty_unique_matches = pretty_number($unique_matches);
    ## Which was the latest to contain something?
    my $last_file_parsed;
    for my $file (@files_parsed) {
        next if ! $file->[1];
        $matchfiles++;
        $last_file_parsed = $file->[0];
    }

    my $grand_total = $opt{grand_total};
    my $pretty_grand_total = pretty_number($grand_total);

    ## If not files matched, output the last one processed
    $last_file_parsed = $files_parsed[-1]->[0] if ! defined $last_file_parsed;

    ## Subject with replaced keywords:
    my $subject = $opt{$curr}{mailsubject} || $DEFAULT_SUBJECT;
    $subject =~ s/FILE/$last_file_parsed/g;
    $subject =~ s/HOST/$hostname/g;
    if ($tsepnosub or $opt{$curr}{tsepnosub}) {
        $subject =~ s/NUMBER/$grand_total/g;
        $subject =~ s/UNIQUE/$unique_matches/g;
    }
    else {
        $subject =~ s/NUMBER/$pretty_grand_total/g;
        $subject =~ s/UNIQUE/$pretty_unique_matches/g;
    }
    print {$fh} "Subject: $subject\n";

    ## Discourage vacation programs from replying
    print {$fh} "Auto-Submitted: auto-generated\n";
    print {$fh} "Precedence: bulk\n";

    ## Some minor help with debugging
    print {$fh} "X-TNM-VERSION: $VERSION\n";

    ## Fill out the "To:" fields
    for my $email (@{$opt{$curr}{email}}) {
        print {$fh} "To: $email\n";
    }
    if (! @{$opt{$curr}{email}}) {
        die "Cannot send email without knowing who to send to!\n";
    }

    my $mailcom = $opt{$curr}{mailcom} || $MAILCOM;

    ## Custom From:
    my $from_addr = $opt{$curr}{from} || '';
    if ($from_addr ne '') {
        print {$fh} "From: $from_addr\n";
        $mailcom .= " -f $from_addr";
    }
    ## End header section
    print {$fh} "\n";

    my $now = scalar localtime;
    print {$fh} "Date: $now\n";
    print {$fh} "Host: $hostname\n";
    if ($timewarp) {
        print {$fh} "Timewarp: $timewarp\n";
    }
    if ($custom_duration >= 0) {
        print {$fh} "Minimum duration: $custom_duration ms\n";
    }

    print {$fh} "Unique items: $pretty_unique_matches\n";

    ## If we parsed more than one file, label them now
    if ($matchfiles > 1) {
        my $letter = 0;
        print {$fh} "Total matches: $pretty_grand_total\n";
        my $maxcount = 1;
        my $maxletter = 1;
        for my $file (@files_parsed) {
            next if ! $file->[1];
            $file->[1] = pretty_number($file->[1]);
            $maxcount = length $file->[1] if length $file->[1] > $maxcount;
            my $name = chr(65+$letter);
            if ($letter >= 26) {
                $name = sprintf '%s%s',
                    chr(64+($letter/26)), chr(65+($letter%26));
            }
            $letter++;
            $fab{$file->[0]} = $name;
            $maxletter = length $name if length $name > $maxletter;
        }
        for my $file (@files_parsed) {
            next if ! $file->[1];
            my $name = $fab{$file->[0]};
            printf {$fh} "Matches from %-*s %s: %*s\n",
                $maxletter + 2,
                "[$name]",
                $file->[0],
                $maxcount,
                $file->[1];
        }
    }
    else {
        print {$fh} "Matches from $last_file_parsed: $pretty_grand_total\n";
    }

    for my $file (@files_parsed) {
        if (exists $toolarge{$file->[0]}) {
            print {$fh} "$toolarge{$file->[0]}\n";
        }
    }

    if ($custom_type eq 'duration' and $duration_limit and $grand_total > $duration_limit) {
        print {$fh} "Not showing all lines: duration limit is $duration_limit\n";
    }

    ## The meat of the message
    lines_of_interest($fh, $matchfiles);

    print {$fh} "\n";
    close $fh or die qq{Could not close "$tempfile": $!\n};

    my $emails = join ' ' => @{$opt{$curr}{email}};
    $verbose and warn "  Sending mail to: $emails\n";
    my $COM = qq{$mailcom $emails < $tempfile};
    if ($dryrun or $nomail) {
        $quiet or warn "  DRYRUN: $COM\n";
        unlink $tempfile;
        return;
    }

    my $mailmode = $opt{$curr}{mailmode} || $MAILMODE;
    if ($MAILMODE eq 'sendmail') {
        system $COM;
    }
    elsif ($MAILMODE eq 'smtp') {
        send_smtp_email($from_addr, $emails, $subject, $tempfile);
    }
    else {
        die "Unknown mailmode: $mailmode\n";
    }
    unlink $tempfile;

    return;

} ## end of process_report


sub send_smtp_email {

    ## Send email via an authenticated SMTP connection

    ## For Windows, you will need:
    # perl 5.10
    # http://cpan.uwinnipeg.ca/PPMPackages/10xx/
    # ppm install Net_SSLeay.ppd
    # ppm install IO-Socket-SSL.ppd
    # ppm install Authen-SASL.ppd
    # ppm install Net-SMTP-SSL.ppd

    ## For non-Windows:
    # perl-Net-SMTP-SSL package
    # perl-Authen-SASL

    my ($from_addr,$emails,$subject,$tempfile) = @_;

    require Net::SMTP::SSL;

    ## Absorb any values set by rc files, and sanity check things
    my $mailserver = $opt{$curr}{mailserver} || $MAILSERVER;
    if ($mailserver eq 'example.com') {
        die qq{When using smtp mode, you must specify a mailserver!\n};
    }
    my $mailuser = $opt{$curr}{mailuser} || $MAILUSER;
    if ($mailuser eq 'example') {
        die qq{When using smtp mode, you must specify a mailuser!\n};
    }
    my $mailpass = $opt{$curr}{mailpass} || $MAILPASS;
    if ($mailpass eq 'example') {
        die qq{When using smtp mode, you must specify a mailpass!\n};
    }
    my $mailport = $opt{$curr}{mailport} || $MAILPORT;

    ## Attempt to connect to the server
    my $smtp;
    if (not $smtp = Net::SMTP::SSL->new(
        $mailserver,
        Port    => $mailport,
        Debug   => 0,
        Timeout => 30,
    )) {
        die qq{Failed to connect to mail server: $!};
    }

    ## Attempt to authenticate
    if (not $smtp->auth($mailuser, $mailpass)) {
        die 'Failed to authenticate to mail server: ' . $smtp->message;
    }

    ## Prepare to send the message
    $smtp->mail($from_addr) or die 'Failed to send mail (from): ' . $smtp->message;
    $smtp->to($emails)      or die 'Failed to send mail (to): '   . $smtp->message;
    $smtp->data()           or die 'Failed to send mail (data): ' . $smtp->message;
    ## Grab the lines from the tempfile and pipe it on to the server
    open my $fh, '<', $tempfile or die qq{Could not open "$tempfile": $!\n};
    while (<$fh>) {
        $smtp->datasend($_);
    }
    close $fh or warn qq{Could not close "$tempfile": $!\n};
    $smtp->dataend() or die 'Failed to send mail (dataend): ' . $smtp->message;
    $smtp->quit      or die 'Failed to send mail (quit): '    . $smtp->message;

    return;

} ## end of send_smtp_email


sub lines_of_interest {

    ## Given a file handle, print all our current lines to it

    my ($lfh,$matchfiles) = @_;

    my $oldselect = select $lfh;

    our ($current_filename, %sorthelp);
    undef %sorthelp;

    sub sortsub {
        my $sorttype = $opt{$curr}{sortby} || $sortby;

        if ($custom_type eq 'duration') {
            if (! exists $sorthelp{$a}) {
                my $lstring = $a->{string} || $a->{earliest}{string};
                $sorthelp{$a} =
                    $lstring =~ /duration: (\d+\.\d+)/ ? $1 : 0;
            }
            if (! exists $sorthelp{$b}) {
                my $lstring = $b->{string} || $b->{earliest}{string};
                $sorthelp{$b} =
                    $lstring =~ /duration: (\d+\.\d+)/ ? $1 : 0;
            }
            return ($sorthelp{$b} <=> $sorthelp{$a})
                    || ($fileorder{$a->{filename}} <=> $fileorder{$b->{filename}})
                    || ($a->{line} <=> $b->{line});
        }
        elsif ($sorttype eq 'count') {
            return ($b->{count} <=> $a->{count})
                    || ($fileorder{$a->{filename}} <=> $fileorder{$b->{filename}})
                    || ($a->{line} <=> $b->{line});
        }
        elsif ($sorttype eq 'date') {
            return ($fileorder{$a->{filename}} <=> $fileorder{$b->{filename}})
                || ($a->{line} <=> $b->{line});

        }

        return $a <=> $b;
    }

    ## Flatten the items for ease of sorting
    my @sorted;
    for my $f (keys %find) {
        for my $l (keys %{$find{$f}}) {
            push @sorted => $find{$f}{$l};
        }
    }

    my $count = 1;
    for my $f (sort sortsub @sorted) {

        last if $showonly and $count > $showonly;

        ## Sometimes we don't want to show all the durations
        if ($custom_type eq 'duration' and $duration_limit) {
            last if $count > $duration_limit;
            ## XXX Print something?
        }

        print "\n[$count]";
        $count++;

        my $filename = exists $f->{earliest} ? $f->{earliest}{filename} : $f->{filename};

        ## If only a single entry, simpler output
        if ($f->{count} == 1) {
            if ($matchfiles > 1) {
                printf " From file %s%s\n",
                    $fab{$filename},
                    $find_line_number ? " (line $f->{line})" : '';
            }
            elsif ($find_line_number) {
                print " (from line $f->{line})\n";
            }
            else {
                print "\n";
            }
            my $string = wrapline(exists $f->{earliest} ? $f->{earliest}{string} : $f->{string});
            print "$string\n";
            next;
        }

        ## More than one entry means we have an earliest and latest to look at
        my $earliest = $f->{earliest};
        my $latest = $f->{latest};
        my $pcount = pretty_number($f->{count});

        ## Does it span multiple files?
        my $samefile = $earliest->{filename} eq $latest->{filename} ? 1 : 0;
        if ($samefile) {
            if ($matchfiles > 1) {
                print " From file $fab{$filename}";
                if ($find_line_number) {
                    print " (between lines $f->{line} and $latest->{line}, occurs $pcount times)";
                }
                else {
                    print " Count: $f->{count}";
                }
                print "\n";
            }
            else {
                if ($find_line_number) {
                    print " (between lines $f->{line} and $latest->{line}, occurs $pcount times)";
                }
                else {
                    print " Count: $pcount";
                }
                print "\n";
            }
        }
        else {
            my ($A,$B) = ($fab{$earliest->{filename}}, $fab{$latest->{filename}});
            print " From files $A to $B";
            if ($find_line_number) {
                printf " (between lines $f->{line} of $A and $latest->{line} of $B, occurs $pcount times)",;
            }
            else {
                print " Count: $pcount";
            }
            print "\n";
        }

        ## If we can, show just the interesting part
        my $estring = $earliest->{string};
        my $lstring = $latest->{string};
        if ($pgmode and $pgmode ne 'csv' and $estring =~ s/$pgpiddatere(.+)/$2/) {
            my $headstart = $1;
            $lstring =~ /$pgpiddatere/ or die "Latest did not match?!\n";
            my $headend = $1; ## no critic (ProhibitCaptureWithoutTest)
            printf "First: %s%s\nLast:  %s%s\n",
                $samefile ? '' : "[$fab{$earliest->{filename}}] ",
                $headstart,
                $samefile ? '' : "[$fab{$latest->{filename}}] ",
                $headend;
            $estring =~ s/^\s+//o;
            print wrapline($estring);
            print "\n";
        }
        else {
            print " Earliest and latest:\n";
            print wrapline($estring);
            print "\n";
            print wrapline($lstring);
            print "\n";
        }

    } ## end each item

    select $oldselect;

    return;

} ## end of lines_of_interest


sub wrapline {

    ## Quick and simple wrapper around very long lines to make SMTP servers happy

    my $line = shift;

    return $line if length $line < $WRAPLIMIT;

    $line =~ s{(.{$WRAPLIMIT})}{$1\n}g;

    return $line;

} ## end of wrapline


sub final_cleanup {

    $debug and warn "  Performing final cleanup\n";

    ## If offset has changed, save it
    my $newoffset = 0;
    if (exists $opt{$curr}{newoffset}) {
        $changes++;
        $newoffset = $opt{$curr}{newoffset};
        $verbose and warn "  Setting offset to $newoffset\n";
    }

    ## Reset always rewrites the file, even in dryrun mode
    if (($changes and !$dryrun) or $reset) {
        $verbose and warn "  Saving new config file (changes=$changes)\n";
        open my $fh, '>', $configfile or die qq{Could not write "$configfile": $!\n};
        my $oldselect = select $fh;
        my $now = localtime;
        print qq{## Config file for the tail_n_mail.pl program
## This file is automatically updated
## Last updated: $now
};

        for my $item (qw/ email from pgformat type duration find_line_number sortby duration_limit/) {
            next if ! exists $opt{$curr}{$item};
            next if $item eq 'duration' and $custom_duration < 0;
            next if $item eq 'duration_limit' and ! $duration_limit;
            ## Only rewrite if it came from this config file, not tailnmailrc or command line
            next if ! exists $opt{configfile}{$item};
            add_comments(uc $item);
            if (ref $opt{$curr}{$item} eq 'ARRAY') {
                for my $itemz (@{$opt{$curr}{$item}}) {
                    next if ! exists $opt{configfile}{"$item.$itemz"};
                    printf "%s: %s\n", uc $item, $itemz;
                }
            }
            else {
                printf "%s: %s\n", uc $item, $opt{$curr}{$item};
            }
        }
        if ($opt{configfile}{maxsize}) {
            print "MAXSIZE: $opt{$curr}{maxsize}\n";
        }
        if ($opt{$curr}{customsubject}) {
            add_comments('MAILSUBJECT');
            print "MAILSUBJECT: $opt{$curr}{mailsubject}\n";
        }

        print "\n";
        add_comments('FILE');
        print "FILE: $opt{$curr}{original_filename}\n";
        print "LASTFILE: $opt{$curr}{filename}\n";
        print "OFFSET: $newoffset\n";
        for my $inherit (@{$opt{$curr}{inherit}}) {
            add_comments("INHERIT: $inherit");
            print "INHERIT: $inherit\n";
        }
        for my $include (@{$opt{$curr}{include}}) {
            next if ! exists $opt{configfile}{"include.$include"};
            add_comments("INCLUDE: $include");
            print "INCLUDE: $include\n";
        }
        for my $exclude (@{$opt{$curr}{exclude}}) {
            next if ! exists $opt{configfile}{"exclude.$exclude"};
            add_comments("EXCLUDE: $exclude");
            print "EXCLUDE: $exclude\n";
        }
        print "\n";

        select $oldselect;
        close $fh or die qq{Could not close "$configfile": $!\n};
    }

    return;

} ## end of final_cleanup


sub add_comments {

    my $item = shift;
    return if ! exists $itemcomment{$item};
    for my $comline (@{$itemcomment{$item}}) {
        print $comline;
    }

    return;

} ## end of add_comments


sub pretty_number {

    ## Format a raw number in a more readable style

    my $number = shift;

    return $number if $number !~ /^\d+$/ or $number < 1000;

    ## If this is our first time here, find the correct separator
    if (! defined $tsep) {
        if (exists $opt{$curr}{tsep}) {
            $tsep = $opt{$curr}{tsep};
            return pretty_number($number);
        }
        eval {
            require POSIX;
        };
        if ($@) {
            ## Default to no separator
            $tsep = '';
            return $number;
        }
        my $lconv = POSIX::localeconv();
        $tsep = $lconv->{thousands_sep} || ',';
    }

    ## No formatting at all
    return $number if '' eq $tsep or ! $tsep;

    (my $reverse = reverse $number) =~ s/(...)(?=\d)/$1$tsep/g;
    $number = reverse $reverse;
    return $number;

} ## end of pretty_number

__DATA__

## Example config file:

## Config file for the tail_n_mail.pl program
## This file is automatically updated
EMAIL: someone@example.com
MAILSUBJECT: Acme HOST Postgres errors (FILE)

FILE: /var/log/postgresql-%Y-%m-%d.log
INCLUDE: ERROR:  
INCLUDE: FATAL:  
INCLUDE: PANIC:  
