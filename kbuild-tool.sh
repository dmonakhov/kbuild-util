#!/bin/bash -e
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh
#
# Kernel build swiss knife tool
#

myname=${0##*/}
#default naming
DIR=$(pwd)
KBLD_LOG_LEVEL=1
KBLD_LOG_PREFIX=""
KBLD_DIR=/opt/kbuild-tool

function _fail()
{
   local i
   local stack_size=${#FUNCNAME[@]}

   echo "$0:${BASH_LINENO[1]}: error: $*" 1>&2
   echo "Backtrace:"
   for (( i=1; i < stack_size; i++ )); do
      local func="${FUNCNAME[$i]}"
      local linen="${BASH_LINENO[(( i - 1 ))]}"
      local src="${BASH_SOURCE[$i]}"

      [ -z "$func" ] && func=MAIN
      [ -z "$src" ] && src=non_file_source
      echo  "	[$i] $src:$linen $func"
   done
   exit 1
}

function _assert_args()
{
    local got=$1
    local min=$2
    local max=$3

    [ -z "$max" ] && max=$min

    [ "$got" -ge "$min" ] || _fail "Bad number of arguments, expect[$min, $max], got $got"
    [ "$got" -le "$max" ] || _fail "Bad number of arguments, expect[$min, $max], got $got"
}

function log_info()
{
    if [ "$KBLD_LOG_LEVEL" -ge 1 ]
    then
        echo "${KBLD_LOG_PREFIX}$*"
    fi
}

function log_dbg()
{
    if [ "$KBLD_LOG_LEVEL" -ge 2 ]
    then
        echo "${KBLD_LOG_PREFIX}$*"
    fi
}

######################################
### Artifacts API
function _art_get()
{
    [ -z "$ART_GET_CMD" ] && _art_set_proto "$KBLD_ART_PROTO"
    [ -z "$ART_GET_CMD" ] && _fail "ART_GET_CMD not defined"
    $ART_GET_CMD  "$1" "$2" || _fail "artifact get $1 $2"
}

function _art_put()
{
    [ -z "$ART_PUT_CMD" ] && _art_set_proto "$KBLD_ART_PROTO"
    [ -z "$ART_PUT_CMD" ] && _fail "ART_PUT_CMD not defined"
    $ART_PUT_CMD "$1" "$2" || _fail "artifact put $1 $2"
}

function _get_arch()
{
    uname_M=$(uname -m 2>/dev/null || echo not)
    echo "$uname_M" | sed -e s/i.86/x86/ -e s/x86_64/x86/
}

function _art_set_proto()
{
    _assert_args $# 1
    local proto=$1

    [ -z "$proto" ] && _fail "artifact protocol not defined"

    case "$proto" in
        file)
            ART_PUT_CMD="cp -f"
            ART_GET_CMD=$ART_PUT_CMD
            ;;
        s3)
            [ "$KBLD_LOG_LEVEL" -le 1 ] && XOPT="-q"

            ART_PUT_CMD="s3cmd put $S3CMD_OPT $XOPT"
            ART_GET_CMD="s3cmd get $S3CMD_OPT $XOPT"
            which 's3cmd' > /dev/null || _fail "s3cmd not found"
            ;;
        rsync|ssh)
            [ "$KBLD_LOG_LEVEL" -le 1 ] && XOPT="-q"

            ART_PUT_CMD="rsync -arz $XOPT -e '\$SSH\'"
            ART_GET_CMD=$ART_PUT_CMD
            which 'rsync' > /dev/null || _fail "rsync not found"
            ;;
        *)
            _fail "artifact protocol: $proto not supported"
            ;;
    esac
}
################################################################
# Helper functions
function _upload_pqueue_archive()
{
    _assert_args $# 1 3
    local upload_url=$1
    local head=$2
    local base=$3

    [ -z "$head" ] && head="HEAD"

    if [ -n "$KBLD_DETECT_GUILT" ]
    then
        local applied=""
        applied=$(guilt applied 2> /dev/null) || DO_GUILT=""
        [ -z "$applied" ] && DO_GUILT=""
    fi
    if [ -n "$base" ] && [ -z "$DO_GUILT" ]
    then
        git format-patch "$base..$head" -o $TMP_DIR/pqueue
        tar -c -C $TMP_DIR pqueue | $ZSTD > $TMP_DIR/pqueue.tar.zstd
        _art_put $TMP_DIR/pqueue.tar.zstd $upload_url/pqueue.tar.zstd
        rm -rf $TMP_DIR/pqueue
    fi
    if [ -n "$DO_GUILT" ]
    then
        guilt export -c $TMP_DIR/pqueue
        tar -c -C $TMP_DIR pqueue | $ZSTD > $TMP_DIR/pqueue.tar.zstd
        _art_put $TMP_DIR/pqueue.tar.zstd $upload_url/pqueue.tar.zstd
        rm -rf $TMP_DIR/pqueue
    fi

}

function _upload_git_archive()
{
    _assert_args $# 1
    local upload_url=$1

    [ -e .scmversion ] && mv .scmversion $TMP_DIR/.scmversion
    $KBLD_DIR/setlocalversion --save-scmversion --force-head
    echo '.scmversion' > $TMP_DIR/files.txt
    git ls-files >> $TMP_DIR/files.txt

    tar -c --transform 's,^,linux-kernel/,S' -T $TMP_DIR/files.txt | \
        $ZSTD > $TMP_DIR/linux-kernel.tar.zstd

    _art_put  $TMP_DIR/linux-kernel.tar.zstd $upload_url/linux-kernel.tar.zstd

    [ -e $TMP_DIR/.scmversion ] && mv $TMP_DIR/.scmversion .scmversion
    rm -rf $TMP_DIR/linux-kernel.tar.zstd
}

function _upload_config()
{
    _assert_args $# 1 2
    local upload_url=$1
    local config=$2

    cp $config $TMP_DIR/linux-kernel.config
    _art_put  $TMP_DIR/linux-kernel.config $upload_url/linux-kernel.config
}

function archive_src()
{
    _assert_args $# 0 4
    local url=$1
    local head=$2
    local base=$3
    local kconfig=$4

    [ -z "$url" ] && url=$KBLD_ART_URL
    [ -z "$head" ] && head=$KBLD_SRC_HEAD
    [ -z "$base" ] && base=$KBLD_SRC_BASE
    [ -z  "$kconfig" ] && kconfig=$KBLD_KCONFIG

    _upload_git_archive $url $head $base

    [ -z "$kconfig" ] && kconfig="$DIR/.config"
    [ -f "$kconfig" ] && _upload_config $url $kconfig
}

function _kernel_config()
{
    _assert_args $# 0 2
    local config=$1
    local opt=$2

    [ -n "$KBLD_MRPROPER" ] && make $opt mrproper

    if [ -z "$config" ]
    then
        [ ! -f '.config' ] && make $opt defconfig
    else
        [ -f $config ] || _fail "Can not file $config"
        cat $config > .config
        cp .config .config.orig
    fi

    # It is always good to have ikconfig embedded
    ./scripts/config -e IKCONFIG
    [ -z "$KBLD_NO_LOCALVERSION_AUTO" ] && [ -e ".scmversion" ] && \
           ./scripts/config -e LOCALVERSION_AUTO

    make $opt oldconfig
}

function _kernel_make()
{
    _assert_args $# 1
    local target=$1

    [ -z $KBLD_MAKE_JOBS ] && KBLD_MAKE_JOBS="-j$(nproc)"

    make $KBLD_MAKE_OPT $KBLD_MAKE_JOBS $target 2>&1 | tee -a make.log
    test ${PIPESTATUS[0]} -eq 0 || _fail "make failed"
}


function make_binpkg()
{
    _assert_args $# 0
    
    _kernel_config $KBLD_KCONFIG
    _kernel_make tar-pkg

    krel=$(make kernelrelease)

    [ -z "$KBLD_ARCH" ] && KBLD_ARCH=$(_get_arch)
    pkg="linux-${krel}-${KBLD_ARCH}.tar"
    [ -f "tar-install/$pkg" ] && pkg=tar-install/$pkg
    [ -f $pkg ] || _fail "Can not find bin-pkg $pkg"

    # Do not wastespace on linux, one can restore it from vmlinux
    # via ./script/extract-vmlinux
    [ "$KBLD_ARCH" == "x86" ] && tar --delete boot/vmlinux-${krel} -f $pkg

    $ZSTD < $pkg > $TMP_DIR/linux-binpkg.tar.zstd
    $ZSTD < make.log > $TMP_DIR/linux-binpkg.log.zstd
    _art_put  $TMP_DIR/linux-binpkg.tar.zstd $KBLD_ART_URL/linux-binpkg.tar.zstd
    _art_put  $TMP_DIR/linux-binpkg.log.zstd $KBLD_ART_URL/linux-binpkg.log.zstd

    # Cleanup
    unlink $pkg
    [ -e tar-install ] && rm -rf tar-install
}

function _remote_exec()
{
    _assert_args $# 1 255
    local host=$1
    shift
    $SSH $host "$KBLD_DIR/kbuild-tool --log-prefix REMOTE:$host $*"
}

# Install deps on target
function _install_deps_remote()
{
    _assert_args $# 1
    local host=$1

    need_install=$($SSH $host "test -d $KBLD_DIR || echo install")
    if [ -n "$need_install" ] || [ -n "$KBLD_REMOTE_ALWAYS_INSTALL_DEPS" ]
    then
        $SSH $host "[ -d $KBLD_DIR ] && rm -rf $KBLD_DIR || /bin/true"
        $SSH $host "mkdir -p $KBLD_DIR"
        tar cz $KBLD_DIR | $SSH $host "tar mzx -C /"
    fi

}

function _kernel_prune_old()
{
    _assert_args $# 0
    local default=$(grubby --default-kernel)

    for f in /boot/vmlinuz-*
    do
        krel=${f##/boot/vmlinuz-}
        if rpm -qf "$f" >/dev/null; then
            echo "keeping $f (installed from rpm)"
        elif [ "$(uname -r)" = "$f" ]; then
            echo "keeping $f (running kernel) "
        elif [ $default = "$f" ]; then
            echo "keeping $f (default kernel) "
        else
            echo "removing $f"
            krel=${f##/boot/vmlinuz-}
            grubby --remove-kernel="/boot/vmlinuz-$krel"
            rm -f "/boot/initramfs-$krel.img" "/boot/System.map-$krel"
            rm -f "/boot/vmlinuz-$krel"   "/boot/config-$krel"
            rm -rf "/lib/modules/$krel"
        fi
    done
}

function _kernel_install_local()
{
    _assert_args $# 1 2

    local binpkg=$1
    local boot_opt=$2
    
    local tmp=$(mktemp /tmp/kbuild-tool-XXXXX)
    local pref_msg=""
    
    [ -f "$binpkg" ] || _fail "Can not find bin-pkg at:$binpkg"
    [ -n "$KBLD_PRUNE_OLD" ] && _kernel_prune_old

    $ZSTD < $binpkg -d | tar vmx --exclude='boot/vmlinux-*' -C / > $tmp
    config=$(cat $tmp | grep 'boot/config')
    krel=${config:12}
    [ -z "$krel" ] && _fail "Can not determine kernelrelease from config: $config"
    unlink $tmp
    
    depmod $krel
    mkinitrd -f /boot/initramfs-$krel.img $krel $KBLD_MKINITRD_OPT

    #Performs explicit sync for extra safity
    sync; sync

    # Boot installer
    if [ -z "$boot_opt" ]
    then
        args="--copy-default"
        if [ -n "$KBLD_MAKE_DEFAULT" ]
        then
            args="$args --make-default"
            pref_msg="[DEFAULT]"
        fi
    else
        args="--args=$boot_opt"
    fi
    grubby --remove-kernel=/boot/vmlinuz-$krel \
           --add-kernel=/boot/vmlinuz-$krel \
           --initrd=/boot/initramfs-$krel.img \
           --title=kernel-$krel   $args

    wall "Add new boot kernel: $pref_msg /boot/vmlinuz-$krel installed"

    # ASSUMPTION: new kernel always has index=0, is this always correct?
    _get_grub_info "/boot/vmlinuz-$krel"
    echo "Check idx"
    [ "$grub_index" = "0" ] || _fail "Unexpected boot index for /boot/vmlinuz-$krel, want:0, got: $grub_index"
}

function _get_grub_info
{
    _assert_args $# 1
    #TODO: Silance #SC2154
    grub_index=""
    grub_kernel=""
    grub_initrd=""
    grub_root=""
    grub_args=""
    grub_title=""

    local entry=$1
    local g_info=$(grubby --info=$entry) || _fail "grubby --info=$entry fail"
    local g_cfg=$(echo "$g_info" | sed "s|^\(\S*\)=\([^'].*\)$|\grub_\1='\2'|")

    eval "$g_cfg"
    [ -z "$grub_index" ] && _fail "index not found"
    [ -z "$grub_kernel" ] && _fail "kernel not found"
    [ -z "$grub_initrd" ] && _fail "initrd not found"
    [ -z "$grub_root" ] && _fail "root not found"
    [ -z "$grub_args" ] && _fail "args not found"
    [ -z "$grub_title" ] && _fail "title not found"
    true
}

function delay_exec
{
    _assert_args $# 1 256
    local delay=$1
    shift

    if [ "$delay" -eq 0 ]
    then
        sh -c "$*"
    else
        setsid sh -c "sleep $delay; $*" &>/dev/null < /dev/null &
    fi
}

function _kernel_reboot_local()
{
    _assert_args $# 2 4
    local method=$1
    local entry=$2
    local sync=$3
    local wait=$4
    local delay=0

    [ -z "$wait" ] && wait=5
    [ -z "$sync" ] && delay=4

    _get_grub_info $entry

    wall "Booting ${grub_kernel}, ${grub_title}..."
    if [ "$wait" -ne 0 ]; then
        log_info "Booting ${grub_kernel}, ${grub_title}..."
        log_info "Press Ctrl-C within $wait seconds to cancel"
        sleep $wait
    fi

    [ "$method" == 'reboot' ] && method=$(grubby --bootloader-probe)

    case $method in
        grub)
            savedefault --default=$grub_index --once | grub --batch > /dev/null
            delay_exec $delay 'shutdown -r now'
            ;;
        grub2)
            grub2-reboot $grub_index
            delay_exec $delay 'shutdown -r now'
            ;;
        kexec)
            kexec -l "$grub_kernel" --initrd="$grub_initrd" --command-line="root=$grub_root $grub_args"
            delay_exec $delay 'systemctl kexec'
            ;;
        *)
            _fail "Unknown reboot method: $method"
            ;;
    esac
}

#function _kernel_install_remote()
#{
#    _assert_args $# 2 3
#    local host="$1"
#    local url="$2"
#    local x_opt="$3"
#
#    url_rel=${url%%/linux-binpkg.tar.zstd}
#    _art_get $url_rel/linux-binpkg.tar.zstd $TMP_DIR/linux-binpkg.tar.zstd
#
#    $SSH $host "mkdir -p $TMP_DIR"
#    cat $TMP_DIR/linux-binpkg.tar.zstd | $SSH $host "cat > $TMP_DIR/linux-binpkg.tar.zstd"
#    _remote_exec $host "install $TMP_DIR/linux-binpkg.tar.zstd $x_opt"
#    $SSH $host "rm -rf $TMP_DIR"
#}

function _wait_reboot()
{
    _assert_args $# 2
    local host=$1
    local old_boot_id=$2
    local count=$SSH_MAX_CONN
    local sleep=5

    boot_id=$old_boot_id
    log_info "Wait for '$host' to reboot (timeout: $((count*sleep)) )"

    while [ "$boot_id" == "$old_boot_id" ] && [ $count -ne 0 ]; do
        boot_id=$($SSH $host 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) || boot_id="$old_boot_id"
        count=$((count - 1))
        [ "$boot_id" == "$old_boot_id" ] && sleep $sleep
    done
    [ "$boot_id" == "$old_boot_id" ]  && _fail "Boot-id not changed for $host"
    true
}

function _reboot_remote()
{
    _assert_args $# 3 4
    local host="$1"
    local method="$2"
    local boot_entry="$3"
    local wait="$4"

    o_bootid=$($SSH $host 'cat /proc/sys/kernel/random/boot_id')
    local bk=$($SSH $host "grubby --info=$boot_entry | grep 'kernel=/boot/vmlinuz-'")
    local krel=${bk##kernel=/boot/vmlinuz-}

    _remote_exec "$host" "$method" "/boot/vmlinuz-$krel"
    [ -z "$wait" ] && return
    
    _wait_reboot $host $o_bootid
    n_krel=$($SSH $host "uname -r")
    n_bootid=$($SSH $host 'cat /proc/sys/kernel/random/boot_id')
    [ "$o_bootid" == "$n_bootid" ] &&__fail "Boot-id not changed for $host"
    [ "$krel" == "$n_krel" ] || _fail "Unexpected kernel want: $krel, got: $n_krel"
    log_info "boot_id        : $o_bootid -> $n_bootid"
    log_info "Current kernel : $($SSH $host 'uname -rv')"

}

function do_remote_install()
{
    _assert_args $# 2 6
    local host=$1
    local url=${2%%/linux-binpkg.tar.zstd}
    local prune=""
    local need_reboot=""
    
    [ -z "$host" ] && _usage_and_fail "remote-install require 'host' as an option"
    [ -z "$url" ] && _usage_and_fail "remote-install require 'url' as an option"
        
    shift
    shift
    echo "ARGS: $*"
    echo "ARG: $1"
    while [ "$1" != "" ]; do
        case $1 in
            --prune)
                prune=t
                ;;
            --reboot)
                need_reboot=t
                method="reboot"
                ;;
            --kexec|--kreboot)
                need_reboot=t
                method="kexec"
                ;;
            --wait)
                KBLD_REMOTE_WAIT=t
                ;;
            --nowait)
                KBLD_REMOTE_WAIT=""
                ;;
            *)
                _fail "Unknown option $1"
                ;;
        esac
        shift
    done
   
    _install_deps_remote $host
    [ "$prune" == t ] && _remote_exec $host prune
    _art_get $url/linux-binpkg.tar.zstd $TMP_DIR/linux-binpkg.tar.zstd

    $SSH $host "mkdir -p $TMP_DIR"
    cat $TMP_DIR/linux-binpkg.tar.zstd | $SSH $host "cat > $TMP_DIR/linux-binpkg.tar.zstd"
    _remote_exec $host install "$TMP_DIR/linux-binpkg.tar.zstd"
    $SSH $host "rm -rf $TMP_DIR"
    # Assume that fresh kernel has index 0
    [ "$need_reboot" == "t" ] && _reboot_remote $host $method 0 $KBLD_REMOTE_WAIT
}

function _lookup_config()
{
    while [ "$1" != "" ]; do
        case $1 in
            -c|--config)
                KBLD_CONFIG=$2
                shift
                ;;
            *)
                ;;
        esac
        shift
    done
}

###############################################################################
# Default values
SSH_OPT="-oLogLevel=error -oUserKnownHostsFile=/dev/null \
                          -oStrictHostKeyChecking=no -oBatchMode=yes \
                           -o passwordauthentication=no -o ConnectTimeout=5"
SSH="ssh $SSH_OPT"
SSH_MAX_CONN=100
uname_m=$(uname -m)
ZSTD="$KBLD_DIR/bin/$uname_m/zstd -T0"

###############################################################################
# Execution section
[ -e "$KBLD_DIR/kbuild-tool.config" ] && . "$KBLD_DIR/kbuild-tool.config"
[ -e "$HOME/.config/kbuild-tool.config" ] && . "$HOME/.config/kbuild-tool.config"
[ -e "$DIR/.kbuild-tool.config" ] && . "$DIR/.kbuild-tool.config"
[ -e "$KBLD_CONFIG" ] && . "$KBLD_CONFIG"


function print_help()
{
    echo "Usage: $myname opt"
    echo "	-C dir		: Change workdir"
    echo "  Actions:"
    echo "  art-get [url]	: get artifact"
    echo "  art-put [url]	: put artifact"
    echo "  archive-src		: arcive kernel source to artifact's storage"
    echo "  make-config		: run kernel config"
    echo "  make-binpkg		: make tar-pkg and upload result to artifact"
    echo "  install binpkg	: install kernel from local binpkg"
    echo "  reboot  boot_entry  : reboot to given boot entry via 'poweroff -r'"
    echo "  kexec boot_entry	: reboot to given boot entry via 'kexec'"
    echo "  remote-init  host	: install kbld-tool binaries on given host"
    echo "  remote-install host binpkg_url [--prine][--reboot|--kreboot][--wait]"
    echo "			: install kernel on remote host"
    echo "  remote-reboot host boot_entry  [--wait|--nowait]"
    echo "			: reboot and wait remote host"
    echo "  remote-kexec host boot_entry   [--wait|--nowait]"
    echo "			: kexec and wait remote host"
    exit 1
}

function _usage_and_fail
{
    echo "$*"
    print_help
    exit 1
}

while [ "$1" != "" ]; do
    case $1 in
        -h|--help|help)
            print_help
            ;;
        -v|--verbose)
            KBLD_LOG_LEVEL=$((KBLD_LOG_LEVEL + 1))
            ;;
        --log-prefix)
            KBLD_LOG_PREFIX="$2: "
            shift
            ;;
        -C)
            DIR=$2
            shift
            pushd $DIR
            ;;
        --kconfig)
            KBLD_KCONFIG=$2
            shift
            ;;
        -p|--artifact-proto)
            KBLD_ART_PROTO=$2
            shift
            ;;
        --art-root)
            KBLD_ART_ROOT=$2
            shift
            ;;
        --art-name)
            KBLD_ART_NAME=$2
            shift
            ;;
        --)
            break
            ;;
        *)
            break
            ;;
    esac
    shift
done

if [ -z "$KBLD_ART_URL" ]
then
    # Need to generate unique name
    [ -z "$KBLD_ART_NAME" ] && KBLD_ART_NAME=kbld-$(date +%s| sha1sum | cut -c 1-8)

    KBLD_ART_URL=$KBLD_ART_ROOT/$KBLD_ART_NAME
fi

TMP_DIR=$(mktemp -d /tmp/kbld-XXXXXX)
action=$1
if [ -z "$action" ]
then
    echo "Action required"
    print_help
fi
shift

case ${action} in
    art-put)
        echo $KBLD_ART_URL
        _art_put "$@"
        ;;
    art-get)
        echo $KBLD_ART_URL
        _art_get "$@"
        ;;
    archive-src)
        echo $KBLD_ART_URL
        archive_src "$@"
        ;;
    make-config)
        _kernel_config "$@"
        ;;
    make-binpkg)
        echo $KBLD_ART_URL
        make_binpkg "$@"
        ;;
    prune)
        _kernel_prune_old
        ;;
    install)
        _kernel_install_local "$@"
        ;;
    reboot)
        _kernel_reboot_local reboot "$1"
        ;;
    kexec)
        _kernel_reboot_local kexec "$1"
        ;;
    remote-init)
        [ -z "$1" ] && _usage_and_fail "$action require 'host' as an option"
        _install_deps_remote "$@"
        ;;
    
    remote-install)
        do_remote_install "$@"
        ;;
    remote-reboot)
        host=$1
        entry=$2
        [ -z "$host" ] && _usage_and_fail "$action require 'host' as an option"
        [ -z "$entry" ] && _usage_and_fail "$action require 'entry' as an option"
        [ "$3" == '--wait' ] &&  KBLD_REMOTE_WAIT=t
        [ "$3" == '--nowait' ] &&  KBLD_REMOTE_WAIT=""

        _install_deps_remote $1
        _reboot_remote $host reboot $entry $KBLD_REMOTE_WAIT
        ;;
    remote-kexec)
        host=$1
        entry=$2
        [ -z "$host" ] && _usage_and_fail "$action require 'host' as an option"
        [ -z "$entry" ] && _usage_and_fail "$action require 'entry' as an option"
        [ "$3" == '--wait' ] &&  KBLD_REMOTE_WAIT=t
        [ "$3" == '--nowait' ] &&  KBLD_REMOTE_WAIT=""

        _install_deps_remote $host
        _reboot_remote $host kexec $entry $KBLD_REMOTE_WAIT
        ;;
    *)
        print_help
        ;;
esac
# Cleanup
[ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
exit 0
