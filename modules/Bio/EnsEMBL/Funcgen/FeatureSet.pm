#
# Ensembl module for Bio::EnsEMBL::Funcgen::FeatureSet
#
# You may distribute this module under the same terms as Perl itself

=head1 NAME

Bio::EnsEMBL::FeatureSet - A module to represent FeatureSet.
 

=head1 SYNOPSIS

use Bio::EnsEMBL::Funcgen::FeatureSet;

my $result_set = Bio::EnsEMBL::Funcgen::FeatureSet->new(

); 



=head1 DESCRIPTION

A FeatureSet object provides access to a set of feature predictions and their details, which may have been generated from a 
single or multiple Experiments with potentially differing analyses.  The FeatureSet itself will only have a single analysis 
which may be one or a combination of programs but will be represented by one analysis record.


=head1 AUTHOR

This module was created by Nathan Johnson.

This module is part of the Ensembl project: http://www.ensembl.org/

=head1 CONTACT

Post comments or questions to the Ensembl development list: ensembl-dev@ebi.ac.uk

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Funcgen::FeatureSet;

use Bio::EnsEMBL::Utils::Argument qw( rearrange );
use Bio::EnsEMBL::Utils::Exception qw( throw warning deprecate);
use Bio::EnsEMBL::Funcgen::Storable;

use vars qw(@ISA);
@ISA = qw(Bio::EnsEMBL::Funcgen::Storable);


=head2 new

  Arg [-EXPERIMENT_ID]     : Experiment dbID
  #or
  #Arg [-EXPERIMENT]       : Bio::EnsEMBL::Funcgen::Experiment
  Arg [-SLICE]             : Bio::EnsEMBL::Slice


  Example    : my $feature = Bio::EnsEMBL::Funcgen::FeatureSet->new(
                                                                    -dbid        => $dbid,
                                                                    -analysis    => $analysis,
                                                                    -feature_type => $ftype,
                                                                    -cell_type => $ctype,
                                                                    -name => $name,
                                                                    -type => 'annotated',
			                                                       ); 
  Description: Constructor for FeatureSet objects.
  Returntype : Bio::EnsEMBL::Funcgen::FeatureSet
  Exceptions : Throws if no experiment_id defined
  Caller     : General
  Status     : At risk

=cut

sub new {
  my $caller = shift;
	
  my $class = ref($caller) || $caller;
	
  my $self = $class->SUPER::new(@_);
	
  my ($analysis, $feature_type, $cell_type, $name, $type, $edb_name)
    = rearrange(['ANALYSIS', 'FEATURE_TYPE', 'CELL_TYPE', 'NAME', 'TYPE', 'EXTERNAL_DB_NAME'], @_);

  #Analysis already checked in BaseFeatureAdaptor
  if (! $feature_type || ! $analysis || ! $type){
    throw("Need to pass a feature_type, analysis and feature_set type argument");
  }

  #mandatory?
  #if (! ($cell_type && $cell_type->isa("Bio::EnsEMBL::Funcgen::CellType"))){
#	  throw("Need to pass a valid Bio::EnsEMBL::Funcgen::CellType");
#  }



  $self->analysis($analysis);
  $self->feature_type($feature_type);
  $self->type($type);
  $self->cell_type($cell_type) if $cell_type;
  $self->name($name) if $name;
  #$self->external_db_name($edb_name) if $edb_name;
  

  return $self;
}

=head2 new_fast

  Args       : Hashref with all internal attributes set
  Example    : none
  Description: Quick and dirty version of new. Only works if the code is very
               disciplined.
  Returntype : Bio::EnsEMBL::Funcgen::FeatureSet
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut

sub new_fast {
   my ($class, $hashref)  = @_;

   return bless ($hashref, $class);
}





#methods
#set wide display label(predicted_feature) + more wordy label for wiggle tracks?
#defined by experiment type i.e. time course would require timepoint in display label
#deal with this dynamically or have display_label in table
#Need call on type, or fetch all would

#_get_ec_ids or contigsets?
#this should now be an intrinsic part of this class/adaptor

#cell line
#feature_type
#displayable...should have one for the whole set and one for each raw and predicted?

#have analysis as arg? Or do we get all analysis sets?
#we need to be able to set analyses for FeatureSets dynamically from DB
#pick up all FeatureSets 
#displayable field in FeatureSets also?

#If we have mixed types in the same experiment then we could get promoter features and histone wiggle tracks displayed togeter
#Not v.good for display purposes?  We may want to separate the promoter and histone tracks, or we may want ll the experiment data together but of mixed types.
#We need to be able to pull back the experiment type for each set, therefore this needs setting on an ec level, not an experiment level.
#This is also v.reliant on putting contig set info in place, otherwise we may get mixed chip types in same set.

#get_raw_analysis_name
#get_predicted_feature_analysis_name
#set ResultFeatures and AnnotatedFeatures in hash keyed by analysis_name?

=head2 name

  Example    : my $fset->name('FEATURESET1');
  Description: Getter/Setter for the name of this FeatureSet.
  Returntype : string
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut

sub name {
  my $self = shift;
     	
  $self->{'name'} = shift if @_;

  return $self->{'name'};
}

#=head2 external_db_name

#  Example    : my $fset->external_db_name('miRanda');
#  Description: Getter/Setter for the external_db name of this FeatureSet.
#  Returntype : string
#  Exceptions : None
#  Caller     : General
#  Status     : At Risk

#=cut

#sub external_db_name {
#  my $self = shift;
     	
#  $self->{'external_db_name'} = shift if @_;

#  return $self->{'external_db_name'};
#}



=head2 type

  Example    : my $fset->type('annotated');
  Description: Getter/Setter for the type of this FeatureSet.
               Valid values are 'annotated', 'regulatory' or 'supporting'.
  Returntype : String
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut

sub type {
  my $self = shift;
     	
  #add validation of enum here..or leave to DB
  $self->{'type'} = shift if @_;

  return $self->{'type'};
}



=head2 analysis

  Arg [1]    : (optional) - Bio::EnsEMBL::Analysis
  Example    : $anal_id = $fset->analysis->dbID();
  Description: Getter and setter for the analysis attribute for this FeatureSet.
  Returntype : Bio::EnsEMBL::Analysis
  Exceptions : Throws if arg is not a valid Bio::EnsEMBL::Analysis
  Caller     : General
  Status     : At Risk

=cut


sub analysis {
  my $self = shift;
	

  if(@_){
	  throw("Must pass a valid Bio::EnsEMBL::Analysis object") if (! $_[0]->isa("Bio::EnsEMBL::Analysis"));
	  $self->{'analysis'} = shift;
  }
		
  return $self->{'analysis'};
}


=head2 feature_type

  Arg [1]    : (optional) - Bio::EnsEMBL::Funcgen::FeatureType
  Example    : $fname = $fset->feature_type->name();
  Description: Getter and setter for the feature_type attribute for this FeatureSet.
  Returntype : Bio::EnsEMBL::Funcgen::FeatureType
  Exceptions : Throws if arg is not a valid Bio::EnsEMBL::Funcgen::FeatureType
  Caller     : General
  Status     : At Risk - needs changing to get_FeatureType

=cut


sub feature_type {
	my $self = shift;
	
	if(@_){
	  throw("Must pass a valid Bio::EnsEMBL::Funcgen::FeatureType object") if (! $_[0]->isa("Bio::EnsEMBL::Funcgen::FeatureType"));
	  $self->{'feature_type'} = shift;
	}
	
	return $self->{'feature_type'};
}


=head2 cell_type

  Arg [1]    : (optional) - Bio::EnsEMBL::Funcgen::CellType
  Example    : $cell_display_label = $fset->cell_type->display_label();
  Description: Getter and setter for the analysis attribute for this FeatureSet.
  Returntype : Bio::EnsEMBL::Funcgen::CellType
  Exceptions : Throws if arg is not a valid Bio::EnsEMBL::Funcgen::CellType
  Caller     : General
  Status     : At Risk

=cut


sub cell_type {
	my $self = shift;
	
	if(@_){
		throw("Must pass a valid Bio::EnsEMBL::Funcgen::CellType object") if (! $_[0]->isa("Bio::EnsEMBL::Funcgen::CellType"));
		$self->{'cell_type'} = shift;
	}
	
	return $self->{'cell_type'};
}



=head2 display_label

  Example    : print $rset->display_label();
  Description: Getter for the display_label attribute for this FeatureSet.
               This is more appropriate for teh predicted_features of the set.
               Use the individual display_labels for each raw result set.
  Returntype : str
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut

sub display_label {
  my $self = shift;
  
  if(! $self->{'display_label'}){
    $self->{'display_label'} = $self->feature_type->name()." - ".$self->cell_type->name()." Enriched Sites";
  }
	
  return $self->{'display_label'};
}



=head2 get_FeatureAdaptor

  Example    : 
  Description: Retrieves and caches FeatureAdaptor of feature_set type 
  Returntype : Bio::EnsEMBL::Funcgen::DBSQL::ucfirst($self->type())FeatureAdaptor
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut


sub get_FeatureAdaptor{
  my $self = shift;

  if(! exists $self->{'adaptor_refs'}){

	#can we code ref this?

	$self->{'adaptor_refs'} = {(
								annotated  => $self->adaptor->db->get_AnnotatedFeatureAdaptor,
								regulatory => $self->adaptor->db->get_RegulatoryFeatureAdaptor,
								external   => $self->adaptor->db->get_ExternalFeatureAdaptor,
							   )};

  }
  return $self->{'adaptor_refs'}->{$self->type()};

}



=head2 get_Features_by_Slice

  Example    : my @features = @{$FeatureSet->get_Features_by_Slice($slice)};
  Description: Retrieves all Features for this FeatureSet for a given Slice
  Returntype : ARRAYREF containing Features of the feature_set type i.e. Annotated, Regulatory or Supporting;
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut


sub get_Features_by_Slice{
  my ($self, $slice) = @_;

  return $self->get_FeatureAdaptor->fetch_all_by_Slice_FeatureSets($slice, $self);
}







1;
