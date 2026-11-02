#!/bin/zsh
# usage: run-one.sh <tab> <config_dir|-> <claude args...>   (strips CMUX_*, uses real binary)
here=${0:A:h}; tab=$1; cd_=$2; shift 2
for v in ${(k)parameters[(I)CMUX*]}; do unset $v; done
if [[ $cd_ == - ]]; then unset CLAUDE_CONFIG_DIR; else export CLAUDE_CONFIG_DIR=$cd_; fi
MEUM_TAB=$tab MEUM_SOCK=${MEUM_SOCK_OVERRIDE:-$here/run/meum.sock} /opt/homebrew/bin/claude -p --model haiku --settings $here/settings.spike.json "$@" 2>&1 | grep -v '^Permission allow rule'
