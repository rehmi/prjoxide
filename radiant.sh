#!/bin/bash
# radiant.sh — Docker-aware Radiant bridge for prjoxide fuzzer harness.
#
# Replaces the original native-Linux radiant.sh on hosts that drive Lattice
# Radiant via the radiant:2025.2.1-ipgen Docker image (eyecrow flow).
# Maintains the original calling contract:
#
#   radiant.sh <PART> <basename.v>
#     env vars consumed: STRUCT_VER, GEN_RBF, RBK_MODE, FORCE_REBUILD,
#                        DEV_PACKAGE, SPEED_GRADE, BITSTREAM_CACHE
#
# The original native radiant.sh is preserved as radiant_native.sh on this
# host for reference; the original upstream radiant.sh assumes a native
# ~/lscc/radiant/3.0 install which funi0n (M2 Ultra macOS, the only host with
# Radiant) does not have — it only has the Docker image.

set -ex

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRJOXIDE_ROOT="${PRJOXIDE_ROOT:-${SCRIPT_PATH}}"

DOCKER="${DOCKER:-/usr/local/bin/docker}"
IMAGE="${RADIANT_IMAGE:-radiant:2025.2.1-ipgen}"
MAC_ADDR="${RADIANT_MAC:-9a:a7:5e:be:52:45}"
RADIANT_INSTALL_IN_CT="${RADIANT_INSTALL_IN_CT:-/opt/lscc/radiant/2025.2.1}"

PART="$1"
V_SUB="${2%.v}"

case "${PART}" in
	LIFCL-17)
		PACKAGE="${DEV_PACKAGE:-CABGA256}"
		DEVICE="LIFCL-17"
		LSE_ARCH="lifcl"
		SPEED_GRADE_DFL="7_High-Performance_1.0V"
		;;
	LIFCL-33)
		PACKAGE="${DEV_PACKAGE:-WLCSP84}"
		DEVICE="LIFCL-33"
		LSE_ARCH="lifcl"
		SPEED_GRADE_DFL="8_High-Performance_1.0V"
		;;
	LIFCL-40)
		PACKAGE="${DEV_PACKAGE:-CABGA400}"
		DEVICE="LIFCL-40"
		LSE_ARCH="lifcl"
		SPEED_GRADE_DFL="7_High-Performance_1.0V"
		;;
	LFD2NX-40)
		PACKAGE="${DEV_PACKAGE:-CABGA256}"
		DEVICE="LFD2NX-40"
		LSE_ARCH="lfd2nx"
		SPEED_GRADE_DFL="7_High-Performance_1.0V"
		;;
	LFCPNX-100)
		PACKAGE="${DEV_PACKAGE:-LFG672}"
		DEVICE="LFCPNX-100"
		LSE_ARCH="lfcpnx"
		EXTRA_BIT_ARGS="-ipeval"
		SPEED_GRADE_DFL="7_High-Performance_1.0V"
		;;
	*)
		echo "radiant.sh: unsupported PART '${PART}'" >&2
		exit 2
		;;
esac
SPEED_GRADE="${SPEED_GRADE:-${SPEED_GRADE_DFL}}"
EXTRA_BIT_ARGS="${EXTRA_BIT_ARGS:-}"

bscache="${BITSTREAM_CACHE:-${PRJOXIDE_ROOT}/tools/bitstreamcache.py}"

rm -rf "${V_SUB}.tmp"
mkdir -p "${V_SUB}.tmp"
cp "${V_SUB}.v" "${V_SUB}.tmp/input.v"
MAYBE_PDC=""
if [ -e "${V_SUB}.pdc" ]; then
	cp "${V_SUB}.pdc" "${V_SUB}.tmp/input.pdc"
	MAYBE_PDC="${V_SUB}.tmp/input.pdc"
fi

if [ -z "$FORCE_REBUILD" ] && python3 "$bscache" fetch "$PART" "${V_SUB}.tmp" "${V_SUB}.tmp/input.v" $MAYBE_PDC 2>/dev/null; then
	echo "Cache hit, not running Radiant"
else
	WORKDIR_HOST="$(cd "$(dirname "${V_SUB}.tmp")" && pwd)/$(basename "${V_SUB}.tmp")"
	case "${WORKDIR_HOST}" in
		${PRJOXIDE_ROOT}/*) ;;
		*)
			echo "radiant.sh: workdir ${WORKDIR_HOST} not under PRJOXIDE_ROOT ${PRJOXIDE_ROOT}" >&2
			exit 3
			;;
	esac

	MAP_PDC_INLINE=""
	[ -n "$MAYBE_PDC" ] && MAP_PDC_INLINE="input.pdc"

	# Write a per-invocation build script into the workdir (which is mounted).
	RUN_SCRIPT="${WORKDIR_HOST}/_radiant_run.sh"
	{
		echo '#!/bin/bash'
		echo 'set -ex'
		echo "export FOUNDRY=\"${RADIANT_INSTALL_IN_CT}/ispfpga\""
		echo "export TCL_LIBRARY=\"${RADIANT_INSTALL_IN_CT}/tcltk/linux/lib/tcl8.6\""
		echo "export LD_LIBRARY_PATH=\"${RADIANT_INSTALL_IN_CT}/bin/lin64:\${FOUNDRY}/bin/lin64\""
		echo "cd \"${WORKDIR_HOST}\""
		if [ -n "$STRUCT_VER" ]; then
			echo '"${FOUNDRY}/bin/lin64/sv2udb" -o par.udb input.v'
		else
			echo "\"\${FOUNDRY}/bin/lin64/synthesis\" -a \"${LSE_ARCH}\" -p \"${DEVICE}\" -t \"${PACKAGE}\" \\"
			echo '    -use_io_insertion 1 -use_io_reg auto -use_carry_chain 1 \'
			echo '    -ver input.v -output_hdl synth.vm'
			echo "\"\${FOUNDRY}/bin/lin64/postsyn\" -a \"${LSE_ARCH}\" -p \"${DEVICE}\" -t \"${PACKAGE}\" -sp \"${SPEED_GRADE}\" \\"
			echo '    -top -w -o synth.udb synth.vm'
			echo "\"\${FOUNDRY}/bin/lin64/map\" -o map.udb synth.udb ${MAP_PDC_INLINE}"
			echo '"${FOUNDRY}/bin/lin64/par" map.udb par.udb'
		fi
		if [ -n "$GEN_RBF" ]; then
			echo "\"\${FOUNDRY}/bin/lin64/bitgen\" ${EXTRA_BIT_ARGS} -b -d -w par.udb"
		elif [ -n "$RBK_MODE" ]; then
			echo "\"\${FOUNDRY}/bin/lin64/bitgen\" ${EXTRA_BIT_ARGS} -d -w -m 1 par.udb"
			echo 'mv par.rbk par.bit'
		else
			echo "\"\${FOUNDRY}/bin/lin64/bitgen\" ${EXTRA_BIT_ARGS} -d -w par.udb"
		fi
	} > "${RUN_SCRIPT}"
	chmod +x "${RUN_SCRIPT}"

	"${DOCKER}" run --rm \
		--platform linux/amd64 \
		--mac-address "${MAC_ADDR}" \
		-v "${PRJOXIDE_ROOT}":"${PRJOXIDE_ROOT}" \
		-w "${PRJOXIDE_ROOT}" \
		-e LSC_DIAMOND=true \
		-e NEOCAD_MAXLINEWIDTH=32767 \
		"${IMAGE}" \
		"${RUN_SCRIPT}"

	python3 "$bscache" commit "$PART" "input.v" "$MAP_PDC" output "par.udb" "${V_SUB}.tmp/par.bit" 2>/dev/null || true
fi

if [ -n "$GEN_RBF" ]; then
	cp "${V_SUB}.tmp"/par.rbt "${V_SUB}.rbt"
else
	cp "${V_SUB}.tmp"/par.bit "${V_SUB}.bit"
fi

if [ -n "$DO_UNPACK" ]; then
	prjoxide unpack "${V_SUB}.bit" "${V_SUB}.fasm"
fi
