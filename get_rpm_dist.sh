#! /bin/sh -x

LSB_RELEASE=/usr/bin/lsb_release
[ ! -x $LSB_RELEASE ] && echo unknown && exit

ID=`$LSB_RELEASE --short --id`

case $ID in
RedHatEnterpriseServer)
	RELEASE=`$LSB_RELEASE --short --release | cut -d. -f1`
	DIST=rhel$RELEASE
	;;
CentOS)
	RELEASE=`$LSB_RELEASE --short --release | cut -d. -f1`
	DIST=el$RELEASE
	;;
Fedora)
	RELEASE=`$LSB_RELEASE --short --release`
	DIST=fc$RELEASE
	;;
SUSE\ LINUX)
	DESC=`$LSB_RELEASE --short --description`
	RELEASE=`$LSB_RELEASE --short --release`
	case $DESC in
	*openSUSE*)
            DIST=opensuse$RELEASE
	    ;;
	*Enterprise*)
            DIST=sles$RELEASE
            ;;
        esac
	;;
*)
	DIST=unknown
	;;
esac

echo $DIST
