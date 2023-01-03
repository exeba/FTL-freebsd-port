#!/bin/sh

JAIL_NAME="pihole"
JAIL_HOSTNAME="www.example.org"
IFACE_NAME="em0"
JAILS_PATH="/jails"
JAIL_ROOT="$JAILS_PATH/$JAIL_NAME"

# Create jail root
mkdir -p "$JAIL_ROOT"

# Install base system on jail root
bsdinstall jail "$JAIL_ROOT"

# Copy utility scripts
mkdir -p /usr/local/scripts/
install /usr/share/examples/jails/jib /usr/local/scripts/

cat << EOF >> "/etc/jail.conf.d/$JAIL_NAME.conf"
pihole {
    vnet;
    vnet.interface="e0b_$JAIL_NAME";
    exec.prestart+="/usr/local/scripts/jib addm $JAIL_NAME $IFACE_NAME";
    exec.poststop+="/usr/local/scripts/jib destroy $JAIL_NAME";
    host.hostname = $JAIL_HOSTNAME;            # Hostname
    path = "$JAIL_ROOT";                       # Path to the jail
    mount.devfs;                               # Mount devfs inside the jail
    exec.start = "/bin/sh /etc/rc";            # Start command
    exec.stop = "/bin/sh /etc/rc.shutdown";    # Stop command
}
EOF
