# $Id: CPANdeps.pm,v 1.13 2007/11/29 16:23:49 drhyde Exp $

package CPANdeps;

use strict;
use warnings;

use Cwd;
use CGI;
use DBI;
use Parse::CPAN::Packages;
use YAML ();
use Module::CoreList;

use Data::Dumper;
use LWP::UserAgent;
use Template;

use constant ANYVERSION => 'any version';
use constant ANYOS      => 'any OS';
use constant DEFAULTCORE => '5.005';
use constant MAXINT => ~0;

my $home = cwd();
my $debug = ($home =~ /-dev/) ? 1 : 0;
my $dbh = DBI->connect("dbi:SQLite:dbname=$home/db/cpantestresults", '', '');

my $p = Parse::CPAN::Packages->new('db/02packages.details.txt.gz');

$Template::Stash::SCALAR_OPS->{int} = sub {
    my $scalar = shift;
    return int(0 + $scalar);
};
$Template::Stash::SCALAR_OPS->{sprintf} = sub {
    my $scalar = shift;
    return sprintf(shift, $scalar);
};

$Data::Dumper::Sortkeys = 1;
my $tt2 = Template->new(
    INCLUDE_PATH => "$home/templates",
);

my $VERSION = '$Id: CPANdeps.pm,v 1.13 2007/11/29 16:23:49 drhyde Exp $';

sub render {
    my($q, $ttvars) = @_;


    $ttvars->{debug} = "<h2>Debug info</h2><pre>".Dumper($ttvars)."</pre>"
        if($debug);

    $tt2->process('cpandeps.tt2', $ttvars, sub { $q->print(@_); }) ||
        die($tt2->error());
}

sub go {
    my $q = CGI->new();
    print "Content-type: text/html\n\n";
    my $ua = LWP::UserAgent->new(
        agent => "cpandeps/$VERSION",
        from => 'cpandeps@cantrell.org.uk'
    );
    my $ttvars = {
        perl => ($q->param('perl') || ANYVERSION),
        os   => ($q->param('os') || ANYOS),
        # ugh, sorting versions is Hard.  Can't use version.pm here
        perls => [ ANYVERSION, 
            sort {
                my($A, $B) = map {
                    my @v = split('\.', $_);
                    $v[2] = defined($v[2]) ? $v[2] : 0;
                    $v[2] + 1000 * $v[1] + 1000000 * $v[0];
                } ($a, $b);
                $A <=> $B;
            }
            (qw(5.6 5.8 5.10), @{ do "$home/db/perls" })
        ],
        oses => [ANYOS, sort { $a cmp $b } @{ do "$home/db/oses" }]
    };

    my $permitted_chars = join('', @{$ttvars->{perls}});
    die("Naughty naughty - bad perl version ".$ttvars->{perl}."\n")
        if($ttvars->{perl} =~ /[^$permitted_chars]/);
        
    $permitted_chars = join('', @{$ttvars->{oses}});
    die("Naughty naughty - bad OS ".$ttvars->{os}."\n")
        if($ttvars->{os} =~ /[^$permitted_chars]/);

    $ttvars->{query} = "
          SELECT state, COUNT(state) FROM cpanstats
           WHERE dist=?
             AND version=?
             AND state IN ('fail', 'pass', 'na', 'unknown')
    ".
       ($ttvars->{perl} eq ANYVERSION ? '' : "AND perl LIKE '".$ttvars->{perl}."%'").
       ($ttvars->{os} eq ANYOS ? '' : "AND os = '".$ttvars->{os}."'")
    ."
        GROUP BY state
    ";
    my $sth = $dbh->prepare($ttvars->{query});

    my $module = $ttvars->{module} = $q->param('module');

    my $distschecked = {};
    if($module) {
        $ttvars->{modules} = [checkmodule(
            module => $module,
            moduleversion => MAXINT,
            indent => -4,
            distschecked => $distschecked,
            perl => $ttvars->{perl},
            sth => $sth,
            ua => $ua
        )];
    }

    render($q, $ttvars);
}

sub checkmodule {
    my %params = @_;
    my($module, $moduleversion, $perl, $indent, $distschecked, $sth, $ua) =
        @params{qw(
            module moduleversion perl indent distschecked sth ua
        )};
    my $warning = '';
    $indent += 4;

    my $m = $p->package($module);
    return () unless($m);
    my $dist = $m->distribution();

    my $author = $dist->cpanid();
    my $distname = $dist->prefix();

    return () if(
        !defined($distname) ||
        $distschecked->{$distname} ||
        # (
        #     exists($distschecked->{$distname}) &&
        #     $distschecked->{$distname} >= $moduleversion
        # ) ||
        $module eq 'perl'
    );

    my $CPANfile = $distname;
    (my $version = $distname) =~ s/.*-([^-]+)\.(tar\.gz|zip)/$1/;

    $distschecked->{$distname} = $version;

    return {
        name   => $module,
        distname => $distname,
        version  => $version,
        indent   => $indent,
        cpantestersurl => "http://search.cpan.org/search?query=$module",
        warning => "Couldn't find module",
    } unless(defined($dist) && defined($distname));

    $author   = '' unless(defined($author));
    $distname = '' unless(defined($distname));
    $version = '' unless(defined($version));

    $distname =~ s!(^.*/|(\.tar\.gz|\.zip)$)!!g;

    my $origdistname = $distname;
    $distname =~ s/\.pm|-[^-]*$//g;
    my $incore = in_core(module => $module, perl => $perl);
    my $testresults = (
        $distname eq 'perl' ||
        (defined($incore) && $incore >= $moduleversion)
    ) ?
        'Core module' :
        gettestresults($sth, $distname, $version);

    my %requires = ();
    if($testresults ne 'Core module') {
        %requires = getreqs($author, $origdistname, $ua);
        if(defined($requires{'!'}) && $requires{'!'} eq '!') {
            %requires = ();
            $warning = "Couldn't get dependencies";
        }
    }

    return {
        name     => $module,
        distname => $distname,
        CPANfile => $CPANfile,
        version  => $version,
        indent   => $indent,
        cpantestersurl => "http://cpantesters.perl.org/show/$distname.html",
        warning => $warning,
        ref($testresults) ?
            %{$testresults} :
            (textresult   => $testresults)
    }, map {
        checkmodule(
            module => $_,
            moduleversion => $requires{$_},
            indent => $indent,
            distschecked => $distschecked,
            perl => $perl,
            sth => $sth,
            ua => $ua
        )
    } keys %requires
}

sub in_core {
    my %params = @_;
    my($module, $perl) = @params{qw(module perl)};

    my @v = split('\.', ($perl eq ANYVERSION) ? DEFAULTCORE : $perl);
    $v[2] = 0 unless(defined($v[2]));
    my $v = sprintf("%d.%03d%03d", @v);

    my $incore = $Module::CoreList::version{0+$v}{$module};
    # warn("M:$module I:$incore P:$perl V:$v\n");
    return $incore;
}

sub gettestresults {
    my($sth, $distname, $version) = @_;
    $sth->execute($distname, ''.$version);
    my $r = $sth->fetchall_arrayref();
    if(ref($r)) { $r = { map { $_->[0] => $_->[1] } @{$r} }; }
     else { return 'Error getting test results'; }

    $r->{$_} = 0 for(grep { !exists($r->{$_}) } qw(fail pass unknown na));
    return $r;
}

sub getreqs {
    my($author, $distname, $ua) = @_;
    my $cachefile = "$home/db/$distname.yml";
    my $yaml;
    local $/ = undef;

    # if we have a valid (less than 7 day old) cache file, read it
    if(-e $cachefile && (stat($cachefile))[9] + 7 * 86400 > time()) {
        open(YAML, $cachefile) || die("Can't read $cachefile\n");
        $yaml = <YAML>;
        close(YAML);
    } else {
        # read from interwebnet
        my $res = $ua->request(HTTP::Request->new(
            GET => "http://search.cpan.org/src/$author/$distname/META.yml"
        ));
        if(!$res->is_success()) {
            return ('!', '!');
        } else {
            $yaml = $res->content();
        }
        open(YAML, ">$cachefile") || die("Can't write $cachefile\n");
        print YAML $yaml;
        close(YAML);
    }
    eval { $yaml = YAML::Load($yaml); };
    return ('!', '!') if($@ || !defined($yaml));

    $yaml->{requires} ||= {};
    $yaml->{build_requires} ||= {};
    return %{$yaml->{requires}}, %{$yaml->{build_requires}};
}

1;
