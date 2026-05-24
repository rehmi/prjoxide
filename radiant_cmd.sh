#!/bin/bash
# radiant_cmd.sh — Docker-aware Radiant command runner for prjoxide.
#
# Replaces the original native radiant_cmd.sh on hosts that drive Radiant via
# the radiant:2025.2.1-ipgen Docker image. Passes through to the requested
# binary inside the container.
#
# Calling contract: radiant_cmd.sh <toolname> [args...]
# Example: radiant_cmd.sh bstool -t input.bit (preferred over lapie which is
#          NOT present in Radiant 2025.2.1 — see fuzz/lapie.py comments).

set -e

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRJOXIDE_ROOT="${PRJOXIDE_ROOT:-${SCRIPT_PATH}}"

DOCKER="${DOCKER:-/usr/local/bin/docker}"
IMAGE="${RADIANT_IMAGE:-radiant:2025.2.1-ipgen}"
MAC_ADDR="${RADIANT_MAC:-9a:a7:5e:be:52:45}"
RADIANT_INSTALL_IN_CT="${RADIANT_INSTALL_IN_CT:-/opt/lscc/radiant/2025.2.1}"

TOOL="$1"
shift || true

# Resolve tool location inside the container. Top-level CLI tools (radiantc,
# pnmainc, ipgenwrap, programmerc) live under bin/lin64/. Synthesis/PnR tools
# (synthesis, postsyn, map, par, bitgen, bstool, sv2udb, ...) live under
# ispfpga/bin/lin64/. We probe ispfpga first (most fuzzer-relevant tools).
TOOL_PATH=""
case "${TOOL}" in
	radiantc|pnmainc|ipgenwrap|programmerc|radiant|cableserver)
		TOOL_PATH="${RADIANT_INSTALL_IN_CT}/bin/lin64/${TOOL}"
		;;
	lapie)
		# lapie does NOT exist in Radiant 2025.2.1 (Diamond-only tool). Fail
		# loudly so fuzzers that need it (110-global-structure et al.) surface
		# the gap instead of silently producing garbage. Use bstool or static
		# extraction instead.
		echo "radiant_cmd.sh: 'lapie' is unavailable in Radiant 2025.2.1 (Diamond-only). See util/common/lapie.py / fuzzers/LIFCL/110-global-structure for the workaround story." >&2
		exit 127
		;;
	*)
		TOOL_PATH="${RADIANT_INSTALL_IN_CT}/ispfpga/bin/lin64/${TOOL}"
		;;
esac

exec "${DOCKER}" run --rm \
	--platform linux/amd64 \
	--mac-address "${MAC_ADDR}" \
	-v "${PRJOXIDE_ROOT}":"${PRJOXIDE_ROOT}" \
	-w "${PWD}" \
	-e LSC_DIAMOND=true \
	-e NEOCAD_MAXLINEWIDTH=32767 \
	"${IMAGE}" \
	bash -c "export FOUNDRY=\"${RADIANT_INSTALL_IN_CT}/ispfpga\"; \
	         export TCL_LIBRARY=\"${RADIANT_INSTALL_IN_CT}/tcltk/linux/lib/tcl8.6\"; \
	         export LD_LIBRARY_PATH=\"${RADIANT_INSTALL_IN_CT}/bin/lin64:\${FOUNDRY}/bin/lin64\"; \
	         exec \"${TOOL_PATH}\" \"\$@\"" -- "$@"
