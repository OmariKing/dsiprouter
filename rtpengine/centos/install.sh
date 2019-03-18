#!/usr/bin/env bash

# TODO: need to find workaround for compiling rtpengine (building rpm's etc..)
# needing to compile requires updated kernel headers in some cases therefore mandatory restart
# which we want to avoid during install, it also causes issues with AWS AMI build process
function install {
    local RTPENGINE_SRC_DIR="${SRC_DIR}/rtpengine"
    local RTP_UPDATE_OPTS=""


    function installKernelDevHeaders {
        yum install -y "kernel-devel-uname-r == $(uname -r)"
        # if the headers for this kernel are not found try archives
        if [ $? -ne 0 ]; then
            yum install -y https://rpmfind.net/linux/centos/$(cat /etc/redhat-release | cut -d ' ' -f 4)/updates/$(uname -m)/Packages/kernel-devel-$(uname -r).rpm ||
            yum install -y https://rpmfind.net/linux/centos/$(cat /etc/redhat-release | cut -d ' ' -f 4)/os/$(uname -m)/Packages/kernel-devel-$(uname -r).rpm
        fi
    }

    # Install required libraries
    yum install -y epel-release
    yum install -y logrotate rsyslog
    rpm --import http://li.nux.ro/download/nux/RPM-GPG-KEY-nux.ro
    rpm -Uh http://li.nux.ro/download/nux/dextop/el7/x86_64/nux-dextop-release-0-5.el7.nux.noarch.rpm
    yum install -y gcc glib2 glib2-devel zlib zlib-devel openssl openssl-devel pcre pcre-devel libcurl libcurl-devel \
        xmlrpc-c xmlrpc-c-devel libpcap libpcap-devel hiredis hiredis-devel json-glib json-glib-devel libevent libevent-devel \
        iptables-devel kernel-devel kernel-headers xmlrpc-c-devel ffmpeg ffmpeg-devel gperf redhat-lsb &&

    if (( $AWS_ENABLED == 0 )); then
        installKernelDevHeaders
    else
        if [ -e ${DSIP_SYSTEM_CONFIG_DIR}/.bootstrap ]; then
            BOOTSTRAP_MODE=$(cat ${DSIP_SYSTEM_CONFIG_DIR}/.bootstrap)
            if (( $BOOTSTRAP_MODE == 1 )); then
                # VPS kernel headers updated,
                # continue installing dev headers for this kernel
                installKernelDevHeaders
                printf '0' > ${DSIP_SYSTEM_CONFIG_DIR}/.bootstrap
            else
                # Bootstrap finished already, skip this
                echo "Kernel Dev Headers already updated."
            fi
        else
            # VPS kernel headers are generally custom, the headers MUST be updated
            # in order to compile RTPengine, so we must restart for this case
            # To accomodate AWS build process offload this to next startup on the AMI instance
            printf '1' > ${DSIP_SYSTEM_CONFIG_DIR}/.bootstrap
            printf '%s\n%s\n'                                                                               \
                "Kernel packages have been updated to compile RTPEngine and will be installed on reboot."   \
                "RTPEngine will be compiled and installed on reboot after kernel headers are updated."

            # add to startup process finishing rtpengine install (using cron)
            if [ ${SERVERNAT:-0} -eq 1 ]; then
                OPTS='-servernat'
            else
                OPTS=''
            fi
            cronAppend "@reboot $(type -P bash) ${DSIP_PROJECT_DIR}/dsiprouter.sh rtpengineonly ${OPTS}"

            return 0
        fi
    fi

    if [ $? -ne 0 ]; then
        echo "Problem with installing the required libraries for RTPEngine"
        exit 1
    fi

    # Make and Configure RTPEngine
    cd ${SRC_DIR}
    rm -rf rtpengine.bak 2>/dev/null
    mv -f rtpengine rtpengine.bak 2>/dev/null
    git clone https://github.com/sipwise/rtpengine.git --branch ${RTPENGINE_VER} --depth 1
    cd rtpengine/daemon && make

    if [ $? -eq 0 ]; then
        # Copy binary to /usr/sbin
        cp -f ${SRC_DIR}/rtpengine/daemon/rtpengine /usr/sbin/rtpengine

        # Make rtpengine config directory
        mkdir -p /etc/rtpengine

        cd ${SRC_DIR}/rtpengine/iptables-extension &&
        make &&
        cp -f libxt_RTPENGINE.so $(pkg-config xtables --variable=xtlibdir 2>/dev/null)/
        if [ $? -ne 0 ]; then
            echo "Problem installing RTPEngine iptables-extension"
            exit 1
        fi

        # Configure RTPEngine to support kernel packet forwarding
        cd ${SRC_DIR}/rtpengine/kernel-module &&
        make &&
        cp -f xt_RTPENGINE.ko /lib/modules/$(uname -r)/updates/ &&
        if [ $? -ne 0 ]; then
            echo "Problem installing RTPEngine kernel-module"
            exit 1
        fi

        # Remove RTPEngine kernel module if previously inserted
        if lsmod | grep 'xt_RTPENGINE'; then
            rmmod xt_RTPENGINE
        fi
        # Load new RTPEngine kernel module
        depmod -a &&
        modprobe xt_RTPENGINE
        #insmod xt_RTPENGINE.ko

        if [ "$SERVERNAT" == "0" ]; then
            INTERFACE=$EXTERNAL_IP
        else
            INTERFACE=$INTERNAL_IP!$EXTERNAL_IP
        fi

        # create rtpengine user and group
        mkdir -p /var/run/rtpengine
        # sometimes locks aren't properly removed (this seems to happen often on VM's)
        rm -f /etc/passwd.lock /etc/shadow.lock /etc/group.lock /etc/gshadow.lock
        useradd --system --user-group --shell /bin/false --comment "RTPengine RTP Proxy" rtpengine
        chown -R rtpengine:rtpengine /var/run/rtpengine

        # rtpengine config file
        # set table = 0 for kernel packet forwarding
        (cat << EOF
[rtpengine]
table = -1
interface = ${INTERFACE}
listen-ng = 7722
port-min = ${RTP_PORT_MIN}
port-max = ${RTP_PORT_MAX}
log-level = 7
log-facility = local1
log-facility-cdr = local1
log-facility-rtcp = local1
EOF
        ) > ${SYSTEM_RTPENGINE_CONFIG_FILE}

        # setup rtpengine defaults file
        (cat << 'EOF'
RUN_RTPENGINE=yes
CONFIG_FILE=/etc/rtpengine/rtpengine.conf
# CONFIG_SECTION=rtpengine
PIDFILE=/var/run/rtpengine/rtpengine.pid
MANAGE_IPTABLES=yes
TABLE=0
SET_USER=rtpengine
SET_GROUP=rtpengine
EOF
        ) > /etc/default/rtpengine.conf

        # Enable and start firewalld if not already running
        systemctl enable firewalld
        systemctl start firewalld

        # Fix for bug: https://bugzilla.redhat.com/show_bug.cgi?id=1575845
        if (( $? != 0 )); then
            systemctl restart dbus
            systemctl restart firewalld
        fi

        # Setup Firewall rules for RTPEngine
        firewall-cmd --zone=public --add-port=${RTP_PORT_MIN}-${RTP_PORT_MAX}/udp --permanent
        firewall-cmd --reload

        # Setup RTPEngine Logging
        cp -f ${DSIP_PROJECT_DIR}/resources/syslog/rtpengine.conf /etc/rsyslog.d/rtpengine.conf
        touch /var/log/rtpengine.log
        systemctl restart rsyslog

        # Setup logrotate
        cp -f ${DSIP_PROJECT_DIR}/resources/logrotate/rtpengine /etc/logrotate.d/rtpengine

        # Setup Firewall rules for RTPEngine
        firewall-cmd --zone=public --add-port=${RTP_PORT_MIN}-${RTP_PORT_MAX}/udp --permanent
        firewall-cmd --reload

        # Setup tmp files
        echo "d /var/run/rtpengine.pid  0755 rtpengine rtpengine - -" > /etc/tmpfiles.d/rtpengine.conf
        cp -f ${DSIP_PROJECT_DIR}/rtpengine/centos/rtpengine.service /etc/systemd/system/rtpengine.service
        cp -f ${DSIP_PROJECT_DIR}/rtpengine/centos/rtpengine-start /usr/sbin/
        cp -f ${DSIP_PROJECT_DIR}/rtpengine/centos/rtpengine-stop-post /usr/sbin/
        chmod +x /usr/sbin/rtpengine-*

        # update kam configs on reboot
        if (( ${SERVERNAT} == 1 )); then
            RTP_UPDATE_OPTS="-servernat"
        fi
        cronAppend "@reboot $(type -P bash) ${DSIP_PROJECT_DIR}/dsiprouter.sh updatertpconfig ${RTP_UPDATE_OPTS}"

        # Reload systemd configs
        systemctl daemon-reload
        # Enable the RTPEngine to start during boot
        systemctl enable rtpengine
        # Start RTPEngine
        systemctl start rtpengine

        # Start manually if the service fails to start
        if [ $? -ne 0 ]; then
            /usr/sbin/rtpengine --config-file=${SYSTEM_RTPENGINE_CONFIG_FILE} --pidfile=/var/run/rtpengine/rtpengine.pid
        fi

        # File to signify that the install happened
        if [ $? -eq 0 ]; then
            touch ${DSIP_PROJECT_DIR}/.rtpengineinstalled
            echo "RTPEngine has been installed!"

            # remove bootstrap cmds from cron if on AMI image
            if (( $AWS_ENABLED == 1 )); then
                cronRemove 'dsiprouter.sh rtpengineonly'
            fi
        else
            echo "FAILED: RTPEngine could not be installed!"
        fi
    fi
}

# Remove RTPEngine
function uninstall {
    echo "Removing RTPEngine for $DISTRO"
    systemctl stop rtpengine
    rm -f /usr/sbin/rtpengine
    rm -f /etc/rsyslog.d/rtpengine.conf
    rm -f /etc/logrotate.d/rtpengine
    echo "Removed RTPEngine for $DISTRO"
}

case "$1" in
    uninstall|remove)
        uninstall && exit 0
        ;;
    install)
        install && exit 0
        ;;
    *)
        echo "usage $0 [install | uninstall]" && exit 1
        ;;
esac