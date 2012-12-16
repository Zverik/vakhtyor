#!/usr/bin/perl
# Vakhtyor (вахтёр): monitors buildings drawn without Bing layer in Russia.
# Written by Ilya Zverev, licensed WTFPL.

use strict;
use Getopt::Long;
use File::Basename;
use LWP::Simple;
use IO::Uncompress::Gunzip;
use DBIx::Simple;
use XML::LibXML::Reader qw( XML_READER_TYPE_ELEMENT XML_READER_TYPE_END_ELEMENT );
use POSIX;
use Math::Trig;
use Time::HiRes qw(gettimeofday tv_interval);
use Cwd qw(abs_path);

my $wget = `/usr/bin/which wget` || 'wget';
$wget =~ s/\s//s;
my $state_file = dirname(abs_path(__FILE__)).'/state.txt';
my $help;
my $verbose;
my $url = 'http://planet.openstreetmap.org/replication/minute';
my $database;
my $dbhost = 'localhost';
my $user;
my $password;
my $clear;
my $bbox_str = '21,42,180,90'; # '-180,-90,180,90';
my $dbprefix = 'v_';
my $bing_zoom = 14;
my @tile_expiry_days = (14, 60); # red, green
my @countries = ('ru', 'ua', 'by'); # if empty then all are ok

GetOptions(#'h|help' => \$help,
           'v|verbose' => \$verbose,
           'l|url=s' => \$url,
           'd|database=s' => \$database,
           'h|host=s' => \$dbhost,
           'u|user=s' => \$user,
           'p|password=s' => \$password,
           'c|clear' => \$clear,
           's|state=s' => \$state_file,
           'w|wget=s' => \$wget,
           'b|bbox=s' => \$bbox_str,
           ) || usage();

if( $help ) {
  usage();
}

usage("Please specify database and user names") unless $database && $user;
my $db = DBIx::Simple->connect("DBI:mysql:database=$database;host=$dbhost;mysql_enable_utf8=1", $user, $password, {RaiseError => 1});
$db->query("set names 'utf8'") or die "Failed to set utf8 in mysql";
create_table() if $clear;
my $ua = LWP::UserAgent->new();
$ua->env_proxy;

my @bbox = split(",", $bbox_str);
die ("badly formed bounding box - use four comma-separated values for left longitude, ".
    "bottom latitude, right longitude, top latitude") unless $#bbox == 3;
die("max longitude is less than min longitude") if ($bbox[2] < $bbox[0]);
die("max latitude is less than min latitude") if ($bbox[3] < $bbox[1]);

my %node_tiles; # keys are node ids, values are quadkeys
my @buildings; # each entry is an array of [changeset,userid,username,date,node1,node2,...]
my @tiles = ([], []); # all checked tiles (0=absent, 1=present)
my %newtiles; # tiles to upload to db
my %store_buildings;
my @tilestats;

$url =~ s#^#http://# unless $url =~ m#://#;
$url =~ s#/$##;
my $clock = [gettimeofday];
update_state($url);
printf STDERR "Done, %d secs\n", tv_interval($clock) if $verbose;

sub update_state {
    my $state_url = shift;
    my $resp = $ua->get($state_url.'/state.txt');
    die "Cannot download $state_url/state.txt: ".$resp->status_line unless $resp->is_success;
    print STDERR "Reading state from $state_url/state.txt\n" if $verbose;
    $resp->content =~ /sequenceNumber=(\d+)/;
    die "No sequence number in downloaded state.txt" unless $1;
    my $last = $1;

    if( !-f $state_file ) {
        # if state file does not exist, create it with the latest state
        open STATE, ">$state_file" or die "Cannot write to $state_file";
        print STATE "sequenceNumber=$last\n";
        close STATE;
    }

    my $cur = $last;
    open STATE, "<$state_file" or die "Cannot open $state_file";
    while(<STATE>) {
        $cur = $1 if /sequenceNumber=(\d+)/;
    }
    close STATE;
    die "No sequence number in file $state_file" if $cur < 0;
    die "Last state $last is less than DB state $cur" if $cur > $last;
    if( $cur == $last ) {
        print STDERR "Current state is the last, no update needed.\n" if $verbose;
        exit 0;
    }

    print STDERR "Last state $cur, updating to state $last\n" if $verbose;
    for my $state ($cur+1..$last) {
        my $osc_url = $state_url.sprintf("/%03d/%03d/%03d.osc.gz", int($state/1000000), int($state/1000)%1000, $state%1000);
        print STDERR $osc_url.'...' if $verbose;
        open FH, '-|:utf8', "$wget -q -O- $osc_url" or die "Failed to open: $!";
        process_osc(new IO::Uncompress::Gunzip(*FH));
        close FH;
        print STDERR "OK\n" if $verbose;

        if( $state == $last || scalar(keys %node_tiles) > 100000 || scalar(@buildings) > 5000 ) {
            process_data();
            store_data(); # not sure if it should be called here or later. All those "die"s...
            undef %node_tiles;
            undef @buildings;

            open STATE, ">$state_file" or die "Cannot write to $state_file";
            print STATE "sequenceNumber=$state\n";
            close STATE;
        }
    }
}

sub process_osc {
    my $handle = shift;
    my $r = XML::LibXML::Reader->new(IO => $handle);
    my %comments;
    my %tiles;
    my $state = '';
    my $tilesc = 0;
    while($r->read) {
        if( $r->nodeType == XML_READER_TYPE_ELEMENT ) {
            if( $r->name eq 'create' ) {
                $state = 1;
            } elsif( $state && $r->name eq 'node' ) {
                my $lat = $r->getAttribute('lat');
                my $lon = $r->getAttribute('lon');
                next if $lon < $bbox[0] || $lon > $bbox[2] || $lat < $bbox[1] || $lat > $bbox[2];
                $node_tiles{$r->getAttribute('id')} = [$lat, $lon];
            } elsif( $state && $r->name eq 'way' ) {
                my $b_info = [];
                push @{$b_info}, $r->getAttribute('changeset');
                push @{$b_info}, $r->getAttribute('uid');
                push @{$b_info}, $r->getAttribute('user') || '???';
                my $time = $r->getAttribute('timestamp');
                push @{$b_info}, substr($r->getAttribute('timestamp'),0,10);
                my $building = 0;
                my $maxnodes = 5;
                while( $r->read ) {
                    last if( $r->nodeType == XML_READER_TYPE_END_ELEMENT && $r->name eq 'way' );
                    if( $r->nodeType == XML_READER_TYPE_ELEMENT ) {
                        if( $r->name eq 'tag' ) {
                            $building = 1 if $r->getAttribute('k') eq 'building';
                        } elsif( $r->name eq 'nd' ) {
                            push @{$b_info}, $r->getAttribute('ref') if $maxnodes-- > 0;
                        }
                    }
                }
                if( $building ) {
                    push @buildings, $b_info;
                }
            }
        } elsif( $r->nodeType == XML_READER_TYPE_END_ELEMENT ) {
            $state = 0 if( $r->name eq 'delete' || $r->name eq 'modify' || $r->name eq 'create' );
        }
    }
}

sub decode_xml_entities {
    my $xml = shift;
    $xml =~ s/&quot;/"/g;
    $xml =~ s/&apos;/'/g;
    $xml =~ s/&gt;/>/g;
    $xml =~ s/&lt;/</g;
    $xml =~ s/&amp;/&/g;
    return $xml;
}

sub process_data {
    # %node_tiles and @buildings
    print STDERR 'Processing '.scalar(@buildings).' buildings...' if $verbose;
    @tilestats = (0,0,0,0,0); # total tiles checked, cached, got from db, expired in db, got from bing
    my $count = 0;
    for $b (@buildings) {
        next if scalar @{$b} < 5;
        my $tile;
        for (4..$#{$b}) {
            $tile = $node_tiles{$b->[$_]} if defined $node_tiles{$b->[$_]};
        }
        next if !$tile;
        if( $tile && !check_tile($tile) ) {
            # found a house in no-bing area
            # download info for the user from database, increment values, store in another array
            # each entry is an array of [changeset,userid,username,date,node1,node2,...]
            my $k = $b->[3].'#'.$b->[1];
            if( exists $store_buildings{$k} ) {
                $store_buildings{$k}->[4]++;
            } else {
                $store_buildings{$k} = [$b->[0], $b->[1], $b->[2], $b->[3], 1, $tile->[0], $tile->[1]];
            }
            $count++;
        }
    }
    printf STDERR " %d suspicious; checked %d tiles: %d from cache, %d-%d from db, %d from bing\n", $count, $tilestats[0], $tilestats[1], $tilestats[2], $tilestats[3], $tilestats[4] if $verbose;
}

sub latlon2tile {
    my $latlon = shift;
    my $lat = $latlon->[0];
    my $lon = $latlon->[1];
    $lat = 85.0 if $lat > 85.0;
    $lat = -85.0 if $lat < -85.0;
    $lon = -179.999 if $lon < -179.999;
    $lon = 179.999 if $lon > 179.999;
    my $xtile = int( ($lon + 180)/360 * 2**$bing_zoom ) ;
    my $ytile = int( (1 - log(tan(deg2rad($lat)) + sec(deg2rad($lat)))/pi)/2 * 2**$bing_zoom ) ;
    my $tile = [$xtile, $ytile];
    return $tile;
}

sub quadkey {
    my $tile = shift;
    # http://msdn.microsoft.com/en-us/library/bb259689.aspx
    my $quad = 'a'; # start with 'a' to prevent treating $quad as a number
    for( my $i = $bing_zoom - 1; $i >= 0; $i-- ) {
        my $digit = 0;
        my $mask = 1 << $i;
        $digit += 1 if $tile->[0] & $mask;
        $digit += 2 if $tile->[1] & $mask;
        $quad .= $digit;
    }
    return $quad;
}

sub check_tile {
    my $tile = latlon2tile(shift);
    $tilestats[0]++;
    $tilestats[1]++;
    # 1. check previous tiles array
    for(@{$tiles[0]}) {
        return 0 if $tile->[0] == $_->[0] && $tile->[1] == $_->[1];
    }
    for(@{$tiles[1]}) {
        return 1 if abs($tile->[0] - $_->[0]) + abs($tile->[1] - $_->[1]) <= 1;
    }
    $tilestats[1]--;
    # 2. get tile from database
    my $quad = quadkey($tile);
    $db->query("select check_date, found from ${dbprefix}bing where tile_id = ?", $quad)->into(my ($date, $result ));
    if( $date && ($result == 0 || $result == 1) ) {
        my @etime = localtime(time - $tile_expiry_days[$result] * 24 * 3600);
        if( $date gt sprintf('%04d-%02d-%02d', $etime[5]+1900, $etime[4]+1, $etime[3]) ) {
            push @{$tiles[$result]}, $tile;
            $tilestats[2]++;
            return $result;
        } else {
            $tilestats[3]++;
        }
    }
    # 3. ok, now check bing
    my $url = 'http://ecn.t'.int(rand(7)).'.tiles.virtualearth.net/tiles/'.$quad.'.jpeg?g=1036';
    my $http = `$wget --server-response --spider $url 2>&1`;
    my $result = $http =~ /X-VE-TILEMETA-CaptureDatesRange/ ? 1 : 0;
    # 4. save result to tables
    push @{$tiles[$result]}, $tile;
    $tilestats[4]++;
    $newtiles{$quad} = $result;
    # ok, now return
    return $result;
}

sub get_location {
    my( $lat, $lon ) = @_;
    my $nom_url = "http://nominatim.openstreetmap.org/reverse?format=xml&zoom=12&addressdetails=1&accept-language=ru&email=zverik%40textual.ru&lat=$lat&lon=$lon";
    if( open FH, '-|:utf8', "$wget -q -O- \"$nom_url\"" ) {
        my $city = '?'; my $state = '?'; my $country; my $whole;
        my $r = XML::LibXML::Reader->new(IO => *FH);
        while( $r->read ) {
            next if $r->nodeType != XML_READER_TYPE_ELEMENT;
            if( $r->name eq 'result' ) {
                $whole = $r->readInnerXml;
            } elsif( $r->name eq 'hamlet' || $r->name eq 'village' || $r->name eq 'town' || $r->name eq 'city' ) {
                $city = $r->readInnerXml;
            } elsif( $r->name eq 'state' ) {
                $state = $r->readInnerXml;
            } elsif( $r->name eq 'country' ) {
                $country = $r->readInnerXml;
            } elsif( $r->name eq 'country_code' ) {
                my $code = $r->readInnerXml;
                if( $code =~ /(\w\w)/ && scalar @countries ) {
                    my $code1 = $1;
                    return '-' if !grep(/^$code1$/, @countries);
                }
            }
        }
        close FH;
        return $country ? "$city, $state, $country" : $whole;
    } else {
        print STDERR "Failed to query nominatim: $!";
        return '';
    }
}

sub store_data {
    $db->begin;
    eval {
        print STDERR 'Storing '.scalar(keys %store_buildings).' bad cases...' if $verbose;
        my $sql = <<SQL;
insert into ${dbprefix}stats (map_date, user_id, user_name, object_count, changeset, lat, lon, location)
values (??) on duplicate key update object_count = object_count + values(object_count)
SQL
        my $cnt = 0;
        for my $b (values %store_buildings) {
            # each entry is an array of [changeset,userid,username,date,count,lat,lon]
            my $location = get_location($b->[5], $b->[6]);
            next if $location eq '-';
            $cnt++;
            $db->query($sql, $b->[3], $b->[1], $b->[2], $b->[4], $b->[0], $b->[5], $b->[6], substr($location,0,199)) or print STDERR "\nDB error: ".$db->error."\n";
        }
        print STDERR "($cnt)" if $cnt != scalar(keys %store_buildings);
        print STDERR ' and '.scalar(keys %newtiles).' bing tiles...' if $verbose;
        my $sql_t = "replace into ${dbprefix}bing (tile_id, found, check_date) values (??)";
        my @etime = localtime;
        my $today = sprintf('%04d-%02d-%02d', $etime[5]+1900, $etime[4]+1, $etime[3]);
        for (keys %newtiles) {
            $db->query($sql_t, $_, $newtiles{$_}, $today) or print "\nError uploading a tile: ".$db->error."\n";
        }
        $db->commit;
        print STDERR " OK\n" if $verbose;
        undef %store_buildings;
        undef %newtiles;
    };
    if( $@ ) {
        my $err = $@;
        eval { $db->rollback; };
        die "Transaction failed: $err";
    }
}

sub create_table {
    $db->query("drop table if exists ${dbprefix}bing") or die $db->error;
    $db->query("drop table if exists ${dbprefix}stats") or die $db->error;

    my $sql = <<CREAT1;
create table ${dbprefix}bing (
        tile_id varchar(20) not null primary key,
        found smallint not null,
        check_date date not null
)
CREAT1
    $db->query($sql) or die $db->error;
    $sql = <<CREAT2;
create table ${dbprefix}stats (
        stat_id int not null auto_increment primary key,
        map_date date not null,
        user_id mediumint unsigned not null,
        user_name varchar(96) not null,
        object_count mediumint not null,
        changeset int not null,
        lat float not null,
        lon float not null,
        location varchar(200) not null,

        checked_by varchar(96),
        comment varchar(1000),
        good smallint,

        unique date_user (map_date, user_id),
        index idx_name (user_name)
)
CREAT2
    $db->query($sql) or die $db->error;
    print STDERR "Database tables were recreated.\n" if $verbose;
}

sub usage {
    my ($msg) = @_;
    print STDERR "$msg\n\n" if defined($msg);

    my $prog = basename($0);
    print STDERR << "EOF";
This is a watchdog script: it searches OSM replication updates
for buildings and checks if they were mapped with Bing imagery.
If not, they are registered in the table, and users are able
to comment on them.

usage: $prog -d database -u user [-h host] [-p password] [-v]

 -l url       : base replication URL, must have a state file.
 -h host      : DB host.
 -d database  : DB database name.
 -u user      : DB user name.
 -p password  : DB password.
 -b bbox      : BBox of a watched region (minlon,minlat,maxlon,maxlat)
 -s state     : name of state file (default=$state_file).
 -w wget      : full path to wget tool (default=$wget).
 -c           : drop and recreate DB tables.
 -v           : display messages.

EOF
    exit;
}
