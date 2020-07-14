#!/usr/bin/env bash

if [ $EUID -ne 0 ]; then echo "Please run as root"; exit 1; fi

ENABLE_LOGGING=1
LOG_FILE="/var/log/ipset-update.log"
log(){
  [ $# -gt 0 ] && msg="$1" || msg=$(cat /dev/stdin)
  [ -z "$msg" ] && return 0
  echo "$msg"
  [ "$ENABLE_LOGGING" -ne "1" ] && return 0
  echo "$(date '+%F %T') - $msg" >> "$LOG_FILE"
}

log "$(printf %60s ' ' | tr ' ' '-')" > /dev/null

LISTDIR=/var/cache/blocklists

if [ "$1" = "-u" ]; then
  log "Running ipset-update uninstall..."
  log "Removing scheduled startup update /etc/cron.d/ipset-update-boot"
  rm /etc/cron.d/ipset-update-boot
  log "Removing scheduled daily update /etc/cron.daily/ipset-update"
  rm /etc/cron.daily/ipset-update
  log "Removing ipset-update iptables rules"
  iptables-save | grep -v ipset-update | iptables-restore
  read -p "Remove /etc/blocklists config? " -n 1 -r; echo;
  if [ "$(echo "$REPLY" | tr '[:upper:]' '[:lower:]')" = "y" ]; then
    log "Removing configuration"
    rm /etc/blocklists/iblocklist.*
    rm /etc/blocklists/ipset-update.conf*
    rmdir /etc/blocklists 2>&1 | log
  fi

  for filename in "$LISTDIR"/*; do
    [ ! -f "$filename" ] && continue
    bname=$(basename "$filename")
    list=${bname%%.*}
    log "Removing ipset (and cache) $filename"
    if [ -n "$list" ]; then
      ipset destroy "$list" 2>&1 | log
    fi
    rm "$filename"
  done
  log "Removing cache folder"
  rmdir "$LISTDIR" 2>&1 | log
  log "Done."
  exit 0
fi


log "Running ipset-update setup..."

confdir=/etc/blocklists # path also hardcoded in ipset-update.sh
echo Creating configuration in $confdir
[ ! -d "$confdir" ] && mkdir "$confdir"

cp iblocklist.lists.default $confdir
if [ ! -f $confdir/iblocklist.lists ]; then
  cp $confdir/iblocklist.lists.default $confdir/iblocklist.lists
else
  log "Preserved existing $confdir/iblocklist.lists"
fi

cp ipset-update.conf.default $confdir
if [ ! -f $confdir/ipset-update.conf ]; then
  cp $confdir/ipset-update.conf.default $confdir/ipset-update.conf
else
  log "Preserved existing $confdir/ipset-update.conf"
fi

credpath=$confdir/iblocklist.cred # path also hardcoded in ipset-update.sh
skipCred=0
if [ -f "$credpath" ]; then
  . "$credpath"
  if [ -n "$IBL_USER" ] && [ -n "$IBL_PIN" ]; then
    printf "\nI-Blocklist subscription credentials exist in %s\n" "$credpath"
    read -p "Recreate? " -n 1 -r; echo;
    [ "$(echo "$REPLY" | tr '[:upper:]' '[:lower:]')" = "y" ] || skipCred=1
  fi
fi
if [ "$skipCred" != "1" ]; then
  printf "\nEnter I-BlockList subscription credentials if you have them.\n"
  printf "  Leave this blank if not, but many blocklists require it.\n"
  printf "  More info at %s\n" "$confdir/iblocklist.lists"
  printf "  Credentials can be changed later at %s\n" "$credpath"
  printf "user? "
  read ibluser
  printf "pin? "
  read iblpin
  printf "# credentials for iblocklist subscriptions\n" > $credpath
  printf "# if either is not set, credentials will not be provided during updates\n" >> $credpath
  printf "# IBL and SBL lists are paid subscriptions and require credentials\n" >> $credpath
  printf "IBL_USER=%s\n" "$ibluser" >> $credpath
  printf "IBL_PIN=%s\n" "$iblpin" >> $credpath
  log "Created $credpath"
fi

log "Scheduling ipset-update to run daily"
cp ipset-update.sh /etc/cron.daily/ipset-update # no '.sh' extensions here

log "Scheduling ipset-update to run at startup"
printf "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n" > /etc/cron.d/ipset-update-boot
printf "@reboot root /etc/cron.daily/ipset-update\n" >> /etc/cron.d/ipset-update-boot

log "Setup complete.  Set your lists at $confdir/iblocklist.lists"
echo

# ex: et sw=2 sts=2
