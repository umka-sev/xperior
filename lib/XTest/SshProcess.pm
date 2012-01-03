#
#===============================================================================
#
#         FILE:  SshProcess.pm
#
#  DESCRIPTION: Module which implements remote process control for singlie process over ssh
#
#       AUTHOR:  ryg
#      COMPANY:  Xyratex
#      CREATED:  10/08/2011
#===============================================================================

=pod

=head1 NAME

XTest::SshProcess - implements remote process control for single process over ssh

=head1  DESCRIPTION

The module is specially designed to be easily replaced by other module 
which provide same interface, possible via other protocol.

Modules support two serial workflows, opposed to a parallel, that a user is resposible to control.

=over 2

=item Workflow 1

User creates long-time process on remote nodes, the process is executed in background on a target node 
and deattached from console.
The stderr/stdout capturing and download is a user responsibility, that can be done, for example,
by standard output rediction via command line.

Functions to be used: B<create>, B<kill>, B<isAlive> and fields B<exitcode> and B<pid>.

=item Workflow 2

Create short-time process on remote nodes with capturing stderr/stdout. It behaves as perl B<``> (backtics) command.

Function to be used: B<createSync> and field B<exitcode>

=back

=head2 Functions

=over 2

=cut

package XTest::SshProcess;
use Moose;
use Data::Dumper;
use Cwd qw(chdir);
use File::chdir;
use File::Path;
use Log::Log4perl qw(:easy);
use Carp;
use Proc::Simple;
use XTest::Utils;
use Time::HiRes;

with qw(MooseX::Clone);

has port => ( is => 'rw' );
has host => ( is => 'rw' );
has user => ( is => 'rw' );
has pass => ( is => 'rw' );

has pidfile   => ( is => 'rw' );
has ecodefile => ( is => 'rw' );
has rscrfile  => ( is => 'rw' );
has pid       => ( is => 'rw' );
has appcmd    => ( is => 'rw' );
has appname   => ( is => 'rw' );
has exitcode  => ( is => 'rw' );
has bprocess  => ( is => 'rw' );

has killed => ( is => 'rw' );

has hostname  => ( is => 'rw' );
has osversion => ( is => 'rw' );

#TODO add timeout support
#TODO speed improvement via socket sharing
sub _sshSyncExec {
    my ( $self, $cmd, $timeout, $master ) = @_;
    $timeout = 30 unless defined $timeout;
    DEBUG "XTest::SshProcess->_sshSyncExec";
    my $cc =
        "ssh -o 'BatchMode yes' -o 'AddressFamily inet'  -f "
      . $self->user . "@"
      . $self->host
      . " \"$cmd\" 2>&1 ";
    DEBUG "Remote cmd is [$cc], timeout is [$timeout]";

#    my $cc =  "ssh -f ". $self->user ."@". $self->host ." -S /tmp/ssh_socket_%r@%h:%p   \"$cmd\" 2>&1 ";
    my $out = '';
    eval {
        local $SIG{ALRM} = sub {
            $self->exitcode(-100);
            $self->killed(time);
            #print "*******************Killed by timeout !\n";
            die "alarm clock restart";
        };
        alarm $timeout;

        #eval {
        $out = `$cc`;

        #        };
        alarm 0;

        # cancel the alarm
    };
    alarm 0;

    # race condition protection
    #DEBUG "!!!!!!!!" . $@;

    #die if $@ && $@ !~ /alarm clock restart/; # reraise
    if ( $@ =~ m/alarm\s+clock\s+restart/ ) {
        $self->exitcode(-100);
        $self->killed(time);
        WARN "Killed by timeout !\n";

    }
    if( ${^CHILD_ERROR_NATIVE} != 0 ){
        $self->exitcode( ${^CHILD_ERROR_NATIVE} );
        WARN "Exit code is !0\n";   
    }

    return $out;
}

sub _sshAsyncExec {
    my ( $self, $cmd, $timeout, $master ) = @_;
    DEBUG "XTest::SshProcess->_sshAsyncExec";
    my $cc = "ssh -f " . $self->user . "@" . $self->host . " \"$cmd\"  ";
    DEBUG "Remote cmd is [$cc]";
    $self->bprocess( Proc::Simple->new() );
    $self->bprocess->start($cc);
    $self->bprocess->kill_on_destroy(1);
    return 0;
}

=item init ($host, $user, $port)

Initialize module. Protocol is only ssh.

=cut

sub init {
    DEBUG "Automator::SshUnixProcess->init";
    my $self = shift;
    $self->pidfile( '/tmp/xtest_pid_ssh_' . Time::HiRes::gettimeofday() );
    $self->ecodefile( '/tmp/remote_exit_code_' . Time::HiRes::gettimeofday() );
    $self->rscrfile(
        '/tmp/remote_script_' . Time::HiRes::gettimeofday() . '.sh' );

    $self->host(shift);
    $self->user(shift);
    $self->port(shift);
    $self->killed(0);
    $self->exitcode(0);

    my $nocrash = shift;

#    DEBUG  "ssh -o 'BatchMode yes' -M -S /tmp/ssh_socked%r@%h:%p  -f ". $self->user ."@". $self->host ." ";

    my $ver = trim $self->_sshSyncExec( "uname -a", 10 );

    #DEBUG "-------------------------------";
    #DEBUG ${^CHILD_ERROR_NATIVE};
    #DEBUG $self->exitcode;
    #DEBUG $self->killed;

    if( (${^CHILD_ERROR_NATIVE} != 0 ) || 
        ( $self->exitcode != 0 ) || 
        ($self->killed != 0) ){
        WARN "SshProcess cannot be initialized";
        if ( defined($nocrash) && $nocrash ) {
            return -99;
         }else {
            confess "SSH returns non-zero values on previous command:"
            . ${^CHILD_ERROR_NATIVE};
            #if ( ${^CHILD_ERROR_NATIVE} != 0 );
        }
    }

    my $h = trim $self->_sshSyncExec( "hostname", 10 );
    INFO "Executing on host [$h]";
    $self->hostname($h);
    DEBUG "Remote system is <$ver>";
    $self->osversion($ver);
    return 0;
}

#TODO test on it
sub _findPid {
    my $self = shift;
    $self->pid(-1);
    my $out = $self->_sshSyncExec( "cat " . $self->pidfile, 1 );

    foreach my $s ( split( /\n/, $out ) ) {
        DEBUG "Check line for PID [$s]\n";
        if ( $s =~ m/pid\:\[(\d+)\]/ ) {
            $self->pid($1);
            DEBUG "PID found: [" . $self->pid . "]\n";
            return 1;
        }
    }
    return -1;
}

=item createSync ($command, $timeout)

Execute remote process and catch stderr/std and exit code. Function exit when remote execution done.

Function have one parameter - command for start on emote node.

=cut

sub createSync {
    my ( $self, $app, $timeout ) = @_;
    $self->appcmd($app);
    DEBUG "XTest::SshProcess createSync";
    DEBUG "App to run [$app] on host[" . $self->host . "]";
    my $ecf = $self->ecodefile;
    $self->killed(0);

    my $ss = <<"SS";
$app   
echo \\\$? > $ecf 
SS

    my $tef = $self->rscrfile;
    my $fco = $self->_sshSyncExec("echo  '$ss' > $tef");

    my $s = $self->_sshSyncExec( "sh $tef", $timeout );
    DEBUG "Remote app completed";

    if ( $self->killed == 0 ) {
        $self->exitcode( trim $self->_sshSyncExec("cat $ecf") );
    }
    return $s;

}

=item create ($name, $command)

Execute remote process with unattached stderr/stdout and exit. Pid is savednon remote fs. Exit code is saved after process end.

Parameters:

=over 2

=item $name

name of process which can be seen on remote node. Can be used in B<killall> call. Now is not used somehow. TBI.

=item $command

command line which will be executed on remote node

=back

=cut

sub create {
    my ( $self, $name, $app ) = @_;
    $self->appname($name);
    $self->appcmd($app);
    DEBUG "[$name]: XTest::SshProcess create";
    DEBUG "[$name]: App to run [$app] on host[" . $self->host . "]";
    $self->killed(0);

    my $pf = $self->pidfile;
    my $rd = $self->_sshSyncExec( "rm -rf " . $pf );
    DEBUG "Del remote pid file: $pf";
    my $ecf = $self->ecodefile;
    my $ss  = <<"SS";
$app &  
pid=\\\$!  
echo pid:[\\\$pid] > $pf 
wait \\\$pid
echo \\\$? > $ecf 
SS

    #TODO  clean /tmp after execution and test it
    my $tef = $self->rscrfile;
    my $fco = $self->_sshSyncExec("echo  '$ss' > $tef");
    DEBUG "Starting async ............";
    my $s = $self->_sshAsyncExec("sh $tef");
    DEBUG "Remote async app started";
    sleep 3;
    $self->exitcode(undef);
    
    #cycle workaround for long remote part start
    # wait 6*5 sec for pid file on remote side
    my $step = 0;    
    while( $step < 6) {
        $self->_findPid();
        last if ($self->pid != -1);
        sleep 5;
        $step++;
    }

    if ( $self->pid == -1 ) {
        confess "Remote process doesn't start or found in pid file";
    }

    DEBUG "App [$app] started on " . $self->host . "\n";
    DEBUG "[$name]: Run aplication [$app] ";
    return $self->pid;
}

=item kill ($mode)

Kill process which was created by create via saved pid.

=cut

sub kill {
    DEBUG "XTest::SshProcess->kill";
    my ($self,$mode) = @_;
    my $pid  = $self->pid;
    my $name = $self->appname;
    $mode =0 unless defined $mode;

    DEBUG "[$name]: Killing job [" . $name . "], mode[$mode] \n";
    if($mode == 0){
        $self->_sshSyncExec("kill -15 $pid");
        sleep 10;
    }
    $self->_sshSyncExec("kill -9  $pid");
    $self->killed(time);
    $self->bprocess->kill;
    DEBUG "[$name:$pid]*** Killed!";
    $self->exitcode(-99);
}

=item isAlive

Check process status on remote system via saved pid. Also this function get exit code from remote side if application is exited or killed.

=cut

sub isAlive {
    DEBUG "XTest::SshProcess->isAlive";
    my $self = shift;
    my $pid  = $self->pid;
    my $name = $self->appname;
    my $o    = trim $self->_sshSyncExec(" kill -0 $pid 2>&1; echo \$? ");
    unless ( defined($o) ) {
        ERROR "unable to check remote system: [$o]";
        return -99;
    }

    if ( $o =~ m/^0$/ ) {
        DEBUG "Remote process is alive! ";
        return 0;
    }
    $self->exitcode( trim $self->_sshSyncExec( "cat " . $self->ecodefile ) );
    DEBUG "Remote process is not found! ";
    return -1;
}

#sub sendFile {
#    my $localdir  = shift;
#    my $user      = shift;
#    my $host      = shift;
#    my $remotedir = shift;
#
#    DEBUG "Sending $localdir to ${user} @ ${host} : $remotedir";
#
#    runExternal("scp -rp $localdir ${user}\@${host}:$remotedir");
#
#}

=item getFile ($remote_file, $local_file)

Get file from remote system. TODO add tests on it.

=cut

sub getFile {
    my ( $self, $rfile, $lfile ) = @_;

    DEBUG "Getting "
      . $self->user . '@'
      . $self->hostname . ':'
      . $rfile . ' to '
      . $lfile;

    return runEx(
        "scp -rp " . $self->user . '@' . $self->hostname . ":$rfile $lfile" );
}

=back

=cut

1;
