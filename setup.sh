#!/bin/bash

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


# schedule update to run daily
cp ipset-update.sh /etc/cron.daily/ipset-update # no '.sh' extensions here

