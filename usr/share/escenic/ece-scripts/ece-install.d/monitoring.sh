# module for installing monitoring software, both server and client side.

MONITORING_VENDOR_NAGIOS=nagios
MONITORING_VENDOR_ICINGA=icinga

## Installs the Nagios monitoring server.
## $1 the nagios vendor/falvour, "nagios" and "icinga" are supported.
function install_nagios_monitoring_server()
{
  print "Installing an $1 server on $HOSTNAME ..."
  local monitoring_vendor=$1

  if [[ $(lsb_release -c -s) == "squeeze" ]]; then
    # needed for check-mk
    add_apt_source "deb http://backports.debian.org/debian-backports squeeze-backports main"
  fi
  
  if [ $on_debian_or_derivative -eq 1 ]; then
    if [[ $monitoring_vendor == $MONITORING_VENDOR_NAGIOS ]]; then
      install_packages_if_missing \
        check-mk-server check-mk-config-nagios \
        apache2 nagios3 nagios-nrpe-plugin
    else
      install_packages_if_missing \
        check-mk-server check-mk-config-icinga \
        apache2 icinga nagios-nrpe-plugin icinga-doc
    fi

    # TODO: make it work if check_icmp is in another location?
    if [ -e /usr/lib/nagios/plugins/check_icmp ] ; then
      # setuid root for icmp_check to make check_mk's host checks to work...???
      # see http://lists.mathias-kettner.de/pipermail/checkmk-en/2009-November/000808.html
      run chmod u+s /usr/lib/nagios/plugins/check_icmp
    else
      print_and_log "Unable to setuid root on check_icmp, needed by check_mk's host checks."
    fi

  fi

  if [[ $monitoring_vendor == $MONITORING_VENDOR_ICINGA ]]; then
    print "Setting user/pass for icinga admin ..."
    local file=/etc/icinga/htpasswd.users
    run htpasswd -b -c $file icingaadmin \
      ${fai_monitoring_admin_password-admin}
  fi

  # enable remote commands
  if [[ $monitoring_vendor == $MONITORING_VENDOR_NAGIOS ]]; then
    local file=/etc/nagios3/nagios.cfg
  else
    local file=/etc/icinga/icinga.cfg
  fi

  dont_quote_conf_values=1
  set_conf_file_value check_external_commands 1 $file
  dont_quote_conf_values=0

  if [ $on_debian_or_derivative -eq 1 ]; then
    if [[ $monitoring_vendor == $MONITORING_VENDOR_ICINGA ]]; then
      # see /usr/share/doc/icinga-common/README.Debian
      dpkg-statoverride --update --add nagios www-data 2710 /var/lib/icinga/rw
      dpkg-statoverride --update --add nagios nagios 751 /var/lib/icinga
    fi
  fi

  set_up_monitoring_host_def $monitoring_vendor $fai_monitoring_host_list;

  if [[ $monitoring_vendor == $MONITORING_VENDOR_NAGIOS ]]; then
    file=/etc/nagios3/conf.d/hostgroups_nagios2.cfg
  else
    file=/etc/icinga/objects/hostgroups_icinga.cfg
  fi

  set_up_monitoring_host_group \
    $file \
    "ece-hosts" \
    'Hosts running one or more ECE' \
    ${fai_monitoring_ece_host_list}

  set_up_monitoring_host_group \
    $file \
    "search-hosts" \
    'Hosts running search instance(s) (Solr + indexer)' \
    ${fai_monitoring_search_host_list}

  if [[ $monitoring_vendor == $MONITORING_VENDOR_NAGIOS ]]; then
    run /etc/init.d/nagios3 restart
    add_next_step "Nagios monitoring interface: http://${HOSTNAME}/nagios3"
  else
    run /etc/init.d/icinga restart
    add_next_step "Icinga monitoring interface: http://${HOSTNAME}/icinga"
  fi

  run /etc/init.d/apache2 reload

}

## Sets up the definition file for a given monitoring host.
##
## $1 nagios flavour/vendor
## $2 <host name>#<ip>, e.g.: fire#192.168.1.100
## (the trailing #<ip> is ignored for reasons of backward compatibility)
function set_up_monitoring_host_def()
{
  local monitoring_vendor=$1
  shift;
  local hosts=
  local el=

  for el in "${@}" ; do
    hosts="$hosts '${el%#*}',"
  done
  # remove last ","
  hosts="${hosts%,}"

  make_dir /etc/check_mk
  cat > /etc/check_mk/main.mk <<EOF
# Generated by ece-install on $(date)
all_hosts = [ $hosts ]

filesystem_default_levels = {
   "levels"         : (90, 95), # levels in percent
   "magic"          : 0.8,      # Make bigger disks grow to more than 90/95%
   "trend_range"    : None,     # disable check_mk's trending
}

service_contactgroups = [
  ( "admins", ALL_HOSTS, ALL_SERVICES ),
]

host_contactgroups = [
  ( "admins", ALL_HOSTS ),
]


extra_service_conf["max_check_attempts"] = [
 # NTP checks can fail for 2 days before they trigger an alert.
 ( "2880", ALL_HOSTS, [ "NTP Time" ]),

 # Disk must fill at sustained rate for 45 minutes before issuing a warning
 ( "45", ALL_HOSTS, [ "disk_fill_rate" ]),

 # External HTTP, TCP and DNS must fail for 10 minutes
 ( "10", ALL_HOSTS, [ "external_HTTP", "external_TCP", "external_DNS", "external_PING" ]),

 # All others get 4 minutes.
 ( "4", ALL_HOSTS, ALL_SERVICES ),
]

EOF

# specific local checks 
# Note that these checks are run from the monitoring server itself, which is
# assumed to have the same connectivity as the other server.
  cat > /etc/check_mk/mrpe.cfg <<EOF
# Check that we can access the Internet
# PING google's DNS server.
external_PING    /usr/lib/nagios/plugins/check_ping -H 8.8.8.8 -w 20,2% -c 30,2% -p 1 -t 0.5

# Do a nameserver lookup
external_DNS    /usr/lib/nagios/plugins/check_dns -H www.google.com -s 8.8.8.8 -w 0.3 -c 2 -t 2

# Make a request to Google (this might use a proxy, don't know)
external_HTTP   /usr/lib/nagios/plugins/check_http -H www.google.com -w 0.8 -c 2 -t 2
EOF

  run check_mk -I
  run check_mk -O

}

function install_nagios_node()
{
  print "Installing a Nagios client on $HOSTNAME ..."
  
  if [[ $(lsb_release -c -s) == "squeeze" ]]; then
    # needed for check-mk
    add_apt_source "deb http://backports.debian.org/debian-backports squeeze-backports main"
  fi
  
  if [ $on_debian_or_derivative -eq 1 ]; then
    install_packages_if_missing \
      xinetd \
      check-mk-agent \
      escenic-check-mk-plugins \
      nagios-nrpe-server nagios-plugins
    if [ -r /etc/xinetd.d/check_mk ] ; then
      # enable check_mk in xinetd
      run sed -i 's/\(\s*\)disable\s*=.*/\1disable = no/' /etc/xinetd.d/check_mk

      if [ ! -z "${fai_monitoring_server_ip}" ] ; then
        # Allow the monitorin gserver IP to access check_mk
        run sed -i '/^\s*only_from\s*=.*/s/^/#/' /etc/xinetd.d/check_mk
        run sed -i "/^}$/ i \\\tonly_from = ${fai_monitoring_server_ip}" /etc/xinetd.d/check_mk
      fi
      run /etc/init.d/xinetd reload
    else
      print_and_log "check_mk might not start automatically, as xinetd.d/check_mk is missing"
    fi
  else
    print_and_log "Nagios node installation not supported on your system," \
      "you will have to install it manually."
    return
  fi

  local file=/etc/nagios/nrpe.cfg
  dont_quote_conf_values=1
  set_conf_file_value \
    allowed_hosts \
    127.0.0.1,${fai_monitoring_server_ip} \
    $file
  dont_quote_conf_values=0


  # bug in nagios-nrpe-server, restart fails (sometimes) if the PID
  # isn't there (!)
  run touch /var/run/nagios/nrpe.pid
  run /etc/init.d/nagios-nrpe-server restart

  add_next_step "A Nagios NRPE node and check_mk has been installed" \
    "on ${HOSTNAME}"
}

function install_munin_node()
{
  print_and_log "Installing a Munin node on $HOSTNAME ..."

    # the IP of the monitoring server
  local default_ip=127.0.0.1
  if [ $fai_enabled -eq 1 ]; then
    if [ -n "fai_monitoring_server_ip" ]; then
      monitoring_server_ip=${fai_monitoring_server_ip}
    fi
  elif [ $install_profile_number -ne $PROFILE_MONITORING_SERVER ]; then
    print "What is the IP of your monitoring server? If you don't know"
    print "this, don't worry and just press ENTER"
    echo -n "Your choice [${default_ip}]> "
    read user_monitoring_server

    if [ -n "$user_monitoring_server" ]; then
      monitoring_server_ip=$user_monitoring_server
    fi
  fi

  if [ -z "$monitoring_server_ip" ]; then
    monitoring_server_ip=$default_ip
  fi

  if [ $on_debian_or_derivative -eq 1 ]; then
    packages="munin-node munin-plugins-extra"
    install_packages_if_missing $packages
  else
    print_and_log "Munin node installation not supported on your system," \
      "you will have to install it manually."
    return
  fi

  if [ -n "$monitoring_server_ip" ]; then
    escaped_munin_gather_ip=$(get_perl_escaped ${monitoring_server_ip})
    file=/etc/munin/munin-node.conf
    cat >> $file <<EOF

# added by ece-install $(date)
allow ${escaped_munin_gather_ip}
EOF
  fi

  # install the escenic_jstat munin plugin
  install_escenic_munin_plugins

  if [ $on_debian_or_derivative -eq 1 ]; then
    run service munin-node restart
  fi

  add_next_step "A Munin node has been installed on $HOSTNAME"
}

function install_escenic_munin_plugins() {
  if [ $on_debian_or_derivative -eq 1 ]; then
    install_packages_if_missing escenic-munin-plugins
    return
  fi

  local file=/usr/share/munin/plugins/escenic_jstat_
  run wget $wget_opts \
    https://github.com/mogsie/escenic-munin/raw/master/escenic_jstat_ \
    -O $file
  run chmod 755 $file

  local instance_list=$(get_instance_list)
  if [ -z "${instance_list}" ]; then
    print_and_log "No ECE instances found on $HOSTNAME, so I'm not adding"
    print_and_log "additional Munin configuration"

    if [ $on_debian_or_derivative -eq 1 ]; then
      run service munin-node restart
    fi

    add_next_step "A Munin node has been installed on $HOSTNAME"
    return
  fi

  local escenic_jstat_modules="_gc _gcoverhead _heap _uptime"
  for current_instance in $instance_list; do
    for module in $escenic_jstat_modules; do
	    cd /usr/share/munin/plugins/
	    make_ln escenic_jstat_ escenic_jstat_${current_instance}${module}
    done

    # we need to hack a bit since escenic_jstat_ looks for
    # instance PIDs in $escenic_run_dir ece-<instance>.pid. It's
    # now <type>-<instance>.pid
    file=$escenic_run_dir/$type-${instance_name}.pid
    if [ ! -e $file ]; then
      run touch $file
    fi

    # enabling the instance specific munin entries:
    for el in /usr/share/munin/plugins/escenic_jstat_[a-z]*; do
      run cd /etc/munin/plugins
      make_ln $el
    done
  done

    # TODO in which version(s) of munin is this directory called
    # client-conf.d?
  file=/etc/munin/plugin-conf.d/munin-node
  if [ -e $file ]; then
    cat >> $file <<EOF
[escenic*]
user $ece_user

EOF
  fi

}

function install_munin_gatherer()
{
  print_and_log "Installing a Munin gatherer on $HOSTNAME ..."

  if [ $on_debian_or_derivative -eq 1 ]; then
    packages="munin"
    install_packages_if_missing $packages
  else
    print_and_log "Munin gatherer installation not supported on your" \
      "system :-( You will have to install it manually."
    return
  fi

  if [ $fai_enabled -eq 0 ]; then
    print "Which nodes shall this Munin monitor gather from?" \
      "Separate your hosts with a space, e.g.: 'editor01 db01 web01'"
    echo -n "Your choice> "
    read user_munin_nodes

    if [ -n "$user_munin_nodes" ]; then
      node_list=$user_munin_nodes
    fi
  else
    node_list=${fai_monitoring_munin_node_list}
  fi

  if [ -z "$node_list" ]; then
    return
  fi

  for el in $node_list; do
    local file=/etc/munin/munin-conf.d/escenic.conf
    if [[ -e $file &&  $(grep '\['${el}'\]' $file | wc -l) -gt 0 ]]; then
      print_and_log "${el} already exists on the ${HOSTNAME} Munin gatherer ..."
      continue
    fi

    print_and_log "Adding ${el} to the Munin gatherer on ${HOSTNAME} ..."
    cat >> $file <<EOF
[${el}]
address $(get_ip $el)
use_node_name yes
EOF
  done

  # TODO add the priveleged network to the allowed stanza (i.e. the
  # network wich will do the monitoring of the servers.
  local file=/etc/apache2/conf.d/munin
  if [ -n "$(get_privileged_hosts)" ]; then
    local privileged_hosts=$(
      echo $(get_privileged_hosts) | sed "s#\ #\\\ #g"
    )
    sed -i "s#Allow\ from\ localhost#Allow\ from\ ${privileged_hosts}\ localhost#g" \
      $file
    exit_on_error "Failed adding ${fai_privileged_hosts} to" \
      "Munin's allowed addresses."
    run /etc/init.d/apache2 reload
  fi

  add_next_step "Munin gatherer admin interface: http://${HOSTNAME}/munin" \
    "Make sure all nodes allows its IP to connect to them."
}

## $1 nagios vendor
function create_monitoring_server_overview()
{
  local file=/var/www/index.html
  local title="Welcome to the mighty monitoring server @ ${HOSTNAME}"

cat > $file <<EOF
<html>
  <head>
    <title>$title</title>
    <style type="text/css">
$(cat $(dirname $BASH_SOURCE)/../vizrt.css)
    </style>
  </head>
  <body>
$(cat $(dirname $BASH_SOURCE)/../vizrt-logo-svg.html)
    <h1>$title</h1>
    <ul>
EOF

  if [[ $1 == $MONITORING_VENDOR_NAGIOS ]]; then
    echo '      <li><a href="/nagios3">Nagios</a></li>' >> $file
  else
    echo '      <li><a href="/icinga">Icinga</a> (an enhanced Nagios)</li>' \
      >> $file
  fi
  cat >> $file <<EOF
      <li><a href="/munin">Munin</a></li>
    </ul>
  </body>
</html>
EOF
  add_next_step "Start page for all monitoring interfaces: http://${HOSTNAME}/"
}

function install_monitoring_server()
{
  local nagios_flavour=${fai_monitoring_nagios_flavour-$MONITORING_VENDOR_ICINGA}

  if [ "$(lsb_release -s -c 2>/dev/null)" = "lucid" ]; then
    log "Version $(lsb_release -s -c 2>/dev/null) of" \
      $(lsb_release -s -c 2>/dev/null) \
      "doesn't support Icinga, will use vanilla Nagios instead."
    nagios_flavour=$MONITORING_VENDOR_NAGIOS
  fi

  install_nagios_monitoring_server $nagios_flavour
  install_munin_gatherer
  create_monitoring_server_overview $nagios_flavour

  leave_trail "trail_monitoring_host=$HOSTNAME"
  leave_trail "trail_monitoring_port=80"
}

## $1 configuration file name
## $2 host group name
## $3 host group alias
## $4..n host group members
function set_up_monitoring_host_group()
{
  local file=$1
  local host_group_name=$2
  local host_group_alias=$3
  # the remainding arguments passed to the methods is the member
  # list members
  local host_group_member_list=${@:4:$(( $# - 3 ))}

  # don't set up host groups for empty node lists, so we exit here if
  # the member list is empty.
  if [ -z "${host_group_member_list}" ]; then
    return
  fi

  if [ $(grep "hostgroup_name $host_group_name" $file | wc -l) -gt 0 ]; then
    print "Icinga group member" \
      $host_group_name \
      "already defined, skipping it."
    return
  fi

  cat >> $file <<EOF
define hostgroup {
  hostgroup_name $host_group_name
  alias $host_group_alias
EOF
  echo -n "  members" >> $file
  for el in $host_group_member_list; do
    echo -n " ${el}," >> $file
  done
  cat >> $file <<EOF

}
EOF
}

## Installs and sets up self-reporting of the current host
function install_system_info() {
  # we don't support RedHat right now
  if [ $on_redhat_or_derivative -eq 1 ]; then
    return
  fi

  print_and_log "Setting up a self-reporting module on $HOSTNAME ..."

  install_packages_if_missing lighttpd escenic-common-scripts
  assert_pre_requisite lighttpd

  local port=${fai_reporting_port-5678}
  local dir=${fai_reporting_dir-/var/www/system-info}
  make_dir $dir

  # configure the web server
  local file=/etc/lighttpd/lighttpd.conf

  # set the port
  local property=server.port
  if [ $(grep ^server.port $file | wc -l) -eq 0 ]; then
    echo "${property} = \"${port}\"" >> $file
  else
    run sed -i "s~^${property}.*=.*$~${property}=\"${port}\"~g" $file
  fi

  # set the document root
  property=server.document-root
  run sed -i "s~^${property}.*=.*\"/var/www\"$~${property}=\"$dir\"~g" $file

  # make the web server start
  run /etc/init.d/lighttpd restart

  # set system-info to be run every minute on the host
  local command="system-info -f html -u $ece_user > $dir/index.html"
  if [ $(grep -v ^# /etc/crontab | grep "$command" | wc -l) -lt 1 ]; then
    echo '* *     * * *   root    '$command >> /etc/crontab
  fi

  # doing a first run of system-info since cron will take a minute to start
  eval $command

  # creating symlinks like:
  # /var/www/system-info/var/log/escenic -> /var/log/escenic
  # /var/www/system-info/etc/escenic -> /etc/escenic
  make_dir ${dir}/$(dirname $escenic_log_dir)
  local target=${dir}/$(dirname ${escenic_log_dir})/$(basename ${escenic_log_dir})
  if [ ! -h $target ]; then
    run ln -s ${escenic_log_dir} $target
  fi

  make_dir ${dir}/$(dirname $escenic_conf_dir)
  target=${dir}/$(dirname $escenic_conf_dir)/$(basename $escenic_conf_dir)
  if [ ! -h $target ]; then
    run ln -s ${escenic_conf_dir} $target
  fi

  make_dir ${dir}/$tomcat_base
  target=${dir}/$tomcat_base/logs
  if [ ! -h $target ]; then
    run ln -s $tomcat_base/logs $target
  fi

  # thttpd doesn't serve files if they've got the execution bit set
  # (it then think it's a misnamed CGI script). Hence, we must ensure
  # the execute bit is set.
  if [ -d $escenic_log_dir ]; then
    find $escenic_log_dir -type f | egrep ".log$|.out$" | while read f; do
      run chmod 644 $f
    done
  fi

  if [ -d $escenic_conf_dir ]; then
    find $escenic_conf_dir -type f | \
      egrep ".conf$|.properties$" | while read f; do
      run chmod 644 $f
    done
  fi

  if [ -d  $tomcat_base/logs ]; then
    find $tomcat_base/logs -type f | egrep ".log$" | while read f; do
      run chmod 644 $f
    done
  fi

  add_next_step "Always up to date system info: http://$HOSTNAME:$port/" \
    "you can also see system-info in the shell, type: system-info"
}
