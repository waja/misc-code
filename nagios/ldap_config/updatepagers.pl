#!/usr/bin/perl
#
# updatepagers.pl  -  Creates Nagios Pager contacts out of LDAP group
#
# Version 1.02
#
# Copyright (C) 2008 Thomas Guyot-Sionnest <tguyot@gmail.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#


use strict;
use warnings;

## CONFIG SECTION ##

# Program to run to dump pager contacts data
my $dumpapp = '/usr/local/bin/getadpagers.pl';

# New pagers dump. This should be written by $dumpapp
my $newdump = '/tmp/pagers.txt.new';

# Backup from the last run. Can be anything but $newdump
my $olddump = '/tmp/pagers.txt.old';

# Temp file
my $tempcfg = '/tmp/pagerscontacts.cfg.new';

# Full path of the final config
my $cfgfile = '/usr/local/nagios/etc/pagercontacts.cfg';

# Config test command
my $cfgtestrun = '/usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg >/dev/null 2>/dev/null';

# Config reload command
my $cfgreloadrun = 'killall -HUP nagios && /usr/local/nagios/libexec/eventhandlers/enable_notifications';

# send_nsca binary
my $send_nsca = '/usr/local/bin/send_nsca';

# send_nsca config file
my $nsca_config = '/etc/send_nsca.cfg';

# Which host to send reports to
my $nsca_host = `hostname`;
chomp $nsca_host;

# Which service to send report to
my $nsca_service = 'Nagios Admins Update';

## END OF CONFIG SECTION ##

## TEMPLATE SECTION ##

my $contactgroup_template = 
'"### Pager-Alerts (Exchange/AD Distribution Group) CONTACT GROUP
### AND CONTACT DEFINITIONS.
###
### WARNING: This file is automatically generated by $0.
###          Do not edit by hands!
 
# \'pagers\' contact group definition
define contactgroup{
  contactgroup_name       pagers
  alias                   Pager-Alerts
  members                 $contactlist
}

"';

my $contact_template =
'"# \'$name\' contact definition
define contact{
  contact_name                  $name
  alias                         $fullname
  service_notification_period   24x7
  host_notification_period      24x7
  service_notification_options  c
  host_notification_options     d
  service_notification_commands notify-by-epager
  host_notification_commands    host-notify-by-epager
  pager                         $email
}

"';

## END OF TEMPLATE SECTION ##

# Use IP address to report status - it's usually the most reliable way.
my $hostname = `hostname`;
chomp $hostname;
$hostname = `gethostip -d $hostname`;
chomp $hostname;

sub report_err {
  my $report = shift;
  warn($report);
  open(RESULT, "|$send_nsca -H $nsca_host -c $nsca_config") or warn "couldn't connect";
  print RESULT "$hostname\t$nsca_service\t1\tWARNING: $report\n";
  close(RESULT);
  exit;
}

sub write_config {
  my %contacts;

  open(INFILE, "<$newdump") or report_err("Can't open $newdump for reading: $!");
  while(<INFILE>) {
    (my $name, my $fullname, my $email) = split(/\t/);
    $contacts{$name} = [$fullname, $email];
  }
  close(INFILE);


  # Get the keys we need...
  my $contactlist;
  foreach my $name (sort keys %contacts) {
    $contactlist .= "$name,";
  }
  chop($contactlist);

  open(OUTFILE, ">$tempcfg") or report_err("Can't open $tempcfg for writing: $!");
  # Write the contactgroup
  print OUTFILE eval($contactgroup_template);

  foreach my $name (sort keys %contacts) {
    (my $fullname, my $email) = @{$contacts{$name}};

    # print each contact definition...
    print OUTFILE eval($contact_template);
  }
  close(OUTFILE);
}

report_err("last run unsuccessful, aborting (check $newdump)")
  if (-e $newdump);

# This should write $newdump
`$dumpapp`;

report_err("Error retrieving data from $dumpapp") if ($?);

## Compare old with new
if (-e $olddump) {
  print "Comparing data files\n";
  my $old = `wc -l <$olddump`;
  my $new = `wc -l <$newdump`;

  if (!$old || !$new || abs($old - $new) > 2) {
    report_err("Too many differences: " . abs($new - $old));
  }
}

## Good to go, write down config if needed.
write_config();

`diff -q $tempcfg $cfgfile >/dev/null 2>/dev/null`;
if (($? >> 8) == 1 || !-e $cfgfile) {
  unlink $cfgfile or -e $cfgfile and report_err("Can't unlink $cfgfile: $!");
  `mv $tempcfg $cfgfile`;
  report_err("Can't copy new config over $cfgfile") if ($?);
  `$cfgtestrun`;
  report_err("Nagios test run failed, please ckeck") if ($?);
  `$cfgreloadrun`;
  report_err("Couldn't SIGHUP Nagios, please ckeck") if ($?);
}

## backup old txt file
`mv $newdump $olddump`;

print "All done\n";

open(RESULT, "|$send_nsca -H $nsca_host -c $nsca_config") or die;
print RESULT "$hostname\t$nsca_service\t0\tOK: Nagios Admins update succesfully completed.\n";
close(RESULT);

