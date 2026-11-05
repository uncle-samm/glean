#!/usr/bin/expect -f
# Publishes to Hex. Needs HEXPM_API_KEY in the environment.
# Hex asks for confirmation on 0.x versions; this answers it.

if {![info exists ::env(HEXPM_API_KEY)]} {
    puts "Set HEXPM_API_KEY first."
    exit 1
}

spawn gleam publish --yes

expect {
    "Type 'I am not using semantic versioning' to continue:" {
        send "I am not using semantic versioning\r"
        exp_continue
    }
    eof
}
