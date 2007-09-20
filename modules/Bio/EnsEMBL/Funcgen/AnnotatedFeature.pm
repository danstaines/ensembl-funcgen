#
# Ensembl module for Bio::EnsEMBL::Funcgen::AnnotatedFeature
#
# You may distribute this module under the same terms as Perl itself

=head1 NAME

Bio::EnsEMBL::AnnotatedFeature - A module to represent a feature mapping as 
predicted by the eFG pipeline.

=head1 SYNOPSIS

use Bio::EnsEMBL::Funcgen::AnnotatedFeature;

my $feature = Bio::EnsEMBL::Funcgen::AnnotatedFeature->new(
	-SLICE         => $chr_1_slice,
	-START         => 1_000_000,
	-END           => 1_000_024,
	-STRAND        => -1,
        -DISPLAY_LABEL => $text,
        -SCORE         => $score,
        -FEATURE_SET   => $fset,
); 



=head1 DESCRIPTION

A AnnotatedFeature object represents the genomic placement of a prediction
generated by the eFG analysis pipeline, which may have originated from one or many
separate experiments.

=head1 AUTHOR

This module was created by Nathan Johnson.

This module is part of the Ensembl project: http://www.ensembl.org/

=head1 CONTACT

Post comments or questions to the Ensembl development list: ensembl-dev@ebi.ac.uk

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Funcgen::AnnotatedFeature;

use Bio::EnsEMBL::Utils::Argument qw( rearrange );
use Bio::EnsEMBL::Utils::Exception qw( throw );
use Bio::EnsEMBL::Funcgen::SetFeature;
use Bio::EnsEMBL::Funcgen::FeatureType;

use vars qw(@ISA);
@ISA = qw(Bio::EnsEMBL::Funcgen::SetFeature);


=head2 new

 
  Arg [-SCORE]: (optional) int - Score assigned by analysis pipeline
  Arg [-ANALYSIS] : Bio::EnsEMBL::Analysis 
  Arg [-SLICE] : Bio::EnsEMBL::Slice - The slice on which this feature is.
  Arg [-START] : int - The start coordinate of this feature relative to the start of the slice
		 it is sitting on. Coordinates start at 1 and are inclusive.
  Arg [-END] : int -The end coordinate of this feature relative to the start of the slice
	       it is sitting on. Coordinates start at 1 and are inclusive.
  Arg [-DISPLAY_LABEL]: string - Display label for this feature
  Arg [-STRAND]       : int - The orientation of this feature. Valid values are 1, -1 and 0.
  Arg [-dbID]         : (optional) int - Internal database ID.
  Arg [-ADAPTOR]      : (optional) Bio::EnsEMBL::DBSQL::BaseAdaptor - Database adaptor.
  Example    : my $feature = Bio::EnsEMBL::Funcgen::AnnotatedFeature->new(
										                                  -SLICE         => $chr_1_slice,
									                                      -START         => 1_000_000,
									                                      -END           => 1_000_024,
									                                      -STRAND        => -1,
									                                      -DISPLAY_LABEL => $text,
									                                      -SCORE         => $score,
                                                                          -FEATURE_SET   => $fset,
                                                                         );


  Description: Constructor for AnnotatedFeature objects.
  Returntype : Bio::EnsEMBL::Funcgen::AnnotatedFeature
  Exceptions : None
  Caller     : General
  Status     : Medium Risk

=cut

sub new {
  my $caller = shift;
	
  my $class = ref($caller) || $caller;
  
  my $self = $class->SUPER::new(@_);
  
  my ($score,)
    = rearrange(['SCORE'], @_);
  
  
  $self->score($score) if $score;
 	
	
  return $self;
}


=head2 score

  Arg [1]    : (optional) int - score
  Example    : my $score = $feature->score();
  Description: Getter and setter for the score attribute for this feature. 
  Returntype : int
  Exceptions : None
  Caller     : General
  Status     : Low Risk

=cut

sub score {
    my $self = shift;
	
    $self->{'score'} = shift if @_;
		
    return $self->{'score'};
}



=head2 display_label

  Arg [1]    : string - display label
  Example    : my $label = $feature->display_label();
  Description: Getter and setter for the display label of this feature.
  Returntype : str
  Exceptions : None
  Caller     : General
  Status     : Medium Risk

=cut

#Can This be mirrored in AnnotatedFeatureSet?
#this will over ride individual display_label for annotated features.
#set label could be used as track name and feature label used in zmenu?
#These should therefore be called track_label and display_label


sub display_label {
    my $self = shift;
	
    $self->{'display_label'} = shift if @_;


    #auto generate here if not set in table
    #need to go with one or other, or can we have both, split into diplay_name and display_label?
    
    if(! $self->{'display_label'}  && $self->adaptor()){
      $self->{'display_label'} = $self->feature_type->name()." -";
      $self->{'display_label'} .= " ".$self->cell_type->name();# if $self->cell_type->display_name();
      $self->{'display_label'} .= " Enriched Site";
    }
	
    return $self->{'display_label'};
}



1;

