#!/bin/sh

# Copyright [1999-2014] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


#. ~/src/ensembl-efg/scripts/.efg

USER=$1
shift
PASS=$1
shift


species=homo_sapiens
release=87
genome_version=37
team=funcgen
dbname="mnuhn_regbuildDone_homo_sapiens_funcgen_87_37"
#dbname="dev_${species}_${team}_${release}_${genome_version}"
host=ens-genomics2
port=3306
dnadb_host=ens-staging-grch37
dnadb_name="${species}_core_${release}_37"
dnadb_port=3306
debug_file="${HOME}/logs/vista_ex_features"
log_file="${HOME}/logs/vista_${dbname}"

species=homo_sapiens

cmd="perl $EFG_SRC/scripts/external_features/load_external_features.pl\
	-type  Vista\
	-species $species\
	-port $port\
	-user $USER\
	-host $host\
	-clobber\
	-dbname $dbname\
	-pass $PASS\
	-dnadb_host $dnadb_host\
	-dnadb_name $dnadb_name\
	-dnadb_port $dnadb_port\
        -tee\
        -debugfile $debug_file\
        -logfile $log_file\
        $@"

echo $cmd 
$cmd

exit

#        -old_assembly GRCh37\
#        -new_assembly GRCh38\
