# -*- mode: tcl; coding: utf-8 -*-

proc string-or {str args} {
    foreach str [list $str {*}$args] {
        if {$str ne ""} {
            return $str
        }
    }
}

proc posix-getopt {argVar {dict ""} {shortcut ""}} {
    upvar 1 $argVar args
    set result {}
    while {[llength $args]} {
        if {![regexp ^- [lindex $args 0]]} break
        set args [lassign $args opt]
        if {$opt eq "--"} break
        if {[regexp {^-(-no)?(-\w[\w\-]*)(=(.*))?} $opt \
                 -> no name eq value]} {
            if {$no ne ""} {
                set value no
            } elseif {$eq eq ""} {
                set value [expr {1}]
            }
        } elseif {[dict exists $shortcut $opt]} {
            set name [dict get $shortcut $opt]
            set value [expr {1}]
        } else {
            error "Can't parse option! $opt"
        }
        lappend result $name $value
        if {[dict exists $dict $name]} {
            dict unset dict $name
        }
    }

    list {*}$dict {*}$result
}
