#!/usr/bin/env bash
#
# ipset-update.sh (C) 2012-2015 Matt Parnell http://www.mattparnell.com
# Licensed under the GNU-GPLv2+
#
# This script updates ipset rules based on lists from iblocklist
#
# config: /etc/blocklists/ipset-update.conf
# iblocklist list selection: /etc/blocklists/iblocklist.lists
# iblocklist subscription pin: /etc/blocklists/iblocklist.cred
# for running portably, configs will also be read from current dir
# if config is in neither location, it will try to read the defaults

if [ $EUID -ne 0 ]; then echo "Please run as root"; exit 1; fi

#####################

convert-pg2-ipset(){
  listName=$1
  [ -z "$listName" ] && listName="noname-$(date +"%Y%m%d")"
  grep -a -v -e \# -e ^$ -e 127\\.0\\.0\\. | # remove #comment_lines, empty lines, localhost references
  awk -F: -vname=$listName '{print "add -exist "name" "$NF} END { print "COMMIT" }' | # convert pg2 to ipset
  awk '!x[$0]++' # remove duplicate lines (without sorting)
}

convert-rawlist-ipset(){
  # allows parsing lists with inline commented descriptions
  listName=$1
  [ -z "$listName" ] && listName="noname-$(date +"%Y%m%d")"
  sed -e 's/\#.*$//' -e 's/[[:space:]]//g' | # remove comments, preserving whats before them, strip *all* whitespace
  grep -v -e '^$' | # remove empty lines
  grep -v -e 127\\.0\\.0\\. | # remove localhost lines
  awk -vname=$listName '{print "add -exist "name" "$1} END { print "COMMIT" }' | # convert list to ipset
  awk '!x[$0]++' # remove duplicate lines (without sorting)
}

log(){
  [ $# -gt 0 ] && msg="$1" || msg=$(cat /dev/stdin)
  [ -z "$msg" ] && return 0
  echo "$msg"
  [ "$ENABLE_LOGGING" -ne "1" ] && return 0
  echo "$(date '+%F %T') - $msg" >> "$LOG_FILE"
}

scriptDir=$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd -P)
findConf(){
  if [ -f "$scriptDir/$1" ]; then echo "$scriptDir/$1"
  elif [ -f "/etc/blocklists/$1" ]; then echo "/etc/blocklists/$1"
  elif [ -f "$scriptDir/$1.default" ]; then echo "$scriptDir/$1.default"
  elif [ -f "/etc/blocklists/$1.default" ]; then echo "/etc/blocklists/$1.default"
  fi
}

blockRules=
importListFile(){
  file=$1
  name=${file%.*}
  if [ ! -f "$LISTDIR/$file" ]; then
    log "FAILED attempted import! List $LISTDIR/$file does not exist."
    return 1
  fi

  if [ "$2" != "gz" ] && [ "$2" != "raw" ]; then
    log "No/Bad input format provided (gz,raw)"
    return 1
  fi
  in_fmt=$2

  if [ "$3" != "block" ] && [ "$3" != "allow" ]; then
    log "No/Bad firewall action specified (block,allow)"
    return 1
  fi
  action=$3

  log "Updating ipset $name..."
  ipset create -exist "$name" hash:net maxelem 4294967295
  ipset create -exist "$name-TMP" hash:net maxelem 4294967295
  ipset flush "$name-TMP" &> /dev/null

  #the second param determines if we need to use zcat or not
  if [ "$in_fmt" == "gz" ]; then
    (zcat "$LISTDIR/$file" | convert-pg2-ipset "$name-TMP" | ipset restore) 2>&1 | log
  elif [ "$in_fmt" == "raw" ]; then
    (cat "$LISTDIR/$file" | convert-rawlist-ipset "$name-TMP" | ipset restore) 2>&1 | log
  else
    log "Unrecognized input format"
    return 1
  fi

  ipset swap "$name" "$name-TMP" &> /dev/null
  oldCount=$(ipset list "$name-TMP" | awk '{if(m)print} /Members:/{m=1}' | wc -l)
  newCount=$(ipset list "$name" | awk '{if(m)print} /Members:/{m=1}' | wc -l)
  log "Set $name length changed from $oldCount to $newCount"
  ipset destroy "$name-TMP" &> /dev/null

  if [ "$action" == "block" ]; then
    # stage block rules to apply atomically later.
    # log rules will be skipped unless $IPT_LOG is set in config
    add=
    [ -n "$IPT_LOG" ] && add="${add}-A INPUT -m set --match-set $name src -m comment --comment ipset-update -j $IPT_LOG \"Blocked src input $name\"\n"
    add="${add}-A INPUT -m set --match-set $name src -m comment --comment ipset-update -j DROP\n"
    [ -n "$IPT_LOG" ] && add="${add}-A FORWARD -m set --match-set $name src -m comment --comment ipset-update -j $IPT_LOG \"Blocked src fwd $name\"\n"
    add="${add}-A FORWARD -m set --match-set $name src -m comment --comment ipset-update -j DROP\n"
    [ -n "$IPT_LOG" ] && add="${add}-A FORWARD -m set --match-set $name dst -m comment --comment ipset-update -j $IPT_LOG \"Blocked dst fwd $name\"\n"
    add="${add}-A FORWARD -m set --match-set $name dst -m comment --comment ipset-update -j REJECT\n"
    [ -n "$IPT_LOG" ] && add="${add}-A OUTPUT -m set --match-set $name dst -m comment --comment ipset-update -j $IPT_LOG \"Blocked dst out $name\"\n"
    add="${add}-A OUTPUT -m set --match-set $name dst -m comment --comment ipset-update -j REJECT\n"
    blockRules="${blockRules}${add}"
  elif [ "$action" == "allow" ]; then
    # stage allow rules to apply atomically later.
    add=
    add="${add}-A INPUT -m set --match-set $name src -m comment --comment ipset-update -j ACCEPT\n"
    add="${add}-A FORWARD -m set --match-set $name src -m comment --comment ipset-update -j ACCEPT\n"
    add="${add}-A FORWARD -m set --match-set $name dst -m comment --comment ipset-update -j ACCEPT\n"
    add="${add}-A OUTPUT -m set --match-set $name dst -m comment --comment ipset-update -j ACCEPT\n"
    blockRules="${blockRules}${add}"
  else
    log "Unrecognized firewall action"
    return 1
  fi
}

applyIptablesRules(){
  #get ruleset with our previous rules dropped
  prevRuleset=$(iptables-save | grep -v ipset-update)
  # get everything to the end of the *filter section, ending just before COMMIT
  preBlockRules="$(printf %b "$prevRuleset" | awk '/COMMIT/{if(filter)exit} {print} /\*filter/{filter=1}')"
  # get the COMMIT terminating *filter and everything afterwards
  postBlockRules=$(printf %b "$prevRuleset" | awk '/COMMIT/{if(filter)filterCommitted=1} {if(filterCommitted)print} /\*filter/{filter=1}')
  newRuleset="$preBlockRules\n$blockRules\n$postBlockRules"
  printf "Applying iptables rules\n%b\n" "$newRuleset"
  if ! result=$(printf %b "$newRuleset" | iptables-restore 2>&1); then
    log "$result"
    log "FAILED to apply filter rules!"
    exit 1
  fi
}

#####################


confPath=$(findConf ipset-update.conf)
if [ -z "$confPath" ]; then
  echo "No ipset-update.conf[.default] found in /etc/blocklists or $scriptDir"
  exit 1
fi

. "$confPath"   # source in config file

log "$(printf %60s ' ' | tr ' ' '-')" > /dev/null
log "Running blocklist update.  Config file is $confPath"

# place to keep our cached blocklists
LISTDIR="/var/cache/blocklists"

# create cache directory for our lists if it isn't there
[ ! -d "$LISTDIR" ] && mkdir -p $LISTDIR
if [ ! -d "$LISTDIR" ]; then
  log "Could not create blocklist cache dir $LISTDIR (LISTDIR in $confPath)"
  exit 1
fi

# remove old countries list
[ -f "$LISTDIR/countries.txt" ] && rm "$LISTDIR/countries.txt"

# remove the old tor node list
[ -f "$LISTDIR/tor.txt" ] && rm "$LISTDIR/tor.txt"


if [ "$ENABLE_IBLOCKLIST" = 1 ]; then
  log "Updating iblocklist lists..."

  # find credentials for iblocklist
  credPath=$(findConf iblocklist.cred)
  if [ -z "$credPath" ]; then
    log "No iblocklist.cred[.default] found in /etc/blocklists or $scriptDir"
  else
    . "$credPath"   #souce in credentials file
    if [ -n "$IBL_USER" ] && [ -n "$IBL_PIN" ]; then
      cred="&username=$IBL_USER&pin=$IBL_PIN"
      log "Got credentials from $credPath user is $IBL_USER"
    else
      log "No credentials provided in $credPath"
    fi
  fi

  # find list config and parse into arrays
  listPath=$(findConf iblocklist.lists)
  if [ -z "$listPath" ]; then
    log "No iblocklist.lists[.default] found in /etc/blocklists or $scriptDir"
  fi
  IFS="="
  while read -r name value
  do
    # clean leading/trailing whitespace and quotes
    name=$(echo "${name//\"/}" | awk '{$1=$1};1'); value=$(echo "${value//\"/}" | awk '{$1=$1};1')
    # ignore comments and lines without both name and key
    [ -z "$name" ] || [ -z "$value" ] || [ "${name:0:1}" = "#" ] && continue
    IBLNAME+=($name); IBLKEY+=($value)
  done < "$listPath"
  IFS=" "
  log "Config $listPath specifies ${#IBLNAME[@]} enabled lists: ${IBLNAME[*]}"
  IFS=

  # get, parse, and import the iblocklist lists
  # they are gz compressed and in pg2 format
  for i in "${!IBLKEY[@]}"; do
    name=${IBLNAME[i]}; list=${IBLKEY[i]};
    if wget --quiet -O "/tmp/$name.gz" "http://list.iblocklist.com/?list=$list&fileformat=p2p&archiveformat=gz$cred"; then
      mv "/tmp/$name.gz" "$LISTDIR/$name.gz"
      log "Retrieved iblocklist $name"
    else
      log "FAILED retrieving iblocklist $name.  Cache will be used."
    fi

    importListFile "${name}.gz" gz block
  done
  log "Finished iblocklist update"
fi

if [ "$ENABLE_COUNTRY" = 1 ]; then
  IFS=" "
  log "Updating country blocklist.  ${#COUNTRIES[@]} specified: ${COUNTRIES[*]}"
  IFS=""
  # get the country lists and cat them into a single file
  for country in "${COUNTRIES[@]}"; do
    if wget --quiet -O "/tmp/$country.txt" "http://www.ipdeny.com/ipblocks/data/countries/$country.zone"; then
      cat "/tmp/$country.txt" >> "$LISTDIR/countries.txt"
      rm "/tmp/$country.txt"
      log "Retrieved ipdeny list for country \'$country\'"
    else
      log "FAILED retrieving ipdeny list for country \'$country\'.  No ips for $country will be blocked!"
    fi
  done
  
  importListFile "countries.txt" raw block
  log "Finished country blocklist update"
fi

if [ "$ENABLE_TORBLOCK" = 1 ]; then
  IFS=" "
  log "Updating tor blocklist.  ${#PORTS[@]} specified to block tor users from: ${PORTS[*]}"
  IFS=""
  # get the tor lists and cat them into a single file
  for ip in $(ip -4 -o addr | awk '!/^[0-9]*: ?lo|link\/ether/ {gsub("/", " "); print $4}'); do
    for port in "${PORTS[@]}"; do
      if wget --quiet -O "/tmp/$port.txt" "https://check.torproject.org/cgi-bin/TorBulkExitList.py?ip=$ip&port=$port"; then
        cat "/tmp/$port.txt" >> "$LISTDIR/tor.txt"
        rm "/tmp/$port.txt"
        log "Retrieved Tor Bulk Exit List for $ip:$port"
      else
        log "FAILED retrieving Tor Bulk Exit List for $ip:$port.  No ips for $ip:$port will be blocked!"
      fi
    done
  done 
  
  importListFile "tor.txt" raw block
  log "Finished tor blocklist update"
fi

# add any custom import lists below
# example: importList "custom"  # (would expect a txt list at $LISTDIR/custom.txt)

log "Recreating iptables rules for enabled lists..."
applyIptablesRules

log "Completed ipset blocklist update"

# ex: et sw=2 sts=2
