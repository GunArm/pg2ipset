#!/usr/bin/env bash

if [ $EUID -ne 0 ]; then echo "Please run as root"; exit 1; fi

# build and install pg2ipset.c
make build && make install && make clean 2>&1 | log
if [ $? -ne  0 ]; then
  echo Failed to install pg2ipset tool!
  exit 1
fi


confdir=/etc/blocklists # path also hardcoded in ipset-update.sh
echo Creating configuration in $confdir
[ ! -d $confdir ] && mkdir $confdir
cp iblocklist.lists.default $confdir
if [ ! -f $confdir/iblocklist.lists ]; then
  cp $confdir/iblocklist.lists.default $confdir/iblocklist.lists
fi


credpath=$confdir/iblocklist.cred # path also hardcoded in ipset-update.sh
skipCred=0
if [ -f "$credpath" ]; then
  . $credpath
  if [ -n "$IBL_USER" ] && [ -n "$IBL_PIN" ]; then
    printf "\nI-Blocklist subscription credentials exist in $credPath\n"
    read -p "Recreate? " -n 1 -r; echo;
    [ "$(echo "$REPLY" | tr '[:upper:]' '[:lower:]')" = "y" ] || skipCred=1
  fi
fi
if [ "$skipCred" != "1" ]; then
  printf "\nEnter I-BlockList subscription credentials if you have them.\n"
  printf "  Leave this blank if not, but many blocklists require it.\n"
  printf "  More info at $confdir/iblocklist.lists\n"
  printf "  Credentials can be changed later at $credpath\n"
  printf "user? "
  read ibluser
  printf "pin? "
  read iblpin
  printf "# credentials for iblocklist subscriptions\n" > $credpath
  printf "# if either is not set, credentials will not be provided during updates\n" >> $credpath
  printf "# IBL and SBL lists are paid subscriptions and require credentials\n" >> $credpath
  printf "IBL_USER=$ibluser\n" >> $credpath
  printf "IBL_PIN=$iblpin\n" >> $credpath
  log "Created $credpath"
fi

echo Scheduling update to run daily
cp ipset-update.sh /etc/cron.daily/ipset-update # no '.sh' extensions here

