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

source [file dirname [fileutil::fullnormalize [info script]]]/libtcl/tcl-expectnit/expectnit.tcl

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

    option -platform gce
    option -mount-dir /mnt/disk

    option -dist-url https://download.fedoraproject.org/pub/fedora/linux/releases/%d/Cloud/x86_64/images/

    option -image-glob Fedora-Cloud-Base-*.raw.xz

    option -update-all no
    option -additional-packages {zsh perl git tcl tcllib}

    option -sudo-askpass-path /usr/libexec/openssh/gnome-ssh-askpass

    component myChroot -public chroot
    option -dnf-timeout 600

    constructor args {
        $self configurelist $args
        set ::env(LANG) C
    }

    method cleanup-chroot {} {
        if {$myChroot ne ""} return
        $myChroot destroy
        set myChroot ""
    }

    method setup-chroot args {
        if {$myChroot ne ""} return

        install myChroot using expectnit $self.chroot
        
        if {$args eq ""} {
            set args /bin/sh
        }

        set sudo [list sudo]
        if {$options(-sudo-askpass-path) ne ""} {
            set sudo [list env SUDO_ASKPASS=$options(-sudo-askpass-path) \
                         {*}$sudo -A]
        }

        $myChroot spawn {*}$sudo \
            chroot $options(-mount-dir) {*}$args
        
        $self chroot wait-prompt
    }

    #========================================
    method {image prepare} ver {
        if {[set url_list [$self image list $ver]] eq ""} {
            error "Can't find download url for Fedora $ver"
        }
        $self image download [lindex $url_list 0]
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
        set fn [file tail $url]
        if {![file exists $fn]
            || ![$self confirm-yes "File $fn already exists. Reuse it? \[Y/n\] "]
        } {
            exec -ignorestderr curl -O $url 2>@ stderr
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
    method build-version {ver args} {
        set fn [$self image prepare $ver]
        $self build-from $fn {*}$args
    }

    method build-from {srcXZFn args} {
        $self traced prepare-mount $srcXZFn

        $self traced common prepare

        $self traced $options(-platform) install
        
        if {$args ne ""} {
            $self traced {*}$args
        }

        $self traced finalize $srcXZFn
    }

    method prepare-mount srcXZFn {
        set destRawFn [$self traced prepare-raw $srcXZFn]
        set mountDir [$self traced mount-image $destRawFn]
    }

    method finalize {srcXZFn {destRawFn ""}} {
        $self traced $options(-platform) cleanup

        if {$options(-keep-mount)} {
            $self sudo-exec-echo \
                mount -o remount,ro $options(-mount-dir)
        } else {
            $self traced umount
        }

        if {$destRawFn eq ""} {
            set destRawFn [$self raw-name-for $srcXZFn]
        }

        set resultFn [$self traced $options(-platform) pack-to \
                          [$self $options(-platform) image-name-for $srcXZFn]\
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
    method {gce pack-to} {packFn rawFn} {
        $self run exec tar zcf $packFn $rawFn \
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
        $self sudo-exec-echo \
            cp /etc/resolv.conf $options(-mount-dir)/etc
        
        $self mount-sysfs
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
        $self sudo-exec-echo umount $options(-mount-dir)/proc
        $self sudo-exec-echo umount $options(-mount-dir)/sys 
        $self sudo-exec-echo umount $options(-mount-dir)/dev
    }

    option -xterm mlterm

    method {gce install} {} {
        $self sudo-exec-echo \
            rsync -av [$self appdir]/sysroot/ $options(-mount-dir)

        if {$options(-update-all)} {
            $self chroot-exec-echo \
                dnf -vvvv update -y --allowerasing {*}[$self dnf-options]
        } else {
            $self chroot-exec-echo \
                dnf -vvvv update -y fedora-gpg-keys
        }

        $self chroot-exec-echo \
            dnf -vvvv install -y --allowerasing {*}[$self dnf-options]\
            {*}$options(-additional-packages) \
            google-compute-engine-tools
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
        set dev [$self find-loop-device]
        $self umount-sysfs
        
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

    method sudo-exec-echo args {
        $self run exec sudo {*}$args \
             >@ stdout 2>@ stderr
    }

    method chroot-exec-echo args {
        $self run exec -ignorestderr sudo chroot $options(-mount-dir) \
            {*}$args \
            >@ stdout 2>@ stderr

    }

    #----------------------------------------

    method mount-image {diskImg {mountDir ""}} {
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

    #----------------------------------------
    # 改行時は yes と解釈する
    method confirm-yes message {
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
