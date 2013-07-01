#!/bin/bash

VERSION="0.0"

if [[ ! -s ${ANTSPATH}/antsRegistration ]]; then
  echo we cant find the antsRegistration program -- does not seem to exist.  please \(re\)define \$ANTSPATH in your environment.
  exit
fi
if [[ ! -s ${ANTSPATH}/antsApplyTransforms ]]; then
  echo we cant find the antsApplyTransforms program -- does not seem to exist.  please \(re\)define \$ANTSPATH in your environment.
  exit
fi

function Usage {
    cat <<USAGE

`basename $0` performs restration between a scalar image and a T1 image:

Usage:

`basename $0` -d imageDimension
              -r anatomicalT1image (brain or whole-head, depending on modality)
              -i scalarImageToMatch
              -x anatomicalT1brainmask
              -t transformType (0=rigid, 1=affine, 2=rigid+small_def, 3=affine+small_def)
              -w prefix of T1 to template transform

           
              <OPTARGS>
              -o outputPrefix
              -l labels in template space
              -a auxiliary scalar image/s to warp to template
              -b auxiliary dt image to warp to template

Example:

  bash $0 -d 3 -i pcasl_control.nii.gz -r t1.nii.gz -x t1_mask.nii.gz -a cbf.nii.gz -l template_aal.nii.gz -w t12template_ -t 2 -o output

Required arguments:

We use *intensity* to denote the original anatomical image of the brain.

We use *probability* to denote a probability image with values in range 0 to 1.

We use *label* to denote a label image with values in range 0 to N.

     -d:  Image dimension                       2 or 3 (for 2- or 3-dimensional image)
     -i:  Anatomical image                      Structural *intensity* scalar image such as avgerage bold, averge dwi, etc. 
     -r:  T1 Anatomical image                   Structural *intensity* image, typically T1.  
     -x:  Brain extraction probability mask     Brain *probability* mask created using e.g. LPBA40 labels which
                                                have brain masks defined, and warped to anatomical template and
                                                averaged resulting in a probability image.
     -w:  T1 to template transform prefix       Prefix for transform files that map T1 (-r) to the template space
                                                -p labelsPriors%02d.nii.gz.
     -o:  Output prefix                         The following images are created:
                                                  * ${OUTPUT_PREFIX}N4Corrected.${OUTPUT_SUFFIX}


Optional arguments:

     -t:  TranformType                          0=rigid, 1=affine, 2=rigid+small_def, 3=affine+small_def [default=1]
     -l:  Brain segmentation priors             Anatomical *label* image in template space to be mapped to modality space
     -a:  Auxiliary scalar files                Additional scalar files to warp to template space
     -b:  DT image                              DTI to warp to template space
      

USAGE
    exit 1
}

echoParameters() {
    cat <<PARAMETERS

    Using antsIntramodalityInterSubject with the following arguments:
      image dimension         = ${DIMENSION}
      anatomical image        = ${BRAIN}
      brain template          = ${TEMPLATE_BRAIN}
      brain template mask     = ${TEMPLATE_MASK}
      output prefix           = ${OUTPUT_PREFIX}
      template labels         = ${TEMPLATE_LABELS}
      auxiliary images        = ${AUX_IMAGES[@]}
      diffusion tensor image  = ${DTI}

    ANTs parameters:
      metric                  = ${ANTS_METRIC}[fixedImage,movingImage,${ANTS_METRIC_PARAMS}]
      regularization          = ${ANTS_REGULARIZATION}
      transformation          = ${ANTS_TRANSFORMATION}
      max iterations          = ${ANTS_MAX_ITERATIONS}

PARAMETERS
}

# Echos a command to both stdout and stderr, then runs it
function logCmd() {
  cmd="$*"
  echo "BEGIN >>>>>>>>>>>>>>>>>>>>"
  echo $cmd
  $cmd
  echo "END   <<<<<<<<<<<<<<<<<<<<"
  echo
  echo
}

################################################################################
#
# Main routine
#
################################################################################

HOSTNAME=`hostname`
DATE=`date`

CURRENT_DIR=`pwd`/
OUTPUT_DIR=${CURRENT_DIR}/tmp$RANDOM/
OUTPUT_PREFIX=${OUTPUT_DIR}/tmp
OUTPUT_SUFFIX="nii.gz"

KEEP_TMP_IMAGES=0

DIMENSION=3

BRAIN=""
AUX_IMAGES=()
TEMPLATE_TRANSFORM=""
TEMPLATE_BRAIN=""
TEMPLATE_MASK=""
TEMPLATE_LABELS=""
TRANSFORM_TYPE="0"
DTI=""


################################################################################
#
# Programs and their parameters
#
################################################################################

ANTS=${ANTSPATH}antsRegistration
ANTS_MAX_ITERATIONS="100x100x70x20"
ANTS_TRANSFORMATION="SyN[0.1,3,0]"
ANTS_LINEAR_METRIC_PARAMS="1,32,Regular,0.25"
ANTS_LINEAR_CONVERGENCE="[1000x500x250x100,1e-8,10]"
ANTS_METRIC="CC"
ANTS_METRIC_PARAMS="1,4"

WARP=${ANTSPATH}antsApplyTransforms


if [[ $# -lt 3 ]] ; then
  Usage >&2
  exit 1
else
  while getopts "a:b:r:x:d:h:i:l:o:t:w:" OPT
    do
      case $OPT in
          a) # auxiliary scalar images
              AUX_IMAGES[${#AUX_IMAGES[@]}]=$OPTARG
              ;;
          b) #brain extraction registration mask
              DTI=$OPTARG
              ;;
          d) #dimensions
              DIMENSION=$OPTARG
              if [[ ${DIMENSION} -gt 3 || ${DIMENSION} -lt 2 ]];
              then
                  echo " Error:  ImageDimension must be 2 or 3 "
                  exit 1
              fi
              ;;
          r) #brain extraction anatomical image
              TEMPLATE_BRAIN=$OPTARG
              ;;
          x) #brain extraction registration mask
              TEMPLATE_MASK=$OPTARG
              ;;
          l) #brain extraction registration mask
              TEMPLATE_LABELS=$OPTARG
              ;;
          h) #help
              Usage >&2
              exit 0
              ;;
          i) #max_iterations
              BRAIN=$OPTARG
              ;;
          o) #output prefix
              OUTPUT_PREFIX=$OPTARG
              ;;
          w) #template registration image
              TEMPLATE_TRANSFORM=$OPTARG
              ;;
          t) #atropos prior weight
              TRANSFORM_TYPE=$OPTARG
              ;;
          *) # getopts issues an error message
              echo "ERROR:  unrecognized option -$OPT $OPTARG"
              exit 1
              ;;
      esac
  done
fi

################################################################################
#
# Preliminaries:
#  1. Check existence of inputs
#  2. Figure out output directory and mkdir if necessary
#  3. See if $REGISTRATION_TEMPLATE is the same as $BRAIN_TEMPLATE
#
################################################################################

for (( i = 0; i < ${#AUX_IMAGES[@]}; i++ ))
  do
  if [[ ! -f ${AUX_IMAGES[$i]} ]];
    then
      echo "The specified auxiliary image \"${AUX_IMAGES[$i]}\" does not exist."
      exit 1
    fi
done

if [[ ! -f ${TEMPLATE_BRAIN} ]];
  then
    echo "The extraction template doesn't exist:"
    echo "   $TEMPLATE_BRAIN"
    exit 1
  fi
if [[ ! -f ${TEMPLATE_MASK} ]];
  then
    echo "The brain extraction prior doesn't exist:"
    echo "   $TEMPLATE_MASK"
    exit 1
  fi
if [[ ! -f ${BRAIN} ]];
  then
    echo "The scalar brain:"
    echo "   $BRAIN"
    exit 1
  fi

OUTPUT_DIR=${OUTPUT_PREFIX%\/*}
if [[ ! -d $OUTPUT_DIR ]];
  then
    echo "The output directory \"$OUTPUT_DIR\" does not exist. Making it."
    mkdir -p $OUTPUT_DIR
  fi

ANTS=${ANTSPATH}antsRegistration
ANTS_MAX_ITERATIONS="100x100x70x20"
ANTS_TRANSFORMATION="SyN[0.1,3,0]"
ANTS_LINEAR_METRIC_PARAMS="1,32,Regular,0.25"
ANTS_LINEAR_CONVERGENCE="[1000x500x250x100,1e-8,10]"
ANTS_METRIC="CC"
ANTS_METRIC_PARAMS="1,4"

if [ ${TRANFORM_TYPE} -eq 0 ];
then
    echo "=========== RIGID =============="
fi

echoParameters >&2

echo "---------------------  Running `basename $0` on $HOSTNAME  ---------------------"

time_start=`date +%s`

exit 0


################################################################################
#
# Output images
#
################################################################################

BRAIN_EXTRACTION_MASK=${OUTPUT_PREFIX}BrainExtractionMask.${OUTPUT_SUFFIX}
BRAIN_SEGMENTATION=${OUTPUT_PREFIX}BrainSegmentation.${OUTPUT_SUFFIX}
CORTICAL_THICKNESS_IMAGE=${OUTPUT_PREFIX}CorticalThickness.${OUTPUT_SUFFIX}

################################################################################
#
# Brain extraction
#
################################################################################

        stage1="-m MI[${images},${ANTS_LINEAR_METRIC_PARAMS}] -c ${ANTS_LINEAR_CONVERGENCE} -t Affine[0.1] -f 8x4x2x1 -s 4x2x1x0"
        stage2="-m CC[${images},1,4] -c [${ANTS_MAX_ITERATIONS},1e-9,15] -t ${ANTS_TRANSFORMATION} -f 6x4x2x1 -s 3x2x1x0"


################################################################################
#
# End of main routine
#
################################################################################

time_end=`date +%s`
time_elapsed=$((time_end - time_start))

echo
echo "--------------------------------------------------------------------------------------"
echo " Done with ANTs processing pipeline"
echo " Script executed in $time_elapsed seconds"
echo " $(( time_elapsed / 3600 ))h $(( time_elapsed %3600 / 60 ))m $(( time_elapsed % 60 ))s"
echo "--------------------------------------------------------------------------------------"

exit 0

