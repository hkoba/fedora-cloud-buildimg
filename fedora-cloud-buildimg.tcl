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

    option -platform gcp
    option -mount-dir /mnt/tmp

    constructor args {
        $self configurelist $args
        set ::env(LANG) C
    }

    #----------------------------------------
    method build-from {srcXZFn {destRawFn ""}} {
        set destRawFn [$self traced prepare-raw $srcXZFn $destRawFn]
        set mountDir [$self traced mount-image $destRawFn]
        $self traced install-to $mountDir
        if {!$options(-keep-mount)} {
            $self run exec umount $mountDir
        }
    }

    #----------------------------------------
    method prepare-raw {srcXZFn {destRawFn ""}} {
        if {[file extension $srcXZFn] ne ".xz"
            || [file extension [file rootname $srcXZFn]] ne ".raw"
        } {
            error "source image must be .raw.xz format"
        }
        if {$destRawFn eq ""} {
            set destRawFn [$self image-name-for $srcXZFn]
        }
        $self run exec xzcat $srcXZFn > $destRawFn
        set destRawFn
    }
    method image-name-for srcXZFn {
        return $options(-platform)-[file rootname [file tail $srcXZFn]]
    }

    #----------------------------------------
    method install-to mountDir {
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
        dict get [lindex [$self read-partitions $diskImg] $partNo] start
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

    puts [.obj {*}$argv]
}
