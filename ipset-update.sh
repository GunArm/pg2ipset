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

log(){
  [ -n "$1" ] && msg="$1" || read msg
  [ -z "$msg" ] && return 0
  echo $msg
  [ "$ENABLE_LOGGING" -ne "1" ] && return 0
  echo $(date "+%F %T")" - "$msg >> "$LOG_FILE"
}

findConf(){
  if [ -f "$(pwd)/$1" ]; then echo "$(pwd)/$1"
  elif [ -f "/etc/blocklists/$1" ]; then echo "/etc/blocklists/$1"
  elif [ -f "$(pwd)/$1.default" ]; then echo "$(pwd)/$1.default"
  elif [ -f "/etc/blocklists/$1.default" ]; then echo "/etc/blocklists/$1.default"
  fi
}

blockRules=
importList(){
  if [ ! -f $LISTDIR/$1.txt ] && [ ! -f $LISTDIR/$1.gz ]; then
    log "FAILED attempted import! List $LISTDIR/$1.[txt,gz] does not exist."
    return 1
  fi

  log "Updating ipset $1..."
  ipset create -exist $1 hash:net maxelem 4294967295
  ipset create -exist $1-TMP hash:net maxelem 4294967295
  ipset flush $1-TMP &> /dev/null

  #the second param determines if we need to use zcat or not
  if [ $2 = 1 ]; then
    zcat $LISTDIR/$1.gz | grep  -v \# | grep -v ^$ | grep -v 127\.0\.0 | pg2ipset - - $1-TMP | ipset restore
  else
    awk '!x[$0]++' $LISTDIR/$1.txt | grep  -v \# | grep -v ^$ |  grep -v 127\.0\.0 | sed -e "s/^/add\ \-exist\ $1\-TMP\ /" | ipset restore
  fi

  ipset swap $1 $1-TMP &> /dev/null
  oldCount=$(ipset list $1-TMP | grep "entries" | awk '{print $4}')
  newCount=$(ipset list $1 | grep "entries" | awk '{print $4}')
  log "Set $1 length changed from $oldCount to $newCount"
  ipset destroy $1-TMP &> /dev/null

  # stage rules to apply atomically later.
  # log rules will be skipped unless $IPT_LOG is set in config
  add=
  [ -n "$IPT_LOG" ] && add="${add}-A INPUT -m set --match-set $1 src -m comment --comment ipset-update -j $IPT_LOG \"Blocked src input $1\"\n"
  add="${add}-A INPUT -m set --match-set $1 src -m comment --comment ipset-update -j DROP\n"
  [ -n "$IPT_LOG" ] && add="${add}-A FORWARD -m set --match-set $1 src -m comment --comment ipset-update -j $IPT_LOG \"Blocked src fwd $1\"\n"
  add="${add}-A FORWARD -m set --match-set $1 src -m comment --comment ipset-update -j DROP\n"
  [ -n "$IPT_LOG" ] && add="${add}-A FORWARD -m set --match-set $1 dst -m comment --comment ipset-update -j $IPT_LOG \"Blocked dst fwd $1\"\n"
  add="${add}-A FORWARD -m set --match-set $1 dst -m comment --comment ipset-update -j REJECT\n"
  [ -n "$IPT_LOG" ] && add="${add}-A OUTPUT -m set --match-set $1 dst -m comment --comment ipset-update -j $IPT_LOG \"Blocked dst out $1\"\n"
  add="${add}-A OUTPUT -m set --match-set $1 dst -m comment --comment ipset-update -j REJECT\n"
  blockRules="${blockRules}${add}"
}

applyIptablesRules(){
  #get ruleset with our previous rules dropped
  prevRuleset=$(iptables-save | grep -v ipset-update)
  # get everything to the end of the *filter section, ending just before COMMIT
  preBlockRules="$(printf "$prevRuleset" | awk '/COMMIT/{if(filter)exit} {print} /\*filter/{filter=1}')"
  # get the COMMIT terminating *filter and everything afterwards
  postBlockRules=$(printf "$prevRuleset" | awk '/COMMIT/{if(filter)filterCommitted=1} {if(filterCommitted)print} /\*filter/{filter=1}')
  newRuleset="$preBlockRules\n$blockRules\n$postBlockRules"
  printf "Applying iptables rules\n$newRuleset\n"
  printf "$newRuleset" | iptables-restore
}

#####################


confPath=$(findConf ipset-update.conf)
if [ -z "$confPath" ]; then
  echo "No ipset-update.conf[.default] found in /etc/blocklists or $(pwd)"
  exit 1
fi

. $confPath   # source in config file

log "Running blocklist update.  Config file is $confPath"

# place to keep our cached blocklists
LISTDIR="/var/cache/blocklists"

# create cache directory for our lists if it isn't there
[ ! -d $LISTDIR ] && mkdir $LISTDIR

# remove old countries list
[ -f $LISTDIR/countries.txt ] && rm $LISTDIR/countries.txt

# remove the old tor node list
[ -f $LISTDIR/tor.txt ] && rm $LISTDIR/tor.txt


if [ $ENABLE_IBLOCKLIST = 1 ]; then
  log "Updating iblocklist lists..."

  # find credentials for iblocklist
  credPath=$(findConf iblocklist.cred)
  if [ -z "$credPath" ]; then
    log "No iblocklist.cred[.default] found in /etc/blocklists or $(pwd)"
  else
    . $credPath   #souce in credentials file
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
    log "No iblocklist.lists[.default] found in /etc/blocklists or $(pwd)"
  fi
  IFS="="
  while read -r name value
  do
    # clean leading/trailing whitespace and quotes
    name=$(echo ${name//\"/} | awk '{$1=$1};1'); value=$(echo ${value//\"/} | awk '{$1=$1};1')
    # ignore comments and lines without both name and key
    [ -z "$name" ] || [ -z "$value" ] || [ ${name:0:1} = "#" ] && continue
    IBLNAME+=($name); IBLKEY+=($value)
  done < $listPath
  IFS=" "
  log "Config $listPath specifies ${#IBLNAME[@]} enabled lists: ${IBLNAME[*]}"
  IFS=

  # get, parse, and import the iblocklist lists
  # they are special in that they are gz compressed and require
  # pg2ipset to be inserted
  for i in ${!IBLKEY[@]}; do
    name=${IBLNAME[i]}; list=${IBLKEY[i]};
    if [ eval $(wget --quiet -O /tmp/$name.gz "http://list.iblocklist.com/?list=$list&fileformat=p2p&archiveformat=gz$cred") ]; then
      mv /tmp/$name.gz $LISTDIR/$name.gz
      log "Retrieved iblocklist $name"
    else
      log "FAILED retrieving iblocklist $name.  Cache will be used."
    fi

    importList $name 1
  done
  log "Finished iblocklist update"
fi

if [ $ENABLE_COUNTRY = 1 ]; then
  IFS=" "
  log "Updating country blocklist.  ${#COUNTRIES[@]} specified: ${COUNTRIES[*]}"
  IFS=""
  # get the country lists and cat them into a single file
  for country in ${COUNTRIES[@]}; do
    if [ eval $(wget --quiet -O /tmp/$country.txt "http://www.ipdeny.com/ipblocks/data/countries/$country.zone") ]; then
      cat /tmp/$country.txt >> $LISTDIR/countries.txt
      rm /tmp/$country.txt
      log "Retrieved ipdeny list for country \'$country\'"
    else
      log "FAILED retrieving ipdeny list for country \'$country\'.  No ips for $country will be blocked!"
    fi
  done
  
  importList "countries" 0
  log "Finished country blocklist update"
fi

if [ $ENABLE_TORBLOCK = 1 ]; then
  IFS=" "
  log "Updating tor blocklist.  ${#PORTS[@]} specified to block tor users from: ${PORTS[*]}"
  IFS=""
  # get the tor lists and cat them into a single file
  for ip in $(ip -4 -o addr | awk '!/^[0-9]*: ?lo|link\/ether/ {gsub("/", " "); print $4}'); do
    for port in ${PORTS[@]}; do
      if [ eval $(wget --quiet -O /tmp/$port.txt "https://check.torproject.org/cgi-bin/TorBulkExitList.py?ip=$ip&port=$port") ]; then
        cat /tmp/$port.txt >> $LISTDIR/tor.txt
        rm /tmp/$port.txt
        log "Retrieved Tor Bulk Exit List for $ip:$port"
      else
        log "FAILED retrieving Tor Bulk Exit List for $ip:$port.  No ips for $ip:$port will be blocked!"
      fi
    done
  done 
  
  importList "tor" 0
  log "Finished tor blocklist update"
fi

# add any custom import lists below
# example: importList "custom"  # (would expect a txt list at $LISTDIR/custom.txt)

log "Recreating iptables rules for enabled lists..."
applyIptablesRules

log "Completed ipset blocklist update"

# ex: et sw=2 sts=2
