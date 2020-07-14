#!/bin/bash

find-blocking-ipset() {
  local test_ip=$1
  local IFS=$'\n'
  for setname in $(sudo ipset -n list); do 
    sudo ipset test "$setname" "$test_ip" 2>/dev/null && echo "$setname"
  done
}

mypg2ipset () {
  listName=$1
  grep -a -v -e \# -e ^$ -e 127\\.0\\.0\\. | awk -F: -vname=$listName '{print "add -exist "name" "$2"\n"} END { print "COMMIT" }'
}
