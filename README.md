# FTL-freebsd-port
FreeBSD ports of `pihole-FTL` & `AdminLTE` based on the `freebsd` branches of theese repo:

 - https://github.com/exeba/FTL
 - https://github.com/exeba/AdminLTE

Help & feedback is very welcome!

## Installing

Inside the `examples` directory you will find 2 scripts
 which should be self-explanatory and easily adaptable.

These examples are currently being tested on `Freebsd` `13.1`
and use `apache` + `mod_php` for the gui part.

- **jail-setup.sh (optional):**
Setup the jail where pihole will be installed
- **pihole-install.sh:**
Compile pihole and configure apache.

After that you should be able to access the gui from: 
`http://pihole.host/pihole-gui/index.php`

