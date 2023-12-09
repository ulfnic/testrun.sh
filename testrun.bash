#!/usr/bin/env bash
# License: GNU Affero General Public License Version 3 (GNU AGPLv3), (c) 2023, Marc Gilligan <marcg@ulfnic.com>
set -o errexit
[[ $DEBUG ]] && set -x



help_doc() {
	cat 1>&2 <<-'HelpDoc'

		testrun.sh [OPTION]... [FILE]... [DIRECTORY]...

		A generic stand-alone script for handling execution and feedback for test files.

		Each DIRECTORY is assumed to only contain executable FILEs that are tests intended to
		be executed by this script.

		Null characters are allowed in stdin (see: -f), and the stdout and stderr of executed test FILEs.


		Options:
		  -a|--all           Include files and directories beginning with '.'
		  -q|--quiet         Only the execution of tests and --help will write to stdout/stderr
		  -r|--recursive     Search each DIRECTORY recursively
		  -p|--params VAL    Contains IFS seperated param(s) to use with all test files, ex: -p '-c=3 -f /my/file'
		  -F|--fork-stdin    Write stdin into all tests
		  --dry-run          Print the filepaths to be executed

		  # -o and -i overwrite each other. They toggle a shared set of attributes.
		  -o|--halt-on       (failed_test|missing_test|non_exec|no_tests)
		  -i|--ignore        (failed_test|missing_test|non_exec|no_tests)

		  --print-result     (always|failure|success|never)
		  --print-stdout     (always|failure|success|never)
		  --print-stderr     (always|failure|success|never)


		Defaults:
		  --print-result always
		  --print-stdout never
		  --print-stderr failure
		  --halt-on missing_test
		  --halt-on no_tests
		  --ignore failed_test
		  --ignore non_exec


		Examples:
			# Run all tests in a directory
			testrun.sh ./tests

			# Run all tests recursively in two different directories
			testrun.sh -r /my/test/dir /my/other-test/dir

			# Fork stdin across all tests
			printf '%s\n' "hello all tests" | testrun.sh -f ./tests


		Exit status:
		  0    success
		  1    unmanaged error
		  2    failed parameter validation
		  4    failed validation of test files to be run
		  8    one or more tests returned an exit code greater than 0

	HelpDoc
	[[ $1 ]] && exit "$1"
}
[[ $1 ]] || help_doc 0



# Define defaults
quiet=
recursive=
test_params=()
fork_stdin=
dry_run=
declare -A halt_on=(
	['missing_test']=1
	['no_tests']=1
)
print_result='always'
print_stdout='never'
print_stderr='failure'
tmp_dir_root='/tmp'



print_stderr() {
	if [[ $1 == '0' ]]; then
		[[ $2 ]] && [[ ! $quiet ]] && printf "$2" "${@:3}" 1>&2 || :
	else
		[[ $2 ]] && printf '%s'"$2" "ERROR: ${0##*/}, " "${@:3}" 1>&2 || :
		exit "$1"
	fi
}


# Read params
test_paths=()
while [[ $1 ]]; do
	case $1 in
		'--all'|'-a')
            shopt -s dotglob ;;
		'--quiet'|'-q')
			quiet=1 ;;
		'--recursive'|'-r')
			recursive=1 ;;
		'--params'|'-p')
			shift; test_params=($1) ;;
		'--fork-stdin'|'-F')
			fork_stdin=1 ;;
		'--dry-run')
			dry_run=1 ;;
		'--halt-on'|'-o')
			shift; halt_on["$1"]=1 ;;
		'--ignore'|'-i')
			shift; halt_on["$1"]= ;;
		'--print-result')
			shift; print_result=$1 ;;
		'--print-stdout')
			shift; print_stdout=$1 ;;
		'--print-stderr')
			shift; print_stderr=$1 ;;
		'--help'|'-h')
			help_doc 0 ;;
		'--')
			break ;;
		'-'*)
			print_stderr 2 '%s\n' 'unrecognized parameter: '"$1" ;;
		*)
			test_paths+=("$1") ;;
	esac
	shift
done
test_paths+=("$@")



# Validate parameter values
[[ ${#test_files[@]} ]] || help_doc 2
[[ -d $tmp_dir_root ]] || printf '%s\n' 'temp directory doesnt exist: '"$tmp_dir_root"

re='^(always|failure|success|never)$'
[[ $print_result =~ $re ]] || print_stderr 2 '%s\n' 'unrecognized value for --print-result: '"$print_result"
[[ $print_stdout =~ $re ]] || print_stderr 2 '%s\n' 'unrecognized value for --print-stdout: '"$print_stdout"
[[ $print_stderr =~ $re ]] || print_stderr 2 '%s\n' 'unrecognized value for --print-stderr: '"$print_stderr"

re='^(failed_test|missing_test|non_exec|no_tests)$'
for prop in "${!halt_on[@]}"; do
	[[ $prop =~ $re ]] || print_stderr 2 '%s\n' 'unrecognized value of --halt-on or --ignore: '"$prop"
done



# Manage/create temp working directory for buffering the stdin and stderr of tests
tmp_dir=$tmp_dir_root'/test-launcher__'$$
[[ -d $tmp_dir ]] && rm -rf "$tmp_dir"

# Delete temp directory on exit
on_exit() {
	[[ -d $tmp_dir ]] && rm -rf "$tmp_dir"
}
trap on_exit EXIT

# Create temp directory with appropriate permissions
umask_orig=$(umask)
umask '0077'
mkdir "$tmp_dir"
umask "$umask_orig"



# Validate paths provided by the user and extract the filepaths belonging to tests
shopt -s nullglob globstar
test_files=()
for test_path in "${test_paths[@]}"; do
	if [[ -x $test_path ]]; then

		if [[ -d $test_path ]]; then
			[[ $recursive ]] && paths_tmp_arr=("$test_path/"**) || paths_tmp_arr=("$test_path/"*)
			for test_path_sub in "${paths_tmp_arr[@]}"; do
				[[ -x $test_path_sub ]] && [[ -f $test_path_sub ]] && test_files+=("$test_path_sub")
			done
		else
			test_files+=("$test_path")
		fi
		continue

	fi

	[[ ${halt_on['missing_test']} ]] && [[ ! -e $test_path ]] && print_stderr 4 '%s\n' 'test path does not exist: '"$test_path"
	[[ ${halt_on['non_exec']} ]] && print_stderr 4 '%s\n' 'test path is not executable: '"$test_path"
done
[[ ${halt_on['no_tests']} ]] && [[ ${#test_files[@]} == '0' ]] && print_stderr 4 '%s\n' 'no files to execute'



# Complete a dry run printing the filepaths to be executed
if [[ $dry_run ]]; then
	for test_path in "${test_files[@]}"; do
		printf -v test_params_print '%q ' "${test_params[@]}"
		printf '%q %s\n' "$test_path" "$test_params_print"
	done
	exit 0
fi



# If --fork-stdin is in use, write stdin to a file so it can be written to the stdin of each test
[[ $fork_stdin ]] && cat /dev/fd/0 > "$tmp_dir"'/stdin'



# Declare functions for printing success/failure conditions of tests
print_success() {
	[[ $print_stdout == 'always' || $print_stdout == 'success' ]] && cat "$tmp_dir"'/stdout'
	[[ $print_stderr == 'always' || $print_stderr == 'success' ]] && cat "$tmp_dir"'/stderr' 1>&2
	print_stderr 0 '\e[32m%s\e[0m %s\n' "[${exit_code}]" "${test_path@Q}"
}

print_failure() {
	[[ $print_stdout == 'always' || $print_stdout == 'failure' ]] && cat "$tmp_dir"'/stdout'
	[[ $print_stderr == 'always' || $print_stderr == 'failure' ]] && cat "$tmp_dir"'/stderr' 1>&2
	print_stderr 0 '\e[31m%s\e[0m %s\n' "[${exit_code}]" "${test_path@Q}"
}



# Execute tests
test_failed=
for test_path in "${test_files[@]}"; do

	if [[ $fork_stdin ]]; then
		"$test_path" "${test_params[@]}" 1> "$tmp_dir"'/stdout' 2> "$tmp_dir"'/stderr' < cat "$tmp_dir"'/stdin' && exit_code=$? || exit_code=$?
	else
		"$test_path" "${test_params[@]}" 1> "$tmp_dir"'/stdout' 2> "$tmp_dir"'/stderr' && exit_code=$? || exit_code=$?
	fi

	case $print_result in
		'always'|'success')
			[[ $exit_code == '0' ]] && print_success
			;;&
		'always'|'failure')
			[[ $exit_code == '0' ]] || print_failure
			;;
	esac

	if [[ $exit_code != '0' ]]; then
		[[ ${halt_on['failed_test']} ]] && exit 8
		test_failed=1
	fi
done



[[ $test_failed ]] && exit 8
exit 0


