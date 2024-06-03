#!/bin/env bash

# Set the "master" CMSSW branch
MASTER_BRANCH=LSTCore_devel

CMSSW_VERSION=CMSSW_14_1_0_pre3

# Print all commands and exit on error
set -e -v

# Build and run the PR
echo "Initializing CMSSW..."
source /cvmfs/cms.cern.ch/cmsset_default.sh
scramv1 project CMSSW $CMSSW_VERSION
cd $CMSSW_VERSION/src
eval `scramv1 runtime -sh`
# cms-init is too slow
# git cms-init --upstream-only
git init
git remote add SegLink https://github.com/SegmentLinkingTests/cmssw.git
git sparse checkout set .gitignore .clang-format .clangtidy
git fetch SegLink refs/pull/${PR_NUMBER}/head:SegLink_cmssw
git checkout SegLink_cmssw
git fetch SegLink $MASTER_BRANCH
# Temporarily merge master branch
git config user.email "gha@example.com" && git config user.name "GHA"
git merge --no-commit --no-ff SegLink/${MASTER_BRANCH} || (echo "***\nError: There are merge conflicts that need to be resolved.\n***" && false)
git cms-addpkg RecoTracker/LST RecoTracker/LSTCore Configuration/ProcessModifiers RecoTracker/ConversionSeedGenerators RecoTracker/FinalTrackSelectors RecoTracker/IterativeTracking
eval `scramv1 runtime -sh`
echo "Building CMSSW..."
scram b -j 4
echo "Starting LST test..."
cmsDriver.py step3 -s RAW2DIGI,RECO:reconstruction_trackingOnly,VALIDATION:@trackingOnlyValidation,DQM:@trackingOnlyDQM --conditions auto:phase2_realistic_T21 --datatier GEN-SIM-RECO,DQMIO -n 100 --eventcontent RECOSIM,DQM --geometry Extended2026D88 --era Phase2C17I13M9 --procModifiers trackingLST,trackingIters01 --nThreads 4 --no_exec
sed -i "28i process.load('Configuration.StandardSequences.Accelerators_cff')\nprocess.load('HeterogeneousCore.AlpakaCore.ProcessAcceleratorAlpaka_cfi')" step3_RAW2DIGI_RECO_VALIDATION_DQM.py
sed -i "s|fileNames = cms.untracked.vstring('file:step3_DIGI2RAW.root')|fileNames = cms.untracked.vstring('file:/data2/segmentlinking/step2_21034.1_100Events.root')|" step3_RAW2DIGI_RECO_VALIDATION_DQM.py
echo "Setting up siteconf..."
git clone https://github.com/cms-sw/siteconf.git
sed -i '/<prefer ipfamily="0"\/>/,/<backupproxy url="http:\/\/cmsbproxy\.fnal\.gov:3128"\/>/d' siteconf/local/JobConfig/site-local-config.xml
export SITECONFIG_PATH=$PWD/siteconf/local
echo "Running 21034.1 workflow..."
cmsRun step3_RAW2DIGI_RECO_VALIDATION_DQM.py
cmsDriver.py step4 -s HARVESTING:@trackingOnlyValidation+@trackingOnlyDQM --conditions auto:phase2_realistic_T21 --mc  --geometry Extended2026D88 --scenario pp --filetype DQM --era Phase2C17I13M9 -n 100 --no_exec
sed -i "s|fileNames = cms.untracked.vstring('file:step4_RECO.root')|fileNames = cms.untracked.vstring('file:step3_RAW2DIGI_RECO_VALIDATION_DQM_inDQM.root')|" step4_HARVESTING.py
cmsRun step4_HARVESTING.py
mv DQM_V0001_R000000001__Global__CMSSW_X_Y_Z__RECO.root This_PR.root
rm step3_*.root

# Checkout the master branch so we can compare what has changed
git stash
PRSHA=$(git rev-parse HEAD)
git checkout SegLink/${MASTER_BRANCH}

# Build and run master
eval `scramv1 runtime -sh`
# Recompile CMSSW in case anything changed in the headers
scram b clean
scram b -j 4
echo "Running 21034.1 workflow..."
cmsRun step3_RAW2DIGI_RECO_VALIDATION_DQM.py
cmsRun step4_HARVESTING.py
mv DQM_V0001_R000000001__Global__CMSSW_X_Y_Z__RECO.root master.root
# Go back to the PR commit so that the git tag is consistent everywhere
git checkout $PRSHA

# Create comparison plots
makeTrackValidationPlots.py --extended -o plots_pdf master.root This_PR.root
makeTrackValidationPlots.py --extended --png -o plots_png master.root This_PR.root

# Copy a few plots that will be attached in the PR comment
mkdir $ARCHIVE_DIR
cp plots_png/plots_ootb/effandfakePtEtaPhi.png $ARCHIVE_DIR

mkdir plots
cp -r plots_pdf/plots_ootb plots
cp -r plots_pdf/plots_highPurity plots
cp -r plots_pdf/plots_building_highPtTripletStep plots
rm -r plots/plots_ootb/*/ plots/plots_highPurity/*/ plots/plots_building_highPtTripletStep/*/
tar zcf $ARCHIVE_DIR/plots.tar.gz plots
