#!/usr/bin/env bash
# shellcheck disable=SC1090

# Pi-hole: A black hole for Internet advertisements
# (c) 2017 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Usage: "pihole -g"
# Compiles a list of ad-serving domains by downloading them from multiple sources
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

export LC_ALL=C

coltable="/usr/local/share/pihole/scripts/COL_TABLE"
source "${coltable}"
# shellcheck disable=SC1091
source "/usr/local/share/pihole/scripts/database_migration/gravity-db.sh"

basename="pihole"
PIHOLE_COMMAND="/usr/local/bin/${basename}"

piholeDir="/usr/local/etc/${basename}"

PIHOLE_USER="bind"
PIHOLE_GROUP="bind"

# Legacy (pre v5.0) list file locations
whitelistFile="${piholeDir}/whitelist.txt"
blacklistFile="${piholeDir}/blacklist.txt"
regexFile="${piholeDir}/regex.list"
adListFile="${piholeDir}/adlists.list"

localList="${piholeDir}/local.list"
VPNList="/etc/openvpn/ipp.txt"

gravityDBfile_default="${piholeDir}/gravity.db"
# GRAVITYDB may be overwritten by source pihole-FTL.conf below
GRAVITYDB="${gravityDBfile_default}"
gravityDBschema="/usr/local/share/pihole/templates/gravity.db.sql"
gravityDBcopy="/usr/local/share/pihole/templates/gravity_copy.sql"

domainsExtension="domains"

# Source setupVars from install script
setupVars="${piholeDir}/setupVars.conf"
if [[ -f "${setupVars}" ]];then
  source "${setupVars}"
else
  echo -e "  ${COL_LIGHT_RED}Installation Failure: ${setupVars} does not exist! ${COL_NC}
  Please run 'pihole -r', and choose the 'reconfigure' option to fix."
  exit 1
fi

# Source pihole-FTL from install script
pihole_FTL="${piholeDir}/pihole-FTL.conf"
if [[ -f "${pihole_FTL}" ]]; then
  source "${pihole_FTL}"
fi

# Set this only after sourcing pihole-FTL.conf as the gravity database path may
# have changed
gravityDBfile="${GRAVITYDB}"
gravityTEMPfile="${GRAVITYDB}_temp"
gravityDIR="$(dirname -- "${gravityDBfile}")"
gravityOLDfile="${gravityDIR}/gravity_old.db"

if [[ -z "${BLOCKINGMODE}" ]] ; then
  BLOCKINGMODE="NULL"
fi

# Determine if superseded pihole.conf exists
if [[ -r "${piholeDir}/pihole.conf" ]]; then
  echo -e "  ${COL_LIGHT_RED}Ignoring overrides specified within pihole.conf! ${COL_NC}"
fi

file_sha1() {
  sha1 -q "${1}"
}

verify_sha1_checksum() {
    local file="${1}"

    sha1 -qc `cat "${file}".sha1 | cut -f1 -d" "` "${file}" > /dev/null
}

# Generate new SQLite3 file from schema template
generate_gravity_database() {
  if ! pihole-FTL sqlite3 "${gravityDBfile}" < "${gravityDBschema}"; then
    echo -e "   ${CROSS} Unable to create ${gravityDBfile}"
    return 1
  fi
  chown $PIHOLE_USER:$PIHOLE_GROUP "${gravityDBfile}"
  chmod g+w "${piholeDir}" "${gravityDBfile}"
}

# Copy data from old to new database file and swap them
gravity_swap_databases() {
  local str copyGravity oldAvail
  str="Building tree"
  echo -ne "  ${INFO} ${str}..."

  # The index is intentionally not UNIQUE as poor quality adlists may contain domains more than once
  output=$( { pihole-FTL sqlite3 "${gravityTEMPfile}" "CREATE INDEX idx_gravity ON gravity (domain, adlist_id);"; } 2>&1 )
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} Unable to build gravity tree in ${gravityTEMPfile}\\n  ${output}"
    return 1
  fi
  echo -e "${OVER}  ${TICK} ${str}"

  str="Swapping databases"
  echo -ne "  ${INFO} ${str}..."

  # Swap databases and remove or conditionally rename old database
  # Number of available blocks on disk
  availableBlocks=$(df -bc "${gravityDIR}" | grep total | sed -E 's/.*([0-9]+) ([0-9]+) ([0-9]+).*/\3/')
  # Number of blocks, used by gravity.db
  # TODO: verify that st_blocks refers to 512 bytes size blocks 
  gravityBlocks=$(stat -f "%b" ${gravityDBfile})
  # Only keep the old database if available disk space is at least twice the size of the existing gravity.db.
  # Better be safe than sorry...
  oldAvail=false
  if [ "${availableBlocks}" -gt "$((gravityBlocks * 2))" ] && [ -f "${gravityDBfile}" ]; then
    oldAvail=true
    mv "${gravityDBfile}" "${gravityOLDfile}"
  else
    rm "${gravityDBfile}"
  fi
  mv "${gravityTEMPfile}" "${gravityDBfile}"
  echo -e "${OVER}  ${TICK} ${str}"

  if $oldAvail; then
    echo -e "  ${TICK} The old database remains available."
  fi
}

# Update timestamp when the gravity table was last updated successfully
update_gravity_timestamp() {
  output=$( { printf ".timeout 30000\\nINSERT OR REPLACE INTO info (property,value) values ('updated',cast(strftime('%%s', 'now') as int));" | pihole-FTL sqlite3 "${gravityDBfile}"; } 2>&1 )
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} Unable to update gravity timestamp in database ${gravityDBfile}\\n  ${output}"
    return 1
  fi
  return 0
}

# Import domains from file and store them in the specified database table
database_table_from_file() {
  # Define locals
  local table src backup_path backup_file tmpFile list_type
  table="${1}"
  src="${2}"
  backup_path="${piholeDir}/migration_backup"
  backup_file="${backup_path}/$(basename "${2}")"
  tmpFile="$(mktemp -t db.gravity)"

  local timestamp
  timestamp="$(date -u +'%s')"

  local rowid
  declare -i rowid
  rowid=1

  # Special handling for domains to be imported into the common domainlist table
  if [[ "${table}" == "whitelist" ]]; then
    list_type="0"
    table="domainlist"
  elif [[ "${table}" == "blacklist" ]]; then
    list_type="1"
    table="domainlist"
  elif [[ "${table}" == "regex" ]]; then
    list_type="3"
    table="domainlist"
  fi

  # Get MAX(id) from domainlist when INSERTing into this table
  if [[ "${table}" == "domainlist" ]]; then
    rowid="$(pihole-FTL sqlite3 "${gravityDBfile}" "SELECT MAX(id) FROM domainlist;")"
    if [[ -z "$rowid" ]]; then
      rowid=0
    fi
    rowid+=1
  fi

  # Loop over all domains in ${src} file
  # Read file line by line
  grep -v '^ *#' < "${src}" | while IFS= read -r domain
  do
    # Only add non-empty lines
    if [[ -n "${domain}" ]]; then
      if [[ "${table}" == "domain_audit" ]]; then
        # domain_audit table format (no enable or modified fields)
        echo "${rowid},\"${domain}\",${timestamp}" >> "${tmpFile}"
      elif [[ "${table}" == "adlist" ]]; then
        # Adlist table format
        echo "${rowid},\"${domain}\",1,${timestamp},${timestamp},\"Migrated from ${src}\",,0,0,0" >> "${tmpFile}"
      else
        # White-, black-, and regexlist table format
        echo "${rowid},${list_type},\"${domain}\",1,${timestamp},${timestamp},\"Migrated from ${src}\"" >> "${tmpFile}"
      fi
      rowid+=1
    fi
  done

  # Store domains in database table specified by ${table}
  # Use printf as .mode and .import need to be on separate lines
  # see https://unix.stackexchange.com/a/445615/83260
  output=$( { printf ".timeout 30000\\n.mode csv\\n.import \"%s\" %s\\n" "${tmpFile}" "${table}" | pihole-FTL sqlite3 "${gravityDBfile}"; } 2>&1 )
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} Unable to fill table ${table}${list_type} in database ${gravityDBfile}\\n  ${output}"
    gravity_Cleanup "error"
  fi

  # Move source file to backup directory, create directory if not existing
  mkdir -p "${backup_path}"
  mv "${src}" "${backup_file}" 2> /dev/null || \
    echo -e "  ${CROSS} Unable to backup ${src} to ${backup_path}"

  # Delete tmpFile
  rm "${tmpFile}" > /dev/null 2>&1 || \
    echo -e "  ${CROSS} Unable to remove ${tmpFile}"
}

# Update timestamp of last update of this list. We store this in the "old" database as all values in the new database will later be overwritten
database_adlist_updated() {
  output=$( { printf ".timeout 30000\\nUPDATE adlist SET date_updated = (cast(strftime('%%s', 'now') as int)) WHERE id = %i;\\n" "${1}" | pihole-FTL sqlite3 "${gravityDBfile}"; } 2>&1 )
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} Unable to update timestamp of adlist with ID ${1} in database ${gravityDBfile}\\n  ${output}"
    gravity_Cleanup "error"
  fi
}

# Check if a column with name ${2} exists in gravity table with name ${1}
gravity_column_exists() {
  output=$( { printf ".timeout 30000\\nSELECT EXISTS(SELECT * FROM pragma_table_info('%s') WHERE name='%s');\\n" "${1}" "${2}" | pihole-FTL sqlite3 "${gravityDBfile}"; } 2>&1 )
  if [[ "${output}" == "1" ]]; then
    return 0 # Bash 0 is success
  fi

  return 1 # Bash non-0 is failure
}

# Update number of domain on this list. We store this in the "old" database as all values in the new database will later be overwritten
database_adlist_number() {
  # Only try to set number of domains when this field exists in the gravity database
  if ! gravity_column_exists "adlist" "number"; then
    return;
  fi

  output=$( { printf ".timeout 30000\\nUPDATE adlist SET number = %i, invalid_domains = %i WHERE id = %i;\\n" "${num_source_lines}" "${num_invalid}" "${1}" | pihole-FTL sqlite3 "${gravityDBfile}"; } 2>&1 )
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} Unable to update number of domains in adlist with ID ${1} in database ${gravityDBfile}\\n  ${output}"
    gravity_Cleanup "error"
  fi
}

# Update status of this list. We store this in the "old" database as all values in the new database will later be overwritten
database_adlist_status() {
  # Only try to set the status when this field exists in the gravity database
  if ! gravity_column_exists "adlist" "status"; then
    return;
  fi

  output=$( { printf ".timeout 30000\\nUPDATE adlist SET status = %i WHERE id = %i;\\n" "${2}" "${1}" | pihole-FTL sqlite3 "${gravityDBfile}"; } 2>&1 )
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} Unable to update status of adlist with ID ${1} in database ${gravityDBfile}\\n  ${output}"
    gravity_Cleanup "error"
  fi
}

# Migrate pre-v5.0 list files to database-based Pi-hole versions
migrate_to_database() {
  # Create database file only if not present
  if [ ! -e "${gravityDBfile}" ]; then
    # Create new database file - note that this will be created in version 1
    echo -e "  ${INFO} Creating new gravity database"
    if ! generate_gravity_database; then
      echo -e "   ${CROSS} Error creating new gravity database. Please contact support."
      return 1
    fi

    # Check if gravity database needs to be updated
    upgrade_gravityDB "${gravityDBfile}" "${piholeDir}"

    # Migrate list files to new database
    if [ -e "${adListFile}" ]; then
      # Store adlist domains in database
      echo -e "  ${INFO} Migrating content of ${adListFile} into new database"
      database_table_from_file "adlist" "${adListFile}"
    fi
    if [ -e "${blacklistFile}" ]; then
      # Store blacklisted domains in database
      echo -e "  ${INFO} Migrating content of ${blacklistFile} into new database"
      database_table_from_file "blacklist" "${blacklistFile}"
    fi
    if [ -e "${whitelistFile}" ]; then
      # Store whitelisted domains in database
      echo -e "  ${INFO} Migrating content of ${whitelistFile} into new database"
      database_table_from_file "whitelist" "${whitelistFile}"
    fi
    if [ -e "${regexFile}" ]; then
      # Store regex domains in database
      # Important note: We need to add the domains to the "regex" table
      # as it will only later be renamed to "regex_blacklist"!
      echo -e "  ${INFO} Migrating content of ${regexFile} into new database"
      database_table_from_file "regex" "${regexFile}"
    fi
  fi

  # Check if gravity database needs to be updated
  upgrade_gravityDB "${gravityDBfile}" "${piholeDir}"
}

# Determine if DNS resolution is available before proceeding
gravity_CheckDNSResolutionAvailable() {
  local lookupDomain="pi.hole"

  # Determine if $localList does not exist, and ensure it is not empty
  if [[ ! -e "${localList}" ]] || [[ -s "${localList}" ]]; then
    lookupDomain="raw.githubusercontent.com"
  fi

  # Determine if $lookupDomain is resolvable
  if timeout 4 getent hosts "${lookupDomain}" &> /dev/null; then
    # Print confirmation of resolvability if it had previously failed
    if [[ -n "${secs:-}" ]]; then
      echo -e "${OVER}  ${TICK} DNS resolution is now available\\n"
    fi
    return 0
  elif [[ -n "${secs:-}" ]]; then
    echo -e "${OVER}  ${CROSS} DNS resolution is not available"
    exit 1
  fi

  # If the /etc/resolv.conf contains resolvers other than 127.0.0.1 then the local dnsmasq will not be queried and pi.hole is NXDOMAIN.
  # This means that even though name resolution is working, the getent hosts check fails and the holddown timer keeps ticking and eventually fails
  # So we check the output of the last command and if it failed, attempt to use dig +short as a fallback
  if timeout 4 dig +short "${lookupDomain}" &> /dev/null; then
    if [[ -n "${secs:-}" ]]; then
      echo -e "${OVER}  ${TICK} DNS resolution is now available\\n"
    fi
    return 0
  elif [[ -n "${secs:-}" ]]; then
    echo -e "${OVER}  ${CROSS} DNS resolution is not available"
    exit 1
  fi

  # Determine error output message
  if pgrep pihole-FTL &> /dev/null; then
    echo -e "  ${CROSS} DNS resolution is currently unavailable"
  else
    echo -e "  ${CROSS} DNS service is not running"
    "${PIHOLE_COMMAND}" restartdns
  fi

  # Ensure DNS server is given time to be resolvable
  secs="120"
  echo -ne "  ${INFO} Time until retry: ${secs}"
  until timeout 1 getent hosts "${lookupDomain}" &> /dev/null; do
    [[ "${secs:-}" -eq 0 ]] && break
    echo -ne "${OVER}  ${INFO} Time until retry: ${secs}"
    : $((secs--))
    sleep 1
  done

  # Try again
  gravity_CheckDNSResolutionAvailable
}

# Retrieve blocklist URLs and parse domains from adlist.list
gravity_DownloadBlocklists() {
  echo -e "  ${INFO} ${COL_BOLD}Neutrino emissions detected${COL_NC}..."

  if [[ "${gravityDBfile}" != "${gravityDBfile_default}" ]]; then
    echo -e "  ${INFO} Storing gravity database in ${COL_BOLD}${gravityDBfile}${COL_NC}"
  fi

  # Retrieve source URLs from gravity database
  # We source only enabled adlists, SQLite3 stores boolean values as 0 (false) or 1 (true)
  mapfile -t sources <<< "$(pihole-FTL sqlite3 "${gravityDBfile}" "SELECT address FROM vw_adlist;" 2> /dev/null)"
  mapfile -t sourceIDs <<< "$(pihole-FTL sqlite3 "${gravityDBfile}" "SELECT id FROM vw_adlist;" 2> /dev/null)"

  # Parse source domains from $sources
  mapfile -t sourceDomains <<< "$(
    # Logic: Split by folder/port
    awk -F '[/:]' '{
      # Remove URL protocol & optional username:password@
      gsub(/(.*:\/\/|.*:.*@)/, "", $0)
      if(length($1)>0){print $1}
      else {print "local"}
    }' <<< "$(printf '%s\n' "${sources[@]}")" 2> /dev/null
  )"

  local str="Pulling blocklist source list into range"
  echo -e "${OVER}  ${TICK} ${str}"

  if [[ -z "${sources[*]}" ]] || [[ -z "${sourceDomains[*]}" ]]; then
    echo -e "  ${INFO} No source list found, or it is empty"
    echo ""
    unset sources
  fi

  local url domain agent cmd_ext str target compression
  echo ""

  # Prepare new gravity database
  str="Preparing new gravity database"
  echo -ne "  ${INFO} ${str}..."
  rm "${gravityTEMPfile}" > /dev/null 2>&1
  output=$( { pihole-FTL sqlite3 "${gravityTEMPfile}" < "${gravityDBschema}"; } 2>&1 )
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} Unable to create new database ${gravityTEMPfile}\\n  ${output}"
    gravity_Cleanup "error"
  else
    echo -e "${OVER}  ${TICK} ${str}"
  fi

  target="$(mktemp -t db.gravity)"

  # Use compression to reduce the amount of data that is transferred
  # between the Pi-hole and the ad list provider. Use this feature
  # only if it is supported by the locally available version of curl
  if curl -V | grep -q "Features:.* libz"; then
    compression="--compressed"
    echo -e "  ${INFO} Using libz compression\n"
  else
    compression=""
    echo -e "  ${INFO} Libz compression not available\n"
  fi
  # Loop through $sources and download each one
  for ((i = 0; i < "${#sources[@]}"; i++)); do
    url="${sources[$i]}"
    domain="${sourceDomains[$i]}"
    id="${sourceIDs[$i]}"

    # Save the file as list.#.domain
    saveLocation="${piholeDir}/list.${id}.${domain}.${domainsExtension}"
    activeDomains[$i]="${saveLocation}"

    # Default user-agent (for Cloudflare's Browser Integrity Check: https://support.cloudflare.com/hc/en-us/articles/200170086-What-does-the-Browser-Integrity-Check-do-)
    agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36"

    # Provide special commands for blocklists which may need them
    case "${domain}" in
      "pgl.yoyo.org") cmd_ext="-d mimetype=plaintext -d hostformat=hosts";;
      *) cmd_ext="";;
    esac

    echo -e "  ${INFO} Target: ${url}"
    local regex check_url
    # Check for characters NOT allowed in URLs
    regex="[^a-zA-Z0-9:/?&%=~._()-;]"

    # this will remove first @ that is after schema and before domain
    # \1 is optional schema, \2 is userinfo
    check_url="$( sed -re 's#([^:/]*://)?([^/]+)@#\1\2#' <<< "$url" )"

    if [[ "${check_url}" =~ ${regex} ]]; then
      echo -e "  ${CROSS} Invalid Target"
    else
      gravity_DownloadBlocklistFromUrl "${url}" "${cmd_ext}" "${agent}" "${sourceIDs[$i]}" "${saveLocation}" "${target}" "${compression}"
    fi
    echo ""
  done

  str="Creating new gravity databases"
  echo -ne "  ${INFO} ${str}..."

  # Gravity copying SQL script
  copyGravity="$(cat "${gravityDBcopy}")"
  if [[ "${gravityDBfile}" != "${gravityDBfile_default}" ]]; then
    # Replace default gravity script location by custom location
    copyGravity="${copyGravity//"${gravityDBfile_default}"/"${gravityDBfile}"}"
  fi

  output=$( { pihole-FTL sqlite3 "${gravityTEMPfile}" <<< "${copyGravity}"; } 2>&1 )
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} Unable to copy data from ${gravityDBfile} to ${gravityTEMPfile}\\n  ${output}"
    return 1
  fi
  echo -e "${OVER}  ${TICK} ${str}"

  str="Storing downloaded domains in new gravity database"
  echo -ne "  ${INFO} ${str}..."
  output=$( { printf ".timeout 30000\\n.mode csv\\n.import \"%s\" gravity\\n" "${target}" | pihole-FTL sqlite3 "${gravityTEMPfile}"; } 2>&1 )
  status="$?"

  if [[ "${status}" -ne 0 ]]; then
    echo -e "\\n  ${CROSS} Unable to fill gravity table in database ${gravityTEMPfile}\\n  ${output}"
    gravity_Cleanup "error"
  else
    echo -e "${OVER}  ${TICK} ${str}"
  fi

  if [[ "${status}" -eq 0 && -n "${output}" ]]; then
    echo -e "  Encountered non-critical SQL warnings. Please check the suitability of the lists you're using!\\n\\n  SQL warnings:"
    local warning file line lineno
    while IFS= read -r line; do
      echo "  - ${line}"
      warning="$(grep -oh "^[^:]*:[0-9]*" <<< "${line}")"
      file="${warning%:*}"
      lineno="${warning#*:}"
      if [[ -n "${file}" && -n "${lineno}" ]]; then
        echo -n "    Line contains: "
        awk "NR==${lineno}" < "${file}"
      fi
    done <<< "${output}"
    echo ""
  fi

  rm "${target}" > /dev/null 2>&1 || \
    echo -e "  ${CROSS} Unable to remove ${target}"

  gravity_Blackbody=true
}

# num_target_lines does increase for every correctly added domain in pareseList()
num_target_lines=0
num_source_lines=0
num_invalid=0
parseList() {
  local adlistID="${1}" src="${2}" target="${3}" incorrect_lines
  # This sed does the following things:
  # 1. Remove all domains containing invalid characters. Valid are: a-z, A-Z, 0-9, dot (.), minus (-), underscore (_)
  # 2. Append ,adlistID to every line
  # 3. Remove trailing period (see https://github.com/pi-hole/pi-hole/issues/4701)
  # 4. Ensures there is a newline on the last line
  sed -e "/[^a-zA-Z0-9.\_-]/d;s/\.$//;s/$/,${adlistID}/;/.$/a\\" "${src}" >> "${target}"
  # Find (up to) five domains containing invalid characters (see above)
  incorrect_lines="$(sed -e "/[^a-zA-Z0-9.\_-]/!d" "${src}" | head -n 5)"

  local num_target_lines_new num_correct_lines
  # Get number of lines in source file
  num_source_lines="$(grep -c "^" "${src}")"
  # Get the new number of lines in destination file
  num_target_lines_new="$(grep -c "^" "${target}")"
  # Number of new correctly added lines
  num_correct_lines="$(( num_target_lines_new-num_target_lines ))"
  # Update number of lines in target file
  num_target_lines="$num_target_lines_new"
  num_invalid="$(( num_source_lines-num_correct_lines ))"
  if [[ "${num_invalid}" -eq 0 ]]; then
    echo "  ${INFO} Analyzed ${num_source_lines} domains"
  else
    echo "  ${INFO} Analyzed ${num_source_lines} domains, ${num_invalid} domains invalid!"
  fi

  # Display sample of invalid lines if we found some
  if [[ -n "${incorrect_lines}" ]]; then
    echo "      Sample of invalid domains:"
    while IFS= read -r line; do
      echo "      - ${line}"
    done <<< "${incorrect_lines}"
  fi
}
compareLists() {
  local adlistID="${1}" target="${2}"

  # Verify checksum when an older checksum exists
  if [[ -s "${target}.sha1" ]]; then
    if ! verify_sha1_checksum "${target}"; then
      # The list changed upstream, we need to update the checksum
      file_sha1 "${target}" > "${target}.sha1"
      echo "  ${INFO} List has been updated"
      database_adlist_status "${adlistID}" "1"
      database_adlist_updated "${adlistID}"
    else
      echo "  ${INFO} List stayed unchanged"
      database_adlist_status "${adlistID}" "2"
    fi
  else
    # No checksum available, create one for comparing on the next run
    file_sha1 "${target}" > "${target}.sha1"
    # We assume here it was changed upstream
    database_adlist_status "${adlistID}" "1"
    database_adlist_updated "${adlistID}"
  fi
}

# Download specified URL and perform checks on HTTP status and file content
gravity_DownloadBlocklistFromUrl() {
  local url="${1}" cmd_ext="${2}" agent="${3}" adlistID="${4}" saveLocation="${5}" target="${6}" compression="${7}"
  local heisenbergCompensator="" patternBuffer str httpCode success="" ip

  # Create temp file to store content on disk instead of RAM
  patternBuffer="$(mktemp -t gravity.phpgb)"

  # Determine if $saveLocation has read permission
  if [[ -r "${saveLocation}" && $url != "file"* ]]; then
    # Have curl determine if a remote file has been modified since last retrieval
    # Uses "Last-Modified" header, which certain web servers do not provide (e.g: raw github urls)
    # Note: Don't do this for local files, always download them
    heisenbergCompensator="-z ${saveLocation}"
  fi

  str="Status:"
  echo -ne "  ${INFO} ${str} Pending..."
  blocked=false
  case $BLOCKINGMODE in
    "IP-NODATA-AAAA"|"IP")
      # Get IP address of this domain
      ip="$(dig "${domain}" +short)"
      # Check if this IP matches any IP of the system
      if [[ -n "${ip}" && $(grep -Ec "inet(|6) ${ip}" <<< "$(ip a)") -gt 0 ]]; then
        blocked=true
      fi;;
    "NXDOMAIN")
      if [[ $(dig "${domain}" | grep "NXDOMAIN" -c) -ge 1 ]]; then
        blocked=true
      fi;;
    "NODATA")
      if [[ $(dig "${domain}" | grep "NOERROR" -c) -ge 1 ]] && [[ -z $(dig +short "${domain}") ]]; then
         blocked=true
      fi;;
    "NULL"|*)
      if [[ $(dig "${domain}" +short | grep "0.0.0.0" -c) -ge 1 ]]; then
        blocked=true
      fi;;
  esac

  if [[ "${blocked}" == true ]]; then
    printf -v ip_addr "%s" "${PIHOLE_DNS_1%#*}"
    if [[ ${PIHOLE_DNS_1} != *"#"* ]]; then
      port=53
    else
      printf -v port "%s" "${PIHOLE_DNS_1#*#}"
    fi
    ip=$(dig "@${ip_addr}" -p "${port}" +short "${domain}" | tail -1)
    if [[ $(echo "${url}" | awk -F '://' '{print $1}') = "https" ]]; then
      port=443;
    else port=80
    fi
    bad_list=$(pihole -q -adlist "${domain}" | head -n1 | awk -F 'Match found in ' '{print $2}')
    echo -e "${OVER}  ${CROSS} ${str} ${domain} is blocked by ${bad_list%:}. Using DNS on ${PIHOLE_DNS_1} to download ${url}";
    echo -ne "  ${INFO} ${str} Pending..."
    cmd_ext="--resolve $domain:$port:$ip $cmd_ext"
  fi

  # shellcheck disable=SC2086
  httpCode=$(curl -s -L ${compression} ${cmd_ext} ${heisenbergCompensator} -w "%{http_code}" -A "${agent}" "${url}" -o "${patternBuffer}" 2> /dev/null)

  case $url in
    # Did we "download" a local file?
    "file"*)
      if [[ -s "${patternBuffer}" ]]; then
        echo -e "${OVER}  ${TICK} ${str} Retrieval successful"; success=true
      else
        echo -e "${OVER}  ${CROSS} ${str} Not found / empty list"
      fi;;
    # Did we "download" a remote file?
    *)
      # Determine "Status:" output based on HTTP response
      case "${httpCode}" in
        "200") echo -e "${OVER}  ${TICK} ${str} Retrieval successful"; success=true;;
        "304") echo -e "${OVER}  ${TICK} ${str} No changes detected"; success=true;;
        "000") echo -e "${OVER}  ${CROSS} ${str} Connection Refused";;
        "403") echo -e "${OVER}  ${CROSS} ${str} Forbidden";;
        "404") echo -e "${OVER}  ${CROSS} ${str} Not found";;
        "408") echo -e "${OVER}  ${CROSS} ${str} Time-out";;
        "451") echo -e "${OVER}  ${CROSS} ${str} Unavailable For Legal Reasons";;
        "500") echo -e "${OVER}  ${CROSS} ${str} Internal Server Error";;
        "504") echo -e "${OVER}  ${CROSS} ${str} Connection Timed Out (Gateway)";;
        "521") echo -e "${OVER}  ${CROSS} ${str} Web Server Is Down (Cloudflare)";;
        "522") echo -e "${OVER}  ${CROSS} ${str} Connection Timed Out (Cloudflare)";;
        *    ) echo -e "${OVER}  ${CROSS} ${str} ${url} (${httpCode})";;
      esac;;
  esac

  local done="false"
  # Determine if the blocklist was downloaded and saved correctly
  if [[ "${success}" == true ]]; then
    if [[ "${httpCode}" == "304" ]]; then
      # Add domains to database table file
      parseList "${adlistID}" "${saveLocation}" "${target}"
      database_adlist_status "${adlistID}" "2"
      database_adlist_number "${adlistID}"
      done="true"
    # Check if $patternbuffer is a non-zero length file
    elif [[ -s "${patternBuffer}" ]]; then
      # Determine if blocklist is non-standard and parse as appropriate
      gravity_ParseFileIntoDomains "${patternBuffer}" "${saveLocation}"
      # Add domains to database table file
      parseList "${adlistID}" "${saveLocation}" "${target}"
      # Compare lists, are they identical?
      compareLists "${adlistID}" "${saveLocation}"
      # Update gravity database table (status and updated timestamp are set in
      # compareLists)
      database_adlist_number "${adlistID}"
      done="true"
    else
      # Fall back to previously cached list if $patternBuffer is empty
      echo -e "  ${INFO} Received empty file"
    fi
  fi

  # Do we need to fall back to a cached list (if available)?
  if [[ "${done}" != "true" ]]; then
    # Determine if cached list has read permission
    if [[ -r "${saveLocation}" ]]; then
      echo -e "  ${CROSS} List download failed: ${COL_LIGHT_GREEN}using previously cached list${COL_NC}"
      # Add domains to database table file
      parseList "${adlistID}" "${saveLocation}" "${target}"
      database_adlist_number "${adlistID}"
      database_adlist_status "${adlistID}" "3"
    else
      echo -e "  ${CROSS} List download failed: ${COL_LIGHT_RED}no cached list available${COL_NC}"
      # Manually reset these two numbers because we do not call parseList here
      num_source_lines=0
      num_invalid=0
      database_adlist_number "${adlistID}"
      database_adlist_status "${adlistID}" "4"
    fi
  fi
}

# Parse source files into domains format
gravity_ParseFileIntoDomains() {
  local src="${1}" destination="${2}" firstLine

  # Determine if we are parsing a consolidated list
  #if [[ "${src}" == "${piholeDir}/${matterAndLight}" ]]; then
    # Remove comments and print only the domain name
    # Most of the lists downloaded are already in hosts file format but the spacing/formatting is not contiguous
    # This helps with that and makes it easier to read
    # It also helps with debugging so each stage of the script can be researched more in depth
    # 1) Remove carriage returns
    # 2) Convert all characters to lowercase
    # 3) Remove comments (text starting with "#", include possible spaces before the hash sign)
    # 4) Remove lines containing "/"
    # 5) Remove leading tabs, spaces, etc.
    # 6) Delete lines not matching domain names
    < "${src}" tr -d '\r' | \
    tr '[:upper:]' '[:lower:]' | \
    sed 's/[[:space:]]*#.*//g' | \
    sed -r '/(\/).*$/d' | \
    sed -r 's/^.*[[:space:]]+//g' | \
    sed -r '/([^\.]+\.)+[^\.]{2,}/!d' >  "${destination}"
    chmod 644 "${destination}"
    return 0
  #fi

  # Individual file parsing: Keep comments, while parsing domains from each line
  # We keep comments to respect the list maintainer's licensing
  read -r firstLine < "${src}"

  # Determine how to parse individual source file formats
  if [[ "${firstLine,,}" =~ (adblock|ublock|^!) ]]; then
    # Compare $firstLine against lower case words found in Adblock lists
    echo -e "  ${CROSS} Format: Adblock (list type not supported)"
  elif grep -q "^address=/" "${src}" &> /dev/null; then
    # Parse Dnsmasq format lists
    echo -e "  ${CROSS} Format: Dnsmasq (list type not supported)"
  elif grep -q -E "^https?://" "${src}" &> /dev/null; then
    # Parse URL list if source file contains "http://" or "https://"
    # Scanning for "^IPv4$" is too slow with large (1M) lists on low-end hardware
    echo -ne "  ${INFO} Format: URL"

    awk '
      # Remove URL scheme, optional "username:password@", and ":?/;"
      # The scheme must be matched carefully to avoid blocking the wrong URL
      # in cases like:
      #   http://www.evil.com?http://www.good.com
      # See RFC 3986 section 3.1 for details.
      /[:?\/;]/ { gsub(/(^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/(.*:.*@)?|[:?\/;].*)/, "", $0) }
      # Skip lines which are only IPv4 addresses
      /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { next }
      # Print if nonempty
      length { print }
    ' "${src}" 2> /dev/null > "${destination}"
    chmod 644 "${destination}"

    echo -e "${OVER}  ${TICK} Format: URL"
  else
    # Default: Keep hosts/domains file in same format as it was downloaded
    output=$( { mv "${src}" "${destination}"; } 2>&1 )
    chmod 644 "${destination}"

    if [[ ! -e "${destination}" ]]; then
      echo -e "\\n  ${CROSS} Unable to move tmp file to ${piholeDir}
    ${output}"
      gravity_Cleanup "error"
    fi
  fi
}

# Report number of entries in a table
gravity_Table_Count() {
  local table="${1}"
  local str="${2}"
  local num
  num="$(pihole-FTL sqlite3 "${gravityDBfile}" "SELECT COUNT(*) FROM ${table};")"
  if [[ "${table}" == "vw_gravity" ]]; then
    local unique
    unique="$(pihole-FTL sqlite3 "${gravityDBfile}" "SELECT COUNT(DISTINCT domain) FROM ${table};")"
    echo -e "  ${INFO} Number of ${str}: ${num} (${COL_BOLD}${unique} unique domains${COL_NC})"
    pihole-FTL sqlite3 "${gravityDBfile}" "INSERT OR REPLACE INTO info (property,value) VALUES ('gravity_count',${unique});"
  else
    echo -e "  ${INFO} Number of ${str}: ${num}"
  fi
}

# Output count of blacklisted domains and regex filters
gravity_ShowCount() {
  gravity_Table_Count "vw_gravity" "gravity domains" ""
  gravity_Table_Count "vw_blacklist" "exact blacklisted domains"
  gravity_Table_Count "vw_regex_blacklist" "regex blacklist filters"
  gravity_Table_Count "vw_whitelist" "exact whitelisted domains"
  gravity_Table_Count "vw_regex_whitelist" "regex whitelist filters"
}

# Create "localhost" entries into hosts format
gravity_generateLocalList() {
  # Empty $localList if it already exists, otherwise, create it
  echo "### Do not modify this file, it will be overwritten by pihole -g" > "${localList}"
  chmod 644 "${localList}"

  # Add additional LAN hosts provided by OpenVPN (if available)
  if [[ -f "${VPNList}" ]]; then
    awk -F, '{printf $2"\t"$1".vpn\n"}' "${VPNList}" >> "${localList}"
  fi
}

# Trap Ctrl-C
gravity_Trap() {
  trap '{ echo -e "\\n\\n  ${INFO} ${COL_LIGHT_RED}User-abort detected${COL_NC}"; gravity_Cleanup "error"; }' INT
}

# Clean up after Gravity upon exit or cancellation
gravity_Cleanup() {
  local error="${1:-}"

  str="Cleaning up stray matter"
  echo -ne "  ${INFO} ${str}..."

  # Delete tmp content generated by Gravity
  rm ${piholeDir}/pihole.*.txt 2> /dev/null
  rm ${piholeDir}/*.tmp 2> /dev/null
  rm /tmp/*.phgpb 2> /dev/null

  # Ensure this function only runs when gravity_SetDownloadOptions() has completed
  if [[ "${gravity_Blackbody:-}" == true ]]; then
    # Remove any unused .domains files
    for file in "${piholeDir}"/*."${domainsExtension}"; do
      # If list is not in active array, then remove it
      if [[ ! "${activeDomains[*]}" == *"${file}"* ]]; then
        rm -f "${file}" 2> /dev/null || \
          echo -e "  ${CROSS} Failed to remove ${file##*/}"
      fi
    done
  fi

  echo -e "${OVER}  ${TICK} ${str}"

  # Only restart DNS service if offline
  if ! pgrep pihole-FTL &> /dev/null; then
    "${PIHOLE_COMMAND}" restartdns
    dnsWasOffline=true
  fi

  # Print Pi-hole status if an error occurred
  if [[ -n "${error}" ]]; then
    "${PIHOLE_COMMAND}" status
    exit 1
  fi
}

database_recovery() {
  local result
  local str="Checking integrity of existing gravity database (this can take a while)"
  local option="${1}"
  echo -ne "  ${INFO} ${str}..."
  result="$(pihole-FTL sqlite3 "${gravityDBfile}" "PRAGMA integrity_check" 2>&1)"

  if [[ ${result} = "ok" ]]; then
    echo -e "${OVER}  ${TICK} ${str} - no errors found"

    str="Checking foreign keys of existing gravity database (this can take a while)"
    echo -ne "  ${INFO} ${str}..."
    unset result
    result="$(pihole-FTL sqlite3 "${gravityDBfile}" "PRAGMA foreign_key_check" 2>&1)"
    if [[ -z ${result} ]]; then
      echo -e "${OVER}  ${TICK} ${str} - no errors found"
      if [[ "${option}" != "force" ]]; then
        return
      fi
    else
      echo -e "${OVER}  ${CROSS} ${str} - errors found:"
      while IFS= read -r line ; do echo "  - $line"; done <<< "$result"
    fi
  else
    echo -e "${OVER}  ${CROSS} ${str} - errors found:"
    while IFS= read -r line ; do echo "  - $line"; done <<< "$result"
  fi

  str="Trying to recover existing gravity database"
  echo -ne "  ${INFO} ${str}..."
  # We have to remove any possibly existing recovery database or this will fail
  rm -f "${gravityDBfile}.recovered" > /dev/null 2>&1
  if result="$(pihole-FTL sqlite3 "${gravityDBfile}" ".recover" | pihole-FTL sqlite3 "${gravityDBfile}.recovered" 2>&1)"; then
    echo -e "${OVER}  ${TICK} ${str} - success"
    mv "${gravityDBfile}" "${gravityDBfile}.old"
    mv "${gravityDBfile}.recovered" "${gravityDBfile}"
    echo -ne " ${INFO} ${gravityDBfile} has been recovered"
    echo -ne " ${INFO} The old ${gravityDBfile} has been moved to ${gravityDBfile}.old"
  else
    echo -e "${OVER}  ${CROSS} ${str} - the following errors happened:"
    while IFS= read -r line ; do echo "  - $line"; done <<< "$result"
    echo -e "  ${CROSS} Recovery failed. Try \"pihole -r recreate\" instead."
    exit 1
  fi
  echo ""
}

helpFunc() {
  echo "Usage: pihole -g
Update domains from blocklists specified in adlists.list

Options:
  -f, --force          Force the download of all specified blocklists
  -h, --help           Show this help dialog"
  exit 0
}

repairSelector() {
  case "$1" in
    "recover") recover_database=true;;
    "recreate") recreate_database=true;;
    *) echo "Usage: pihole -g -r {recover,recreate}
Attempt to repair gravity database

Available options:
  pihole -g -r recover        Try to recover a damaged gravity database file.
                              Pi-hole tries to restore as much as possible
                              from a corrupted gravity database.

  pihole -g -r recover force  Pi-hole will run the recovery process even when
                              no damage is detected. This option is meant to be
                              a last resort. Recovery is a fragile task
                              consuming a lot of resources and shouldn't be
                              performed unnecessarily.

  pihole -g -r recreate       Create a new gravity database file from scratch.
                              This will remove your existing gravity database
                              and create a new file from scratch. If you still
                              have the migration backup created when migrating
                              to Pi-hole v5.0, Pi-hole will import these files."
    exit 0;;
  esac
}

for var in "$@"; do
  case "${var}" in
    "-f" | "--force" ) forceDelete=true;;
    "-r" | "--repair" ) repairSelector "$3";;
    "-h" | "--help" ) helpFunc;;
  esac
done

# Remove OLD (backup) gravity file, if it exists
if [[ -f "${gravityOLDfile}" ]]; then
  rm "${gravityOLDfile}"
fi

# Trap Ctrl-C
gravity_Trap

if [[ "${recreate_database:-}" == true ]]; then
  str="Recreating gravity database from migration backup"
  echo -ne "${INFO} ${str}..."
  rm "${gravityDBfile}"
  pushd "${piholeDir}" > /dev/null || exit
  cp migration_backup/* .
  popd > /dev/null || exit
  echo -e "${OVER}  ${TICK} ${str}"
fi

if [[ "${recover_database:-}" == true ]]; then
  database_recovery "$4"
fi

# Move possibly existing legacy files to the gravity database
if ! migrate_to_database; then
  echo -e "   ${CROSS} Unable to migrate to database. Please contact support."
  exit 1
fi

if [[ "${forceDelete:-}" == true ]]; then
  str="Deleting existing list cache"
  echo -ne "${INFO} ${str}..."

  rm /usr/local/etc/pihole/list.* 2> /dev/null || true
  echo -e "${OVER}  ${TICK} ${str}"
fi

# Gravity downloads blocklists next
if ! gravity_CheckDNSResolutionAvailable; then
  echo -e "   ${CROSS} Can not complete gravity update, no DNS is available. Please contact support."
  exit 1
fi

gravity_DownloadBlocklists

# Create local.list
gravity_generateLocalList

# Migrate rest of the data from old to new database
if ! gravity_swap_databases; then
  echo -e "   ${CROSS} Unable to create database. Please contact support."
  exit 1
fi

# Update gravity timestamp
update_gravity_timestamp

# Ensure proper permissions are set for the database
chown $PIHOLE_USER:$PIHOLE_GROUP "${gravityDBfile}"
chmod g+w "${piholeDir}" "${gravityDBfile}"

# Compute numbers to be displayed
gravity_ShowCount

# Determine if DNS has been restarted by this instance of gravity
if [[ -z "${dnsWasOffline:-}" ]]; then
  "${PIHOLE_COMMAND}" restartdns reload
fi

gravity_Cleanup
echo ""

"${PIHOLE_COMMAND}" status
