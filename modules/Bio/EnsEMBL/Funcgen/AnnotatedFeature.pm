#
# Ensembl module for Bio::EnsEMBL::Funcgen::AnnotatedFeature
#

=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2017] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <http://www.ensembl.org/Help/Contact>.


=head1 NAME

Bio::EnsEMBL::AnnotatedFeature - A module to represent an enriched feature mapping i.e. a peak call.

=head1 SYNOPSIS

use Bio::EnsEMBL::Funcgen::AnnotatedFeature;

my $feature = Bio::EnsEMBL::Funcgen::AnnotatedFeature->new
  (
	 -SLICE         => $chr_1_slice,
	 -START         => 1_000_000,
   -SUMMIT        => 1_000_019,
	 -END           => 1_000_024,
	 -STRAND        => -1,
   -DISPLAY_LABEL => $text,
   -SCORE         => $score,
   -FEATURE_SET   => $fset,
  );

=head1 DESCRIPTION

An AnnotatedFeature object represents the genomic placement of a prediction
generated by the eFG analysis pipeline. This normally represents the 
output of a peak calling analysis. It can have a score and/or a summit, the 
meaning of which depend on the specific Analysis used to infer the feature.
For example, in the case of a feature derived from a peak call over a ChIP-seq
experiment, the score is the peak caller score, and summit is the point in the
feature where more reads align with the genome.

=head1 SEE ALSO

Bio::EnsEMBL::Funcgen::DBSQL::AnnotatedFeatureAdaptor
Bio::EnsEMBL::Funcgen::FeatureSet

=cut

package Bio::EnsEMBL::Funcgen::AnnotatedFeature;

use strict;
use warnings;
use Bio::EnsEMBL::Utils::Argument  qw( rearrange );
use Bio::EnsEMBL::Utils::Exception qw( throw );

use base qw(Bio::EnsEMBL::Funcgen::SetFeature);

=head2 new

  Arg [-SLICE]        : Bio::EnsEMBL::Slice - The slice on which this feature is.
  Arg [-START]        : Int - The start coordinate of this feature relative to the start of the slice
                              it is sitting on. Coordinates start at 1 and are inclusive.
  Arg [-END]          : Int -The end coordinate of this feature relative to the start of the slice
  Arg [-STRAND]       : Int - The orientation of this feature. Valid values are 1, -1 and 0.
	                            it is sitting on. Coordinates start at 1 and are inclusive.
  Arg [-DISPLAY_LABEL]: String - Display label for this feature
  Arg [-SUMMIT]       : Int (optional) - seq_region peak summit position
  Arg [-SCORE]        : Int (optional) - Score assigned by analysis pipeline
  Arg [-dbID]         : Int (optional) - Internal database ID.
  Arg [-ADAPTOR]      : Bio::EnsEMBL::DBSQL::BaseAdaptor (optional) - Database adaptor.
  Example    : my $feature = Bio::EnsEMBL::Funcgen::AnnotatedFeature->new
                                 (
								  -SLICE         => $chr_1_slice,
								  -START         => 1_000_000,
								  -END           => 1_000_024,
                                  -STRAND        => -1,
                                  -FEATURE_SET   => $fset,
								  -DISPLAY_LABEL => $text,
								  -SCORE         => $score,
                                  -SUMMIT        => 1_000_019,   
                                 );


  Description: Constructor for AnnotatedFeature objects.
  Returntype : Bio::EnsEMBL::Funcgen::AnnotatedFeature
  Exceptions : None
  Caller     : General
  Status     : Stable

=cut

#Hard code strand => 0 here? And remove from input params?

sub new {
  my $caller = shift;
  my $class  = ref($caller) || $caller;
  my $self   = $class->SUPER::new(@_);
  ($self->{score},  $self->{summit}) = rearrange(['SCORE', 'SUMMIT'], @_);	
  return $self;
}


=head2 score

  Example    : my $score = $feature->score;
  Description: Getter for the score attribute for this feature. 
  Returntype : String (float)
  Exceptions : None
  Caller     : General
  Status     : Stable

=cut

sub score {  return shift->{score}; }

=head2 summit

  Arg [1]    : (optional) int - summit postition
  Example    : my $peak_summit = $feature->summit;
  Description: Getter for the summit attribute for this feature. 
  Returntype : int
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut

sub summit {  return shift->{summit}; }


=head2 display_label

  Example    : my $label = $feature->display_label();
  Description: Getter for the display label of this feature.
  Returntype : String
  Exceptions : None
  Caller     : General
  Status     : Medium Risk

=cut

sub display_label {
    my $self = shift;

    #auto generate here if not set in table
    #need to go with one or other, or can we have both, split into diplay_name and display_label?
    
    if(! $self->{'display_label'}  && $self->adaptor){
      $self->{'display_label'} = $self->feature_type->name()." -";
      $self->{'display_label'} .= " ".$self->epigenome->display_label();
      $self->{'display_label'} .= " Enriched Site";
    }
	
    return $self->{'display_label'};
}

=head2 display_id

  Example    : my $label = $feature->display_id;
  Description: Getter for the display_id of this feature. This was created 
               for generating the display id used in big bed files. Converting
               from bed to bigbed causes problems, if 
  Returntype : String
  Exceptions : None
  Caller     : General
  Status     : Medium Risk

=cut

sub display_id {
    my $self = shift;

    if(! $self->{'display_id'}  && $self->adaptor){
      $self->{'display_id'} = join '_', 
        $self->feature_type->name(),
        $self->epigenome->production_name(),
        "_Enriched_Site";
    }
    return $self->{'display_id'};
}


=head2 is_focus_feature

  Args       : None
  Example    : if($feat->is_focus_feature){ ... }
  Description: Returns true if AnnotatedFeature is part of a focus
               set used in the RegulatoryBuild
  Returntype : Boolean
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut

sub is_focus_feature{ return shift->feature_set->is_focus_set; }


=head2 get_underlying_structure

  Example    : my @loci = @{ $af->get_underlying_structure() };
  Description: Returns and array of loci consisting of:
                  (start, (motif_feature_start, motif_feature_end)*, end)
  Returntype : ARRAYREF
  Exceptions : None
  Caller     : General
  Status     : At Risk - This is TFBS specific and could move to TranscriptionFactorFeature

=cut

#This should really be precomputed and stored in the DB to avoid the MF attr fetch
#Need to be aware of projecting here, as these will expire if we project after this method is called

sub get_underlying_structure{
  my $self = shift;

  if(! defined $self->{underlying_structure}){
    my @loci = ($self->start);
	
    foreach my $mf(@{$self->get_associated_MotifFeatures}){
      push @loci, ($mf->start, $mf->end);
    }

    push @loci, $self->end;
	
    $self->{underlying_structure} = \@loci;
  }

  return $self->{underlying_structure};
}

=head2 get_associated_MotifFeatures

  Example    : my @assoc_mfs = @{ $af->get_associated_MotifFeatures };
  Description: Returns and array associated MotifFeature i.e. MotifFeatures
               representing a relevanting PWM/BindingMatrix
  Returntype : ARRAYREF
  Exceptions : None
  Caller     : General
  Status     : At Risk - This is TFBS specific and could move to TranscriptionFactorFeature

=cut

sub get_associated_MotifFeatures{
  my $self = shift;

  if(! defined $self->{assoc_motif_features}){
    my $mf_adaptor = $self->adaptor->db->get_MotifFeatureAdaptor;
		#These need reslicing!
		$self->{assoc_motif_features} = $mf_adaptor->fetch_all_by_AnnotatedFeature($self, $self->slice);
  }

  return $self->{assoc_motif_features};
}

sub SO_term {
  my $self = shift;
  return $self->feature_type->so_accession;
}

=head2 summary_as_hash

  Example       : $segf_summary = $annotf->summary_as_hash;
  Description   : Retrieves a textual summary of this AnnotatedFeature.
  Returns       : Hashref of descriptive strings
  Status        : Intended for internal use (REST)

=cut

sub summary_as_hash {
  my $self = shift;
  my $feature_set = $self->feature_set;

  return
    {
      feature_type     => $self->feature_type->name,
      epigenome        => $self->epigenome->name,
      source           => $feature_set->analysis->logic_name,
      seq_region_name  => $self->seq_region_name,
      start            => $self->seq_region_start,
      end              => $self->seq_region_end,
      description      => $feature_set->display_label,
      strand           => $self->strand,
      summit           => $self->summit,
      score            => $self->score,
    };
}
1;

