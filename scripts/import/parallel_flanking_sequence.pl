use strict;
use warnings;

use Getopt::Long;
use Fcntl ':flock';
use DBI;
use DBH;

use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Utils::Exception qw(warning throw verbose);
use ImportUtils qw(debug load);


my ($TMP_DIR, $TMP_FILE, $LIMIT,$status_file);

{
  my ($vhost, $vport, $vdbname, $vuser, $vpass,
      $chost, $cport, $cdbname, $cuser, $cpass,
      $limit, $num_processes);

  GetOptions('chost=s'   => \$chost,
             'cuser=s'   => \$cuser,
             'cpass=s'   => \$cpass,
             'cport=i'   => \$cport,
             'cdbname=s' => \$cdbname,
             'vhost=s'   => \$vhost,
             'vuser=s'   => \$vuser,
             'vpass=s'   => \$vpass,
             'vport=i'   => \$vport,
             'vdbname=s' => \$vdbname,
             'tmpdir=s'  => \$ImportUtils::TMP_DIR,
             'tmpfile=s' => \$ImportUtils::TMP_FILE,
             'limit=s'   => \$limit,
	     'num_processes=i' => \$num_processes,
	     'status_file=s' => \$status_file);

  #added default options
  $chost    ||= 'ecs2';
  $cuser    ||= 'ensro';
#  $cport    ||= 3364;

  $vport    ||= 3306;
  $vuser    ||= 'ensadmin';
  
  $num_processes ||= 1;

  $LIMIT = ($limit) ? " LIMIT $limit " : '';

  usage('-vdbname argument is required') if(!$vdbname);
  usage('-cdbname argument is required') if(!$cdbname);

  usage('-num_processes must at least be 1') if ($num_processes == 0);
  usage('-status_file argument is required') if (!$status_file);

  my $dbCore = Bio::EnsEMBL::DBSQL::DBAdaptor->new
    (-host   => $chost,
     -user   => $cuser,
     -pass   => $cpass,
     -port   => $cport,
     -dbname => $cdbname);

  my $dbVar = DBH->connect
    ("DBI:mysql:host=$vhost;dbname=$vdbname;port=$vport",$vuser, $vpass );
  die("Could not connect to variation database: $!") if(!$dbVar);


  $TMP_DIR  = $ImportUtils::TMP_DIR;
  $TMP_FILE = $ImportUtils::TMP_FILE;

  flanking_sequence($dbCore,$dbVar);
  open STATUS, ">>$TMP_DIR/$status_file"
    or throw("Could not open tmp file: $TMP_DIR/$status_file\n"); 
  flock(STATUS,LOCK_EX);
  seek(STATUS, 0, 2); #move to the end of the file
  print STATUS "process finished\n";
  flock(STATUS,LOCK_UN);
  close STATUS;
  #check if it is the last process
  my $processes = `cat $TMP_DIR/$status_file | wc -l`;
  if ($processes == $num_processes){
      #if is the last process, delete the variation table and upload with the new coordinate information from the different tables
      last_process($dbCore,$dbVar);
  }
}


#
# Compresses flanking sequence storage by only storing genomic coordinates
# when the genomic sequence exactly matches the flanking sequence.
#
sub flanking_sequence {
  my $dbCore = shift;
  my $dbVar  = shift;

  debug("Compressing storage of flanking sequence");
  my $slice_adaptor = $dbCore->get_SliceAdaptor();

  #there are problems with disk space for this query. To avoid them, I will first select the variation_id we want to calculate the flanking_Sequence
# and then, run the query
  my $sth_variation = $dbVar->prepare(qq{SELECT variation_id
					 FROM flanking_sequence
				     ORDER BY variation_id
				 $LIMIT});
  $sth_variation->execute();
  my $var_id;
  $sth_variation->bind_columns(\$var_id);
  #in the parallel version, I will write to a file all the flanking sequences to avoid locking the database for updates
  my $dbname = $dbVar->dbname(); #get the name of the database to create the file
  open FH, ">$TMP_DIR/$dbname.flanking_sequence_$$\.txt"
      or throw("Could not open tmp file: $TMP_DIR/flanking_sequence_$$\n");
  while ($sth_variation->fetch()){
      my $sth = $dbVar->prepare(qq{SELECT fs.up_seq, fs.down_seq,
				   vf.seq_region_id, vf.seq_region_start,
				   vf.seq_region_end, vf.seq_region_strand
				       FROM flanking_sequence fs LEFT JOIN variation_feature vf
				       ON vf.variation_id = fs.variation_id
				       WHERE fs.variation_id = ?});
      
      
      $sth->execute($var_id);
      my ($up_seq, $dn_seq, $sr_id, $sr_start, $sr_end, $sr_strand);
      $sth->bind_columns(\$up_seq, \$dn_seq, \$sr_id, \$sr_start,
			 \$sr_end, \$sr_strand);
      
      while($sth->fetch()) {
	  my ($up_sr_start, $up_sr_end, $dn_sr_start, $dn_sr_end);
          #only figure out coordinates if there is entry in the VARIATION_FEATURE table
	  if (!$sr_id){
	      $sr_id = '\N';
	      $up_sr_start = '\N';
	      $up_sr_end = '\N';
	      $dn_sr_start = '\N';
	      $dn_sr_end = '\N';
	      $sr_strand = '\N';
	  }
	  else{
	      my $up_len = 0;
	      my $dn_len = 0;
	      $up_len = length($up_seq) if ($up_seq);
	      $dn_len = length($dn_seq) if ($dn_seq);
	      
	      # figure out the coordinates of the flanking sequence	      
	      
	      if($sr_strand == 1) {
		  $up_sr_start = $sr_start - $up_len;
		  $up_sr_end   = $sr_start - 1;
		  $dn_sr_start = $sr_end + 1;
		  $dn_sr_end   = $sr_end + $dn_len;
	      } else {
		  $up_sr_start = $sr_end + 1;
		  $up_sr_end   = $sr_end + $up_len;
		  $dn_sr_start = $sr_start - $dn_len;
		  $dn_sr_end   = $sr_start - 1;
	      }
	      
	      my $slice = $slice_adaptor->fetch_by_seq_region_id($sr_id);
	      if(!$slice) {
		  warning("Could not obtain slice for seq_region_id $sr_id\n");
		  next;
	      }
	  
	      # compare sequence in database to flanking sequence
	      # if it matches store only coordinates, otherwise still store flanking
	      
	      # there are sometimes off by ones in dbSNP, try to take this into account
	      # with a 'wobble' of one base on either side
	      my @wobble = (0, 1, -1);
	      my $i = 0;
	      my $w;
	      while((defined($up_seq) || defined($dn_seq)) && $i < 3) {
		  $w = $wobble[$i++];
	      
		  if(defined($up_seq)) {
		      my $up = $slice->subseq($up_sr_start+$w, $up_sr_end+$w, $sr_strand);
		      $up_seq = undef if(uc($up) eq uc($up_seq));
		      if($w && !defined($up_seq)){
			print STDERR "*";
			$up_sr_start += $w;
			$up_sr_end += $w;
		    }
		  }
		  
		  if(defined($dn_seq)) {
		      my $dn = $slice->subseq($dn_sr_start+$w, $dn_sr_end+$w, $sr_strand);
		      $dn_seq = undef if(uc($dn) eq uc($dn_seq));
		      if($w && !defined($dn_seq)){
			  print STDERR "*";
			  $dn_sr_start += $w;
			  $dn_sr_end += $w;
		      }
		  }
	      }
	      #to write NULL values in the database, we have to write \n
	      $up_sr_start = $up_sr_end = '\N' if (defined($up_seq));
	      $dn_sr_start = $dn_sr_end = '\N' if(defined($dn_seq));	 

	      $up_seq = '\N' if (!defined($up_seq));
	      $dn_seq = '\N' if (!defined($dn_seq));
	 
	  }
	  #print to the file the information
	  print FH join("\t",$var_id,$up_seq, $dn_seq, $up_sr_start, $up_sr_end,$dn_sr_start, $dn_sr_end, $sr_id, $sr_strand),"\n";
      }
      $sth->finish();
  }
  close FH;
  $sth_variation->finish();
  return;
}


#will know if it is the last process running counting the lines of the status_file.
sub last_process{
    my $dbCore = shift;
    my $dbVar = shift;

#    debug("Deleting existing flanking_sequences");
    $dbVar->do("DELETE FROM flanking_sequence");

    debug("Reimporting processed flanking sequences");
    #group all the fragments in 1 file
    my $dbname = $dbVar->dbname(); #get the name of the database to create the file
    my $call = "cat $TMP_DIR/$dbname.flanking_sequence*.txt > $TMP_DIR/$TMP_FILE";
    system($call);
    #delete the files
    unlink(<$TMP_DIR/$dbname.flanking_sequence*.txt>);

    #and upload all the information to the flanking_sequence table
    load ($dbVar,qw(flanking_sequence variation_id up_seq down_seq up_seq_region_start up_seq_region_end down_seq_region_start down_seq_region_end seq_region_id seq_region_strand));
    
    update_meta_coord($dbCore, $dbVar, 'flanking_sequence');

    unlink("$TMP_DIR/$status_file");
}

#
# updates the meta coord table
#
sub update_meta_coord {
  my $dbCore = shift;
  my $dbVar  = shift;
  my $table_name = shift;
  my $csname = shift || 'chromosome';

  my $csa = $dbCore->get_CoordSystemAdaptor();

  my $cs = $csa->fetch_by_name($csname);

  my $sth = $dbVar->prepare
    ('INSERT INTO meta_coord set table_name = ?, coord_system_id = ?');

  $sth->execute($table_name, $cs->dbID());

  $sth->finish();

  return;
}

sub usage {
  my $msg = shift;

  print STDERR <<EOF;

usage: perl parallel_flanking_sequence.pl <options>

options:
    -chost <hostname>    hostname of core Ensembl MySQL database (default = ecs2)
    -cuser <user>        username of core Ensembl MySQL database (default = ensro)
    -cpass <pass>        password of core Ensembl MySQL database
    -cport <port>        TCP port of core Ensembl MySQL database (default = 3364)
    -cdbname <dbname>    dbname of core Ensembl MySQL database
    -vhost <hostname>    hostname of variation MySQL database to write to
    -vuser <user>        username of variation MySQL database to write to (default = ensadmin)
    -vpass <pass>        password of variation MySQL database to write to
    -vport <port>        TCP port of variation MySQL database to write to (default = 3306)
    -vdbname <dbname>    dbname of variation MySQL database to write to
    -limit <number>      limit the number of rows for testing
    -tmpdir <dir>        temp directory to use (with lots of space!)
    -tmpfile <filename>   name of temp file to use
    -num_processes <number> number of processes that are running (default = 1)
    -status_file <filename> name of a temp file where all the processes write when they finish
EOF

  die("\n$msg\n\n");
}
