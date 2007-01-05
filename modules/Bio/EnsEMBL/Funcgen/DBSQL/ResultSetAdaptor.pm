#
# Ensembl module for Bio::EnsEMBL::DBSQL::Funcgen::ResultSetAdaptor
#
# You may distribute this module under the same terms as Perl itself

=head1 NAME

Bio::EnsEMBL::DBSQL::Funcgen::ResultSetAdaptor - A database adaptor for fetching and
storing ResultSet objects.  

=head1 SYNOPSIS

my $rset_adaptor = $db->get_ResultSetAdaptor();

my @rsets = @{$rset_adaptor->fetch_all_ResultSets_by_Experiment()};
my @displayable_rsets = @{$rset_adaptor->fetch_all_displayable_ResultSets()};

#Other methods?
#by FeatureType, CellType all with displayable flag?


=head1 DESCRIPTION

The ResultSetAdaptor is a database adaptor for storing and retrieving
ResultSet objects.

=head1 AUTHOR

This module was created by Nathan Johnson.

This module is part of the Ensembl project: http://www.ensembl.org/

=head1 CONTACT

Post comments or questions to the Ensembl development list: ensembl-dev@ebi.ac.uk

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Funcgen::DBSQL::ResultSetAdaptor;

use Bio::EnsEMBL::Utils::Exception qw( throw warning );
use Bio::EnsEMBL::Funcgen::ResultSet;

use vars qw(@ISA);
use strict;
use warnings;

@ISA = qw(Bio::EnsEMBL::Funcgen::DBSQL::BaseAdaptor);

#Generates ResultSet contains info about ResultSet content
#and actual results for channel or for chips in contig set?
#omit channel handling for now as we prolly won't ever display them
#but we might use it for running analyses and recording in result_set...change to result_group or result_analyses
#data_set!!  Then we can keep other tables names and retain ResultFeature
#and change result_feature to result_set, this makes focus of result set more accurate and ResultFeatures are lightweight result objects.
#do we need to accomodate different classes of data or multiple feature types in one set?  i.e. A combi experiment (Promot + Histone mod)?
#schema can handle this...API? ignore for now but be mindful. 
#This is subtley different to handling different experiments with different features in the same ResultSet.  
#Combi will have same sample.


#This needs one call to return all displayable sets, grouped by cell_line and ordered by FeatureType
#needs to be restricted to cell line, feature type, but these fields have to be disparate from result_feature 
#as this is only a simple linker table, and connections may not always be present
#so cell tpye and feature type constraints have to be performed on load, then can assume that associated features and results
# have same cell type/feature
#so we need to group by cell_type in sql and then order by feature_type_id in sql or rearrange in code?
#This will not know about chip sets, just that a feature set is linked to various result sets
#There fore we need to use the chip_set_id or link back to the experimental_chip chip_set_ids
#this would require a self join on experimental_chip




#Result_set_id is analagous to the chip_set key, altho' we may have NR instances of the same chip set with different analysis
#if we didn't know the sets previosuly, then we would have to alter the result_set_id retrospectively i.e. change the result_set_id.#All chips in exp to be in same set until we know sets, or all in separate set?
#Do not populate data_set until we know sets as this would cause hacky updating in data_set too.


#how are we going to accomodate a combi exp?  Promot + Histone mods?
#These would lose their exp set association, i.e. same exp & sample different exp method
#we're getting close to defining the regulon here, combined results features from the same exp
#presently want them displayed as a group but ordered appropriately
#was previously treating each feature as a separate result set


#for storing/making link we don't need the Slice context
#store should check all 
#so do we move the slice context to the object methods or make optional
#then object method can check for slice and throw or take a Slice as an optional argument
#this will enable generic set to be created to allow loading and linking of features to results
#we still need to know which feature arose from which chip!!!!  Not easy to do and may span two.
#Need to genericise this to the chip_set(or use result_set_id non unique)
#We need to disentangle setting the feature to chip/set problem from the displayable problem.
#change the way StatusAdaptor works to accomodate result_set_id:table_name:table_id, as this will define unique results
#

#can we extend this to creating skeleton result sets and loading raw results too?
#

#Result.pm should be lightweight by default to enable fast web display, do we need oligo_probe_id?


#how are we going to overcome unlinked but displayable sets?
#incomplete result_feature records will be hack to update/alter?
#could have attach_result to feature method?
#force association when loading features

=head2 fetch_all_by_Slice_ExperimentalChips

  Arg [1]    : Bio::EnsEMBL::Slice
  Arg [2...] : listref of Bio::EnsEMBL::Funcgen::ExperimentalChip objects
  Example    : my $slice = $sa->fetch_by_region('chromosome', '1');
               my $features = $ofa->fetch_by_Slice_arrayname($slice, $exp);
  Description: Retrieves a list of features on a given slice that are created
               by probes from the given ExperimentalChip.
  Returntype : Listref of Bio::EnsEMBL::Funcgen::OligoFeature objects
  Exceptions : Throws if no array name is provided
  Caller     : 
  Status     : At Risk

=cut

#This is no longer appropriate
#should this take >1 EC? What if we can't fit a all mappings onto one chip
#Would possibly miss some from the slice


sub fetch_all_by_Slice_ExperimentalChips {
	my ($self, $slice, $exp_chips) = @_;

	my (%nr);


	foreach my $ec(@$exp_chips){
				
	  throw("Need pass listref of valid Bio::EnsEMBL::Funcgen::ExperimentalChip objects") 
	    if ! $ec->isa("Bio::EnsEMBL::Funcgen::ExperimentalChip");
	  
	  $nr{$ec->array_chip_id()} = 1;
	}

	#get array_chip_ids from all ExperimentalChips and do a
	#where op.array_chip_id IN (".(join ", ", @ac_ids)

	#my @echips = @{$self->db->get_ExperimentalChipAdaptor->fetch_all_by_experiment_dbID($exp->dbID())};
	#map $nr{$_->array_chip_id()} = 1, @echips;
	my $constraint = " op.array_chip_id IN (".join(", ", keys %nr).") AND op.oligo_probe_id = of.oligo_probe_id ";


	
	return $self->SUPER::fetch_all_by_Slice_constraint($slice, $constraint);
}




=head2 fetch_all_by_Slice_type

  Arg [1]    : Bio::EnsEMBL::Slice
  Arg [2]    : string - type of array (e.g. AFFY or OLIGO)
  Arg [3]    : (optional) string - logic name
  Example    : my $slice = $sa->fetch_by_region('chromosome', '1');
               my $features = $ofa->fetch_by_Slice_type($slice, 'OLIGO');
  Description: Retrieves a list of features on a given slice that are created
               by probes from the specified type of array.
  Returntype : Listref of Bio::EnsEMBL::OligoFeature objects
  Exceptions : Throws if no array type is provided
  Caller     : General
  Status     : At Risk

=cut

sub fetch_all_by_Slice_type {
	my ($self, $slice, $type, $logic_name) = @_;

	throw("Not implemented yet\n");
	
	throw('Need type as parameter') if !$type;
	
	my $constraint = qq( a.type = '$type' );
	
	return $self->SUPER::fetch_all_by_Slice_constraint($slice, $constraint, $logic_name);
}
 
=head2 _tables

  Args       : None
  Example    : None
  Description: PROTECTED implementation of superclass abstract method.
               Returns the names and aliases of the tables to use for queries.
  Returntype : List of listrefs of strings
  Exceptions : None
  Caller     : Internal
  Status     : At Risk

=cut

sub _tables {
  my $self = shift;
	
  return (
	  [ 'result_set',    'rs' ]
	 );
}

=head2 _columns

  Args       : None
  Example    : None
  Description: PROTECTED implementation of superclass abstract method.
               Returns a list of columns to use for queries.
  Returntype : List of strings
  Exceptions : None
  Caller     : Internal
  Status     : At Risk

=cut

sub _columns {
	my $self = shift;

	return qw(
		  rs.result_set_id  rs.analysis_id
		  rs.table_id       rs.table_id
		 );

	
}

=head2 _default_where_clause

  Args       : None
  Example    : None
  Description: PROTECTED implementation of superclass abstract method.
               Returns an additional table joining constraint to use for
			   queries.
  Returntype : List of strings
  Exceptions : None
  Caller     : Internal
  Status     : At Risk

=cut
#sub _default_where_clause {
#	my $self = shift;
	
#	return 'of.oligo_probe_id = op.oligo_probe_id AND op.array_chip_id = ac.array_chip_id';
#}

=head2 _final_clause

  Args       : None
  Example    : None
  Description: PROTECTED implementation of superclass abstract method.
               Returns an ORDER BY clause. Sorting by oligo_feature_id would be
			   enough to eliminate duplicates, but sorting by location might
			   make fetching features on a slice faster.
  Returntype : String
  Exceptions : None
  Caller     : generic_fetch
  Status     : At Risk

=cut


#do we need this?

#sub _final_clause {
#	return ' ORDER BY rs.result_set_id,';
#}

=head2 _objs_from_sth

  Arg [1]    : DBI statement handle object
  Example    : None
  Description: PROTECTED implementation of superclass abstract method.
               Creates Array objects from an executed DBI statement
			   handle.
  Returntype : Listref of Bio::EnsEMBL::Funcgen::Experiment objects
  Exceptions : None
  Caller     : Internal
  Status     : At Risk

=cut

sub _objs_from_sth {
  my ($self, $sth) = @_;
  
  my (@rsets, $rset, $dbid, $anal_id, $table_id, $table_name);
  
  $sth->bind_columns(\$dbid, \$anal_id, \$table_id, \$table_name);
  
  while ( $sth->fetch() ) {


 
    if(! $rset || ($rset->dbID() != $dbid)){

      push @rsets, $rset if $rset;

      $rset = $self->_new_fast( {
				 'dbid'         => $dbid,
				 'analysis_id'  => $anal_id,
				 'table_name'   => $table_name,
				 #'table_id'     => $table_id,
				 #do all the rest dynamically?
				} );

      $rset->add_table_id($table_id);

    }else{
      #This assumes logical association, confer in store method?
      $rset->add_table_id($table_id);
    }
  }

  return \@rsets;
}


=head2 _new_fast

  Args       : Hashref to be passed to ResultSet->new_fast()
  Example    : None
  Description: Construct an OligoFeature object using quick and dirty new_fast.
  Returntype : Bio::EnsEMBL::Funcgen::OligoFeature
  Exceptions : None
  Caller     : _objs_from_sth
  Status     : Medium Risk

=cut

sub _new_fast {
  my $self = shift;
	
  my $hash_ref = shift;
  return Bio::EnsEMBL::Funcgen::ResultSet->new_fast($hash_ref);
}

=head2 store

  Args       : List of Bio::EnsEMBL::Funcgen::ResultSet objects
  Example    : $rsa->store(@rsets);
  Description: Stores or updates previously stored ResultSet objects in the database. 
  Returntype : None
  Exceptions : Throws if a List of ResultSet objects is not provided or if
               an analysis is not attached to any of the objects
  Caller     : General
  Status     : At Risk

=cut

sub store{
  my ($self, @rsets) = @_;

  throw("Must provide a list of ResultSet objects") if(scalar(@rsets == 0));


  my (%analysis_hash);
  

 
  my $sth = $self->prepare("
		INSERT INTO result_set (
			analysis_id,  table_id, table_name
		) VALUES (?, ?, ?)
	");
  
  my $db = $self->db();
  my $analysis_adaptor = $db->get_AnalysisAdaptor();

 FEATURE: foreach my $rset (@rsets) {
    
    if( ! ref $rset || ! $rset->isa('Bio::EnsEMBL::Funcgen::ResultSet') ) {
      throw('Must be an ResultSet object to store');
    }
    


    if ( $rset->is_stored($db) ) {
      throw('ResultSet [' . $rset->dbID() . '] is already stored in the database\nResultSetAdaptor does not yet accomodate updating ResultSets');
      #would need to retrive stored result set and update table_ids
    }
    
    if ( ! defined $rset->analysis() ) {
      throw('An analysis must be attached to the ResultSet objects to be stored.');
    }

    # Store the analysis if it has not been stored yet
    if ( ! $rset->analysis->is_stored($db) ) {
      warn("Will this not keep storing the same analysis if we keep passing the same unstored analysis?");
      $analysis_adaptor->store( $rset->analysis() );
    }


   
    foreach my $table_id(@{$rset->table_ids()}){
	
      $sth->bind_param(1, $rset->analysis->dbID(),        SQL_INTEGER);
      $sth->bind_param(2, $table_id,                      SQL_INTEGER);
      $sth->bind_param(3, $rset->table_name(),            SQL_VARCHAR);
          
      $sth->execute();
    }

    $rset->dbID( $sth->{'mysql_insertid'} );
    $rset->adaptor($self);

  }

  return \@rsets
}

=head2 list_dbIDs

  Args       : None
  Example    : my @rsets_ids = @{$rsa->list_dbIDs()};
  Description: Gets an array of internal IDs for all OligoFeature objects in
               the current database.
  Returntype : List of ints
  Exceptions : None
  Caller     : ?
  Status     : Medium Risk

=cut

sub list_dbIDs {
	my $self = shift;
	
	return $self->_list_dbIDs('result_set');
}

# All the results methods may be moved to a ResultAdaptor

=head2 fetch_results_by_channel_analysis

  Arg [1]    : int - OligoProbe dbID
  Arg [2]    : int - Channel dbID
  Arg [1]    : string - Logic name of analysis
  Example    : my @results = @{$ofa->fetch_results_by_channel_analysis($op_id, $channel_id, 'RAW_VALUE')};
  Description: Gets all analysis results for probe on given channel
  Returntype : ARRAYREF
  Exceptions : warns if analysis is not valid in Channel context
  Caller     : OligoFeature
  Status     : At Risk - rename fetch_results_by_probe_channel_analysis

=cut



sub fetch_results_by_channel_analysis{
	my ($self, $probe_id, $channel_id, $logic_name) = @_;
	
	#Will this always be RAW_VALUE?

	my %channel_metrics = (
						   RawValue => 1,
						  );


	if(! defined $probe_id || ! defined $channel_id) {
		throw("Need to define a valid probe and channel dbID");
	}
		

	my $analysis_clause = "";

	if($logic_name){
		if(exists $channel_metrics{$logic_name}){
			$analysis_clause = "AND a.logic_name = \"$logic_name\"";
		}else{
			warn("$logic_name is not a channel specific metric\nNo results returned\n");
			return;
		}
	}

	my $query = "SELECT r.score, a.logic_name from result r, analysis a where r.oligo_probe_id =\"$probe_id\" AND r.table_name=\"channel\" AND r.table_id=\"$channel_id\" AND r.analysis_id = a.analysis_id $analysis_clause";
	
	return $self->dbc->db_handle->selectall_arrayref($query);
}

=head2 fetch_results_by_probe_experimental_chips_analysis

  Arg [1]    : int - OligoProbe dbID
  Arg [2]    : ARRAYREF - ExperimentalChip dbIDs
  Arg [1]    : string - Logic name of analysis
  Example    : my @results = @{$ofa->fetch_results_by_channel_analysis($op_id, \@chip_ids, 'VSN_GLOG')};
  Description: Gets all analysis results for probe within a set of ExperimentalChips
  Returntype : ARRAYREF
  Exceptions : warns if analysis is not valid in ExperimentalChip context
  Caller     : OligoFeature
  Status     : At Risk 

=cut

sub fetch_results_by_probe_experimental_chips_analysis{
	my ($self, $probe_id, $chip_ids, $logic_name) = @_;
	
	my $table_ids;
	my $table_name = "experimental_chip";

	my %chip_metrics = (
			    VSN_GLOG => 1,
			   );

	#else no logic name or not a chip metric, then return channel and metric=?


	if(! defined $probe_id || ! @$chip_ids) {
		throw("Need to define a valid probe and pass a listref of experimental chip dbIDs");
	}
		

	my $analysis_clause = ($logic_name) ? "AND a.logic_name = \"$logic_name\"" : "";

	if(! exists $chip_metrics{$logic_name}){
	  $table_name = "channel";
	  warn("Logic name($logic_name) is not a chip specific metric\nNo results returned\n");
	  
	  #build table ids from exp chip channel ids
	  #need to then sort out which channel is which in caller.

	  #need to enable raw data retrieval!!
	  return;
	}else{
	  $table_ids = join(", ", @$chip_ids);
	}


	my $query = "SELECT r.score, r.table_id, a.logic_name from result r, analysis a where r.oligo_probe_id =\"$probe_id\" AND r.table_name=\"${table_name}\" AND r.table_id IN (${table_ids}) AND r.analysis_id = a.analysis_id $analysis_clause";
	
	return $self->dbc->db_handle->selectall_arrayref($query);
}


#This checks each locus to ensure identically mapped probes only return a median/mean
#can we just return array triplets?, start, end, score?

sub fetch_result_features_by_Slice_Analysis_ExperimentalChips{
  my ($self, $slice, $analysis, $exp_chips) = @_;

  #warn("Put in ResultAdaptor");

  my (@ofs, @results, $result);

  
  foreach my $of(@{$self->fetch_all_by_Slice_ExperimentalChips($slice, $exp_chips)}){
    
    if((! @ofs) || ($of->start == $ofs[0]->start() && $of->end == $ofs[0]->end())){
      push @ofs, $of;
    }else{#Found new location, deal with previous
      push @results, [$ofs[0]->start(), $ofs[0]->end(), $self->_get_best_result(\@ofs, $analysis, $exp_chips)];
      @ofs = ($of);
    }
  }

  push @results, [$ofs[0]->start(), $ofs[0]->end(), $self->_get_best_result(\@ofs, $analysis, $exp_chips)];

  return \@results;

}

sub _get_best_result{
  my ($self, $ofs, $analysis, $exp_chips) = @_;

  my ($result, $mpos);

  if(scalar(@$ofs) == 2){#mean
    $result = ($ofs->[0]->get_result_by_Analysis_ExperimentalChips($analysis, $exp_chips) + 
	       $ofs->[1]->get_result_by_Analysis_ExperimentalChips($analysis, $exp_chips))/2;
    
  }
  elsif(scalar(@$ofs) > 2){#median or mean of median flanks
    $mpos = (scalar(@$ofs))/2;
    
    if($mpos =~ /\./){#true median
      $mpos =~ s/\..*//;
      $mpos ++;
      $result = $ofs->[$mpos]->get_result_by_Analysis_ExperimentalChips($analysis, $exp_chips);
    }else{
      $result = ($ofs->[$mpos]->get_result_by_Analysis_ExperimentalChips($analysis, $exp_chips) +
		 $ofs->[($mpos+1)]->get_result_by_Analysis_ExperimentalChips($analysis, $exp_chips))/2 ;
    }
  }else{
    #push start, end, score onto results
    $result =  $ofs->[0]->get_result_by_Analysis_ExperimentalChips($analysis, $exp_chips);

  }

  return $result;
}

sub fetch_result_set_by_Slice_Analysis_ExperimentalChips{
  my ($self, $slice, $anal, $exp_chips) = @_;

  #Slice needs to be genrated from eFG not core DB?
  #we need to make sure seq_region_id for slice corresponds to db
  


  #do an equals check here
  my (@ids);
  my $id_type = "r.table_id";
  my $channel_clause = "";
  my $channel_alias = "";
  my $table_name = 'experimental_chip';

  my %chip_metrics = (
		      VSN_GLOG => 1,
		     );


  if(! exists $chip_metrics{$anal->logic_name()}){
    $table_name = "channel";
    $id_type = "concat(r.table_id, ':', c.type)";
    $channel_clause = "AND c.channel_id=r.table_id";
    $channel_alias = ", channel c ";

    foreach my $ec(@$exp_chips){
      push @ids, @{$ec->get_channel_ids()};
    }

  }else{
    foreach my $ec(@$exp_chips){#map?
      push @ids, $ec->dbID;
    }
  }

    #join(", ", @ids);

  #need to then sort out which channel is which in caller.
  #we need channel type (id?), exp_chip id(:channel type), probe_id, score, chr, start, end
  my $query = "SELECT r.score, of.seq_region_start, of.seq_region_end, $id_type, r.oligo_probe_id from result r, oligo_feature of $channel_alias WHERE r.table_name=\"${table_name}\" ".
    "AND r.table_id IN (".join(", ", @ids).") ".
      "AND r.oligo_probe_id=of.oligo_probe_id ".
	"AND  of.seq_region_id=".$slice->get_seq_region_id()." AND of.seq_region_start>=".($slice->start() - 49).
	  " AND of.seq_region_end<=".($slice->end() + 49). 
	    " AND r.analysis_id=".$anal->dbID()." $channel_clause order by of.seq_region_start";


  #warn "query is $query\n";


  #this does not handle features over lapping ends...maybe we should just add the max probe length -1 for the given array.
  #need to handle strand too!

  #Is this what a result should look like?
  #create array of objects from each line
  #score, exp_chip_id(:channeltype), chr?, start(relative to slice?), end(relative to slice?), probe_id


  #should be ordered by start (and seq_region_id?)
	
  return $self->dbc->db_handle->selectall_arrayref($query);
}

1;

