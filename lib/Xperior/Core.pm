#
# GPL HEADER START
#
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 only,
# as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License version 2 for more details (a copy is included
# in the LICENSE file that accompanied this code).
#
# You should have received a copy of the GNU General Public License
# version 2 along with this program; If not, see http://www.gnu.org/licenses
#
# Please  visit http://www.xyratex.com/contact if you need additional
# information or have any questions.
#
# GPL HEADER END
#
# Copyright 2012 Xyratex Technology Limited
#
# Author: Roman Grigoryev<Roman_Grigoryev@xyratex.com>
#

=pod

=head1 NAME

Xperior::Core - Xperior Core module

=head1 DESCRIPTION

The module implements main execution cycle, test object creation, include/exclude list processing, simple HTML report generation and configuration reading.

=cut

package Xperior::Core;
use Log::Log4perl qw(:easy);
use YAML qw "Bless LoadFile Load";
use Data::Dumper;
use Moose;
use Carp qw( confess cluck );
use File::Path;
use File::chdir;
use File::Copy;
use File::Find;
use File::Slurp;
use Xperior::html::HTML;
use TAP::Parser::Aggregator;
use TAP::Parser;
use TAP::Formatter::HTML::Session;
use List::Util qw(first);
use Module::Load;

use Xperior::Test;
use Xperior::TestEnvironment;
use Xperior::Utils;
use Xperior::Executor::Roles::RoleLoader;


=head Exit codes

=over 4

=item 19

Configuration cannot pass testing on initialization step

=item 10

Configuration cannot pass testing on after test

=item 11

Dangerous test failed.

=item 12

Test failed with error.

=cut

use constant ERROR_CONFIG_FAILURE         => 19;
use constant ERROR_CONFIG_FAILURE2        => 10;
use constant ERROR_DANGEROUS_TEST_FAILURE => 11;
use constant ERROR_TEST_BREAK_REQUIRED    => 12;

our $VERSION = "0.0.2";

has 'options'    => (is => 'rw');
has 'tests'      => (is => 'rw');    # isa => 'ArrayRef[]', );
has 'testgroups' => (is => 'rw');
has 'env'        => (is => 'rw');
has 'extoptions' => (is => 'rw');

=head2 _multiplyTests

Return test set same as C<$self-tests> with increased number of tests.
Factor set via cmd option 'multirun' set. If cmd 'multirun' set 0 or 
undefined test option 'multirun' will be used.

=cut

sub _multiplyTests {
    my ($self, $multirun) = @_;
    DEBUG "Multiply tests";
    my @newtests;
    foreach my $test (@{$self->{'tests'}}) {
        push(@newtests, $test->multiply($multirun));
    }
    return \@newtests;
}

sub _createExecutor {
    my ($self, $es, @roles) = @_;
    DEBUG "Loading module [$es]";
    load $es;
    my $exe = $es->new;
    if(@roles){
        my $loader = Xperior::Executor::Roles::RoleLoader->new();
        $loader->applyRoles($exe,@roles);
    }
    return $exe;
}

sub _runtest {
    my ($self, $test) = @_;
    DEBUG "Starting test " . $test->getParam('id');

    #DEBUG "Test is:". Dumper $test;
    my $executorname = $test->getParam('executor');
    my $roles        = $test->getParam('roles');
    if ($test->{excluded}) {
        $executorname = 'Xperior::Executor::Skip';
        $roles        = '';
    }

    my $executor = $self->_createExecutor($executorname, split(/\s+/, trim($roles)));

    $executor->init($test, $self->options, $self->env);

    my $opt = $self->{extoptions};
    if (ref ($opt) eq 'HASH') {
        DEBUG "Setting executor external options";
        for my $k (keys %{$opt}) {
            $executor->setExtOpt($k, $opt->{$k});
        }
    }

    $executor->execute();
    $executor->report();
    $executor->tap() if $self->options->{'tap'};
    return $executor;
}

sub getExtOptions {
    my $self    = shift;
    my $options = shift;

    my %extoptions;
    if (defined $options->{'extoptfile'}) {
        my $path = $options->{'extoptfile'};
        INFO "Load external options from file [$path]";
        my $extopt;
        eval {$extopt = LoadFile($path)}
            or confess "$!";
        %extoptions = (%{$extopt->{'extoptions'}});
    }

    #TODO: move parsing of extopt out of Core package
    if (@{$options->{'extopt'}})
    {
        INFO "Apply external options";
        foreach my $param (@{$options->{'extopt'}}) {
            if ($param =~ m/^([\w\d]+)\s*\:(.+)$/) {
                $extoptions{$1} = $2;
            }
            else {
                INFO "Cannot parse --extopt parameter [$param], ",
                    "please, use following form '--extopt=key:value'";
            }
        }
    }
    return \%extoptions;
}

=item run

Execution enter point

=cut

sub run {
    my $self    = shift;
    my $options = shift;
    $self->{'options'} = $options;

    my $action = $self->options->{'action'};
    if ($action eq 'generatehtml') {
        $self->_reportHtml;
        INFO "Report generation completed";
        exit 0;
    }

    DEBUG "Start framework";
    my $tags = $self->loadTags();
    $self->tests($self->loadTests());
    $self->extoptions($self->getExtOptions($options));
    $self->env($self->loadEnv($options->{'configfile'}));
    if ($self->env->checkEnv < 0) {
        WARN "Found problems while testing configuration";
        exit(ERROR_CONFIG_FAILURE);
    }

    $self->tests($self->_multiplyTests($self->options->{'multirun'}));

    #TODO check tests applicability there

    my @includeonly = @{$self->options->{'includeonly'}};
    my $excludelist;
    my $includelist;
    my $completelist;

    if (   (defined $self->options->{'excludelist'})
        && ($self->options->{'excludelist'} ne ''))
    {
        $excludelist = parseFilterFile($self->options->{'excludelist'});
    }

    if(    (defined $self->options->{'includelist'})
        && ($self->options->{'includelist'} ne ''))
    {
        $includelist = parseFilterFile($self->options->{'includelist'});
    }

    $completelist = findCompleteTests($self->options->{'workdir'})
        if ($self->options->{'continue'});

    foreach my $test (@{$self->{'tests'}}) {
        my $testName     = $test->getName();
        my $testFullName = $test->getGroupName . '/' . $test->getName;

        my $skip = 0;
        INFO "Preprocessing $testFullName";
        if (@includeonly) {
            $skip = 1 unless first {$testFullName =~ m/^$_$/} @includeonly;
        }
        else {
            foreach my $tag (@{$test->getTags}) {
                next
                    unless first {$_ eq $tag} @{$self->options->{'skiptags'}};
                $skip = 1;
                last;
            }
            if (defined $excludelist) {
                $test->excluded(1)
                    if first {$testFullName =~ m/^$_$/} @$excludelist;
            }
            if (defined $includelist) {
                $skip = 1
                    unless first {$testFullName =~ m/^$_$/} @$includelist;
            }
        }

        $skip = 1 if first {"$testFullName.yaml" =~ m/^$_$/} @$completelist;

        if ($skip) {
            INFO "Test [$testFullName] will be skipped";
            $test->skipped(1);
        }
    }

    if ($action eq 'run') {
        WARN "Starting test execution";
        my $execCounter = 0;
        my $skipCounter = 0;
        my $error;
        foreach my $test (@{$self->{'tests'}}) {
            if ($test->skipped()) {
                $skipCounter++;
                next;
            }
            my $testName     = $test->getName();
            my $exe    = $self->_runtest($test, $test->{excluded});
            my $res    = $exe->result_code;
            my $status = $test->results->{'status'};

            INFO "TEST $testName STATUS: $status";

            $execCounter++;

            #ignore passed and skipped results
            if ($res != 0 and $res != 2) {

                #test failed, do env check
                if ($self->{'env'}->checkEnv < 0) {
                    WARN
"Found problems while testing configuration after failed test, exiting";
                    $error = ERROR_CONFIG_FAILURE2;
                    last;
                }
                if (($res == 1) and 
                    ($exe->yaml->{'fail_reason'} eq 'No_status_found') and 
                    ($exe->yaml->{'killed'} eq 'no'))
                {
                    WARN "Not a dangerous test failure detected, continuing...";
                }
                else
                {
                    if ($test->getParam('dangerous', 'yes')) {
                        WARN "Dangerous test failure detected, exiting";
                        $error = ERROR_DANGEROUS_TEST_FAILURE;
                        last;
                    }
                }
            }
            else {
                if ($test->getParam('exitafter', 'yes')) {
                    WARN "Test requires stop after complete, exiting";
                    $error = ERROR_TEST_BREAK_REQUIRED;
                    last;
                }
            }
        }
        INFO "Test execution completed" unless $error;
        INFO "Executed tests: $execCounter";
        INFO "Skipped tests:  $skipCounter";
        $self->_reportHtml;
        exit ($error) if ($error);
    }
    elsif ($action eq 'list') {
        foreach my $test (grep { ! $_->skipped() } @{$self->{'tests'}}) {
            print "====================\n";
            print $test->getDescription();
            print "====================\n";
        }
    }
    else {
        confess "Unknown action detected: $action";
    }
}

=item loadEnv

Class method
Load data from file (parameter). The file must be Xperior configuration
file. See Xperior user guide.

=cut

sub loadEnv {
    DEBUG 'Xperior::Core->loadEnv';
    my $self = shift;
    my $config_file = shift || 'systemcfg.yaml';
    INFO "Load env configuration file [ $config_file ]";
    my $config = LoadFile($config_file) or confess $!;

    my $env = Xperior::TestEnvironment->new;
    $env->init($config);

    return $env;
}

sub loadTests {
    DEBUG 'Xperior::Core->loadTests';
    my $self = shift;
    my @testNames;
    my @tests;
    INFO "Reading tests from dir: [" . $self->{'options'}->{'testdir'} . "]";
    find(
        sub {
            push(@testNames, $File::Find::name)
                if ($File::Find::name =~ m/tests.yaml/);
        },
        $self->{'options'}->{'testdir'}
    );

    #DEBUG Dumper @testNames;

    foreach my $fn (@testNames) {
        my $testscfg = $self->loadTestsFile($fn);
        my %groupcfg;
        foreach my $key (keys %{$testscfg}) {
            $groupcfg{$key} = $testscfg->{$key}
                if ($key ne 'Tests');
        }

        foreach my $testcfg (@{$testscfg->{'Tests'}}) {
            my $test = Xperior::Test->new;

            #DEBUG "groupcfg=".Dumper \%groupcfg;
            $test->init($testcfg, \%groupcfg);
            push @tests, $test;
        }
    }

    #DEBUG 'Load tests result:' . Dumper \@tests;
    return \@tests;
}

sub loadTestsFile {
    my $self = shift;
    my $fn   = shift;
    INFO "Load test file [ $fn ]";
    my $testscfg = LoadFile($fn) or confess $!;

    #DEBUG Dumper $testscfg;
    return $testscfg;
}

sub loadTags {
    DEBUG 'Xperior::Core->loadTestSuites';
    my $self = shift;
    my $file = $self->{'options'}->{'testdir'} . '/tags.yaml';
    INFO "Load tag file [ $file ]";
    my $cfg = LoadFile($file) or confess $!;

    #DEBUG Dumper $cfg;
    return $cfg->{'tags'};
}

=head3 _reportHtml

Generate HTML report for work directory with results.
Every executed suite is converted to TAP test result and 
HTML report is generated via using customized TAP::Formatter::HTML
  
=cut

sub _reportHtml {
    my $self = shift;
    return
        unless ($self->{options}->{html}
        or ($self->options->{'action'} eq 'generatehtml'));

    my $wd     = $self->{options}->{workdir};
    my $libdir = $self->{options}->{xperiorbasedir} . '/Xperior/html';
    my @suites;
    opendir my ($dh), $wd or confess "Couldn't open dir '$wd': $!";

    #read executed test group list from workdir dir
    # filter report dir if report was previous generated
    @suites = grep {!/report/} grep {!/^\.\.?$/} readdir $dh;
    closedir $dh;
    my %data;
    my %etimes;
    mkdir "$wd/report";

    #read yaml xperior results and generate one tap
    foreach my $suite (@suites) {
        my $report = '';
        my $i    = 1;

        opendir my ($dh), "$wd/$suite"
            or confess "Couldn't open dir '$wd/$suite': $!";
        my @tapfiles = grep {/\.yaml/}
            grep {!/^\.\.?$/} readdir $dh;
        closedir $dh;

        #generate tap for many files to
        #show xperior test group as one tap test
        foreach my $tfile (@tapfiles) {

            my $yaml = LoadFile("$wd/$suite/$tfile") or confess $!;
            my $message = '';
            if ($yaml->{'status_code'} == 0) {
                $message = "ok $i # id=" . $yaml->{id};
            }
            elsif ($yaml->{'status_code'} == 2) {
                $message =
                    "ok $i # skip # id=$yaml->{id} $yaml->{'fail_reason'}";
                $yaml->{killed}    = 'no';
                $yaml->{endtime}   = 0;
                $yaml->{starttime} = 0;
            }
            else {
                $message ="not ok $i # id=$yaml->{'id'} $yaml->{'fail_reason'}";
            }
            $report =
                  "$report$message \n"
                . "# killed  : $yaml->{killed} .  \n# timeout :$yaml->{timeout} \n"
                . "\# elapsed time    :"
                . ($yaml->{endtime} - $yaml->{starttime}) . "\n";
            $etimes{$suite} = $yaml->{endtime} - $yaml->{starttime};
            foreach my $lname (keys %{$yaml->{log}}) {
                $report =
                      $report
                    . "\# log "
                    . "<a href='../$suite/"
                    . $yaml->{log}->{$lname}
                    . "' type='text/plain'>$lname</a> \n";
            }

            $i++;
        }
        $i--;
        $data{$suite} = "TAP version 13\n" . "1..$i\n" . $report . "\n";
        write_file("$wd/report/$suite.tap", $data{$suite});

    }

    my $fmt = Xperior::html::HTML->new;
    $fmt->verbosity(-2);
    my $aggregate = TAP::Parser::Aggregator->new;
    my $session;
    foreach my $suite (@suites) {
        $aggregate->start;
        my $parser = TAP::Parser->new({tap => $data{$suite}});
        $session = $fmt->open_test($suite, $parser);
        while (defined(my $result = $parser->next)) {
            $session->result($result);
            next if $result->is_bailout;
        }
        $session->close_test;

        $aggregate = $aggregate->add($suite, $parser);

        $aggregate->stop;
    }
    $fmt->abs_file_paths(1);
    $CWD = $libdir;
    $fmt->template("$CWD/xperior_report.tt2");

    #
    $fmt->output_file("$wd/report/report.html");
    $fmt->tests(\@suites);

    $fmt->summary($aggregate);

    my @libfiles = (
        "default_page.css",  "default_report.css",
        "default_report.js", "jquery-1.4.2.min.js",
        "jquery.tablesorter-2.0.3.min.js",
    );

    foreach my $f (@libfiles) {
        copy("$libdir/$f", "$wd/report/$f") or confess "Copy failed: $!";
    }
    INFO "HTML Report generated: file://$wd/report/report.html";

}
__PACKAGE__->meta->make_immutable;
1;

=head1 COPYRIGHT AND LICENSE

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License version 2 only,
as published by the Free Software Foundation.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License version 2 for more details (a copy is included
in the LICENSE file that accompanied this code).

You should have received a copy of the GNU General Public License
version 2 along with this program; If not, see http://www.gnu.org/licenses



Copyright 2012 Xyratex Technology Limited

=head1 AUTHOR

Roman Grigoryev<Roman_Grigoryev@xyratex.com>

=cut

# vim: set ts=4 sw=4 et:

