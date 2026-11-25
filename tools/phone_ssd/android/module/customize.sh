SKIPUNZIP=0
ui_print "iPac Phone SSD: installing manual tools only."
ui_print "No USB configuration, kernel, bootloader, or SELinux changes are made."
set_perm "$MODPATH/system/bin/ipac-phone-ssd" 0 0 0755
