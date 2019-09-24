#!/bin/bash
# Quick and dirty, do a 'nodefind' on each alias in a zone - report if any are not found
# Assumes SSH keys are in place for current user to authenticate to switch as 'admin'
# No error handling
# Usage: ./check_fc_zone.sh fcswitch01.domain.local zonename

TMP_OUTPUT="/tmp/$(basename ${0}).tmp"

SWITCH=${1}
ZONE=${2}

NOTFOUND=0

ssh admin@${SWITCH} zoneshow ${ZONE} > ${TMP_OUTPUT}
ZONE_MEMBERS=$(grep -v " zone:" ${TMP_OUTPUT} | sed -e 's/;//g')
echo "${ZONE}: $(echo ${ZONE_MEMBERS} | wc -w) members"
for MEMBER in ${ZONE_MEMBERS}; do
	ssh admin@${SWITCH} nodefind ${MEMBER} > ${TMP_OUTPUT}
	grep -q "No device found" ${TMP_OUTPUT}
	if [[ ${?} -eq 0 ]]; then
		echo "${MEMBER} not found"
		NOTFOUND=1
	fi
done

if [[ ${NOTFOUND} -eq 1 ]]; then
	echo "Zone has members that are not found"
else
	echo "Zone is healthy"
fi
