#!/bin/bash

data_directory=/nfs/production/panda/ensembl/funcgen/api_course_material/data/WiggleTools

wiggletools \
  write \
    ./sums_deleteme.bw \
  sum  \
    $data_directory/Monocytes_CD14_PB_Roadmap_H3K27ac_ChIP-Seq_Roadmap85_bwa_samse.bw  \
    $data_directory/Lung_H3K27ac_ChIP-Seq_Roadmap85_bwa_samse.bw  \
    $data_directory/Fetal_Muscle_Leg_H3K27ac_ChIP-Seq_Roadmap85_bwa_samse.bw \
    $data_directory/Aorta_H3K27ac_ChIP-Seq_Roadmap85_bwa_samse.bw \
    $data_directory/K562_H3K27ac_ChIP-Seq_ENCODE85_bwa_samse.bw


