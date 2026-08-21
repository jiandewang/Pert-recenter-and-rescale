#!/bin/bash
# ==============================================================================
# Driver Script, Re-center and Rescale CPC Ocean Perturbations
# ==============================================================================
set -euo pipefail

# Command-line input for IC date (optional, defaults to 20260201 if empty)
INPUT_DATE="${1:-20260201}"

# 1. Source Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.rescale"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[FATAL ERROR] Configuration file '${CONFIG_FILE}' not found!"
    exit 1
fi

# Source configuration passing the date parameter
source "${CONFIG_FILE}" "${INPUT_DATE}"

# 2. Print Workflow Environment Check
echo "======================================================================"
echo "      Driver Script, Re-center and Rescale CPC Ocean Perturbations    "
echo "======================================================================"
echo "  Target IC Date       : ${YYYYMMDD}"
echo "  Cycle Hour           : ${HH}Z"
echo "  Ensemble Range       : mem$(printf "${MEM_FORMAT}" "${MEM_START}") to mem$(printf "${MEM_FORMAT}" "${MEM_END}") (${NUM_MEMBERS} members)"
echo "  Perturbation File    : ${PERT_FILENAME:-[Not Found]}"
echo "  Source Directory     : ${CYCLE_ORIGIN_DIR}"
echo "  Scaling Profile CSV  : ${SCALE_CSV}"
echo "  Max Scaling Cap      : ${MAX_SCALE_RATIO}x"
echo "  Work Space           : ${WORK_DIR}"
echo "  Ensemble Mean Output : ${ENSEMBLE_MEAN_FILE}"
echo "  Final Output Dir     : ${OCEAN_PERT_RESCALED}/sfs.${YYYYMMDD}/${HH}"
echo "======================================================================"

# 3. Strict Pre-flight Checks
if [[ ! -d "${CYCLE_ORIGIN_DIR}" ]]; then
    echo "[FATAL ERROR] Target cycle origin directory does not exist:"
    echo "              ${CYCLE_ORIGIN_DIR}"
    exit 1
fi

if [[ -z "${PERT_FILENAME:-}" ]]; then
    echo "[FATAL ERROR] Could not locate any .mom6_perturbation.nc file in:"
    echo "              ${CYCLE_ORIGIN_DIR}"
    exit 1
else
    echo "✓ Found source perturbation file: ${PERT_FILENAME}"
fi

if [[ ! -f "${SCALE_CSV}" ]]; then
    echo "[FATAL ERROR] Required fixed scale CSV file is missing:"
    echo "              ${SCALE_CSV}"
    exit 1
else
    echo "✓ Found fixed scale profile: ${SCALE_CSV}"
fi

# 4. Create Working and Output Directories
mkdir -p "${WORK_DIR}"
mkdir -p "${OCEAN_PERT_RESCALED}"
echo "✓ Directories initialized successfully."

# ------------------------------------------------------------------------------
# STEP 1: Compute Ensemble Mean for t_pert and s_pert
# ------------------------------------------------------------------------------
echo ""
PYTHON_MEAN_SCRIPT="${SCRIPT_DIR}/scripts/compute_ensemble_mean.py"

if [[ ! -f "${PYTHON_MEAN_SCRIPT}" ]]; then
    echo "[FATAL ERROR] Python mean calculation script missing: ${PYTHON_MEAN_SCRIPT}"
    exit 1
fi

python "${PYTHON_MEAN_SCRIPT}" \
    "${CYCLE_ORIGIN_DIR}" \
    "${MEM_START}" \
    "${MEM_END}" \
    "${PERT_FILENAME}" \
    "${ENSEMBLE_MEAN_FILE}"

# ------------------------------------------------------------------------------
# STEP 2: Parallel Re-centering (Subtract Ensemble Mean)
# ------------------------------------------------------------------------------
echo ""
PYTHON_RECENTER_SCRIPT="${SCRIPT_DIR}/scripts/recenter_parallel.py"

if [[ ! -f "${PYTHON_RECENTER_SCRIPT}" ]]; then
    echo "[FATAL ERROR] Python recentering script missing: ${PYTHON_RECENTER_SCRIPT}"
    exit 1
fi

python "${PYTHON_RECENTER_SCRIPT}" \
    "${CYCLE_ORIGIN_DIR}" \
    "${WORK_DIR}" \
    "${MEM_START}" \
    "${MEM_END}" \
    "${PERT_FILENAME}" \
    "${ENSEMBLE_MEAN_FILE}" \
    "${NUM_WORKERS}"

# ------------------------------------------------------------------------------
# STEP 3: Parallel Rescaling (Apply Profile Scaling with Depth Interpolation & Capping)
# ------------------------------------------------------------------------------
echo ""
PYTHON_RESCALE_SCRIPT="${SCRIPT_DIR}/scripts/rescale_parallel.py"

if [[ ! -f "${PYTHON_RESCALE_SCRIPT}" ]]; then
    echo "[FATAL ERROR] Python rescaling script missing: ${PYTHON_RESCALE_SCRIPT}"
    exit 1
fi

python "${PYTHON_RESCALE_SCRIPT}" \
    "${WORK_DIR}" \
    "${OCEAN_PERT_RESCALED}" \
    "${YYYYMMDD}" \
    "${HH}" \
    "${MEM_START}" \
    "${MEM_END}" \
    "${PERT_FILENAME}" \
    "${SCALE_CSV}" \
    "${MAX_SCALE_RATIO}" \
    "${NUM_WORKERS}"

# ------------------------------------------------------------------------------
# STEP 4: Link Unmodified Source IC Directories (mem000, Previous Day ICs, etc.)
# ------------------------------------------------------------------------------
echo ""
echo "======================================================================"
echo " STEP 4: LINKING UNMODIFIED SOURCE IC FILES & PREVIOUS DAY BACKGROUND"
echo "======================================================================"

TARGET_CYCLE_DIR="${OCEAN_PERT_RESCALED}/sfs.${YYYYMMDD}/${HH}"

# 4a. Link Control Run (mem000) if present in target IC date
CONTROL_MEM="${CYCLE_ORIGIN_DIR}/mem000"
if [[ -d "${CONTROL_MEM}" ]]; then
    echo "  Linking control run directory (mem000)..."
    mkdir -p "${TARGET_CYCLE_DIR}"
    ln -sfn "${CONTROL_MEM}" "${TARGET_CYCLE_DIR}/mem000"
    echo "  ✓ Linked mem000 control run."
fi

# 4b. Calculate and Link Previous Day Background Directory (sfs.YYYYMMDD_PREV)
# Example: 20260701 -> sfs.20260630
PREV_YYYYMMDD=$(date -d "${YYYYMMDD} - 1 day" +%Y%m%d)
PREV_DATE_ORIGIN="${OCEAN_PERT_ORIGIN}/sfs.${PREV_YYYYMMDD}"
PREV_DATE_TARGET="${OCEAN_PERT_RESCALED}/sfs.${PREV_YYYYMMDD}"

echo "  Target previous day IC background directory: sfs.${PREV_YYYYMMDD}"

if [[ -d "${PREV_DATE_ORIGIN}" ]]; then
    echo "  Linking previous day background directory..."
    mkdir -p "${OCEAN_PERT_RESCALED}"
    ln -sfn "${PREV_DATE_ORIGIN}" "${PREV_DATE_TARGET}"
    echo "  ✓ Linked background ICs: sfs.${PREV_YYYYMMDD} -> ${PREV_DATE_ORIGIN}"
else
    echo "  ⚠ WARNING: Previous day directory not found at: ${PREV_DATE_ORIGIN}"
fi

# 4c. Link remaining IC directories for perturbation ensemble members (mem001 to memXXX)
for (( m=MEM_START; m<=MEM_END; m++ )); do
    MEM_STR=$(printf "mem${MEM_FORMAT}" "$m")
    SRC_MEM_DIR="${CYCLE_ORIGIN_DIR}/${MEM_STR}"
    TGT_MEM_DIR="${TARGET_CYCLE_DIR}/${MEM_STR}"

    if [[ -d "${SRC_MEM_DIR}" ]]; then
        echo "  Linking remaining IC files for ${MEM_STR}..."

        # Loop over items in member directory (e.g., analysis, model)
        for item in "${SRC_MEM_DIR}"/*; do
            item_name=$(basename "${item}")

            if [[ "${item_name}" == "analysis" ]]; then
                # Handle analysis directory contents
                mkdir -p "${TGT_MEM_DIR}/analysis"
                
                for sub_item in "${SRC_MEM_DIR}/analysis"/*; do
                    sub_name=$(basename "${sub_item}")
                    
                    if [[ "${sub_name}" == "ocean" ]]; then
                        # Inside ocean: link everything except the rescaled perturbation file
                        mkdir -p "${TGT_MEM_DIR}/analysis/ocean"
                        for o_file in "${SRC_MEM_DIR}/analysis/ocean"/*; do
                            o_name=$(basename "${o_file}")
                            if [[ "${o_name}" != "${PERT_FILENAME}" ]]; then
                                ln -sfn "${o_file}" "${TGT_MEM_DIR}/analysis/ocean/${o_name}"
                            fi
                        done
                    else
                        # Symlink non-ocean subdirectories (e.g., analysis/atmos)
                        ln -sfn "${sub_item}" "${TGT_MEM_DIR}/analysis/${sub_name}"
                    fi
                done
            else
                # Symlink non-analysis directories (e.g., model/)
                ln -sfn "${item}" "${TGT_MEM_DIR}/${item_name}"
            fi
        done
    fi
done

echo "✓ STEP 4 Complete! Target cycle, control run, and previous-day background links ready."
# ------------------------------------------------------------------------------
# CLEANUP (Optional)
# ------------------------------------------------------------------------------
if [[ "${CLEAN_WORK_DIR}" == "YES" ]]; then
    echo ""
    echo "Purging temporary work directory: ${WORK_DIR}"
    rm -rf "${WORK_DIR}"
fi

echo ""
echo "======================================================================"
echo "✓ ALL STEPS COMPLETED SUCCESSFULLY FOR DATE: ${YYYYMMDD}"
echo "======================================================================"
