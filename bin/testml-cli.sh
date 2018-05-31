#! bash

# shellcheck disable=1090,2034,2154
GETOPT_SPEC="\
  $(basename "$0") <options...> [<testml-file>...]

See 'man testml' for more help.

Common commands:

  testml foo.tml
  testml --lang=python foo.tml
  testml --compile foo.tml
  testml --compile --print foo.tml
  testml --list
  testml --env
  testml --clean

Options:
--
 
c,compile   Compile a TestML file to the cache directory
e,eval=     Specify TestML input on command line
p,print     Print compiled TestML to stdout
l,list      List all the TestML langauge/framework runners
env         Show the TestML environment details
clean       Remove generated TestML files
version     Print TestML version
h,help      Show the command summary
 
R,run=      TestML runner to use (see: testml --list)
B,bridge=   TestML bridge module to use
I,lib=      Directory path to find bridge modules
P,path=     Directory path to find test files and imports
M,module=   TestML runner module to use
C,config=   TestML config file
 
x,debug     Print lots of debugging info
"

source "$TESTML_ROOT/bin/getopt.sh"

testml-run-cli() {
  get-options "$@"

  set -- "${arguments[@]}"

  "cmd-$cmd" "$@"
}

cmd-run() {
  for file; do
    check-input-file "$file"

    set-testml-bin

    set-testml-vars

    compile-testml

    if [[ -z $testml_runner_sourced ]]; then
      source "$TESTML_BIN"
    fi

    set-testml-lib-vars

    testml-run-file "$TESTML_EXEC" || true
  done
}

cmd-compile() {
  for file; do
    check-input-file "$file"

    set-testml-vars

    if $option_print; then
      testml-compiler "$TESTML_FILE"

    else
      mkdir -p "$TESTML_CACHE"

      testml-compiler "$TESTML_FILE" > "$TESTML_EXEC" || {
        rc=$?
        rm -f "$TESTML_EXEC"
        exit $rc
      }
    fi
  done
}

cmd-list() {
  cat <<...
TestML runners use a programming language with one of its testing frameworks.

TestML supports the following runners:

    coffee-mocha    CoffeeScript with Mocha
    coffee-tap      CoffeeScript with TAP
    node-mocha      NodeJS with Mocha
    node-tap        NodeJS with TAP
    perl-tap        Perl 5 with TAP (Test::Builder)
    perl6-tap       Perl 6 with TAP (Test::Builder)
    python-pytest   Python 2 with Pytest

Aliases:
    coffee          Alias for coffee-mocha
    node            Alias for node-mocha
    perl            Alias for perl-tap
    perl6           Alias for perl-tap
    python          Alias for python-pytest

...
}

cmd-env() {
  if [[ -n $1 ]]; then
    export TESTML_INPUT=$1
    set-testml-vars
  fi

  env | grep '^TESTML_'
}

make-clean() {
  # We can't really find the CACHE directory without a filename, so for now we
  # just delete all .testml directories under us in a repo.

  # TODO Check for non-git repos
  git rev-parse --is-inside-work-tree &>/dev/null ||
    die "Can only use --clean inside a code repository"

  for dir in $(find . -type d | grep '/\.testml$'); do
    (
      set -x
      rm -fr "$dir"
    )
  done
}

cmd-version() {
  echo "TestML v$TESTML_VERSION"
}

get-options() {
  local option_eval_lines=1
  GETOPT_ARGS='@arguments' \
    getopt "$@"

  setup-eval

  $option_debug && set -x

  if $option_clean; then
    make-clean

    [[ ${#arguments[@]} -gt 0 ]] || exit 1
  fi

  if [[ -n $option_bridge ]]; then
    export TESTML_BRIDGE="$option_bridge"
  fi
  if [[ -n $option_lib ]]; then
    TESTML_LIB="$(cd $option_lib && pwd)"
    export TESTML_LIB
  fi
  if [[ -n $option_path ]]; then
    TESTML_PATH="$(cd $option_path && pwd)"
    export TESTML_PATH
  fi

  if $option_env; then
    cmd='env'
  elif $option_list; then
    cmd='list'
  elif $option_version; then
    cmd=version
  elif $option_compile; then
    cmd=compile
  else
    cmd=run
  fi

  [[ -n $option_run ]] &&
    export TESTML_RUN="$option_run"

  true
}

setup-eval() {
  [[ ${#option_eval[@]} -gt 0 ]] || return 0

  eval_tml=''
  eval_file=.testml_eval
  rm -f "$eval_file"
  touch "$eval_file"

  for line in "${option_eval[@]}"; do
    echo "$line" >> $eval_file
  done

  for file in "${arguments[@]}"; do
    [[ -f $file ]] ||
      die "File not found '$file'"

    echo >> "$eval_file"
    echo >> "$eval_file"
    cat "$file" >> "$eval_file"
    echo -n "$eval_tml" > "${arguments[0]}"
  done

  arguments=(".testml_eval")
}
