#!/bin/bash

find-blocking-ipset() {
  local test_ip=$1
  local IFS=$'\n'
  for setname in $(sudo ipset -n list); do 
    sudo ipset test "$setname" "$test_ip" 2>/dev/null && echo "$setname"
  done
}
