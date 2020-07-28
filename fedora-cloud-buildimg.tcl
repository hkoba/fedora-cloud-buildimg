#!/bin/sh
# -*- mode: tcl; coding: utf-8 -*-
# the next line restarts using tclsh \
exec tclsh -encoding utf-8 "$0" ${1+"$@"}

#
# requires /usr/sbin/sfdisk
#

package require fileutil
package require snit
package require fileutil
package require json
package require http
if {![catch {package require tls}]} {
    http::register https 443 tls::socket
}

namespace eval fedora-cloud-buildimg {
    ::variable realScriptFile [::fileutil::fullnormalize [info script]]
    source [file dirname $realScriptFile]/lib/util.tcl
}

#----------------------------------------

namespace eval fedora-cloud-buildimg {
    ::variable realScriptFn [fileutil::fullnormalize [info script]]
    ::variable scriptDir [file dirname $realScriptFn]
}

snit::type fedora-cloud-buildimg {

    option -dry-run no
    option -verbose 1
    option -force no
    option -keep-mount 0
    option -keep-raw 0

    option -fedora-version ""

    option -copr-list ""

    option -platform gce
    option -mount-dir /mnt/disk
    option -admkit-dir ""
    option -admkit-to /admkit
    option -admkit-use-mount no

    option -source-sysroot ""

    option -runtime-dir ""
    option -runtime-to /root/runtime

    option -dist-url https://download.fedoraproject.org/pub/fedora/linux/releases/%d/Cloud/x86_64/images/

    option -image-glob Fedora-Cloud-Base-*.raw.xz
    option -image-dir imgs
    option -source-image ""

    option -update-all no
    option -update-excludes kernel-core
    option -additional-packages {zsh perl git tcl tcllib}
    option -additional-packages-from ""; #

    option -remove-cloud-init ""

    option -use-systemd-nspawn ""

    option -rsync-common-options {
        --recursive
        --links
        --times
        --devices
        --specials
    }
    
    option -rsync-chown root:root

    constructor args {
        $self configurelist $args
        set ::env(LANG) C
        
        if {$options(-use-systemd-nspawn) eq ""} {
            set options(-use-systemd-nspawn) \
                [expr {[auto_execok systemd-nspawn] ne ""}]
        }
        if {$options(-runtime-dir) eq ""} {
            set options(-runtime-dir) \
                [set ::fedora-cloud-buildimg::scriptDir]/runtime
        }
        if {$options(-source-sysroot) eq ""} {
            set options(-source-sysroot) [if {[file isdirectory sysroot]} {
                file normalize sysroot
            } else {
                concat [$self appdir]/sysroot
            }]
        } else {
            if {[regexp /$ $options(-source-sysroot)]} {
                error "-source-sysroot must end with /"
            }
        }
        if {$options(-admkit-dir) eq ""
            && [file isdirectory $options(-source-sysroot)$options(-admkit-to)]} {
            set options(-admkit-dir) $options(-source-sysroot)$options(-admkit-to)
        }
        if {$options(-fedora-version) eq ""} {
            set options(-fedora-version) \
                [$self host-fedora-version]
        }
    }

    #========================================
    method {image prepare} ver {
        $self image download [$self image latest $ver]
    }

    method {image fakename} {} {
        file join $options(-image-dir) [file tail [$self image latest $options(-fedora-version)]]
    }

    method {image latest} ver {
        if {[set url_list [$self image list $ver]] eq ""} {
            error "Can't find download url for Fedora $ver"
        }
        lindex $url_list 0
    }

    method {image list} {ver} {
        set token [$self fetchURL [format $options(-dist-url) $ver]]
        upvar #0 $token state
        set baseUrl $state(url)
        if {[http::ncode $token] != 200} {
            error "Failed to fetch url($baseUrl): [http::data $token]"
        }
        set result []
        foreach {- fn} [regexp -all -inline {<a href="([^\"]*)">} [http::data $token]] {
            if {![string match $options(-image-glob) $fn]} continue
            lappend result $baseUrl$fn
        }
        http::cleanup $token

        set result
    }
    method {image download} url {
        if {![file exists $options(-image-dir)]} {
            $self run file mkdir $options(-image-dir)
        }
        set fn [file join $options(-image-dir) [file tail $url]]
        if {![file exists $fn]
            || ![$self confirm-yes "File $fn already exists. Reuse it? \[Y/n\] "]
        } {
            $self run exec -ignorestderr curl -o $fn $url 2>@ stderr
        }
        set fn
    }

    method fetchURL url {
        set token [http::geturl $url]
        while {[http::ncode $token] >= 300 && [http::ncode $token] < 400} {
            set url [dict get [http::meta $token] location]
            http::cleanup $token
            set token [http::geturl $url]
        }
        set token
    }

    #========================================
    method build args {
        
        if {![string is integer $options(-fedora-version)]} {
            error "Please specify fedora-version (in integer): $options(-fedora-version)"
        }

        $self build-version $options(-fedora-version) {*}$args

    }

    method build-version {ver args} {
        if {$options(-source-image) eq ""} {
            set options(-source-image) [$self image prepare $ver]
        }
        $self build-from $options(-source-image) {*}$args
    }

    method build-from {srcXZFn args} {
        $self traced prepare-mount $srcXZFn

        if {$args eq ""} {
            $self traced $options(-platform) install
        } else {
            $self traced {*}$args
        }

        $self traced finalize
    }

    method prepare-mount srcXZFn {
        if {[$self find-loop-device] ne ""} {
            if {![$self confirm-yes "$options(-mount-dir) is already mounted. Reuse it? \[Y/n\] "]} {
                error "Aborted"
            }
            return $options(-mount-dir)
        }

        set destRawFn [$self traced prepare-raw $srcXZFn]
        set mountDir [$self traced mount-image $destRawFn]
        if {[set errors [$self selinux list-errors]] ne ""} {
            puts "# found selinux errors ($errors)."
        }
        set mountDir
    }

    option -selinux-checklist {
        system_u:object_r:init_exec_t:s0   /usr/lib/systemd/systemd
        system_u:object_r:shadow_t:s0      /etc/gshadow
        system_u:object_r:shadow_t:s0      /etc/gshadow-
        system_u:object_r:passwd_file_t:s0 /etc/passwd
        system_u:object_r:passwd_file_t:s0 /etc/passwd-
        system_u:object_r:shadow_t:s0      /etc/shadow
        system_u:object_r:shadow_t:s0      /etc/shadow-
    }
    method {selinux list-errors} {} {
        if {$options(-dry-run)} return
        set files []
        set wants [dict create]
        foreach {want base} $options(-selinux-checklist) {
            set fn $options(-mount-dir)$base
            if {[file exists $fn]} {
                lappend files $fn
                dict set wants $fn $want
            }
        }
        set nErrors []
        foreach line [split [exec ls -1Z {*}$files] \n] {
            lassign $line actual fn
            if {$actual ne [dict get $wants $fn]} {
                lappend nErrors [list $fn got $actual \
                                     expect [dict get $wants $fn]]
            }
        }
        set nErrors
    }

    method finalize {{destImageFn ""} {destRawFn ""}} {
        $self traced $options(-platform) cleanup

        if {[set errors [$self selinux list-errors]] ne ""} {
            puts "# found selinux errors ($errors)."
            $self sudo-exec-echo \
                touch $options(-mount-dir)/.autorelabel
        }

        if {$options(-keep-mount)} {
            $self sudo-exec-echo \
                mount -o remount,ro $options(-mount-dir)
        } else {
            $self traced umount
        }

        if {$destImageFn eq ""} {
            set destImageFn [$self $options(-platform) image-name-for [$self image fakename]]
        }
        if {$destRawFn eq ""} {
            set destRawFn [$self $options(-platform) raw-name-for]
        }

        set resultFn [$self traced $options(-platform) pack-to \
                          $destImageFn\
                          $destRawFn]
        if {!$options(-keep-raw)} {
            $self run file delete $destRawFn
        }
        set resultFn
    }

    #----------------------------------------
    method prepare-raw {srcXZFn {destRawFn ""}} {
        if {[file extension $srcXZFn] ne ".xz"
            || [file extension [file rootname $srcXZFn]] ne ".raw"
        } {
            error "source image must be .raw.xz format"
        }
        if {$destRawFn eq ""} {
            set destRawFn [$self raw-name-for $srcXZFn]
        }
        $self run exec xzcat $srcXZFn > $destRawFn
        set destRawFn
    }
    method raw-name-for srcXZFn {
        set meth [list $options(-platform) raw-name-for]
        if {[$self info methods $meth] ne ""} {
            $self {*}$meth
        } else {
            return $options(-platform)-[file rootname [file tail $srcXZFn]]
        }
    }

    #========================================
    # platform specific installation
    #
    option -gce-compress auto

    method {gce pack-to} {packFn rawFn} {
        # use --auto selection of compression
        $self run exec tar cf $packFn --$options(-gce-compress) $rawFn \
            >@ stdout 2>@ stderr
        set packFn
    }
    method {gce image-name-for} srcXZFn {
        file join [file dirname $srcXZFn] \
            $options(-platform)-[file rootname [file rootname [file tail $srcXZFn]]].tar.gz
    }
    method {gce raw-name-for} args {
        return disk.raw
    }

    method {common prepare} {} {
        
        $self runtime mount

        if {!$options(-use-systemd-nspawn)} {

            $self sudo-exec-echo \
                cp /etc/resolv.conf $options(-mount-dir)/etc

            $self mount-sysfs
        }
        
        $self admkit-dir ensure visible
    }
    
    method mount-sysfs {} {
        $self sudo-exec-echo \
            mount -t proc /proc $options(-mount-dir)/proc

        $self sudo-exec-echo \
            mount -t sysfs sysfs  $options(-mount-dir)/sys

        # $self sudo-exec-echo \
        #     mount --rbind /sys $options(-mount-dir)/sys
        # $self sudo-exec-echo \
        #     mount --make-rslave $options(-mount-dir)/sys

        # $self sudo-exec-echo \
        #     mount --rbind /dev $options(-mount-dir)/dev
        # $self sudo-exec-echo \
        #     mount --make-rslave $options(-mount-dir)/dev

        $self sudo-exec-echo \
            mount -t devtmpfs devtmpfs $options(-mount-dir)/dev
    }

    method umount-sysfs {} {
        if {![file exists $options(-mount-dir)/proc/cpuinfo]} return
        $self sudo-exec-echo umount $options(-mount-dir)/proc
        $self sudo-exec-echo umount $options(-mount-dir)/sys 
        $self sudo-exec-echo umount $options(-mount-dir)/dev
    }

    method copy-from {dn args} {
        $self sudo-rsync $dn/ $dn {*}$args
    }

    method sudo-rsync {srcDir destDir args} {
        $self traced run self sudo-exec-echo \
            rsync {*}[$self rsync-options $args] \
            $srcDir/ $options(-mount-dir)$destDir
    }

    method rsync-options {{arglist ""}} {
        set opts $options(-rsync-common-options)
        lappend opts {*}[if {$arglist ne ""} {
            set arglist
        } else {
            list --owner --group --chown=$options(-rsync-chown)
        }] 
    }

    method {runtime mount} {} {
        set destDir $options(-mount-dir)$options(-runtime-to)
        if {![file exists $destDir]} {
            $self sudo-exec-echo \
                mkdir -p $destDir
        }
        $self sudo-exec-echo \
            mount --bind $options(-runtime-dir) $destDir
    }
    method {runtime umount} {} {
        set destDir $options(-mount-dir)$options(-runtime-to)
        if {![file exists $destDir/.MOUNTED]} return
        $self sudo-exec-echo umount $destDir
    }

    method {admkit-dir ensure} meth {
        if {[$self admkit-dir exists]} {
            $self admkit-dir $meth
        } else {
            if {$options(-verbose)} {
                puts "# admkit-dir is missing, skipped."
            }
        }
    }
    method {admkit-dir exists} {} {
        expr {$options(-admkit-dir) ne "" && [file isdirectory $options(-admkit-dir)]}
    }
    method {admkit-dir hostpath} {} {
        return $options(-mount-dir)$options(-admkit-to)
    }
    method {admkit-dir visible} {} {
        if {$options(-admkit-use-mount)} {
            $self admkit-dir mount
        } else {
            $self admkit-dir copy
        }
    }
    method {admkit-dir mount} {} {
        set destDir [$self admkit-dir hostpath]
        if {![file exists $destDir]} {
            $self sudo-exec-echo \
                mkdir -p $destDir
        }

        $self sudo-exec-echo \
            mount --bind $options(-admkit-dir) $destDir
    }

    method {admkit-dir umount-and-copy} {} {
        if {!$options(-admkit-use-mount)} return
        $self sudo-exec-echo umount [$self admkit-dir hostpath]
        $self admkit-dir copy
    }

    method {admkit-dir copy} {} {
        $self sudo-exec-echo \
            rsync {*}[$self rsync-options \
                          [list --owner --group --chown=adm:adm \
                               --perms --chmod=Dg+s,ug+w,Fo-w,+X]] \
            $options(-admkit-dir)/ [$self admkit-dir hostpath]
        
        $self chroot-exec-echo \
            restorecon -vr $options(-admkit-to)
    }

    option -xterm mlterm

    method {gce install} {} {

        $self rsync-sysroot

        foreach copr $options(-copr-list) {
            $self traced run self chroot-exec-echo \
                dnf copr enable -y $copr
        }

        set opts []
        foreach s $options(-update-excludes) {
            lappend opts --excludepkgs=$s
        }
        if {$options(-update-all)} {
            $self chroot-exec-echo \
                dnf update -y --allowerasing \
                {*}$opts {*}[$self dnf-options]
        } else {
            $self chroot-exec-echo \
                dnf update -y fedora-gpg-keys
        }

        if {[set errors [$self selinux list-errors]] ne ""} {
            puts "# found selinux errors ($errors)."
        }

        if {$options(-remove-cloud-init) eq ""
            || $options(-remove-cloud-init)
        } {
            puts "# removing cloud-init"
            $self chroot-exec-echo dnf remove -y cloud-init
        }

        $self chroot-exec-echo \
            dnf install -y --allowerasing {*}[$self dnf-options]\
            {*}[$self additional-packages] \
            google-compute-engine-tools

        $self rsync-sysroot
    }
    
    method additional-packages {} {
        set pkgList $options(-additional-packages)
        if {[set glob $options(-additional-packages-from)] ne ""} {
            lappend pkgList {*}[fileutil::cat {*}[glob -nocomplain $glob]]
        }
        set pkgList
    }

    method rsync-sysroot args {
        $self sudo-exec-echo \
            rsync \
            {*}[$self rsync-options] \
            --exclude=admkit/ \
            {*}$args \
            $options(-source-sysroot)/ $options(-mount-dir)
    }

    method {gce cleanup} {} {
        $self chroot-exec-echo \
            dnf clean all

        $self sudo-exec-echo \
            cp /dev/null $options(-mount-dir)/etc/resolv.conf

        $self chroot-exec-echo \
            fstrim /
    }

    method umount {} {
        $self admkit-dir ensure umount-and-copy

        set dev [$self find-loop-device]

        $self runtime umount

        if {!$options(-use-systemd-nspawn)} {
            $self umount-sysfs
        }
        
        $self sudo-exec-echo \
            umount -AR $options(-mount-dir)
        if {$dev in [$self list-used-loop-devices]} {
            $self sudo-exec-echo \
                losetup -d $dev
        }
        if {$dev in [$self list-used-loop-devices]} {
            error "Loop device is still in use! $dev"
        }
    }
    
    method list-used-loop-devices {} {
        set pipe [open [list | sudo losetup -l -n --raw]]
        set result []
        while {[gets $pipe line] >= 0} {
            lappend result [lindex $line 0]
        }
        set result
    }

    method find-loop-device {} {
        foreach line [$self read_file_lines /proc/mounts] {
            if {[regexp "^(/dev/loop\\d+)\\s+$options(-mount-dir)\\s+" $line \
                     -> dev]} {
                return $dev
            }
        }
    }

    method with-fake-machine-id args {
        $self chroot-exec-echo env MACHINE_ID=[$self get-fake-bls-machine-id] \
            {*}$args
    }

    method get-fake-bls-machine-id {} {
        set files [exec sudo chroot $options(-mount-dir) tclsh << {puts [glob -tails -directory /boot/loader/entries *.conf]}]
        regexp -inline {^[0-9a-f]{32,}} [lindex $files 0]
    }

    method sudo-exec-echo args {
        $self run exec sudo {*}$args \
             >@ stdout 2>@ stderr
    }

    method chroot-exec-echo args {
        
        set cmd [if {$options(-use-systemd-nspawn)} {
            list sudo systemd-nspawn -D $options(-mount-dir) \
                $options(-runtime-to)/run-with-rw-selinuxfs.sh
        } else {
            list sudo chroot $options(-mount-dir)
        }]

        $self run exec -ignorestderr {*}$cmd \
            {*}$args \
            >@ stdout 2>@ stderr

    }

    #----------------------------------------

    method mount-image {diskImg {mountDir ""}} {
        $self ensure-image-size $diskImg

        $self mount-image-raw $diskImg $mountDir
        
        $self common prepare
    }

    option -min-image-size

    proc parse-size size {
        expr [string map {
            G *1024*1024*1024
            M *1024*1024
        } $size]
    }

    method ensure-image-size diskImg {

        if {$options(-min-image-size) eq ""} return

        set minSize [parse-size $options(-min-image-size)]
        set curSize [file size $diskImg]

        set diff [expr {$minSize - $curSize}]

        if {$diff <= 0} return

        $self run exec fallocate -l $diff \
            --offset $curSize --zero-range \
            $diskImg \
            >@ stdout 2>@ stderr

        $self with-wholedisk-loopdev loopDiskDev $diskImg {
            $self run exec sudo growpart $loopDiskDev 1 \
                >@ stdout 2>@ stderr

            set loopDev ${loopDiskDev}p1

            $self run exec sudo resize2fs $loopDev \
                >@ stdout 2>@ stderr
        
            $self run exec sudo fsck -y $loopDev \
                >@ stdout 2>@ stderr
        }
    }

    method with-part-loopdev {varName diskImg command} {
        upvar 1 $varName loopDev
        set loopDev [$self prepare-part-loopdev $diskImg]
        scope_guard loopDev [list $self run exec sudo losetup \
                                 -d $loopDev \
                                 >@ stdout 2>@ stderr]
        uplevel 1 $command
    }

    method prepare-part-loopdev {diskImg} {
        set loopDev [exec sudo losetup -f]

        $self run exec sudo losetup \
            -o [$self read-start-offset $diskImg] \
            $loopDev $diskImg \
            >@ stdout 2>@ stderr
        
        set loopDev
    }

    method with-wholedisk-loopdev {varName diskImg command} {
        upvar 1 $varName loopDev
        set loopDev [$self prepare-wholedisk-loopdev $diskImg]
        scope_guard loopDev [list $self run exec sudo losetup \
                                 -d $loopDev \
                                 >@ stdout 2>@ stderr]
        uplevel 1 $command
    }
    method prepare-wholedisk-loopdev {diskImg} {
        set loopDev [exec sudo losetup -f]

        $self run exec sudo losetup \
            --partscan \
            $loopDev $diskImg \
            >@ stdout 2>@ stderr
        
        set loopDev
    }

    method mount-image-raw {diskImg {mountDir ""}} {
        set mountDir [string-or $mountDir $options(-mount-dir)]
        $self run exec sudo mount \
            -t auto \
            -o loop,offset=[$self read-start-offset $diskImg] \
            $diskImg $mountDir
        set options(-mount-dir) $mountDir
    }

    method read-start-offset {diskImg {partNo 0}} {
        expr {[$self read-start-section $diskImg $partNo] * 512}
    }

    method read-start-section {diskImg {partNo 0}} {
        if {$options(-dry-run) && ![file readable $diskImg]} {
            puts "# ...using fake sector number"
            return 2048
        } else {
            dict get [lindex [$self read-partitions $diskImg] $partNo] start
        }
    }

    method read-partitions diskImg {
        set json [$self run exec sfdisk -J $diskImg]
        dict get [::json::json2dict $json] partitiontable partitions
    }

    #----------------------------------------
    method traced args {
        if {$options(-dry-run) || $options(-verbose)} {
            puts "# self $args"
        }
        $self {*}$args
    }

    method run {cmd args} {
        if {$options(-dry-run) || $options(-verbose)} {
            puts "# $cmd $args"
        }
        if {$options(-dry-run)} {
            return
        }
        if {$cmd eq "self"} {
            $self {*}$args
        } else {
            $cmd {*}$args
        }
    }
    
    method source {scriptFn args} {
        if {$options(-dry-run) || $options(-verbose)} {
            puts "# source $scriptFn $args"
        }
        uplevel #0 [list apply [list {self args} [list source $scriptFn]] \
                        $self {*}$args]
    }

    #----------------------------------------
    method host-fedora-version {} {
        set dict [$self os-release]
        if {[dict get $dict ID] eq "fedora"} {
            dict get $dict VERSION_ID
        }
    }
    
    method os-release {} {
        set dict [dict create]
        foreach line [$self read_file_lines /etc/os-release] {
            if {[regexp {^([^=]+)=(.*)} $line -> key value]} {
                dict set dict $key [lindex $value 0]
            }
        }
        set dict
    }

    #----------------------------------------
    # 改行時は yes と解釈する
    method confirm-yes message {
        # TODO: $options(-yes) support
        puts -nonewline $message
        flush stdout
        gets stdin yn
        expr {$yn eq "" || !!$yn}
    }

    #----------------------------------------
    method appdir {} {
        return [file dirname [set ${type}::realScriptFile]]/$options(-platform)
    }
    method dnf-options {} {
        if {$options(-force)} {
            list --nogpgcheck
        }
    }
    method read_file_lines {fn} {
        set fh [open $fn]
        set lines []
        while {[gets $fh line] >= 0} {
            lappend lines $line
        }
        close $fh
        set lines
    }
}

#----------------------------------------

if {![info level] && [info script] eq $::argv0} {
    fedora-cloud-buildimg .obj {*}[fedora-cloud-buildimg::posix-getopt ::argv]

    if {$argv eq ""} {
        error "Usage: [file tail [set fedora-cloud-buildimg::realScriptFile]] COMMAND ARGS..."
    }

    if {[string is list [set result [.obj {*}$argv]]]} {
        puts [join $result \n]
    } else {
        puts $result
    }
}
