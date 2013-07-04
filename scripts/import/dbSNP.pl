#!/usr/bin/env perl


=head1 LICENSE

  Copyright (c) 1999-2013 The European Bioinformatics Institute and
  Genome Research Limited.  All rights reserved.

  This software is distributed under a modified Apache license.
  For license details, please see

    http://www.ensembl.org/info/about/legal/code_licence.html

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <dev@ensembl.org>.

  Questions may also be sent to the Ensembl help desk at
  <helpdesk.org>.

=cut

# this is the script to fill the new variation
# schema with data from dbSNP
# we use the local mssql copy of dbSNP at the sanger center
# the script will call the dbSNP factory to create the object that will deal with
# the creation of the data according to the species


use strict;
use warnings;
use DBI;
use Getopt::Long;
use Bio::EnsEMBL::Registry;
use FindBin qw( $Bin );
use Progress;

use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Variation::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Utils::Exception qw(throw);

use ImportUtils qw(dumpSQL debug create_and_load load);
use dbSNP::GenericContig;
use dbSNP::GenericChromosome;
use dbSNP::MappingChromosome;
use dbSNP::Mosquito;
use dbSNP::Human;
use dbSNP::EnsemblIds;
use dbSNP::DBManager;
use Bio::EnsEMBL::Variation::Pipeline::VariantQC::RegisterDBSNPImport qw(register);

# If a config file was specified, parse it and override any specified options
my @opts;
if (scalar(@ARGV) == 1) {
  my $configfile = $ARGV[0];
  print STDOUT "Reading configuration file $configfile\n";
  open(CFG,'<',$configfile) or die("Could not open configuration file $configfile for reading");
  while (<CFG>) {
    chomp;
    next unless/\w+/;
    my ($name,$val) = (split/\s+/,$_,2);             #altered for cow which had space in primary assembly tag
    push(@opts,('-' . $name,$val));
  }
  close(CFG);
  @ARGV = @opts;
}
  
my %options = ();
my @option_defs = (
  'species=s',
  'dbSNP_version=s',
  'shared_db=s',
  'tmpdir=s',
  'tmpfile=s',
  'limit=i',
  'mapping_file_dir=s',
  'schema_file=s',
  'dshost=s',
  'dsuser=s',
  'dspass=s',
  'dsport=i',
  'dsdbname=s',
  'registry_file=s',
  'mssql_driver=s',
  'skip_routine=s@',
  'scriptdir=s', 
  'logfile=s',
  'group_term=s',
  'group_label=s',
  'ensembl_version:s'
);

GetOptions(\%options,@option_defs);

debug("\n######### " . localtime() . " #########\n\tImport script launched\n");
print STDOUT "\n######### " . localtime() . " #########\n\tImport script launched\n";

my $LIMIT_SQL = $options{'limit'};
my $dbSNP_BUILD_VERSION = $options{'dbSNP_version'};
my $shared_db = $options{'shared_db'};
my $TMP_DIR = $options{'tmpdir'};
my $TMP_FILE = $options{'tmpfile'};
my $MAPPING_FILE_DIR = $options{'mapping_file_dir'};
my $SCHEMA_FILE = $options{'schema_file'};
my $GROUP_TERM  = $options{'group_term'};
my $GROUP_LABEL = $options{'group_label'};
my $species = $options{'species'};
my $dshost = $options{'dshost'};
my $dsuser = $options{'dsuser'};
my $dspass = $options{'dspass'};
my $dsport = $options{'dsport'};
my $dsdbname = $options{'dsdbname'};
my $registry_file = $options{'registry_file'};
my $mssql_driver = $options{'mssql_driver'};
my $scriptdir = $options{'scriptdir'};
my $logfile = $options{'logfile'};
my $ens_version = $options{'ensembl_version'};

my @skip_routines;
@skip_routines = @{$options{'skip_routine'}} if (defined($options{'skip_routine'}));

$ImportUtils::TMP_DIR = $TMP_DIR;
$ImportUtils::TMP_FILE = $TMP_FILE;

# Checking that some necessary arguments have been provided
die("Please provide a current schema definition file for the variation database, use -schema_file option!") unless (-e $SCHEMA_FILE);
# die("You must specify the dbSNP mirror host, port, user, pass, db and build version (-dshost, -dsport, -dsuser, -dspass, and -dbSNP_version options)") unless (defined($dshost) && defined($dsport) && defined($dsuser) && defined($dspass) && defined($dbSNP_BUILD_VERSION));
die("You must specify a temp dir and temp file (-tmpdir and -tmpfile options)") unless(defined($ImportUtils::TMP_DIR) && defined($ImportUtils::TMP_FILE));
die("You must specify the species. Use -species option") unless (defined($species));
die("You must specify the dbSNP build. Use -dbSNP_version option") unless (defined($dbSNP_BUILD_VERSION));
die("You must specify the dbSNP shared database. Use -shared_db option") unless (defined($shared_db));
die("You must specify the sql driver, either through an environment variable (SYBASE) or the -sql_driver option") unless (defined($mssql_driver) || defined($ENV{'SYBASE'}));

warn("Note that the port for the dbSNP mirror is overridden by the freetds configuration file!\n") if (defined($dsport));
warn("Make sure you have a updated ensembl.registry file!\n");

# Set the driver
$ENV{'SYBASE'} = $mssql_driver if (defined($mssql_driver));

# Set default option
$registry_file ||= $Bin . "/ensembl.registry";



# Open a file handle to the logfile. If it's not defined, use STDOUT
my $logh = *STDOUT;
if (defined($logfile)) {
  open(LOG,'>>',$logfile) or die ("Could not open logfile $logfile for writing");
  #Turn on autoflush for the logfile
  {
    my $ofh = select LOG;
    $| = 1;
    select $ofh;
  }
  $logh = *LOG;
  print $logh "\n######### " . localtime() . " #########\n\tImport script launched\n";
}

=head
Bio::EnsEMBL::Registry->load_all( $registry_file );

my $cdba = Bio::EnsEMBL::Registry->get_DBAdaptor($species,'core') or die ("Could not get core DBadaptor");
my $vdba = Bio::EnsEMBL::Registry->get_DBAdaptor($species,'variation') or die ("Could not get DBadaptor to destination variation database");
my $snpdba = Bio::EnsEMBL::Registry->get_DBAdaptor($species,'dbsnp') or die ("Could not get DBadaptor to dbSNP source database");
# Set the disconnect_when_inactive property
#$cdba->dbc->disconnect_when_inactive(1);
#$vdba->dbc->disconnect_when_inactive(1);
#$snpdba->dbc->disconnect_when_inactive(1);

$vdba->dbc->{mysql_auto_reconnect} = 1;
$cdba->dbc->{mysql_auto_reconnect} = 1;

$vdba->dbc->do("SET SESSION wait_timeout = 2678200");
$cdba->dbc->do("SET SESSION wait_timeout = 2678200");

 Set some variables on the MySQL server that can speed up table read/write/loads
my $stmt = qq{
  SET SESSION
    bulk_insert_buffer_size=512*1024*1024
};
$vdba->dbc->do($stmt);

if (!$dsdbname) {
  my $TAX_ID = $cdba->get_MetaContainer()->get_taxonomy_id() or throw("Unable to determine taxonomy id from core database for species $species.");
  my $version = $dbSNP_BUILD_VERSION;
  $version =~ s/^b//;
 $dsdbname = "$species\_$TAX_ID\_$version";
}

my $dbSNP = $snpdba->dbc;
my $dbVar = $vdba->dbc;
my $dbCore = $cdba;

#my $my_species = $mc->get_Species();
=cut

my $dbm = dbSNP::DBManager->new($registry_file,$species);
$dbm->dbSNP_shared($shared_db);
my $dbCore = $dbm->dbCore();

my ($cs) = @{$dbCore->get_CoordSystemAdaptor->fetch_all};
my $ASSEMBLY_VERSION = $cs->version();

#my $SPECIES_PREFIX = get_species_prefix($TAX_ID);

#create the dbSNP object for the specie we want to dump the data

my @parameters = (
  -DBManager => $dbm,
  -tmpdir => $TMP_DIR,
  -tmpfile => $TMP_FILE,
  -limit => $LIMIT_SQL,
  -mapping_file_dir => $MAPPING_FILE_DIR,
  -dbSNP_version => $dbSNP_BUILD_VERSION,
  -assembly_version => $ASSEMBLY_VERSION,
  -group_term  => $GROUP_TERM,
  -group_label => $GROUP_LABEL,
  -skip_routines => \@skip_routines,
  -scriptdir => $scriptdir,
  -log => $logh
);

my $import_object;

if ($species =~ m/felix_cattus/i || $species =~ m/zebrafinch|taeniopygia_guttata/i || $species =~ m/tetraodon/i) {
  $import_object = dbSNP::MappingChromosome->new(@parameters);
}
elsif ($species =~ m/zebrafish|danio/i || 
       $species =~ m/chimp|troglodytes/i || 
       $species =~ m/gallus_gallus/i || 
       $species =~ m/rat/i ||
       $species =~ m/horse|equus/i ||  
       $species =~ m/platypus|anatinus/i || 
       $species =~ m/opossum/i ||
       $species =~ m/mus_musculus/i || 
       $species =~ m/bos_taurus/i   || 
       $species =~ m/sus_scrofa/i   ||  
       $species =~ m/felix_cattus/i || 
       $species =~ m/zebrafinch|taeniopygia_guttata/i || 
       $species =~ m/tetraodon/i || 
       $species =~ m/orangutan|Pongo_abelii/i || 
       $species =~ m/monodelphis_domestica/i  || 
       $species =~ m/macaca_mulatta/i
    ) {
    $import_object = dbSNP::GenericChromosome->new(@parameters);
}
elsif ($species =~ m/dog|canis/i) {
  $import_object = dbSNP::GenericContig->new(@parameters);
}
elsif ($species =~ m/mosquitos/i) {
  $import_object = dbSNP::Mosquito->new(@parameters);
}
elsif ($species =~ m/human|homo/i) {
  $import_object = dbSNP::EnsemblIds->new(@parameters);
}
else {
  die("The species needs to have a module to use for import hardcoded into this script");
}

$import_object->{'schema_file'} = $SCHEMA_FILE;

my $clock = Progress->new();
$clock->checkpoint('start_dump');

$import_object->dump_dbSNP();

$clock->checkpoint('end_dump');
print $logh $clock->duration('start_dump','end_dump');

### Previously this script copied tmp_individual_genotypes to alleles for mouse, rat, chicken and dog.
### This behaviour ceased as of 30/1/2013


## update meta 
my $meta_ins_sth = $dbm->dbVar()->dbc->db_handle->prepare(qq[ INSERT INTO meta (species_id, meta_key, meta_value) values (?,?,?)]);

$meta_ins_sth->execute('1', 'species.production_name', $dbm->dbVar()->species() ) ||die;

if (defined $ens_version){
    $meta_ins_sth->execute('1','schema_version',  $ens_version ) ||die;
}


### update production db as final step

my $dbSNP_name = $dbm->dbSNP()->dbc->dbname();
$dbSNP_name =~ s/\_\d+$//;

my %data;

$data{dbSNP_name}       = $dbSNP_name;
$data{species}          = $dbm->dbVar()->species();
$data{ensdb_name}       = $dbm->dbVar()->dbc->dbname();
$data{registry}         = $dbm->registry();
$data{ensdb_version}    = $ens_version;
$data{assembly_version} = $ASSEMBLY_VERSION;
$data{pwd}              = $TMP_DIR;
register(\%data);






debug(localtime() . "\tAll done!");

#Close the filehandle to the logfile if one was specified
close($logh) if (defined($logfile));
  

sub usage {
    my $msg = shift;
    
    print STDERR <<EOF;
    
  usage: perl dbSNP.pl <options>
      
    options:
      -dshost <hostname>          hostname of dbSNP MSSQL database (default = dbsnp)
      -dsuser <user>              username of dbSNP MSSQL database (default = dbsnpro)
      -dspass <pass>              password of dbSNP MSSQL database
      -dsport <port>              TCP port of dbSNP MSSQL database (default = 1026)
      -dsdbname <dbname>          dbname of dbSNP MySQL database   (default = dbSNP_121)
      -chost <hostname>           hostname of core Ensembl MySQL database (default = ecs2)
      -cuser <user>               username of core Ensembl MySQL database (default = ensro)
      -cpass <pass>               password of core Ensembl MySQL database
      -cport <port>               TCP port of core Ensembl MySQL database (default = 3364)
      -cdbname <dbname>           dbname of core Ensembl MySQL database
      -vhost <hostname>           hostname of variation MySQL database to write to
      -vuser <user>               username of variation MySQL database to write to (default = ensadmin)
      -vpass <pass>               password of variation MySQL database to write to
      -vport <port>               TCP port of variation MySQL database to write to (default = 3306)
      -vdbname <dbname>           dbname of variation MySQL database to write to
      -limit <number>             limit the number of rows transfered for testing
      -tmpdir <dir>               temporary directory to use (with lots of space!)
      -tmpfile <filename>         temporary filename to use
      -mapping_file <filename>    file containing the mapping data
      -group_term <group_term>    select the group_term to import
      -group_label <group_label>  select the group_label to import
                        
EOF

      die("\n$msg\n\n");
}

