
=head1 NAME

Bio::EnsEMBL::Funcgen::Importer
  
=head1 SYNOPSIS

my $imp = Bio::EnsEMBL::Funcgen::Importer->new(%params);
$imp->register_experiment();


=head1 DESCRIPTION

B<This program> is the main class coordinating import of Arrays and experimental data.
It utilises several underlying definitions classes specific to array vendor, array class and
experimental group.  

=head1 CONTACT

Post questions to the EnsEMBL development list ensembl-dev@ebi.ac.uk


=head1 AUTHOR(S)

Nathan Johnson, njohnson@ebi.ac.uk



=cut

################################################################################

package Bio::EnsEMBL::Funcgen::Importer;

use Bio::EnsEMBL::Funcgen::Utils::EFGUtils qw(get_date open_file run_system_cmd);
use Bio::EnsEMBL::Utils::Exception qw( throw deprecate );
use Bio::EnsEMBL::Utils::Argument qw( rearrange );
use Bio::EnsEMBL::Funcgen::Experiment;
use Bio::EnsEMBL::Funcgen::Parsers::ArrayDesign;
use Bio::EnsEMBL::Funcgen::Parsers::Sanger;
use Bio::EnsEMBL::Funcgen::Parsers::Nimblegen;
use Bio::EnsEMBL::Funcgen::Parsers::Bed;
use Bio::EnsEMBL::Funcgen::Utils::Helper;
use Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Registry;
use Bio::MAGE::XMLUtils;
use strict;
use vars qw(@ISA);

use Data::Dumper;


################################################################################

=head2 new

 Description : Constructor method

 Arg  [1]    : hash containing optional attributes:
                    -name     Name of Experiment(dir) 
                    -format   of array e.g. Tiled(default)
                    -vendor   name of array vendor
                    -description of the experiment
                    -pass DB password
		    -host DB host
		    -user  DB user
		    -port  DB port
                    -ssh  Flag to set connection over ssh via forwarded port to localhost (default = 0); remove?
                    -group    name of experimental/research group
                    -location of experimental/research group
                    -contact  e/mail address of primary contact for experimental group
                    -species 
                    -assembly Genome assembly version i.e. 36 for NCBI36
                    -recover Recovery flag (default = 0)
                    -data_dir  Root data directory (default = $ENV{'EFG_DATA'})
                    -output_dir review these dirs ???????
                    -input_dir  ?????????
                    -import_dir  ???????
                    -norm_dir    ??????
                    -fasta dump FASTA flag (default =0)
                    -array_set Flag to treat all chip designs as part of same array (default = 0)
                    -array_name Name for array set
                    -array_file Path of array file to import for sanger ENCODE array
                    -result_set_name  Name to give the raw and normalised result sets (default uses experiment and analysis name)
                    -norm_method  Normalisation method (Nimblegen default = VSN_GLOG or $ENV{'NORM_METHOD'})
                    -dbname Override for autogeneration of funcgen dbaname
                    -reg_config path to local registry config file (default = ~/ensembl.init || undef)
                    -design_type MGED term (default = binding_site_identification) get from meta/MAGE?
                    -verbose
 ReturnType  : Bio::EnsEMBL::Funcgen::Importer
 Example     : my $Exp = Bio::EnsEMBL::Importer->new(%params);
 Exceptions  : throws if mandatory params are not set or DB connect fails
 Caller      : General
 Status      : Medium - potential for %params names to change, remove %attrdata?

=cut

################################################################################

sub new{
  my ($caller) = shift;

  my $reg = "Bio::EnsEMBL::Registry";
  my $class = ref($caller) || $caller;

  my ($name, $format, $vendor, $group, $location, $contact, $species,
	  $array_name, $array_set, $array_file, $data_dir, $result_files,
	  $ftype_name, $ctype_name, $exp_date, $desc, $user, $host, $port, 
	  $pass, $dbname, $db, $assm_version, $design_type, $output_dir, $input_dir,
	  $farm, $ssh, $fasta, $recover, $reg_config, $write_mage, $no_mage, $eset_name, 
	  $norm_method, $old_dvd_format, $feature_analysis, $reg_db, $parser_type, $ucsc_coords, $verbose)
	= rearrange(['NAME', 'FORMAT', 'VENDOR', 'GROUP', 'LOCATION', 'CONTACT', 'SPECIES', 
				 'ARRAY_NAME', 'ARRAY_SET', 'ARRAY_FILE', 'DATA_DIR', 'RESULT_FILES',
				 'FEATURE_TYPE_NAME', 'CELL_TYPE_NAME', 'EXPERIMENT_DATE', 'DESCRIPTION',
				 'USER', 'HOST', 'PORT', 'PASS', 'DBNAME', 'DB', 'ASSEMBLY', 'DESIGN_TYPE',
				 'OUTPUT_DIR', 'INPUT_DIR',	#to allow override of defaults
				 'FARM', 'SSH', 'DUMP_FASTA', 'RECOVER', 'REG_CONFIG', 'WRITE_MAGE', 
				 'NO_MAGE', 'EXPERIMENTAL_SET_NAME', 'NORM_METHOD', 'OLD_DVD_FORMAT',
				 'FEATURE_ANALYSIS', 'REGISTRY_DB', 'PARSER', 'UCSC_COORDS', 'VERBOSE'], @_);

  
  #### Define parent parser class based on vendor
  throw("Mandatory argument -vendor not defined") if ! defined $vendor;

  #This will override the default Vendor Parser type
  #Evals simply protect from messy errors if parser type not found
  my $parser_error;
  my $vendor_parser = ucfirst(lc($vendor));
  eval {require "Bio/EnsEMBL/Funcgen/Parsers/${vendor_parser}.pm";};
 

  if($@){
	#Don't warn/throw yet as we might have a standard parser format
	$parser_error = "There is no valid parser for the vendor your have specified:\t".$vendor.
	  "\nMaybe this is a typo or maybe you want to specify a default import format using the -parser option\n".$@;
  }


  if(defined $parser_type){
	$parser_type = ucfirst(lc($parser_type));

	#Now eval the new parser
	eval {require "Bio/EnsEMBL/Funcgen/Parsers/${parser_type}.pm";};

	if($@){

	  #Might be no default
	  my $txt = "There is no valid parser for the -parser format your have specified:\t".$parser_type."\n";

	  if(! $parser_error){
		$txt .= "Maybe this is a typo or maybe you want run with the default $vendor_parser parser\n";
	  }

	  throw($txt.$@);
	}
		
	#warn about over riding vendor parser here
	if(! $parser_error){
	  #Can't log this as we haven't blessed the Helper yet
	  warn("WARNING\t::\tYou are over-riding the default ".$vendor." parser with -parser ".$parser_type);
	}
  }
  else{
	throw($parser_error) if $parser_error;
	$parser_type = $vendor_parser;
  }

  #we should now really set parser_type as an attrtibute
  #So we know what we're dealing with outside of the Parser itself


  #if ($vendor =~ /^affymetrix$/i) {
  #    $parser_type = 'Bed';
  #} else {
  #    $parser_type = ucfirst(lc($vendor));
  #}

  unshift @ISA, 'Bio::EnsEMBL::Funcgen::Parsers::'.$parser_type;
  #change this to be called explicitly from the load script?

  #### Create object from parent class

  my $self = $class->SUPER::new(@_);
    
  #### Set vars and test minimum mandatory params for any import type

  $self->{'name'} = $name if $name;
  $self->vendor(uc($vendor));	#already tested
  $self->{'format'} = uc($format) || 'TILED'; #remove default?
  $self->group($group) if $group;
  $self->location($location) if $location;
  $self->contact($contact) if $contact;
  $self->{'species'} = $species || throw('Mandatory param -species not met');
  $self->array_name($array_name) if $array_name;
  $self->array_set($array_set) if $array_set;
  $self->array_file($array_file) if $array_file;
  $self->{'data_dir'} = $data_dir || $ENV{'EFG_DATA'};
  $self->result_files($result_files)if $result_files; #Sanger specific ???
  $self->experiment_date($exp_date) if $exp_date;
  $self->description($desc) if $desc;
  $assm_version || throw('Mandatory param -assembly not met');
  $self->{'design_type'} = $design_type || 'binding_site_identification'; #remove default?
  $self->{'output_dir'} = $output_dir if $output_dir; #config default override
  $self->input_dir($input_dir) if $input_dir; #config default override
  $self->farm($farm) if $farm;
  $self->{'ssh'} = $ssh || 0;
  $self->{'_dump_fasta'} = $fasta || 0;
  $self->{'recover'} = $recover || 0;
  #check for ~/.ensembl_init to mirror general EnsEMBL behaviour
  $self->{'reg_config'} = $reg_config || ((-f "$ENV{'HOME'}/.ensembl_init") ? "$ENV{'HOME'}/.ensembl_init" : undef);
  #$self->{'update_xml'} = $update_xml || 0;
  $self->{'write_mage'} = $write_mage || 0;
  $self->{'no_mage'} = $no_mage || 0;
  $self->{'experimental_set_name'} = $eset_name if $eset_name;
  $self->{'old_dvd_format'} = $old_dvd_format || 0;
  $self->{'ucsc_coords'} = $ucsc_coords || 0;
  $self->{'verbose'} = $verbose || 0;

  #Will a general norm method be applicable for all imports?
  #Already casued problems with Bed imports... remove?
  #Could set NORM_METHOD in Parser!!
  warn "Need to fully implement norm_method is validate_mage, remove ENV NORM_METHOD?";
  $self->{'norm_method'} = $norm_method || $ENV{'NORM_METHOD'};
 
  if ($self->vendor ne 'NIMBLEGEN'){
	$self->{'no_mage'} = 1;
	warn "Hardcoding no_mage for non-NIMBLEGEN imports";
  }

 
  if($self->{'no_mage'} && $self->{'write_mage'}){
	throw('-no_mage and -write_mage options are mutually exclusive, please select just one');
  }

  #### Set up DBs and load and reconfig registry

  ### Load Registry
  #Can we load the registry using the assembly version, then just redefine the efg DB?
  #We have problems here if we try and load on a dev version, where no dev DBs are available on ensembldb
  #Right what we need to do here is get the latest API version for the assembly we want to use
  #Then load the registry from that version
  #Then we can remove some of the dnadb setting code below?

  #How does the registry pick up the schema version??

  #We should really load the registry first given the dnadb assembly version
  #Then reset the eFG DB as appropriate


  if (! defined $self->{'_reg_config'}) {
	#current ensembl DBs

	#This will try and load the dev DBs if we are using v49 schema or API?
	#Need to be mindful about this when developing
	#Can we for loading of an older registry?


	$reg->load_registry_from_db(
								-host => "ensembldb.ensembl.org",
								-user => "anonymous",
								-db_version => 48, #$self->{'release'},
								-verbose => $self->verbose(),
							   );

	
	throw('Not sensible to set the import DB as the default eFG DB from ensembldb, please define db params') if ((! $dbname) && (! $db));;
  }
  else{
	$reg->load_all($self->{'_reg_config'}, 1);
  }


  #SET UP DBs
  #reset species to standard alias to allow dbname generation
  $self->species($reg->get_alias($self->species()));


  if($db){
	#sanity test vs. data_version
	if(! (ref($db) && $db->isa('Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor'))){
	  $self->throw('-db must be a valid Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor');
	}
  }
  else{
	#define eFG DB from params or registry

	if($reg_db){#load eFG DB from reg

	  #we should throw here if db params are set
	  #How do we handle passwords within the reg config?
	  #Do we still need to pass this when loading?

	  $self->log('WARNING: Loading eFG DB from Registry');
	  $db = $reg->get_DBAdaptor($self->species(), 'funcgen');
	  throw("Unable to retrieve ".$self->species." funcgen DB from the registry");
	}
	else{#from params
	  #This resets the eFG DB in the custom or generic registry

	  #Need to check for mandatory params here

	  $dbname || throw('Must provide a -dbname if not using default custom registry config');
	  $user || throw('Must provide a -user parameter');
	  $pass || throw('Must provide a -pass parameter');
	 
	  #remove this and throw?
	  if(! defined $host){
		$self->log('WARNING: Defaulting to localhost');
		$host = 'localhost';
	  }
	  
	  $port ||= 3306;
	  my $host_ip = '127.0.0.1';#is this valid for all localhosts?
	  
	  if ($self->{'ssh'}) {
		$host = `host localhost`; #mac specific? nslookup localhost wont work on server/non-PC 
		#will this always be the same?
		
		if (! (exists $ENV{'EFG_HOST_IP'})) {
		  warn "Environment varaible EFG_HOST_IP not set for ssh mode, defaulting to $host_ip for $host";
		} else {
		  $host_ip = $ENV{'EFG_HOST_IP'};
		}
		
		if ($self->host() ne 'localhost') {
		  warn "Overriding host ".$self->host()." for ssh connection via localhost($host_ip)";
		}
	  }
	

	  #data version is only used if we don't want to define the dbname
	  #This should never be guessed so don't need data_version here
	  #$dbname ||= $self->species()."_funcgen_".$self->data_version();


	  #Remove block below when we can
	  my $dbhost = ($self->{'ssh'}) ? $host_ip : $host;

	  #This isn't set yet!?
	  #When we try to load, say 49, when we only have 48 on ensembldb
	  #This fails because there is not DB set for v49, as it is not on ensembl DB
	  #In this case we need to load from the previous version
	  #Trap this and suggest using the -schema_version/release option
	  #Can we autodetect this and reload the registry?
	  #We want to reload the registry anyway with the right version corresponding to the dnadb

	  $db = $reg->reset_DBAdaptor($self->species(), 'funcgen', $dbname, $dbhost, $port, $user, $pass);


	  #ConfigRegistry will try ans set this
	  #This will fail if there is already one in the registry as it will try
	  #and defined a new unique species so as not to overwrite the original
	  #e.g. homo_sapiens1
	  
	  #This is why it was orignally written backwards as we can't easily dynamically redefine
	  #an adaptor in the registry without ConfigRegistry trying to change the name
	  #the very act of creating a new db to redefine the registry with causes ConfigRegistry
	  #to try and register it with a unique species name

	  #Delete the old funcgen DB from the registry first
	  #$reg->remove_DBAdaptor($self->species, 'funcgen');

	  #ConfigRegistry will automatically configure this new db
	  
	  #$db = Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor->new(
	#													 -user => $user,
	#													 -host => ($self->{'ssh'}) ? $host_ip : $host,
	#													 -port => $port,
	#													 -pass => $pass,
	#													 #we need to pass dbname else we can use non-standard dbs
	#													 -dbname => $dbname,
	#													 -species => $self->species(),
	#													 -group    => 'funcgen',
	#													);


	  #if we get a species like homo_sapiens1 here
	  #This is because ConfigRegistry is try to make the dbname different between the 
	  #one already present and the one you're trying to add
	}
  }

    
  ### VALIDATE DNADB

  #We can change this to just use the assembly version
  #we could even have the wordy assmelby version from the meta table
  #do the standard ensembl subs
  #s/[A-Za-z]//g;
  #s/\.//g;
  #And then validate?
  #Just stick to number version for now.


  if($db->_get_schema_build($db->dnadb()) !~ /_[0-9]+_${assm_version}[a-z]*$/){
	my $warning = "WARNING: dnadb does not match assembly_version $assm_version. Using ensembldb.enembl.org to define the dnadb";
	$warning .= ' rather than the reg_config' if (defined $self->{'_reg_config'});

	#We need to account for reg_config DBs which may have custom info in
	#So try reg_config host first, then try ensembldb with warning
	#Could have a reg_config only flag for core dbs
	#Need to implement more params in set_dnadb_by_assembly_version
	$self->log($warning);

	$db->set_dnadb_by_assembly_version($assm_version);
  }
	
 
  $self->db($db);

  #Test connections
  $db->dbc->db_handle;
  $db->dnadb->dbc->db_handle;
  $db->dbc->disconnect_when_inactive(1);
  $db->dnadb->dbc->disconnect_when_inactive(1);
  
  ### Check analyses/feature_type/cell_type

  if($feature_analysis){
	my $fanal = $self->db->get_AnalysisAdaptor->fetch_by_logic_name($feature_analysis);
 	throw("The Feature Analysis $feature_analysis does not exist in the database") if(!$fanal);
	$self->feature_analysis($fanal);
  }

  if($ctype_name){
	my $ctype = $self->db->get_CellTypeAdaptor->fetch_by_name($ctype_name);
 	throw("The CellType $ctype_name does not exist in the database") if(!$ctype);
	$self->cell_type($ctype);
  }

  if ($ftype_name) {
    my $ftype = $self->db->get_FeatureTypeAdaptor->fetch_by_name($ftype_name);
	throw("The FeatureType $ftype_name does not exist in the database") if(!$ftype);
	$self->feature_type($ftype);
  }


  #Set config here instead?
  #So we can check all mandatory params
  #Set vendor specific attr dependent vars
  $self->set_config();


  $self->debug(2, "Importer class instance created.");
  $self->debug_hash(3, \$self);
    
  return ($self);
}


#init method kept separate from new due to differing madatory check and set up

=head2 init_array_import

  Example    : $self->init_import();
  Description: Initialises import by creating working directories 
               and by storing the Experiemnt
  Returntype : none
  Exceptions : warns and throws depending on recover and Experiment status 
  Caller     : general
  Status     : at risk - merge with register_array_design

=cut

sub init_array_import{

  my ($self) = shift;

  # we need to define which paramters we'll be storing
  #use the logic names of the analyses as the field headers

  #need to test for vendor here

  #Sanger, NIMBLEGEN(no design_id issue, could get from the ndf, but we want it in the DesignNotes.txt)
  #Then we can change the Array/Chip generation to soley use the DesignNotes.txt rather than SampleKey 
  #which is experiment specific
  #or eFG format.

  $self->create_output_dirs('caches', 'fastas');


}


=head2 init_experiment_import

  Example    : $self->init_import();
  Description: Initialises import by creating working directories 
               and by storing the Experiemnt
  Returntype : none
  Exceptions : warns and throws depending on recover and Experiment status 
  Caller     : general
  Status     : at risk - merge with register exeriment

=cut

sub init_experiment_import{
  my ($self) = shift;

  foreach my $tmp ("name", "group", "data_dir") {
    throw("Mandatory arg $tmp not been defined") if (! defined $self->{$tmp});
  }
  #Should we separate path on group here too, so we can have a dev/test group?
  
  #Set and create dirs
  $self->{'input_dir'} ||= $self->get_dir("data").'/input/'.$self->vendor().'/'.$self->name();
  throw('input_dir is not defined or does not exist ('.
		$self->get_dir('input').')') if(! -d $self->get_dir('input')); #Helper would fail first on log/debug files
  $self->create_output_dirs('raw', 'norm', 'caches', 'fastas');
  throw("No result_files defined.") if (! defined $self->result_files());

  #Log input files
  if (@{$self->result_files()}) {
    $self->log("Found result files arguments:\n\t".join("\n\t", @{$self->result_files()}));
  }

  #check for cell||feature and warn if no met file supplied?

  if($self->norm_method){
	my $norm_anal = $self->db->get_AnalysisAdaptor->fetch_by_logic_name($self->norm_method);

	#should we list the valid analyses?
	throw($self->norm_method.' is not a valid analysis') if ! $norm_anal;
	$self->norm_analysis($norm_anal);
  }else{
	$self->log('WARNING: No normalisation analysis specified');
  }
  
  warn "Need to check env vars here or in Parser or just after set_config?";
  #Need generic method for checking ENV vars in Helper
  #check for ENV vars?
  #R_LIBS
  #R_PATH if ! farm
  #R_FARM_PATH 

  $self->validate_group();#import experimental_group

  #Get experiment
  my $exp_adaptor = $self->db->get_ExperimentAdaptor();  
  my $exp = $exp_adaptor->fetch_by_name($self->name());	#, $self->group());
 
  #This is only used for the first test below.
  my $xml = $exp_adaptor->fetch_mage_xml_by_experiment_name($self->name());# if $self->{'write_xml'};

  #DO NOT CHANGE THIS LOGIC!
  #write mage if we specify or we don't have a the final xml or the template
  #recovery is turned on to stop exiting when previously stored chips are found from the 'write_mage' run.
  #This does mean that if you import without running the write_mage step
  #you could potentially be overwriting someone elses experiment info
  #No way of getting around this, need to make warning obvious, add to end of log!!!
  #We always want to write and update xml and ResultSets if we're running the 2nd stage of the import
  #Why would we ever want to skip the validate process?
  #Leave for now as this is working as we want it
  #But propose to remove skip functionality
  
  if( ! $self->{'no_mage'}){

	if($self->{'write_mage'} || !( -f $self->get_config('tab2mage_file') || $xml)){
	  $self->{'write_mage'} = 1;
	  $self->backup_file($self->get_config('tab2mage_file'));
	}
	#elsif($xml && (! $self->{'update_xml'})){#Changed this so we always update
	#elsif(! $self->{'update_xml'}){



	  #Here, we need to always update_xml
	  #If we are doing the 2nd stage
	  #Currently this is skipping as we haven't explicitly set it
	  #To remove this...
	  #what we need to do is check that we don't test for update_xml, 
	  # i.e. assuming that we're running the second stage of the import.
	  # Therefore we need a boolean to set whether it is the first stage..else update_xml implicit
	  # write mage is explicit flag
	  # Or if we have not tab2mage file?
	  # we can then override this explicitly with update_xml?
	  # WE're never likely edit the xml directly, so we always want to validate and update
	  # so write mage flag become update_experiment?  No this is no obvious behaviour
	  # We need to warn about removing the write_mage flag after we have updated it
	  # Otherwise we will never get to 2nd stage


	#No mage is still valid as we may want to jus import and experiment
	#Before receiving correct meta data
	#When we can then rerun the import with -write_mage to update the resultsets

	#  $self->{'recover'} = 1;
	#  $self->{'skip_validate'} = 1;
	#}
	elsif( -f $self->get_config('tab2mage_file')){#Run Tab2Mage

	  $self->backup_file($self->get_config('mage_xml_file'));
	  my $cmd = 'tab2mage.pl -e '.$self->get_config('tab2mage_file').' -k -t '.$self->get_dir('output').
		' -c -d '.$self->get_dir('results');
	  
	  $self->log('Reading tab2mage file');
	  my $t2m_exit_code = run_system_cmd($cmd, 1);#no exit flag due to non-zero exit codes	  
	  warn "tab2mage exit code is  $t2m_exit_code"; 
	  
	  if(! ($t2m_exit_code > -1) && ($t2m_exit_code <255)){
		throw("tab2mage failed.  Please check and correct:\t".$self->get_config('tab2mage_file')."\n...and try again");
	  }
	  
	  $self->{'recover'} = 1;
	}
  }
	
  #Recovery now set so deal with experiment
  if ($self->recovery() && ($exp)) {
    $self->log("Using previously stored Experiment:\t".$exp->name);
  } elsif ((! $self->recovery()) && $exp) {
    throw("Your experiment name is already registered in the database, please choose a different \"name\", this will require renaming you input directory, or specify -recover if you are working with a failed/partial import.");
    #can we skip this and store, and then check in register experiment if it is already stored then throw if not recovery
  } else {						# (recover && exp) || (recover  && ! exp) 
 
    
    $exp = Bio::EnsEMBL::Funcgen::Experiment->new(
												  -GROUP => $self->group(),
												  -NAME  => $self->name(),
												  -DATE  => $self->experiment_date(),
												  -PRIMARY_DESIGN_TYPE => $self->design_type(),
												  -DESCRIPTION => $self->description(),
												  -ADAPTOR => $self->db->get_ExperimentAdaptor(),
												 );
    
    ($exp) =  @{$exp_adaptor->store($exp)};
  }
  
  
  $self->experiment($exp);
  
  #remove and add specific report, this is catchig some Root stuff
  #$self->log("Initiated efg import with following parameters:\n".Data::Dumper::Dumper(\$self));
  
  return;
}

=heead init_tab2mage_export

  Example    : $self->init_tab2mage_export;
  Description: Writes the standard experiment section of the tab2mage file
  Returntype : FileHandle
  Exceptions : ???
  Caller     : general
  Status     : at risk

=cut

sub init_tab2mage_export{
  my $self = shift;

  $self->backup_file($self->get_config('tab2mage_file')) if(-f $self->get_config('tab2mage_file'));

  my $t2m_file = open_file($self->get_config('tab2mage_file'), '>');

  #reformat this
  my $exp_section = "experiment section\ndomain\t".(split/@/, $self->contact())[1]."\naccession\t\n".
	"quality_control\tbiological_replicate\nexperiment_design_type\tbinding_site_identification\n".
	  "name\t".$self->name()."\nrelease_date\t\nsubmission_date\t\nsubmitter\t???\n".
		"submitter_email\t???\ninvestigator\t???\ninvestigator_email\t???\norganization\t???\naddress\t".
		  "???\npublication_title\t\nauthors\t\njournal\t\nvolume\t\nissue\t\npages\t\nyear\t\npubmed_id\t\n";

  my $protocol_section = "Protocol section\naccession\tname\ttext\tparameters\n";

  foreach my $protocol(sort (keys %{$self->get_config('protocols')})){
	$protocol_section .= $self->get_config('protocols')->{$protocol}->{'accession'}.
	  "\t".$self->get_config('protocols')->{$protocol}->{'name'}.
		"\t".$self->get_config('protocols')->{$protocol}->{'text'}."\t";

	$protocol_section .= (defined $self->get_config('protocols')->{$protocol}->{'parameters'}) ?
	  $self->get_config('protocols')->{$protocol}->{'parameters'}."\t\n" : "\t\n";
  }

  #File[raw]	Array[accession]	Array[serial]	Protocol[grow]	Protocol[treatment]	Protocol[extraction]	Protocol[labeling]	Protocol[hybridization]	Protocol[scanning]	BioSource	Sample	Extract	LabeledExtract	Immunoprecipitate	Hybridization	BioSourceMaterial	SampleMaterial	ExtractMaterial	LabeledExtractMaterial	Dye	BioMaterialCharacteristics[Organism]	BioMaterialCharacteristics[BioSourceType]	BioMaterialCharacteristics[StrainOrLine]	BioMaterialCharacteristics[CellType]	BioMaterialCharacteristics[Sex]	FactorValue[StrainOrLine]	FactorValue[Immunoprecipitate]


  #Need to do this bit better?
  #have array of fields.  We can then populate a hash in the read method based on field names, then use the array to print in order

  my $hyb_header = "\nHybridization section\n".join("\t", @{$self->hybridisation_fields()});

  print $t2m_file $exp_section."\n".$protocol_section."\n".$hyb_header."\n";

  return $t2m_file;
}


#Move to MAGE package?

sub hybridisation_fields{
  my $self = shift;

  return ['File[raw]', 'Array[accession]', 'Array[serial]', 
		  (map 'Protocol['.$_.']', (sort (keys %{$self->get_config('protocols')}))),
		  'BioSource', 'Sample', 'Extract', 'LabeledExtract', 'Immunoprecipitate', 'Hybridization', 
		  'BioSourceMaterial', 'SampleMaterial', 'ExtractMaterial', 'LabeledExtractMaterial',
		  'Dye', 'BioMaterialCharacteristics[Organism]', 'BioMaterialCharacteristics[BioSourceType]',	
		  'BioMaterialCharacteristics[StrainOrLine]', 'BioMaterialCharacteristics[CellType]', 
		  'BioMaterialCharacteristics[Sex]', 'FactorValue[StrainOrLine]', 'FactorValue[Immunoprecipitate]'];
}


=head2 validate_group

  Example    : $self->validate_group();
  Description: Validates groups details
  Returntype : none
  Exceptions : throws if insufficient info defined to store new Group and is not already present
  Caller     : general
  Status     : Medium - check location and contact i.e. group name clash?

=cut

sub validate_group{
  my ($self) = shift;

  my $group_ref = $self->db->fetch_group_details($self->group());

  if (! $group_ref) {
    if ($self->location() && $self->contact()) {
      $self->db->import_group($self->group(), $self->location, $self->contact());
    } else {
      throw("Group ".$self->group()." does not exist, please specify a location and contact to register the group");
    }
  }
  
  return;
}

=head2 create_output_dirs

  Example    : $self->create_output_dirs();
  Description: Does what it says on the tin, creates dirs in 
               the root output dir foreach @dirnames, also set paths in self
  Arg [1]    : mandatory - list of dir names
  Returntype : none
  Exceptions : none
  Caller     : general
  Status     : Medium - add throw?

=cut

sub create_output_dirs{
  my ($self, @dirnames) = @_;
	

  #unshift @dirnames, "";#create base output dir
  #now done in control script due to log being generated first


  foreach my $name (@dirnames) {

	if($name eq 'caches'){
	  $self->{"${name}_dir"} = $ENV{'EFG_DATA'}."/${name}/".$self->db->dbc->dbname() if(! defined $self->{"${name}_dir"});
	}
	elsif($name eq 'fastas'){
	  $self->{"${name}_dir"} = $ENV{'EFG_DATA'}."/${name}/" if(! defined $self->{"${name}_dir"});
	}
	else{
	  $self->{"${name}_dir"} = $self->get_dir("output")."/${name}" if(! defined $self->{"${name}_dir"});
	}

	if(! (-d $self->get_dir($name) || (-l $self->get_dir($name)))){
	  $self->log("Creating directory:\t".$self->get_dir($name));
	  mkdir $self->get_dir($name) || throw('Failed to create directory:    '. $self->get_dir($name));
	  chmod 0744, $self->get_dir($name);
	}
  }
  
  return;
}



#move this to SolexaDefs/ExperimentalSetDefs?

=head2 experimental_set_name
  
  Example    : my $esset_name = $imp->experimental_set_name();
  Description: Getter/Setter for experimental_set_name
  Arg [1]    : optional - ExperimentalSet name
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub experimental_set_name{
  my $self = shift;

  $self->{'experimental_set_name'} = shift if @_;

  return $self->{'experimental_set_name'};
}



=head2 vendor
  
  Example    : $imp->vendor("NimbleGen");
  Description: Getter/Setter for array vendor
  Arg [1]    : optional - vendor name
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub vendor{
  my ($self) = shift;

  if(@_){
	$self->{'vendor'} = shift;
	$self->{'vendor'} = uc($self->{'vendor'});
  }

  return $self->{'vendor'};
}


=head2 feature_type
  
  Example    : $imp->feature_type($ftype);
  Description: Getter/Setter for Experiment FeatureType
  Arg [1]    : optional - Bio::EnsEMBL::Funcgen::FeatureType
  Returntype : Bio::EnsEMBL::Funcgen::FeatureType
  Exceptions : Throws if arg is not valid or stored
  Caller     : general
  Status     : at risk

=cut

sub feature_type{
  my ($self) = shift;

  if (@_) {
    my $ftype = shift;
    
    #do we need this as we're checking in new?
    if (! ($ftype->isa('Bio::EnsEMBL::Funcgen::FeatureType') && $ftype->dbID())) {
      throw("Must pass a valid stored Bio::EnsEMBL::Funcgen::FeatureType");
    }
  
    $self->{'feature_type'} = $ftype;
  }

  return $self->{'feature_type'};
}

=head2 feature_analysis
  
  Example    : $imp->feature_analysis($fanal);
  Description: Getter/Setter for Analysis used for creating the imported Features
  Arg [1]    : optional - Bio::EnsEMBL::Analysis
  Returntype : Bio::EnsEMBL::Analysis
  Exceptions : Throws if arg is not valid or stored
  Caller     : general
  Status     : at risk

=cut

sub feature_analysis{
  my ($self) = shift;

  if (@_) {
    my $fanal = shift;
    
    #do we need this as we're checking in new?
    if (! (ref ($fanal) && $fanal->isa('Bio::EnsEMBL::Analysis') && $fanal->dbID())) {
      throw("Must pass a valid stored Bio::EnsEMBL::Analysis");
    }
  
    $self->{'feature_analysis'} = $fanal;
  }

  return $self->{'feature_analysis'};
}

=head2 norm_analysis
  
  Example    : $imp->norm_analysis($anal);
  Description: Getter/Setter for the normalisation analysis
  Arg [1]    : optional - Bio::EnsEMBL::Analysis
  Returntype : Bio::EnsEMBL::Analysis
  Exceptions : Throws if arg is not valid or stored
  Caller     : general
  Status     : at risk

=cut

sub norm_analysis{
  my ($self) = shift;

  if (@_) {
    my $anal = shift;
    
    #do we need this as we're checking in new?
    if (! (ref($anal) && $anal->isa('Bio::EnsEMBL::Analysis') && $anal->dbID())) {
      throw("Must pass a valid stored Bio::EnsEMBL::Analysis");
    }
  
    $self->{'norm_analysis'} = $anal;
  }

  return $self->{'norm_analysis'};
}



=head2 cell_type
  
  Example    : $imp->cell_type($ctype);
  Description: Getter/Setter for Experiment CellType
  Arg [1]    : optional - Bio::EnsEMBL::Funcgen::CellType
  Returntype : Bio::EnsEMBL::Funcgen::CellType
  Exceptions : Throws if arg is not valid or stored
  Caller     : general
  Status     : at risk

=cut

sub cell_type{
  my ($self) = shift;

  if (@_) {
    my $ctype = shift;
    
    #do we need this as we're checking in new?
    if (! ($ctype->isa('Bio::EnsEMBL::Funcgen::CellType') && $ctype->dbID())) {
      throw("Must pass a valid stored Bio::EnsEMBL::Funcgen::CellType");
    }
  
    $self->{'cell_type'} = $ctype;
  }

  return $self->{'cell_type'};
}


=head2 ucsc_coords
  
  Example    : $start += 1 if $self->ucsc_coords;
  Description: Getter for UCSC coordinate usage flag
  Returntype : boolean
  Exceptions : none
  Caller     : general
  Status     : at risk

=cut

sub ucsc_coords{
  my $self = shift;
  return $self->{'ucsc_coords'};
}



=head2 array_file
  
  Example    : my $array_file = $imp->array_file();
  Description: Getter/Setter for sanger/design array file
  Arg [1]    : optional - path to adf or gff array definition/mapping file
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : at risk

=cut

sub array_file{
  my ($self) = shift;
  $self->{'array_file'} = shift if(@_);
  return $self->{'array_file'};
}

=head2 array_name
  
  Example    : my $array_name = $imp->array_name();
  Description: Getter/Setter for array name
  Arg [1]    : optional string - name of array
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : at risk

=cut

sub array_name{
  my ($self) = shift;
  $self->{'array_name'} = shift if(@_);
  return $self->{'array_name'};
}


=head2 array_set
  
  Example    : $imp->array_set(1);
  Description: Getter/Setter for array set flag
  Arg [1]    : optional boolean - treat all array chips as the same array
  Returntype : boolean
  Exceptions : none
  Caller     : general
  Status     : at risk

=cut

sub array_set{
  my ($self) = shift;
  $self->{'array_set'} = shift if(@_);
  return $self->{'array_set'};
}


=head2 add_Array

  Arg [1]    : Bio::EnsEMBL::Funcgen::Array
  Example    : $self->add_Array($array);
  Description: Setter for array elements
  Returntype : none
  Exceptions : throws if passed non Array or if more than one Array set
  Caller     : Importer
  Status     : At risk - Implement multiple arrays? Move to Experiment?

=cut

sub add_Array{
  my $self = shift;

  #do we need to check if stored?
  if (! $_[0]->isa('Bio::EnsEMBL::Funcgen::Array')) {
    throw("Must supply a Bio::EnsEMBL::Funcgen::Array");
  } elsif (@_) {
    push @{$self->{'arrays'}}, @_;
  }
   
  throw("Does not yet support multiple array imports") if(scalar (@{$self->{'arrays'}}) > 1);
  #need to alter read_probe data at the very least
  
  return;
}



=head2 arrays
  
  Example    : foreach my $array(@{$imp->arrays}){ ...do an array of things ...};
  Description: Getter for the arrays attribute
  Returntype : ARRAYREF
  Exceptions : none
  Caller     : general
  Status     : at risk

=cut

sub arrays{
  my $self = shift;

  if(! defined $self->{'arrays'}){
	$self->{'arrays'} = $self->db->get_ArrayAdaptor->fetch_all_by_Experiment($self->experiment());
  }

  return $self->{'arrays'};
}


=head2 data_dir
  
  Example    : $imp->data_dir($ENV{'EFG_DATA'});
  Description: Getter/Setter for root data directory
  Arg [1]    : optional - default $ENV{'EFG_DATA'}
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut


sub data_dir{
  my ($self) = shift;
  $self->{'data_dir'} = shift if(@_);
  return $self->{'date_dir'} || $ENV{'EFG_DATA'};
}

=head2 input_dir
  
  Example    : $imp->input_dir($dir);
  Description: Getter/Setter for input directory for an experiment
  Arg [1]    : optional - input directory path
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : at risk

=cut


sub input_dir{
  my ($self) = shift;
  $self->{'input_dir'} = shift if(@_);


  #not implemented, need to convert all get_dir calls to check if method exists or use VendorDefs
  warn "Not implmented input dir..need to cahnge all get_dir calls when we've implemented VendorDefs";

  return $self->{'input_dir'};
}

=head2 output_dir
  
  Example    : $imp->output_dir($dir);
  Description: Getter/Setter for input directory for an experiment
  Arg [1]    : optional - output directory path
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : deprecated

=cut


sub output_dir{
  my ($self) = shift;
  $self->{'output_dir'} = shift if(@_);

  throw("Deprecated, use get_dir('output') instead");

  #not implemented, need to convert all get_dir calls to check if method exists or use VendorDefs
  warn "Not implmented output dir..need to cahnge all get_dir calls when we've implemented VendorDefs";

  return $self->{'output_dir'};
}



=head2 location
  
  Example    : $imp->vendor("Hinxton");
  Description: Getter/Setter for group location
  Arg [1]    : optional - location
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut


sub location{
  my ($self) = shift;
  $self->{'location'} = shift if(@_);
  return $self->{'location'};
}


=head2 contact
  
  Example    : my $contact = $imp->contact();
  Description: Getter/Setter for the group contact
  Arg [1]    : optional - contact name/email/address
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub contact{
  my ($self) = shift;
  $self->{'contact'} = shift if(@_);
  return $self->{'contact'};
}

=head2 name
  
  Example    : $imp->name('Experiment1');
  Description: Getter/Setter for the experiment name
  Arg [1]    : optional - experiment name
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut


sub name{
  my ($self) = shift;	
  $self->{'name'} = shift if(@_);
  return $self->{'name'};
}

=head2 result_files
  
  Example    : $imp->result_files(\@files);
  Description: Getter/Setter for the result file paths
  Arg [1]    : Listref of file paths
  Returntype : Listref
  Exceptions : none
  Caller     : general
  Status     : At risk

=cut


sub result_files{
  my ($self) = shift;	
  $self->{'result_files'} = shift if(@_);
  return $self->{'result_files'};
}




=head2 verbose
  
  Example    : $imp->verbose(1);
  Description: Getter/Setter for the verbose flag
  Arg [1]    : optional - 0 or 1
  Returntype : int
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut


sub verbose{
  my ($self) = shift;	
  $self->{'verbose'} = shift if(@_);
  return $self->{'verbose'};
}



=head2 experiment_date
  
  Example    : $imp->experiment_date('2006-11-02');
  Description: Getter/Setter for the experiment date
  Arg [1]    : optional - date string in yyyy-mm-dd
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : At risk 

=cut



sub experiment_date{
  my ($self) = shift;	

  if (@_) {
    my $date = shift;

    if ($date !~ /[0-9]{4}-[0-9]{2}[0-9]{2}/o) {
      throw('Parameter -experiment_date needs to fe in the format: YYYY-MM-DD');
    }

    $self->{'experiment_date'} = $date;
  } elsif ($self->vendor() eq "nimblegen" && ! defined $self->{'experiment_date'}) {
    $self->{'experiment_date'} = &get_date("date", $self->get_config("chip_file")),
  }

  return $self->{'experiment_date'};
}



=head2 group
  
  Example    : my $exp_group = $imp->group();
  Description: Getter/Setter for the group name
  Arg [1]    : optional - group name
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub group{
  my ($self) = shift;	
  $self->{'group'} = shift if(@_);
  return $self->{'group'};
}

=head2 dbname
  
  Example    : my $exp_group = $imp->group();
  Description: Getter/Setter for the group name
  Arg [1]    : optional - group name
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : At risk - to be removed, us db->dbc->dbname

=cut

sub dbname{
  my ($self) = shift;	
  

  deprecate('Use $imp->db->dbname');

  return $self->db->dbc->dbname;

  #$self->{'dbname'} = shift if @_;


 # if(! defined  $self->{'dbname'}){
#	warn 'Need to guess dbname here?';
#  }
    
#  return $self->{'dbname'};
}

=head2 recovery
  
  Example    : if($imp->recovery()){ ....do recovery code...}
  Description: Getter/Setter for the recovery flag
  Arg [1]    : optional - 0 or 1
  Returntype : boolean
  Exceptions : none
  Caller     : self
  Status     : Medium - Most recovery now dynamic using status table

=cut

sub recovery{
  my $self = shift;
  $self->{'recover'} = shift if(@_);
  return $self->{'recover'};
}

=head2 description
  
  Example    : $imp->description("Human chrX H3 Lys 9 methlyation");
  Description: Getter/Setter for the experiment element
  Arg [1]    : optional - experiment description
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub description{
  my $self = shift;

  if (@_) {
	$self->{'description'} = shift;
  }

  return $self->{'description'};
}

=head2 format
  
  Example    : $imp->format("Tiled");
  Description: Getter/Setter for the array format
  Arg [1]    : optional - array format
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub format{
  my ($self) = shift;	
  $self->{'format'} = shift if(@_);
  return $self->{'format'};
}

=head2 experiment
  
  Example    : my $exp = $imp->experiment();
  Description: Getter/Setter for the Experiment element
  Arg [1]    : optional - Bio::EnsEMBL::Funcgen::Experiment
  Returntype : Bio::EnsEMBL::Funcgen::Experiment
  Exceptions : throws if arg is not an Experiment
  Caller     : general
  Status     : Stable

=cut

sub experiment{
  my ($self) = shift;	

  if (@_) {
	
    if (! $_[0]->isa('Bio::EnsEMBL::Funcgen::Experiment')) {
      throw("Must pass a Bio::EnsEMBL::Funcgen::Experiment object");
    }

    $self->{'experiment'} = shift;
  }

  return $self->{'experiment'};
}

=head2 db
  
  Example    : $imp->db($funcgen_db);
  Description: Getter/Setter for the db element
  Arg [1]    : optional - Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor
  Returntype : Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor
  Exceptions : throws if arg is not an DBAdaptor
  Caller     : general
  Status     : Stable

=cut

sub db{
  my $self = shift;

  if (defined $_[0] && $_[0]->isa("Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor")) {
    $self->{'db'} = shift;
  } elsif (defined $_[0]) {
    throw("Need to pass a valid Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor");
  }
  
  return $self->{'db'};
}

=head2 pass
  
  Example    : $imp->pass("password");
  Description: Getter/Setter for the db password
  Arg [1]    : optional - db password
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut


sub pass{
  my $self = shift;
  $self->{'pass'} = shift if(@_);
  return $self->{'pass'};
}

=head2 pass
  
  Example    : $imp->host("hoastname");
  Description: Getter/Setter for the db hostname
  Arg [1]    : optional - db hostname
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub host{
  my $self = shift;
  $self->{'host'} = shift if(@_);
  return $self->{'host'};
}

=head2 port
  
  Example    : $imp->port(3306);
  Description: Getter/Setter for the db port number
  Arg [1]    : optional - db port number
  Returntype : int
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub port{
  my $self = shift;
  $self->{'port'} = shift if(@_);
  return $self->{'port'};
}

=head2 user
  
  Example    : $imp->user("user_name");
  Description: Getter/Setter for the db user name
  Arg [1]    : optional - db user name
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub user{
  my $self = shift;
  $self->{'user'} = shift if(@_);
  return $self->{'user'};
}

=head2 dump_fasta
  
  Example    : if($self->dump_fasta()){...do fasta dump...}
  Description: Getter/Setter for the dump_fasta flag
  Arg [1]    : optional - 0 or 1
  Returntype : boolean
  Exceptions : none
  Caller     : self
  Status     : Stable

=cut


sub dump_fasta{
  my $self = shift;
  $self->{'_dump_fasta'} = shift if @_;
  return $self->{'_dump_fasta'};
}



=head2 species
  
  Example    : $imp->species("homo_sapiens");
  Description: Getter/Setter for species
  Arg [1]    : optional - species name(alias?)
  Returntype : string
  Exceptions : none ? throw if no alias found?
  Caller     : general
  Status     : Medium - may move reg alias look up to this method

=cut

sub species{
  my $self = shift;

  #should we do reg alias look up here?

  $self->{'species'} = shift if(@_);
	
  return $self->{'species'};
}

=head2 get_dir
  
  Example    : $imp->get_dir("import");
  Description: Retrieves full path for given directory
  Arg [1]    : mandatory - dir name
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : at risk - move to Helper?

=cut

sub get_dir{
  my ($self, $dirname) = @_;
  return $self->get_data("${dirname}_dir");
}

=head2 norm_method
  
  Example    : my $norm_method = $imp->norm_method()
  Description: Getter/Setter for normalisation method
  Arg [1]    : mandatory - method name
  Returntype : string
  Exceptions : none ? throw if no analysis with logic name
  Caller     : general
  Status     : At risk - restrict to logic_name and validate against DB, allow multiple

=cut


sub norm_method{
  my $self = shift;

  if (@_) {
    $self->{'norm_method'} = shift;
  } elsif (! defined  $self->{'norm_method'}) {
    $self->{'norm_method'}= $self->get_config('norm_method');
  }

  return $self->{'norm_method'};
}


=head2 get_config

  Arg [1]    : mandatory - name of the data element to retrieve from the config hash
  Example    : %dye_freqs = %{$imp->get_config('dye_freqs')};
  Description: returns data from the definitions hash
  Returntype : various
  Exceptions : none
  Caller     : Importer
  Status     : at risk - replace with direct calls in the inherited Defs class?

=cut


sub get_config{
  my ($self, $data_name) = @_;
  return $self->get_data('config', $data_name); #will this cause undefs?
}





=head2 register_experiment
  
  Example    : $imp->register_experiment()
  Description: General control method, performs all data import and normalisations
  Arg [1]    : optional - dnadb DBAdaptor
  Returntype : none
  Exceptions : throws if arg is not Bio::EnsEMBL::DBSQL::DBAdaptor
  Caller     : general
  Status     : Medium

=cut


sub register_experiment{
  my ($self) = shift;
  
  #Need to check for dnadb passed with adaptor to contructor
  if (@_) { 

    if ( ! $_[0]->isa("Bio::EnsEMBL::DBSQL::DBAdaptor")) {
      throw("You need to pass a valid dnadb adaptor to register the experiment");
    }
    $self->db->dnadb($_[0]);
  } elsif ( ! $self->db) {
    throw("You need to pass/set a DBAdaptor with a DNADB attached of the relevant data version");
  }
  
  #This could still be the default core db for the current version
  #warn here if not passed DB?
  #These should be vendor independent, only the read methods should need specific order?
  
  $self->init_experiment_import();
  #can we just have init here instead?


  
  if($self->{'write_mage'} || $self->{'no_mage'}){
	$self->read_data("array");

	if(! $self->{'no_mage'}){
	  $self->log("PLEASE CHECK AND EDIT AUTOGENERATED TAB2MAGE FILE:\t".$self->get_config('tab2mage_file'));
	  #we could make this print only if it was set by the user, not by the Importer
	  $self->log('REMEMBER TO REMOVE -write_mage FLAG BEFORE UPDATING');
	  exit;
	}
  }
  elsif(! $self->{'no_mage'}){#This should be a no_channel flag, set dependent on import mode(gff_chip, gff_chan)
	#Need to accomodate chip level imports in validate?
	$self->validate_mage() if (! $self->{'skip_validate'});
  }

  $self->read_data("probe");
  $self->read_data("results");  
  #Need to be able to run this separately, so we can normalise previously imported sets with different methods
  #should be able t do this without raw data files e.g. retrieve info from DB

  my $norm_method = $self->norm_method();
  
  if (defined $norm_method) {
	$self->R_norm($norm_method);
	#change this to $self->$norm_method
	#so we can have non-R_norm normalisation
  }
  
  
  return;
}


=head2 validate_mage
  
  Example    : $imp->validate_mage() if(! $imp->{'write_mage'};
  Description: Validates auto-generated and manually edited mage against
               Experiment information, aswell as checking replicate defitions.
               Updates mage_xml table and replicate information accordingly.
               Any other differences are logged or an error is thrown if the 
               difference is deemed critical.
  Returntype : none
  Exceptions : throws if ...?
  Caller     : Bio::EnsEMBL::Funcgen::Importer
  Status     : At risk

=cut


#THis is hardcoded for a channel level import at present
#Validation may fail on channels for Sanger?

sub validate_mage(){
  my ($self, $mage_xml, $update) = @_;

  $self->log("Validating mage file:\t".$self->get_config('mage_xml_file'));


  #Updating ResultSets:
  #Given that we might want to add a chip to an experiment we will also need to update the tab2MAGE
  #mage_xml and ResultSets accordingly.

  #This should happen if we specify update_xml
  #Should recovery also always force update?
  #Considering the two run modes, write tab2mage & validate and import
  #There is a subtle difference between recovery and update mage_xml
  #Do we always run in recovery mode for the validate&import step?
  #Yes we do, so can't guarantee the this means we want to update.
  #So we need to change update_xml to update to reflect the changed functionality on ResultSets
  
  #If we run an update without on then chips will be loaded but xml and ResultSets will not be altered :(
  #If we're running the 2nd stage we should always be updating the xml anyway!!!!
  #As there is no reason to rerun the validate & import step without it.(unless we're debugging maybe)
  #So why should we ever run without it?

  #To update ResultSets we validate as normal and then update where appropriate
  #What has precedence? Replicate name?
  #Update echip types as appropriate
  #What if this invalidates original rsets?
  #Then list sets not covered for removal by script?



  my (%echips, @log);
  my $rset_adaptor = $self->db->get_ResultSetAdaptor;
  my $chan_anal = $self->db->get_AnalysisAdaptor->fetch_by_logic_name('RawValue');

  #need to change this to default analysis
  #There we issues with setting VSN_GLOG as an env var
  #as this is tested for and the norm was skipped for some reason?
  my $chip_anal = $self->db->get_AnalysisAdaptor->fetch_by_logic_name('VSN_GLOG');

  #Try import sets like this first, so we know ther is new data
  my $chan_rset = $self->get_import_ResultSet($chan_anal, 'channel');
  my $rset =  $self->get_import_ResultSet($chip_anal, 'experimental_chip');


  #Else get them anyway and log
  if(! $rset){
	
	if($chan_rset){
	  $self->log('Identified partial Channel only import, updating MAGE-XML');
	}
	else{
	  ($chan_rset) = @{$rset_adaptor->fetch_all_by_name_Analysis($self->experiment->name.'_IMPORT', $chan_anal)};
	  #Don't need to test for >1 here as this has already been done in get_import_ResultSet
	  $self->log('All ExperimentalChips imported, updating MAGE-XML only');
	}

	($rset) = @{$rset_adaptor->fetch_all_by_name_Analysis($self->experiment->name.'_IMPORT', $chip_anal)};
  }


  #This will never happen now due to the change tab2mage rules in init_experiment
  #Remove?
  if(! $rset){
	throw('Cannot find ResultSet, are you trying to import a new experiment which already has a tab2mage file present?  Try removing the file, or specifying the -write_mage flag to parse_and_import.pl');
  }

  if(! -l $self->get_dir('output').'/MAGE-ML.dtd'){
	system('ln -s '.$ENV{'EFG_DATA'}.'/MAGE-ML.dtd '.$self->get_dir('output').'/MAGE-ML.dtd') == 0 || 
	  throw('Failed to link MAGE-ML.dtd');
  }
 

  $self->log('VALIDATING MAGE XML');
  my $reader = Bio::MAGE::XML::Reader->new();
  $mage_xml ||= $self->get_config('mage_xml_file');
  $self->{'mage'} = $reader->read($mage_xml);
  
  #this should only ever return 1 for an import
  foreach my $mage_exp(@{$self->{'mage'}->getExperiment_package->getExperiment_list()}){	

	if($mage_exp->getName() ne $self->name()){
	  $self->log('MAGE experiment name ('.$mage_exp->getName().') does not match import name ('.$self->name().')');
	}
	
	#add more experiment level validation here?

	foreach my $assay (@{$mage_exp->getBioAssays()}){

	  if($assay->isa('Bio::MAGE::BioAssay::PhysicalBioAssay')){#channel
		$self->log('Validating PhysicalBioAssay "'.$assay->getName()."'\n");#hyb name(this is the file name for measured assays

		my $bioassc = $assay->getBioAssayCreation();#This is a Hybridisation
		my $array = $bioassc->getArray();#this is an ArrayChip
		my $design_id = $array->getArrayDesign->getIdentifier();
		my $chip_uid = $array->getArrayIdentifier();
	
	
		foreach my $echip(@{$rset->get_ExperimentalChips()}){
		

		  if($echip->unique_id() eq $chip_uid){
			$self->log("Found ExperimentalChip:\t".$chip_uid);

			if(! exists $echips{$chip_uid}){
			  $echips{$chip_uid} = {(
									 total_biorep            => undef,
									 total_biotechrep        => undef,
									 experimental_biorep     => undef,
									 experimental_biotechrep => undef,
									 total_dye               => undef,
									 experimental_dye        => undef,
									 cell_type               => undef,
									 feature_type            => undef,
									)};
			}

			#Validate ArrayChip
			my ($achip) = @{$self->db->get_ArrayChipAdaptor->fetch_all_by_ExperimentalChips([$echip])};

			if($achip->design_id() ne $design_id){
			  push @log, "ArrayDesign Identifier (${design_id}) does not match ArrayChip design ID (".
				$achip->design_id().")\n\tSkipping channel and replicate validation";
			  #skip the channel/replicate validation here?	  
			} 
			else {			#validate channels and replicate names
					
			  foreach my $src_biomat (@{$bioassc->getSourceBioMaterialMeasurements()}) { #Channel materials(X1)?
				my $biomat = $src_biomat->getBioMaterial();	#LabelledExtract (IP/Control)
				#we could sub this passing $echip and biomat?
				#messy to pass regexs and populate correct echip hash attrs
				#also messy to populate log
				#keeping nested loop also prevents further obfuscation
				#do we need to do all the defined checks, or maybe just the first one?
				#Then we can skip all following warning?

				foreach my $treat (@{$biomat->getTreatments()}) {
				  #As there is effectively one more level of material extraction for the IP channel
				  #this loop will returns materials an iteration out of sync for each channel

				  foreach my $ssrc_biomat (@{$treat->getSourceBioMaterialMeasurements()}) {	#Channel measurement(x1)
					my $sbiomat = $ssrc_biomat->getBioMaterial();
					#This will either be techrep name for control of IP name for experimental channel
					#SOM0035_BR1_TR2 IP  #Immunoprecicpitate
					#SOM0035_BR1_TR2     #Extract
				
					if ($sbiomat->getName() =~ /BR[0-9]+_TR[0-9]+$/o) { #Total

					  if (! defined $echips{$chip_uid}{'total_biotechrep'}) {
						$echips{$chip_uid}{'total_biotechrep'} = $sbiomat->getName();
					  }
					  else{
						push @log, "Found two TOTAL Channels on same chip with biotechreps:\t".$sbiomat->getName().
						  " and ".$echips{$chip_uid}{'total_biotechrep'};
					  }
					}else{#Experimental

					  #get feature type from assay
					  my $fv_ref = $assay->getBioAssayFactorValues();
					  if(! defined $fv_ref){
						throw('No FactorValues found, you must populate the "Immunoprecipitate" field. Maybe you forgot to specify -feature_type?'); 
					  }

					  my ($feature_type);
					  
					  foreach my $fvalue(@{$fv_ref}){
						
						if($fvalue->getValue()->getCategory() eq 'Immunoprecipitate'){
						  $feature_type = $fvalue->getName();
						  $feature_type =~ s/anti\s*-\s*//;
						  $feature_type =~ s/\s*antibody\s*//;
						}
					  }
					  $echips{$chip_uid}{'feature_type'} = $feature_type;
					}

					foreach my $ttreat (@{$sbiomat->getTreatments()}) {
									  
					  foreach my $tsrc_biomat (@{$ttreat->getSourceBioMaterialMeasurements()}) {
						my $tbiomat = $tsrc_biomat->getBioMaterial();
						#SOM0035_BR1_TR2     #Extract (exp)
						#SOM0035_BR1              #Sample (total)
									   	
						if ($tbiomat->getName() =~ /BR[0-9]+_TR[0-9]+$/o) { #experimental
						  
						  if (! defined $echips{$chip_uid}{'experimental_biotechrep'}) {
							$echips{$chip_uid}{'experimental_biotechrep'} = $tbiomat->getName();
						  }
						  else{
							push @log, "Found two EXPERIMENTAL Channels on same chip with biotechreps:\t".$tbiomat->getName().
							  " and ".$echips{$chip_uid}{'experimental_biotechrep'};
						  }
						
						  my $dye = $biomat->getLabels()->[0]->getName();
							
						  foreach my $chan (@{$echip->get_Channels()}) {
							  
							if ($chan->type() eq 'EXPERIMENTAL') {
								
							  if (uc($dye) ne uc($chan->dye())) {
								push @log, "EXPERIMENTAL channel dye mismatch:\tMAGE = ".uc($dye).' vs DB '.uc($chan->dye);
							  } else {
								$echips{$chip_uid}{'experimental_dye'} = uc($dye);
							  }
							}
						  }
						} 
						else { #control
											  
						  if (! defined $echips{$chip_uid}{'total_biorep'}) {
							$echips{$chip_uid}{'total_biorep'} = $tbiomat->getName();
						  }
						  else{
							push @log, "Found two TOTAL Channels on same chip with biotechreps:\t".$tbiomat->getName().
							  " and ".$echips{$chip_uid}{'total_biorep'};
						  }
						  
						  my $dye = $biomat->getLabels()->[0]->getName();
						
						  foreach my $chan (@{$echip->get_Channels()}) {
						  
							if ($chan->type() eq 'TOTAL') {
							
							  if (uc($dye) ne uc($chan->dye())) {
								push @log, "TOTAL channel dye mismatch:\tMAGE = ".uc($dye).' vs DB '.uc($chan->dye);
							  } 
							  else {
								$echips{$chip_uid}{'total_dye'} = uc($dye);
							  }
							}
						  }
						}
						#could do one more iteration and get Source and FeatureType?
						#we should really extend this, and then update the EC cell_type and feature_types
						#these features might not be biotmats tho...need to check


						foreach my $ftreat (@{$tbiomat->getTreatments()}) {
									  
						  foreach my $fsrc_biomat (@{$ftreat->getSourceBioMaterialMeasurements()}) {
							my $fbiomat = $fsrc_biomat->getBioMaterial();
							#EXPERIMENTAL - biorep 
							#TOTAL        - source/cell type
							my $cell_type;

							if($fbiomat->getName() =~ /BR[0-9]+$/o){#EXPERIMETNAL
							
							  if(! defined $echips{$chip_uid}{'experimental_biorep'}){
								$echips{$chip_uid}{'experimental_biorep'} = $fbiomat->getName();
							  }
							  else{
								push @log, "Found two Experimental Channels on same chip with bioreps:\t".$fbiomat->getName().
								  " and ".$echips{$chip_uid}{'experimental_biorep'};
							  }


							  #last treatment/measurement/biomat level should go here
							  #as TOTAL channel does not have another level and will fail
							  foreach my $xtreat (@{$fbiomat->getTreatments()}) {
								
								foreach my $xsrc_biomat (@{$xtreat->getSourceBioMaterialMeasurements()}) {
								  my $xbiomat = $xsrc_biomat->getBioMaterial();
								  
								  foreach my $char(@{$xbiomat->getCharacteristics()}){
									$cell_type = $char->getValue() if($char->getCategory() eq 'CellType');
								  }
								}
							  }

							}else{#this should be BioSource
							  #which should have CellType as characteristic
							  #we could change tab2mage and have this as a factor value, 
							  #but don't want to start messing with "standard" format
						
							  foreach my $char(@{$fbiomat->getCharacteristics()}){
								$cell_type = $char->getValue() if($char->getCategory() eq 'CellType');
							  }
							}
						
							#can have cell_type validation here
							if(! defined $echips{$chip_uid}{'cell_type'}){
							  $echips{$chip_uid}{'cell_type'} = $cell_type;
							}
							elsif( $echips{$chip_uid}{'cell_type'} ne $cell_type){
							  push @log, "Found Channels on same chip (${chip_uid}) with different cell types:\t".
								$cell_type." and ".$echips{$chip_uid}{'cell_type'};
							}
						  }
						}
					  }
					}
				  }
				}
			  }
			}
		  }						#end of echip
		}						#end of foreach echip
	  }							#end of physbioassay	
	}							#end of foreach assay
  }								#end of foreach exp



  #we should fail here with log before we update the result sets

   #we need to build rep names
  #we're currently using sample labels, in the tab2mage file
  #altho' previous sets have been using exp name
  #these have been manually patched afterwards

  #More desirable to have exp name as rset name, but no way of doing BR validation
  #based on sample label, if we don't have it in the tab2mage
  #if we change it in the DB then we need to update the tab2mage

  #no way to do this when generating tab2mage as the user hasn't yet defined the reps
  #we could just make reps based on sample labels
  #then we just assume that alterations made by the user are correct
  #as we can no longer validate using sample labels
  #can still validate using cell/feature type

  #no longer need vendor specific validation as this will be done in tab2mage generation


  #We need to validate reps here
  #then update ec records as appropriate and then create rsets

  my (%bio_reps, %tech_reps);
  my $ct_adaptor = $self->db->get_CellTypeAdaptor();
  my $ft_adaptor = $self->db->get_FeatureTypeAdaptor();
 
#select rs.*, ec.*, c.* from result_set rs, chip_channel cc, channel c, experimental_chip ec where rs.result_set_id=cc.result_set_id and cc.table_name='experimental_chip' and cc.table_id=ec.experimental_chip_id and cc.table_id=c.experimental_chip_id order by name;

  foreach my $echip (@{$rset->get_ExperimentalChips()}) {

	my ($biorep, $biotechrep);

	if (! exists $echips{$echip->unique_id()}) {
	  push @log, "No MAGE entry found for ExperimentalChip:\t".$echip->unique_id();
	} 
	else {

	  foreach my $chan_type('total', 'experimental'){
		
		$biorep = $echips{$echip->unique_id()}{$chan_type.'_biorep'};
		$biotechrep = $echips{$echip->unique_id()}{$chan_type.'_biotechrep'};

		if (! defined $biotechrep) {
		  push @log, 'ExperimentalChip('.$echip->unique_id().') Extract field do not meet naming convention(SAMPLE_BRN_TRN)';
		}							#! defined biorep? will never occur at present
		elsif ($biotechrep !~ /\Q$biorep\E/) {
		  push @log, "Found Extract(techrep) vs Sample(biorep) naming mismatch\t${biotechrep}\tvs\t$biorep";
		} 
		
		if ( ! $echips{$echip->unique_id()}{$chan_type.'_dye'}) {
		  push @log, "No ".uc($chan_type)." channel found for ExperimentalChip:\t".$echip->unique_id();
		}

	  }

	  #Is this is really implicit in the test above
	  if($echips{$echip->unique_id()}{'experimental_biorep'} ne $echips{$echip->unique_id()}{'total_biorep'}){
		push @log, "Found biorep mismatch between channels of ExperimentalChip ".$echip->unique_id().":\n".
		  "\tEXPERIMENTAL\t".$echips{$echip->unique_id()}{'experimental_biorep'}."\tTOTAL\t".
			$echips{$echip->unique_id()}{'total_biorep'};
	  }

	  #Is this is really implicit in the test above
	  if($echips{$echip->unique_id()}{'experimental_biotechrep'} ne $echips{$echip->unique_id()}{'total_biotechrep'}){
		push @log, "Found biotechrep mismatch between channels of ExperimentalChip ".$echip->unique_id().":\n".
		  "\tEXPERIMENTAL\t".$echips{$echip->unique_id()}{'experimental_biotechrep'}."\tTOTAL\t".
			$echips{$echip->unique_id()}{'total_biotechrep'};
	  }

		   
	}


	#Now we need to validate ec has same feature/cell type as other ecs in this br
	#this does not handle import sets which ARE allowed to have same name but different types

	#warn "Processing ".$echip->unique_id()." $biorep $biotechrep";

	
	if(exists $bio_reps{$biorep}){


	  if(! defined $bio_reps{$biorep}{'cell_type'}){
		push @log, "Found undefined CellType for biorep $biorep";
	  }
	  elsif($bio_reps{$biorep}{'cell_type'}->name() ne  $echips{$echip->unique_id()}{'cell_type'}){
		push @log, "Found CellType mismatch between $biorep and ExperimentalChip ".$echip->unique_id();
	  }
	  
	  
	  if(! defined $bio_reps{$biorep}{'feature_type'}){
		push @log, "Found undefined FeatureType for biorep $biorep";
	  }
	  elsif($bio_reps{$biorep}{'feature_type'}->name() ne  $echips{$echip->unique_id()}{'feature_type'}){
		push @log, "Found FeatureType mismatch between $biorep and ExperimentalChip ".$echip->unique_id();
	  }
	  
	  #warn "$biorep exists with\t".$bio_reps{$biorep}{'cell_type'}->name().' '.$bio_reps{$biorep}{'feature_type'}->name();
	  
	  #We need to set the tech rep here too!
	  #Do we need to validate this also, as above.
	  #This would be overkill due to the inherant nature of the TR to BR relationship

	  if(! exists $tech_reps{$biotechrep}){
		 $tech_reps{$biotechrep}{'cell_type'} = $bio_reps{$biorep}{'cell_type'};
		 $tech_reps{$biotechrep}{'feature_type'} = $bio_reps{$biorep}{'feature_type'};
	  }


	}else{

	  #warn "Creating new BR $biorep and TR $biotechrep";

	  if(defined $echips{$echip->unique_id()}{'cell_type'}){

		my $cell_type = $ct_adaptor->fetch_by_name($echips{$echip->unique_id()}{'cell_type'});

		if(! defined $cell_type){
		  push @log, 'CellType '.$echips{$echip->unique_id()}{'cell_type'}.' does not exist in the database, please use the import_type.pl script';
		}else{
		  $bio_reps{$biorep}{'cell_type'} = $cell_type;
		  $tech_reps{$biotechrep}{'cell_type'} = $cell_type;
		#  warn "Setting ".$echip->unique_id()." $biorep $biotechrep ".$cell_type->name;
		}
	  }else{
		warn "No CellType specified for ExperimentalChip:\t".$echip->unique_id()."\n";
	  }


	  if(defined $echips{$echip->unique_id()}{'feature_type'}){
		my $feature_type = $ft_adaptor->fetch_by_name($echips{$echip->unique_id()}{'feature_type'});

		if(! defined $feature_type){
		  push @log, 'FeatureType '.$echips{$echip->unique_id()}{'feature_type'}.' does not exist in the database, please use the import_type.pl script';
		}
		else{
		  $bio_reps{$biorep}{'feature_type'} = $feature_type;
		  $tech_reps{$biotechrep}{'feature_type'} = $feature_type;

		  #warn "Setting ".$echip->unique_id()." $biorep $biotechrep ".$feature_type->name;
		}
	  }else{
		warn "No FeatureType specified for ExperimentalChip:\t".$echip->unique_id()."\n";
	  }
	}

	push @{$tech_reps{$biotechrep}{'echips'}}, $echip->unique_id();
	push @{$bio_reps{$biorep}{'echips'}}, $echip->unique_id();	
  }
  



  if (@log) {
	$self->log("MAGE VALIDATION REPORT\n::\t".join("\n::\t", @log));
	throw("MAGE VALIDATION FAILED\nPlease correct tab2mage file and try again:\t".$self->get_config('tab2mage_file'));
  } else {
	$self->log('MAGE VALDIATION SUCCEEDED');
  }


  #we also need to build the tech rep results sets(not displayable)
  #do we need to have result sets for each biorep too?
  #update ExperimentalChip replicate info
  my (%rsets);
  my %types = (
			   feature => {},
			   cell    => {},
			  );


 
  #This needs to update and split the import/top level sets so they are of same types
  #update ec type here as we have ec context
  #careful not to update multiple times, just once for each ec
 
  my $eca = $self->db->get_ExperimentalChipAdaptor();
  

  foreach my $echip (@{$rset->get_ExperimentalChips()}) {
	my ($cell_type, $feature_type);

	#Set biorep info and rset
	foreach my $biorep (keys %bio_reps){

	  foreach my $chip_uid(@{$bio_reps{$biorep}{'echips'}}){

		if($chip_uid eq $echip->unique_id()){
		  $echip->biological_replicate($biorep);
		  $cell_type = $bio_reps{$biorep}{'cell_type'};
		  $feature_type = $bio_reps{$biorep}{'feature_type'};

		  if(! defined $rsets{$biorep}){
			
			$rsets{$biorep} = Bio::EnsEMBL::Funcgen::ResultSet->new
			  (
			   -NAME         => $biorep,#this may not be unique, prepend with exp name? Force method to use Experiment_and_name?
			   -ANALYSIS     => $rset->analysis(),
			   -TABLE_NAME   => 'experimental_chip',
			   -FEATURE_TYPE => $feature_type,
			   -CELL_TYPE    => $cell_type,
			  );

			#record cell and feature types
			$types{'feature'}{$feature_type->name()} = $feature_type;
			$types{'cell'}{$cell_type->name()} = $cell_type;
			$self->log("Created BioRep ResultSet:\t".$rsets{$biorep}->log_label);
		  }
		  
		  $rsets{$biorep}->add_table_id($echip->dbID(), $rset->get_chip_channel_id($echip->dbID()));
		}
	  }
	}

	#reset echip types
	$echip->feature_type($feature_type);
	$echip->cell_type($cell_type);

	
	#set tech rep info and rset
	foreach my $techrep(keys %tech_reps){
	  
	  foreach my $chip_uid(@{$tech_reps{$techrep}{'echips'}}){
		
		if($chip_uid eq $echip->unique_id()){
		  $echip->technical_replicate($techrep);

		  if(! defined $rsets{$techrep}){
			$rsets{$techrep} = Bio::EnsEMBL::Funcgen::ResultSet->new
			  (
			   -NAME       => $techrep,#this may not be unique, prepend with exp name? Force method to use Experiment_and_name?
			   -ANALYSIS   => $rset->analysis(),
			   -TABLE_NAME => 'experimental_chip',
			   -FEATURE_TYPE => $tech_reps{$techrep}{'feature_type'},
			   -CELL_TYPE    => $tech_reps{$techrep}{'cell_type'},
			  );

			$self->log("Created TechRep ResultSet:\t".$rsets{$techrep}->log_label);
		  }
		  $rsets{$techrep}->add_table_id($echip->dbID(), $rset->get_chip_channel_id($echip->dbID()));
		}
	  }
	}

	$echip->adaptor->update_replicate_types($echip);#store rep info
  }


  ### Reset/Update/Clean import sets type fields
  my $sql;

  if(scalar keys %{$types{'feature'}} >1){
	$self->log('Resetting IMPORT FeatureType to NULL for multi-FeatureType Experiment');
	$sql = "UPDATE result_set set feature_type_id='NULL' where result_set_id in (".$rset->dbID().', '.$chan_rset->dbID().')';

  }else{
	my ($ftype) = values %{$types{'feature'}};

	if(! defined $rset->feature_type()){
	  $self->log('Updating IMPORT FeatureType to '.$ftype->name());
	  $sql = "UPDATE result_set set feature_type_id=".$ftype->dbID()." where result_set_id in (".$rset->dbID().', '.$chan_rset->dbID().')';
	}
	elsif($rset->feature_type->dbID ne $ftype->dbID()){
	  warn 'FeatureType mismatch between IMPORT sets('.$rset->feature_type->name().') vs meta sets('.$ftype->name.
	  "\nUpdating to IMPORT to match meta";
	  $self->log('WARNING: FeatureType mismatch.  Updating IMPORT FeatureType('.$rset->feature_type->name().') to match meta('.$ftype->name.')');
	  $sql = "UPDATE result_set set feature_type_id=".$ftype->dbID()." where result_set_id in (".$rset->dbID().', '.$chan_rset->dbID().')';

	}
  }

  $self->db->dbc->do($sql) if $sql;

  undef $sql;

  if(scalar keys %{$types{'cell'}} >1){
	$self->log('Resetting IMPORT CellType to NULL for multi-CellType Experiment');
	my $sql = "UPDATE result_set set cell_type_id='NULL' where result_set_id in (".$rset->dbID().', '.$chan_rset->dbID().')';
  }else{
	my ($ctype) = values %{$types{'cell'}};

	if(! defined $rset->cell_type()){
	  $self->log('Updating IMPORT CellType to '.$ctype->name());
	  $sql = "UPDATE result_set set cell_type_id=".$ctype->dbID()." where result_set_id in (".$rset->dbID().', '.$chan_rset->dbID().')';
	}
	elsif($rset->cell_type->dbID ne $ctype->dbID()){
	  warn 'CellType mismatch between IMPORT sets('.$rset->cell_type->name().') vs meta sets('.$ctype->name.
	  "\nUpdating to IMPORT to match meta";
	  $self->log('WARNING: FeatureType mismatch.  Updating IMPORT CellType('.$rset->cell_type->name().') to match meta('.$ctype->name.')');
	  $sql = "UPDATE result_set set cell_type_id=".$ctype->dbID()." where result_set_id in (".$rset->dbID().', '.$chan_rset->dbID().')';
	}
  }

  $self->db->dbc->do($sql) if $sql;

  ### Generate new top level sets here based on br type combos
  #we risk duplicating sets here if import set is set to one cell/featuretype
  #duplicate anyway, as import is really just for easy tracking of all chips during import

  my %toplevel_sets;
  my $toplevel_cnt = 1;
  #could tidy up toplevel_sets implmentation

  foreach my $new_rset(values %rsets){
	
	my $ftype_name = (defined $new_rset->{'feature_type'}) ? $new_rset->{'feature_type'}->name() : undef;
	my $ctype_name = (defined $new_rset->{'cell_type'}) ? $new_rset->{'cell_type'}->name() : undef;

	if(! exists $toplevel_sets{$ftype_name}){
	  $toplevel_sets{$ftype_name} = {};
	  $toplevel_sets{$ftype_name}{'feature_type'} = $new_rset->{'feature_type'};
	}



	if(! exists $toplevel_sets{$ftype_name}{$ctype_name}){
	  $toplevel_sets{$ftype_name}{$ctype_name}{'cell_type'} = $new_rset->{'cell_type'};
	  $toplevel_sets{$ftype_name}{$ctype_name}{'rsets'} = [$new_rset];
	}else{
	  push @{$toplevel_sets{$ftype_name}{$ctype_name}{'rsets'}}, $new_rset;
	}
  }



  #build toplevel sets for each feature/cell type combo using constituent rsets
  foreach my $ftype_name(keys %toplevel_sets){
	
	foreach my $ctype_name(keys %{$toplevel_sets{$ftype_name}}){
	  
	  next if $ctype_name eq 'feature_type';#skip feature type

	  #we need to give these a different key so we're not overwriting in the rset hash
	  $rsets{$self->experiment->name().'_'.$toplevel_cnt} = Bio::EnsEMBL::Funcgen::ResultSet->new
		(
		 -NAME       => $self->experiment->name(),
		 -ANALYSIS   => $rset->analysis(),
		 -TABLE_NAME => 'experimental_chip',
		 -FEATURE_TYPE => $toplevel_sets{$ftype_name}{'feature_type'},
		 -CELL_TYPE    => $toplevel_sets{$ftype_name}{$ctype_name}{'cell_type'},
		);

	  $self->log("Created toplevel ResultSet for:\t". $rsets{$self->experiment->name().'_'.$toplevel_cnt}->log_label);

	  #add consituent table ids
	  foreach my $new_rset(@{$toplevel_sets{$ftype_name}{$ctype_name}{'rsets'}}){
		
		foreach my $ec_id(@{$new_rset->table_ids()}){

		  #Only add it if it has not already been added
		  if(!  $rsets{$self->experiment->name().'_'.$toplevel_cnt}->get_chip_channel_id($ec_id)){
			$rsets{$self->experiment->name().'_'.$toplevel_cnt}->add_table_id($ec_id, $new_rset->get_chip_channel_id($ec_id));
		  }
		}
	  }
	  $toplevel_cnt++;
	}
  }

  #ResultSet update strategy
  #To avoid messyness in resolving result_set differences
  #Simply delete all that are not used as supporting sets
  #and load new ones, log old supporting rsets for manual
  #reassignment and rollback.
  #If we have clash between an old set and a new set, rename old
  #set and log
  #We might not always have the previous data files.
  #But we might want to maintain all the previous rsets and just add a new one
  #At present this would require acquiring the previous Tab2Mage file
  #and adding the new data to it.
  #We could do with a way to merge data already in the DB with new meta data to form a new Tab2Mage file
  #and validate that
  

  my @previous_rep_sets;
  my @supporting_rset_dsets;


  #Get non-import Sets
  map {push @previous_rep_sets, $_ if $_->name !~ /_IMPORT$/} 
	@{$rset_adaptor->fetch_all_by_Experiment_Analysis($self->experiment, $chip_anal)};
 

  #rollback_ResultSet if possible
  if(@previous_rep_sets){
	$self->log('Found previously stored ResultSets');

	foreach my $prev_rset(@previous_rep_sets){
	  #THis is pushing undef array?
	  #But surely this should do nothing?
	  my $rset_dset = $self->rollback_ResultSet($prev_rset);
	  push @supporting_rset_dsets, $rset_dset if @$rset_dset;
	}
  }

  #Note: If we remove chips from an experiment, they are only removed from the non-import sets
  #To fully remove them, you need to use the rollback_experiment.pl script with -chip_ids
  #can we log this in get_import_ResultSet?

  $self->log('Storing ResultSets');

  #Store new tech, biol and toplevel type rsets
  foreach my $new_rset(values %rsets){
	my $replace_txt;

	#Rename old set if we have a name/anal/type clash
	foreach my $prs(@supporting_rset_dsets){
	
	  my ($pset, $dset) = @$prs;

	  if($pset->log_label eq $new_rset->log_label){
		$self->log("Found update supporting ResultSet clash, renaming to:\tOLD_".$rset->log_label);

		#We risk overwriting any previously renamed result sets.
		#Should use datestamp
		my $sql = 'UPDATE result_set set name="OLD_'.$rset->name.'" where result_set_id='.$pset->dbID;
		$self->db->dbc->do($sql);

		if($dset->product_FeatureSet){
		  $self->log('Associated DataSet('.$dset->name.') has already been processed. It is not wise to replace a supporting set without first rolling back the FeatureSet, as there may be additional supporting data');
		  warn 'Associated DataSet('.$dset->name.') has already been processed. It is not wise to replace a supporting set without first rolling back the FeatureSet, as there may be additional supporting data';
		}
		
		$replace_txt = 'Proposed ResultSet(dbID) replacement for DataSet('.$dset->name."):\t".$pset->dbID.' > ';
	  }
	}


	$new_rset->add_status('DAS_DISPLAYABLE');
	my ($new_rset) = @{$rset_adaptor->store($new_rset)};

	if(defined $replace_txt){
	  $self->log($replace_txt.$new_rset->dbID);
	}
  }

  my $xml_file = open_file($self->get_config('mage_xml_file'));

  #slurp in changing separator to null so we get it all in one string.
  $self->experiment->mage_xml(do{ local ($/); <$xml_file>});
  close($xml_file);

  $self->experiment($self->db->get_ExperimentAdaptor->update_mage_xml_by_Experiment($self->experiment()));
  
  return;
}


=head2 store_set_probes_features

  Arg [1]    : mandatory - array chip id
  Arg [2]    : optional - Bio::EnsEMBL::Funcgen::ProbeSet
  Arg [3]    : mandatory - hashref of keys probe id, values are 
               hash of probe/features with values 
               Bio::EnsEMBL::Funcgen::Probe/Features for a given 
               probe set if defined.
  Example    : $self->store_set_probes_features($ac->dbID(), $ops, \%pfs);
  Description: Stores probe set, probes and probe features 
  Returntype : none
  Exceptions : none
  Caller     : self
  Status     : Medium

=cut

sub store_set_probes_features{
  my ($self, $ac_id, $pf_hash, $ops) = @_;
  
  ### Deal with ProbeSets
  if ($ops) {
    $ops->size(scalar(keys %$pf_hash));
    ($ops) = $self->db->get_ProbeSetAdaptor->store($ops);
  }

  #If we're going to validate fully, we need to check for probes in this probeset on this array chip
  #Update size if we have any new probes
  #Overkill? Only do on recover? Do not read if array chip is IMPORTED 
  #This does not make any attempt to validate probes/set vs previously stored data
   
  for my $probe_id (keys %$pf_hash) {
    
    #set probeset in probe and store
    #the process corresponding feature
    my $probe = $pf_hash->{$probe_id}->{'probe'};
    $probe->probeset($ops) if $ops;
    ($probe) = @{$self->db->get_ProbeAdaptor->store($probe)};

	#Can't use get_all_Arrays here as we can't guarantee this will only ever be the array we've generated
    #Might dynamically load array if non-present
    #This is allowing multiple dbIDs per probe???  Is this wrong?
    #$self->cache_probe_info($probe->get_probename(), $probe->dbID());###########Remove as we're now importing all then resolving

        
    foreach my $feature (@{$pf_hash->{$probe_id}->{'features'}}) {
      $feature->probe($probe);
      ($feature) = @{$self->db->get_ProbeFeatureAdaptor->store($feature)};
    }
  }

  undef $ops;					#Will this persist in the caller?
  undef %{$pf_hash};

  return;
}


=head2 cache_slice

  Arg [0]    : string - region_name e.g. X
  Arg [1]    : optional - coordinate system name e.g. supercontig, defaults to chromosome
  Example    : my $slice = $self->cache_slice(12);
  Description: Caches or retrieves from cache a given slice
  Returntype : Bio::EnsEMBL::Slice
  Exceptions : throws f no region name specified
  Caller     : self
  Status     : At risk

=cut

sub cache_slice{
  my ($self, $region_name, $cs_name) = @_;

  throw("Need to define a region_name to cache a slice from") if ! $region_name;

  $cs_name ||= 'chromosome';
  $self->{'slice_cache'} ||= {};
  $region_name =~ s/chr//;
  $region_name = "MT" if $region_name eq "M";
  
  #can we handle UN/random chromosomes here?
  
  
  if (! exists $self->{'slice_cache'}->{$region_name}) {
    $self->{'slice_cache'}->{$region_name} = $self->slice_adaptor->fetch_by_region($cs_name, $region_name);
    warn("-- Could not generate a slice for ${cs_name}:$region_name\n") if ! defined $self->{'slice_cache'}->{$region_name};
  }
  
  return $self->{'slice_cache'}->{$region_name};
}


=head2 cache_probe_info

  Arg [0]    : mandatory - probe name
  Arg [1]    : mandatory - probe dbID
  Arg [2]    : optioanl int - x coord of probe on array
  Arg [3]    : optional int - y coord of probe on array
  Example    : $self->cache_probe_info("Probe1", $probe->dbID());
               Or for result files which do not have X & Y, we need to cache 
               X & Y from the design files: $self->cache_probe_info('Probe2', $probe->dbID(), $x, $y);
  Description: Setter for probe cache values
  Returntype : none
  Exceptions : throws is cache conflict encountered
  Caller     : self
  Status     : At risk - merge with following?

=cut

sub cache_probe_info{
  my ($self, $pname, $pid, $x, $y) = @_;

  throw('Deprecated, too memory expensive, now resolving DB duplicates and using Tied File cache');
  throw("Must provide a probe name and id") if (! defined $pname || ! defined $pid);


  #do we need to loop through the file here?
  #if we make sure we're testing for a previous dbID before storing probes then we don't need to do this
  #we can catch the error when we get the probe id as we can check for >1 id for the same probe name
  #if (defined $self->{'_probe_cache'}->{$pname} && ($self->{'_probe_cache'}->{$pname}->[0] != $pid)) {
  #  throw("Found two differing dbIDs for $pname, need to sort out redundant probe entries");
  #}
  
  $self->{'_probe_cache'}->{$pname} = (defined $x && defined $y) ? [$pid, $x, $y] : [$pid];
  
  return;
}


=head2 get_probe_id_by_name_Array

  Arg [1]    : mandatory - probe name
  Example    : $pid = $self->get_probe_id_by_name($pname);
  Description: Getter for probe cache values
  Returntype : int
  Exceptions : none
  Caller     : self
  Status     : At risk - merge with previous, move to importer?

=cut

sub get_probe_id_by_name_Array{
  my ($self, $name, $array) = @_;
  
  #this is only ever called for fully imported ArrayChips, as will be deleted if recovering
  $self->resolve_probe_data() if(! exists $self->{'_probe_cache'}{$array->name()});
  
  #we want to cycle through the given cache starting from the last position or 0.
  #we don't want to have to test for the size of the cache each time as this will be quite expensive
  #so we should store sizes separately along with current position


  my ($pid, $line);
 
  #check current line
  if($line = $self->{'_probe_cache'}{$array->name()}{'current_line'}){
	if($line =~ /^\Q${name}\E\t/){
	  $pid = (split/\t/o, $line)[1];
	}
  }


  if(! $pid){
	while($line = $self->{'_probe_cache'}{$array->name()}{'handle'}->getline()){
	  
	  if($line =~ /^\Q${name}\E\t/){
		$pid = (split/\t/o, $line)[1];
		$self->{'_probe_cache'}{$array->name()}{'current_line'} = $line;
		last;
	  }
	}
  }

  #do not remove this
  if(! $pid){
	throw("Did not find probe name ($name) in cache, cache may need rebuilding, results may need sorting, or do you have an anomolaous probe?")
  }else{
	chomp $pid;
  }

  return $pid;
}

=head2 get_probe_cache_by_Array

  Arg[1]     : Bio::EnsEMBL::Funcgen::Array
  Arg[2]     : boolean - from db flag, only to be used by Importer->resolve_probe_data !
  Example    : $self->get_probe_cache_by_Array();
  Description: Gets the probe info cache which is an array tied to a file
  Returntype : Boolean - True if cache has been generated and set successfully
  Exceptions : none
  Caller     : general
  Status     : At risk

=cut

#from db flag should only be used by importer
#this is because there is no guarantee that it will be resolved unless
#called by resolve_probe_data
#which then renames the file and resets the handle
#can we clean this up and protect/hide this functionality?
#can we check the cache file name in the get methods and throw if it contains unresolved?
#make this private?

sub get_probe_cache_by_Array{
  my ($self, $array, $from_db) = @_;

  my $msg = "Getting probe cache for ".$array->name();
  $msg .= " from DB" if $from_db;
  $self->log($msg);#, 1);

  if(! ($array && $array->isa('Bio::EnsEMBL::Funcgen::Array') && $array->dbID())){
	throw('Must provide a valid stored Bio::EnsEMBL::Funcgen::Array object');
  }

  my $set = 0;
  my $cache_file = $self->get_dir('caches').'/'.$array->name().'.probe_cache';

  ### Generate and resolve fresh cache from DB
  if($from_db){

	$cache_file .= '.unresolved';#This will be renamed by the caller if it is resolved

	if(exists $self->{'_probe_cache'}{$array->name()}){
	  $self->log('Rebuilding probe_cache from DB for '.$array->name(), 1);


	  #untie @{$self->{'_probe_cache'}{$array->name()}{'entries'}};
	  #close($self->{'_probe_cache'}{$array->name()}{'handle'});#do we need to do this?
	  delete $self->{'_probe_cache'}{$array->name()};#implicitly closes
	  $self->log('Deleted old cache', 1);
	}else{
	  $self->log('Building probe_cache from DB for '.$array->name(), 1);
	}
	
	#Move this to ProbeAdaptor?
	#This is where we'd set the unique key for a vendor and resolves duplicates based on the key
	my $cmd = 'SELECT name, probe_id from probe WHERE array_chip_id IN ('.join(',', @{$array->get_array_chip_ids()}).') ORDER by name, probe_id';
	$cmd = 'mysql '.$self->db->connect_string()." -e \"$cmd\" >".$cache_file;
	run_system_cmd($cmd);
	
  }
 
  ### Set cache
  if(-f $cache_file){ 
	$self->log('MD5 check here?',1);
	$self->{'_probe_cache'}{$array->name()}{'current_line'} = undef;
	$self->{'_probe_cache'}{$array->name()}{'handle'} = open_file($cache_file);

	#can we do a select count instead? and do this instead of the MD5?
	#$cmd = "wc -l $cache_file";
	#my $size = `$cmd`;

	$set = 1;
  }
  else{
	warn 'Failed to get probe cache for array:'.$array->name();
  }
 
  return $set;
}


#should reorganise these emthods to split reading the array data, and the actual data
#currently:
#meta reads array and chip data
#probe reads probe_set, probes, which should definitely be in array, probe_feature? and results
#native data format may not map to these methods directly, so may need to call previous method if required data not defined


=head2 read_data
  
  Example    : $self->read_data("probe")
  Description: Calls each method in data_type array from config hash
  Arg [1]    : mandatory - data type
  Returntype : none
  Exceptions : none
  Caller     : self
  Status     : At risk

=cut

sub read_data{
  my($self, $data_type) = @_;
  map {my $method = "read_${_}_data"; $self->$method()} @{$self->get_config("${data_type}_data")};
  return;
}


=head2 design_type
  
  Example    : $self->design_type("binding_site_identification")
  Description: Getter/Setter for experimental design type
  Arg [1]    : optional - design type
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : At risk

=cut

sub design_type{
  my $self = shift;
  return $self->{'design_type'};
}


=head2 get_chr_seq_region_id
  
  Example    : $seq_region_id = $self->get_seq_region_id('X');
  Description: Calls each method in data_type array from config hash
  Arg [1]    : mandatory - chromosome name
  Arg [2]    : optional - start value
  Arg [3]    : optional - end value
  Returntype : int
  Exceptions : none
  Caller     : self
  Status     : At risk

=cut

#convinience wrapper method
#could we use the seq region cache instead?
#this seems like a lot of overhead for getting the id
sub get_chr_seq_region_id{
  my ($self, $chr, $start, $end) = @_;
  #what about strand info?

  #do we need the start and stop?

  #use start and stop to prevent problems with scaffodl assemblies, i.e. >1 seq_region_id
  #my $slice = $self->slice_adaptor->fetch_by_region("chromosome", $chr, $start, $end);
  #we could pass the slice back to the slice adaptor for this, to avoid dbid problems betwen DBs
  
  ###would need to implement other cs's here

  return $self->slice_adaptor->fetch_by_region("chromosome", $chr, $start, $end)->get_seq_region_id();
}

#convinience method

sub slice_adaptor{
  my $self = shift;

  if (! defined $self->{'slice_adaptor'}) {
	$self->{'slice_adaptor'} =  $self->db->get_SliceAdaptor();
  }

  return $self->{'slice_adaptor'};
}


=head2 vsn_norm
  
  Example    : $self->vsn_norm();
  Description: Convinience/Wrapper method for vsn R normalisation
  Returntype : none
  Exceptions : none
  Caller     : general
  Status     : At risk

=cut

#Have Norm class or contain methods in importer?
#Need to have analysis set up script for all standard analyses.

sub vsn_norm{
  my $self = shift;
  return $self->R_norm("VSN_GLOG");
}


=head2 farm
  
  Arg [1]    : Boolean
  Example    : $importer->farm(1);
  Description: Flag to turn farm submission on
  Returntype : Boolean
  Exceptions : Throws is argument not a boolean
  Caller     : general
  Status     : At risk

=cut


sub farm{
  my ($self, $farm) = @_;

  $self->{'farm'} ||= undef;#define farm

  if (defined $farm) {
    throw("Argument to farm must be a boolean 1 or 0")  if(! ($farm == 1 || $farm == 0));
    $self->{'farm'} = $farm;
  }

  return $self->{'farm'};

}


=head2 R_norm
  
  Example    : $self->R_norm(@logic_names);
  Description: Performs R normalisations for given logic names
  Returntype : none
  Exceptions : Throws if R exits with error code or if data not not valid for analysis
  Caller     : general
  Status     : At risk

=cut

sub R_norm{
  my ($self, @logic_names) = @_;
  #This currently normalises a single two colour chip at a time
  #rather than normalising across a set of chip
  #also does in sets of analyses
  #good for keeping data separate, but not efficient in terms of querying
  #convert to use one script which only queries for each echip once, then does each anal


  my $aa = $self->db->get_AnalysisAdaptor();
  my $rset_adaptor = $self->db->get_ResultSetAdaptor();
  my $ra_id = $aa->fetch_by_logic_name("RawValue")->dbID();
  my %r_config = (
				  "VSN_GLOG"      => {( libs         => ['vsn'],
										#norm_method => 'vsn',
									  )},
				  
				  "T.Biweight" => {(
									libs => ['affy'],
									#norm_method => 'tukey.biweight',
								   )},
				 );
  

  foreach my $logic_name (@logic_names) {
    #throw("Not yet implemented TukeyBiweight") if $logic_name eq "Tukey_Biweight";

	#this has already been chcecked and set as the norm_analysis
	#need to resolve this multi method approach
    my $norm_anal = $aa->fetch_by_logic_name($logic_name);


	
	#This only creates an RSet for the IMPORT set
	#So if we re-run with a different analysis
	#tab2mage will have already been validated
	#So RSet generation will be skipped
	#We need to recreate the each non-import RSet for this norm analysis
	
	#This also means the RSets are being created before the data has been imported
	#This avoids having to parse tab2mage each time but means we have an uncertain status of these Rsets

    my $rset = $self->get_import_ResultSet($norm_anal, 'experimental_chip');
	
	my @chips = ();
  
    if (! $rset) {
      $self->log("All ExperimentalChips already have status:\t${logic_name}");
    } else {					#Got data to normalise and import
      my @dbids;
      my $R_file = $self->get_dir("norm")."/${logic_name}.R";
      my $job_name = $self->experiment->name()."_${logic_name}";
      my $outfile = $self->get_dir("norm")."/result.${logic_name}.txt";
      my $errfile = $self->get_dir("norm")."/${logic_name}.out";

      my $cmdline = "$ENV{'R_PATH'} --no-save < $R_file >$errfile 2>&1";
      my $bsub = "bsub -K -J $job_name ".$ENV{'R_BSUB_OPTIONS'}.
		" -e $errfile $ENV{'R_FARM_PATH'} CMD BATCH $R_file"; #--no-save?

      my $r_cmd = (! $self->farm()) ? $cmdline : $bsub;

      $self->backup_file($outfile);	#Need to do this as we're appending in the loop
  
      #setup qurey
      #warn "Need to add host and port here";
      #Set up DB, defaults and libs for each logic name
      my $query = "options(scipen=20);library(RMySQL);library(Ringo);"; 
	  #scipen is to prevent probe_ids being converted to exponents
      #Ringo is for default QC

      #foreach my $ln(@logic_names){
	
      foreach my $lib (@{$r_config{$logic_name}{'libs'}}) {
		$query .= "library($lib);";
      }
      #}
      
      $query .= "con<-dbConnect(dbDriver(\"MySQL\"), host=\"".$self->db->dbc->host()."\", port=\"".$self->db->dbc->port()."\", dbname=\"".$self->db->dbc->dbname()."\", user=\"".$self->db->dbc->username()."\"";

	  #should use read only pass here as we are printing this to file
      $query .= ", pass=\"".$self->db->dbc->password."\")\n";
      
      
      #Build queries for each chip
      foreach my $echip (@{$self->experiment->get_ExperimentalChips()}) {
    

		#should implement logic name here?
		#can't as we need seperate ResultSet for each

  
		if ($echip->has_status($logic_name)) {
		  $self->log("ExperimentalChip ".$echip->unique_id()." already has status:\t$logic_name");
		} else {
	  
		  #warn "Need to roll back here if recovery, as norm import may fail halfway through";
		  
		  push @chips, $echip;
		  my $cc_id = $rset->get_chip_channel_id($echip->dbID());

		  #if ($self->recovery()){
		#	$self->log('Rolling back results for ExperimentalChip('.$echip->dbID().") $logic_name");
		#	$self->db->rollback_results($cc_id) if $self->recovery();							  
		#  }
		  
		  $self->log("Building $logic_name R cmd for ".$echip->unique_id());
		  @dbids = ();
	  
		  foreach my $chan (@{$echip->get_Channels()}) {

			if ($chan->type() eq "EXPERIMENTAL") {
			  push @dbids, $chan->dbID();
			} else {
			  unshift @dbids, $chan->dbID();
			}
		  }
	  
		  throw("vsn does not accomodate more than 2 channels") if (scalar(@dbids > 2) && $logic_name eq "VSN_GLOG");
	  
		  #should do some of this with maps?
		  #HARDCODED metric ID for raw data as one
	
		  #Need to get total and experimental here and set db_id accordingly
		  #can probably do this directly into one df
	  
		  $query .= "c1<-dbGetQuery(con, 'select r.probe_id as PROBE_ID, r.score as CONTROL_score, r.X, r.Y from result r, chip_channel c, result_set rs where c.table_name=\"channel\" and c.table_id=${dbids[0]} and c.result_set_id=rs.result_set_id and rs.analysis_id=${ra_id} and c.chip_channel_id=r.chip_channel_id')\n";

		  $query .= "c2<-dbGetQuery(con, 'select r.probe_id as PROBE_ID, r.score as EXPERIMENTAL_score, r.X, r.Y from result r, chip_channel c, result_set rs where c.table_name=\"channel\" and c.table_id=${dbids[1]} and c.result_set_id=rs.result_set_id and rs.analysis_id=${ra_id} and c.chip_channel_id=r.chip_channel_id')\n";
	  
		  #Can we define some of the basic structures here and reuse in the QC and each norm method?


		  #Is this going to eat up memory?
		  #can we strip out and separate the data from c1 and c2 into RGList and
		  #individual vector for probe_ids, then rm c1 and c2 to free up memory

		  #create RGList object
		  $query .= "R<-as.matrix(c1['CONTROL_score'])\nG<-as.matrix(c2['EXPERIMENTAL_score'])\n";
		  $query .= "genes<-cbind(c1['PROBE_ID'], c1['X'], c1['Y'])\n";
		  $query .= "testRG<-new('RGList', list(R=R, G=G, genes=genes))\n";
		 

		  #QC plots here before doing norm

		  #open pdf device
		  $query .= "pdf('".$self->get_dir('norm').'/'.$echip->unique_id."_QC.pdf', paper='a4', height = 15, width = 9)\n";
		  #set format
		  $query .= "par(mfrow = c(2,2), font.lab = 2)\n";

		  #Channel densisties
		  #These need limma or Ringo
		  $query .= "plotDensities(testRG)\n";
		  
		  #MvA Plot

		  $query .= 'meanLogA<-((log(testRG$R, base=exp(2)) + log(testRG$G, base=exp(2)))/2)'."\n";
		  $query .= 'logIntRatioM<-(log(testRG$R, base=exp(2)) - log(testRG$G, base=exp(2)))'."\n";
		  $query .= "yMin<-min(logIntRatioM)\n";
		  $query .= "yMax<-max(logIntRatioM)\n";



		  #Need to validate yMax here
		  #If is is Inf then we need to sort the vector and track back until we find the high real number
		  #count number of Infs and note on MvA plot
		  $query .= "infCount<-0\n";
		  $query .= "if( yMax == Inf){; sortedM<-sort(logIntRatioM); lengthM<-length(logIntRatioM); indexM<-lengthM\n"
			."while (yMax == Inf){; indexM<-(indexM-1); yMax<-sortedM[indexM];}; infCount<-(lengthM-indexM);}\n";

		  #
		  $query .= "if(infCount == 0){\n"; 
		  $query .= 'plot(meanLogA, logIntRatioM, xlab="A - Average Log Ratio",ylab="M - Log Ratio",pch=".",ylim=c(yMin,yMax), main="'.$echip->unique_id.'")'."\n";
		  $query .= "} else {\n";
		  $query .= 'plot(meanLogA, logIntRatioM, xlab="A - Average Log Ratio",ylab="M - Log Ratio",pch=".",ylim=c(yMin,yMax), main="'.$echip->unique_id.'", sub=paste(infCount, " Inf values not plotted"));'."}\n";


		  #$query .= 'plot(log(testRG$R*testRG$G, base=exp(2))/2, log(testRG$R/testRG$G, base=exp(2)),xlab="A",ylab="M",pch=".",ylim=c(-3,3), main="'.$echip->unique_id."\")\n";

		  #Plate plots
		  $query .= 'image(testRG, 1, channel = "green", mycols = c("black", "green4", "springgreen"))'."\n";
		  $query .= 'image(testRG, 1, channel = "red", mycols = c("black", "green4", "springgreen"))'."\n";

		  $query .= "dev.off()\n";
		  #Finished QC pdf printing



		  #The simple preprocess step of Ringo is actually vsn, so we can nest these in line


		  ### Build Analyses cmds ###
		  
		  if($logic_name eq 'T.Biweight'){

			#log2 ratios
			$query .= 'lr_df<-cbind((log(c2["EXPERIMENTAL_score"], base=exp(2)) - log(c1["CONTROL_score"], base=exp(2))))'."\n";
			
			#Adjust using tukey.biweight weighted average
			#inherits first col name
			$query .= 'norm_df<-(lr_df["EXPERIMENTAL_score"]-tukey.biweight(as.matrix(lr_df)))'."\n";
			$query .= 'formatted_df<-cbind(rep.int(0, length(c1["PROBE_ID"])), c1["PROBE_ID"], sprintf("%.3f", norm_df[,1]), rep.int('.$cc_id.', length(c1["PROBE_ID"])), c1["X"], c1["Y"])'."\n";
		  
		}
		elsif($logic_name eq 'VSN_GLOG'){
		  #could do this directly
		  $query .= "raw_df<-cbind(c1[\"CONTROL_score\"], c2[\"EXPERIMENTAL_score\"])\n";
		  #variance stabilise
		  $query .= "norm_df<-vsn(raw_df)\n";
    
	  
		  #do some more calcs here and print report?
		  #fold change exponentiate? See VSN docs
		  #should do someplot's of raw and glog and save here?
		  #set log func and params
		  #$query .= "par(mfrow = c(1, 2)); log.na = function(x) log(ifelse(x > 0, x, NA));";
		  #plot
		  #$query .= "plot(exprs(glog_df), main = \"vsn\", pch = \".\");". 
		  #  "plot(log.na(exprs(raw_df)), main = \"raw\", pch = \".\");"; 
		  #FAILS ON RAW PLOT!!
		  #par(mfrow = c(1, 2)) 
		  #> meanSdPlot(nkid, ranks = TRUE) 
		  #> meanSdPlot(nkid, ranks = FALSE) 
		
	
		  #Now create table structure with glog values(diffs)
		  #3 sig dec places on scores(doesn't work?!)
		  $query .= 'formatted_df<-cbind(rep.int(0, length(c1["PROBE_ID"])), c1["PROBE_ID"], sprintf("%.3f", (exprs(norm_df[,2]) - exprs(norm_df[,1]))), rep.int('.$cc_id.', length(c1["PROBE_ID"])), c1["X"], c1["Y"])'."\n";
		  
		}
		#load back into DB
		#c3results<-cbind(rep("", length(c3["probe_id"])), c3["probe_id"], c3["c3_score"], rep(1, length(c3["probe_id"])), rep(1, length(c3["probe_id"])))
		#may want to use safe.write here
		#dbWriteTable(con, "result", c3results, append=TRUE)
		#dbWriteTable returns true but does not load any data into table!!!
		
		$query .= "write.table(formatted_df, file=\"${outfile}\", sep=\"\\t\", col.names=FALSE, row.names=FALSE, quote=FALSE, append=TRUE)\n";
		
		#tidy up here?? 
		}
      }
  
      $query .= "q();";
  
      open(RFILE, ">$R_file") || throw("Cannot open $R_file for writing");
      print RFILE $query;
      close(RFILE);
 

	  $self->log("Submitting $logic_name job to farm:\t".localtime());
	  run_system_cmd($r_cmd);
	  $self->log("Finished $logic_name job:\t".localtime());
	  $self->log('See '.$self->get_dir('norm').' for ExperimentalChip QC files');

	  #Now load file and update status
	  #Import directly here to avoid having to reparse all results if we crash!!!!
	  $self->log("Importing:\t$outfile");
	  $self->db->load_table_data("result",  $outfile);
	  $self->log("Finishing importing:\t$outfile");
	  

	  foreach my $echip(@chips){
		$echip->adaptor->store_status($logic_name, $echip);
	  }

	  #Recreate all non-import RSets for analysis if not already present
	  #

	  my $rset_a = $self->db->get_ResultSetAdaptor();
	  my %seen_rsets;
	 
	  foreach my $anal_rset(@{$rset_a->fetch_all_by_Experiment($self->experiment)}){
		next if($anal_rset->name =~ /_IMPORT$/o);
		next if(exists $seen_rsets{$anal_rset->name});
		next if $anal_rset->analysis->logic_name eq $norm_anal->logic_name;
		$seen_rsets{$rset->name} = 1;
		$anal_rset->analysis($norm_anal);
		$anal_rset->{'dbID'} = undef;
		$anal_rset->{'adaptor'} = undef;
		
		#add the chip_channel_ids from the new anal IMPORT set
		foreach my $table_id(@{$anal_rset->table_ids}){
		  $anal_rset->{'table_id_hash'}{$table_id} = $rset->get_chip_channel_id($table_id);
		}

		$self->log('Adding new ResultSet '.$anal_rset->name.' with analysis '.$norm_anal->logic_name);
		$rset_a->store($anal_rset);
	  }



    }
  }

  return;
}

#can we sub this? args: table_name, logic_name
#also use result_set_name
#would also clean all data for result set if recovery
#return would be result_set

sub get_import_ResultSet{
  my ($self, $anal, $table_name) = @_;

  if (!($anal && $anal->isa("Bio::EnsEMBL::Analysis") && $anal->dbID())) {
    throw("Must provide a valid stored Bio::EnsEMBL::Analysis");
  }

  $self->log("Getting import $table_name ResultSet for analysis:\t".$anal->logic_name());

  my ($rset, @new_chip_channels);
  my $result_adaptor = $self->db->get_ResultSetAdaptor();
  my $logic_name = $anal->logic_name;
  my $status = ($logic_name eq "RawValue") ? "IMPORTED" : $logic_name;

  if(($logic_name) eq 'RawValue' && ($table_name eq 'experimental_chip')){
	throw("Cannot have an ExperimentalChip ResultSet with a RawValue analysis, either specify 'channel' or another analysis");
  }

  #Build IMPORT Set for $table_name
  foreach my $echip (@{$self->experiment->get_ExperimentalChips()}) {

    #clean chip import and generate rset
	
	if($table_name eq 'experimental_chip'){
	  
	  if ($echip->has_status($status)) { #this translates to each channel have the IMPORTED_RawValue status
		$self->log("ExperimentalChip(".$echip->unique_id().") already has status:\t".$status);
	  } 
	  else {
		$self->log("Found ExperimentalChip(".$echip->unique_id().") without status $status");

		push @new_chip_channels, $echip;
	  }

	}else{#channel
	  
	  foreach my $chan(@{$echip->get_Channels()}){

		if ($chan->has_status($status)) { #this translates to each channel have the IMPORTED_RawValue status
		  $self->log("Channel(".$echip->unique_id()."_".$self->get_config('dye_freqs')->{$chan->dye()}.") already has status:\t".$status);
		} 
		else {
		  $self->log("Found Channel(".$echip->unique_id()."_".$self->get_config('dye_freqs')->{$chan->dye()}.") without status $status");
		  push @new_chip_channels, $chan;
		}
	  }
	}
  
	if (( ! $rset) && @new_chip_channels) {
	  my(@tmp) = @{$result_adaptor->fetch_all_by_name_Analysis($self->name()."_IMPORT", $anal)};

	  if(scalar(@tmp) > 1){
		throw('Found more than one IMPORT ResultSet for '.$self->name().'_IMPORT with analysis '.$logic_name);
	  }

	  $rset = shift @tmp;


	  #do we need to throw here if not recovery?
	  #what if we want the import result set elsewhere during the first import?
	  
	  #if ($self->recovery()) {
	  
		#fetch by anal and experiment_id
	  #Need to change this to result_set.name!
	  #	warn("add chip set handling here");
	  
		#my @tmp = @{$result_adaptor->fetch_all_by_Experiment_Analysis($self->experiment(), $anal)};
	  #throw("Found more than one ResultSet for Experiment:\t".$self->experiment->name()."\tAnalysis:\t".$anal->logic_name().')' if (scalar(@tmp) >1);
	  #$rset = $tmp[0];
	  
	  #warn "fetching rset with ".$self->name()."_IMPORT ". $anal->logic_name;
	  
	  #$rset = $result_adaptor->fetch_by_name_Analysis($self->name()."_IMPORT", $anal);
	  warn("Warning: Could not find recovery ResultSet for analysis ".$logic_name) if ! $rset;
	  #}
	  
	  if (! $rset) {
		$self->log("Generating new ResultSet for analysis ".$logic_name);
	
		$rset = Bio::EnsEMBL::Funcgen::ResultSet->new
		  (
		   -analysis   => $anal,
		   -table_name => $table_name,
		   -name       => $self->name()."_IMPORT",
		   -feature_type => $self->feature_type(),
		   -cell_type    => $self->cell_type(),
		  );
	
		#These types should be set to NULL during the MAGE-XML validation if we have more than one type in an experiment
	
		($rset) = @{$result_adaptor->store($rset)};
	  }
	}
  }

  #do we need this here as we're rolling back in the read methods?
  #we only want to roll back those chips/channels which have not been registered
  
  if ($self->recovery()) {

	my $ec_adaptor = $self->db->get_ExperimentalChipAdaptor();
	
	foreach my $cc(@new_chip_channels){
	  
	  #only roll back if already part of import set
	  #Not previously registered if not 
	  if($rset->contains($cc) && $rset->get_chip_channel_id($cc->dbID())){
		
		if($table_name eq 'channel'){
		  my $chan_name = $ec_adaptor->fetch_by_dbID($cc->experimental_chip_id())->unique_id()."_".
			$self->get_config('dye_freqs')->{$cc->dye()};
		  $self->log("Rolling back results for $table_name:\t".$chan_name);
		  
		}else{
		  $self->log("Rolling back results for $table_name:\t".$cc->unique_id);
		}
		
		$self->rollback_results([$rset->get_chip_channel_id($cc->dbID())]);
	  }
	}
  }

  
  #check whether it is present in the ResultSet and add if not
  if ($rset) {
	#ids will already be present if not rset i.e. already imported

	foreach my $cc(@new_chip_channels){
	  $rset->add_table_id($cc->dbID()) if(! $rset->contains($cc));
	}
  }


  
  if ($rset) {
    $result_adaptor->store_chip_channels($rset);
  } else {
    $self->log("All ExperimentalChips have status:\t$status");
  }
  
  #this only returns a result set if there is new data to import
  return $rset;
}



=head2 resolve_probe_data

  Example    : $self->resolve_probe_data();
  Description: Resolves DB probe duplicates and builds local probe cache
  Returntype : none
  Exceptions : ????
  Caller     : general
  Status     : At risk

=cut

sub resolve_probe_data{
  my $self = shift;

  $self->log("Resolving probe data", 1);

  warn "Probe cache resolution needs to accomodate probesets too!";

  foreach my $array(@{$self->arrays()}){
	my $resolve = 0;
	
	if($self->get_probe_cache_by_Array($array)){#cache already generated

	  #check if we have any new unresolved array chips to add to the cache
	  foreach my $achip(@{$array->get_ArrayChips()}){
		
		if($achip->has_status('RESOLVED')){
		  $self->log("ArrayChip has RESOLVED status:\t".$achip->design_id());#, 1);
		  next;
		}else{
		  $self->log("Found un-RESOLVED ArrayChip:\t".$achip->design_id());
		  $resolve = 1;
		  last;
		}
	  }
	}else{#no cache file
	  $resolve = 1;
	  $self->log('No probe cache found for array '.$array->name());
	}

	if($resolve){
	  $self->log('Resolving array duplicates('.$array->name().') and rebuilding probe cache.', 1);
	  $self->get_probe_cache_by_Array($array, 1);#get from DB

	  #we need ot make sure we mark cache as unresolved, so we don't use it by mistake.
	  


	  my ($line, $name, $pid, @pids);
	  #my $index = 0;
	  my $tmp_name = '';
	  my $tmp_id = '';

	  #miss the header

	  while ($line = $self->{'_probe_cache'}{$array->name}{'handle'}->getline()){
		($name, $pid) = split/\t/o, $line;

		if($name eq $tmp_name){

		  if($pid != $tmp_id){
			push @pids, $pid;
			#should reset to pid here if we have x y data else undef
			#ignore this and force result to have x y
		  }

		  #can't do this naymore unless we figure out how to move the line pointer
		  #would still need to sed the file anyway, better to regen from DB?
		  #undef $self->{'_probe_cache'}{$array->name}{'entries'}->[$i];#delete true or to be resolved duplicate
		}
		elsif($name ne $tmp_name){#new probe
		  $self->tidy_duplicates(\@pids) if(scalar(@pids) > 1);
		  $tmp_name = $name;
		  $tmp_id = $pid;
		  @pids = ($pid);
		  #$index = $i + 1;
		}
	  }

	  $self->tidy_duplicates(\@pids) if(scalar(@pids) > 1);

	  #rename resovled cache and reset cache handle
	  my $cmd = 'mv '.$self->get_dir('caches').'/'.$array->name().'.probe_cache.unresolved '.
		$self->get_dir('caches').'/'.$array->name().'.probe_cache';

	  run_system_cmd($cmd);
	  $self->get_probe_cache_by_Array($array); #This sets the caches


	  #warn "Only generate MD5 here, as this is guranteed to be correct";
	  
	  foreach my $achip(@{$array->get_ArrayChips()}){
		
		if(! $achip->has_status('RESOLVED')){
		  $self->log("Updating ArrayChip to RESOLVED status:\t".$achip->design_id());
		  $achip->adaptor->store_status('RESOLVED', $achip);
		}
	  }
	  
	  $self->log('Finished building probe cache for '.$array->name(), 1);
	}
  }

  $self->log('Finished resolving probe data', 1);

  return;
}


sub tidy_duplicates{
  my ($self, $pids) = @_;

  my $pfa = $self->db->get_ProbeFeatureAdaptor();
  my ($feature, %features);
			
  foreach my $dup_id(@$pids){
			  
	foreach $feature(@{$pfa->fetch_all_by_Probe_id($dup_id)}){
	  #can we safely assume end will be same too?
	  push @{$features{$feature->seq_region_name().':'.$feature->start()}}, $feature;
	}
  }
			
  my (@reassign_ids, @delete_ids);
			
  foreach my $seq_start_key(keys %features){
	my $reassign_features = 1;
	
	foreach $feature(@{$features{$seq_start_key}}){
	  
	  if($feature->probe_id() == $pids->[0]){
		$reassign_features = 0;
	  }else{
		push @delete_ids, $feature->dbID();
	  }
	}
	
	#This assumes that we actually have at least one element to every seq_start_key array
	if($reassign_features){
	  my $new_fid = pop @delete_ids;
	  push @reassign_ids, $new_fid;
	}
  }
			
  #resolve features first so we don't get any orphaned features if we crash.
  $pfa->reassign_features_to_probe(\@reassign_ids, $pids->[0]) if @reassign_ids;
  $pfa->delete_features(\@delete_ids) if @delete_ids;

  return;
}



1;
