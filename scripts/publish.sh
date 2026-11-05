#!/usr/bin/expect -f
# Publishes to Hex. Uses HEXPM_API_KEY from the environment, or else the
# git-ignored .hex_api_key file in the repo root.
# Hex asks for confirmation on 0.x versions; this answers it.

if {![info exists ::env(HEXPM_API_KEY)]} {
    set key_file [file dirname [info script]]/../.hex_api_key
    if {![file exists $key_file]} {
        puts "Set HEXPM_API_KEY or create .hex_api_key first."
        exit 1
    }
    set ::env(HEXPM_API_KEY) [string trim [exec cat $key_file]]
}

spawn gleam publish --yes

expect {
    "Type 'I am not using semantic versioning' to continue:" {
        send "I am not using semantic versioning\r"
        exp_continue
    }
    eof
}
