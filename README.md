========
ABOUT
========

### What

This is a solution for blocking large maintained lists of malicious/untrusted IP addresses, provided primarily (but not exclusively) by iBlocklist.

It serves as lightweight, simple alternative to programs like PeerGuardian Linux, iplist/ipblock, MoBlock, etc, each of which seem to have gone out of maintenance.

Uniquely, this project makes use of ipset for much more efficient hash-based matching.

### How

Lists of IPs are blocked via linux native firewall rules which are efficiently matched by the IP set framework in the kernel.  IP sets are large lists of ip addresses that can be matched by iptables rules via hashes rather than linear searches, increasing the speed of the routing tables given a great many involved ips.

The IP set feature of Netfilter is not new, having become widely available in the early 2010's.  Yet oddly, as of the late 2010s, it seems that none of the main ip blockers take advantage of this feature -- probably due to being unmaintained for most of the last decade.  Anyway, making use of ipsets is the driving idea of this project.

### More

http://ipset.netfilter.org/

https://wiki.archlinux.org/index.php/Ipset

http://www.maeyanie.com/2008/12/efficient-iptables-peerguardian-blocklist/

pg2ipset takes the contents of PG2 IP Blocklists and outputs lists that
ipset under Linux can consume, for more efficient blocking than most 
other methods. 

The ipset-update.sh script helps import these and
plain text based blocklists easily, for scheduling via cron.

======== 
SETUP
========

### Install

```# ./setup.sh```

The easiest way to get started blocking IPs is to download this project and run setup.sh which will do the following

* Build and install the pg2ipset tool which converts pg2 formatted ip lists into a format readable by ipset
* Create the default configuration files in /etc/blocklists/
* Prompt you for credentials in case you subscribe to iBlocklist's paid lists
* Copy the update script into /etc/cron.daily for daily updating of rules
* Create a cron.d file to run the update script on reboot so you're not without filter rules until the next morning
* Preserve any previously existing config

After running setup, you'll likely want to edit the `/etc/blocklists/iblocklist.lists` file to set your selection of lists to apply rules for.  To enable a list, simply uncomment it, and comment it to disable.  The file contains all currently maintained iBlocklist offerings shown at https://www.iblocklist.com/lists.php in the order listed there.  You will also find descriptions of the various lists on that page.  Note that many of the lists require subscription to iBlocklist, which should be made obvious in the .lists file, as well as when viewing [the list info page](https://www.iblocklist.com/lists.php) while not logged in.

After that you should be good to go.  You might want to manually run the update script in /etc/cron.daily/ipset-update in order to see that there are no errors.  And then keep an eye on the log file in /var/log/ipset-update.log for a few days in order to see the that updates are getting run once per day and at at bootup.  Bootup updating is important since the filter rules do not persist across a reboot, but it's not nice to hammer the list server so be mindful of this if you expect to reboot frequently.

### Uninstall

There is an uninstall feature in the setup script, accessed `# ./setup.sh -u` which reverses the setup, does it's best to safely clean up up the current ipsets and iptables rules, deletes the cache, and optionally deletes the configs.

========
CONFIGURATION
========

The updater makes use of 3 config files

`ipset-update.conf` - general settings; logging and alternate blocking methods

`iblocklist.lists` - selection of iblocklist lists to be applied

`iblocklist.cred` - optional file holds iblocklist subscription credentials

Setup.sh will put these files in `/etc/blocklists/` and that is the location where the update script will look first.  If not found there, they will be read from the directory where the script is located.  This allows the update script to be run portably (without setup.sh) so long as the config files follow the update script to whatever it's destination.

If those filenames are still not found, the .default files will be read as a further fallback.  Thus, technically you can edit the .default files, but ideally make a copy without ".default" (like setup.sh does) so that the defaults are preserved and personal config is not accidentally pushed (.list, .conf, .cred are gitignored).  The  config file locations found and used for an update will be logged during that update.

Successive runs of setup.sh will *not* overwrite your non-default config files.

========
LOGGING
========

The log file /var/log/ipset-update.log only contains logs related to the updating of the lists and their ipsets.

Logging of actual blocked ip addresses is (only slightly) more complicated as it depends on an external package.  The ULOG method has been deprecated in favor of NFLOG and most likely what you need to do is install the package "ulogd2" and then in the /etc/blocklists/ipset-update.conf file, uncomment the IPT_LOG="NFLOG --nflog-prefix"

========
PG2IPSET SOLO
========

pg2ipset can be used independently of the rest of the project

### Install

```make build && make install```

(or just run make as root)

### Usage

The pg2 format is a simple line delineated file of entries in the form `description:fromAddr-toAddr`.  As the name implies, pg2ipset takes pg2 as input, drops the descriptions, and creates ipset entries from the ip ranges, which can be piped into `ipset restore`.

To manually import from a .txt list from iBlocklist or any other pg2 format text input:

```cat /path/to/blocklist.txt | pg2ipset - - listname | ipset restore```


To manually import from a .gz list:

```zcat /path/to/blocklist.gz | pg2ipset - - listname | ipset restore```

To manually import a txt list of only IP addresses and/or CIDR ranges, 
make sure to remove all comments and empty lines, then do the following:

```awk '!x[$0]++' /path/to/blocklist.txt | sed -e "s/^/\-A\ \-exist\ listname\ /" | grep  -v \# | grep -v ^$ | ipset restore```

Help text:
	Usage: ./pg2ipset [<input> [<output> [<set name>]]]
	Input should be a PeerGuardian .p2p file, blank or '-' reads from stdin.
	Output is suitable for usage by 'ipset restore', blank or '-' prints to stdout.
	Set name is 'IPFILTER' if not specified.
	Example: curl http://www.example.com/guarding.p2p | ./pg2ipset | ipset restore

========
CRON SCHEDULING
========

The update script can be manually scheduled with cron, for example with `crontab -e` or in a cron.d file:

```0 0 * * * sh /path/to/ipset-update.sh >/dev/null 2>&1```

You might need to provide a path variable that includes the pg2ipset install location.

Be friendly and don't update more than once every 24 hours.

========
LICENSE
========

	pg2ipset.c - Convert PeerGuardian lists to IPSet scripts.
	Copyright (C) 2009-2010, me@maeyanie.com
	
	ipset-update.sh - Automatically update and import pg2 format
	and text based ipset blocklists.
	Copyright (C) 2012-2015, parwok@gmail.com
	
	This program is free software; you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation; either version 2 of the License, or
	(at your option) any later version.
	
	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.
	
	You should have received a copy of the GNU General Public License along
	with this program; if not, write to the Free Software Foundation, Inc.,
	51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
