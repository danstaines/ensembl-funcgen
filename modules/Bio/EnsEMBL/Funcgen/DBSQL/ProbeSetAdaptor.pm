#
# Ensembl module for Bio::EnsEMBL::Funcgen::DBSQL::ProbeSetAdaptor
#
# You may distribute this module under the same terms as Perl itself

=head1 NAME

Bio::EnsEMBL::DBSQL::ProbeSetAdaptor - A database adaptor for fetching and
storing ProbeSet objects.

=head1 SYNOPSIS

my $opa = $db->get_ProbeSetAdaptor();

my $probeset = $opa->fetch_by_array_probeset_name('Array-1', 'ProbeSet-1');

=head1 DESCRIPTION

The ProbeSetAdaptor is a database adaptor for storing and retrieving
ProbeSet objects.

This module is part of the Ensembl project: http://www.ensembl.org/

=head1 CONTACT

Post comments or questions to the Ensembl development list: ensembl-dev@ebi.ac.uk

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Funcgen::DBSQL::ProbeSetAdaptor;

use Bio::EnsEMBL::Utils::Exception qw( throw warning );
use Bio::EnsEMBL::Funcgen::ProbeSet;
use Bio::EnsEMBL::DBSQL::BaseAdaptor;

use vars qw(@ISA);
@ISA = qw(Bio::EnsEMBL::Funcgen::DBSQL::BaseAdaptor);

my @true_tables = (['probe_set', 'ps']);
my @tables = @true_tables;


=head2 fetch_by_array_probeset_name

  Arg [1]    : string - name of array
  Arg [2]    : string - name of probeset
  Example    : my $probeset = $opsa->fetch_by_array_probeset_name('Array-1', 'Probeset-1');
  Description: Returns a probeset given the array name and probeset name
               This will uniquely define a probeset. Only one
			   probeset is ever returned.
  Returntype : Bio::EnsEMBL::ProbeSet
  Exceptions : None
  Caller     : General
  Status     : At Risk

=cut

sub fetch_by_array_probeset_name{
	my ($self, $array_name, $probeset_name) = @_;
	
	if(! ($array_name && $probeset_name)){
	  throw('Must provide array_name and probeset_name arguments'); 
	}
	

	#Extend query tables
	push @tables, (['probe', 'p'], ['array_chip', 'ac'], ['array', 'a']);
	
	#Extend query and group
	#This needs generic_fetch_bind_param
	my $constraint = 'ps.name= ? AND ps.probe_set_id=p.probe_set_id AND p.array_chip_id=ac.array_chip_id AND ac.array_id=a.array_id AND a.name= ? GROUP by ps.probe_set_id';
	
	#my $constraint = 'ps.name="'.$probeset_name.'" and ps.probe_set_id=p.probe_set_id and p.array_chip_id=ac.array_chip_id and ac.array_id=a.array_id and a.name="'.$array_name.'" group by ps.probe_set_id';
	
	$self->bind_param_generic_fetch($probeset_name,SQL_VARCHAR);
	$self->bind_param_generic_fetch($array_name,SQL_VARCHAR);
	my $pset =  $self->generic_fetch($constraint)->[0];
	
	#Reset tables
	@tables = @true_tables;
  
	return $pset;

}

=head2 fetch_by_ProbeFeature

  Arg [1]    : Bio::EnsEMBL::ProbeFeature
  Example    : my $probeset = $opsa->fetch_by_ProbeFeature($feature);
  Description: Returns the probeset that created a particular feature.
  Returntype : Bio::EnsEMBL::ProbeSet
  Exceptions : Throws if argument is not a Bio::EnsEMBL::ProbeFeature object
  Caller     : General
  Status     : At Risk

=cut

#This is a good candidate for complex query extension
#As we will most likely want the probe also if we are fetching the ProbeSet
#For a given feature.
#We could also set the probe in the ProbeFeature object, so we don't re-query
#should the user use ProbeFeature->get_probe
#This is also a case for passing the array name to automatically set
#the probe name? As we will likely know the array name beforehand.

#Could we also bring back annotations for this Probe/ProbeSet?
#

sub fetch_by_ProbeFeature {
	my ($self, $pfeature) = @_;
	
	$self->db->is_stored_and_valid('Bio::EnsEMBL::Funcgen::ProbeFeature', $pfeature);

	#Extend query tables
	push @tables, (['probe', 'p']);
	
	#Extend query and group
	my $pset =  $self->generic_fetch('p.probe_id='.$pfeature->probe_id.' and p.probe_set_id=ps.probe_set_id GROUP by ps.probe_set_id')->[0];

	#Reset tables
	@tables = @true_tables;
  
	return $pset;


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

  	return @tables;
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

  #remove xref_id and use xref tables
  return qw( ps.probe_set_id ps.name ps.size ps.family);

}

=head2 _objs_from_sth

  Arg [1]    : DBI statement handle object
  Example    : None
  Description: PROTECTED implementation of superclass abstract method.
               Creates ProbeSet objects from an executed DBI statement
			   handle.
  Returntype : Listref of Bio::EnsEMBL::ProbeSet objects
  Exceptions : None
  Caller     : Internal
  Status     : At Risk

=cut

sub _objs_from_sth {
	my ($self, $sth) = @_;

	my (@result, $current_dbid, $probeset_id, $name, $size, $family);
	my ($array, %array_cache);
	
	$sth->bind_columns( \$probeset_id,  \$name, \$size, \$family);
	

	#do not have array_chip adaptor
	#use array adaptor directly
	#how are we going ot handle the cache here?????

	my $probeset;
	while ( $sth->fetch() ) {
		#$array = $array_cache{$array_id} || $self->db->get_ArrayAdaptor()->fetch_by_dbID($array_id);

		#This is nesting array object in probeset!
		#$array = $array_cache{$arraychip_id} || $self->db->get_ArrayAdaptor()->fetch_by_array_chip_dbID($arraychip_id);

		#Is this required? or should we lazy load this?
		#Should we also do the same for probe i.e. nest or lazy load probeset
		#Setting here prevents, multiple queries, but if we store the array cache in the adaptor we can overcome this
		#danger of eating memory here, but it's onld the same as would be used for generating all the probesets
		#what about clearing the cache?
		#also as multiple array_chips map to same array, cache would be redundant
		#need to store only once and reference.
		#have array_cache and arraychip_map
		#arraychip_map would give array_id which would be key in array cache
		#This is kinda reinventing the wheel, but reducing queries and redundancy of global cache
		#cache would never be populated if method not called
		#there for reducing calls and memory, increasing speed of generation/initation
		#if method were called
		#would slightly slow down processing, and would slightly increase memory as cache(small as non-redundant)
		#and map hashes would persist

		#Do we even need this????

		#warn("Can we lazy load the arrays from a global cache, which is itself lazy loaded and non-redundant?\n");

		
		#this current id stuff is due to lack of probeset table in core
		#if (!$current_dbid || $current_dbid != $probeset_id) {
		  
		  # New probeset
		  $probeset = Bio::EnsEMBL::Funcgen::ProbeSet->new
			(
			 -dbID         => $probeset_id,
			 -name         => $name,
			 -size         => $size,
			 #			 -array        => $array,
			 -family       => $family,
			 -adaptor     => $self,
			);
		push @result, $probeset;

			#$current_dbid = $probeset_id;
		#} else {
		#	# Extend existing probe
		#	$probe->add_Array_probename($array, $name);
		#}
	}
	return \@result;
}

=head2 store

  Arg [1]    : List of Bio::EnsEMBL::Funcgen::ProbeSet objects
  Example    : $opa->store($probeset1, $probeset2, $probeset3);
  Description: Stores given ProbeSet objects in the database. Should only be
               called once per probe because no checks are made for duplicates.??? It certainly looks like there is :/
			   Sets dbID and adaptor on the objects that it stores.
  Returntype : None
  Exceptions : Throws if arguments are not Probe objects
  Caller     : General
  Status     : At Risk

=cut

sub store {
	my ($self, @probesets) = @_;

	my ($sth, $array);

	if (scalar @probesets == 0) {
		throw('Must call store with a list of Probe objects');
	}

	my $db = $self->db();

	PROBESET: foreach my $probeset (@probesets) {

		if ( !ref $probeset || !$probeset->isa('Bio::EnsEMBL::Funcgen::ProbeSet') ) {
			throw('ProbeSet must be an ProbeSet object');
		}

		if ( $probeset->is_stored($db) ) {
			warning('ProbeSet [' . $probeset->dbID() . '] is already stored in the database');
			next PROBESET;
		}
		
		$sth = $self->prepare("
					INSERT INTO probe_set
					(name, size, family)
					VALUES (?, ?, ?)
				");
		$sth->bind_param(1, $probeset->name(),                     SQL_VARCHAR);
		$sth->bind_param(2, $probeset->size(),                     SQL_INTEGER);
		$sth->bind_param(3, $probeset->family(),                   SQL_VARCHAR);
		
		$sth->execute();
		my $dbID = $sth->{'mysql_insertid'};
		$probeset->dbID($dbID);
		$probeset->adaptor($self);
	  }

	return \@probesets;
}

=head2 list_dbIDs

  Arg [1]    : none
  Example    : my @ps_ids = @{$opa->list_dbIDs()};
  Description: Gets an array of internal IDs for all ProbeSet objects in the
               current database.
  Returntype : List of ints
  Exceptions : None
  Caller     : ?
  Status     : Medium Risk

=cut

sub list_dbIDs {
	my ($self) = @_;

	return $self->_list_dbIDs('probe_set');
}

1;

