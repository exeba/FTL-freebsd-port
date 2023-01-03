#!/bin/sh

# Download ports tree
portsnap fetch
portsnap extract

# Install git
pkg install git
# Clone ports repository
git clone https://github.com/exeba/FTL-freebsd-port.git /FTL-freebsd-port

# Build pihole-ftp (BATCH=yes accepts all defaults for dependencies)
cd /FTL-freebsd-port/dns/pihole-ftl && make install BATCH=yes
# Build pihole-gui (BATCH=yes accepts all defaults for dependencies)
cd /FTL-freebsd-port/dns/pihole-gui && make install BATCH=yes


# Enable pihole service
echo pihole_FTL_enable="YES" >> /etc.rc.conf
# Initialize pihole db
pihole -g


# Install apache & php
pkg install apache24 mod_php81

# Set production mode for php.
# This will prevent E_NOTICES to corrupt json output
cp /usr/local/etc/php.ini-production /usr/local/etc/php.ini

# Enable PHP handler for apache
cat << EOF > /usr/local/etc/apache24/Includes/php.conf
<FilesMatch "\.php$">
    SetHandler application/x-httpd-php
</FilesMatch>
<FilesMatch "\.phps$">
    SetHandler application/x-httpd-php-source
</FilesMatch>
EOF

# Enable pihole-gui config for apache
cp /usr/local/share/examples/pihole-gui/apache24-pihole-gui.conf /usr/local/etc/apache24/Includes/pihole-gui.conf

# Enable "sudo pihole" for apache user
cp /usr/local/share/examples/pihole-gui/sudoers.d-pihole-gui /usr/local/etc/sudoers.d/pihole-gui

# Enable apache webserver
echo apache24_enable="YES" >> /etc.rc.conf
