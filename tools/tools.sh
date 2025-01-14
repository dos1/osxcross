#!/usr/bin/env bash

export LC_ALL="C"

BASE_DIR=$PWD

TARBALL_DIR=$BASE_DIR/tarballs
BUILD_DIR=$BASE_DIR/build
TARGET_DIR=$BASE_DIR/target
TARGET_DIR_SDK_TOOLS=$TARGET_DIR/SDK/tools
PATCH_DIR=$BASE_DIR/patches
SDK_DIR=$TARGET_DIR/SDK

PLATFORM=$(uname -s)
ARCH=$(uname -m)
SCRIPT=$(basename $0)

if [ $PLATFORM == CYGWIN* ]; then
  echo "Cygwin is no longer supported." 1>&2
  exit 1
fi


function require()
{
  set +e
  which $1 &>/dev/null
  while [ $? -ne 0 ]
  do
    if [ -z "$UNATTENDED" ]; then
      echo ""
      read -p "Please install '$1' then press enter"
    else
      echo "Required dependency '$1' is not installed" 1>&2
      exit 1
    fi
    which $1 &>/dev/null
  done
  set -e
}

if [[ $PLATFORM == *BSD ]] || [ $PLATFORM == "DragonFly" ]; then
  MAKE=gmake
  SED=gsed
else
  MAKE=make
  SED=sed
fi

if [ -z "$USESYSTEMCOMPILER" ]; then
  if [ -z "$CC" ]; then
    export CC="clang"
  fi

  if [ -z "$CXX" ]; then
    export CXX="clang++"
  fi
fi

if [ -z "$CMAKE" ]; then
  CMAKE="cmake"
fi

if [ -n "$CC" ]; then
  require $CC
fi

if [ -n "$CXX" ]; then
  require $CXX
fi

require $SED
require $MAKE
require $CMAKE
require patch
require gunzip


# enable debug messages
[ -n "$OCDEBUG" ] && set -x

if [[ $SCRIPT != *wrapper/build.sh ]]; then
  # how many concurrent jobs should be used for compiling?
  if [ -z "$JOBS" ]; then
    JOBS=$(tools/get_cpu_count.sh || echo 1)
  fi

  if [ $SCRIPT != "build.sh" -a \
       $SCRIPT != "build_clang.sh" -a \
       $SCRIPT != "mount_xcode_image.sh" -a \
       $SCRIPT != "gen_sdk_package_darling_dmg.sh" -a \
       $SCRIPT != "gen_sdk_package_p7zip.sh" -a \
       $SCRIPT != "gen_sdk_package_pbzx.sh"  ]; then
    res=$(tools/osxcross_conf.sh)

    if [ $? -ne 0 ]; then
      echo -n "you must run ./build.sh first before you can start "
      echo "building $DESC"
      exit 1
    fi

    eval "$res"
  fi
fi


# find sdk version to use
function guess_sdk_version()
{
  tmp1=
  tmp2=
  tmp3=
  file=
  sdk=
  guess_sdk_version_result=
  sdkcount=$(find -L tarballs/ -type f | grep MacOSX | wc -l)
  if [ $sdkcount -eq 0 ]; then
    echo no SDK found in 'tarballs/'. please see README.md
    exit 1
  elif [ $sdkcount -gt 1 ]; then
    sdks=$(find -L tarballs/ -type f | grep MacOSX)
    for sdk in $sdks; do echo $sdk; done
    echo 'more than one MacOSX SDK tarball found. please set'
    echo 'SDK_VERSION environment variable for the one you want'
    echo '(for example: SDK_VERSION=10.x [OSX_VERSION_MIN=10.x] ./build.sh)'
    exit 1
  else
    sdk=$(find -L tarballs/ -type f | grep MacOSX)
    tmp2=$(echo ${sdk/bz2/} | $SED s/[^0-9.]//g)
    tmp3=$(echo $tmp2 | $SED s/\\\.*$//g)
    guess_sdk_version_result=$tmp3
    echo 'found SDK version' $guess_sdk_version_result 'at tarballs/'$(basename $sdk)
  fi
  if [ $guess_sdk_version_result ]; then
    if [ $guess_sdk_version_result = 10.4 ]; then
      guess_sdk_version_result=10.4u
    fi
  fi
  export guess_sdk_version_result
}

# make sure there is actually a file with the given SDK_VERSION
function verify_sdk_version()
{
  sdkv=$1
  for file in tarballs/*; do
    if [ -f "$file" ] && [ $(echo $file | grep OSX.*$sdkv) ]; then
      echo "verified at "$file
      sdk=$file
    fi
  done
  if [ ! $sdk ] ; then
    echo cant find SDK for OSX $sdkv in tarballs. exiting
    exit
  fi
}


function extract()
{
  echo "extracting $(basename $1) ..."

  local tarflags

  tarflags="xf"
  test -n "$OCDEBUG" && tarflags+="v"

  case $1 in
    *.pkg)
      require cpio
      which xar &>/dev/null || exit 1
      xar -xf $1
      cat Payload | gunzip -dc | cpio -i 2>/dev/null && rm Payload
      ;;
    *.tar.xz)
      xz -dc $1 | tar $tarflags -
      ;;
    *.tar.gz)
      gunzip -dc $1 | tar $tarflags -
      ;;
    *.tar.bz2)
      bzip2 -dc $1 | tar $tarflags -
      ;;
    *)
      echo "Unhandled archive type" 2>&1
      exit 1
      ;;
  esac
}


function get_exec_dir()
{
  local dirs=$(dirs)
  echo ${dirs##* }
}

function make_absolute_path()
{
  local current_path

  if [ $# -eq 1 ]; then
    current_path=$PWD
  else
    current_path=$2
  fi

  case $1 in
    /*) echo "$1" ;;
     *) echo "${current_path}/$1" ;;
  esac
}

function cleanup_tmp_dir()
{
  if [ -n "$OC_KEEP_TMP_DIR" ]; then
      echo "Not removing $TMP_DIR ..."
      return
  fi
  echo "Removing $TMP_DIR ..."
  rm -rf $TMP_DIR
}

function create_tmp_dir()
{
  mkdir -p $BUILD_DIR
  pushd $BUILD_DIR &>/dev/null
  local tmp

  for i in {1..100}; do
    tmp="tmp_$RANDOM"
    [ -e $tmp ] && continue
    mkdir $tmp && break
  done

  if [ ! -d $tmp ]; then
    echo "cannot create $BUILD_DIR/$tmp directory" 1>&2
    exit 1
  fi

  TMP_DIR=$BUILD_DIR/$tmp
  trap cleanup_tmp_dir EXIT

  popd &>/dev/null
}

# f_res=1 = something has changed upstream
# f_res=0 = nothing has changed

function git_clone_repository
{
  local url=$1
  local branch=$2
  local project_name=$3

  if [ -n "$TP_OSXCROSS_DEV" ]; then
    # copy files from local working directory
    rm -rf $project_name
    cp -r $TP_OSXCROSS_DEV/$project_name .
    if [ -e ${project_name}/.git ]; then
      pushd $project_name &>/dev/null
      git clean -fdx &>/dev/null
      popd &>/dev/null
    fi
    f_res=1
    return
  fi

  if [ ! -d $project_name ]; then
    local args=""
    if [ -z "$FULL_CLONE" ] && [ $branch == "master" ]; then
      args="--depth 1"
    fi 
    git clone $url $args
  fi

  pushd $project_name &>/dev/null

  git reset --hard &>/dev/null
  git clean -fdx &>/dev/null
  git fetch origin
  git checkout $branch
  git pull origin $branch

  local new_hash=$(git rev-parse HEAD)
  local old_hash=""
  local hash_file="$BUILD_DIR/.${project_name}_git_hash"

  if [ -f $hash_file ]; then
    old_hash=$(cat $hash_file)
  fi

  echo -n $new_hash > $hash_file

  if [ "$old_hash" != "$new_hash" ]; then
    f_res=1
  else
    f_res=0
  fi

  popd &>/dev/null
}

function get_project_name_from_url()
{
  local url=$1
  local project_name
  project_name=$(basename $url)
  project_name=${project_name/\.git/}
  echo -n $project_name
}

function build_success()
{
  local project_name=$1
  touch "$BUILD_DIR/.${CURRENT_BUILD_PROJECT_NAME}_build_complete"
  unset CURRENT_BUILD_PROJECT_NAME
}

function build_msg()
{
  echo ""

  if [ $# -eq 2 ]; then
    echo "## Building $1 ($2) ##"
  else
    echo "## Building $1 ##"
  fi

  echo "" 
}

# f_res=1 = build the project
# f_res=0 = nothing to do

function get_sources()
{
  local url=$1
  local branch=$2
  local project_name=$(get_project_name_from_url $url)
  local build_complete_file="$BUILD_DIR/.${project_name}_build_complete"

  CURRENT_BUILD_PROJECT_NAME=$project_name

  build_msg $project_name $branch

  if [[ "$SKIP_BUILD" == *$project_name* ]]; then
    f_res=0
    return
  fi

  git_clone_repository $url $branch $project_name

  if [ $f_res -eq 1 ]; then
    rm -f $build_complete_file
    f_res=1
  else
    # nothing has changed upstream

    if [ -f $build_complete_file ]; then
      echo ""
      echo "## Nothing to do ##"
      echo ""
      f_res=0
    else
      rm -f $build_complete_file
      f_res=1
    fi
  fi
}


function create_symlink()
{
  ln -sf $1 $2
}


function verbose_cmd()
{
  echo "$@"
  eval "$@"
}


function test_compiler()
{
  echo -ne "testing $1 ... "
  $1 $2 -O2 -Wall -o test
  rm test
  echo "works"
}

function test_compiler_cxx11()
{
  set +e
  echo -ne "testing $1 -stdlib=libc++ -std=c++11 ... "
  $1 $2 -O2 -stdlib=libc++ -std=c++11 -Wall -o test &>/dev/null
  if [ $? -eq 0 ]; then
    rm test
    echo "works"
  else
    echo "failed (ignored)"
  fi
  set -e
}

## Also used in gen_sdk_package_pbzx.sh ##

function build_xar()
{
  pushd $BUILD_DIR &>/dev/null

  get_sources https://github.com/tpoechtrager/xar.git master

  if [ $f_res -eq 1 ]; then
    pushd $CURRENT_BUILD_PROJECT_NAME/xar &>/dev/null
    CFLAGS+=" -w" \
      ./configure --prefix=$TARGET_DIR
    $MAKE -j$JOBS
    $MAKE install -j$JOBS
    popd &>/dev/null
    build_success
  fi

  popd &>/dev/null
}



# exit on error
set -e
