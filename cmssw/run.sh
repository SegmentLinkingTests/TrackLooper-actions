#!/bin/env bash

# Validate the cmssw branch name to avoid code injection
CMSSW_BRANCH=$(echo $CMSSW_BRANCH | tr -d '[:cntrl:]') # remove \r and other control characters that could be in there.
if [[ "$CMSSW_BRANCH" =~ ^[0-9]+$ ]]; then
  CMSSW_BRANCH=refs/pull/${CMSSW_BRANCH}/head
fi
CMSSW_BRANCH=(git check-ref-format --branch $CMSSW_BRANCH || echo "default")

# Set the CMSSW branch to use
# When using a non-default branch comparison plots are not made because the changes in both repos presumably depend on each other
COMPARE_TO_MASTER=false
if [ -z "$CMSSW_BRANCH" ] || [ "$CMSSW_BRANCH" == "default" ]; then
  CMSSW_BRANCH=CMSSW_13_3_0_pre3_LST_X
  COMPARE_TO_MASTER=true
fi

# Exit if any command fails
set -e

# Build and run the PR
echo "Running setup script..."
source setup.sh
echo "Building and LST..."
make code/rooutil/
sdl_make_tracklooper -c || echo "Done"
if ! [ -f bin/sdl ]; then echo "Build failed. Printing log..."; cat .make.log*; false; fi
echo "Setting up CMSSW..."
scramv1 project CMSSW $CMSSW_VERSION
cd $CMSSW_VERSION/src
eval `scramv1 runtime -sh`
git cms-init --upstream-only
git remote add SegLink https://github.com/SegmentLinking/cmssw.git
git fetch SegLink $CMSSW_BRANCH
git checkout $CMSSW_BRANCH
git cms-addpkg RecoTracker/LST Configuration/ProcessModifiers RecoTracker/ConversionSeedGenerators RecoTracker/FinalTrackSelectors RecoTracker/IterativeTracking
cat <<EOF >lst_cpu.xml
<tool name="lst_cpu" version="1.0">
  <client>
    <environment name="LSTBASE" default="$PWD/../../../TrackLooper"/>
    <environment name="LIBDIR" default="\$LSTBASE/SDL"/>
    <environment name="INCLUDE" default="\$LSTBASE"/>
  </client>
  <runtime name="LST_BASE" value="\$LSTBASE"/>
  <lib name="sdl_cpu"/>
</tool>
EOF
scram setup lst_cpu.xml
eval `scramv1 runtime -sh`
# We need to remove the Cuda plugin because it fails to compile if there is no GPU
sed -i '/<library file="alpaka\/\*\.cc" name="RecoTrackerLSTPluginsPortableCuda">/,/<\/library>/d' RecoTracker/LST/plugins/BuildFile.xml
echo "Building CMSSW..."
scram b -j 2
echo "Starting LST test..."
cmsDriver.py step3  -s RAW2DIGI,RECO:reconstruction_trackingOnly,VALIDATION:@trackingOnlyValidation,DQM:@trackingOnlyDQM --conditions auto:phase2_realistic_T21 --datatier GEN-SIM-RECO,DQMIO -n 10 --eventcontent RECOSIM,DQM --geometry Extended2026D88 --era Phase2C17I13M9 --procModifiers trackingLST,trackingIters01 --no_exec
sed -i "28i process.load('Configuration.StandardSequences.Accelerators_cff')\nprocess.load('HeterogeneousCore.AlpakaCore.ProcessAcceleratorAlpaka_cfi')" step3_RAW2DIGI_RECO_VALIDATION_DQM.py
sed -i "s|fileNames = cms.untracked.vstring('file:step3_DIGI2RAW.root')|fileNames = cms.untracked.vstring('/data2/segmentlinking/file:step2_21034.1_10Events.root')|" step3_RAW2DIGI_RECO_VALIDATION_DQM.py
echo "Setting up siteconf..."
git clone https://github.com/cms-sw/siteconf.git
sed -i '/<prefer ipfamily="0"\/>/,/<backupproxy url="http:\/\/cmsbproxy\.fnal\.gov:3128"\/>/d' siteconf/local/JobConfig/site-local-config.xml
export SITECONFIG_PATH=$PWD/siteconf/local
echo "Running 21034.1 workflow..."
cmsRun step3_RAW2DIGI_RECO_VALIDATION_DQM.py
cmsDriver.py step4 -s HARVESTING:@trackingOnlyValidation+@trackingOnlyDQM --conditions auto:phase2_realistic_T21 --mc  --geometry Extended2026D88 --scenario pp --filetype DQM --era Phase2C17I13M9 -n 10 --no_exec
sed -i "s|fileNames = cms.untracked.vstring('file:step4_RECO.root')|fileNames = cms.untracked.vstring('file:step3_RAW2DIGI_RECO_VALIDATION_DQM_inDQM.root')|" step4_HARVESTING.py
cmsRun step4_HARVESTING.py
mv DQM_V0001_R000000001__Global__CMSSW_X_Y_Z__RECO.root This_PR.root
rm step3_*.root

if [ "$COMPARE_TO_MASTER" == "true" ]; then
  # Checkout the master branch so we can compare what has changed
  cd ../..
  PRSHA=$(git rev-parse HEAD)
  git fetch origin master
  git checkout origin/master

  # Build and run master
  echo "Running setup script..."
  source setup.sh
  echo "Building and LST..."
  make clean
  make code/rooutil/
  sdl_make_tracklooper -c || echo "Done"
  if ! [ -f bin/sdl ]; then echo "Build failed. Printing log..."; cat .make.log*; false; fi
  cd $CMSSW_VERSION/src
  eval `scramv1 runtime -sh`
  echo "Running 21034.1 workflow..."
  cmsRun step3_RAW2DIGI_RECO_VALIDATION_DQM.py
  cmsRun step4_HARVESTING.py
  mv DQM_V0001_R000000001__Global__CMSSW_X_Y_Z__RECO.root master.root
  # Go back to the PR commit so that the git tag is consistent everywhere
  cd ../..
  git checkout $PRSHA
  cd $CMSSW_VERSION/src

  # Create comparison plots
  makeTrackValidationPlots.py --extended -o plots_pdf This_PR.root master.root
  makeTrackValidationPlots.py --extended --png -o plots_png This_PR.root master.root
else
  # Create validation plots
  makeTrackValidationPlots.py --extended -o plots_pdf This_PR.root
  makeTrackValidationPlots.py --extended --png -o plots_png This_PR.root
fi

# Copy a few plots that will be attached in the PR comment
mkdir $TRACKLOOPERDIR/$ARCHIVE_DIR
cp plots_png/plots_ootb/effandfakePtEtaPhi.png $TRACKLOOPERDIR/$ARCHIVE_DIR

mkdir plots
cp -r plots_pdf/plots_ootb plots
cp -r plots_pdf/plots_highPurity plots
cp -r plots_pdf/plots_building_highPtTripletStep plots
rm -r plots/plots_ootb/*/ plots/plots_highPurity/*/ plots/plots_building_highPtTripletStep/*/
tar zcf $TRACKLOOPERDIR/$ARCHIVE_DIR/plots.tar.gz plots
