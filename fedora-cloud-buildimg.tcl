#!/bin/sh
# -*- mode: tcl; coding: utf-8 -*-
# the next line restarts using tclsh \
exec tclsh -encoding utf-8 "$0" ${1+"$@"}

#
# requires /usr/sbin/sfdisk
#

package require snit
package require fileutil
package require json
package require http

namespace eval fedora-cloud-buildimg {
    ::variable realScriptFile [::fileutil::fullnormalize [info script]]
    source [file dirname $realScriptFile]/lib/util.tcl
}

#----------------------------------------

snit::type fedora-cloud-buildimg {

    option -dry-run no
    option -verbose 0
    option -force no
    option -keep-mount 0
    option -keep-raw 0

    option -platform gcp
    option -mount-dir /mnt/tmp

    option -dist-url https://download.fedoraproject.org/pub/fedora/linux/releases/%d/Cloud/x86_64/images/

    option -image-glob Fedora-Cloud-Base-*.raw.xz
    constructor args {
        $self configurelist $args
        set ::env(LANG) C
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
    method build-from {srcXZFn {destRawFn ""}} {
        set destRawFn [$self traced prepare-raw $srcXZFn $destRawFn]
        set mountDir [$self traced mount-image $destRawFn]
        $self traced $options(-platform) install-to $mountDir
        if {!$options(-keep-mount)} {
            $self run exec umount $mountDir
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
    method {gcp pack-to} {packFn rawFn} {
        $self run exec tar zcf $packFn $rawFn \
            >@ stdout 2>@ stderr
        set packFn
    }
    method {gcp image-name-for} srcXZFn {
        return $options(-platform)-[file rootname [file rootname [file tail $srcXZFn]]].tar.gz
    }
    method {gcp raw-name-for} args {
        return disk.raw
    }
    method {gcp install-to} mountDir {
        $self run exec rsync -av [$self appdir]/sysroot/ $mountDir \
             >@ stdout 2>@ stderr

        $self run exec cp /etc/resolv.conf $mountDir/etc

        $self run exec -ignorestderr chroot $mountDir \
            dnf -y copr enable ngompa/gce-oslogin \
            >@ stdout 2>@ stderr

        $self run exec -ignorestderr chroot $mountDir \
            dnf -vvvv install {*}[$self dnf-options]\
            -y google-compute-engine \
            >@ stdout 2>@ stderr

        $self run exec -ignorestderr chroot $mountDir\
            dnf clean all \
            >@ stdout 2>@ stderr

        $self run exec cp /dev/null $mountDir/etc/resolv.conf
    }

    #----------------------------------------

    method mount-image {diskImg {mountDir ""}} {
        set mountDir [string-or $mountDir $options(-mount-dir)]
        $self run exec mount \
            -t auto \
            -o loop,offset=[$self read-start-offset $diskImg] \
            $diskImg $mountDir
        set mountDir
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
}

#----------------------------------------

if {![info level] && [info script] eq $::argv0} {
    fedora-cloud-buildimg .obj {*}[fedora-cloud-buildimg::posix-getopt ::argv]

    if {$argv eq ""} {
        error "Usage: [file tail [set fedora-cloud-buildimg::realScriptFile]] COMMAND ARGS..."
    }

    puts [join [.obj {*}$argv] \n]
}
