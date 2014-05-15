=pod 

=head1 NAME

Bio::EnsEMBL::Funcgen::Sequencing::SeqTools

=head1 DESCRIPTION


=cut

package Bio::EnsEMBL::Funcgen::Sequencing::SeqTools;

use warnings;
use strict;

use Net::FTP;
use feature qw(say);
use DBI     qw(:sql_types);

use Bio::EnsEMBL::Funcgen::DBSQL::TrackingAdaptor;
use Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Funcgen::InputSubset;
use Bio::EnsEMBL::Funcgen::Experiment;
use Bio::EnsEMBL::Utils::SqlHelper;

#use File::Basename                        qw( fileparse );
use Bio::EnsEMBL::Utils::Scalar            qw( assert_ref );
use Bio::EnsEMBL::Utils::Argument          qw( rearrange );
use Bio::EnsEMBL::Utils::Exception         qw( throw );
use Bio::EnsEMBL::Funcgen::Utils::EFGUtils qw( dump_data
                                               run_system_cmd
                                               run_backtick_cmd 
                                               write_checksum 
                                               validate_path
                                               check_file );  




use Bio::EnsEMBL::Funcgen::Sequencing::SeqQC; #run_QC

use base qw( Exporter );
use vars qw( @EXPORT );

@EXPORT = qw( 
  convert_bam_to_sam
  convert_sam_to_bed
  create_and_populate_files_txt
  download_all_files_txt
  get_files_by_formats
  load_experiments_into_tracking_db
  merge_bams
  modify_files_txt_for_regulation
  process_bam
  run_aligner
  split_fastqs
  validate_sam_header 
  );

#This is designed to act as an object and as a standard package
#run_align_tools will call constructor which will validate that a run mode has been passed
#before cacheing all params and retuning
#then script will call run, which will call the method defined by the run mode,
#passing all the params which wil passed to the contructor
#or optionall, taking arguments, to overide those passed to the constructor?
#then will undef method, for safety


#todo add QC methods (and integrate into other methods turn off with -no_qc)
#todo add split/preprocess methods
#todo add merge method in rmdups
#todo add sort/filter methods? unmapped are normally remove in process_sam_bam
#

#process_sam_bam filters unmapped, sorts and rmdups
#merge only rmdups



#add debug and helper to all these methods


#to do, allow qc methods to be used in here too, to restrict what is run
#from the default qc_type?
#No, just make people run these separately?

sub run_aligner{ 
  my ($aln_pkg, $aln_params, $skip_qc) = rearrange( [qw(aligner aligner_params skip_qc) ], @_);
  assert_ref($aln_params, 'ARRAY', 'Aligner params');
  
  throw('-aligner parameter has not been specifed')  if ! defined $aln_pkg;
    #This is being run when we call require, and exiting as we have no args
    #$0 = $real_path;
    #pod2usage(-exitval => 1, 
    #          -message => '-aligner parameter must be defined');
  #}
  
  if($aln_pkg !~ /::/){
    warn "Full $aln_pkg namespace was not specified, defaulting to:\t".
      "Bio::EnsEMBL::Funcgen::Sequencing::Aligner::$aln_pkg\n";
    $aln_pkg = "Bio::EnsEMBL::Funcgen::Sequencing::Aligner::$aln_pkg";
  }
  
  #Quote so eval treats $aln_pkg as BAREWORD and converts :: to /
  if( ! eval "{require $aln_pkg; 1}"){
    die("Failed to require $aln_pkg\n$@");
  }

 
  my $aligner = $aln_pkg->new(@$aln_params);

  #Don't really need this, although might be nice to show the args passed in the 
  #error output in Aligner
  #if(! defined $aligner){
  #  throw("Failed to create $aln_pkg from params:\n",
  #    join(' ', @$aln_params));
  #}


  #Implement QC in here, wht are we going to return here?
  #return ($aligner->run, $qc_results);
  #This may cause problems if the caller does this
  #if($run_aligner($aln_pkg, $aln_params, 1)){ ... }
  #This test will return false, as this will test the last value in the array
  #in this context
  #if we return @results, where the null value is omited
  #then all is good.
  
  
  #Need to eval this, so we don't call QC on undef file if it has failed?
  #No failure should have died by now
  my @results = ($aligner->run); #This should return the output file
  
  if( ! $skip_qc){
        
  }

  
  return @results;
}



#mv md5 checking in here too? as that is integrated into check_file
#Just force use of gz files here to simplify zcat and md5 checking?
# add qc thresholds?

sub split_fastqs{
  my ($files, $out_prefix, $out_dir, $work_dir, 
      $check_sums, $merge, $chunk_size, $skip_qc, $debug) = rearrange( 
      [qw( files out_prefix out_dir work_dir 
       merge chunk_size skip_qc debug) ], @_);  
 
  assert_ref($files, 'ARRAY', '-files');

  if(! (@$files && 
        (grep {!/fastq.gz$/} @$files) )){
    throw('-files must be an array ref of gzipped fastq files');  
  }
    
  throw('-out_prefix is not defined') if ! defined $out_prefix;
  
  if(! -d $out_dir){
    throw("-out_dir $out_dir is not a valid output directory");        
  } 

  if(! defined $work_dir){
    $work_dir = $out_dir;
  }
  elsif(! -d $work_dir){
    throw("-work_dir $work_dir is not a valid work directory");   
  }
 
  if($check_sums){
    assert_ref($check_sums, 'ARRAY', '-check_sums');    
    
    if(scalar(@$check_sums) != scalar(@$files)){
      throw(scalar(@$files).' -files have been specific but only '.scalar(@$check_sums).
        " -check_sums have been specified\nTo ensure input validation these must ".
        "match, even if undef checksums have to be specified");  
    }
  }
 
  $chunk_size ||= 16000000;#Optimised for ~ 30 mins bwa alignment bjob
  my (@fastqs, %params, $throw);
  
  foreach my $i(0..$#{$files}){
    my $found_path;
    %params = ( debug => $debug, checksum => $check_sums->[$i] );
    
    #Hmm, no undef checksum here means try and find one in a file
    
    #Look for gz files too, 
    #we can't do a md5 check if we don't match the url exactly
    eval { $found_path = check_file($files->[$i], 'gz', \%params); };
 
    if($@){
      $throw .= "$@\n";
      next;  
    }
    elsif(! defined $found_path){
      $throw .= "Could not find fastq file, is either not downloaded, has been deleted or is in warehouse:\t".
        $files->[$i]."\n";
      #Could try warehouse here?
    }
    elsif($found_path !~ /\.gz$/o){
      #use is_compressed here?
      #This will also modify the original file! And potentially invalidate any checksumming
      throw("Found unzipped path, aborting as gzipping will invalidate any further md5 checking:\t$found_path");
      run_system_cmd("gzip $found_path");
      $found_path .= '.gz';  
    }
     
    push @fastqs, $found_path;   
  }
  
  throw($throw) if $throw;
  
  my (@results, @qc_results);
  
  
  
  #if qc fails here, we still split?
  #we need a way to signify QC failure easily without 
  #having to test hash keys?
  #This could be an array of booleans?
  #so we would return \@new_fastqs, \@pass_fail_booleans, \@qc_hashes 
  
 #FastQC in here 
 
 
  #This currently fails as it tries to launch an X11 window!
 
  ### RUN FASTQC
  #18-06-10: Version 0.4 released ... Added full machine parsable output for integration into pipelines
  #use -casava option for filtering
  
  #We could set -t here to match the number of cpus on the node?
  #This will need reflecting in the resource spec for this job
  #How do we specify non-interactive mode???
  #I think it just does this when file args are present
  
  #Can fastqc take compressed files?
  #Yes, but it seems to want to use Bzip to stream the data in
  #This is currently failing with:
  #Exception in thread "main" java.lang.NoClassDefFoundError: org/itadaki/bzip2/BZip2InputStream
  #Seems like there are some odd requirements for installing fastqc 
  #although this seems galaxy specific 
  #http://lists.bx.psu.edu/pipermail/galaxy-dev/2011-October/007210.html
  
  #This seems to happen even if the file is gunzipped!
  #and when executed from /dsoftware/ensembl/funcgen  
  #and when done in interative mode by loading the fastq through the File menu
  
  #This looks to be a problem with the fact that the wrapper script has been moved from the 
  #FastQC dir to the parent bin dir. Should be able to fix this with a softlink
  #Nope, this did not fix things!
  
  warn "DEACTIVATED FASTQC FOR NOW:\nfastqc -f fastq -o ".$out_dir." @fastqs";
  #run_system_cmd('fastqc -o '.$self->output_dir." @fastqs");
  
 
  #todo parse output for failures
  #also fastscreen?

  warn("Need to add parsing of fastqc report here to catch module failures");
  
  #What about adaptor trimming? and quality score trimming?
  #FASTX? quality_trimmer, clipper (do we have access to the primers?) and trimmer?
   
    

  #For safety, clean away any that match the prefix
  run_system_cmd('rm -f '.$work_dir."/${out_prefix}.fastq_*", 1);
  #no exit flag, in case rm fails due to no old files
     
  my @du = run_backtick_cmd("du -ck @fastqs");   
  (my $pre_du = $du[-1]) =~ s/[\s]+total//;   
     
  my $cmd = 'zcat '.join(' ', @fastqs).' | split --verbose -d -a 4 -l '.
    $chunk_size.' - '.$work_dir.'/'.$out_prefix.'.fastq_';
  #$self->helper->debug(1, "Running chunk command:\n$cmd");
  warn "Running chunk command:\n$cmd\n" if $debug;
  
  my @split_stdout = run_backtick_cmd($cmd);
  (my $final_file = $split_stdout[-1]) =~ s/creating file \`(.*)\'/$1/;
  
  if(! defined $final_file){
    throw('Failed to parse (s/.*\`([0-9]+)\\\'/$1/) final file '.
      ' from last split output line: '.$split_stdout[-1]);  
  }
  
  #Get files to data flow to individual alignment jobs
  my @new_fastqs = run_backtick_cmd('ls '.$work_dir."/${out_prefix}.fastq_*");
  @new_fastqs    = sort {$a cmp $b} @new_fastqs;
  
  #Now do some sanity checking to make sure we have all the files
  if($new_fastqs[-1] ne $final_file){
    throw("split output specified last chunk file was numbered \'$final_file\',".
      " but found:\n".$new_fastqs[-1]);  
  }
  else{
    $final_file =~ s/.*_([0-9]+)$/$1/;
    $final_file  =~ s/^[0]+//;
    
    #$self->debug(1, "Matching final_file index $final_file vs new_fastq max index ".$#new_fastqs);
    warn "Matching final_file index $final_file vs new_fastq max index ".$#new_fastqs."\n" if $debug;
    
    
    if($final_file != $#new_fastqs){
      throw('split output specified '.($final_file+1).
        ' file(s) were created but only found '.scalar(@new_fastqs).":\n".join("\n", @new_fastqs));  
    }  
  }
  
  #and the unzipped files are at least as big as the input gzipped files
  @du = run_backtick_cmd("du -ck @new_fastqs");   
  (my $post_du = $du[-1]) =~ s/[\s]+total//; 
  
  #$self->helper->debug(1, 'Merged and split '.scalar(@fastqs).' (total '.$pre_du.'k) input fastq files into '.
  #  scalar(@new_fastqs).' tmp fastq files (total'.$post_du.')');
  warn 'Merged and split '.scalar(@fastqs).' (total '.$pre_du.'k) input fastq files into '.
    scalar(@new_fastqs).' tmp fastq files (total'.$post_du.")\n" if $debug;
  
  if($post_du < $pre_du){
    throw("Input fastq files totaled ${pre_du}k, but output chunks totaled only ${post_du}k");  
  }
  
  return \@results;#\@new_fastqs, \%qc_results;
}




#todo
# 1 add support for filter config i.e. which seq_regions to filter in/out
# 2 Sorted but unfiltered and unconverted files may cause name clash here
#   Handle this in caller outside of EFGUtils, by setting out_file appropriately
# 3 add a DESTROY method to remove any tmp sorted files which may persist after an
#   ungraceful exit. These can be added to a global $main::files_to_delete array
#   which should then also be undef'd in DESTROY so they don't persisnt to another instance

#This warning occurs when only filtering bam to bam:
#[bam_header_read] EOF marker is absent. The input is probably truncated.
#This is not fatal, and not caught. Does not occur when filtering with sort
#maybe we shoudl also be catchign $@ after samtools view -H $in_file?


#We could use the existing Bio::SamTools package but:
#1 This will add an extra requirement
#2 This will need to be isolated in a hive/analysis only module
#3 It doesn't appear to support merge operations
#4 It wouldn't support the piping/greping we do to filter the data

#support sam input here
#also separate this into merge_sam_bam
#and merge_sam_bam_cmd
#then we can use this to grab the pipe command and have 1 place for the sort/merge code

#move to Utils::SamUtils?


#Can we return the number of duplicates removes?

#header should already be included in bams, but 
#we do want functionality to include it here
#todo currently does nothing and header shoudl be specified as fai file!
#shoudl validate this if they are both present
#so we need an infile optional flag in _validate_sam_header_index_fai

#when do we ever use sam_header and no fai?

#We currently never use sam_header as the is the only things it is passed to and this
#doesn't ever use it

#This is for use with merge, and overwrites header which would otherwise
#just be copied from the first bam file!
#This maybe a subset of the complete header, dependant on the output of bwa 
#for that chunk. Does it omit header lines for which is has no alignments?

#how do we create sam header from fai?
#samtools faidx ref.fa; samtools view -ht ref.fa.fai myfile.sam
#But this requires a sam file, and will this output the full header?

#Do we really need the sam header here, can't we just validate
#each bam header is a subset of the fai, then integrate the full header via view?

#update to take a sam fai or header file
#the header integration removes the need for the final view step
#if ther headers aren't identical

#Move rmdups to process_sam_bam?
#Then unfiltered file, will be truly unfiltered.
#This will just increase our footprint on warehouse
#Keeping the unfiltered bam is not really necessary, we really only want the unfitlered QC report, 
#so we now how many didn't map, and how many duplicates there were. to give us an idea of the quality 
#of the fastq.
#So change this to skip the rmdups, then perform the pre-filter qc
#i.e. the alignement report, flagstat etc
#Then immediately process_bam, to sort and filter out dups and unmapped
#and call this unique_mappings

#so we are effectively moving all filter processing to process_sam_bam

#This is slightly inefficient,if we don't care about the intermediate unfiltered data

#Integrate slign report in here?

sub merge_bams{
  my $outfile     = shift;
  my $sam_ref_fai = shift;
  my $bams        = shift;
  my $params      = shift || {};  
  assert_ref($bams, 'ARRAY', 'bam files');
  
  if(! scalar(@$bams)){
    throw('Must provide an arrayref of bam files to merge');  
  }
  
  my $out_flag = '';
  
  if(! defined $outfile){
    throw('Output file argument is not defined');  
  }
  elsif($outfile !~ /\.(?:bam|sam)$/xo){
    #?: does not assign to $1
    $out_flag = 'b' if $1 eq 'bam';
    throw('Output file argument must have a sam or bam file suffix');    
  }

  assert_ref($params, 'HASH');
  my $debug     = (exists $params->{debug})          ? $params->{debug}          : 0;
  my $no_rmdups = (exists $params->{no_rmdups})      ? $params->{no_rmdups}      : undef;
  my $checksum  = (exists $params->{write_checksum}) ? $params->{write_checksum} : undef;
  warn "merge_bam_params are:\n".dump_data($params)."\n" if $debug;
  
  
  #For safety we need to validate all the bam headers are the same?
  #or at least no LN clashed for the same SN?
  #Must all be subsets of sam_header if specified, and reheader output with
  #sam_header if defined
  #else, with the merge of all the input headers?
  #This later option would permit merges of redunant headers if the SN values
  #are not identical for the same sequence
  #force sam header for safety?
  #For now, let just make sure they are identical
  #if (! defined $sam_header){
  #  throw('Must pass a sam_header argument');
  #}
  #sam_header check will be done in validate_sam_header with cross validate boolean
  my $view_header_opt;
  
  for(@$bams){ 
    my $tmp_opt = validate_sam_header($_, $sam_ref_fai, 1, $params);
    $view_header_opt = $tmp_opt if $tmp_opt;               
  }
  
  #validate/convert inputs here?
  #just assume all aren bam for now
  my $cmd = '';
  
  #Assume files are already sorted but support optional sort
  #it would be nice if samtools updated the sort flag in the header?
  #maybe we can do this?
  
  #if(defined $sort){
  #  throw('Not implemented sort yet');  
    # my $sorted_prefix = $tmp_bam.".sorted_$$";
    #$tmp_bam .= ($sort) ? ".sorted_$$.bam" : '.tmp.bam';
    #$cmd .= ' | samtools view -uShb - ';  #simply convert to bam using infile header
    #$cmd .= ($sort) ? ' | samtools sort - '.$sorted_prefix : ' > '.$tmp_bam;
  #}
 

  
  #-u uncompressed BAM output for pipe (header remains in sam format)
  #-f force overwrite output
  #-h is include header in output, seems to be in sam format i.e. not binary if output is bam??
  # - To specify seding output to STDOUTT for
  

  
  #rmdup samtools rmdup [-sS] <input.srt.bam> <out.bam>
  #docs look like it only takes sorted bam? 
  #but there is no specific mention of this?
  #I don't think so, this is probably just the optimal way of doing this
  #but we never assume the file is sorted? or do we?
  #look how this is handled in get_alignment_files_by_ResultSet  
  
  my $skip_merge = 0;
  
  if(scalar(@$bams) == 1){
    #samtools merge cannot handle a single input!
    #Instead it throws a seemingly completely unrelated error message:
    #Note: Samtools' merge does not reconstruct the @RG dictionary in the header. Users
    #  must provide the correct header with -h, or uses Picard which properly maintains
    #  the header dictionary in merging.
           
    #Rather than having the caller have to handle this, let's just do the expected thing here
    #and warn.
    $skip_merge = 1;
    warn 'Only 1 bam file has been specified, merge will be skipped, '.
      "otherwise file will be processed accordingly\n";
  }
  
  
  
  if((! $no_rmdups) || $view_header_opt){
    #merge keeps the header in sam format (maybe this is a product of -u)?
    $cmd = 'samtools merge -u - '.join(' ', @$bams).' | ' if ! $skip_merge; 
   
    if( ! $no_rmdups ){
       #rmdup converts the header into binary format
       $cmd .= 'samtools rmdup -s ';
       $cmd .= $skip_merge ? $bams->[0].' ' : ' - ';
       
       if( $view_header_opt ){
         $cmd .=  ' - | '
       }
       else{
         $cmd .= $outfile;  
       }
    }
    
    if($view_header_opt){
      #We only need to do this if the validate_sam_header
      #method identifed some of the bams without the relevant header
      
      warn "Currently integrating fai header via samtools view, but it is more efficient to integrate is with sam format header in merge";
      
      $cmd .= "samtools view -t $sam_ref_fai -h${out_flag} - > $outfile";
      #This is current failing on the first line of the fai file with?
      #[sam_header_read2] 194 sequences loaded.
      #[sam_read1] reference 'LN:133797422' is recognized as '*'.
      #Parse error at line 1: invalid CIGAR character
      # Aborted
      
           
      #$? is set to 134 when this happens!
      #Why is this working in BWA?
      #Maybe it's not?
      
      #Oddly enough this doesn't abort when running within this analysis
      #but does on the cmdline, when runnign the commands separately
      #even after exit handling fix
      
      #scripts does give this output tho, which is totally different:
      #sh: line 1:  1707 Done                    samtools merge -u - /lustre/scratch109/ensembl/funcgen/output/sequencing_nj1_tracking_homo_sapiens_funcgen_76_38/alignments/homo_sapiens/GRCh38/ENCODE_UW/NHEK_WCE_ENCODE_UW.0000.bam /lustre/scratch109/ensembl/funcgen/output/sequencing_nj1_tracking_homo_sapiens_funcgen_76_38/alignments/homo_sapiens/GRCh38/ENCODE_UW/NHEK_WCE_ENCODE_UW.0001.bam /lustre/scratch109/ensembl/funcgen/output/sequencing_nj1_tracking_homo_sapiens_funcgen_76_38/alignments/homo_sapiens/GRCh38/ENCODE_UW/NHEK_WCE_ENCODE_UW.0002.bam /lustre/scratch109/ensembl/funcgen/output/sequencing_nj1_tracking_homo_sapiens_funcgen_76_38/alignments/homo_sapiens/GRCh38/ENCODE_UW/NHEK_WCE_ENCODE_UW.0003.bam /lustre/scratch109/ensembl/funcgen/output/sequencing_nj1_tracking_homo_sapiens_funcgen_76_38/alignments/homo_sapiens/GRCh38/ENCODE_UW/NHEK_WCE_ENCODE_UW.0004.bam
      #1708                       | samtools rmdup -s - -
      #1709 Aborted                 | samtools view -t /lustre/scratch109/ensembl/funcgen/sam_header/homo_sapiens/homo_sapiens_male_GRCh38_unmasked.fasta.fai -h - > /lustre/scratch109/ensembl/funcgen/alignments/homo_sapiens/GRCh38/ENCODE_UW/NHEK_WCE_ENCODE_UW_bwa_samse_1.unfiltered.bam
      
      #Irt just seems to hang for a long time and then carry on with the script
      #as though nothign had happened
      #cmdline returns 134 in $?
      
      #This appears to have been caused by using the wrong fai file
      #it was using the male file by default (as it has the super set of seqs)
      #So it seems that mismatched in file headers vs fai headers causes this error
      #No! But getting the headers to match, did mean the merge avoids the problematic
      #samtools view -ht command
      
      #This is because only the first process exit status is captured by perl
      
    }
  }
  elsif(! $skip_merge){  
    $cmd = "samtools merge $outfile ".join(' ', @$bams); 
  }
  else{ #skip merge
    $cmd = 'cp '.$bams->[0].' '.$outfile;
  }
 
  
  #piping like this may cause errors downstream of the pipe to be missed
  #could we try doing an open on the piped cmd to try and catch a SIGPIPE?
  
  warn "Merging with:\n$cmd\n" if $debug;
  run_system_cmd($cmd);
  warn "Finished merge to $outfile" if $debug;
  
  if($checksum){
    write_checksum($outfile, $params);  
  }
    
  return;
}



#todo
#1 We need to catch if consequence of opts is to actually do nothing
#2 Make rmdups optional as this will have already been done in the merge_bams?
#  No we should always rmdups here, in case we want to keep the truly unfiltered file?
#3 Implement multi-mapping filter
  #ENCODE removed multimapping reads, probably by filtering based on presence of XA tag
  #-n is not defined. This seems only to apply to paired reads?
  #It's unclear exactly what bwa does here.
  #Repetitive hits will be chosen randoml(y, and XA will be written for alternate mappings)
  #This means some duplicate reads will likely be slipping through if
  #they map to multiple locations
#  To filter (given bwa samse -n wasn't used)
#  -F 100 will remove non-primary mappings
#  -v XA will remove remaining primary mappings will alternative mapping present in the 
#  XA field.  samtools view -F 100 -h in.bam | grep -v XA 
#This only works for single end reads, and would potentially leave dangling reads if
#the other half of a pair did not have an XA tag. So you would have to grep out the QNAME (query/pair name)
#and re-filter on that.
#--> Implement and are_paired flag


#checksum in params here acts to check and write checksums
#checksum => undef tries to find a checksum file
#checksum => MD%STRING checks using string

sub process_sam_bam {
  my $sam_bam_path = shift;
  my $params       = shift || {};
  my $in_file;

  #undef checksum here mean try and find one to validate
  #but then we don't write one

  if(! ($in_file = check_file($sam_bam_path, undef, $params)) ){
    throw("Cannot find file:\n\t$sam_bam_path");
  }
  
  #Could just take a local copy of the hash to avoid doing this and use
  #the hash directly
  assert_ref($params, 'HASH');
  my $out_file      = (exists $params->{out_file})              ? $params->{out_file}              : undef;
  my $sort          = (exists $params->{sort})                  ? $params->{sort}                  : undef;
  my $skip_rmdups   = (exists $params->{skip_rmdups})           ? $params->{skip_rmdups}           : undef;
  #Turn on checksum writing
  my $checksum      = (exists $params->{checksum})              ? 1                                : undef;
  my $fasta_fai     = (exists $params->{ref_fai})               ? $params->{ref_fai}               : undef;
  my $out_format    = (exists $params->{output_format})         ? $params->{output_format}         : undef;
  my $debug         = (exists $params->{debug})                 ? $params->{debug}                 : 0;  
  my $filter_format = (exists $params->{filter_from_format})    ? $params->{filter_from_format}    : undef;
  my $force         = (exists $params->{force_process_sam_bam}) ? $params->{force_process_sam_bam} : undef; 

  #sam defaults
  $out_format     ||= 'sam';
  my $in_format = 'sam';
  my $in_flag   = 'S';

  if($out_format !~ /^(?:bam|sam)$/){
    throw("$out_format is not a valid samtools output format");
  }

  if($in_file =~ /\.bam$/o){     # bam (not gzipped!)
    $in_format = 'bam';
    $in_flag   = '';
  }
  elsif($in_file !~ /\.sam(?:\.gz)*?$/o){ # sam (maybe gzipped)
    throw("Unrecognised sam/bam file:\t".$in_file);
  }

  #This is odd, we really only need a flag here
  #but we already have the filter_from_format in the params
  if(defined $filter_format &&
     ($filter_format ne $in_format) ){
    throw("Input filter_from_format($filter_format) does not match input file:\n\t$in_file");
  }


  if(! $out_file){
    ($out_file = $in_file) =~ s/\.${in_format}(?:.gz)*?$/.${out_format}/;

    if(defined $filter_format){
      $out_file =~ s/\.unfiltered//o;  #This needs doing only if is not defined
    }
  }

  #Sanity checks
  (my $unzipped_source = $in_file) =~ s/\.gz$//o;
  (my $unzipped_target = $out_file)     =~ s/\.gz$//o;

  if($unzipped_source eq $unzipped_target){
    #This won't catch .gz difference
    #so we may have an filtered file which matches the in file except for .gz in the infile
    throw("Input and output (unzipped) files are not allowed to match:\n\t$in_file");
  }

  if($filter_format){

    if($in_file !~ /unfiltered/o){
      warn("Filter flag is set but input file name does not contain 'unfiltered':\n\t$in_file");
    }

    if($out_file =~ /unfiltered/o){
      throw("Filter flag is set but output files contains 'unfiltered':\n\t$in_file");
    }
  }
  elsif(! $sort &&
        ($in_format eq $out_format) ){
    throw("Parameters would result in no change for:\n\t$in_file");
  }


  #Could do all of this with samtools view?
  #Will fail if header is absent and $fasta_fai not specified
  #$fasta_fai is ignored if infile header present
  #Doing it like this would integrate the fai into the output file, which is probably what we want?
  #This would also catch the absent header in the first command rather than further down the pipe
  #chain which will not becaught gracefully

  #This can result in mismatched headers, as it does seem like the fai file is used rather than the in file header
  #here, at least for bams


  #Define and clean intermediate sorted files first
  (my $tmp_bam = $in_file) =~ s/\.$in_format//;
  my $sorted_prefix = $tmp_bam.".sorted";
  $tmp_bam .= ($sort) ? ".sorted.bam" : '.tmp.bam';  
  my $cmd = "rm -f $tmp_bam*";
  warn $cmd."\n" if $debug;
  run_system_cmd($cmd, 1); #no exit flag
  $cmd = '';
  
  #Check header and define include option
  my $fasta_fai_opt = validate_sam_header($in_file, $fasta_fai, undef $params);
  
  
  #Validate that we actually want to do something here
  #filter, sort, format conversion or header include?
  #othwerwise this is a simple mv operation
  my $reheader = 0;
  
  if((! ($filter_format || $sort)) &&
     ($out_format eq $in_format) ){
    #This could possibly be a reheader operation or simply a move
    
    if(! $fasta_fai_opt){
      
      if(! $force){
      #arguably we should just do this but it is likely the options are wrong
      #could provide a flag over-ride for this?
      throw('The options provided do not require any processing of the input file:'.
        "\n\t$in_file\nOther than copying to the output file destination:\n\t".
        $out_file."\nPlease check/revise your options or specify the force_process_sam_bam parameter");
      }
      else{
        $cmd = "mv $in_file $out_file";  
      }
    }
    else{ #We simply want to reheader
      #in and out format are the same, so can just test in format
    
      if($in_format eq 'sam'){
        $cmd = "samtools view -h${in_flag} $fasta_fai_opt $in_file ";   
      }
      else{ #must be bam
        throw('bam reheader is not yet supported as requires a sam format header file');
        #actually fai format is not yet being validated, so this will fail if we pass a sam header
        #as the $fasta_fai_opt will be -h (for merge) if it is in sam format
        #$cmd = 'samtools reheader $sam_fai_or_header $in_file && mv $in_file $out_file';
      }
    }
  }
  
  
  if(! $cmd){ #We want to do some filtering/sorting
    my $filter_opt = ($filter_format) ? '-F 4' : '';
    $cmd = "samtools view -hub${in_flag} $filter_opt $fasta_fai_opt $in_file "; # -h include header
    #if we are not filtering and the headers match then we don even need this step!
    #We shoudl probably omit the MT filtering completely as these will be handled in the blacklist?
    #we haven't omitted other repeats yet, so this would be consistent
  
    #todo tidy up filter_format vs filter_mt modes
    #drop MT filtering from here!
  
    #if($filter_format){
      #$cmd .= "-F 4 | ". #-F Skip alignments with bit set in flag (4 = unaligned)
      #  " grep -vE '^[^[:blank:]]+[[:blank:]][^[:blank:]]+[[:blank:]]+(MT|chrM)' "; #Filter MTs or any reference seq with an MT prefix
      #Could add blank after MT, just in case there are valid unassembed seq names with MT prefixes
      #Fairly safe to assume that all things beginning with chrM are MT or unassembled MT
    #}
  
    #-u uncompressed bam (as we are piping)
    #-S SAM input
    #-t  header file (could omit this if it is integrated into the sam/bam?)
    #- (dash) here is placeholder for STDIN (as samtools doesn't fully support piping).
    #This is interpreted by bash but probably better to specify /dev/stdin?
    #for clarity and as some programs can treat is as STDOUT or anything else?
    #-b output is bam
    #-m 2000000 (don't use 2G here,a s G is just ignored and 2k is used, resulting in millions of tmp files)
    #do we need an -m spec here for speed? Probably better to throttle this so jobs are predictable on the farm
    #We could also test the sorted flag before doing this?
    #But samtools sort does not set it (not in the spec)!
    #samtools view -H unsort.bam
    #@HD    VN:1.0    SO:unsorted
    #samtools view -H sort.bam
    #@HD    VN:1.0    SO:coordinate
    #We could add it here, but VN is mandatory and we don't know the version of the sam format being used?
    #bwa doesn't seem to output the HD field, not do the docs suggest which spec is used for a given version
    #mailed Heng Lee regarding this
    #$cmd .= ' | samtools view -uShb - ';  #simply convert to bam using infile header
    $cmd .= ($sort) ? ' | samtools sort - '.$sorted_prefix : ' > '.$tmp_bam;
    warn $cmd."\n" if $debug;
    run_system_cmd($cmd);
    
    
    #This is now giving 
    #[sam_header_read2] 194 sequences loaded.
    #[sam_read1] reference 'LN:133797422' is recognized as '*'.
    #Parse error at line 1: invalid CIGAR character
    #[samopen] SAM header is present: 194 sequences.
    #[sam_read1] reference 'SN:KI270740.1    LN:37240
  
  
    #' is recognized as '*'.
    #[main_samview] truncated file.
    
    #But this is not caught as an error!!!
    #as the exit status is only caught for the last command
    #let's write a run_piped_system_cmd which checks bash $PIPESTATUS array
    #which contains all exit states for all commands in last pipe command
    
    #why is the fasta_fai_opt being defined at all?
    #surely the headers are the same?
    #Is this error because there are headers in both files
    
  
    #Add a remove duplicates step
    #-s single end reads or samse (default is paired, sampe)
    #Do this after alignment as we expect multiple reads if they map across several loci
    #but not necessarily at exactly the same loci which indicates PCR bias
    
    my $rm_cmd = "rm -f $tmp_bam";
    
    if($filter_format){
      
      if(! $skip_rmdups){      
        $cmd = "samtools rmdup -s $tmp_bam ";
      }
      
      if($out_format eq 'sam'){
        
        if($skip_rmdups){       
          $cmd = "samtools view -h $tmp_bam > $out_file"; 
        }
        else{
          $cmd .= "- | samtools view -h - > $out_file";
        }
           
      }
      elsif($skip_rmdups){
        $cmd = "mv $tmp_bam $out_file";   
        $rm_cmd = ''
      }
      else{
        $cmd .= $out_file;  
      }
    }
    elsif($out_format eq 'bam'){
      #We know we have bam by now as we have done some sorting
      $cmd = "mv $tmp_bam $out_file";
      $rm_cmd = '';
    }
    else{ #We need to convert to sam     
      $cmd = "samtools view -h $tmp_bam > $out_file";
    }
    
    warn $cmd."\n" if $debug;
    run_system_cmd($cmd);  
    $cmd = $rm_cmd;
  }
  
  if($cmd){
    warn $cmd."\n" if $debug;
    run_system_cmd($cmd);
  }
  
  if($checksum){
    write_checksum($out_file, $params);
  }

  return $out_file;
}


#todo refactor get_files_by_formats complexity & nesting issues
#This handles g/unzipping and conversion from bam > sam > bed
#This also assumes that we only ever want to convert in this direction
#i.e. assumes bam /sam will always exist if we have bed.

#sam params contains:
#ref_fai         => file_path
#filter_from_bam => 1
#could also support:
#include_MT   => 1,
#include_dups => 1,
#ignore header mismatch? (could do thi swith levels, which ignore supersets in fai?

#Currently hardoded for samse files name for sam and bed
#todo _validate_sam_params


#$formats should be in preference order? Although this doesn't break things, it will just return a non-optimal file format

#Slightly horrible method to manage acquisition and conversion of files between
#supported formats (not necessarily feature formats)
#all_formats is necessary such that we don't redundant process files which are on the same conversion path when we have filter_format set


#There is a possibility that the formats provided might not have the same root, and so
#filter_from_format may be invlaid for one
#In this case two method calls might be require, hence we don't want to throw here if we can't find a file

#This seems over-engineered! But we definitely need the ability to request two formats at the same time
#to prevent parallel requests for the same file

#Filtering will normally be done outside of this method, by the alignment pipeline
#however, we must support it here incase we need to refilter, or we get alignment files
#supplied outside of the pipeline


#what about if we only have the unfiltered file
#but we ask for filtered
#should we automatically filter?
#should we move handling 'unfiltered' to here from get_alignment_files_by_InputSet_formats?
#Is this too pipeline specific?
#what if some files don't use the 'unfiltered' convention?
#then we may get warnings or failures if the in_file and the out_file match
#would need to expose out_path as a parameter
#which would then need to be used as the in path for all subsequent conversion
#No this wouldn't work as it would change the in file to contain unfiltered
#which might not be the case.

#This is actually a generic method apart from the conversion paths
#which could be passed as code refs from here
#so we could move this back to EFGUtils

sub get_files_by_formats {
  my $path    = shift;
  my $formats = shift;
  my $params  = shift || {};
  assert_ref($formats, 'ARRAY');
  assert_ref($params, 'HASH');
  $params->{sort}     = 1 if ! defined $params->{sort};     #Always sort if we call process_$format
  #process_$format will never be called if $format file exists, hence no risk of a redundant sort
  #for safety, only set this default if filter_from_format is defined? in block below

  #Leave this to the caller now
  #$params->{checksum} = 1 if ! defined $params->{checksum}; #validate and check

  if(scalar(@$formats) == 0){
    throw('Must pass an Arrayref of file formats/suffixes in preference order e.g. [\'sam\', \'bed\']');
  }

  my %conversion_paths = ( bam => ['bam'],
                           sam => ['bam', 'sam'],
                           bed => ['bam', 'sam', 'bed'],
                           #we always need the target format as the last element
                           #such that we can validate the filter_format e.g. for bam
                           #if the path array only has one element, it must match the key
                           #and this constitues calling filter_bam
                           #or if filter_format not set, just grabbing the bam file

                           #This approach prevents being able to | bam sort/filters through
                           #to other cmds, so may be slower if we don't need to keep intermediate files?

                           #Could also have non-bam rooted paths in here
                           #and maybe multiple path with different roots?
                         );

  my $can_convert           = 0;
  my $clean_filtered_format = 0;
  my $filter_format         = $params->{filter_from_format};
  my $all_formats           = $params->{all_formats};
  my $done_formats          = {};

  #Add filter format if it is not in $formats
  if($filter_format &&
     (!  grep { /^$filter_format$/ } @$formats )){
    unshift @$formats, $filter_format;
    $clean_filtered_format = 1;
  }

  #Attempt to get the first or all formats
  foreach my $format(@$formats){
    my $can_filter = 0;

    #Do this before simple file test as it is quicker
    if(grep { /^${format}$/ } keys %$done_formats){ #We have already created this format
      next;
    }

    #Simple/quick file test first before we do any conversion nonsense
    #This also means we don't have to have any conversion config to get a file which
    
    #This is being undefd after we filter, so hence, might pick up a pre-exising file!
    if(! defined $filter_format){

       if(my $from_path = check_file($path.'.'.$format, 'gz', $params)){#we have found the required format
          $done_formats->{$format} = $from_path;
          next;
       }
    }


    ### Validate we can convert ###
    if(exists $conversion_paths{$format}){
      $can_convert = 1;

      if(defined $filter_format){

        if( ($conversion_paths{$format}->[0] ne $filter_format) &&
            ($all_formats) ){
          throw("Cannot filter $format from $filter_format for path:\n\t$path");
        }
        elsif((scalar(@{$conversion_paths{$format}}) == 1 ) ||
              (! $clean_filtered_format)){
          my $filter_method_name = 'process_'.$filter_format;
          my $filter_method;
          $can_filter = 1;

          #Sanity check we can call this
          if(! ($filter_method = Bio::EnsEMBL::Funcgen::Sequencing::SeqTools->can($filter_method_name))){
            throw("Cannot call $filter_method_name for path:\n\t$path\n".
              'Please add method or correct conversion path config hash');
          }

          #Set outfile here so we don't have to handle unfiltered in process_sam_bam
          #don't add it to $params as this will affected all convert methods
          (my $outpath = $path) =~ s/\.unfiltered$//o;

          #$format key is same as first element

          $done_formats->{$format} = $filter_method->($path.'.'.$filter_format, 
                                                      {%$params, 
                                                       out_file => $outpath.'.'.$filter_format} );       
          #so we don't try and refilter when calling convert_${from_format}_${to_format}
 
          #delete $params->{filter_from_format};#Is this right?

          undef $filter_format; #Just for safety but not strictly needed
          $path = $outpath;

        }
      }
    }
    elsif($all_formats){
      throw("No conversion path defined for $format. Cannot acquire $format file for path:\n\t$path\n".
        'Please select a supported file format or add config and conversion support methods for $format');
    }

    ### Attempt conversion ###
    if($can_convert){
      #This now assumes that if $filter_format is set
      #convert_${filter_format}_${to_format} provides filter functionality

      if(scalar(@{$conversion_paths{$format}}) != 1){      #already handled process_${format} above
        #Go through the conversion path backwards
        #Start at last but one as we have already checked the last above i.e. the target format
        #or start at 0 if we have $filter_format defined
        my $start_i = (defined $filter_format) ? 0 : ($#{$conversion_paths{$format}} -1);

        for(my $i = $start_i; $i>=0; $i--){
          my $from_format = $conversion_paths{$format}->[$i];

          #Test for file here if we are not filtering! Else we will always go through
          #other formats and potentially redo conversion if we have tidied intermediate files
          if( (! defined $filter_format) &&
              (! grep { /^${from_format}$/ } keys %$done_formats )){
            my $from_path = $path.".${from_format}";

            if($from_path = check_file($from_path, 'gz', $params)){#we have found the required format
              $done_formats->{$from_format} = $from_path;
              #next; #next $x/$to_format as we don't want to force conversion
            }
          }


          #find the first one which has been done, or if none, assume the first is present
          if( (grep { /^${from_format}$/ } keys %$done_formats)  ||
              $i == 0){
            #then convert that to the next, and so on.
            for(my $x = $i; $x < $#{$conversion_paths{$format}}; $x++){
              my $to_format   = $conversion_paths{$format}->[$x+1];
              $from_format    = $conversion_paths{$format}->[$x];
              my $conv_method = 'convert_'.$from_format.'_to_'.$to_format;

              #Sanity check we can call this
              if(! ($conv_method = Bio::EnsEMBL::Funcgen::Sequencing::SeqTools->can($conv_method))){
                throw("Cannot call $conv_method for path:\n\t$path\n".
                  'Please add method or correct conversion path config hash');
              }


              $done_formats->{$to_format} = $conv_method->($path.'.'.$from_format, $params);

              #Remove '.unfitlered' from path for subsequent conversion
              if(($i==0) &&
                defined $filter_format){
                $path =~ s/\.unfiltered$//o;
              }
            }

            last; #We have finished with this $conversion_path{format}
          }
        }


        if($clean_filtered_format && ($format eq $filter_format)){
          #filter_format is not our target format, so we need to keep going
          next; #$format
        }
        elsif(! $all_formats){  #else we have found the most preferable, yay!
          last;  #$format
        }
      }
    }
  } #end foreach my $format


  #Now clean $done_formats

  if($clean_filtered_format){
   #actually delete filtered file here?
    delete $done_formats->{$filter_format};
  }

  foreach my $format(keys %$done_formats){
    #doesn't matter about $all_formats here

    if(! grep { /^${format}$/ } @$formats){
      delete $done_formats->{$format};
    }
  }

  #test we have somethign to return!?
  #if( scalar(keys %$done_formats) == 0 ){
  #  throw('Failed to find any '.join(', ', @$formats)." files for path:\n\t$path");
  #}
  #don't do this as we may want to test for a filtered file, before attempting a filter
  #from a different path
  #This is caught in get_alignment_files_by_InputSet_formats

  return $done_formats;
}



#Is validate_checksum going to have problems as files are gunzipped
#Should validate checksum also handle .gz files i.e. check for entry without .gz, gunzip and validate?
#Maybe all checksums should be done on gunzipped files


#DAMMIT! Part of the filtering is currently done in SAM!!!!
#Need to fix this so we can drop sam file completely.

#There is a danger that a filter_format maybe specified but a pre_process_method
#never get called. This will have to be handled in the first convert_method in the path
#but we could put a method check in place?


#All pre_process_$format methods need to handle filter_from_format
#and should faciliatate filter and sort functions
#Can we merge this with process_sam_bam?
#and maintain this as a simple wrapper process_bam, which somply sets output format
#then we can also have process_sam as another wrapper method
#This would mean moving $params support to sort_and_filter_sam(process_bam)
#and also filter_from_format support and generate_checksum

#No this will make unflitered naming mandatory for process_sam!

#Calling pre_process assumes we want to at least convert, filter or just sort
#Otherwise we can simply just use the file
#Need to support sort flag. We might not want to sort if we already have a sorted bam
#Always sort when filtering?
#

sub process_bam{
  my ($bam_file, $params) = @_;
  $params ||= {};
  assert_ref($params, 'HASH');
  return process_sam_bam($bam_file, {%$params, output_format => 'bam'});
}

sub convert_bam_to_sam{
  my ($bam_file, $params) = @_;
  $params ||= {};
  assert_ref($params, 'HASH');
  return process_sam_bam($bam_file, {%$params, output_format => 'sam'});
}

#sub process_sam would need to check_file with gz suffix!


#Need to implement optional sort_and_filter_sam here?

sub convert_sam_to_bed{
  my ($sam_file, $params) = @_;
  my $in_file;

  if(! ($in_file = check_file($sam_file, 'gz', $params)) ){
    throw("Cannot find file:\n\t$sam_file(.gz)");
  }

  (my $bed_file = $in_file) =~ s/\.sam(\.gz)*?$/.bed/;
  run_system_cmd($ENV{EFG_SRC}."/scripts/miscellaneous/sam2bed.pl -1_based -files $in_file");

  if( (exists $params->{checksum}) && $params->{checksum}){
    write_checksum($bed_file, $params);
  }
  

  return $bed_file;
}



#There are three use cases here:
#1 Cross validation
#2 Returning header opt in case of no samfile header
#3 Ensuring sam has header if ref header not specified

#The last two will happen by default, with 1 happening if both are present
#or the corss validate boolean is passed

#arguably the cross validate boolean could be dropped in favour of testing
#in the calling context, but convenient here


sub validate_sam_header {
  my $sam_bam_file     = shift;
  my $header_or_fai    = shift;
  my $xvalidate        = shift;
  my $params           = shift || {};
  assert_ref($params, 'HASH');
  my $is_fai           = ($header_or_fai =~ /\.fai$/o) ?                1 : 0;
  my $debug            = (exists $params->{debug})     ? $params->{debug} : 0;
  
  if(! defined $sam_bam_file){
    throw("Mandatory argument not specified:\t sam/bam file"); 
  }
  elsif($xvalidate && ! $header_or_fai){
     throw('The cross validation boolean has been passed, but no header/fai argument has been passed');
  }  
  
  validate_path($sam_bam_file);
  #samtools view -t
  #samtools merge -h 
  my $header_opt    = ($is_fai) ? ' -t '.$header_or_fai : ' -h '.$header_or_fai;
  my @infile_header = run_backtick_cmd("samtools view -H $sam_bam_file");  
 
  if($!){
    #$! not $@ here which will be null string
    if(! defined $header_or_fai){
      throw('Could not find an in file header or a reference file header for:'.
        "\n$sam_bam_file\n$header_or_fai\n$!");
    }
    elsif($xvalidate){
      throw('Cross validate boolean has been passed but failed to fetch a header from the reference file:'.
        "\n\t$header_or_fai");    
    }
  }
  elsif($xvalidate && ! @infile_header){
    throw('Cross validate boolean has been passed but bam/sam file has no header entries:'.
      "\n\t$sam_bam_file");  
  }
  elsif($header_or_fai){
    validate_path($header_or_fai); 
    my @ref_header;
    
    if($is_fai){
      @ref_header = run_backtick_cmd("samtools view -H $header_opt $sam_bam_file");;
    }
    else{
      @ref_header = run_backtick_cmd("cat $header_or_fai"); 
    }
    
    
    if(! @ref_header){
       throw("Reference file has no header entries:\n\t$header_or_fai");
    }
    
    if(scalar(@infile_header) > scalar(@ref_header)){
      throw("Found in file header with more entries that the reference header:\n".
        scalar(@ref_header)."\t$header_or_fai\n".scalar(@infile_header)."\t$sam_bam_file");    
    }
   
    # size difference is fine here, just so long as the file header
    # is a subset of the ref header
    my ($SN, $LN, %ref_header);
    my $hdr_cnt = 0;
    
    for(@ref_header){
      (undef, $SN, $LN) = split(/\s+/, $_);
      $ref_header{$SN} = $LN; 
    }
   
    foreach my $line(@infile_header){
      (undef, $SN, $LN) = split(/\s+/, $line);
      $hdr_cnt++;
      
      if(! exists $ref_header{$SN} ){
        throw("$SN exist in file header but not sam header/fai\n".
          $header_or_fai."\n".$sam_bam_file);  
      }
      elsif($ref_header{$SN} ne $LN){
        throw("$SN  has mismatched LN entry between file header and sam fasta index\n".
          $ref_header{$SN}."\t".$header_or_fai."\n$LN\t".$sam_bam_file);  
      }
    }
   
    # we don't need the header file as the headers completely match
    # This may result in a feamle header bing replaced with a male header
    # due to it containing the extra @SQ SN:Y line
    # actaully there can be some gender specific top level unassembled contigs too! 
    # Meaning any non-gender specific header will need to be a merge, not just the male header 
    warn scalar(@ref_header)." lines in reference header:\t$header_or_fai\n".
      $hdr_cnt." lines in file header:\t$sam_bam_file\n" if $debug >= 2;
    $header_opt = '' if $hdr_cnt == scalar(@ref_header);
  }
  
  return $header_opt;
}

# Iterates through all files.txt found in the typical goldenPath 
# directory structure
# !!! Only stores fastq !!!

sub create_and_populate_files_txt {
  my ($cfg, $helper) = @_;

  # reduced to classes (potentially) present in $table
  my $class = "'Histone','RNA','Polymerase','Transcription Factor','Open Chromatin'";
  my $table = $cfg->{tables}->{registration};

  my $table_id = $table.'_id';

  my $sql_table = "
          CREATE TABLE `$table` (
            `$table_id`         INT(10) unsigned      NOT NULL  auto_increment,
            `name`              VARCHAR(100)          NOT NULL,
            `alternate_name`    VARCHAR(100)          DEFAULT NULL,
            `antibody`          VARCHAR(64)           DEFAULT NULL,
            `assembly`          enum('hg18', 'hg19')  NOT NULL,
            `cell`              VARCHAR(64)           NOT NULL,
            `compression`       VARCHAR(10)           DEFAULT NULL,
            `control`           VARCHAR(64)           DEFAULT NULL,
            `controlId`         VARCHAR(64)           DEFAULT NULL,
            `dataType`          VARCHAR(50)           DEFAULT NULL,
            `dateUnrestricted`  DATE                  DEFAULT NULL,
            `filename`          VARCHAR(100)          NOT NULL,
            `lab`               VARCHAR(100)          NOT NULL,
            `md5sum`            CHAR(32)              DEFAULT NULL,
            `objStatus`         VARCHAR(255)          DEFAULT NULL,
            `path`              VARCHAR(255)          DEFAULT NULL,
            `replicate`         INTEGER(2)            DEFAULT NULL,
            `setType`           VARCHAR(25)           DEFAULT NULL,
            `size`              VARCHAR(5)            DEFAULT NULL,
            `treatment`         VARCHAR(50)           DEFAULT NULL,
            `type`              VARCHAR(20)           NOT     NULL,
            `cell_type`         VARCHAR(120)          DEFAULT NULL,
            `class`             ENUM($class)          DEFAULT NULL,
            `ens_lab`           VARCHAR(100)          NOT NULL,
            `feature_type`      VARCHAR(40)           DEFAULT NULL,
            `logic_name`        VARCHAR(100)          DEFAULT NULL,

            PRIMARY KEY  (`$table_id`),
            UNIQUE name_assembly_idx (`name`, `assembly`)
            ) ENGINE=MyISAM DEFAULT CHARSET=latin1 MAX_ROWS=100000000;
  ";
  # DBI->trace(2);

  $helper->execute_update(-SQL => "DROP TABLE IF EXISTS `$table`");
  $helper->execute_update(-SQL => $sql_table);


  #Make table name variable, use $cfg

  my $sql_select_by_md5sum = "
    SELECT 
      name 
    FROM
      $table
    WHERE
      md5sum = ?
  ";

  my $sql_insert_table = "
  INSERT INTO 
    $table (
      name,
      alternate_name,
      antibody,
      assembly,
      cell,
      compression,
      control,
      controlId,
      dataType,
      dateUnrestricted,
      filename,
      lab,
      md5sum,
      objStatus,
      path,
      replicate,
      setType,
      size,
      treatment,
      type,
      cell_type,
      ens_lab,
      feature_type
    )
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
  ";
  my @assemblies = qw(hg18 hg19);
  for my $assembly(@assemblies) {
    
    my $base_dir = File::Spec->catdir('goldenPath', $assembly, 'encodeDCC');
    my $dir_dcc  = File::Spec->catdir($cfg->{directories}->{files_txt}, $base_dir);

    opendir (my $labs, $dir_dcc ) or die "Error  opening dir $dir_dcc";
    while( my $lab = readdir($labs)){
      next if($lab !~ /^wgEncode/);
    
      my $path_table = File::Spec->catfile($dir_dcc, $lab, 'files.txt');
      if(-f $path_table){
        # !!! only fastq coming back !!!!
        my $files_txt = _read_files_txt($path_table);
        foreach my $name (sort keys %{$files_txt}){
          my $record = $files_txt->{$name};

          my $path = File::Spec->catfile($base_dir,$lab);
          
          my $md5sum = $record->{md5sum};
          my $alt_name = undef;

          if(defined $md5sum){
              # DBI->trace(2);
              $alt_name = 
              $helper->execute_single_result(
                -SQL      => $sql_select_by_md5sum, 
                -PARAMS   => [$md5sum], 
                -NO_ERROR => 1
                );
            }
          # use the same values as ENCODE. Ensembl specific changes are applied later  
          my $cell_type     = $record->{cell};
          my $feature_type  = $record->{antibody};
          my $ens_lab       = $record->{lab};
            # say dump_data($$table->{$name},1,1);
            # say $cell_type,
            # say $feature_type;
            # say $ens_lab;

            

            $helper->execute_update(
              -SQL    => $sql_insert_table, 
              -PARAMS => [
              [$name,                       SQL_VARCHAR],
              [$alt_name,                   SQL_VARCHAR],
              [$record->{antibody},         SQL_VARCHAR],
              [$assembly,                   SQL_VARCHAR],
              [$record->{cell},             SQL_VARCHAR],
              [$record->{compression},      SQL_VARCHAR],
              [$record->{control},          SQL_VARCHAR],
              [$record->{controlId},        SQL_VARCHAR],
              [$record->{dataType},         SQL_VARCHAR],
              [$record->{dateUnrestricted}, SQL_VARCHAR],
              [$record->{filename},         SQL_VARCHAR],
              [$record->{lab},              SQL_VARCHAR],
              [$record->{md5sum},           SQL_VARCHAR],
              [$record->{objStatus},        SQL_VARCHAR],
              [$path,                       SQL_VARCHAR],
              [$record->{replicate},        SQL_VARCHAR],
              [$record->{setType},          SQL_VARCHAR],
              [$record->{size},             SQL_VARCHAR],
              [$record->{treatment},        SQL_VARCHAR],
              [$record->{type},             SQL_VARCHAR],
              [$cell_type,                  SQL_VARCHAR],
              [$ens_lab,                    SQL_VARCHAR],
              [$feature_type,               SQL_VARCHAR],
              ]);
  # die;
        }
      }
      else{
        say "$path_table not available";
      }
    }
    closedir($labs);
  }
}


=head2 modify_files_txt_for_regulation

  Arg 1  : HASH - Configuration
  Arg 2  : Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor
  Returntype  : None
  Exceptions  : Throws if non-optional arguments are missing
  Description : Downloads all files.txt and md5sum.txt from standard ENCODE directory structure.

=cut
  
sub modify_files_txt_for_regulation {
  my ($cfg, $helper) = @_;
  
  warn "\n\n++++++ These modifications should be regularly reviewed. Especially assigning class HISTONE ++++++\n";
  my $table = $cfg->{tables}->{registration};

  
  if($table ne 'files_txt'){
   warn "These modifications are specific to ENCODE $table";
  }
  
  say "\n\n+++++++++++++++++++ Modifications to $table: FeatureType +++++++++++++++++++\n";

  # Antibodies "CTCF_(SC-15914)" and "CTCF_(SC-5916)" to FeatureType "CTCF"
  # no discinct as we execute_into_hash
  # Be careful, this will also do wrong shortenings like ZNF-MIZD-CP1_(ab65767) to ZNF-MIZD-CP1
  # These are addressed individually later
  my $sql_select_antibody = "
    SELECT
      antibody,
      1
    FROM
      $table
    WHERE
      antibody LIKE '%_(%)'
  ";

  my $tmp = $helper->execute_into_hash(-SQL => $sql_select_antibody);
  
  my $ab_to_ft = {};
  foreach my $antibody (sort keys %{$tmp}){
    # CTCF_(SC-15914) or  Pol2(phosphoS2)
    $antibody =~ /^(.*?)_?\(/;
    $ab_to_ft->{$antibody} = $1;
  }

  my $sql_update_feature_type = "
    UPDATE
      $table
    SET
      feature_type = ?
    WHERE
      antibody = ?
  ";

  foreach my $antibody (sort keys %{$ab_to_ft}){
    my $feature_type = $ab_to_ft->{$antibody};
    say "UPDATE $table SET feature_type = $feature_type\tWHERE antibody = $antibody";
    $helper->execute_update(
      -SQL    =>  $sql_update_feature_type,
      -PARAMS => [$feature_type, $antibody],
      );
  }

  say "\n\n+++++++++++++++++++ Modifications to $table: Miscellaneous +++++++++++++++++++\n";

  my @sqls;

  # replicate
  push(@sqls, "UPDATE $table SET replicate = 1 WHERE replicate IS NULL");

  # treatment
  push(@sqls, "UPDATE $table SET treatment = 'None' WHERE treatment IS NULL");

  # setType
  push(@sqls, "UPDATE files_txt SET setType = 'input' WHERE feature_type = 'Input'   AND setType = 'exp'");
  push(@sqls, "UPDATE files_txt SET setType = 'input' WHERE antibody     = 'Control' AND setType = 'exp'");

  # antibody
  push(@sqls, "UPDATE $table SET antibody = 'DNase' WHERE name LIKE '%dnase%'");

  # cell_type
  push(@sqls, "UPDATE $table SET cell_type = 'Monocytes-CD14+' WHERE cell = 'Monocytes-CD14+_RO01746'");
  push(@sqls, "UPDATE $table SET cell_type = 'DND-41'          WHERE cell = 'Dnd41'");
  push(@sqls, "UPDATE $table SET cell_type = 'H1ESC'           WHERE cell = 'H1-hESC'");

  #ens_lab
  push(@sqls, "UPDATE $table SET ens_lab = 'UTA' WHERE lab = 'UT-A'");

  #feature_type
  push(@sqls, "UPDATE $table SET feature_type = 'H2AF'  WHERE antibody = 'H2A.Z'");
  push(@sqls, "UPDATE $table SET feature_type = 'DNase1' WHERE antibody = 'DNase'");
  push(@sqls, "UPDATE $table SET feature_type = 'CTCF'   WHERE antibody like 'CTCF_%'");
  push(@sqls, "UPDATE $table SET feature_type = 'PolII'  WHERE antibody like 'Pol2%'");
  push(@sqls, "UPDATE $table SET feature_type = 'PolIII' WHERE antibody like 'Pol3%'");

  # http://www.ensembl.org/Homo_sapiens/Gene/Summary?db=core;g=ENSG00000087510; 
  push(@sqls, "UPDATE $table SET feature_type = 'TFAP2C' WHERE feature_type = 'AP-2gamma' ");
  # http://moma.ki.au.dk/genome-mirror/cgi-bin/hgEncodeVocab?ra=encode%2Fcv.ra&target=%22CHD4_Mi2%22
  push(@sqls, "UPDATE $table SET feature_type = 'CHD4'   WHERE antibody = 'CHD4_Mi2' ");
  # http://www.factorbook.org/mediawiki/index.php/ERalpha_a
  push(@sqls, "UPDATE $table SET feature_type = 'ESR1'   WHERE antibody = 'ERalpha_a' ");
  push(@sqls, "UPDATE $table SET feature_type = 'EGR1'   WHERE antibody = 'Egr-1' ");
  push(@sqls, "UPDATE $table SET feature_type = 'GATA2'  WHERE antibody = 'GATA-2' ");
  # http://epigenome.cbrc.jp/cgi-bin/hgEncodeVocab?ra=encode%2Fcv.ra&target=%22HA-E2F1%22
  push(@sqls, "UPDATE $table SET feature_type = 'E2F1'   WHERE antibody = 'HA-E2F1' ");
  # http://moma.ki.au.dk/genome-mirror/cgi-bin/hgEncodeVocab?ra=encode%2Fcv.ra&target=%22NCoR%22
  push(@sqls, "UPDATE $table SET feature_type = 'NCOR1'  WHERE antibody = 'NCoR' ");
  # http://www.noncode.org/cgi-bin/hgEncodeVocab?ra=encode%2Fcv.ra&target=%22p300%22
  push(@sqls, "UPDATE $table SET feature_type = 'EP300'  WHERE antibody = 'P300_KAT3B' ");
  push(@sqls, "UPDATE $table SET feature_type = 'PAX5'   WHERE antibody like 'PAX5-%' ");
  push(@sqls, "UPDATE $table SET feature_type = 'SIN3A'  WHERE antibody = 'Sin3Ak-20' ");
  # http://epigenome.cbrc.jp/cgi-bin/hgEncodeVocab?ra=encode%2Fcv.ra&target=%22TCF7L2%22
  push(@sqls, "UPDATE $table SET feature_type = 'TCF7L2' WHERE antibody = 'TCF7L2_C9B9_(2565)' ");
  push(@sqls, "UPDATE $table SET feature_type = 'USF1'   WHERE antibody = 'USF-1' ");
  # http://www.noncode.org/cgi-bin/hgEncodeVocab?ra=encode%2Fcv.ra&target=%22ZNF-MIZD-CP1_(ab65767)%22
  push(@sqls, "UPDATE $table SET feature_type = 'ZMIZ1'  WHERE antibody = 'ZNF-MIZD-CP1_(ab65767)' ");

  # See also: http://genome.ucsc.edu/cgi-bin/hgEncodeVocab?ra=encode/cv.ra&type=control
  push(@sqls, "UPDATE $table SET feature_type = 'WCE'    WHERE setType = 'Input'");

  # logic_name
  push(@sqls, "UPDATE $table SET logic_name = 'ChIP-Seq'  WHERE dataType = 'ChipSeq'");
  push(@sqls, "UPDATE $table SET logic_name = 'DNase-Seq' WHERE dataType = 'DnaseSeq'");
  push(@sqls, "UPDATE $table SET logic_name = 'FAIRE'     WHERE dataType = 'FaireSeq'");

  # class
  # This is true for the ENCODE 2011 data freeze
  push(@sqls, "UPDATE $table SET class = 'Histone'                WHERE dataType = 'ChipSeq' AND feature_type LIKE 'H%K%'");
  push(@sqls, "UPDATE $table SET class = 'Polymerase'             WHERE dataType = 'ChipSeq' AND feature_type IN ('PolII', 'PolIII')  ");
  push(@sqls, "UPDATE $table SET class = 'Open Chromatin'         WHERE dataType = 'DnaseSeq'");
  push(@sqls, "UPDATE $table SET class = 'Transcription Factor'   WHERE dataType = 'ChipSeq' AND feature_type != 'WCE' AND class is NULL");
  push(@sqls, "UPDATE $table SET class = 'Transcription Factor'   WHERE antibody = 'H2A.Z'");


  for my $sql(@sqls){
    say $sql;
    $helper->execute_update(-SQL => $sql);
  }
}
 
=head2 load_experiments

  Arg 1  : HASH - Configuration
  Arg 2  : Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor
  Arg 3  : HASH - Constraints
  Arg 4  : [Optional] ARRAY of Bio::EnsEMBL::Funcgen::Experiment
  Arg 5  : [Optional] ARRAY of Bio::EnsEMBL::Funcgen::CellType
  Arg 6  : [Optional] ARRAY of Bio::EnsEMBL::Funcgen::FeatureType
  
  Returntype  : None
  Exceptions  : Throws if non-optional arguments are missing
  Description : Downloads all files.txt and md5sum.txt from standard ENCODE directory structure.

=cut


sub load_experiments_into_tracking_db {
  my ($cfg, $db, $constraints, $exp_data, $cell_type_data, $feature_type_data) = @_;

  assert_ref($cfg, 'HASH');
  assert_ref($db, 'Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor');
  assert_ref($constraints, 'HASH');

  my $helper  = Bio::EnsEMBL::Utils::SqlHelper->new( -DB_CONNECTION => $db->dbc );
  
  my $exp_a = $db->get_ExperimentAdaptor;
  my $eg_a  = $db->get_ExperimentalGroupAdaptor;

  my $ct_a = $db->get_CellTypeAdaptor;
  my $ft_a = $db->get_FeatureTypeAdaptor;

  my $anal_adaptor = $db->get_AnalysisAdaptor;
  my $iss_a = $db->get_InputSubsetAdaptor;

  my $tr_a  = Bio::EnsEMBL::Funcgen::DBSQL::TrackingAdaptor->new(
        -user       => $db->dbc->user,
        -pass       => $db->dbc->pass,
        -host       => $db->dbc->host,
        -port       => $db->dbc->port,
        -dbname     => $db->dbc->dbname,
        -dnadb_name => $db->dnadb_name,
  );


  my $sql = "
    SELECT
      cell_type,
      dateUnrestricted,
      ens_lab,
      feature_type,
      filename,
      logic_name,
      md5sum,
      name,
      objStatus,
      path,
      replicate
    FROM
      files_txt
  ";
  # Adding constraints
  if(defined $constraints){
    $sql .= 'WHERE ';

   for my $cst(@$constraints){
     my $table = shift @$cst;
     my $values = join(', ', map { qq/"$_"/ } @$cst);
     $sql .= "$table IN ($values)";
     $sql .= " AND\n " if($cst != $constraints->[-1]);
   }  
  }
  # say $sql;
  # DBI->trace(2);
  my $files = $helper->execute(
    -SQL      => $sql,
    -CALLBACK => sub {
      my @row = @{shift @_};
      return {
        cell_type         => $row[0],
        dateUnrestricted  => $row[1],
        ens_lab           => $row[2],
        feature_type      => $row[3],
        filename          => $row[4],
        logic_name        => $row[5],
        md5sum            => $row[6],
        name              => $row[7],
        objStatus         => $row[8],
        path              => $row[9],
        replicate         => $row[10],
      }
    } 
  );
      # say dump_data($files,1,1);
  # die;
  foreach my $file (@$files){
    my $ft_name  = $file->{feature_type};
    my $ct_name  = $file->{cell_type};
    

    # type determines the style of the experiment name
    my $type = $cfg->{general}->{type};
    
    my $exp_name;
    if($type eq 'ENCODE'){
      $exp_name = $ct_name .'_' . $ft_name . '_' . $type . '_' . $file->{ens_lab};
    }
    else{
      throw "'$type' not implemted."; 
    }

    # CellType
    my $ct  = $ct_a ->fetch_by_name($ct_name);
    if(!$ct){
      $ct =_store_cell_feature_type ($db, $helper, 'CellType', $ct_name, $cell_type_data);
    }

    # FeatureType
    my $ft  = $ft_a ->fetch_by_name($ft_name); 
    if(!$ft){
      $ft = _store_cell_feature_type ($db, $helper, 'FeatureType', $ft_name, $feature_type_data);
    }

    # Implement store method
    my $anal = $anal_adaptor->fetch_by_logic_name($file->{logic_name});
    if(not $anal){
      warn "Analysis $file->{logic_name} not in DB. Skipping...";
      next;
    };

    # Risky me thinks
    my $control = 0; 
    $control = 1 if($ft_name eq "WCE"); 


    my $exp = $exp_a->fetch_by_name($exp_name);
    my $iss = $iss_a->fetch_by_name($file->{name}, $exp);

    # Check if InputSubset is already linked to a different Experiment
    if(!$exp and $iss){
      if($exp_name ne $iss->experiment->name){
        throw($iss->name . ' is linked to ' . $iss->experiment->name . ' not ' . $exp_name );
      }
    }

    if(! $exp){
      my $eg = $eg_a->fetch_by_name($exp_data->{experimental_group});
     
      my $exp_new = Bio::EnsEMBL::Funcgen::Experiment->new
                       (
                        -cell_type           => $ct,
                        -experimental_group  => $eg,
                        -feature_type        => $ft,
                        -date                => DateTime::Format::MySQL->format_datetime(DateTime->now),
                        -description         => $exp_data->{description},
                        -name                => $exp_name,
                       );
       ($exp) = @{$exp_a->store($exp_new)};
       say "Added Experiment " . $exp->name . ' [dbID: ' . $exp->dbID .']';
    }

    if(!$iss){
      my $iss_new = Bio::EnsEMBL::Funcgen::InputSubset->new
                     (
                      -cell_type     => $ct,
                      -experiment    => $exp,
                      -feature_type  => $ft,
                      -analysis      => $anal,
                      -is_control    => $control,
                      -name          => $file->{name},
                      -replicate     => $file->{replicate},
                     );
      ($iss) = @{$iss_a->store($iss_new)};
      say "Added InputSubset " . $iss->name . ' [dbID: ' .$iss->dbID .']';

      my $web_url = File::Spec->catfile($cfg->{urls}->{base}, $file->{path}, $file->{filename});
      # catfile replaces // with /
      $web_url =~ s!:/!://!;
      
      if($file->{objStatus}){
        if($file->{objStatus} !~ /^[revoked|replaced]/){
          throw('Status: '. $file->{objStatus}. ' not implemted');
        }
      }

      my $tr_info->{info} = {
        availability_date => 1,
        download_url      => $web_url,
        download_date     => undef,
        local_url         => undef,
        md5sum            => $file->{md5sum},
        notes             => $file->{objStatus},
      };
      my $out = $tr_a->store_tracking_info($iss, $tr_info);
      say "Added TrackingInfo for " . $iss->name . ' [dbID: ' .$iss->dbID .']';

    }
  }
}



=head2 _download_all_files_txt

  Argument 1  : HASH - configuration
  Returntype  : None 
  Exceptions  : Missing config, inaccessible remote server or local directories
  Description : Downloads all files.txt and md5sum.txt from standard ENCODE directory structure.

=cut

sub download_all_files_txt {
  my ($cfg) = @_;

  my $server = $cfg->{urls}->{base};
  my $base_data_dir = $cfg->{directories}->{data};


  my $ftp;
  $ftp = Net::FTP->new($server, Debug => 0) or throw "Cannot connect to $server: $@";
  $ftp->login("anonymous",'-anonymous@')    or throw "Cannot login ", $ftp->message;
  
  my @assemblies = qw(hg18 hg19);
  for my $assembly(@assemblies){
    my $dir_dcc = File::Spec->catdir('/', 'goldenPath', $assembly, 'encodeDCC');
    $ftp->cwd($dir_dcc) or throw "Cannot cd to $dir_dcc ", $ftp->message;
    my $labs = $ftp->ls;
    for my $lab(@$labs){
      next if($lab !~ /^wgEncode/);
      my $dir_lab = File::Spec->catdir($dir_dcc, $lab);
      $ftp->cwd($dir_lab) or throw "Cannot cd to $dir_lab", $ftp->message;
      my $local_dir = File::Spec->catdir($base_data_dir, $dir_lab);
      make_path($local_dir);
      
      my $local_files_txt  = File::Spec->catfile($local_dir, 'files.txt');
      $ftp->get('files.txt', $local_files_txt) 
      or warn "No files.txt in $dir_lab\tFTP message:", $ftp->message;
      $local_files_txt =~ s/files\.txt/md5sum.txt/;
      $ftp->get('md5sum.txt', $local_files_txt) 
      or warn "No md5sum.txt in $dir_lab\tFTP message:", $ftp->message;
    }
  }
}

=head2 _store_cell_feature_type

  Argument 1  : Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor
  Argument 2  : Bio::EnsEMBL::Utils::SqlHelper
  Argument 3  : String - CellType or FeatureType
  Argument 4  : String - Name used as key in $data HASH
  Argument 5  : HASHREF - containing Cell or FeatureType objects
  Returntype  : Bio::EnsEMBL::Funcgen::CellType or Bio::EnsEMBL::Funcgen::FeatureType
  Exceptions  : Missing arguments
  Description : PRIVATE - stores Cell or FeatureType

=cut

sub _store_cell_feature_type {
  my ($db, $helper, $type, $name, $data) = @_;

  assert_ref($db,     'Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor');
  assert_ref($helper, 'Bio::EnsEMBL::Utils::SqlHelper');

  if($type !~ /[CellType|FeatureType]/){
    throw("$type must be CellType or FeatureType");
  }
  if(! $data->{$name}){
    throw("$type $name not defined in $type data.");
  }
  if(! defined $data){
    throw("$type $name is not in db and $type data not defined.");
  }

  my $adaptor;
  $adaptor = $db->get_CellTypeAdaptor    if ($type eq 'CellType');
  $adaptor = $db->get_FeatureTypeAdaptor if ($type eq 'FeatureType');
  my ($object) = @{$adaptor->store($data->{$name})};
  say "Added $type $name";
  return $object;
}



1;

