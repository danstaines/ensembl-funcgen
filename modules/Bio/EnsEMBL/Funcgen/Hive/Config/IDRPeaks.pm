
=head1 LICENSE

Copyright [1999-2013] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute

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
  developers list at <ensembl-dev@ebi.ac.uk>.

  Questions may also be sent to the Ensembl help desk at
  <helpdesk@ensembl.org>.

=head1 NAME

    Bio::EnsEMBL::Funcgen::Hive::Config::IDRPeaks;

=head1 SYNOPSIS


=head1 DESCRIPTION


=head1 CONTACT

    Please contact ensembl-dev@ebi.ac.uk mailing list with questions/suggestions.

=cut


package Bio::EnsEMBL::Funcgen::Hive::Config::IDRPeaks;

use strict;
use warnings;

use base ('Bio::EnsEMBL::Funcgen::Hive::Config::BaseSequenceAnalysis');
# All Hive databases configuration files should inherit from HiveGeneric, directly or indirectly


=head2 default_options

    Description : Implements default_options() interface method of
    Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf that is used to initialize default options.

=cut


sub default_options {
  my $self = shift; 
  #Define any optional params here as undef
  #If they are mandatory for one analysis, but optional for another
  #will have to catch that in the runnable
  return 
   {
    %{$self->SUPER::default_options},        
  
    ### THIS NEEDS REWORKING FOR IDRPEAKS ###
   };
}


=head2 pipeline_wide_parameters

    Description : Interface method that should return a hash of pipeline_wide_parameter_name->pipeline_wide_parameter_value pairs.
                  The value doesn't have to be a scalar, can be any Perl structure now (will be stringified and de-stringified automagically).
                  Please see existing PipeConfig modules for examples.

=cut


#Can we move some of these to Base.pm config?

sub pipeline_wide_parameters {
  my $self = shift;
               
  return 
   {
    %{$self->SUPER::pipeline_wide_parameters},
    
    #Arg! we can use this approach if we are reusing an analysis?
    #As there is no way of there is no way of the analysis knowing which param to use?
    #
    
    can_run_DefineReplicateDataSet => 1, 
    can_run_DefineMergedDataSet    => 0, 
   };
}


=head2 pipeline_create_commands

    Description : Implements pipeline_create_commands() interface method of
      Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf that lists the commands
      that will create and set up the Hive database.

=cut

## WARNING!!
## Currently init_pipeline.pl doesn't run this method when a pipeline is created with the -analysis_topup option



=head2 pipeline_analyses

    Description : Implements pipeline_analyses() interface method of
      Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf that defines the structure of the pipeline: analyses, jobs, rules, etc.


=cut



#(2) The hive_capacity worker limiting mechanism that was in place for years is going to change slightly.
#The old meanings of the values were:
#	negative value  : checking is switched off in this particular analysis
#	zero		: no workers will be allowed to take this analysis
#	missing value   : sets the default, which is 1
#	positive value	: (including the 1 by default) this analysis is limited by the given value
#This was counter-intuitive, because by default there was already a limit, which people had to raise or switch off if they needed.
#Now, since we also have an alternative mechanism (analysis_capacity), I'd like to make both mechanisms "off" by default
#(missing value will mean "checking is switched off").
#
#So please, please, please - check whether your pipeline *RELIES* on the current default behaviour
#(which is "if you don't specify -hive_capacity, the system will set it to 1
#and will not allow any workers of other analyses to take any jobs while this analysis is running").
#
#If you know/find out that your pipeline *RELIES* on this functionality, please explicitly set -hive_capacity => 1 in the corresponding analyses.
#This will make your pipeline compatible with future releases of the Hive system.





sub pipeline_analyses {
  my $self = shift;

  return [
   @{$self->SUPER::pipeline_analyses}, #To pick up BaseSequenceAnalysis-DefineMergedOutputSet
   
   {
    -logic_name => 'IdentifyReplicateResultSets',
	  -module     => 'Bio::EnsEMBL::Funcgen::Hive::IdentifySetInputs',	 
	  

    #Currently set to dummy until we define branch 4 output from IdentifySetInputs
    #which will group replicate ResultSet outputs based on parent merged ResultSet
    #how are we going to identify that if we don't have a parent set created?
    #Could do this simply based on a set name match?
    #by stripping off the _TR1 number
    #better way would be to re-use the code which identified them as a merged set in the first place
    #which is already in IdentifySetInputs
	   
	   
	  -meadow_type => 'LOCAL',#should always be uppercase
	  
	  #general parameters to pass to all jobs, use_tracking_db?
	  -parameters => {set_type        => 'result_set',
	                  only_replicates      => 1, 
	                 #This might need to take a -replicate flag
	                 #to ensure we only identify single rep InputSets
	                 #Probably need a naming convention i.e. suffix of TR_[1-9]*
	                 #  
	              
	                
	                 },
	             
      #This will fan into the rep peak jobs
      #and semaphore the IDR job, which will need all the input_set ids
      #including the final InputSet
      
      #This IDR jobs needs to record the analysis params and associate them with the FeatureSet
      #so we need to link on DefineOutputSets in here
      #Hence we also need all of the collection config! which I have just deleted. doh!
      
	
	#DOES THIS NEED TO BE A FACTORY Or do we need to flow into a factory?
	#We need to semaphore the IDR job based on a batch of replicates
	
			 	 
	 -flow_into => 
	  {		
     'A->2' => ['RunIDR'], 
	   '3->A' => ['DefineReplicateDataSet'],
	   
	   #'2' => ['PreprocessControl_ReplicateFactory'], 
      #'2' => [ 'DefineReplicateOutputSet' ],
      #Not 2->A as we don't close the funnel for this pipeline
      #'A->1' => [ ],#Nothing else waiting for this job
      #Use branch 2 here so we can flow input_ids
      #down branch 1 back bone later to a merge step
      #although we will need to explicitly data flow
      #Is there a post MergeCollections step?
      
      
      
      #IDR/Replicate Implementation
      #We will need additional semaphored data_flow to run_peak_replicates here
      #to support replicate calling and IDR QC
      #This needs to wait for all replicate sets to be peak called
      #but ignore the rest(we don't want to wait for merged replicate peaks)
      #there is no way of doing this without splitting the whole analysis tree from
      #here i.e. DefineOutputSet?!!!
      #it's clear that implementing IDR optionally along side merged peak calling 
      #in the same pipeline is going to be tricky
      #This would need to flow to another link analysis(if >1 is supported)
      #Something like Run_IDR_QC
      #That link analysis would pick up the groups of input_set_ids
      #do the IDR across the linked FeatureSets and the submit another merged 
      #peak job.
      #This would mean duplicating the peak analyses as we can't loop back due to semaphore
      #IdentifyFeatureSets(or more likely PeaksReport) would also have to be semaphored from here
      #and receive the output of all peak jobs from both originally merged and IDR jobs?
      #No, we can handle this with status entries
      #Further more PreprocessALignment should not data flow to WriteCollections if it is 
      #a replicate
      
      #How can we semaphore an analysis(PeaksReport) which doesn't exist in this config?
      #would have to do this through the link analysis
      #This would wait for everything hanging of DefineOutputSet before commencing 
      #the link analysis, which would then run the IDR and merged peaks, before doing the final 
      #PeaksReport
      #This would also wait for Collections! So we would have to detach that analysis somehow
      #or split DefineOutputSet into DefineReplicateOutputSet and DefineOutputSet
      #VERY COMPLICATED!!!
      
      },
			 
	  -analysis_capacity => 100, #although this runs on LOCAL
      -rc_name => 'default',
    },
	
	
	
	
	 #Actually, we need to Preprocess the control alignments
	 #before we call the peaks
	 #this is to avoid having concurrent sorting/filtering of 
	 #controls which are shared across replicates/experiments
	 
	 #This we need to submit to a factory which will submit batches of replicate peaks jobs
	 #semaphoring each downstream IDR job
	 
	 #This will be by passed if we use analysis top up as
	 #the alignment conf will perform this factory functionality
	 #flowing directly from the replicate peaks jobs to DefineReplicateOutputSet
	 #and also semaphoring the IDR job from the replicate factory which submit the replicate align jobs
	
	 #Can the factory perform the preprocess job too?
	
	  #{
    # -logic_name => 'PreprocessControl_ReplicateFactory',#was 'SetUp',
    # #This is basically making sure the input file is sorted wrt genomic locations
    # #This is so we don't get parallel jobs trying to sort the control file
    # #todo use bam_filtered to skip this sort
    # #we need to make bam_filtered mandatory
    # #as we can'r have parallel jobs resorting/filtering the control file
    # #Need to implement this in all Preprocess jobs
    # #but allow an over-ride function?
    # #such that if we don't have a sorted file for some reason, we can still 
    # #do the relevant preprocessing
     
    # -module     => 'Bio::EnsEMBL::Hive::RunnableDB::JobFactory', #Not CollectionWriter!
   # 
   #  
   #  #Need to maintain this here as will not be updated by -analysis_topup
   #  -parameters => 
   #   {
   #    feature_formats => ['bam'],
   #    peak_branches   => $self->o('peak_branches'),
   #   },
    
   #   -flow_into => 
   #    {   
   #     #This is a factory! Is this the right markup? 
   #  #   '2->A' => ['DefineReplicateDataSet'],
   #  #   'A->3' => ['RunIDR'], 
   #    },
   #  
   #    
   #  -analysis_capacity => 10,
   #    -rc_name => 'normal_2GB',
   #  #this really need revising as this is sorting the bed files
   #  #Need to change resource to reserve tmp space
   # },
	  
    {
     -logic_name => 'DefineReplicateDataSet', 
	   -module     => 'Bio::EnsEMBL::Funcgen::Hive::DefineDataSet',
	   -parameters => 
	    {
	     feature_set_analysis => $self->o('permissive_peaks'), #This will not allow batch override
	    },
				 	 
	    -flow_into => 
       {
        '2' => [ 'run_SWEmbl_R0005_replicate' ],
       },
		 
	   -analysis_capacity => 100,
     -rc_name => 'default',
	   #this really need revising as this is sorting the bed files
	   #Need to change resource to reserve tmp space
	   
	   #Not having a -failed_job_tolerance here is causing the beekeeper to 
	   #exit, especially as there is no -max_retry_count set either
	   
    },
    
    
    
    
    #Could have split this out into a mixin conf, as this is a shared analysis
    #between Peaks and IDRPeaks
    {
     -logic_name    => 'run_SWEmbl_R0005_replicate',  #SWEmbl permissive
     -module        => 'Bio::EnsEMBL::Funcgen::Hive::RunPeaks',
     -analysis_capacity => 10,
     -rc_name => 'long_monitored_high_mem', # Better safe than sorry... size of datasets tends to increase...       
    },
  
  
  
  
  
  
  
    {
     -logic_name    => 'RunIDR',
     -module        => 'Bio::EnsEMBL::Hive::RunnableDB::Dummy',
     #-module        => 'Bio::EnsEMBL::Funcgen::Hive::RunIDR',
     -analysis_capacity => 100,
     -rc_name    => 'default', #~5mins + (memory?)
     -batch_size => 6,#~30mins +
     -parameters => 
      { 
       #result_set_mode              => 'none',#We never want one for an IDR DataSet
       #default_feature_set_analyses => $self->o('permissive_feature_set_analyses'), 
      },
           
     -flow_into => 
      {
       '2' => [ 'DefineMergedReplicateResultSet' ],
      }, 
      
      #Or should this do all this in the same analysis
      #where are we going to cache the run_idr output for the
      #final peak calling threshold? Let's keep this in a tracking DB
      #table to prevent proliferation of analyses based on this value differing between data sets.
      
      #are we going to have problems having these two analyses together
      #if we want to rerun the analysis due to the creation of the merged rset failing?
      #would have to rerun idr too?
      
      #This is extremely unlikely to happen
      #and could do some funky job_id manipulation to set skip_idr
      
      #No we won't be able to reuse DefineResultSets here
      
      
      
      
      
    },
  
 
    {
     -logic_name    => 'DefineMergedReplicateResultSet',  #SWEmbl
     -module        => 'Bio::EnsEMBL::Funcgen::Hive::DefineResultSets',
     -analysis_capacity => 100,
     -rc_name => 'default', 
     
     -parameters => 
     { 
     },
           
     -flow_into => 
      {
       '2' => [ 'DefineMergedDataSet' ],
      }, 
      
      #Or should this do all this in the same analysis
      #where are we going to cache the run_idr output for the
      #final peak calling threshold? Let's keep this in a tracking DB
      #table to prevent proliferation of analyses based on this value differing between data sets.
      
      #are we going to have problems having these two analyses together
      #if we want to rerun the analysis due to the creation of the merged rset failing?
      #would have to rerun idr too?
      
      #This is extremely unlikely to happen
      #and could do some funky job_id manipulation to set skip_idr
      
      #No we won't be able to reuse DefineResultSets here
      
      
      
      
      
    },
  
 
 
 
 
  
 
 
 
  #LINK ANALYSES TO OTHER CONFIGS ###
  
  #DefineMergedDataSet is in BaseSequenceAnalysis as it is common to all
  #either as a 'link out' analysis or as a 'link from' analysis.
  
  
  #We need this to run otherwise we will lose the association between
  #the IDR output (SWEmbl params) and the FeatureSet it is to be associated with
  #As such we need identical working analysis config here and in DefineOutputSets.pm
  #We could separate this and require/import it?
  #might be tricky with variable scoping
 
  #no longer needing to subsamble  
  #java -jar ~/tools/picard-tools-1.70/DownsampleSam.jar I=accepted_hits.bam P=0.01 R=42 O=sample.bam  


 


	 
  ];
}




1;