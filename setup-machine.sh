#!/usr/bin/env bash
set -ex

# TODO: migrate this all the python
this_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Install apt-get requirements
# !!!NOTE!!! You should use the version which supports multiple versions: https://github.com/profitbricks/reprepro
# r-cran-littler is critical for the /usr/bin/r script used extensively by cran2deb
apt-get update && \
    apt-get install -y --no-install-recommends \
    pbuilder devscripts fakeroot dh-r reprepro sqlite3 lsb-release build-essential equivs \
    libcurl4-gnutls-dev libxml2-dev libssl-dev \
    cdbs r-cran-littler

# Attempt to install packages
function join_by { local d=${1-} f=${2-}; if shift 2; then printf %s "$f" "${@/#/$d}"; fi; }


required_modules=("Rcpp" "ctv" "RSQLite" "DBI" "digest" "getopt" "hwriter")
# These may pick up modules for the wrong R version
# TODO: fix Rcpp deps
#set +e
#for module in ${required_modules[*]}; do
#     apt-get install -y --no-install-recommends "r-cran-${module,,}"
#done
#set -e

# NOTE: if you enable this it can hang your docker container
#export MAKEFLAGS='-j$(nproc)'
export MAKEFLAGS='-j2'

# Install R packages requirements
packages_str=\"$(join_by '", "' ${required_modules[*]})\"

cat << EOF > /tmp/r_setup_pkgs.R
ipak <- function(pkg) {
    new.pkg <- pkg[!(pkg %in% installed.packages()[, "Package"])]

    if (length(new.pkg))
        install.packages(new.pkg, dependencies = TRUE, repos="http://cran.rstudio.com/")

    sapply(pkg, require, character.only = TRUE)
}
ipak(c(${packages_str}))
EOF

Rscript /tmp/r_setup_pkgs.R
rm /tmp/r_setup_pkgs.R

# Install R cran2deb package and add bin symlink
R CMD INSTALL "${this_dir}"

if [[ ! -e "/usr/bin/cran2deb" ]]; then
    if [[ -f "/root/cran2deb/exec/cran2deb" ]]; then
      ln -s "/root/cran2deb/exec/cran2deb" /usr/bin/
    elif [[ -f "/usr/local/lib/R/site-library/cran2deb/exec/cran2deb" ]]; then
      ln -s "/usr/local/lib/R/site-library/cran2deb/exec/cran2deb" /usr/bin/
    fi
fi

chmod u+x /usr/bin/cran2deb

# TODO: instead we should ensure these are in the bashrc so they're run on every terminal along with MAKEFLAGS
#   along with the helper functions below
export ROOT=$(cran2deb root)
export ARCH=$(dpkg --print-architecture)
export SYS="debian-${ARCH}"
export R_VERSION=$(dpkg-query --showformat='${Version}' --show r-base-core)
export DIST=$(lsb_release -c -s)

if [[ ! -e ~/.sqliterc ]]; then
  cat << EOF > ~/.sqliterc
.header on
.mode column
EOF
fi

if [[ ! -d "/etc/cran2deb" ]]; then
    mkdir /etc/cran2deb/
    cp -r ${ROOT}/etc/* /etc/cran2deb/

    mkdir -p /etc/cran2deb/archive/${SYS}
    mkdir -p /etc/cran2deb/archive/rep/conf

    mkdir -p /var/cache/cran2deb

    mkdir -p /var/www
    ln -s /etc/cran2deb/archive /var/www/cran2deb
fi

cran2deb repopulate
cran2deb update

list_alias() {
    depend_alias=$1
    debian_pkg=$2
    alias=$3

    sqlite3 /var/cache/cran2deb/cran2deb.db "SELECT * FROM sysreq_override WHERE depend_alias LIKE '$1' OR r_pattern LIKE '$1';"
    sqlite3 /var/cache/cran2deb/cran2deb.db "SELECT * FROM debian_dependency WHERE debian_pkg LIKE '$2' OR alias LIKE '$3';"
}

remove_local_deb() {
  reprepro -b /var/www/cran2deb/rep remove rbuilders "$1"
}

reset_cran2deb() {
    # Will reset
    rm -rf /var/www/cran2deb/rep/db/ /var/www/cran2deb/rep/lists /var/www/cran2deb/rep/pool /var/www/cran2deb/rep/dists/
    sqlite3 /var/cache/cran2deb/cran2deb.db "DROP TABLE builds; DROP TABLE packages;"
    sqlite3 /var/cache/cran2deb/cran2deb.db "DELETE FROM sysreq_override; DELETE FROM debian_dependency; DELETE FROM license_override;"
    cran2deb repopulate
}

reset_reprepro () {
  reprepro -b /var/www/cran2deb/rep removefilter rbuilders 'Section'
}

python3 -m pip install distro rpy2
