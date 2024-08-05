#!/usr/bin/bash
output=$(zig fmt --check --ast-check src/*.zig build.zig build.zig.zon)
exit_code=$?
if [ $exit_code -ne 0 ]
then
	>&2 echo "not all files are formatted:"
	>&2 echo "$output"
fi
exit $exit_code
