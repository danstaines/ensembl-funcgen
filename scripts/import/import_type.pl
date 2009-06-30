#!/software/bin/perl -w


####!/opt/local/bin/perl -w


=head1 NAME

import_type.pl
  
=head1 SYNOPSIS

import_array_from_fasta.pl [options]

The script will import a new CellType, FeatureType or Analysis.


=head1 OPTIONS

=over 8

=item B<-name|n>

Mandatory:  Instance name for the data set, this is the directory where the native data files are located

=item B<-format|f>

Mandatory:  The format of the data files e.g. nimblegen

=item B<-group|g>

Mandatory:  The name of the experimental group


=item B<-data_root>

The root data dir containing native data and pipeline data, default = $ENV{'EFG_DATA'}

=item B<-fasta>

Flag to turn on dumping of all probe_features in fasta format for the remapping pipeline

=item B<-norm>

Normalisation method, deafult is the Bioconductor vsn package which performs generalised log ratio transformations

=item B<-species|s>

Species name for the array.

=item B<-debug>

Turns on and defines the verbosity of debugging output, 1-3, default = 0 = off


=item B<-help>

Print a brief help message and exits.

=item B<-man>

Prints the manual page and exits.

=back

=head1 DESCRIPTION

B<This program> takes a input redundant probe name fasta file and generates an NR probe dbID fasta file.

=cut


#add @INC stuff here, or leave to .bashrc/.efg?

BEGIN{
  if (! defined $ENV{'EFG_DATA'}) {
	if (-f "~/src/ensembl-functgenomics/scripts/.efg") {
	  system (". ~/src/ensembl-functgenomics/scripts/.efg");
	} else {
	  die ("This script requires the .efg file available from ensembl-functgenomics\n".
		   "Please source it before running this script\n");
	}
  }
}
	

#use Bio::EnsEMBL::Root; #Only used for rearrange see pdocs
#Roll own Root object to handle debug levels, logging, dumps etc.

### MODULES ###
use Getopt::Long;
#use Carp;#For dev only? cluck not exported by default Remove this and implement in Helper
use Pod::Usage;
#POSIX? File stuff
use File::Path;
#use Bio::EnsEMBL::Registry;
use Bio::EnsEMBL::Utils::Exception qw( throw warning );
use Bio::EnsEMBL::Funcgen::Utils::EFGUtils qw (open_file run_system_cmd backup_file);
use Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Funcgen::FeatureType;
use Bio::EnsEMBL::Funcgen::CellType;
use Bio::EnsEMBL::Analysis;
use Data::Dumper;
use strict;

$| = 1;							#autoflush
my ($pass, $dbname, $array_name, $line, $label, $dnadb_user, $dnadb_port);
my ($clobber, $type, $desc, $file, $class, $logic_name, $name, $dnadb_host);
my ($anal_db, $db_version, $db_file, $program, $program_version, $program_file);
my ($gff_source, $gff_feature, $module, $module_version, $parameters, $created);
my ($displayable, $web_data, $species);

#Need to change these to match EFG_USER EFG_HOST EFG_PORT
#And then test
my $user = "ensadmin";
my $host = 'ens-genomics1';
my $port = '3306';


#should also build cache and generate nr file?
#this depends on id/name field refering to unique seq
#same name can't refer to more than one seq
my @tmp_args = @ARGV;

GetOptions (
			#general params
			"file|f=s"        => \$file,
			"pass|p=s"        => \$pass,
			"port=s"          => \$port,
			"host|h=s"        => \$host,
			"dnadb_host=s"    => \$dnadb_host,
			"dnadb_user=s"    => \$dnadb_user,
			"dnadb_port=s"    => \$dnadb_port,
			"user|u=s"        => \$user,
			"dbname|d=s"      => \$dbname,
			"species=s"       => \$species,
			"help|?"          => sub { pos2usage(-exitval => 0, -message => "Params are:\t@tmp_args"); },
			"man|m"           => sub { pos2usage(-exitval => 0, -verbose => 2, -message => "Params are:\t@tmp_args"); },
			"type|t=s"        => \$type,
			'clobber'         => \$clobber,#update old entries?
			#Cell/Feature params
			"class=s"         => \$class,#FeatureType only
			"display_label=s" => \$label,
			"name=s"          => \$name,
			"description=s"   => \$desc,
			#analysis opts
			"logic_name=s"    => \$logic_name,
			"db=s"            => \$anal_db,
			"db_version=s"    => \$db_version,
			"db_file=s"       => \$db_file,
			"program=s"       => \$program,
			"program_version=s" => \$program_version,
			"program_file=s"    => \$program_file,
			"gff_source=s"      => \$gff_source,
			"gff_feature=s"     => \$gff_feature,
			"module=s"          => \$module,
			"module_version=s"  => \$module_version,
			"parameters=s"      => \$parameters,
			"created=s"         => \$created,
			"displayable=s"     => \$displayable,
			"web_data=s"        => \$web_data,
		   ) or pod2usage(
						 -exitval => 1,
						 -message => "Params are:\t@tmp_args");


#This should work for any object so long as we set u the config correctly

my %type_config = (
				   'FeatureType' => {(
									  class            => 'Bio::EnsEMBL::Funcgen::FeatureType',
									  fetch_method     => 'fetch_by_name',
									  fetch_arg       => '-name',
									  mandatory_params => {(
															-name        => $name,
														   )},
									  optional_params  => {(
															-class       => $class,
															-description => $desc,
															
														   )},
									 )},

				   'CellType' => {(
								   class            => 'Bio::EnsEMBL::Funcgen::CellType',
								   fetch_method     => 'fetch_by_name',
								   fetch_arg       => '-name',
								   mandatory_params => {(
														 -name          => $name,
														)},
								   optional_params  => {(
														 -display_label => $label,
														 -description   => $desc,
														)},

								  )},
				   
				   'Analysis' => {(
								   class            => 'Bio::EnsEMBL::Analysis',
								   fetch_method => 'fetch_by_logic_name',
								   fetch_arg   => '-logic_name',
								   
								   #DB
								   #DB_VERSION
								   #DB_FILE
								   #PROGRAM
								   #PROGRAM_VERSION
								   #PROGRAM_FILE
								   #GFF_SOURCE
								   #GFF_FEATURE
								   #MODULE
								   #MODULE_VERSION
								   #PARAMETERS
								   #CREATED
								   #LOGIC_NAME
								   #DESCRIPTION
								   #DISPLAY_LABEL
								   #DISPLAYABLE
								   #WEB_DATA


								   #this is assumed mandatory params as they are not forced in Analysis->new
								   mandatory_params => {(
														 -logic_name => $logic_name,
														)},
								   optional_params => {(
														-db => $anal_db,
														-db_version => $db_version,
														-db_file => $db_file,
														-program => $program,
														-program_version => $program_version,
														-program_file => $program_file,
														-gff_source => $gff_source,
														-gff_feature => $gff_feature,
														-module => $module,
														-module_version => $module_version,
														-parameters => $parameters,
														-created => $created,
														-description => $desc, #DESCRIPTION
														-display_label => $label,#DISPLAY_LABEL
														-displayable => $displayable,
														-web_data => $web_data,
													   )},
								  )},
				  
				   
				  );

#generic mandatory params
if(!(exists $type_config{$type} && $dbname && $pass && $species)){
  throw("Mandatory parameters not met -dbname -pass -species or $type config is not yet accomodated");
}


#now do type specific checking

my $db = Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor->new(
													  -dbname  => $dbname,
													  -port    => $port,
													  -pass    => $pass,
													  -host    => $host,
													  -user    => $user,
													  -dnadb_host => $dnadb_host,
													  -dnadb_port => $dnadb_port,
													  -dnadb_user => $dnadb_user,
													  -species => $species,
													 );

my $fetch_method = $type_config{$type}->{'fetch_method'};
my $obj_class = $type_config{$type}->{'class'};
my $method = 'get_'.$type.'Adaptor';
my $adaptor = $db->$method();
my ($field, @values);

if($file){

  #parse file here
  #parse headers to match to params and call relevant sub


  my @fields = keys %{$type_config{$type}{mandatory_params}};
  push @fields, keys %{$type_config{$type}{optional_params}};

  map $_=~ s/^-//, @fields;

  #Could set header hash here? using helper?
  #Or should this be in EFGUtils?

  #would need to clean hash values here
  my $in = open_file($file);


  my @header = split /\s+/, <$in>;#Will this slurp?

  #mysql -hens-genomics1 -uensro -e "select name, class, description from feature_type where class in('Histone', 'Regulatory Feature', 'Open Chromatin', 'Insulator')" homo_sapiens_funcgen_55_37


  my $hposns = set_header_hash(\@header, \@fields);

  while ($line = <$in>){
	next if $line =~ /^#/;

	chomp $line;

	@values = split /\t/, $line;
	
	#This will clean all the old values
	foreach my $param(keys %{$type_config{$type}{mandatory_params}}){
	  ($field = $param) =~ s/^-//;
	  $type_config{$type}{mandatory_params}{$param} = $values[$hposns->{$field}];
	}
	
	foreach my $param(keys %{$type_config{$type}{optional_params}}){
	  ($field = $param) =~ s/^-//;
	  $type_config{$type}{optional_params}{$param} = $values[$hposns->{$field}];
	}
		
	&import_type;
  }


}else{
  #Values already set
  &import_type;
}


sub import_type{

  #check mandatorys here

  foreach my $man_param(keys %{$type_config{$type}{'mandatory_params'}}){
	throw ("$man_param not defined") if ! defined $type_config{$type}->{'mandatory_params'}->{$man_param};
  }


  #test if already present
  my $obj = $adaptor->$fetch_method($type_config{$type}{mandatory_params}->{$type_config{$type}->{'fetch_arg'}});
  
  if(defined $obj){
	warn("Found pre-existing $type object:\t".$type_config{$type}{mandatory_params}->{$type_config{$type}->{'fetch_arg'}}.
		 "\nClobber/Update not yet implementing, skipping import\n");
	
  }
  else{
	$obj = new $obj_class(%{$type_config{$type}->{'mandatory_params'}}, 
						   %{$type_config{$type}->{'optional_params'}});

	print "Storing $type ".$type_config{$type}{mandatory_params}->{$type_config{$type}->{'fetch_arg'}}."\n";

	$adaptor->store($obj);
  }

  return;
}


#Should use helper for this and add logging

sub set_header_hash{
  my ($self, $header_ref, $fields) = @_;
	
  my %hpos;

  for my $x(0..$#{$header_ref}){
    $hpos{$header_ref->[$x]} = $x;
  }	


  if($fields){

    foreach my $field(@$fields){
	  
      if(! exists $hpos{$field}){
	throw("Header does not contain mandatory field:\t${field}");
      }
    }
  }
  
  return \%hpos;
}
