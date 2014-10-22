package Dir::Rocknroll ;

####################################################
#
# Rock'n'Roll : Rsync fOr baCKup and Roll
#
# http://math.univ-angers.fr/~charbonnel/rocknroll
# Jacquelin Charbonnel - CNRS/Mathrice/LAREMA - 2006-09-04
#
# $Id: rocknroll 22 2012-07-24 11:57:10Z jacquelin.charbonnel $
#
####################################################

require Exporter ;
@ISA = qw(Exporter);
@EXPORT=qw() ;
@EXPORT_OK = qw( );

use 5.006;
use Carp;
use strict;

our $VERSION = "0.".eval{'$Rev: 24 $'=~/(\d+)/;$1;} ;

use Data::Dumper ;
use Sys::Syslog ;
use File::Path::Tiny;
use Getopt::Long ;
use File::Basename ;
use FileHandle ;
use DirHandle ;
use FindBin ;
use Net::SMTP ;
use Sys::Hostname;
use Config::General ;
use Config::General::Extended ;
use Dir::Which q/which/;

# binaries
my $RSYNC = "/usr/bin/rsync" ;

my $this_prog = 'rocknroll' ;
my $NEW_EXT = "_running_snapshot_" ;
my $OLD_EXT = "_snapshot_to_delete_" ;
my $CONFFILE = "$this_prog.conf" ;
my $CONFPATH = $FindBin::Bin.":".$FindBin::Bin."/../etc:/etc:/etc/${this_prog}.d" ;
my $FACILITY = "local7" ;
my %arg_conf ;

my $default_conf = {
  "continue" => 0
  , "debug" => 0
  , "dry-run" => 0
  , "refresh" => 0
  , "link-dest" => ""
  , "mail_from" => 'root@localhost'
  , "mail_to" => 'root@localhost'
  , "max_runtime" => 360  # 6h
  , "no-links" => 0
  , "no-roll" => 0
  , "rsync_path" => "/usr/bin/rsync"
  , "rsync_retcode_ok" => 0
  , "rsync_retcode_warn" => 24
  , "ro" => ["--stats"]
  , "ro_default" => "--hard-links --xattrs --archive -e ssh"
  , "send_warn" => 0
  , "smtp_server" => "localhost"
  , "update" => 0
  , "use_syslog" => 1
  , "verbose" => 0
} ;

my ($log,@files,$init,@excludes,@rsync_options,$dry_run,$config,$config_file,$arg) ;

############################################################

{
  package _Log ;
  require Exporter ;
  our @ISA = qw(Exporter);
  our @EXPORT=qw() ;

  use Carp ;
  use Data::Dumper ;
  use Dir::Which q/which/ ;
  use Sys::Syslog ;

  #my ($DEBUG,$INFO,$WARN,$ERR) = (1,2,3,4) ;

  #--------------------
  sub new
  {
    my($type,$cmdline,$level) = @_ ;
    my($this) ;

    # %h = map { /^-/ ? lc(substr($_,1)) : $_ ; } %h ;

    $this->{"level"} = $level ;
    $this->{"cmdline"} = $cmdline ;
    $this->{"log"} = [] ;
    $this->{"criticity"} = 0 ;

    bless $this,$type ;

    openlog($this_prog,"ndelay,pid", "local0") ;
    return $this ;
  }

  sub set_level
  {
    my($this,$level) = @_ ;
    $this->{"level"} = $level ;
  }

  sub send
  {
    my ($this)=@_ ;

    return unless scalar(@{$this->{"log"}}>0) ;

    my $smtp_server = $config->get("smtp_server") ;
    my $smtp ;

    if ($smtp = Net::SMTP->new($smtp_server))
    {
      #die Dumper $smtp_server ;
      $smtp->mail($config->get("mail_from"));
      $smtp->to($config->get("mail_to"));

      $smtp->data();
      $smtp->datasend("From: ".$config->get("mail_from")."\n");
      $smtp->datasend("To: ".$config->get("mail_to")."\n");
      $smtp->datasend("Subject: $this_prog ".$this->{"criticity"}."\n");
      $smtp->datasend("\n");
      $smtp->datasend("running command : $this_prog ".$this->{"cmdline"}."\n");
      $smtp->datasend("output :\n");
      $smtp->datasend(join("\n",@{$this->{"log"}}));
      $smtp->dataend();
      $smtp->quit;
    }
    else
    {
      $this->warn("can't connect to the SMTP server '$smtp_server'") ;
      print join("\n",@$log) ;
    }
  }
  #--------------------
  sub debug
  {
    my($this,$msg) = @_ ;
    print "$msg\n" if $this->{"level"}==2 ;
  }
  sub info
  {
    my($this,$msg) = @_ ;
    if ($this->{"level"}>=1)
    {
      if ($config->get("use_syslog")==1) { syslog("info",$msg) ; }
      print "$msg\n" ;
    }
  }
  sub warn
  {
    my($this,$msg) = @_ ;
    if ($config->get("use_syslog")==1) { syslog("warn",$msg) ; }
    else { print "$msg\n" ; }
  }
  sub crit
  {
    my($this,$msg) = @_ ;
    if ($config->get("use_syslog")==1) { syslog("crit",$msg) ; }
    die "$msg\nExecution aborted !\n" ;
    }
  sub warn_by_mail
  {
    my($this,$msg) = @_ ;

    $this->{"criticity"} = "warn" ;
    if ($config->get("mail_to")=~/\S/ && $config->get("send_warn")==1)
      {
      push(@{$this->{"log"}},"WARN: $msg") ;
      syslog("info",split(/\n/,$msg)) if $config->get("use_syslog")==1 ;
      }
    else
      { $this->warn($msg) ; }
  }
  sub crit_by_mail
  {
    my($this,$msg) = @_ ;

    $this->{"criticity"} = "crit" ;
    if ($config->get("mail_to")=~/\S/)
    {
      push(@{$this->{"log"}},"CRIT: $msg") ;
      syslog("info",$msg) if $config->get("use_syslog")==1 ;
    }
    $this->crit($msg) ;
    }
}
END { $log->send() if $log ; closelog() ; }

############################################################

{
  package Config ;
  require Exporter ;
  our @ISA = qw(Exporter);
  our @EXPORT=qw() ;

  use Carp ;
  use Data::Dumper ;
  use Dir::Which q/which/ ;

  #--------------------
  sub new
  {
    my($type,%h) = @_ ;
    my($this) ;

    %h = map { /^-/ ? lc(substr($_,1)) : $_ ; } %h ;

    $this->{"args"} = \%h ;

    bless $this,$type ;
    return $this ;
  }

  #--------------------
  sub init
  {
    my($this,$default,$arg) = @_ ;

    $this->{"default"} = $default ;
    $this->{"arg"} = $arg ;
  }

  #--------------------
  sub get_arg
  {
    my($this,$arg) = @_ ;
    carp "arg '$arg' undefined" unless exists($this->{"args"}{$arg}) ;
    return $this->{"args"}{$arg} ;
  }
  #--------------------
  sub load
  {
    my($this) = @_ ;
    my $file = $this->get_arg("file") ;
    my $path = $this->get_arg("path") ;

    my $confname = which(-entry=>$file
            ,-defaultpath=>$path
            ) ;
    return unless defined $confname ;

    my $conffile=new Config::General(-ConfigFile=>$confname,-ExtendedAccess => 1) or $log->warn("can't read config file $confname") ;
    my %conf ;
    {
      my %this_conf = $conffile->getall() ;
      for my $k (keys %this_conf)
      {
        die "unknown parameter '$k' in $file\n" unless exists $this->{"default"}{$k} ;
        $conf{$k} = $this_conf{$k} ;
      }
    }
    # die Dumper \%conf ;
    $this->{"conf"} = \%conf ;
  }
  sub get
  {
    my($this,$var) = @_ ;

    return $this->{"arg"}{$var} if exists($this->{"arg"}{$var}) ;
    return $this->{"conf"}{$var} if exists($this->{"conf"}{$var}) ;
    return $this->{"default"}{$var} if exists($this->{"default"}{$var}) ;
    die "'$var' not found in config\n" ;
  }
}

############################################################

{
  package RocknRoll ;
  require Exporter ;
  our @ISA = qw(Exporter);
  our @EXPORT=qw() ;

  use Carp ;
  use Data::Dumper ;
  use Dir::Which q/which/ ;
  use File::stat ;

  #--------------------
  sub new
  {
    my($type,$dstdir,$interval) = @_ ;
    my($this) ;

    $this->{"dstdir"} = $dstdir ;
    $this->{"interval"} = $interval ;
    $this->{NORMAL} = 1 ;
    @{$this->{rsync_opt}} = () ;

    # get files
    my $d = new DirHandle($dstdir) or $log->crit("can't read directory $dstdir: $!\n") ;
    @{$this->{"files"}} = $d->read() ;

    bless $this,$type ;

    $this->check_if_running() unless $config->get("continue") ;

    return $this ;
  }
  #--------------------
  sub get_archives
  {
    my($this) = @_ ;
    my $interval = $this->{"interval"} ;

    return grep /^$interval.\d+$/,@{$this->{"files"}} ;
  }
  #--------------------
  sub check_if_running
  {
    my($this) = @_ ;
    my $dstdir = $this->{"dstdir"} ;
    my $interval = $this->{"interval"} ;
    my @files = @{$this->{"files"}} ;
    my $running = ".$interval.running" ;

    if ( grep /^$running$/,@files )
    {
      $this->{"running_exists"} = 1 ;
      my $st = stat($this->{"dstdir"}."/$running") ;
      if (time()-$st->ctime < $config->get("max_runtime")*60)
      {
        $log->crit_by_mail(sprintf("a directory '$dstdir/$running' (with ctime<%dmin) found.",$config->get("max_runtime"))) ;
      }
      else
      {
        $log->warn_by_mail("a directory '$running' already exists in '$dstdir', it will be overwritten.") ;
        push(@{$this->{rsync_opt}},"--delete") ;
      }
    }
  }

  #--------------------
  sub read_control
  {
    my($this,$nb) = @_ ;

    my $dstdir = $this->{"dstdir"} ;
    my $interval = $this->{"interval"} ;

    if (open F,"$dstdir/.$interval.ctl")
    {
      my $line = <F> ;
      close(F) ;
      if ($line=~/^\s*nb_archives\s*:\s*\d+\s*$/)
      {
        my ($nb) = $line=~/^\s*nb_archives\s*:\s*(\d+)\s*$/ ;
        return $nb ;
      }
      else { return -1 ; }
    }
    else { return -1 ; }
  }
  #--------------------
  sub write_control
  {
    my($this,$nb) = @_ ;

    my $dstdir = $this->{"dstdir"} ;
    my $interval = $this->{"interval"} ;

    open F,">$dstdir/.$interval.ctl" or die "$!" ;
    print F "nb_archives:$nb" ;
    close(F) ;
  }
  #--------------------
  sub check_if_complete
  {
    my($this) = @_ ;

    my $dstdir = $this->{"dstdir"} ;
    my $interval = $this->{"interval"} ;

    my @archives = $this->get_archives() ;
    die("No archive found in $dstdir for interval $interval !\n"
      ."(you must do  '$this_prog --init n $interval $dstdir'  first),\n\twhere n is the number of archives expected\n")
      if @archives==0 ;

    my $found = @archives ;
    my $require = $this->read_control() ;

    if ($require!=-1)
    {
      if ($require > $found)
      {
        my $diff = $require-$found ;
        my $un = $diff==1 ;
        $log->warn_by_mail(sprintf("%s archive%s missing in %s",$diff,$un?"":"s",$this->{"dstdir"})) ;
        $this->{NORMAL} = 0 ;
      }
      elsif ($require < $found)
      {
        $log->warn_by_mail("$require archives required, but $found found !!") ;
        $this->{NORMAL} = 0 ;
        # que faire ?
      }
    }
    else
    {
      $log->warn_by_mail("no control file found in ".$this->{"dstdir"}.", $found required archives supposed") ;
      $this->write_control($found) ;
    }
    $this->{"require"} = $require ;
    $this->{"found"} = $found ;
  }
  #--------------------
  sub mkdirs
  {
    my($this,$nb) = @_ ;

    my $dstdir = $this->{"dstdir"} ;
    my $interval = $this->{"interval"} ;
    my @files = grep /^$interval.\d+$/,@{$this->{"files"}} ;
    my $running = ".$interval.running" ;

    die("'$interval' archives already exist on $dstdir, abort !\n") if @files!=0 ;

    for my $i (1..$nb)
    {
      my $dir = "$dstdir/$interval.$i" ;
      mkdir $dir or die("can't create $dir, abort !\n") ;
    }
    $this->write_control($nb) ;
  }
  #--------------------
  sub rock
  {
    my($this,$srcdir) = @_ ;

    my $dstdir = $this->{"dstdir"} ;
    my $interval = $this->{"interval"} ;
    my @files = @{$this->{"files"}} ;
        my $running = ($config->get("refresh") || $config->get("update"))
                  ? "$interval.1"
                  : ".$interval.running" ;

    my $jro = join(" ",@{$config->get("ro")}) ;
    push(@{$this->{rsync_opt}},"--delete") if $config->get("update") ;
    my $require = $this->{"require"} ;

    # options
    my $ld ;
    if ($config->get("no-links")==1)
    {
      $ld = "" ;
    }
    else
    {
      $ld = exists($this->{"linkdest"})
        ? "--link-dest=$this->{'linkdest'}"
        : "--link-dest=../${interval}.1" ;
    }

    my $cmd = sprintf("%s %s %s %s $ld $srcdir $dstdir/$running"
            , $config->get("rsync_path")
            , join(" ",@{$this->{rsync_opt}})
            , $config->get("ro_default")
            , $jro
    ) ;

    my $retcode = main::_myexec($cmd) ;
    $log->crit_by_mail("$dstdir/$running not found after rsync execution") unless -d "$dstdir/$running" ;
    return $retcode ;
  }
  #--------------------
  sub roll
  {
    my($this) = @_ ;

    my $dstdir = $this->{"dstdir"} ;
    my $interval = $this->{"interval"} ;
    my $require = $this->{"require"} ;
    my @files = grep /^$interval.\d+$/,@{$this->{"files"}} ;
    my $running = ".$interval.running" ;
    my $found = $this->{"found"} ;
    my (@to_roll,@exist,@next_rank,@steps,@roll,@place) ;

    # determine the future rank of each archive
    my ($i,$j) = (1,2) ;

    while ($found>0)
    {
      if (scalar(grep(/^$interval.$i$/,@files)) == 1)
      {
        # this archive exists
        $found-- ;
        $j=-1 if $j>$require || $j==0 ;
        push @to_roll,$i ;
        $exist[$i] = 1 ;
        $place[$i] = 1 ;
        $next_rank[$i] = $j ;
        $j++ ;
      }
      else
      {
        $exist[$i] = 0 ;
      }
      $i++ ;
    }

    # determine the order of future rename operation
    my $again ;
    do
    {
      $again = 0 ;
      for $i (reverse @to_roll)
      {
        next unless $exist[$i]==1 ; # this archive doesn't exist
        next if defined($roll[$i]) && $roll[$i]==1 ; # this archive has already rolled
        next if $next_rank[$i]!=-1 && defined($place[$next_rank[$i]]) && $place[$next_rank[$i]]==1 ; # next place is not free
        $log->debug("exist: ".Dumper \@exist) ;
        $log->debug("roll: ".Dumper \@roll) ;
        $log->debug("next_rank: ".Dumper \@next_rank) ;
        $log->debug("place: ".Dumper \@place) ;
        $again = 1 ; # at least one archive performed

        # oldest(s) archives to delete
        if ($next_rank[$i]==-1)
        {
          push @steps,[$i,-1] ;
          $place[$i] = 0 ;
          $roll[$i] = 1 ;
          next ;
        }

        # is the next rank free ?
        #if (! (defined($next_rank[$i]) && defined($place[$next_rank[$i]]) && $place[$next_rank[$i]]==1))
        if (! (defined($place[$next_rank[$i]]) && $place[$next_rank[$i]]==1))
        {
          push @steps,[$i,$next_rank[$i]] ;
          $place[$next_rank[$i]] = 1 ;
          $place[$i] = 0 ;
          $roll[$i] = 1 ;
        }
      }
    } while $again ;
    $log->debug("NORMAL: ".$this->{NORMAL}) ;
    $log->debug("steps: ".Dumper \@steps) ;
    for my $s (@steps)
    {
      my($old,$new) = @$s ;
      my $msg ;

      if ($new==-1)
      {
        my $path = sprintf("%s/%s.%d"
          ,$this->{"dstdir"}
          ,$this->{"interval"}
          ,$old
          ) ;
        $msg = sprintf("delete $path") ;
        File::Path::Tiny::rm($path) or $log->crit("can't remove $path: $!") ;
      }
      else
      {
        my $src = sprintf("%s/%s.%d",
          ,$this->{"dstdir"}
          ,$this->{"interval"}
          ,$old
          ) ;
        my $dst = sprintf("%s/%s.%d"
          ,$this->{"dstdir"}
          ,$this->{"interval"}
          ,$new
          ) ;
        $msg = "rename $src $dst" ;
        rename($src,$dst) or $log->crit("can't rename $src to $dst: $!") ;
      }
      $log->info($msg) ;
      $log->warn_by_mail($msg) if $this->{NORMAL}==0 ;
    }
    {
      my $src = sprintf("%s/.%s.running",$this->{"dstdir"},$this->{"interval"}) ;
      my $dst = sprintf("%s/%s.1",$this->{"dstdir"},$this->{"interval"}) ;
      my $msg = sprintf("rename $src $dst") ;
      $log->info($msg) ;
      $log->warn_by_mail($msg) if $this->{NORMAL}==0 ;
      rename($src,$dst) or $log->crit("can't rename $src to $dst: $!") ;
    }
  }
}

############################################################

#--------------------
sub _man
{
  use Pod::Perldoc ;

  @ARGV = ($this_prog) ;
  exit(Pod::Perldoc->run($this_prog,undef)) ;
}

#--------------------
sub _usage
{
  my($msg) = @_ ;

  print(<< "EOF") ;
Rsync fOr baCKup (and roll) - v$VERSION

$msg

Usage: $this_prog --init n interval_name dstdir (1)
       $this_prog options interval_name srcdir dstdir (2)
       $this_prog --man

  common options :
    --debug (1)(2)
    --excludes=DIR (2)
    --ro rsync_option (2)
    --link-dest=DIR (2)
    --no-roll (2)
    --refresh (2)
    --update (2)
    --continue (2)

  example :
    $this_prog --init 7 daily /var/snapshots/home
    creates an archive directory structure

    $this_prog daily /home /var/snapshots/home
    rsync a new copy and roll the archives

EOF
exit(0) ;
}

#--------------------
sub _myexec
{
  my ($cmd) = @_ ;

  $log->info("exec: $cmd") ;
    my @output ;
    my $fcmd = new FileHandle("$cmd 2>&1|") or $log->crit_by_mail("can't execure $cmd: $!") ;
  my $output ;
    while (<$fcmd>)
    {
    chomp ;
    $log->info("> $_") ;
    push(@output,"> $_") ;
    }
  my $rc = $fcmd->close() ;

  if ($rc)
  {
    # all rights
    $log->info(sprintf("return: %d (rc=$rc)",$?>>8)) ;
    return 2 ;
  }

  $log->crit_by_mail(sprintf("can't execure $cmd (rc=$rc, \$!==$!)")) if ($!) ;

  # some issues remains...
  my $retcode = $?>>8 ;
  $log->info(sprintf("return: %d",$retcode)) ;
  my %ok_codes = map { $_ => 1 ; } split(/[^\d]+/,$config->get("rsync_retcode_ok")) ;
  my %warn_codes = map { $_ => 1 ; } split(/[^\d]+/,$config->get("rsync_retcode_warn")) ;

  # case known as OK
  return 2 if (exists($ok_codes{$retcode}) && $ok_codes{$retcode}==1) ;

  # case not known as WARNING -> ERROR
  unless (exists($warn_codes{$retcode}) && $warn_codes{$retcode}==1)
  {
    $log->crit_by_mail(sprintf("'$cmd' returns %d (not found in OK et WARN codes)\n%s",$retcode,join("\n",@output))) ;
    return 0 ;
  }

  # other case : WARNING
  $log->warn_by_mail(sprintf("'$cmd' returns %d\n%s",$retcode,join("\n",@output))) ;
  return 1 ;
}

#--------------------

sub _run
{
my $cmdline = join(" ",@ARGV) ;
$Data::Dumper::Terse = 1;

GetOptions(
  \%arg_conf
  , "init=s" => \$init
  , "c=s" => \$config_file
  , "continue"                             # start again with an existing .running archive
  , "help" => \&_usage
  , "man" => \&_man
  , "debug"
  , "dry-run"
  , "link-dest=s"
  , "mail_from=s"
  , "mail_to=s"
  , "max_runtime=i"
  , "no-links"
  , "no-roll"
  , "refresh"                              # update archive .1, without deleting any files
  , "rsync_retcode_ok=s"
  , "rsync_retcode_warn=s"
  , "ro=s@"
  , "ro_default=s"
  , "send_warn=i"
  , "smtp_server=s"
  , "update"                               # update archive .1, and delete obsolete files
  , "use_syslog=i"
  , "verbose"
) or _usage("") ;

# load conf file
if ($config_file)
{
  $config = new Config(-file=>$config_file,-path=>"") ;
}
else
{
  $config = new Config(
    -file=>"$this_prog.conf"
    , -path=>$CONFPATH
  ) ;
}
$config->init($default_conf,\%arg_conf) ;
$config->load() ;

$log = new _Log($cmdline,$config->get("debug")?2:$config->get("verbose")?1:0) ;
$log->debug("config: ".Dumper $config) ;

my $interval = shift() or _usage("wrong number of arguments") ;

my ($srcdir,$dstdir) ;

if ($init)
{
  $init =~ /^\d+$/ or _usage("'$init' isn't numeric") ;
  $dstdir = shift() or _usage("dstdir is missing") ;
}
else
{
  $srcdir = shift() or _usage("srcdir is missing") ;
  $dstdir = shift() or _usage("dstdir is missing") ;
}
_usage("wrong number of arguments") if scalar(@ARGV)!=0 ;

my $rocknRoll = new RocknRoll($dstdir,$interval) ;

if ($init)
{
  $rocknRoll->mkdirs($init) ;
}
else
{
  $rocknRoll->check_if_complete() ;

  if ($rocknRoll->rock($srcdir)==0)
  {
    $log->crit_by_mail("aborted before rolling archives") ;
    exit 1 ;
  }
  $rocknRoll->roll() unless $config->get("no-roll")
                            || $config->get("refresh")
                            || $config->get("update")
                            ;
}
}

1;




=head1 NAME

rocknroll - Rsync fOr baCKup and Roll

Light incremental backup tool based on rsync.

=head1 SYNOPSIS

rocknroll --init n tag dstdir

rocknroll [options] tag srcdir dstdir

rocknroll --help

rocknroll --man

=head1 DESCRIPTION

rocknroll backups a remote directories tree srcdir in dstdir onto the
local host.  For this backup, it manages a set of archives, named
tag.1, tag.2, etc.  Using the 'link-dest' option of rsync, it
keeps only the difference between the different archives.

A dstdir can contain several tagged sequences of archive. For example,
a dstdir can contain 2 archive sets named daily.1 daily.2 daily.3
daily.4 daily.5 daily.6 daily.7 and week.1 week.2 week.3 week.4.

Before a dstdir can be able to store an archive sequence, it must be
formatted with the --init option.

=head1 OPTIONS

Almost options can as well be specified into the configuration file.

=head2 -c config_file

use an alternate config file.

By default, rocknroll.conf is
searched in @/, @/../etc/, /etc/, /etc/rocknroll.d/
where @ is the directory containing the rocknroll binary.

=head2 --continue

start again with an existing .tag.running archive (useful after an
abort)

=head2 --debug

debug mode

=head2 --dry-run

don't perfom any action, just say what it could be done

=head2 --help

print usage

=head2 --man

print the manual

=head2 --no-links

don't specify any --link-dest option to rsync

=head2 --no-roll

don't roll up the archives set

=head2 --refresh

only update the archive tag.1 (without deletion of any files on
it).  Don't roll up the archives set.

=head2 --ro "--opt1 --opt2 --opt3"

pass some options to rsync (useful only in argument of command line)

=head2 --update

update archive tag.1 (with deletion of obsolete files).  Don't roll
up archives set.

=head1 CONFIGURATION FILE

Some directives are taken from rocknroll.conf, a file located
in @/, @/../etc/, /etc/, /etc/rocknroll.d/
where @ is the directory contained the rocknroll binary.

The format of a line is :

  directive=value

or

  directive value

A # starts a comment.


=head1 CONFIGURATION FILE DIRECTIVES

Each following directive can be passed as well on the command line as an option.

=head2 link-dest dir

by default the link-dest option is set to the tag.1 directory name.
This option is to bypass this default.

=head2 mail_from email

set the email address of the sender for the mail alerts

=head2 mail_to email

set the email address of the recipient for the mail alerts

=head2 max_runtime time_in_second

set the max among of time that a backup can take. Older than this
value, a .tag.running temporary directory will be deleted.

=head2 rsync_path path/to/rsync

specify the path of the rsync command line (default /usr/bin/rsync)

=head2 rsync_retcode_ok n,n,n,n...

specify a list of return codes of rsync considered as OK codes.
Each code not specified with --rsync_retcode_ok or
--rsync_retcode_warn is considered as an error return code.

=head2 rsync_retcode_warn n,n,n...

specify a list of return codes of rsync considered as warning
codes.  Each code not specified with --rsync_retcode_ok or
--rsync_retcode_warn is considered as an error return code.

=head2 ro_default "--opt1 --opt2"

pass some options to rsync (useful only in config file)

=head2 send_warn 0/1

send alert on warning (default is send alert only on error)

=head2 smtp_server smtp_server

set the SMTP server

=head2 use_syslog 0/1

enable to talk to syslog

=head1 ARCHIVE INITIALIZATION

This operation is needed before a directory can be used as a backup destination.

=head2 --init n

format a backup directory to receive n archives.

=head1 FILES AND DIRECTORIES

=head2 rocknroll.conf

configuration file

=head2 .tag.ctl

a control file located in the backup directory, related to the tag
archive set.

=head2 .tag.running

the temporary directory (located in the archive directory) for the
running rsync.

=head1 SEE ALSO

rsnapshot, <http://rsnapshot.org>. rsnapshot and rocknroll have similar
functionalities, and rsnapshot has been the first on the place. But
when I began to think about rocknroll, I've never heard of rnspashot.

=head1 AUTHOR

Jacquelin Charbonnel, C<< <jacquelin.charbonnel at math.cnrs.fr> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-Dir-Rocknroll at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Dir-Rocknroll>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Dir-Rocknroll

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Dir-Rocknroll>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Dir-Rocknroll>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Dir-Rocknroll>

=item * Search CPAN

L<http://search.cpan.org/dist/Dir-Rocknroll>

=back

=head1 COPYRIGHT & LICENSE

Copyright Jacquelin Charbonnel E<lt> jacquelin.charbonnel at math.cnrs.fr E<gt>

This software is governed by the CeCILL-C license under French law and
abiding by the rules of distribution of free software.  You can  use, 
modify and/ or redistribute the software under the terms of the CeCILL-C
license as circulated by CEA, CNRS and INRIA at the following URL
"http://www.cecill.info". 

As a counterpart to the access to the source code and  rights to copy,
modify and redistribute granted by the license, users are provided only
with a limited warranty  and the software's author,  the holder of the
economic rights,  and the successive licensors  have only  limited
liability. 

In this respect, the user's attention is drawn to the risks associated
with loading,  using,  modifying and/or developing or reproducing the
software by the user in light of its specific status of free software,
that may mean  that it is complicated to manipulate,  and  that  also
therefore means  that it is reserved for developers  and  experienced
professionals having in-depth computer knowledge. Users are therefore
encouraged to load and test the software's suitability as regards their
requirements in conditions enabling the security of their systems and/or 
data to be ensured and,  more generally, to use and operate it in the 
same conditions as regards security. 

The fact that you are presently reading this means that you have had
knowledge of the CeCILL-C license and that you accept its terms.

