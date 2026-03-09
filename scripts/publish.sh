#!/usr/bin/expect -f

set api_key [exec cat [file dirname [info script]]/../.hex_api_key]
set ::env(HEXPM_API_KEY) $api_key

spawn gleam publish --yes

expect {
    "Type 'I am not using semantic versioning' to continue:" {
        send "I am not using semantic versioning\r"
        exp_continue
    }
    eof
}
